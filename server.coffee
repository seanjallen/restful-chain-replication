###
This file represents the servers in the chain. It starts and runs a RESTful webservice on a port in order to participate
in the chain replication protocol.
###

_ = require('lodash')

# The port number this server is running on
myPort = process.argv[2]

# List of ports of all servers that are running chain replication
allPorts = process.argv[3]?.split(',')

# Required args checking should be handled by grunt task but check here just in case
process.exit(1) unless myPort? and allPorts?

express = require('express')
app = express()

requestHelper = require('request')

# The master service used to configure the set of chain replicated servers
Master = require('./master.js')
master = new Master(app, allPorts)

# The data stored at this server, keyed as id => value
data = {}

# A logical clock / sequence counter used to determine the order of requests that are handled by this server.
# Chain replication assumes FIFO links between the servers in the chain, so we add sequence numbers to our forwarded
# http requests to ensure that behavior
clock = 0

# Queue of update requests that are waiting to be processed by this server
pending = []

# Queue of update requests that have been processed and sent down the chain that we are waiting for an acknowledgement of
sent = []

###
Query operation. A client of the service wants to know the value of the object with the given id.
###
app.get '/query/:id', (request, response) ->

  # I'm the tail in the chain! Respond to the query
  if master.isTail(myPort)
    id = request.params.id
    response.send("value of id: #{id} in chain replicated service is: #{data[id]}")

  # I'm not the tail, tell the tail to handle this query
  else
    forwardTo = "http://#{request.hostname}:#{master.getTail()}#{request.originalUrl}"
    response.redirect(forwardTo)

###
Update operation. A client of the service wants to update the value of the object with the given id. The seqNum parameter
is added internally to ensure that requests are forwarded along the chain in FIFO order.
###
app.post '/update/:id/:value/:seqNum?', (request, response) ->
  id = request.params.id
  value = request.params.value
  seqNum = request.params.seqNum

  # If I'm the first server to see this update request and I'm not the head, tell the client to send it to the head!
  if not seqNum? and not master.isHead(myPort)
    response.status(400).send("#{myPort} is not the head server, please send update requests to: #{master.getHead()}")
    return

  # All servers process requests in FIFO order, if a request got here unusally fast, queue it
  if seqNum? and parseInt(seqNum) isnt (clock+1)
    pending.push
      id: id
      value: value
      seqNum: seqNum
      response: response
    return

  clock++

  # Only way this request doesn't have a timestamp / seq num yet is if we're the head server, so assign it one if needed
  seqNum = clock unless seqNum?

  data[id] = value

  # If I'm the tail, the update has been replicated everywhere
  if master.isTail(myPort)
    response.send("value: #{value} stored for id: #{id} at all servers in chain")

  # If I'm not the tail
  else

    # Forward the request down the chain
    sent.push
      id: id
      value: value
      seqNum: seqNum
      response: response
    successorUpdateURL = "http://#{request.hostname}:#{master.getSuccessor(myPort)}/update/"
    successorUpdateURL += encodeURIComponent(id) + '/'
    successorUpdateURL += encodeURIComponent(value) + '/'
    successorUpdateURL += encodeURIComponent(seqNum)
    requestHelper.post(successorUpdateURL)

    # When the request is acked from our successor
    .on 'response', ->

        # Remove request from list of requests that need to be replicated down the chain
        sent = _.reject sent, (element) -> element.seqNum is seqNum

        # Send ack to predecessor
        response.send("value: #{value} stored for id: #{id} at all servers in chain")

app.listen(myPort)