###
Start script for an individual server instance. See README for instructions.
###

# The port number this server is running on
myPort = process.argv[2]

# List of ports of all servers that are running chain replication
allPorts = process.argv[3]?.split(',')

# Required args checking should be handled by grunt task but check here just in case
unless myPort? and allPorts?
  console.error("usage: start port allports")
  process.exit(1)

express = require('express')
app = express()

# The master configuration service used to configure the set of chain replicated servers
Master = require('./master.js')
master = new Master(app, allPorts)

# The chain replicated server instance
Server = require('./server.js')
new Server(app, myPort, master)

app.listen(myPort)