###
This file represents the servers in the chain. It starts and runs a RESTful webservice on a port in order to participate
in the chain replication protocol.
###

# The port number this server is running on
myPort = process.argv[2]

# List of ports of all servers that are running chain replication
allPorts = process.argv[3]?.split(',')

# Required args should be handled by grunt task but check here just in case
process.exit(1) unless myPort? and allPorts?

console.log 'server is running on: ' + myPort
console.log 'all ports: ' + allPorts.join(' ')