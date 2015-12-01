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
        args: ['start', port, portsAsString]
      )
      stream: true

###
Configures the grunt coffee task so we can compile all coffeescript into javascript.

@see grunt-contrib-coffee
###
initCoffeeTaskConfig = (grunt) ->
  grunt.loadNpmTasks('grunt-contrib-coffee')
  grunt.initConfig
    coffee:
      all:
        src: ['*.coffee']
        ext: '.js'
        expand: true
  grunt.registerTask('compile', "Compile all source files.", ['coffee'])

###
Setup the grunt task used to run the application.
###
setupStartTask = (grunt) ->
  grunt.registerTask 'start', 'Start a set of chain replicated servers on a given list of ports.', (ports...) ->
    if _.isEmpty(ports)
      grunt.log.error('Ports for servers to run on are required! See README.')
    else
      initParallelTaskConfig(grunt, ports)
      grunt.task.run(['parallel:server'])

module.exports = (grunt) ->
  initCoffeeTaskConfig(grunt)
  setupStartTask(grunt)