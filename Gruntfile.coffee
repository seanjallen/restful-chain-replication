###
Configures the grunt tasks needed to build and run the application.
###

_ = require('lodash')

###
Configures the grunt parallel task so that we can run a set of replicated servers on the given list of ports in parallel.

@see grunt-parallel

@param object grunt - The grunt task runner object.
@param list[number] ports
###
initParallelTaskConfig = (grunt, ports) ->
  grunt.loadNpmTasks('grunt-parallel')
  portsAsString = ports.join(',')
  grunt.config 'parallel',
    server:
      tasks: _.map(ports, (port) ->
        cmd: 'node'
        args: ['server', port, portsAsString]
      )
      stream: true

module.exports = (grunt) ->

  grunt.registerTask 'chain', 'Start a set of chain replicated servers on different ports.', (ports...) ->
    if _.isEmpty(ports)
      grunt.log.error('Ports for servers to run on are required! See README.')
    else
      initParallelTaskConfig(grunt, ports)
      grunt.task.run(['parallel:server'])