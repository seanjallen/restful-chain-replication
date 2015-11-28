###
A simulated master configuration service that tracks and controls the configuration of the chain of servers.
###

_ = require('lodash')

module.exports = (app, ports) ->

  activePorts = _.clone(ports)

  ###
  Returns true if the server running on the given port is the tail server in the chain.
  ###
  isTail: (port) -> @getTail() is port

  ###
  Returns the port number of the server that is the active tail in the chain.
  ###
  getTail: -> _.last(activePorts)

  ###
  Returns true if the server running on the given port is the head server in the chain.
  ###
  isHead: (port) -> @getHead() is port

  ###
  Returns the port number of the server that is the active head in the chain.
  ###
  getHead: -> _.first(activePorts)

  ###
  Returns the successor server port # to the server with the given port # in the chain. Or
  undefined if the given port number has no successor.
  ###
  getSuccessor: (port) ->
    index = _.indexOf(activePorts, port)
    if index? then activePorts[index+1]