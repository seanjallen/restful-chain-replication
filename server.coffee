###
Represents a replication server in the chain.
###

_ = require('lodash')
requestHelper = require('request')

class Server

  # The data stored at this server, keyed as id => value
  data: {}

  # A logical clock / sequence counter used to determine the order of requests that are handled by this server.
  # Chain replication assumes FIFO links between the servers in the chain, so we add sequence numbers to our forwarded
  # http requests to ensure that behavior
  clock: 0

  # Queue of update requests that are waiting to be processed by this server
  pending: []

  # Queue of update requests that have been processed and sent down the chain that we are waiting for an
  # acknowledgement of
  sent: []

  # Whether or not this server has failed
  failed: false

  ###
  app - The running express app instance.
  myPort - The port that this server is running on.
  master - The master configuration service that configures the state of the chain.
  ###
  constructor: (app, @myPort, @master) ->
    @setupExpressRoutes(app)
    @listenForConfigChanges()

  ###
  Setup REST API routes used by the server.
  ###
  setupExpressRoutes: (app) ->
    app.get '/query/:id', (request, response) => @query(request, response)
    app.delete '/server', (request, response) => @fail(request, response)

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

    # All servers process requests in FIFO order, if a request got here unusally fast, queue it
    if seqNum? and parseInt(seqNum) isnt (@clock+1)
      @pending.push
        id: id
        value: value
        seqNum: seqNum
        request: request
        response: response
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
      @updateComplete(response, id, value)

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
    requestHelper.post(successorUpdateURL)

    # When the request is acked from our successor
    # (note that error responses do not trigger the response event and are thus no-ops)
    .on 'response', =>
      update = _.findWhere({seqNum: seqNum})
      if update?

        # Remove request from list of requests that need to be replicated down the chain
        @sent = _.reject(@sent, {seqNum: seqNum})

        # Send ack to predecessor, or tell the client that the update is complete
        @updateComplete(response, id, value)

  updateComplete: (response, id, value) -> response.send("value: #{value} stored for id: #{id} at all servers in chain")

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
          @updateComplete(update.response, update.id, update.value)
        @sent = []

      # Otherwise re-send all of the updates we have that haven't been acked yet so they can be replicated at our
      # new successor in case they were lost by our old failed successor
      else
        for update in @sent
          @replicateUpdate(update.id, update.value, update.seqNum, update.request, update.response, true)

module.exports = Server