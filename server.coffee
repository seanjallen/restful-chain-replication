###
Represents a replication server in the chain.
###

_ = require('lodash')
requestHelper = require('request')

class Server

  # The data stored at this server, keyed as id => value
  data: null

  # A logical clock / sequence counter used to determine the order of requests that are handled by this server.
  # Chain replication assumes FIFO links between the servers in the chain, so we add sequence numbers to our forwarded
  # http requests to ensure that behavior
  clock: null

  # Queue of update requests that are waiting to be processed by this server
  pending: null

  # Queue of update requests that have been processed and sent down the chain that we are waiting for an
  # acknowledgement of
  sent: null

  # Whether or not this server has failed
  failed: null

  # The port that this server is running on
  myPort: null

  # The master configuration service that configures the state of the chain
  master: null

  ###
  app - The running express app instance.
  myPort - The port that this server is running on.
  master - The master configuration service that configures the state of the chain.
  ###
  constructor: (app, @myPort, @master) ->
    @setupExpressRoutes(app)
    @listenForConfigChanges()
    @init()

  init: ->
    @failed = false
    @clock = 0
    @pending = []
    @sent = []
    @data = {}

  ###
  Setup REST API routes used by the server.
  ###
  setupExpressRoutes: (app) ->
    app.get '/query/:id', (request, response) => @query(request, response)
    app.get '/new-tail/:port', (request, response) => @newTail(request, response)
    app.delete '/server', (request, response) => @fail(request, response)
    app.put '/server', (request, response) => @restart(request, response)

    # The seqNum parameter is added internally to ensure that requests are forwarded along the chain in FIFO order.
    app.post '/update/:id/:value/:seqNum?', (request, response) => @update(request, response)

  ###
  Listen to the master service for changes in the server chain configuration (server failures, server additions).
  ###
  listenForConfigChanges: -> @master.on 'successorFailed', (port) => @successorFailed(port)

  ###
  Query operation. A client of the service wants to know the value of the object with the given id.
  ###
  query: (request, response) ->
    if @failed
      response.sendStatus(500)
      return

    # I'm the tail in the chain! Respond to the query
    if @master.isTail(@myPort)
      id = request.params.id
      response.send("value of id: #{id} in chain replicated service is: #{@data[id]}")

    # I'm not the tail, tell the tail to handle this query
    else
      forwardTo = "http://#{request.hostname}:#{@master.getTail()}#{request.originalUrl}"
      response.redirect(forwardTo)

  ###
  Update operation. A client of the service wants to update the value of the object with the given id. The seqNum
  parameter is added internally to ensure that requests are forwarded along the chain in FIFO order.
  ###
  update: (request, response) ->
    if @failed
      response.sendStatus(500)
      return

    id = request.params.id
    value = request.params.value
    seqNum = request.params.seqNum

    # If I'm the first server to see this update request and I'm not the head, tell the client to send it to the head!
    if not seqNum? and not @master.isHead(@myPort)
      response.status(400).send("#{@myPort} is not the head server, please send update requests to: #{@master.getHead()}")
      return

    # All servers process requests in FIFO order, if a request got here unusally fast (> clock+1), queue it
    # Also if this is a duplicate request that we have already processed (<= clock, which can happen if one of our
    # predecessors failed and their predecessor never received an ack for the update), queue it and we will re-ack it
    # when the original update request can be acked
    if seqNum? and parseInt(seqNum) isnt (@clock+1)
      @pending.push
        id: id
        value: value
        seqNum: seqNum
        request: request
        response: response
      @ackDuplicatePendingUpdates()
      return

    @clock++

    # Only way this request doesn't have a timestamp / seq num yet is if we're the head server, so assign it one if needed
    seqNum = @clock unless seqNum?

    @processUpdate(id, value, seqNum, request, response)

    # Process all of the pending requests that may have been queued before this request arrived
    nextRequest = _.findWhere(@pending, {seqNum: seqNum+1})
    while nextRequest?
      @clock++
      @processUpdate(nextRequest.id, nextRequest.value, nextRequest.seqNum, nextRequest.request, nextRequest.response)

      # Update has been processed, so remove it from our list of pending requests
      @pending = _.reject @pending, (element) -> element.seqNum is nextRequest.seqNum

      nextRequest = _.findWhere(@pending, {seqNum: nextRequest.seqNum+1})

  ###
  Processes the update and then takes the appropriate action to ensure that it is also processed at all other servers.
  ###
  processUpdate: (id, value, seqNum, request, response) ->
    @data[id] = value

    # If I'm the tail, the update has been replicated everywhere
    if @master.isTail(@myPort)
      @updateComplete(response)

    # If I'm not the tail, we need to replicate the update down the chain
    else
      @replicateUpdate(id, value, seqNum, request, response)

  ###
  Replicates the update request with the given parameters to the successor server in the chain, and acknowledges the
  predecessor server (or the client if we're the head [see README for note on this]) once this is complete.
  ###
  replicateUpdate: (id, value, seqNum, request, response, sendingAgain=false) ->

    # Track list of replicated requests that need to be acknowledged
    unless sendingAgain
      @sent.push
        id: id
        value: value
        seqNum: seqNum
        request: request
        response: response

    # Forward the request down the chain
    successorUpdateURL = "http://#{request.hostname}:#{@master.getSuccessor(@myPort)}/update/"
    successorUpdateURL += encodeURIComponent(id) + '/'
    successorUpdateURL += encodeURIComponent(value) + '/'
    successorUpdateURL += encodeURIComponent(seqNum)
    requestHelper.post successorUpdateURL, (error) =>

      # If we have failed by the time we receive the ack from our successor, do not forward the ack to our predecessor
      if @failed
        response.sendStatus(500)
        return

      # If our successor failed and thus cannot send an ack back to us saying that the update was replicated, do nothing,
      # wait until we get a notification from the master chain config service and then take the appropriate action
      if error
        return

      # Find the update request that was just acked from our successor
      update = _.findWhere(@sent, {seqNum: seqNum})
      if update?

        # Remove request from list of requests that need to be replicated down the chain
        @sent = _.reject(@sent, {seqNum: seqNum})

        # Send ack to predecessor, or tell the client that the update is complete
        @updateComplete(response)

  ###
  Resolves the given http response for an update operation.
  ###
  updateComplete: (response, ackDuplicates=true) ->
    response.send("Update complete.")
    if ackDuplicates
      @ackDuplicatePendingUpdates()

  ###
  Clears the pending request queue of any duplicate update requests we have received that have already been applied at
  this server and replicated at all successor servers in the chain.
  ###
  ackDuplicatePendingUpdates: ->
    alreadyAppliedUpdates = _.filter @pending, (pendingRequest) => pendingRequest.seqNum <= @clock
    for update in alreadyAppliedUpdates
      unless _.findWhere(@sent, {seqNum: update.seqNum})? # Unless this update hasn't been replicated yet
        @updateComplete(update.response, false)

  ###
  Fail operation. Simulates a server failure.
  ###
  fail: (request, response) ->
    if @failed
      response.sendStatus(500)
      return
    @failed = true
    @master.fail(@myPort)
    response.send("Server #{@myPort} has been killed.")

  ###
  Notification from configuration service that the successor of the chain server running on the given port has failed.
  ###
  successorFailed: (port) ->

    # My successor failed!
    if port is @myPort

      # If I'm the new tail, all of the update requests that I'm waiting to be acked have been replicated to all servers
      if @master.isTail(@myPort)
        for update in @sent
          @updateComplete(update.response)
        @sent = []

      # Otherwise re-send all of the updates we have that haven't been acked yet so they can be replicated at our
      # new successor in case they were lost by our old failed successor
      else
        for update in @sent
          @replicateUpdate(update.id, update.value, update.seqNum, update.request, update.response, true)

  ###
  NewTail operation. A new server has been added to the chain and wants us (the old tail), to forward all of our data
  down to them.
  ###
  newTail: (request, response) ->
    if @failed
      response.sendStatus(500)
      return
    response.json
      clock: @clock
      data: @data
    @master.add(request.params.port)

  ###
  Restart operation, the failed server has been rebooted and wants to be added back into the chain as the new tail.
  ###
  restart: (request, response) ->
    unless @failed
      response.status(405)
      response.send("Cannot restart a server that has not been failed.")
      return
    @askTailForData(response)

  ###
  Notifies the tail server in the chain that we want to be the new tail and asks it to forward all of the replicated
  service data down to us.
  ###
  askTailForData: (response) ->
    tailPort = @master.getTail()
    if tailPort?
      requestHelper.get "http://localhost:#{tailPort}/new-tail/#{@myPort}", (error, tailResponse, body) =>

        # If the tail has failed, ask the new tail for data
        if error
          @master.fail(tailPort)
          @askTailForData(response)

        # If the tail is still up, initialize myself as the new tail
        else
          @master.add(@myPort)
          @init()
          tailState = JSON.parse(body)
          @clock = tailState.clock
          @data = tailState.data
          response.send("#{@myPort} has been fully restarted and is now the new tail in the chain.")

    # If the entire chain failed, not much we can do, so start a new chain!
    else
      @master.add(@myPort)
      @init()
      response.send("#{@myPort} has been fully restarted, but all previous data has been lost since all servers were failed at once.")

module.exports = Server