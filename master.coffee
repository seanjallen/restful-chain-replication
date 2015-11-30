###
A simulated master configuration service that tracks and controls the configuration of the chain of servers. This is an
extremely basic and naive minimum implementation doing just enough so that the replication algorithm can work and should
not be used as an example. In reality the configuration service would use its own replication scheme and would be
accessible by the chain servers when they needed it.
###

_ = require('lodash')
requestHelper = require('request')
EventEmitter = require('events').EventEmitter

class Master extends EventEmitter

  ###
  @param object app - The running express app instance for this server.
  @param [number] ports - The port numbers of all of the servers participating in the replication scheme.
  ###
  constructor: (@app, @allPorts) ->
    @activePorts = _.clone(@allPorts)
    @synchronize()

  ###
  Returns true if the server running on the given port is the tail server in the chain.
  ###
  isTail: (port) -> @getTail() is port

  ###
  Returns the port number of the server that is the active tail in the chain.
  ###
  getTail: -> _.last(@activePorts)

  ###
  Returns true if the server running on the given port is the head server in the chain.
  ###
  isHead: (port) -> @getHead() is port

  ###
  Returns the port number of the server that is the active head in the chain.
  ###
  getHead: -> _.first(@activePorts)

  ###
  Returns the successor server port # to the server with the given port # in the chain, or undefined if the given port
  number has no successor.
  ###
  getSuccessor: (port) ->
    index = _.indexOf(@activePorts, port)
    if index? then @activePorts[index+1]

  ###
  Returns the predecessor port # to the server with the given port # in the chain, or undefined if the given port
  number has no predecessor.
  ###
  getPredecessor: (port) ->
    index = _.indexOf(@activePorts, port)
    if index? then @activePorts[index-1]

  ###
  Fail the server running on the given port.

  @param number port
  @param boolean broadcast - If true this failure will be broadcasted to all other servers so their master service
  instances can update the state of the chain.
  ###
  fail: (failedPort, broadcast=true) ->
    predecessor = @getPredecessor(failedPort)
    @activePorts = _.without(@activePorts, failedPort)
    if broadcast
      for port in @allPorts
        requestHelper.del("http://localhost:#{port}/sync/#{failedPort}")
    if predecessor?
      @emit('successorFailed', predecessor)

  ###
  The server on the given port has been added to the chain as the new tail.
  ###
  add: (addPort, broadcast=true) ->
    unless _.contains(@activePorts, addPort)
      @activePorts.push(addPort)
    if broadcast
      for port in @allPorts
        requestHelper.put("http://localhost:#{port}/sync/#{addPort}")

  ###
  Open up express app routes used to keep this master instance in sync with all of the other instances.
  ###
  synchronize: ->

    # Failure notifications
    @app.delete '/sync/:port', (request, response) =>
      @fail(request.params.port, false)
      response.sendStatus(200)

    # Add new server notifications
    @app.put '/sync/:port', (request, response) =>
      @add(request.params.port, false)
      response.sendStatus(200)

module.exports = Master