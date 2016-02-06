# Hue ZLL Pimatic plugin

module.exports = (env) ->

  # Require the  bluebird promise library
  Promise = env.require 'bluebird'

  # Require the [cassert library](https://github.com/rhoot/cassert).
  assert = env.require 'cassert'

  t = env.require('decl-api').types

  # node-hue-api needs es6-promise
  es6Promise = require 'es6-promise'
  hue = require 'node-hue-api'

  class HueZLLPlugin extends env.plugins.Plugin

    init: (app, @framework, @config) =>
      @hueApi = new hue.HueApi(
        @config.host,
        @config.username
      )

      @hueApi.version (err, version) =>
        env.logger.info("Connected to bridge #{version['name']}, " +
          "API version #{version['version']['api']}, software #{version['version']['software']}")
      @hueApi.lights (err, lights) => env.logger.debug(lights)
      @hueApi.groups (err, groups) => env.logger.debug(groups)

      deviceConfigDef = require("./device-config-schema")

      deviceClasses = [
        HueZLLOnOffLight,
        HueZLLOnOffLightGroup,
        HueZLLDimmableLight,
        HueZLLDimmableLightGroup,
        HueZLLColorTempLight,
        HueZLLColorTempLightGroup
      ]
      for DeviceClass in deviceClasses
        do (DeviceClass) =>
          @framework.deviceManager.registerDeviceClass(DeviceClass.name, {
            configDef: deviceConfigDef[DeviceClass.name],
            createCallback: (deviceConfig) => new DeviceClass(deviceConfig, @hueApi, @config)
          })

  class BaseHueLight

    constructor: (@device, @hueApi, @hueId) ->
      @lightState = hue.lightState.create()

    poll: -> @hueApi.lightStatus(@hueId).then(@_stateReceived)

    _stateReceived: (result) =>
      newLightState = hue.lightState.create(result.state)
      env.logger.debug("light #{@hueId} old state: #{JSON.stringify(@lightState._values)}   " +
        "new state: #{JSON.stringify(newLightState._values)}")
      @lightState = newLightState
      return result.state

    setLightState: (hueState) ->
      @hueApi.setLightState(@hueId, hueState).then( ( => @lightState = hueState) )

  class BaseHueLightGroup extends BaseHueLight

    poll: -> @hueApi.getGroup(@hueId).then(@_stateReceived)

    _stateReceived: (result) =>
      newGroupState = hue.lightState.create(result.lastAction)
      env.logger.debug("group #{@hueId} old state: #{JSON.stringify(@lightState._values)}   " +
        "new state: #{JSON.stringify(newGroupState._values)}")
      @lightState = newGroupState
      return result.lastAction

    setLightState: (hueState) ->
      @hueApi.setGroupLightState(@hueId, hueState).then( ( => @lightState = hueState) )

  class HueZLLOnOffLight extends env.devices.SwitchActuator
    HueClass: BaseHueLight
    isGroup: false

    constructor: (@config, @hueApi, @_pluginConfig) ->
      @id = @config.id
      @name = @config.name
      super()

      @hue = new @HueClass(this, hueApi, @config.hueId)
      @lightStateInitialized = @poll()
      setInterval(( => @poll() ), @_pluginConfig.polling)

    # Wait on first poll on initialization
    getState: -> Promise.join @lightStateInitialized, super()

    poll: -> @hue.poll().then(@_lightStateReceived)

    _lightStateReceived: (rstate) => @_setState rstate.on

    changeStateTo: (state) ->
      hueState = hue.lightState.create().on(state)
      return @hue.setLightState(hueState).then( ( => @_setState state) )

  class HueZLLOnOffLightGroup extends HueZLLOnOffLight
    HueClass: BaseHueLightGroup
    isGroup: true

  class HueZLLDimmableLight extends env.devices.DimmerActuator
    HueClass: BaseHueLight
    isGroup: false

    constructor: (@config, hueApi, @_pluginConfig) ->
      @id = @config.id
      @name = @config.name
      super()

      @hue = new @HueClass(this, hueApi, @config.hueId)
      @lightStateInitialized = @poll()
      setInterval(( => @poll() ), @_pluginConfig.polling)

    # Wait on first poll on initialization
    getState: -> Promise.join @lightStateInitialized, super()
    getDimlevel: -> Promise.join @lightStateInitialized, super()

    poll: -> @hue.poll().then(@_lightStateReceived)

    _lightStateReceived: (rstate) => @_setDimlevel rstate.bri / 254 * 100

    changeStateTo: (state) ->
      hueState = hue.lightState.create().on(state)
      return @hue.setLightState(hueState).then( ( => @_setState state) )

    changeDimlevelTo: (state) ->
      hueState = hue.lightState.create().on(state != 0).bri(state / 100 * 254)
      return @hue.setLightState(hueState).then( ( => @_setDimlevel state) )

  class HueZLLDimmableLightGroup extends HueZLLDimmableLight
    HueClass: BaseHueLightGroup
    isGroup: true

  class HueZLLColorTempLight extends HueZLLDimmableLight
    HueClass: BaseHueLight
    isGroup: false

    _ct: null

    attributes:
      state:
        description: "The current state of the switch"
        type: t.boolean
        labels: ['on', 'off']
      dimlevel:
        description: "The current dim level"
        type: t.number
        unit: "%"
      ct:
        description: "the color temperature"
        type: t.number

    actions:
      changeStateTo:
        description: "Changes the switch to on or off"
        params:
          state:
            type: t.boolean
      turnOn:
        description: "Turns the dim level to 100%"
      turnOff:
        description: "Turns the dim level to 0%"
      changeDimlevelTo:
        description: "Sets the level of the dimmer"
        params:
          dimlevel:
            type: t.number
      changeCtTo:
        description: "changes the color temperature"
        params:
          ct:
            type: t.number

    _lightStateReceived: (rstate) =>
      @_setDimlevel rstate.bri / 254 * 100
      @_setCt rstate.ct

    changeCtTo: (ct) ->
      hueState = hue.lightState.create().ct(ct)
      return @hue.setLightState(hueState).then( ( => @_setCt ct) )

    _setCt: (ct) ->
      ct = parseFloat(ct)
      assert not isNaN(ct)
      assert 153 <= ct <= 500
      unless @_ct is ct
        @_ct = ct
        @emit "ct", ct

    getCt: -> Promise.join @lightStateInitialized, Promise.resolve( @_ct )

  class HueZLLColorTempLightGroup extends HueZLLColorTempLight
    HueClass: BaseHueLightGroup
    isGroup: true

  return new HueZLLPlugin()