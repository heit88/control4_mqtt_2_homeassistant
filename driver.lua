-- Control4 to Home Assistant MQTT Bridge
-- Author: John Heit
-- Copyright 2025 Heit Automation
-- Licensed under the MIT License, see the LICENSE file
-- Version 4.11 - Native C4 Network Stack (Event-Driven), Light V2 color lights, all outlet driver generations,
-- bridge availability (MQTT Will), automatic discovery on Home Assistant restart, devices deleted from the
-- project removed from Home Assistant, Gen3 auto off and power / energy sensors

-- Constants
local DRIVER_VERSION = "4.11"  -- keep in step with <version> in driver.xml
local MQTT_BINDING_ID = 6001  -- Network binding ID for MQTT broker connection

-- Bridge availability: the broker publishes "offline" here (the MQTT Will) when the connection to the
-- controller is lost; the driver publishes "online" when it connects. Every entity depends on it.
local BRIDGE_STATUS_TOPIC = "control4/bridge/status"
-- Home Assistant's birth message: "online" when Home Assistant (re)starts, so discovery is sent again
local HA_STATUS_TOPIC = "homeassistant/status"
-- Command topics: every /set topic the driver's entities use has one of these two shapes
--   homeassistant/<component>/<object>/set        light, switch, outlet, media_player, number, thermostat LED text
--   homeassistant/<component>/<object>/<x>/set    climate (mode, temperature, ...), LED text (top_on, ...)
local COMMAND_TOPIC_FILTERS = {"homeassistant/+/+/set", "homeassistant/+/+/+/set"}
local MQTT_KEEPALIVE_SECONDS = 60  -- keep alive in CONNECT; no packet from the broker for 1.5x this = dead
local VARIABLE_IDS = {
    LIGHT_LEVEL = 1001,
    SWITCH_STATE = 1000,

    -- LED Color Variables (for switches/dimmers with light.c4i)
    TOP_BUTTON_ON_COLOR = 1050,
    TOP_BUTTON_OFF_COLOR = 1051,
    BOTTOM_BUTTON_ON_COLOR = 1052,
    BOTTOM_BUTTON_OFF_COLOR = 1053,

    -- Advanced Dimmer Control Variables (proxy variables)
    CLICK_RAMP_RATE_UP = 1002,      -- Ramp rate when turning on (ms, 0-5000)
    CLICK_RAMP_RATE_DOWN = 1003,    -- Ramp rate when turning off (ms, 0-5000)
    PRESET_LEVEL = 1004,            -- Preset level (%, 0-100)
    MAX_ON_LEVEL = 1005,            -- Maximum on level (%, 0-100)
    MIN_ON_LEVEL = 1006,            -- Minimum on level (%, 0-100)

    -- Light V2 (light_v2.c4i) proxy variables: level and state match V1 above. Of the dimmer
    -- settings only the Default On preset is a variable (when the driver supports Default On);
    -- the others are read from the proxy (RefreshLightV2Settings)
    V2_PRESET_LEVEL = 1006,         -- Default On preset brightness (%)
    CURRENT_CHROMATICITY = 1200,    -- Current color "x,y,mode" (mode 1 = color temperature, 0 = full color)
    CURRENT_COLOR_MODE = 1201,      -- Current color mode (1 = color temperature, 0 = full color)
    CURRENT_CCT = 1202,             -- Current color temperature (K)
    DYNAMIC_CAPABILITIES = 6661,    -- Capabilities XML (color support, color temperature range)

    -- Thermostat V2 Variables
    HVAC_MODE = 1104,          -- Off/Heat/Cool/Auto
    FAN_MODE = 1105,           -- On/Auto/Circulate
    HVAC_STATE = 1107,         -- Current operating state
    TEMPERATURE_F = 1130,      -- Current temperature
    HEAT_SETPOINT_F = 1132,    -- Heat setpoint
    COOL_SETPOINT_F = 1134,    -- Cool setpoint
    HUMIDITY = 1138,           -- Relative humidity (%)
    HVAC_MODES_LIST = 1120,    -- Available modes
    FAN_MODES_LIST = 1121,     -- Available fan modes
    THERMOSTAT_BUTTON_LED_COLOR = 1001,  -- Button LED Color (RGB format: "255,0,0")

    -- Media Room Variables (Room-level control) - EXPERIMENTAL feature
    ROOM_POWER_STATE = 1010,              -- Room power state (0=off, 1=on)
    ROOM_CURRENT_VOLUME = 1011,           -- Current volume (0-100)
    ROOM_IS_MUTED = 1018,                 -- Mute state (0=unmuted, 1=muted)

    -- Contact Sensor Variables (WCS10A Wireless Contact Sensor)
    CONTACT_BATTERY_LEVEL = 1010,         -- Battery level (0-100%)
    CONTACT_BATTERY_VOLTAGE = 1011,       -- Battery voltage (mV)
    CONTACT_TEMPERATURE = 1003,           -- Temperature (°F)
    CONTACT_LOCAL_TEMP = 1012,            -- Local temperature sensor (°F)
    CONTACT_REMOTE_TEMP = 1013,           -- Remote temperature sensor (°F)
}

-- Thermostat Mode Mapping Tables
local HVAC_MODE_HA_TO_C4 = {
    ["off"] = "Off",
    ["heat"] = "Heat",
    ["cool"] = "Cool",
    ["heat_cool"] = "Auto"
}
-- 
local HVAC_MODE_C4_TO_HA = {
    ["Off"] = "off",
    ["Heat"] = "heat",
    ["Cool"] = "cool",
    ["Auto"] = "heat_cool"
}

local FAN_MODE_HA_TO_C4 = {
    ["auto"] = "Auto",
    ["on"] = "On",
    ["circulate"] = "Circulate"
}

local FAN_MODE_C4_TO_HA = {
    ["Auto"] = "auto",
    ["On"] = "on",
    ["Circulate"] = "circulate"
}

local MQTT_TYPES = {
    CONNECT = 1,
    CONNACK = 2,
    PUBLISH = 3,
    PUBACK = 4,
    SUBSCRIBE = 8,
    SUBACK = 9,
    PINGREQ = 12,
    PINGRESP = 13
}

-- Room Event IDs for Device Event Registration
-- These events allow tracking of playback state and transport control
local ROOM_EVENTS = {
    PLAY = 2054,
    PAUSE = 2051,
    STOP = 2052,
    SKIP_FWD = 2044,
    SKIP_REV = 2043,
    SCAN_FWD = 2048,
    START_SCAN_FWD = 2049,
    STOP_SCAN_FWD = 2050,
    SCAN_REV = 2045,
    START_SCAN_REV = 2046,
    STOP_SCAN_REV = 2047
}

local TIMER_INTERVALS = {
    KEEPALIVE = 15000,
    WATCHDOG = 60000,
    SUBSCRIPTION_DELAY = 50,   -- Reduced from 200ms for faster subscription completion
    DISCOVERY_DELAY = 500,
    AUTO_CONNECT_DELAY = 500,  -- Reduced from 3000ms for faster command response
    RECONNECT_DELAY = 2000,
    LIGHT_V2_CONFIRM = 3000,   -- after a Light V2 setting or LED change, read the light's settings back
    KEEPALIVE_TICK = 15000,    -- how often the connection's liveness is checked
    PINGREQ_INTERVAL = 45,     -- seconds between PINGREQs
    RECONNECT_MIN = 2000,      -- reconnect backoff after a lost connection: 2 s, doubling to 60 s
    RECONNECT_MAX = 60000,
    STATS_PROPERTY_INTERVAL = 10, -- seconds between updates of the Messages Sent / Received properties
    SETTINGS_CHANGED_RESCAN = 45000, -- after start-up, look again for SETTINGS_CHANGED on light drivers that create it late
    DELETED_MISS_SPACING = 60  -- a light is only taken as deleted after 3 misses at least this many seconds apart
}

local LIMITS = {
    MAX_BUFFER_SIZE = 10240, -- 10KB max buffer
    MAX_PACKET_SIZE = 8192,  -- 8KB max single packet
    MAX_MONITORED_LIGHTS = 200
}

-- Default broker IP in driver.xml: not a real address, it means the broker isn't configured yet
local BROKER_IP_PLACEHOLDER = "192.168.1.xxx"

-- Device Type Configuration Registry
-- Centralizes configuration for all monitored device types
local DEVICE_TYPES = {
    LIGHT = {
        name = "Light",
        plural = "Lights",
        storage_key = "MonitoredLights",
        property_name = "Monitored Lights",
        proxy_names = {"light_v2.c4i", "dimmer_v2.c4i", "light.c4i"},
        variable_ids = {VARIABLE_IDS.LIGHT_LEVEL, VARIABLE_IDS.SWITCH_STATE}
    },
    SWITCH = {
        name = "Switch",
        plural = "Switches",
        storage_key = "MonitoredSwitches",
        property_name = "Monitored Switches",
        proxy_names = {"light_v2.c4i", "dimmer_v2.c4i", "light.c4i"},
        variable_ids = {VARIABLE_IDS.SWITCH_STATE}  -- Switches are simple on/off, no dimming
    },
    THERMOSTAT = {
        name = "Thermostat",
        plural = "Thermostats",
        storage_key = "MonitoredThermostats",
        property_name = "Monitored Thermostats",
        proxy_names = {"thermostatV2.c4i"},
        variable_ids = {
            VARIABLE_IDS.TEMPERATURE_F,
            VARIABLE_IDS.HEAT_SETPOINT_F,
            VARIABLE_IDS.COOL_SETPOINT_F,
            VARIABLE_IDS.HVAC_MODE,
            VARIABLE_IDS.FAN_MODE,
            VARIABLE_IDS.HVAC_STATE,
            VARIABLE_IDS.HUMIDITY,
            VARIABLE_IDS.THERMOSTAT_BUTTON_LED_COLOR
        }
    },
    MEDIA_ROOM = {
        name = "Media Room",
        plural = "Media Rooms",
        storage_key = "MonitoredMediaRooms",
        property_name = "Monitored Media Rooms",
        variable_ids = {
            VARIABLE_IDS.ROOM_POWER_STATE,
            VARIABLE_IDS.ROOM_CURRENT_VOLUME,
            VARIABLE_IDS.ROOM_IS_MUTED
        }
    },
    OUTLET = {
        name = "Outlet",
        plural = "Outlets",
        storage_key = "MonitoredOutlets",
        property_name = "Monitored Outlets",
        -- Outlets are found by driver file, not by proxy: see OUTLET_DRIVER_FILES / FindOutletProxies
        proxy_names = {},
        variable_ids = {VARIABLE_IDS.SWITCH_STATE}  -- Outlets are simple on/off switches
    },
    CONTACT_SENSOR = {
        name = "Contact Sensor",
        plural = "Contact Sensors",
        storage_key = "MonitoredContactSensors",
        property_name = "Monitored Contact Sensors",
        proxy_names = {"control4_wirelesscontact.c4i"},
        variable_ids = {
            VARIABLE_IDS.CONTACT_BATTERY_LEVEL,
            VARIABLE_IDS.CONTACT_BATTERY_VOLTAGE,
            VARIABLE_IDS.CONTACT_TEMPERATURE,
            VARIABLE_IDS.CONTACT_LOCAL_TEMP,
            VARIABLE_IDS.CONTACT_REMOTE_TEMP
        }
    }
}

-- Driver files whose loads are outlets, across the outlet driver generations:
--   outlet_light.c4i                 light of the original Wireless Outlet Switch (its own proxy)
--   outlet_nondimmable_light.c4i     light of the stock Wireless Outlet Switch V2 (a Light V2 proxy)
--   outlet_switch_loz5s1_lua.c4z     community Lua driver: one device with two Light V2 proxies
-- Dimmable outlet lights (outlet_dimmable_light.c4i) are left to the Lights list.
local OUTLET_DRIVER_FILES = {
    "outlet_light.c4i",
    "outlet_nondimmable_light.c4i",
    "outlet_switch_loz5s1_lua.c4z"
}
-- driverFileName patterns that are outlets too (other builds / renamed copies of the community driver)
local OUTLET_DRIVER_PATTERNS = {
    "^outlet_switch_loz5s1"
}

-- Global Variables
local gConnected = false
local gMQTTConnected = false
local gManualDisconnect = false -- True after the Disconnect action: no reconnecting until the Connect action
local gPacketID = 1
local gKeepAliveTimer = nil
local gWatchdogTimer = nil
local gDebugModeTimer = nil -- Auto-timeout timer for debug mode
local gMonitoredLights = {}
local gMonitoredSwitches = {} -- Array of switch device IDs
local gSwitchIDsSet = {} -- Hash set for O(1) switch ID lookups during filtering
local gMonitoredOutlets = {} -- Array of outlet device IDs
local gMonitoredThermostats = {} -- Array of thermostat device IDs
local gMonitoredMediaRooms = {} -- Array of media room IDs
local gMediaRoomDebounceTimers = {} -- Debounce timers for media room state updates
local gMediaRoomPlaybackState = {} -- Track playback state for each room (playing/paused/stopped/idle)
local gContactSensorStates = {} -- Cache contact sensor states: [bindingID] = {deviceID, deviceName, state, timestamp}
local gContactSensorBindings = {} -- Map binding ID to device: [bindingID] = {deviceID, customName}
local gMonitoredContactSensors = {} -- Array of unique contact sensor device IDs
local gContactSensorDevices = {} -- Map device ID to its bindings/contacts: [deviceID] = {bindings = {[bindingID] = customName}, ...}
local gMQTTBuffer = "" -- Buffer for partial MQTT packets
local gActiveTimers = {} -- One-shot timers that haven't fired yet, for cleanup: [timer] = true
local gHoldRampRates = {} -- Track hold ramp rates for dimmers: [deviceID] = {up = ms, down = ms}
local gLightV2Proxies = nil -- Light V2 proxy IDs in the project: [proxyID] = true (built on first use)
local gOutletProxies = nil -- Outlet proxy IDs in the project: [proxyID] = true (built on first use)
local gConnIP, gConnPort = nil, nil -- Broker address of the current connection (properties may change under it)
local gConnecting = false -- A TCP connect is under way (ConnectToBroker called, no ONLINE/OFFLINE yet)
local gConnectStarted = 0
local gReconnectTimer = nil -- The one pending reconnect (single in flight)
local gReconnectAttempts = 0 -- For the backoff; reset by a CONNACK
local gLastInbound = 0 -- os.time() of the last packet from the broker
local gLastPingSent = 0
local gLastPublished = {} -- Last payload published per topic (this connection): unchanged state isn't sent again
local gSkipUnchanged = false -- Set while a state change is published: PublishMQTT skips unchanged payloads
local gDiscoveryInProgress = false -- A paced discovery run is going
local gDiscoveryRerun = false -- Home Assistant restarted during it: run once more when it ends
local gRetainedSetLogged = {} -- Retained /set topics already logged (logged once each)
local gLightMisses = {} -- Lights whose name couldn't be read: [deviceID] = {count = n, last = os.time()}
local gLightColorCapsSig = {} -- Color capabilities last published in a light's discovery: [deviceID] = "sig"
local gStatsTimer = nil
local gLastStatsUpdate = 0
local gRescanTimer = nil
local gDeviceLookup = nil -- Monitored device sets and proxy -> device maps (see GetDeviceLookup)
local gStats = {
    messagesReceived = 0,
    messagesSent = 0,
    errors = 0,
    reconnects = 0,
    lastError = "None"
}

-- Logging Functions
function Log(msg)
    local mode = Properties["Debug Mode"] or "Off"
    if mode == "Print" or mode == "Print and Log" then
        print(msg)
    end
    if mode == "Log" or mode == "Print and Log" then
        C4:DebugLog(msg)
    end
end

-- Check if logging is enabled (for performance-critical paths)
function IsLoggingEnabled()
    local mode = Properties["Debug Mode"] or "Off"
    return mode ~= "Off"
end

function LogError(msg)
    Log("[ERROR] " .. msg)
    C4:ErrorLog(msg)
    gStats.errors = gStats.errors + 1
    gStats.lastError = msg
    C4:UpdateProperty("Last Error", msg)
end

-- Timer Management Functions
function TrackTimer(timer)
    if timer then
        gActiveTimers[timer] = true
    end
    return timer
end

function SafeSetTimer(delay, callback, repeating)
    -- If repeating is nil, it defaults to non-repeating
    local shouldRepeat = (repeating == true)
    local timer
    local wrappedCallback = function(firedTimer)
        -- A one-shot timer is finished once it fires, so stop tracking it
        if not shouldRepeat and timer then
            gActiveTimers[timer] = nil
        end
        local success, err = pcall(callback, firedTimer)
        if not success then
            LogError("Timer callback error: " .. tostring(err))
        end
    end
    -- C4:SetTimer expects (delay, callback, repeat_boolean)
    timer = C4:SetTimer(delay, wrappedCallback, shouldRepeat)
    if not shouldRepeat then
        TrackTimer(timer)
    end
    return timer
end

-- Cancel a timer object from C4:SetTimer / SafeSetTimer (nil is fine)
function CancelTimerObject(timer)
    if type(timer) == "table" or type(timer) == "userdata" then
        pcall(function() timer:Cancel() end)
        gActiveTimers[timer] = nil
    end
end

-- A timer that isn't cancelled with the connection's timers, with its callback protected
function SetUntrackedTimer(delay, callback)
    return C4:SetTimer(delay, function(firedTimer)
        local ok, err = pcall(callback, firedTimer)
        if not ok then
            LogError("Timer callback error: " .. tostring(err))
        end
    end, false)
end

-- Initialization
function OnDriverInit()
    Log("========================================")
    Log("Control4 to Home Assistant MQTT Bridge")
    Log("Author: John Heit - Version " .. DRIVER_VERSION)
    Log("Bidirectional Control + Auto-Discovery")
    Log("Contact Sensor Support (Auto-Detection)")
    Log("========================================")
    C4:UpdateProperty("Connection Status", "Initialized")
    C4:UpdateProperty("Last Error", "None")
    gConnected = false
    gMQTTConnected = false
    gMonitoredLights = {}
    gMonitoredSwitches = {}
    gMonitoredOutlets = {}
    gMonitoredThermostats = {}
    gMonitoredMediaRooms = {}
    gMediaRoomPlaybackState = {}
    gContactSensorBindings = {}
    gMonitoredContactSensors = {}
    gContactSensorDevices = {}
    gContactSensorStates = {}
    gMQTTBuffer = ""
    gActiveTimers = {}
    gStats = {
        messagesReceived = 0,
        messagesSent = 0,
        errors = 0,
        reconnects = 0,
        lastError = "None"
    }
    LoadMonitoredLights()
    LoadMonitoredSwitches()
    LoadMonitoredOutlets()
    LoadMonitoredThermostats()
    LoadMonitoredMediaRooms()
    LoadMonitoredContactSensors()
    LoadSwitchIDsFromProperty()
    LoadMediaRoomIDsFromProperty()
    LoadContactSensorBindingMap()
end

function OnDriverLateInit()
    Log("Driver ready - Bidirectional mode enabled")
    UpdateLightCount()
    UpdateSwitchCount()
    UpdateOutletCount()
    UpdateThermostatCount()
    UpdateMediaRoomCount()

    RefreshLightV2Proxies()
    for _, lightID in ipairs(gMonitoredLights) do
        SubscribeToLight(lightID)
    end

    for _, switchID in ipairs(gMonitoredSwitches) do
        SubscribeToSwitch(switchID)
    end

    for _, outletID in ipairs(gMonitoredOutlets) do
        SubscribeToOutlet(outletID)
    end

    for _, thermostatID in ipairs(gMonitoredThermostats) do
        SubscribeToThermostat(thermostatID)
    end

    for _, roomID in ipairs(gMonitoredMediaRooms) do
        SubscribeToMediaRoom(roomID)
    end

    -- Subscribe to variables for all contact sensors
    for _, deviceID in ipairs(gMonitoredContactSensors) do
        SubscribeToContactSensor(deviceID)
    end

    if #gMonitoredLights == 0 then
        Log("No lights monitored - use 'Auto-Discover All Devices' action")
    end

    if #gMonitoredSwitches == 0 then
        Log("No switches monitored - use 'Auto-Discover All Devices' action")
    end

    if #gMonitoredThermostats == 0 then
        Log("No thermostats monitored - use 'Add Thermostat to Monitor' command")
    end

    if #gMonitoredMediaRooms == 0 then
        Log("No media rooms monitored - use 'Add Media Room to Monitor' command")
    end

    -- Auto-connect to MQTT broker if configured
    if IsBrokerConfigured() then
        Log("Auto-connecting to MQTT broker on startup...")
        SafeSetTimer(TIMER_INTERVALS.AUTO_CONNECT_DELAY, function()
            ConnectToBroker()
        end)
    else
        Log("MQTT not configured - waiting for manual connection")
    end

    -- Start connection watchdog
    StartConnectionWatchdog()

    -- Remove a monitored device from Home Assistant when it is deleted from the project
    RememberTrackedNames()
    local ok, err = pcall(RegisterProjectEvents)
    if not ok then
        LogError("Registering system events failed: " .. tostring(err))
    end

    -- A light driver may create its SETTINGS_CHANGED variable after this driver started (drivers
    -- start in any order): look again once everything is up. Not a connection timer, so a
    -- disconnect doesn't cancel it.
    if gRescanTimer then
        pcall(function() gRescanTimer:Cancel() end)
    end
    gRescanTimer = C4:SetTimer(TIMER_INTERVALS.SETTINGS_CHANGED_RESCAN, function()
        gRescanTimer = nil
        local ok, err = pcall(function()
            -- Its power / energy variables likewise: sensors found only now are published
            local function rescan(deviceID)
                ResolveSettingsChangedVariable(deviceID)
                local had = gEnergyVars[tonumber(deviceID)] ~= nil
                ResolveEnergyVariables(deviceID)
                if not had and gEnergyVars[tonumber(deviceID)] and gMQTTConnected then
                    PublishEnergyDiscovery(deviceID)
                end
            end
            for _, lightID in ipairs(gMonitoredLights) do
                rescan(lightID)
            end
            for _, switchID in ipairs(gMonitoredSwitches) do
                rescan(switchID)
            end
        end)
        if not ok then
            LogError("SETTINGS_CHANGED rescan failed: " .. tostring(err))
        end
    end, false)
end

-- Load Contact Sensor Binding Map from driver property
function LoadContactSensorBindingMap()
    local bindingMapStr = Properties["Contact Sensor Binding Map"] or ""

    if bindingMapStr == "" then
        Log("No contact sensor binding map configured")
        -- Clear existing data
        gMonitoredContactSensors = {}
        gContactSensorBindings = {}
        gContactSensorDevices = {}
        UpdateContactSensorCount()
        return
    end

    Log("========================================")
    Log("Loading Contact Sensor Binding Map...")
    Log("========================================")

    -- Clear existing data
    gMonitoredContactSensors = {}
    gContactSensorBindings = {}
    gContactSensorDevices = {}

    local bindingsRegistered = 0
    local devicesAdded = {}  -- Track unique devices

    -- Parse format: deviceID:binding:name,deviceID:binding:name
    for entry in string.gmatch(bindingMapStr, "([^,]+)") do
        local trimmedEntry = string.match(entry, "^%s*(.-)%s*$")  -- Trim whitespace
        local deviceID, bindingID, customName = string.match(trimmedEntry, "^(%d+):(%d+):(.+)$")

        if deviceID and bindingID and customName then
            deviceID = tonumber(deviceID)
            bindingID = tonumber(bindingID)
            customName = string.match(customName, "^%s*(.-)%s*$")  -- Trim name

            if bindingID >= 300 and bindingID <= 319 then
                -- Register the binding with custom name
                gContactSensorBindings[bindingID] = {
                    deviceID = deviceID,
                    customName = customName
                }

                -- Update device info
                local deviceInfo = gContactSensorDevices[deviceID]
                if not deviceInfo then
                    deviceInfo = {
                        name = C4:GetDeviceDisplayName(deviceID) or "Contact Sensor " .. deviceID,
                        bindings = {}
                    }
                    gContactSensorDevices[deviceID] = deviceInfo
                end
                deviceInfo.bindings[bindingID] = customName

                -- Add device to monitored list (only once per device)
                if not devicesAdded[deviceID] then
                    table.insert(gMonitoredContactSensors, deviceID)
                    devicesAdded[deviceID] = true
                end

                Log(string.format("✓ Registered: Binding %d → Device %d (%s)", bindingID, deviceID, customName))
                bindingsRegistered = bindingsRegistered + 1
            else
                Log(string.format("WARNING: Invalid binding ID %d (must be 300-319)", bindingID))
            end
        else
            Log("WARNING: Invalid binding map entry: '" .. trimmedEntry .. "' (expected format: deviceID:binding:name)")
        end
    end

    -- Subscribe to variables for all monitored devices (battery, temperature)
    for _, deviceID in ipairs(gMonitoredContactSensors) do
        SubscribeToContactSensor(deviceID)
    end

    Log("========================================")
    Log(string.format("Loaded %d binding(s) from %d device(s)", bindingsRegistered, #gMonitoredContactSensors))
    Log("========================================")

    -- Save and update count
    SaveMonitoredContactSensors()
    UpdateContactSensorCount()
end

-- Subscribe to contact sensor variables for battery and temperature
function SubscribeToContactSensor(deviceID)
    local config = DEVICE_TYPES.CONTACT_SENSOR
    if not config then return end

    Log("Subscribing to contact sensor variables for device " .. deviceID)

    for _, varID in ipairs(config.variable_ids) do
        C4:RegisterVariableListener(deviceID, varID)
    end
end

-- Load/Save/Update Contact Sensors
function LoadMonitoredContactSensors()
    LoadMonitoredDevices("CONTACT_SENSOR")
end

function SaveMonitoredContactSensors()
    SaveMonitoredDevices("CONTACT_SENSOR")
end

function UpdateContactSensorCount()
    local count = #gMonitoredContactSensors
    C4:UpdateProperty("Monitored Contact Sensors", tostring(count))
    Log("Contact Sensors monitored: " .. count)
end

-- Helper: Get custom name and naming suffix for a contact sensor device
-- Returns: customName, nameSuffix, deviceName (or nil if not found)
function GetContactSensorNaming(deviceID)
    local deviceInfo = gContactSensorDevices[deviceID]
    if not deviceInfo then
        return nil, nil, nil
    end

    -- The device, and its battery and temperature entities, take the name of its lowest binding
    local firstBinding = nil
    for bindingID in pairs(deviceInfo.bindings) do
        if not firstBinding or bindingID < firstBinding then
            firstBinding = bindingID
        end
    end

    if not firstBinding then
        return nil, nil, nil
    end

    local customName = deviceInfo.bindings[firstBinding]
    local nameSuffix = GetContactNameSuffix(firstBinding, customName)
    local deviceName = customName .. " Contact Sensor" .. nameSuffix
    return customName, nameSuffix, deviceName
end

-- Helper: Suffix that keeps a contact's entities unique when several bindings share a name:
-- "" if the name is only used once, otherwise " 1", " 2"... in binding ID order
function GetContactNameSuffix(bindingID, customName)
    local sameName = {}
    for id, binding in pairs(gContactSensorBindings) do
        if binding.customName == customName then
            table.insert(sameName, id)
        end
    end
    if #sameName <= 1 then
        return ""
    end
    table.sort(sameName)
    for number, id in ipairs(sameName) do
        if id == bindingID then
            return " " .. number
        end
    end
    return ""
end

-- Helper: The open/closed entity of one contact: {name, id}, or nil if the binding isn't mapped
function GetContactStateEntity(bindingID)
    local binding = gContactSensorBindings[bindingID]
    if not binding then
        return nil
    end
    local nameSuffix = GetContactNameSuffix(bindingID, binding.customName)
    return BuildContactSensorEntityNames(binding.customName, nameSuffix).state
end

-- Helper: MQTT payload for a contact state. "None" makes Home Assistant show the sensor as unknown,
-- so a sensor is never reported as closed unless it really said so.
function ContactStatePayload(state)
    if state == "open" then
        return "ON"
    elseif state == "closed" then
        return "OFF"
    end
    return "None"
end

-- Helper: A contact sensor device's variable, or nil if the device doesn't have it (only some
-- sensors have a battery or temperature probe)
function ReadContactVariable(deviceID, varID)
    local value = C4:GetDeviceVariable(deviceID, varID)
    if value == nil or value == "" then
        return nil
    end
    return value
end

function ReadContactTemperature(deviceID)
    return ReadContactVariable(deviceID, VARIABLE_IDS.CONTACT_TEMPERATURE)
        or ReadContactVariable(deviceID, VARIABLE_IDS.CONTACT_LOCAL_TEMP)
        or ReadContactVariable(deviceID, VARIABLE_IDS.CONTACT_REMOTE_TEMP)
end

-- Helper: Build all entity names and IDs for a contact sensor
-- Returns: table with {state={name,id}, battery={name,id}, voltage={name,id}, temperature={name,id}}
function BuildContactSensorEntityNames(customName, nameSuffix)
    local result = {}

    result.state = {
        name = customName .. " Contact Sensor State" .. nameSuffix,
        id = SanitizeEntityName(customName .. " Contact Sensor State" .. nameSuffix)
    }

    result.battery = {
        name = customName .. " Contact Sensor Battery" .. nameSuffix,
        id = SanitizeEntityName(customName .. " Contact Sensor Battery" .. nameSuffix)
    }

    result.voltage = {
        name = customName .. " Contact Sensor Battery Voltage" .. nameSuffix,
        id = SanitizeEntityName(customName .. " Contact Sensor Battery Voltage" .. nameSuffix)
    }

    result.temperature = {
        name = customName .. " Contact Sensor Temperature" .. nameSuffix,
        id = SanitizeEntityName(customName .. " Contact Sensor Temperature" .. nameSuffix)
    }

    return result
end

-- Handle binding connections/disconnections for contact sensors
function OnBindingChanged(idBinding, strClass, bIsBound)
    -- Only process contact sensor bindings (300-319)
    if idBinding < 300 or idBinding > 319 then
        return
    end

    if strClass ~= "CONTACT_SENSOR" then
        return
    end

    if bIsBound then
        -- Binding was connected
        -- We need to determine which device and which contact input was bound
        -- Unfortunately, Control4 doesn't provide device info in OnBindingChanged
        -- We'll handle this in ReceivedFromProxy when first event arrives
        Log(string.format("Contact sensor binding %d connected - waiting for first event to identify device", idBinding))
    else
        -- Binding was disconnected
        local binding = gContactSensorBindings[idBinding]
        if binding then
            local deviceID = binding.deviceID
            local customName = binding.customName
            local deviceInfo = gContactSensorDevices[deviceID]

            Log(string.format("Contact sensor binding %d disconnected - Device %d (%s) %s",
                idBinding, deviceID, deviceInfo and deviceInfo.name or "Unknown", customName))

            -- Remove this binding from device's bindings list
            if deviceInfo and deviceInfo.bindings then
                deviceInfo.bindings[idBinding] = nil
            end

            -- Remove binding mapping
            gContactSensorBindings[idBinding] = nil

            -- Clear cached state
            gContactSensorStates[idBinding] = nil
        else
            Log(string.format("Contact sensor binding %d disconnected (was not registered)", idBinding))
        end
    end
end

-- Connection Watchdog
function StartConnectionWatchdog()
    -- Cancel existing watchdog if any
    if gWatchdogTimer then
        gWatchdogTimer:Cancel()
    end

    -- Use repeating timer to avoid creating multiple timers
    gWatchdogTimer = C4:SetTimer(TIMER_INTERVALS.WATCHDOG, function(timer)
        local autoReconnect = Properties["Auto Reconnect"] or "Enabled"

        if autoReconnect == "Enabled" and not gManualDisconnect then
            if not gMQTTConnected and gConnected then
                -- Connected to TCP but not MQTT - something is wrong
                LogError("Watchdog: MQTT disconnected, reconnecting...")
                DisconnectFromBroker()
                ScheduleReconnect()
            elseif not gConnected then
                -- Not connected at all: unless a reconnect is already pending or a connect is
                -- under way (one in flight at a time)
                if gReconnectTimer or (gConnecting and os.time() - gConnectStarted < 30) then
                    Log("Watchdog: reconnect already pending")
                elseif IsBrokerConfigured() then
                    Log("Watchdog: Not connected, attempting connection...")
                    gStats.reconnects = gStats.reconnects + 1
                    ConnectToBroker()
                end
            else
                Log("Watchdog: Connection healthy")
            end
        end
    end, true) -- true = repeating timer
end


function OnDriverDestroyed()
    Log("Driver shutting down...")
    Log("Statistics - Sent: " .. gStats.messagesSent .. ", Received: " .. gStats.messagesReceived .. ", Errors: " .. gStats.errors)

    -- Tell Home Assistant the bridge is going away (the broker would also send the Will once the
    -- connection closes, but this is immediate)
    if gMQTTConnected then
        PublishMQTT(BRIDGE_STATUS_TOPIC, "offline", 1, true)
    end

    -- Cancel all media room debounce timers
    for roomID, timer in pairs(gMediaRoomDebounceTimers) do
        CancelTimerObject(timer)
    end
    gMediaRoomDebounceTimers = {}

    -- Unregister all device events for media rooms
    for _, roomID in ipairs(gMonitoredMediaRooms) do
        Log("Unregistering device events for media room " .. roomID .. " on shutdown")
        for eventName, eventID in pairs(ROOM_EVENTS) do
            pcall(function() C4:UnregisterDeviceEvent(roomID, eventID) end)
        end
    end

    pcall(UnregisterProjectEvents)
    CancelTimerObject(gDeleteCheckTimer)
    CancelTimerObject(gDeleteConfirmTimer)

    CancelTimers()
    SaveMonitoredLights()
    SaveMonitoredThermostats()
    SaveMonitoredMediaRooms()
    DisconnectFromBroker()
end

function OnPropertyChanged(prop)
    Log("Property Changed: " .. prop)

    if prop == "Debug Mode" then
        local value = Properties["Debug Mode"] or "Off"

        -- Cancel any existing debug mode timer
        if gDebugModeTimer then
            gDebugModeTimer:Cancel()
            gDebugModeTimer = nil
        end

        -- If debug mode is enabled (not "Off"), set auto-timeout for 1 hour
        if value ~= "Off" then
            Log("Debug mode enabled - will auto-disable in 1 hour")
            gDebugModeTimer = C4:SetTimer(3600000, function(timer) -- 3600000ms = 1 hour
                C4:UpdateProperty("Debug Mode", "Off")
                OnPropertyChanged("Debug Mode")
                Log("Debug mode auto-disabled after timeout")
            end)
        end

    elseif prop == "MQTT Broker IP" or prop == "MQTT Broker Port" or
        prop == "MQTT Username" or prop == "MQTT Password" then
        -- Reconnect with the new settings (the old connection is closed on the address it was
        -- opened with), unless the Disconnect action was used
        if (gConnected or gConnecting or gReconnectTimer) and not gManualDisconnect then
            Log("Connection settings changed - reconnecting")
            DisconnectFromBroker()
            if IsBrokerConfigured() then
                gReconnectAttempts = 0
                ScheduleReconnect(true)
            end
        end
    elseif prop == "Switch Device IDs (comma separated)" then
        Log("Switch Device IDs property changed - reloading...")
        LoadSwitchIDsFromProperty()
        Log("Switch IDs reloaded. Run 'Auto-Discover All Devices' to apply changes.")
    elseif prop == "Media Room IDs (comma separated)" then
        Log("Media Room IDs property changed - reloading...")
        LoadMediaRoomIDsFromProperty()
        Log("Media room IDs reloaded. Subscribing to rooms and publishing discovery...")
        -- Subscribe to new rooms and publish their discovery
        for _, roomID in ipairs(gMonitoredMediaRooms) do
            SubscribeToMediaRoom(roomID)
            if gMQTTConnected then
                PublishMediaRoomState(roomID)
                PublishMediaRoomDiscovery(roomID)
            end
        end
    elseif prop == "Contact Sensor Binding Map" then
        Log("Contact Sensor Binding Map property changed - reloading bindings...")
        LoadContactSensorBindingMap()
        Log("Binding map reloaded. Bindings are now active.")
        -- Publish discovery for updated bindings
        for _, sensorID in ipairs(gMonitoredContactSensors) do
            if gMQTTConnected then
                PublishContactSensorDiscovery(sensorID)
            end
        end
    end
end

------------------------------------------------------------------------
-- HELPER FUNCTIONS
-- Generic utilities that work across all device types
------------------------------------------------------------------------

-- Get proxy ID from device ID using C4's official API
-- For lights/dimmers/fans, the proxy is the interface we use to read/write state variables
-- The device itself holds LED color variables and other hardware-specific data
-- A device can have several proxies, listed comma separated (a Gen3 keypad dimmer has a light
-- proxy and a keypad proxy): prefer the Light V2 proxy, then the first
function GetProxyID(deviceID)
    -- Outlets are stored by their own proxy ID (one device can carry two outlets)
    if IsOutletProxy(deviceID) then
        return tonumber(deviceID)
    end
    local firstProxyID
    for proxyStr in string.gmatch(tostring(C4:GetProxyDevicesById(deviceID) or ""), "%d+") do
        local proxyID = tonumber(proxyStr)
        if IsLightV2(proxyID) then
            return proxyID
        end
        firstProxyID = firstProxyID or proxyID
    end
    return firstProxyID or deviceID  -- Fallback to deviceID if no proxy found
end

-- Find the Light V2 (light_v2.c4i) proxies in the project: Gen3 dimmers and third-party lights
-- such as Hue. Refreshed whenever lights are loaded, added or discovered.
function RefreshLightV2Proxies()
    gLightV2Proxies = {}
    for proxyID in pairs(C4:GetDevicesByC4iName("light_v2.c4i") or {}) do
        gLightV2Proxies[tonumber(proxyID)] = true
    end
    InvalidateDeviceLookup()  -- proxy resolution can change with it
end

function IsLightV2(proxyID)
    if not gLightV2Proxies then
        RefreshLightV2Proxies()
    end
    return gLightV2Proxies[tonumber(proxyID)] == true
end

-- Find every outlet in the project, whichever outlet driver it uses. Returns the outlets' proxy IDs
-- in ascending order and rebuilds the lookup set.
-- Devices are matched by driver file in two ways, because C4:GetDevicesByC4iName does not return
-- devices of a .c4z driver on every controller: by that call, and by the driverFileName that
-- C4:GetDevices reports for each device. Of a matching device take its Light V2 proxies (not a
-- keypad proxy); without any, its other proxies, or the ID as it is (the original outlet light).
function FindOutletProxies()
    RefreshLightV2Proxies()
    local found = {}
    gOutletProxies = {}

    local function add(id)
        id = tonumber(id)
        if id and not gOutletProxies[id] then
            gOutletProxies[id] = true
            table.insert(found, id)
        end
    end

    -- id: a device or proxy of an outlet driver; knownProxies: proxy IDs already known for it
    local function consider(id, knownProxies)
        id = tonumber(id)
        if not id then
            return
        end
        if IsLightV2(id) then
            add(id)
            return
        end
        local proxies, seen = {}, {}
        local function addProxy(proxyID)
            proxyID = tonumber(proxyID)
            if proxyID and not seen[proxyID] then
                seen[proxyID] = true
                table.insert(proxies, proxyID)
            end
        end
        for _, proxyID in ipairs(knownProxies or {}) do
            addProxy(proxyID)
        end
        for proxyStr in string.gmatch(tostring(C4:GetProxyDevicesById(id) or ""), "%d+") do
            addProxy(proxyStr)
        end
        local lightProxies = 0
        for _, proxyID in ipairs(proxies) do
            if IsLightV2(proxyID) then
                add(proxyID)
                lightProxies = lightProxies + 1
            end
        end
        if lightProxies == 0 then
            if #proxies > 0 then
                for _, proxyID in ipairs(proxies) do
                    add(proxyID)
                end
            else
                add(id)
            end
        end
    end

    local wanted = {}
    for _, fileName in ipairs(OUTLET_DRIVER_FILES) do
        wanted[string.lower(fileName)] = true
        for key in pairs(C4:GetDevicesByC4iName(fileName) or {}) do
            consider(key)
        end
    end

    local function isOutletFile(fileName)
        fileName = string.lower(tostring(fileName))
        if wanted[fileName] then
            return true
        end
        for _, pattern in ipairs(OUTLET_DRIVER_PATTERNS) do
            if string.find(fileName, pattern) then
                return true
            end
        end
        return false
    end

    for deviceID, deviceInfo in pairs(C4:GetDevices() or {}) do
        local fileName = type(deviceInfo) == "table" and deviceInfo.driverFileName
        if fileName and isOutletFile(fileName) then
            local proxies = {}
            for proxyID in pairs(deviceInfo.proxies or {}) do
                table.insert(proxies, proxyID)
            end
            consider(deviceID, proxies)
        end
    end

    table.sort(found)
    InvalidateDeviceLookup()
    return found
end

function IsOutletProxy(proxyID)
    if not gOutletProxies then
        FindOutletProxies()
    end
    return gOutletProxies[tonumber(proxyID)] == true
end

-- Color abilities of a Light V2 light, from its proxy's dynamic capabilities:
-- {color = true/false, minK = , maxK = } (minK nil without color temperature), or nil for
-- V1 lights and lights without color
function GetLightColorCaps(proxyID)
    if not IsLightV2(proxyID) then
        return nil
    end
    local caps = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.DYNAMIC_CAPABILITIES) or ""
    local color = string.match(caps, "<supports_color>%s*[Tt]rue") ~= nil
    local colorTemp = string.match(caps, "<supports_color_correlated_temperature>%s*[Tt]rue") ~= nil
    if not color and not colorTemp then
        return nil
    end
    local result = {color = color}
    if colorTemp then
        result.minK = tonumber(string.match(caps, "<color_correlated_temperature_min>%s*(%d+)")) or 2000
        result.maxK = tonumber(string.match(caps, "<color_correlated_temperature_max>%s*(%d+)")) or 6500
    end
    return result
end

-- The color capabilities as a string, to tell when they change (what discovery depends on)
function ColorCapsSignature(proxyID)
    local caps = GetLightColorCaps(proxyID)
    if not caps then
        return "none"
    end
    return tostring(caps.color) .. ":" .. tostring(caps.minK) .. ":" .. tostring(caps.maxK)
end

-- Is a CIE xy color on the white (Planckian) curve, i.e. a color temperature?
local WHITE_CURVE_TOLERANCE = 0.005
function IsOnWhiteCurve(x, y)
    if not x or not C4.ColorXYtoCCT or not C4.ColorCCTtoXY then
        return false
    end
    local wx, wy = C4:ColorCCTtoXY(C4:ColorXYtoCCT(x, y))
    return math.sqrt((x - wx) ^ 2 + (y - wy) ^ 2) <= WHITE_CURVE_TOLERANCE
end

-- Light V2 current color variable "x,y,mode" as x, y, mode (numbers), or nil
function ParseChromaticity(value)
    local x, y, mode = string.match(value or "", "^%s*([%d%.]+)%s*,%s*([%d%.]+)%s*,?%s*(%d*)")
    if not x then
        return nil
    end
    return tonumber(x), tonumber(y), tonumber(mode)
end

-- Advanced dimmer controls: the V1 (light.c4i) proxy variable holding each, and for Light V2 lights
-- the tag in the proxy's GET_PROPERTIES / GET_SETUP answers and the proxy command that changes it.
-- A Light V2 proxy keeps these settings to itself: of them only the Default On preset (1006) is a
-- variable, so the rest are read with C4:SendUIRequest (confirmed on a Gen3 dimmer and a gen2 Lua
-- dimmer, 2026-11-17). Hold rates are shown in seconds. range: the GET_SETUP limits, in ms.
local DIMMER_CONTROL_VARS = {
    min_on_level = {v1 = VARIABLE_IDS.MIN_ON_LEVEL, tag = "MIN_ON_LEVEL", command = "SET_MIN_ON_LEVEL", param = "LEVEL", capability = "min_max"},
    max_on_level = {v1 = VARIABLE_IDS.MAX_ON_LEVEL, tag = "MAX_ON_LEVEL", command = "SET_MAX_ON_LEVEL", param = "LEVEL", capability = "min_max"},
    preset_level = {v1 = VARIABLE_IDS.PRESET_LEVEL, v2 = VARIABLE_IDS.V2_PRESET_LEVEL, tag = "PRESET_LEVEL", command = "SET_PRESET_LEVEL", param = "LEVEL", capability = "supports_default_on"},
    click_ramp_rate_up = {v1 = VARIABLE_IDS.CLICK_RAMP_RATE_UP, tag = "CLICK_RATE_UP", command = "SET_CLICK_RATE_UP", param = "RATE", range = "CLICK_RATE", capability = "click_rates"},
    click_ramp_rate_down = {v1 = VARIABLE_IDS.CLICK_RAMP_RATE_DOWN, tag = "CLICK_RATE_DOWN", command = "SET_CLICK_RATE_DOWN", param = "RATE", range = "CLICK_RATE", capability = "click_rates"},
    hold_ramp_rate_up = {tag = "HOLD_RATE_UP", command = "SET_HOLD_RATE_UP", param = "RATE", seconds = true, range = "HOLD_RATE", capability = "hold_rates"},
    hold_ramp_rate_down = {tag = "HOLD_RATE_DOWN", command = "SET_HOLD_RATE_DOWN", param = "RATE", seconds = true, range = "HOLD_RATE", capability = "hold_rates"},
    -- Gen3 auto off (seconds, 0 = off): only the light's device reports it (GET_PROPERTIES to the
    -- device, not the proxy); SET_AUTO_OFF works sent to either (confirmed on a Gen3 adaptive
    -- dimmer, 2026-11-19). Light V2 only.
    auto_off_time = {device_tag = "AUTO_OFF_TIME", command = "SET_AUTO_OFF", param = "TIME", integer = true, v2only = true}
}

-- Gen3 device settings shown read-only (no command found that changes them): suffix -> tag in the
-- device's GET_PROPERTIES. Published as binary sensors.
local DEVICE_FLAG_SETTINGS = {
    rocker_as_keypad = {tag = "ROCKER_AS_KEYPAD", name = "Rocker As Keypad", icon = "mdi:gesture-tap-button"}
}

-- Light V2 settings and button LED colors as the proxy last answered, by proxy ID:
-- { values = {suffix = "text"}, leds = {[buttonID] = {on = "rrggbb", off = "rrggbb"}}, setup = "<setup>..." }
gLightV2Settings = {}

-- While set, Light V2 settings come from gLightV2Settings only (no C4:SendUIRequest)
gSettingsCacheOnly = false
function RunWithCachedSettings(fn)
    local previous = gSettingsCacheOnly
    gSettingsCacheOnly = true
    local ok, err = pcall(fn)
    gSettingsCacheOnly = previous
    if not ok then
        LogError("Publish from cached settings failed: " .. tostring(err))
    end
end

local function xmlTag(xml, tag)
    return string.match(xml or "", "<" .. tag .. ">([^<]*)</" .. tag .. ">")
end

-- The proxy answers GET_PROPERTIES with every dimmer setting and three buttons whatever the light
-- supports (a Hue light too), so what the light has comes from the capabilities its driver declares
-- (GET_CAPABILITIES). Without an answer to that, everything reported is kept.
local function lightV2Has(caps, capability)
    if caps == "" then
        return true
    end
    return xmlTag(caps, capability) == "True"
end

-- Ask a Light V2 proxy for its settings and LED colors (GET_PROPERTIES), limits (GET_SETUP) and
-- capabilities (GET_CAPABILITIES), and keep the settings and LEDs the light has. Returns the
-- cached table, or nil if the proxy didn't answer.
function RefreshLightV2Settings(proxyID)
    proxyID = tonumber(proxyID)
    -- Automatic runs (connect, Home Assistant restart) never ask the proxy: SendUIRequest blocks,
    -- and a command from Home Assistant arriving meanwhile would wait. What is cached, or nil.
    if gSettingsCacheOnly then
        return gLightV2Settings[proxyID]
    end
    local ok, xml = pcall(C4.SendUIRequest, C4, proxyID, "GET_PROPERTIES", {})
    if not ok or type(xml) ~= "string" or xml == "" then
        Log("Light V2 proxy " .. tostring(proxyID) .. ": no answer to GET_PROPERTIES")
        gLightV2Settings[proxyID] = nil
        return nil
    end
    local okSetup, setup = pcall(C4.SendUIRequest, C4, proxyID, "GET_SETUP", {})
    local okCaps, caps = pcall(C4.SendUIRequest, C4, proxyID, "GET_CAPABILITIES", {})
    caps = (okCaps and type(caps) == "string") and caps or ""
    local settings = { values = {}, leds = {}, flags = {}, setup = (okSetup and type(setup) == "string") and setup or "" }
    -- A Gen3 light's device answers GET_PROPERTIES with settings its proxy doesn't have (auto off,
    -- rocker as keypad). Other light drivers answer nothing.
    local deviceID = GetDeviceLookup().lightProxy[proxyID]
    local deviceXml = ""
    if deviceID and deviceID ~= proxyID then
        local okDevice, answer = pcall(C4.SendUIRequest, C4, deviceID, "GET_PROPERTIES", {})
        deviceXml = (okDevice and type(answer) == "string") and answer or ""
    end
    for suffix, flag in pairs(DEVICE_FLAG_SETTINGS) do
        local value = xmlTag(deviceXml, flag.tag)
        if value and value ~= "" then
            settings.flags[suffix] = (value == "True" or value == "true" or value == "1")
        end
    end
    for suffix, control in pairs(DIMMER_CONTROL_VARS) do
        local value, has
        if control.device_tag then
            -- Reported by the device: it has the setting if the tag is there
            value, has = xmlTag(deviceXml, control.device_tag), true
        else
            value = xmlTag(xml, control.tag)
            -- The Default On preset also counts when the proxy has its variable: a Gen3 dimmer has
            -- 1006 without declaring supports_default_on
            has = lightV2Has(caps, control.capability) or
                (control.v2 ~= nil and C4:GetDeviceVariable(proxyID, control.v2) ~= nil)
        end
        if has and value and value ~= "" then
            settings.values[suffix] = value
        end
    end
    -- LEDs: a light with LEDs, or with buttons (the community Lua dimmer drives its LEDs itself and
    -- declares has_leds False, but has button events)
    local hasLeds = lightV2Has(caps, "has_leds") or lightV2Has(caps, "has_button_events")
    for info in string.gmatch(hasLeds and xml or "", "<BUTTON_INFO>(.-)</BUTTON_INFO>") do
        local id = tonumber(xmlTag(info, "BUTTON_ID"))
        if id then
            settings.leds[id] = { on = xmlTag(info, "ON_COLOR"), off = xmlTag(info, "OFF_COLOR") }
        end
    end
    gLightV2Settings[proxyID] = settings
    return settings
end

function GetLightV2Settings(proxyID)
    return gLightV2Settings[tonumber(proxyID)] or RefreshLightV2Settings(proxyID)
end

-- A light driver can announce changes to its settings, which its Light V2 proxy doesn't, with a
-- driver variable of this name that changes with each one (the Hue Light driver from v0.4.6).
-- Watched variable ID by device ID.
local SETTINGS_CHANGED_VAR = "SETTINGS_CHANGED"
gSettingsChangedVars = {}

function FindSettingsChangedVariable(deviceID)
    for varID, var in pairs(C4:GetDeviceVariables(deviceID) or {}) do
        if type(var) == "table" and var.name == SETTINGS_CHANGED_VAR then
            return tonumber(varID)
        end
    end
    return nil
end

-- Look up (by name) a light's SETTINGS_CHANGED variable again and watch it: at start-up, when the
-- light's capabilities change, and once a little after start-up (a light driver may add the
-- variable after this driver started, or a driver update may renumber it).
function ResolveSettingsChangedVariable(deviceID)
    deviceID = tonumber(deviceID)
    if not deviceID then
        return
    end
    local wanted = nil
    if IsLightV2(GetProxyID(deviceID)) and (IsLEDControlEnabled() or IsAdvancedDimmerControlEnabled()) then
        wanted = FindSettingsChangedVariable(deviceID)
    end
    local current = gSettingsChangedVars[deviceID]
    if current == wanted then
        return
    end
    if current then
        C4:UnregisterVariableListener(deviceID, current)
    end
    if wanted then
        C4:RegisterVariableListener(deviceID, wanted)
        Log("Watching SETTINGS_CHANGED (variable " .. wanted .. ") of light " .. deviceID)
    end
    gSettingsChangedVars[deviceID] = wanted
end

-- A Light V2 light's settings changed outside Home Assistant: read them again and publish them
function PublishLightV2SettingsChanged(deviceID)
    if not gMQTTConnected then
        return
    end
    RefreshLightV2Settings(GetProxyID(deviceID))
    PublishDimmerAdvancedControlStates(deviceID)
    PublishAllLEDStates(deviceID)
end

-- Allowed range of an advanced control as Home Assistant shows it (hold rates in seconds).
-- Light V2 lights give their own click and hold rate limits in GET_SETUP.
local DIMMER_CONTROL_DEFAULT_RANGES = {
    min_on_level = {0, 100}, max_on_level = {0, 100}, preset_level = {0, 100},
    click_ramp_rate_up = {0, 5000}, click_ramp_rate_down = {0, 5000},
    hold_ramp_rate_up = {0, 10}, hold_ramp_rate_down = {0, 10},
    auto_off_time = {0, 65535}  -- seconds (the dimmer's limit, 16 bits)
}
function GetDimmerControlRange(proxyID, suffix)
    local default = DIMMER_CONTROL_DEFAULT_RANGES[suffix] or {0, 100}
    local control = DIMMER_CONTROL_VARS[suffix]
    if not (control and control.range and IsLightV2(proxyID)) then
        return default[1], default[2]
    end
    local settings = GetLightV2Settings(proxyID)
    local setup = settings and settings.setup or ""
    local low, high = tonumber(xmlTag(setup, control.range .. "_MIN")), tonumber(xmlTag(setup, control.range .. "_MAX"))
    if not (low and high) then
        return default[1], default[2]
    end
    if control.seconds then
        return low / 1000, high / 1000
    end
    return low, high
end

-- Light proxy variables (V1 and Light V2): their changes arrive with the proxy ID
local LIGHT_PROXY_VARIABLES = {}
for _, varID in ipairs({VARIABLE_IDS.SWITCH_STATE, VARIABLE_IDS.LIGHT_LEVEL, VARIABLE_IDS.CLICK_RAMP_RATE_UP,
        VARIABLE_IDS.CLICK_RAMP_RATE_DOWN, VARIABLE_IDS.PRESET_LEVEL, VARIABLE_IDS.MAX_ON_LEVEL,
        VARIABLE_IDS.MIN_ON_LEVEL, VARIABLE_IDS.V2_PRESET_LEVEL, VARIABLE_IDS.CURRENT_CHROMATICITY, VARIABLE_IDS.CURRENT_COLOR_MODE, VARIABLE_IDS.CURRENT_CCT,
        VARIABLE_IDS.DYNAMIC_CAPABILITIES}) do
    LIGHT_PROXY_VARIABLES[varID] = true
end

-- Light V2 color variables watched on color lights
local LIGHT_V2_COLOR_VARIABLES = {
    VARIABLE_IDS.CURRENT_CHROMATICITY, VARIABLE_IDS.CURRENT_COLOR_MODE, VARIABLE_IDS.CURRENT_CCT,
    VARIABLE_IDS.DYNAMIC_CAPABILITIES
}

-- Proxy variable holding an advanced control's value on this light, or nil if it has none
function GetDimmerControlVariable(proxyID, suffix)
    local control = DIMMER_CONTROL_VARS[suffix]
    if not control then
        return nil
    end
    if IsLightV2(proxyID) then
        return control.v2
    end
    return control.v1
end

-- Advanced control variables to watch: all of them on V1 dimmers; on Light V2 lights only the
-- Default On preset (1006), whose change also refreshes the other settings
function GetDimmerControlVariables(proxyID)
    local isV2 = IsLightV2(proxyID)
    local varIDs = {}
    for suffix in pairs(DIMMER_CONTROL_VARS) do
        local varID = GetDimmerControlVariable(proxyID, suffix)
        if varID and (not isV2 or C4:GetDeviceVariable(proxyID, varID) ~= nil) then
            table.insert(varIDs, varID)
        end
    end
    return varIDs
end

-- The advanced control a changed proxy variable belongs to, or nil
function GetDimmerControlForVariable(proxyID, varID)
    for suffix in pairs(DIMMER_CONTROL_VARS) do
        if GetDimmerControlVariable(proxyID, suffix) == varID then
            return suffix
        end
    end
    return nil
end

-- Current value of an advanced control as Home Assistant shows it (hold rates in seconds), or nil
-- if the light doesn't have it. Light V2: as the proxy last answered. V1 hold rates have no
-- variable: the last value set from Home Assistant.
function GetDimmerControlValue(deviceID, proxyID, suffix)
    local control = DIMMER_CONTROL_VARS[suffix]
    if not control then
        return nil
    end
    local value
    if IsLightV2(proxyID) then
        local settings = GetLightV2Settings(proxyID)
        value = settings and settings.values[suffix]
    elseif control.v1 then
        value = C4:GetDeviceVariable(proxyID, control.v1)
    end
    if value ~= nil and value ~= "" then
        if control.seconds then
            return string.format("%g", (tonumber(value) or 0) / 1000)
        end
        return tostring(value)
    end
    if IsLightV2(proxyID) then
        return nil
    end
    -- V1 hold rates (seconds): set from Home Assistant, or reported by the dimmer (OnDataToUI)
    local rates = gHoldRampRates[tonumber(deviceID)]
    if suffix == "hold_ramp_rate_up" and rates and rates.up then
        return string.format("%g", rates.up)
    elseif suffix == "hold_ramp_rate_down" and rates and rates.down then
        return string.format("%g", rates.down)
    end
    return nil
end

-- Build a map of proxy ID -> device ID
-- This is used during discovery to convert proxy IDs (from C4:GetDevicesByC4iName) to device IDs for storage
function BuildProxyToDeviceMap()
    local map = {}
    local devices = C4:GetDevices()

    if not devices then
        return map
    end

    for deviceID, deviceInfo in pairs(devices) do
        local proxies = deviceInfo.proxies or {}
        for proxyID, _ in pairs(proxies) do
            map[tonumber(proxyID)] = tonumber(deviceID)
        end
    end

    return map
end

-- Get the monitored list for a device type
function GetMonitoredList(deviceType)
    if deviceType == "LIGHT" then
        return gMonitoredLights
    elseif deviceType == "SWITCH" then
        return gMonitoredSwitches
    elseif deviceType == "OUTLET" then
        return gMonitoredOutlets
    elseif deviceType == "THERMOSTAT" then
        return gMonitoredThermostats
    elseif deviceType == "MEDIA_ROOM" then
        return gMonitoredMediaRooms
    elseif deviceType == "CONTACT_SENSOR" then
        return gMonitoredContactSensors
    end
    return {}
end

-- Monitored devices by type as sets, and the proxy -> device maps that variable changes (which
-- arrive with the proxy ID) are looked up in. Built once and rebuilt only when a monitored list or
-- the proxy lookup changes, instead of resolving every monitored device's proxy on every change.
local LOOKUP_TYPES = {"LIGHT", "SWITCH", "OUTLET", "THERMOSTAT", "MEDIA_ROOM", "CONTACT_SENSOR"}

function InvalidateDeviceLookup()
    gDeviceLookup = nil
end

function GetDeviceLookup()
    local lookup = gDeviceLookup
    if lookup then
        -- A list replaced or resized without going through a save also counts as a change
        for _, deviceType in ipairs(LOOKUP_TYPES) do
            local list = GetMonitoredList(deviceType)
            if lookup.lists[deviceType] ~= list or lookup.counts[deviceType] ~= #list then
                lookup = nil
                break
            end
        end
        if lookup then
            return lookup
        end
    end

    -- Resolve the Light V2 / outlet proxy sets first: refreshing them invalidates the lookup
    if not gLightV2Proxies then
        RefreshLightV2Proxies()
    end
    if not gOutletProxies then
        FindOutletProxies()
    end

    lookup = { sets = {}, lists = {}, counts = {}, lightProxy = {}, thermostatProxy = {} }
    for _, deviceType in ipairs(LOOKUP_TYPES) do
        local list = GetMonitoredList(deviceType)
        local config = DEVICE_TYPES[deviceType]
        local set = {}
        for _, item in ipairs(list) do
            local id = tonumber((config.uses_table and item.id) or item)
            if id then
                set[id] = true
            end
        end
        lookup.sets[deviceType] = set
        lookup.lists[deviceType] = list
        lookup.counts[deviceType] = #list
    end
    -- Light proxy variables: as before, the first device of a list with that proxy, and an outlet
    -- over a switch over a light
    for _, deviceType in ipairs({"LIGHT", "SWITCH", "OUTLET"}) do
        local typeMap = {}
        for _, deviceID in ipairs(GetMonitoredList(deviceType)) do
            local proxyID = tonumber(GetProxyID(deviceID))
            if proxyID and typeMap[proxyID] == nil then
                typeMap[proxyID] = deviceID
            end
        end
        for proxyID, deviceID in pairs(typeMap) do
            lookup.lightProxy[proxyID] = deviceID
        end
    end
    for _, deviceID in ipairs(gMonitoredThermostats) do
        local proxyID = tonumber(GetProxyID(deviceID))
        if proxyID and lookup.thermostatProxy[proxyID] == nil then
            lookup.thermostatProxy[proxyID] = deviceID
        end
    end
    gDeviceLookup = lookup
    return lookup
end

-- Check if a device is being monitored
function IsDeviceMonitored(deviceID, deviceType)
    local set = GetDeviceLookup().sets[deviceType]
    local id = tonumber(deviceID)
    return set ~= nil and id ~= nil and set[id] == true
end

-- Generic device loading from persistence
function LoadMonitoredDevices(deviceType)
    local config = DEVICE_TYPES[deviceType]
    local saved = C4:PersistGetValue(config.storage_key)
    local list = GetMonitoredList(deviceType)

    if not saved or saved == "" then
        return
    end

    if config.uses_table then
        -- Touchscreens use JSON-like storage: id:name:ip,id:name:ip
        for entry in string.gmatch(saved, "([^,]+)") do
            local id, name, ip = string.match(entry, "(%d+):([^:]+):([^:]+)")
            if id and name and ip then
                table.insert(list, {id = tonumber(id), name = name, ip = ip})
            end
        end
    else
        -- Lights and thermostats use comma-separated IDs
        for deviceID in string.gmatch(saved, "([^,]+)") do
            local id = tonumber(deviceID)
            if id then
                table.insert(list, id)
            end
        end
    end

    if #list > 0 then
        Log("Loaded " .. #list .. " monitored " .. string.lower(config.plural) .. " from storage")
    end
end

-- Generic device saving to persistence
function SaveMonitoredDevices(deviceType)
    local config = DEVICE_TYPES[deviceType]
    local list = GetMonitoredList(deviceType)
    local saveStr

    if config.uses_table then
        -- Touchscreens: id:name:ip,id:name:ip
        local entries = {}
        for _, ts in ipairs(list) do
            table.insert(entries, ts.id .. ":" .. ts.name .. ":" .. ts.ip)
        end
        saveStr = table.concat(entries, ",")
    else
        -- Lights and thermostats: comma-separated IDs
        saveStr = table.concat(list, ",")
    end

    C4:PersistSetValue(config.storage_key, saveStr)
    InvalidateDeviceLookup()
end

-- Generic device count updater
function UpdateDeviceCount(deviceType)
    local config = DEVICE_TYPES[deviceType]
    local list = GetMonitoredList(deviceType)
    C4:UpdateProperty(config.property_name, tostring(#list))
end

-- Subscribe to device variable changes
-- For lights/switches/outlets: registers on proxy for state variables, on device for LED variables
-- For thermostats: registers on proxy for state variables, on device for LED color
-- For media rooms: device ID = proxy ID, registers directly
function SubscribeToDevice(deviceID, deviceType)
    local config = DEVICE_TYPES[deviceType]
    InvalidateDeviceLookup()

    if deviceType == "LIGHT" or deviceType == "SWITCH" or deviceType == "OUTLET" then
        -- For lights/switches/outlets, state variables are on the proxy
        local proxyID = GetProxyID(deviceID)
        for _, varID in ipairs(config.variable_ids) do
            C4:RegisterVariableListener(proxyID, varID)
        end

        -- Light V2 lights: their current color and capabilities (1200, 1201, 1202, 6661) and the
        -- Default On preset (1006), whatever the capabilities say now. At start-up a light driver
        -- may not have reported its capabilities yet (6661 empty), and a light that gains color
        -- later must not need a restart of this driver to be followed.
        if deviceType == "LIGHT" and IsLightV2(proxyID) then
            for _, varID in ipairs(LIGHT_V2_COLOR_VARIABLES) do
                C4:RegisterVariableListener(proxyID, varID)
            end
            C4:RegisterVariableListener(proxyID, VARIABLE_IDS.V2_PRESET_LEVEL)
        end

        -- Light V2 lights whose driver announces settings changes (see SETTINGS_CHANGED_VAR), and
        -- power / energy the light's driver reports (see ENERGY_SENSORS)
        if deviceType == "LIGHT" or deviceType == "SWITCH" then
            ResolveSettingsChangedVariable(deviceID)
            ResolveEnergyVariables(deviceID)
        end

        -- Also register for LED color variables on the device itself (if LED control enabled)
        -- Only for lights and switches, not outlets
        if (deviceType == "LIGHT" or deviceType == "SWITCH") and IsLEDControlEnabled() then
            C4:RegisterVariableListener(deviceID, VARIABLE_IDS.TOP_BUTTON_ON_COLOR)
            C4:RegisterVariableListener(deviceID, VARIABLE_IDS.TOP_BUTTON_OFF_COLOR)
            C4:RegisterVariableListener(deviceID, VARIABLE_IDS.BOTTOM_BUTTON_ON_COLOR)
            C4:RegisterVariableListener(deviceID, VARIABLE_IDS.BOTTOM_BUTTON_OFF_COLOR)
        end

        -- Also register for advanced dimmer control variables on the proxy (if enabled)
        -- Only for actual dimmers, not switches or outlets
        if deviceType == "LIGHT" and IsAdvancedDimmerControlEnabled() then
            -- Check if this is actually a dimmer (has LIGHT_LEVEL) vs a switch (only SWITCH_STATE)
            local level = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.LIGHT_LEVEL)
            local isDimmer = (level and level ~= "")

            if isDimmer then
                for _, varID in ipairs(GetDimmerControlVariables(proxyID)) do
                    C4:RegisterVariableListener(proxyID, varID)
                end
                -- Settings changed in Control4 that no variable shows (Light V2 settings, V1 hold
                -- rates): the OnDataToUI system event
                WatchLightSettingsEvents(deviceID)
            end
        end
    elseif deviceType == "THERMOSTAT" then
        -- For thermostats, register on proxy ID for thermostat variables
        local proxyID = GetProxyID(deviceID)
        for _, varID in ipairs(config.variable_ids) do
            -- Variable 1001 (THERMOSTAT_BUTTON_LED_COLOR) is on device, others on proxy
            if varID == VARIABLE_IDS.THERMOSTAT_BUTTON_LED_COLOR then
                C4:RegisterVariableListener(deviceID, varID)
            else
                C4:RegisterVariableListener(proxyID, varID)
            end
        end
    elseif deviceType == "MEDIA_ROOM" then
        -- For media rooms, device ID = proxy ID, register directly
        for _, varID in ipairs(config.variable_ids) do
            C4:RegisterVariableListener(deviceID, varID)
        end

        -- Also register for device events to track playback state
        Log("Registering device events for media room " .. deviceID)
        for eventName, eventID in pairs(ROOM_EVENTS) do
            C4:RegisterDeviceEvent(deviceID, eventID)
        end
        -- Initialize playback state to idle
        gMediaRoomPlaybackState[deviceID] = "idle"
    end
end

-- Unsubscribe from device variable changes
function UnsubscribeFromDevice(deviceID, deviceType)
    local config = DEVICE_TYPES[deviceType]
    InvalidateDeviceLookup()

    if deviceType == "LIGHT" or deviceType == "SWITCH" or deviceType == "OUTLET" then
        -- For lights/switches/outlets, unregister from proxy variables
        local proxyID = GetProxyID(deviceID)
        for _, varID in ipairs(config.variable_ids) do
            C4:UnregisterVariableListener(proxyID, varID)
        end

        if deviceType == "LIGHT" and IsLightV2(proxyID) then
            for _, varID in ipairs(LIGHT_V2_COLOR_VARIABLES) do
                C4:UnregisterVariableListener(proxyID, varID)
            end
            C4:UnregisterVariableListener(proxyID, VARIABLE_IDS.V2_PRESET_LEVEL)
        end
        UnwatchLightSettingsEvents(deviceID)

        if gSettingsChangedVars[deviceID] then
            C4:UnregisterVariableListener(deviceID, gSettingsChangedVars[deviceID])
            gSettingsChangedVars[deviceID] = nil
        end
        if deviceType == "LIGHT" or deviceType == "SWITCH" then
            UnwatchEnergyVariables(deviceID)
        end

        -- Also unregister LED variables from device (only for lights and switches, not outlets)
        if (deviceType == "LIGHT" or deviceType == "SWITCH") and IsLEDControlEnabled() then
            C4:UnregisterVariableListener(deviceID, VARIABLE_IDS.TOP_BUTTON_ON_COLOR)
            C4:UnregisterVariableListener(deviceID, VARIABLE_IDS.TOP_BUTTON_OFF_COLOR)
            C4:UnregisterVariableListener(deviceID, VARIABLE_IDS.BOTTOM_BUTTON_ON_COLOR)
            C4:UnregisterVariableListener(deviceID, VARIABLE_IDS.BOTTOM_BUTTON_OFF_COLOR)
        end

        -- Also unregister advanced dimmer control variables from proxy (only for actual dimmers)
        if deviceType == "LIGHT" and IsAdvancedDimmerControlEnabled() then
            -- Check if this is actually a dimmer (has LIGHT_LEVEL) vs a switch (only SWITCH_STATE)
            local level = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.LIGHT_LEVEL)
            local isDimmer = (level and level ~= "")

            if isDimmer then
                for _, varID in ipairs(GetDimmerControlVariables(proxyID)) do
                    C4:UnregisterVariableListener(proxyID, varID)
                end
            end
        end
    else
        -- For thermostats and media rooms, unregister directly
        for _, varID in ipairs(config.variable_ids) do
            C4:UnregisterVariableListener(deviceID, varID)
        end

        -- For media rooms, also unregister device events
        if deviceType == "MEDIA_ROOM" then
            Log("Unregistering device events for media room " .. deviceID)
            for eventName, eventID in pairs(ROOM_EVENTS) do
                C4:UnregisterDeviceEvent(deviceID, eventID)
            end
            -- Clear playback state
            gMediaRoomPlaybackState[deviceID] = nil
        end
    end
end

-- Generic list all monitored devices
function ListMonitoredDevices(deviceType)
    local config = DEVICE_TYPES[deviceType]
    local list = GetMonitoredList(deviceType)

    Log("========================================")
    Log("Monitored " .. config.plural .. " (" .. #list .. " total):")

    if #list == 0 then
        Log("  (none)")
    else
        for i, item in ipairs(list) do
            local deviceID = (config.uses_table and item.id) or item

            -- For lights/switches/outlets, get proxy ID for reading variables and display name
            local proxyID = (deviceType == "LIGHT" or deviceType == "SWITCH" or deviceType == "OUTLET") and GetProxyID(deviceID) or deviceID
            local deviceName = C4:GetDeviceDisplayName(proxyID) or "Unknown"

            if deviceType == "LIGHT" then
                local level = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.LIGHT_LEVEL)
                if level and level ~= "" then
                    local kind = "Dimmer"
                    if IsLightV2(proxyID) then
                        kind = GetLightColorCaps(proxyID) and "Light V2, color" or "Light V2"
                    end
                    Log(string.format("  %d. [%d] %s - %s: %s%%", i, deviceID, deviceName, kind, level))
                else
                    local switchState = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.SWITCH_STATE)
                    local state = (switchState == "1" or switchState == "ON") and "ON" or "OFF"
                    Log(string.format("  %d. [%d] %s - Switch: %s", i, deviceID, deviceName, state))
                end
            elseif deviceType == "SWITCH" then
                local switchState = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.SWITCH_STATE)
                local state = (switchState == "1" or switchState == "ON") and "ON" or "OFF"
                Log(string.format("  %d. [%d] %s - State: %s", i, deviceID, deviceName, state))
            elseif deviceType == "OUTLET" then
                local switchState = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.SWITCH_STATE)
                local state = (switchState == "1" or switchState == "true" or switchState == "ON" or switchState == "True") and "ON" or "OFF"
                Log(string.format("  %d. [%d] %s - State: %s (proxy %d)", i, deviceID, deviceName, state, proxyID))
            elseif deviceType == "THERMOSTAT" then
                local temp = C4:GetDeviceVariable(deviceID, VARIABLE_IDS.TEMPERATURE_F) or "?"
                local mode = C4:GetDeviceVariable(deviceID, VARIABLE_IDS.HVAC_MODE) or "?"
                Log(string.format("  %d. [%d] %s - %s°F, Mode: %s", i, deviceID, deviceName, temp, mode))
            elseif deviceType == "MEDIA_ROOM" then
                local power = tonumber(C4:GetDeviceVariable(deviceID, VARIABLE_IDS.ROOM_POWER_STATE) or "") or 0
                local volume = C4:GetDeviceVariable(deviceID, VARIABLE_IDS.ROOM_CURRENT_VOLUME) or "?"
                Log(string.format("  %d. [%d] %s - Power: %s, Volume: %s, Playback: %s", i, deviceID, deviceName,
                    power == 0 and "OFF" or "ON", tostring(volume), gMediaRoomPlaybackState[deviceID] or "idle"))
            elseif deviceType == "CONTACT_SENSOR" then
                local deviceInfo = gContactSensorDevices[deviceID]
                if deviceInfo then
                    local bindingCount = 0
                    local contactNames = {}
                    for bindingID, customName in pairs(deviceInfo.bindings) do
                        bindingCount = bindingCount + 1
                        table.insert(contactNames, customName)
                    end
                    local battery = C4:GetDeviceVariable(deviceID, VARIABLE_IDS.CONTACT_BATTERY_LEVEL) or "?"
                    local temp = C4:GetDeviceVariable(deviceID, VARIABLE_IDS.CONTACT_TEMPERATURE) or "?"
                    Log(string.format("  %d. [%d] %s - %d contact(s): %s - Battery: %s%%, Temp: %s°F",
                        i, deviceID, deviceName, bindingCount, table.concat(contactNames, ", "), battery, temp))
                else
                    Log(string.format("  %d. [%d] %s", i, deviceID, deviceName))
                end
            elseif deviceType == "TOUCHSCREEN" then
                Log(string.format("  %d. [%d] %s - IP: %s", i, deviceID, deviceName, item.ip))
            end
        end
    end

    Log("========================================")
end

-- Generic refresh all device states
function RefreshAllDeviceStates(deviceType)
    local config = DEVICE_TYPES[deviceType]
    local list = GetMonitoredList(deviceType)

    if not gMQTTConnected then
        LogError("Cannot refresh " .. string.lower(config.plural) .. " - not connected to MQTT")
        return false
    end

    Log("Refreshing all " .. string.lower(config.plural) .. " states...")

    for _, item in ipairs(list) do
        local deviceID = (config.uses_table and item.id) or item

        if deviceType == "LIGHT" then
            PublishLightState(deviceID)
            -- Light V2: read its settings and LED colors again (the proxy has no variables for them)
            if IsLightV2(GetProxyID(deviceID)) and (IsLEDControlEnabled() or IsAdvancedDimmerControlEnabled()) then
                RefreshLightV2Settings(GetProxyID(deviceID))
            end
            -- Also publish LED states if enabled
            if IsLEDControlEnabled() then
                PublishAllLEDStates(deviceID)
            end
            -- Also publish advanced dimmer control states if enabled
            if IsAdvancedDimmerControlEnabled() then
                PublishDimmerAdvancedControlStates(deviceID)
            end
        elseif deviceType == "SWITCH" then
            PublishSwitchState(deviceID)
            -- Also publish LED states if enabled
            if IsLEDControlEnabled() then
                PublishAllLEDStates(deviceID)
            end
        elseif deviceType == "OUTLET" then
            PublishOutletState(deviceID)
        elseif deviceType == "THERMOSTAT" then
            PublishThermostatState(deviceID)
        elseif deviceType == "MEDIA_ROOM" then
            PublishMediaRoomState(deviceID)
        elseif deviceType == "CONTACT_SENSOR" then
            PublishContactSensorState(deviceID)
        -- Note: Touchscreens don't have MQTT state publishing (used only for local C4 actions)
        end
    end

    Log("Refreshed " .. #list .. " " .. string.lower(config.plural))
    return true
end

-- Generic discover all devices
function DiscoverAllDevices(deviceType)
    local config = DEVICE_TYPES[deviceType]
    local list = GetMonitoredList(deviceType)

    Log("Auto-discovering " .. config.plural .. "...")
    if deviceType == "LIGHT" then
        RefreshLightV2Proxies()
    end
    -- Outlets of every driver generation; lights and switches leave them to the outlet list
    local outletProxies = {}
    if deviceType == "LIGHT" or deviceType == "SWITCH" or deviceType == "OUTLET" then
        outletProxies = FindOutletProxies()
        if deviceType == "OUTLET" then
            Log("  Outlet drivers in the project have " .. #outletProxies .. " outlet(s)")
        end
    end

    -- Build proxy->device map for all device types except media rooms (which don't have separate device/proxy)
    local proxyToDevice = {}
    if deviceType ~= "MEDIA_ROOM" and deviceType ~= "CONTACT_SENSOR" then
        proxyToDevice = BuildProxyToDeviceMap()
    end

    local foundDevices = {}

    -- Outlets are stored by proxy ID, so both outlets of a two-outlet device are found
    if deviceType == "OUTLET" then
        for _, proxyID in ipairs(outletProxies) do
            local name = C4:GetDeviceDisplayName(proxyID)
            local state = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.SWITCH_STATE)
            if name and state ~= nil then
                table.insert(foundDevices, {id = proxyID, name = name})
            else
                Log("  Skipping outlet proxy " .. proxyID .. " - no name or no state variable")
            end
        end
    end

    -- Search for all proxy types for this device
    for _, proxyName in ipairs(config.proxy_names) do
        local devices = C4:GetDevicesByC4iName(proxyName)
        if devices then
            for key, device in pairs(devices) do
                local proxyID = tonumber(key)  -- C4:GetDevicesByC4iName returns proxy IDs

                if proxyID then
                    -- Convert proxy ID to device ID (use proxy as-is only for media rooms/contact sensors)
                    local deviceID = proxyToDevice[proxyID] or proxyID
                    local name = C4:GetDeviceDisplayName(proxyID)  -- Display name comes from proxy

                    if name and (deviceType == "LIGHT" or deviceType == "SWITCH") and IsOutletProxy(proxyID) then
                        Log("  Skipping " .. proxyID .. " (" .. name .. ") - it is an outlet")
                        -- Its device may have been published as a light before (with LED color and
                        -- dimmer control entities): take those out of Home Assistant
                        if deviceType == "LIGHT" and gMQTTConnected then
                            RemoveLightEntities(deviceID)
                        end
                        name = nil
                    end

                    if name then
                    -- Check if already found
                    local alreadyFound = false
                    for _, foundDevice in ipairs(foundDevices) do
                        if foundDevice.id == deviceID then
                            alreadyFound = true
                            break
                        end
                    end

                    if not alreadyFound then
                        -- Verify device by checking if we can read its variables (use proxy ID for reading)
                        local isValid = false

                        if deviceType == "LIGHT" then
                            local level = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.LIGHT_LEVEL)
                            local state = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.SWITCH_STATE)
                            isValid = (level ~= nil or state ~= nil)
                        elseif deviceType == "SWITCH" then
                            local state = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.SWITCH_STATE)
                            isValid = (state ~= nil)
                        elseif deviceType == "OUTLET" then
                            local state = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.SWITCH_STATE)
                            isValid = (state ~= nil)
                        elseif deviceType == "THERMOSTAT" then
                            local temp = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.TEMPERATURE_F)
                            isValid = (temp ~= nil)
                        end

                        if isValid then
                            -- Apply switch filtering for lights and switches (use device ID for checking)
                            if deviceType == "LIGHT" then
                                if not IsDeviceConfiguredAsSwitch(deviceID) then
                                    table.insert(foundDevices, {id = deviceID, name = name})
                                else
                                    Log("  Skipping " .. deviceID .. " (" .. name .. ") - configured as switch")
                                end
                            elseif deviceType == "SWITCH" then
                                if IsDeviceConfiguredAsSwitch(deviceID) then
                                    table.insert(foundDevices, {id = deviceID, name = name})
                                end
                            else
                                table.insert(foundDevices, {id = deviceID, name = name})
                            end
                        end
                    end
                    end
                end
            end
        end
    end

    if #foundDevices == 0 then
        Log("No " .. string.lower(config.plural) .. " found in system")
        -- Don't leave deleted outlets or switches behind in the monitored list
        if deviceType == "OUTLET" or deviceType == "SWITCH" then
            CleanupDeletedOfType(deviceType)
        end
        return false
    end

    -- Clear previous monitored devices
    for _, item in ipairs(list) do
        local deviceID = (config.uses_table and item.id) or item
        UnsubscribeFromDevice(deviceID, deviceType)
    end

    -- Clear the list
    if deviceType == "LIGHT" then
        gMonitoredLights = {}
    elseif deviceType == "SWITCH" then
        gMonitoredSwitches = {}
    elseif deviceType == "OUTLET" then
        gMonitoredOutlets = {}
    elseif deviceType == "THERMOSTAT" then
        gMonitoredThermostats = {}
    elseif deviceType == "MEDIA_ROOM" then
        gMonitoredMediaRooms = {}
    end

    -- Add verified devices to monitoring
    for _, device in ipairs(foundDevices) do
        if config.uses_table then
            table.insert(GetMonitoredList(deviceType), device)
        else
            table.insert(GetMonitoredList(deviceType), device.id)
            SubscribeToDevice(device.id, deviceType)
        end
    end

    SaveMonitoredDevices(deviceType)
    UpdateDeviceCount(deviceType)

    Log("Now monitoring " .. #foundDevices .. " " .. string.lower(config.plural))

    -- Publish initial states and auto-discovery
    RefreshAllDeviceStates(deviceType)

    return true
end

------------------------------------------------------------------------
-- LEGACY PERSISTENCE FUNCTIONS (Kept for backward compatibility)
-- These now wrap the generic functions above
------------------------------------------------------------------------

-- Light Persistence Functions (Wrappers)
function LoadMonitoredLights()
    LoadMonitoredDevices("LIGHT")
end

function SaveMonitoredLights()
    SaveMonitoredDevices("LIGHT")
end

function UpdateLightCount()
    UpdateDeviceCount("LIGHT")
end

-- Switch Persistence Functions (Wrappers)
function LoadMonitoredSwitches()
    LoadMonitoredDevices("SWITCH")
end

function SaveMonitoredSwitches()
    SaveMonitoredDevices("SWITCH")
end

function UpdateSwitchCount()
    UpdateDeviceCount("SWITCH")
end

-- Load Switch IDs from driver property
function LoadSwitchIDsFromProperty()
    local switchIDsStr = Properties["Switch Device IDs (comma separated)"] or ""
    gSwitchIDsSet = {}

    if switchIDsStr == "" then
        return
    end

    for idStr in string.gmatch(switchIDsStr, "([^,]+)") do
        local id = tonumber(string.match(idStr, "^%s*(%d+)%s*$"))
        if id then
            gSwitchIDsSet[id] = true
        end
    end

    if next(gSwitchIDsSet) then
        local count = 0
        for _ in pairs(gSwitchIDsSet) do count = count + 1 end
        Log("Loaded " .. count .. " switch IDs from property")
    end
end

-- Check if a device is configured as a switch
function IsDeviceConfiguredAsSwitch(deviceID)
    return gSwitchIDsSet[deviceID] == true
end

-- Outlet Persistence Functions (Wrappers)
function LoadMonitoredOutlets()
    LoadMonitoredDevices("OUTLET")
end

function SaveMonitoredOutlets()
    SaveMonitoredDevices("OUTLET")
end

function UpdateOutletCount()
    UpdateDeviceCount("OUTLET")
end

-- Thermostat Persistence Functions (Wrappers)
function LoadMonitoredThermostats()
    LoadMonitoredDevices("THERMOSTAT")
end

function SaveMonitoredThermostats()
    SaveMonitoredDevices("THERMOSTAT")
end

function UpdateThermostatCount()
    UpdateDeviceCount("THERMOSTAT")
end

-- Media Room Persistence Functions (Wrappers)
function LoadMonitoredMediaRooms()
    LoadMonitoredDevices("MEDIA_ROOM")
end

function SaveMonitoredMediaRooms()
    SaveMonitoredDevices("MEDIA_ROOM")
end

function UpdateMediaRoomCount()
    UpdateDeviceCount("MEDIA_ROOM")
end

-- Load Media Room IDs from driver property
function LoadMediaRoomIDsFromProperty()
    local roomIDsStr = Properties["Media Room IDs (comma separated)"] or ""

    if roomIDsStr == "" then
        return
    end

    local roomIDsToAdd = {}
    for idStr in string.gmatch(roomIDsStr, "([^,]+)") do
        local id = tonumber(string.match(idStr, "^%s*(%d+)%s*$"))
        if id then
            -- Check if already monitored
            local alreadyMonitored = false
            for _, existingID in ipairs(gMonitoredMediaRooms) do
                if existingID == id then
                    alreadyMonitored = true
                    break
                end
            end

            if not alreadyMonitored then
                table.insert(roomIDsToAdd, id)
            end
        end
    end

    -- Add new room IDs
    for _, roomID in ipairs(roomIDsToAdd) do
        local roomName = C4:GetDeviceDisplayName(roomID)
        if roomName then
            Log("Adding media room from property: " .. roomID .. " (" .. roomName .. ")")
            table.insert(gMonitoredMediaRooms, roomID)
        else
            LogError("Media room " .. roomID .. " not found - skipping")
        end
    end

    if #roomIDsToAdd > 0 then
        SaveMonitoredMediaRooms()
        UpdateMediaRoomCount()
        Log("Loaded " .. #roomIDsToAdd .. " new media room(s) from property")
    end
end

-- Take every entity a monitored light can have out of Home Assistant: the light itself, its four
-- button LED color texts and its advanced dimmer control numbers. An empty retained config removes
-- an entity, and is harmless for one that was never published.
function RemoveLightEntities(deviceID)
    for _, topic in ipairs(DeviceConfigTopics("LIGHT", deviceID)) do
        PublishMQTT(topic, "", 1, true)
    end
end

-- Handle devices that have been deleted from Control4
function RemoveDeletedDevice(lightID)
    Log("========================================")
    Log("Removing deleted device from monitoring")
    Log("  Device ID: " .. lightID)

    -- Check if device is in our monitored list
    local found = false
    for i, id in ipairs(gMonitoredLights) do
        if id == lightID then
            found = true
            table.remove(gMonitoredLights, i)
            Log("  Removed from monitored list")
            break
        end
    end

    if not found then
        Log("  Device was not in monitored list")
        Log("========================================")
        return
    end

    -- Save updated list
    SaveMonitoredLights()
    UpdateLightCount()

    -- Remove from Home Assistant by publishing empty discovery
    if gMQTTConnected then
        Log("  Publishing removal to Home Assistant...")

        -- Empty payloads remove the light and its LED / dimmer control entities
        RemoveLightEntities(lightID)
        Log("  Device removed from Home Assistant")
    else
        Log("  Not connected to MQTT - device will be removed on next connection")
    end

    Log("========================================")
end

-- Light Monitoring Functions
function AddLightToMonitor(lightID)
    lightID = tonumber(lightID)
    if not lightID then
        LogError("Invalid light ID")
        return false
    end

    -- Check combined limit (lights + switches + outlets)
    local totalDevices = #gMonitoredLights + #gMonitoredSwitches + #gMonitoredOutlets
    if totalDevices >= LIMITS.MAX_MONITORED_LIGHTS then
        LogError("Cannot add light - maximum limit of " .. LIMITS.MAX_MONITORED_LIGHTS .. " devices reached (lights + switches + outlets)")
        return false
    end

    for _, id in ipairs(gMonitoredLights) do
        if id == lightID then
            Log("Already monitoring light " .. lightID)
            return true
        end
    end
    
    local lightName = C4:GetDeviceDisplayName(lightID)
    if not lightName then
        LogError("Light " .. lightID .. " not found in system")
        return false
    end
    RefreshLightV2Proxies()
    
    Log("========================================")
    Log("Adding light to monitor:")
    Log("  ID: " .. lightID)
    Log("  Name: " .. lightName)
    Log("========================================")
    
    table.insert(gMonitoredLights, lightID)
    SaveMonitoredLights()
    UpdateLightCount()
    
    SubscribeToLight(lightID)

    if gMQTTConnected then
        PublishLightState(lightID)
        PublishLightDiscovery(lightID)

        -- Also publish advanced dimmer control discovery if enabled
        if IsAdvancedDimmerControlEnabled() then
            PublishDimmerAdvancedControlDiscovery(lightID)
        end
    end

    return true
end

function RemoveLightFromMonitor(lightID)
    lightID = tonumber(lightID)
    
    for i, id in ipairs(gMonitoredLights) do
        if id == lightID then
            table.remove(gMonitoredLights, i)
            SaveMonitoredLights()
            UpdateLightCount()
            UnsubscribeFromLight(lightID)
            Log("Removed light " .. lightID .. " from monitoring")
            return true
        end
    end
    
    LogError("Light " .. lightID .. " not in monitored list")
    return false
end

-- Light/Switch Subscription Wrapper Functions
-- Note: SubscribeToDevice now handles both proxy variables and LED variables automatically
function SubscribeToLight(deviceID)
    SubscribeToDevice(deviceID, "LIGHT")
end

function UnsubscribeFromLight(deviceID)
    UnsubscribeFromDevice(deviceID, "LIGHT")
end

function SubscribeToSwitch(deviceID)
    SubscribeToDevice(deviceID, "SWITCH")
end

function UnsubscribeFromSwitch(deviceID)
    UnsubscribeFromDevice(deviceID, "SWITCH")
end

-- Outlet Subscription Wrappers
function SubscribeToOutlet(deviceID)
    SubscribeToDevice(deviceID, "OUTLET")
end

function UnsubscribeFromOutlet(deviceID)
    UnsubscribeFromDevice(deviceID, "OUTLET")
end

-- Switch Device Management Functions
function AddSwitchToMonitor(switchID)
    switchID = tonumber(switchID)
    if not switchID then
        LogError("Invalid switch ID")
        return false
    end

    -- Check combined limit (lights + switches + outlets)
    local totalDevices = #gMonitoredLights + #gMonitoredSwitches + #gMonitoredOutlets
    if totalDevices >= LIMITS.MAX_MONITORED_LIGHTS then
        LogError("Cannot add switch - maximum limit of " .. LIMITS.MAX_MONITORED_LIGHTS .. " devices reached (lights + switches + outlets)")
        return false
    end

    for _, id in ipairs(gMonitoredSwitches) do
        if id == switchID then
            Log("Already monitoring switch " .. switchID)
            return true
        end
    end

    local switchName = C4:GetDeviceDisplayName(switchID)
    if not switchName then
        LogError("Switch " .. switchID .. " not found in system")
        return false
    end

    Log("Adding switch to monitor: " .. switchName .. " (ID: " .. switchID .. ")")

    table.insert(gMonitoredSwitches, switchID)
    SaveMonitoredSwitches()
    UpdateSwitchCount()
    SubscribeToSwitch(switchID)

    if gMQTTConnected then
        PublishSwitchState(switchID)
        PublishSwitchDiscovery(switchID)
    end

    return true
end

function RemoveSwitchFromMonitor(switchID)
    switchID = tonumber(switchID)

    for i, id in ipairs(gMonitoredSwitches) do
        if id == switchID then
            table.remove(gMonitoredSwitches, i)
            SaveMonitoredSwitches()
            UpdateSwitchCount()
            UnsubscribeFromSwitch(switchID)
            Log("Removed switch " .. switchID .. " from monitoring")
            return true
        end
    end

    LogError("Switch " .. switchID .. " not in monitored list")
    return false
end

-- Outlet Device Management Functions
function AddOutletToMonitor(outletID)
    outletID = tonumber(outletID)
    if not outletID then
        LogError("Invalid outlet ID")
        return false
    end

    -- Check combined limit (lights + switches + outlets)
    local totalDevices = #gMonitoredLights + #gMonitoredSwitches + #gMonitoredOutlets
    if totalDevices >= LIMITS.MAX_MONITORED_LIGHTS then
        LogError("Cannot add outlet - maximum limit of " .. LIMITS.MAX_MONITORED_LIGHTS .. " devices reached (lights + switches + outlets)")
        return false
    end

    for _, id in ipairs(gMonitoredOutlets) do
        if id == outletID then
            Log("Already monitoring outlet " .. outletID)
            return true
        end
    end

    FindOutletProxies()  -- a newly added outlet driver may not be in the lookup yet
    local outletName = C4:GetDeviceDisplayName(outletID)
    if not outletName then
        LogError("Outlet " .. outletID .. " not found in system")
        return false
    end

    Log("Adding outlet to monitor: " .. outletName .. " (ID: " .. outletID .. ")")

    table.insert(gMonitoredOutlets, outletID)
    SaveMonitoredOutlets()
    UpdateOutletCount()
    SubscribeToOutlet(outletID)

    if gMQTTConnected then
        PublishOutletState(outletID)
        PublishOutletDiscovery(outletID)
    end

    return true
end

function RemoveOutletFromMonitor(outletID)
    outletID = tonumber(outletID)

    for i, id in ipairs(gMonitoredOutlets) do
        if id == outletID then
            table.remove(gMonitoredOutlets, i)
            SaveMonitoredOutlets()
            UpdateOutletCount()
            UnsubscribeFromOutlet(outletID)
            Log("Removed outlet " .. outletID .. " from monitoring")
            return true
        end
    end

    LogError("Outlet " .. outletID .. " not in monitored list")
    return false
end

-- Thermostat Device Management Functions
function AddThermostatToMonitor(thermostatID)
    thermostatID = tonumber(thermostatID)
    if not thermostatID then
        LogError("Invalid thermostat ID")
        return false
    end

    -- Use proxy ID to get display name
    local proxyID = GetProxyID(thermostatID)
    local thermostatName = C4:GetDeviceDisplayName(proxyID)
    if not thermostatName then
        LogError("Thermostat device " .. thermostatID .. " not found")
        return false
    end

    -- Check if already monitored
    for _, id in ipairs(gMonitoredThermostats) do
        if id == thermostatID then
            Log("Thermostat " .. thermostatID .. " (" .. thermostatName .. ") is already monitored")
            return true
        end
    end

    Log("========================================")
    Log("Adding Thermostat to monitoring:")
    Log("  Device ID: " .. thermostatID)
    Log("  Device Name: " .. thermostatName)

    table.insert(gMonitoredThermostats, thermostatID)
    SaveMonitoredThermostats()
    UpdateThermostatCount()

    -- Subscribe to thermostat events
    SubscribeToThermostat(thermostatID)

    -- If connected, publish state and discovery
    if gMQTTConnected then
        PublishThermostatState(thermostatID)
        PublishThermostatDiscovery(thermostatID)
    end

    Log("Thermostat added successfully")
    Log("========================================")
    return true
end

function RemoveThermostatFromMonitor(thermostatID)
    thermostatID = tonumber(thermostatID)
    if not thermostatID then
        LogError("Invalid thermostat ID")
        return false
    end

    Log("========================================")
    Log("Removing Thermostat from monitoring: " .. thermostatID)

    local found = false
    for i, id in ipairs(gMonitoredThermostats) do
        if id == thermostatID then
            table.remove(gMonitoredThermostats, i)
            found = true
            break
        end
    end

    if not found then
        LogError("Thermostat " .. thermostatID .. " not in monitored list")
        Log("========================================")
        return false
    end

    SaveMonitoredThermostats()
    UpdateThermostatCount()
    UnsubscribeFromThermostat(thermostatID)

    Log("Thermostat removed successfully")
    Log("========================================")
    return true
end

-- Media Room Device Management Functions
function AddMediaRoomToMonitor(roomID)
    roomID = tonumber(roomID)
    if not roomID then
        LogError("Invalid media room ID")
        return false
    end

    local roomName = C4:GetDeviceDisplayName(roomID)
    if not roomName then
        LogError("Media room device " .. roomID .. " not found")
        return false
    end

    -- Check if already monitored
    for _, id in ipairs(gMonitoredMediaRooms) do
        if id == roomID then
            Log("Media room " .. roomID .. " (" .. roomName .. ") is already monitored")
            return true
        end
    end

    Log("========================================")
    Log("Adding Media Room to monitoring:")
    Log("  Room ID: " .. roomID)
    Log("  Room Name: " .. roomName)

    table.insert(gMonitoredMediaRooms, roomID)
    SaveMonitoredMediaRooms()
    UpdateMediaRoomCount()

    -- Subscribe to media room events
    SubscribeToMediaRoom(roomID)

    -- If connected, publish state and discovery
    if gMQTTConnected then
        PublishMediaRoomState(roomID)
        PublishMediaRoomDiscovery(roomID)
    end

    Log("Media room added successfully")
    Log("========================================")
    return true
end

function RemoveMediaRoomFromMonitor(roomID)
    roomID = tonumber(roomID)
    if not roomID then
        LogError("Invalid media room ID")
        return false
    end

    Log("========================================")
    Log("Removing Media Room from monitoring: " .. roomID)

    local found = false
    for i, id in ipairs(gMonitoredMediaRooms) do
        if id == roomID then
            table.remove(gMonitoredMediaRooms, i)
            found = true
            break
        end
    end

    if not found then
        LogError("Media room " .. roomID .. " not in monitored list")
        Log("========================================")
        return false
    end

    SaveMonitoredMediaRooms()
    UpdateMediaRoomCount()
    UnsubscribeFromMediaRoom(roomID)

    -- Cancel any pending debounce timer
    CancelTimerObject(gMediaRoomDebounceTimers[roomID])
    gMediaRoomDebounceTimers[roomID] = nil

    -- Remove from Home Assistant by publishing empty discovery
    if gMQTTConnected then
        local discoveryTopic = "homeassistant/media_player/control4_room_" .. roomID .. "/config"
        PublishMQTT(discoveryTopic, "", 1, true)
        Log("Removed media room from Home Assistant")
    end

    Log("Media room removed successfully")
    Log("========================================")
    return true
end

-- Thermostat Subscription Functions (Wrappers)
function SubscribeToThermostat(thermostatID)
    SubscribeToDevice(thermostatID, "THERMOSTAT")
end

function UnsubscribeFromThermostat(thermostatID)
    UnsubscribeFromDevice(thermostatID, "THERMOSTAT")
end

-- Media Room Subscription Functions (Wrappers)
function SubscribeToMediaRoom(roomID)
    SubscribeToDevice(roomID, "MEDIA_ROOM")
end

function UnsubscribeFromMediaRoom(roomID)
    UnsubscribeFromDevice(roomID, "MEDIA_ROOM")
end


function ParseHVACState(c4State)
    -- Handle various HVAC_STATE formats:
    -- "Off", "Idle", "Stage 1 Heat", "Stage 2 Heat",
    -- "Stage 1 Cool", "Stage 2 Cool", "Heating", "Cooling"

    if not c4State or c4State == "" then
        return "off"
    end

    local stateLower = string.lower(c4State)

    if string.find(stateLower, "heat") then
        return "heating"
    elseif string.find(stateLower, "cool") then
        return "cooling"
    elseif stateLower == "idle" then
        return "idle"
    elseif stateLower == "off" then
        return "off"
    else
        return "idle"  -- Default to idle for unknown states
    end
end

-- A number cut to an integer toward zero, as string.format("%d", x) does with a fractional x on
-- Lua 5.1 (72.6 -> 72, -3.5 -> -3). Lua 5.3 and later raise an error for "%d" with a fractional
-- number instead, so values that may be fractional go through this first.
function TruncInt(x)
    x = tonumber(x) or 0
    if x ~= x or x == math.huge or x == -math.huge then
        return 0
    end
    if x >= 0 then
        return math.floor(x)
    end
    return math.ceil(x)
end

function PublishThermostatState(thermostatID)
    -- thermostatID is device ID (consistent with lights/switches)
    -- Use proxy ID for reading variables and getting display name
    local proxyID = GetProxyID(thermostatID)
    local thermostatName = C4:GetDeviceDisplayName(proxyID)

    if not thermostatName then
        LogError("Thermostat " .. thermostatID .. " not found - may have been deleted")
        return false
    end

    -- Read all thermostat variables from proxy
    local currentTemp = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.TEMPERATURE_F) or "0"
    local heatSetpoint = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.HEAT_SETPOINT_F) or "68"
    local coolSetpoint = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.COOL_SETPOINT_F) or "74"
    local hvacMode = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.HVAC_MODE) or "Off"
    local fanMode = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.FAN_MODE) or "Auto"
    local hvacState = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.HVAC_STATE) or "Idle"
    local humidity = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.HUMIDITY) or "0"

    -- Convert to numbers
    currentTemp = tonumber(currentTemp) or 0
    heatSetpoint = tonumber(heatSetpoint) or 68
    coolSetpoint = tonumber(coolSetpoint) or 74
    humidity = tonumber(humidity) or 0

    -- Map C4 modes to HA modes
    local haMode = HVAC_MODE_C4_TO_HA[hvacMode] or "off"
    local haFanMode = FAN_MODE_C4_TO_HA[fanMode] or "auto"
    local haAction = ParseHVACState(hvacState)

    -- Build mode-dependent JSON payload with null values
    -- Heat/Cool/Off modes: use single setpoint, null dual setpoints
    -- Auto mode: use dual setpoints, null single setpoint
    local payload
    if hvacMode == "Auto" then
        -- Auto mode: show dual setpoints, hide single setpoint
        payload = string.format([[{
  "current_temperature": %d,
  "temperature": null,
  "target_temp_high": %d,
  "target_temp_low": %d,
  "mode": "%s",
  "fan_mode": "%s",
  "action": "%s",
  "humidity": %d
}]], TruncInt(currentTemp), TruncInt(coolSetpoint), TruncInt(heatSetpoint), haMode, haFanMode, haAction, TruncInt(humidity))
    else
        -- Heat/Cool/Off modes: show single setpoint, hide dual setpoints
        local temperature = heatSetpoint
        if hvacMode == "Cool" then
            temperature = coolSetpoint
        end
        payload = string.format([[{
  "current_temperature": %d,
  "temperature": %d,
  "target_temp_high": null,
  "target_temp_low": null,
  "mode": "%s",
  "fan_mode": "%s",
  "action": "%s",
  "humidity": %d
}]], TruncInt(currentTemp), TruncInt(temperature), haMode, haFanMode, haAction, TruncInt(humidity))
    end

    local topic = "homeassistant/climate/control4_" .. thermostatID .. "/state"

    Log("Publishing thermostat state for: " .. thermostatName)
    Log("  Topic: " .. topic)
    Log("  Mode: " .. haMode .. ", Temp: " .. currentTemp .. "°F, Heat: " .. heatSetpoint .. "°F, Cool: " .. coolSetpoint .. "°F" .." Humidity: " .. humidity)

    -- Retained, so Home Assistant gets the state straight away after it restarts
    return PublishMQTT(topic, payload, 0, true)
end

function PublishThermostatDiscovery(thermostatID)
    -- thermostatID is device ID (we store device IDs for consistency)
    -- Use proxy ID for getting display name
    local proxyID = GetProxyID(thermostatID)
    local thermostatName = C4:GetDeviceDisplayName(proxyID)

    if not thermostatName then
        LogError("Thermostat " .. thermostatID .. " not found")
        return false
    end

    local uniqueID = "control4_thermostat_" .. thermostatID
    local deviceName = thermostatName
    local objectID = SanitizeEntityName(thermostatName)
    local configTopic = "homeassistant/climate/control4_" .. thermostatID .. "/config"
    local stateTopic = "homeassistant/climate/control4_" .. thermostatID .. "/state"
    local commandTopic = "homeassistant/climate/control4_" .. thermostatID .. "/set"

    -- Build command topics
    local modeCommandTopic = string.format("homeassistant/climate/control4_%d/mode/set", thermostatID)
    local tempCommandTopic = string.format("homeassistant/climate/control4_%d/temperature/set", thermostatID)
    local tempLowCommandTopic = string.format("homeassistant/climate/control4_%d/temperature_low/set", thermostatID)
    local tempHighCommandTopic = string.format("homeassistant/climate/control4_%d/temperature_high/set", thermostatID)
    local fanModeCommandTopic = string.format("homeassistant/climate/control4_%d/fan_mode/set", thermostatID)

    -- Build discovery payload with BOTH single and dual setpoint topics
    -- State payloads use JSON null to toggle between single/dual display
    -- Heat/Cool modes: temperature has value, target_temp_low/high are null
    -- Auto mode: temperature is null, target_temp_low/high have values
    local discoveryPayload = string.format([[{
  "name": null,
  "object_id": "%s",
  "default_entity_id": "%s",
  "unique_id": "%s",
  "modes": ["off", "heat", "cool", "heat_cool"],
  "fan_modes": ["auto", "on", "circulate"],
  "temperature_unit": "F",
  "current_temperature_topic": "%s",
  "current_temperature_template": "{{ value_json.current_temperature }}",
  "temperature_state_topic": "%s",
  "temperature_state_template": "{{ value_json.temperature }}",
  "temperature_command_topic": "%s",
  "temperature_low_state_topic": "%s",
  "temperature_low_state_template": "{{ value_json.target_temp_low }}",
  "temperature_low_command_topic": "%s",
  "temperature_high_state_topic": "%s",
  "temperature_high_state_template": "{{ value_json.target_temp_high }}",
  "temperature_high_command_topic": "%s",
  "mode_state_topic": "%s",
  "mode_state_template": "{{ value_json.mode }}",
  "fan_mode_state_topic": "%s",
  "fan_mode_state_template": "{{ value_json.fan_mode }}",
  "action_topic": "%s",
  "action_template": "{{ value_json.action }}",
  "current_humidity_topic": "%s",
  "current_humidity_template": "{{ value_json.humidity }}",
  "mode_command_topic": "%s",
  "fan_mode_command_topic": "%s",
  "min_temp": 50,
  "max_temp": 90,
  "temp_step": 1,
  "device": {
    "identifiers": ["%s"],
    "name": "%s",
    "manufacturer": "Control4",
    "model": "Aprilaire"
  }
}]], objectID, DefaultEntityID("climate", objectID, thermostatID), uniqueID,
     stateTopic, stateTopic, tempCommandTopic,
     stateTopic, tempLowCommandTopic, stateTopic, tempHighCommandTopic,
     stateTopic, stateTopic, stateTopic, stateTopic,
     modeCommandTopic, fanModeCommandTopic,
     uniqueID, EscapeJSON(deviceName))
    discoveryPayload = WithAvailability(discoveryPayload)

    Log("Publishing thermostat auto-discovery for: " .. thermostatName)
    Log("  Config Topic: " .. configTopic)

    if PublishMQTT(configTopic, discoveryPayload, 1, true) then
        Log("Thermostat discovery published successfully")

        -- Publish initial state
        PublishThermostatState(thermostatID)

        -- Publish LED color control discovery if enabled
        PublishThermostatButtonLEDDiscovery(thermostatID)

        return true
    else
        LogError("Failed to publish thermostat discovery")
        return false
    end
end

-- Thermostat Button LED Color Discovery
function PublishThermostatButtonLEDDiscovery(thermostatID)
    if not IsLEDControlEnabled() then
        return
    end

    -- thermostatID is device ID, get proxy for display name
    local proxyID = GetProxyID(thermostatID)
    local thermostatName = C4:GetDeviceDisplayName(proxyID)
    if not thermostatName then
        LogError("Thermostat " .. thermostatID .. " not found")
        return false
    end

    local discoveryTopic = "homeassistant/text/control4_thermostat_" .. thermostatID .. "_button_led/config"
    local objectID = SanitizeEntityName(thermostatName .. " Button LED")

    local config = {
        name = thermostatName .. " - Button LED Color",
        object_id = objectID,
        default_entity_id = DefaultEntityID("text", objectID, thermostatID),
        unique_id = "control4_thermostat_" .. thermostatID .. "_button_led_color",
        state_topic = "homeassistant/text/control4_thermostat_" .. thermostatID .. "_button_led/state",
        command_topic = "homeassistant/text/control4_thermostat_" .. thermostatID .. "_button_led/set",
        pattern = "[0-9A-Fa-f]{6}",  -- Validates 6-character hex codes
        mode = "text",
        icon = "mdi:palette",
        entity_category = "config",  -- Show in device config section
        device = {
            identifiers = {"control4_thermostat_" .. thermostatID},
            name = thermostatName,
            manufacturer = "Control4",
            model = "Thermostat V2"
        }
    }
    AddAvailability(config)

    local payload = EncodeJSON(config)
    Log("Publishing thermostat button LED discovery: " .. thermostatName)

    if PublishMQTT(discoveryTopic, payload, 1, true) then
        -- Publish initial state
        PublishThermostatButtonLEDState(thermostatID)
        return true
    else
        LogError("Failed to publish thermostat button LED discovery")
        return false
    end
end

-- Publish current thermostat button LED color state to HA
function PublishThermostatButtonLEDState(thermostatID)
    if not IsLEDControlEnabled() then
        return
    end

    -- thermostatID is the device ID (consistent with lights/switches)
    -- Variable 1001 on the DEVICE holds the button LED color
    local rgbString = C4:GetDeviceVariable(thermostatID, VARIABLE_IDS.THERMOSTAT_BUTTON_LED_COLOR)

    if not rgbString or rgbString == "" then
        Log("WARNING: No button LED color value for thermostat device " .. thermostatID)
        return false
    end

    -- Convert RGB string to hex for HA
    local hexColor = RGBStringToHex(rgbString)

    -- Ensure uppercase for consistency
    hexColor = string.upper(hexColor)

    -- Use device ID in topic (consistent with lights/switches pattern)
    local stateTopic = "homeassistant/text/control4_thermostat_" .. thermostatID .. "_button_led/state"

    Log("Publishing thermostat button LED state: " .. thermostatID .. " = " .. hexColor .. " (from C4: " .. rgbString .. ")")

    return PublishMQTT(stateTopic, hexColor, 1, true)  -- QoS 1, retained
end
-- Media Room State Publishing
-- EXPERIMENTAL: media room support (with the mqtt_media_player custom component) is experimental.
-- Playback state is inferred from room events and is not fully reliable.
function PublishMediaRoomState(roomID)
    local roomName = C4:GetDeviceDisplayName(roomID)
    if not roomName then
        LogError("Media room " .. roomID .. " not found - may have been deleted")
        return false
    end

    -- Read media room variables
    local powerState = tonumber(C4:GetDeviceVariable(roomID, VARIABLE_IDS.ROOM_POWER_STATE) or "0") or 0
    local volume = tonumber(C4:GetDeviceVariable(roomID, VARIABLE_IDS.ROOM_CURRENT_VOLUME) or "0") or 0
    local isMuted = tonumber(C4:GetDeviceVariable(roomID, VARIABLE_IDS.ROOM_IS_MUTED) or "0") or 0

    -- Determine state based on power and tracked playback state
    -- If room is off, state is "off"
    -- If room is on, use the tracked playback state (playing/paused/idle)
    local state
    if powerState == 0 then
        state = "off"
        gMediaRoomPlaybackState[roomID] = "idle"  -- Reset playback state when room turns off
    else
        -- Room is on - use tracked playback state or default to "idle"
        state = gMediaRoomPlaybackState[roomID] or "idle"
    end
    local muteState = (isMuted == 1)

    -- Build JSON payload for custom MQTT media player component
    local payload = string.format([[{
  "state": "%s",
  "volume_level": %.2f,
  "is_volume_muted": %s
}]], state, volume / 100.0, muteState and "true" or "false")

    local topic = "homeassistant/media_player/control4_room_" .. roomID .. "/state"

    Log("Publishing media room state for: " .. roomName)
    Log("  State: " .. state .. ", Volume: " .. volume .. ", Muted: " .. tostring(muteState))

    return PublishMQTT(topic, payload, 0, false)
end

-- Debounced Media Room State Publishing
-- Delays publishing until volume/state changes have settled (300ms)
function PublishMediaRoomStateDebounced(roomID)
    -- Cancel any existing timer for this room (SafeSetTimer returns a timer object)
    CancelTimerObject(gMediaRoomDebounceTimers[roomID])

    -- Create a new timer to publish after 300ms (non-repeating)
    local newTimer
    newTimer = SafeSetTimer(300, function(timer)
        if gMediaRoomDebounceTimers[roomID] == newTimer then
            gMediaRoomDebounceTimers[roomID] = nil
        end
        if gMQTTConnected then
            PublishMediaRoomState(roomID)
        end
    end, false)  -- false = non-repeating
    gMediaRoomDebounceTimers[roomID] = newTimer
end

-- Media Room Auto-Discovery
function PublishMediaRoomDiscovery(roomID)
    local roomName = C4:GetDeviceDisplayName(roomID)
    if not roomName then
        LogError("Media room " .. roomID .. " not found")
        return false
    end

    local uniqueID = "control4_room_" .. roomID
    local deviceName = roomName .. " Media"
    local objectID = SanitizeEntityName(deviceName)
    local configTopic = "homeassistant/media_player/control4_room_" .. roomID .. "/config"
    local stateTopic = "homeassistant/media_player/control4_room_" .. roomID .. "/state"
    local commandTopic = "homeassistant/media_player/control4_room_" .. roomID .. "/set"
    local availabilityTopic = "homeassistant/media_player/control4_room_" .. roomID .. "/availability"

    -- Build discovery payload for Home Assistant MQTT media player
    -- Note: MQTT media_player has limited discovery support, so we keep it minimal
    -- Availability: the mqtt_media_player custom component reads one availability_topic, so that is
    -- the bridge's (the room's own topic only ever says "online"). The "availability" list (bridge
    -- and room, both must be online) is there for a player that reads the standard form.
    local discoveryPayload = string.format([[{
  "name": "%s",
  "object_id": "%s",
  "unique_id": "%s",
  "state_topic": "%s",
  "command_topic": "%s",
  "availability_topic": "%s",
  "payload_available": "online",
  "payload_not_available": "offline",
  "availability": [{"topic": "%s"}, {"topic": "%s"}],
  "availability_mode": "all",
  "device": {
    "identifiers": ["%s"],
    "name": "%s",
    "manufacturer": "Control4",
    "model": "Media Room"
  }
}]], EscapeJSON(deviceName), objectID, uniqueID, stateTopic, commandTopic, BRIDGE_STATUS_TOPIC,
     BRIDGE_STATUS_TOPIC, availabilityTopic, uniqueID, EscapeJSON(deviceName))

    Log("Publishing media room auto-discovery for: " .. roomName)
    Log("  Config Topic: " .. configTopic)

    if PublishMQTT(configTopic, discoveryPayload, 1, true) then
        Log("Media room discovery published successfully")

        -- Publish availability
        PublishMQTT(availabilityTopic, "online", 1, true)

        -- Publish initial state
        PublishMediaRoomState(roomID)
        return true
    else
        LogError("Failed to publish media room discovery")
        return false
    end
end

-- Publish Contact Sensor Discovery (MQTT auto-discovery for Home Assistant)
function PublishContactSensorDiscovery(deviceID)
    if not gMQTTConnected then
        return false
    end

    local deviceInfo = gContactSensorDevices[deviceID]
    if not deviceInfo then
        LogError("Contact sensor " .. deviceID .. " not in device map")
        return false
    end

    -- Get naming using helper function
    local customName, nameSuffix, deviceName = GetContactSensorNaming(deviceID)
    if not deviceName then
        LogError("No custom name found for contact sensor " .. deviceID)
        return false
    end

    -- Build all entity names using helper function
    local entities = BuildContactSensorEntityNames(customName, nameSuffix)

    local deviceIdentifier = "control4_contact_" .. deviceID
    Log("Publishing contact sensor auto-discovery for: " .. deviceName .. " (ID: " .. deviceID .. ")")

    -- Device payload (shared by all entities)
    local devicePayload = string.format([[{
    "identifiers": ["%s"],
    "name": "%s",
    "manufacturer": "Control4",
    "model": "Wireless Contact Sensor"
  }]], deviceIdentifier, EscapeJSON(deviceName))

    -- Publish discovery for each bound contact input (binary_sensor)
    for bindingID in pairs(deviceInfo.bindings) do
        local stateEntity = GetContactStateEntity(bindingID)
        local uniqueID = string.format("control4_contact_%d_%d", deviceID, bindingID)
        local configTopic = string.format("homeassistant/binary_sensor/%s/config", stateEntity.id)
        local stateTopic = string.format("homeassistant/binary_sensor/%s/state", stateEntity.id)

        local discoveryPayload = string.format([[{
  "name": "%s",
  "object_id": "%s",
  "default_entity_id": "%s",
  "unique_id": "%s",
  "state_topic": "%s",
  "device_class": "door",
  "payload_on": "ON",
  "payload_off": "OFF",
  "device": %s
}]], EscapeJSON(stateEntity.name), stateEntity.id, DefaultEntityID("binary_sensor", stateEntity.id, deviceID), uniqueID, stateTopic, devicePayload)

        PublishMQTT(configTopic, WithAvailability(discoveryPayload), 1, true)
        Log("  Published binary_sensor discovery: " .. stateEntity.name)
    end

    -- Publish battery level discovery (sensor), if this sensor has a battery
    if ReadContactVariable(deviceID, VARIABLE_IDS.CONTACT_BATTERY_LEVEL) then
        local batteryConfigTopic = string.format("homeassistant/sensor/%s/config", entities.battery.id)
        local batteryStateTopic = string.format("homeassistant/sensor/%s/state", entities.battery.id)
        local batteryPayload = string.format([[{
  "name": "%s",
  "object_id": "%s",
  "default_entity_id": "%s",
  "unique_id": "control4_%d_battery",
  "state_topic": "%s",
  "device_class": "battery",
  "unit_of_measurement": "%%",
  "state_class": "measurement",
  "device": %s
}]], EscapeJSON(entities.battery.name), entities.battery.id, DefaultEntityID("sensor", entities.battery.id, deviceID), deviceID, batteryStateTopic, devicePayload)

        PublishMQTT(batteryConfigTopic, WithAvailability(batteryPayload), 1, true)
        Log("  Published battery sensor discovery")
    end

    -- Publish battery voltage discovery (sensor), if this sensor reports it
    if ReadContactVariable(deviceID, VARIABLE_IDS.CONTACT_BATTERY_VOLTAGE) then
        local voltageConfigTopic = string.format("homeassistant/sensor/%s/config", entities.voltage.id)
        local voltageStateTopic = string.format("homeassistant/sensor/%s/state", entities.voltage.id)
        local voltagePayload = string.format([[{
  "name": "%s",
  "object_id": "%s",
  "default_entity_id": "%s",
  "unique_id": "control4_%d_battery_voltage",
  "state_topic": "%s",
  "device_class": "voltage",
  "unit_of_measurement": "mV",
  "state_class": "measurement",
  "device": %s
}]], EscapeJSON(entities.voltage.name), entities.voltage.id, DefaultEntityID("sensor", entities.voltage.id, deviceID), deviceID, voltageStateTopic, devicePayload)

        PublishMQTT(voltageConfigTopic, WithAvailability(voltagePayload), 1, true)
        Log("  Published battery voltage sensor discovery")
    end

    -- Publish temperature discovery (sensor), if this sensor reports it
    if ReadContactTemperature(deviceID) then
        local tempConfigTopic = string.format("homeassistant/sensor/%s/config", entities.temperature.id)
        local tempStateTopic = string.format("homeassistant/sensor/%s/state", entities.temperature.id)
        local tempPayload = string.format([[{
  "name": "%s",
  "object_id": "%s",
  "default_entity_id": "%s",
  "unique_id": "control4_%d_temperature",
  "state_topic": "%s",
  "device_class": "temperature",
  "unit_of_measurement": "°F",
  "state_class": "measurement",
  "device": %s
}]], EscapeJSON(entities.temperature.name), entities.temperature.id, DefaultEntityID("sensor", entities.temperature.id, deviceID), deviceID, tempStateTopic, devicePayload)

        PublishMQTT(tempConfigTopic, WithAvailability(tempPayload), 1, true)
        Log("  Published temperature sensor discovery")
    end

    -- Publish initial states
    PublishContactSensorState(deviceID)

    Log("Contact sensor discovery complete for device " .. deviceID)
    return true
end

-- Publish Contact Sensor State (battery + temperature for all contacts on a device)
function PublishContactSensorState(deviceID)
    if not gMQTTConnected then
        return false
    end

    local deviceInfo = gContactSensorDevices[deviceID]
    if not deviceInfo then
        LogError("Contact sensor " .. deviceID .. " not in device map")
        return false
    end

    -- Get naming using helper function
    local customName, nameSuffix, deviceName = GetContactSensorNaming(deviceID)
    if not deviceName then
        return false
    end

    -- Build all entity names using helper function
    local entities = BuildContactSensorEntityNames(customName, nameSuffix)

    -- Publish battery state, if this sensor has a battery
    local batteryLevel = ReadContactVariable(deviceID, VARIABLE_IDS.CONTACT_BATTERY_LEVEL)
    if batteryLevel then
        local batteryTopic = string.format("homeassistant/sensor/%s/state", entities.battery.id)
        PublishMQTT(batteryTopic, batteryLevel, 0, true)
    end

    -- Publish battery voltage, if this sensor reports it
    local batteryVoltage = ReadContactVariable(deviceID, VARIABLE_IDS.CONTACT_BATTERY_VOLTAGE)
    if batteryVoltage then
        local voltageTopic = string.format("homeassistant/sensor/%s/state", entities.voltage.id)
        PublishMQTT(voltageTopic, batteryVoltage, 0, true)
    end

    -- Publish temperature, if this sensor reports it
    local temperature = ReadContactTemperature(deviceID)
    if temperature then
        local tempTopic = string.format("homeassistant/sensor/%s/state", entities.temperature.id)
        PublishMQTT(tempTopic, temperature, 0, true)
    end

    -- Publish contact states for all bound contacts
    for bindingID in pairs(deviceInfo.bindings) do
        local contactState = gContactSensorStates[bindingID]
        if contactState and contactState.state then
            local stateTopic = string.format("homeassistant/binary_sensor/%s/state", GetContactStateEntity(bindingID).id)
            PublishMQTT(stateTopic, ContactStatePayload(contactState.state), 1, true)  -- QoS 1, retained
        end
    end

    Log("Published contact sensor state for device " .. deviceID .. " (" .. deviceName .. ")")
    return true
end

-- A watched change is published at once, in the same callback (no timer, no window). Several
-- variables of one light change together (level, state, color): each publishes, but a payload
-- identical to the last one sent on that topic is skipped.
function RunSkippingUnchanged(fn)
    gSkipUnchanged = true
    local ok, err = pcall(fn)
    gSkipUnchanged = false
    if not ok then
        LogError("State publish failed: " .. tostring(err))
    end
end

-- Controller callbacks are protected: an error in one change must not stop the next
function OnWatchedVariableChanged(idDevice, idVariable, strValue)
    local ok, err = pcall(HandleWatchedVariableChanged, idDevice, idVariable, strValue)
    if not ok then
        LogError("OnWatchedVariableChanged(" .. tostring(idDevice) .. ", " .. tostring(idVariable) .. "): " .. tostring(err))
    end
end

function HandleWatchedVariableChanged(idDevice, idVariable, strValue)
    -- Note: idDevice can be either a device ID or proxy ID depending on which variable changed
    -- - For light/switch state variables (LIGHT_LEVEL, SWITCH_STATE): idDevice is the PROXY ID
    -- - For LED color variables: idDevice is the DEVICE ID
    -- - For thermostat state variables (temperature, mode, etc.): idDevice is the PROXY ID
    -- - For thermostat LED color variable: idDevice is the DEVICE ID
    -- - For media rooms: idDevice is the same for both device and proxy

    -- A light driver's SETTINGS_CHANGED: checked first, because the controller numbers a driver's
    -- own variables from 1001, the same IDs as the light proxy variables below
    local changedDevice = tonumber(idDevice)
    if changedDevice and gSettingsChangedVars[changedDevice] == tonumber(idVariable) then
        PublishLightV2SettingsChanged(changedDevice)
        return
    end

    -- Power / energy a light's or switch's driver reports in its own variables
    if changedDevice and gEnergyVars[changedDevice] and gEnergyVars[changedDevice][tonumber(idVariable)] then
        if gMQTTConnected then
            PublishEnergyState(changedDevice, idVariable, strValue)
        end
        return
    end

    -- Determine the actual device ID we store in our lists
    local actualDeviceID = idDevice
    local deviceName = C4:GetDeviceDisplayName(idDevice) or "Unknown"

    -- Check what type of variable this is and find the device ID accordingly
    local lookup = GetDeviceLookup()
    if LIGHT_PROXY_VARIABLES[idVariable] then
        -- State variables and advanced control variables come from proxy ID - need to find device ID
        -- (proxy -> monitored light, switch or outlet, built once: see GetDeviceLookup)
        actualDeviceID = lookup.lightProxy[changedDevice] or idDevice
    elseif idVariable == VARIABLE_IDS.TEMPERATURE_F or
           idVariable == VARIABLE_IDS.HEAT_SETPOINT_F or
           idVariable == VARIABLE_IDS.COOL_SETPOINT_F or
           idVariable == VARIABLE_IDS.HVAC_MODE or
           idVariable == VARIABLE_IDS.FAN_MODE or
           idVariable == VARIABLE_IDS.HVAC_STATE or
           idVariable == VARIABLE_IDS.HUMIDITY then
        -- Thermostat state variables come from proxy ID - need to find device ID
        actualDeviceID = lookup.thermostatProxy[changedDevice] or idDevice
    end

    -- Now check if actualDeviceID is monitored
    local actualID = tonumber(actualDeviceID)
    local isLight = actualID ~= nil and lookup.sets.LIGHT[actualID] == true
    local isSwitch = actualID ~= nil and lookup.sets.SWITCH[actualID] == true
    local isOutlet = actualID ~= nil and lookup.sets.OUTLET[actualID] == true
    local isThermostat = actualID ~= nil and lookup.sets.THERMOSTAT[actualID] == true
    local isMediaRoom = actualID ~= nil and lookup.sets.MEDIA_ROOM[actualID] == true
    local isContactSensor = actualID ~= nil and lookup.sets.CONTACT_SENSOR[actualID] == true

    if not isLight and not isSwitch and not isOutlet and not isThermostat and not isMediaRoom and not isContactSensor then
        return  -- Not monitoring this device
    end

    -- Handle light variables (Light V2 color lights also report their color). Several of these
    -- change together for one light: each is published at once; repeated payloads are skipped.
    if isLight and (idVariable == VARIABLE_IDS.LIGHT_LEVEL or idVariable == VARIABLE_IDS.SWITCH_STATE or
                    idVariable == VARIABLE_IDS.CURRENT_CHROMATICITY or idVariable == VARIABLE_IDS.CURRENT_COLOR_MODE or
                    idVariable == VARIABLE_IDS.CURRENT_CCT) then
        if gMQTTConnected then
            RunSkippingUnchanged(function() PublishLightState(actualDeviceID) end)
        end
        local timestamp = os.date("%H:%M:%S")
        C4:UpdateProperty("Last Event", deviceName .. " @ " .. timestamp)

    -- Light V2 capabilities changed (color support, color temperature range): update the entity if
    -- what its discovery config is built from changed, and look again for SETTINGS_CHANGED (a light
    -- driver that has just started reports its capabilities then)
    elseif isLight and idVariable == VARIABLE_IDS.DYNAMIC_CAPABILITIES then
        ResolveSettingsChangedVariable(actualDeviceID)
        if gMQTTConnected then
            local proxyID = GetProxyID(actualDeviceID)
            if gLightColorCapsSig[actualID] ~= LightDiscoverySignature(proxyID) then
                PublishLightDiscovery(actualDeviceID)
            end
            RunSkippingUnchanged(function() PublishLightState(actualDeviceID) end)
        end

    -- Handle switch variables
    elseif isSwitch and idVariable == VARIABLE_IDS.SWITCH_STATE then
        if gMQTTConnected then
            RunSkippingUnchanged(function() PublishSwitchState(actualDeviceID) end)
        end
        local timestamp = os.date("%H:%M:%S")
        C4:UpdateProperty("Last Event", deviceName .. " @ " .. timestamp)

    -- Handle outlet variables
    elseif isOutlet and idVariable == VARIABLE_IDS.SWITCH_STATE then
        if gMQTTConnected then
            RunSkippingUnchanged(function() PublishOutletState(actualDeviceID) end)
        end
        local timestamp = os.date("%H:%M:%S")
        C4:UpdateProperty("Last Event", deviceName .. " @ " .. timestamp)

    -- Handle thermostat variables
    elseif isThermostat and (idVariable == VARIABLE_IDS.TEMPERATURE_F or
                              idVariable == VARIABLE_IDS.HEAT_SETPOINT_F or
                              idVariable == VARIABLE_IDS.COOL_SETPOINT_F or
                              idVariable == VARIABLE_IDS.HVAC_MODE or
                              idVariable == VARIABLE_IDS.FAN_MODE or
                              idVariable == VARIABLE_IDS.HVAC_STATE or
                              idVariable == VARIABLE_IDS.HUMIDITY) then
        if gMQTTConnected then
            PublishThermostatState(actualDeviceID)
        end
        local timestamp = os.date("%H:%M:%S")
        C4:UpdateProperty("Last Event", deviceName .. " @ " .. timestamp)

    -- Handle thermostat button LED color variable
    elseif isThermostat and idVariable == VARIABLE_IDS.THERMOSTAT_BUTTON_LED_COLOR then
        if IsLEDControlEnabled() and gMQTTConnected then
            PublishThermostatButtonLEDState(actualDeviceID)
        end
        local timestamp = os.date("%H:%M:%S")
        C4:UpdateProperty("Last Event", deviceName .. " LED @ " .. timestamp)

    -- Handle media room variables
    elseif isMediaRoom and (idVariable == VARIABLE_IDS.ROOM_POWER_STATE or
                             idVariable == VARIABLE_IDS.ROOM_CURRENT_VOLUME or
                             idVariable == VARIABLE_IDS.ROOM_IS_MUTED) then
        if gMQTTConnected then
            -- Use debounced publish to avoid rapid-fire updates during volume changes
            PublishMediaRoomStateDebounced(actualDeviceID)
        end
        local timestamp = os.date("%H:%M:%S")
        C4:UpdateProperty("Last Event", deviceName .. " @ " .. timestamp)

    -- Handle contact sensor variables (battery, voltage, temperature)
    elseif isContactSensor and (idVariable == VARIABLE_IDS.CONTACT_BATTERY_LEVEL or
                                 idVariable == VARIABLE_IDS.CONTACT_BATTERY_VOLTAGE or
                                 idVariable == VARIABLE_IDS.CONTACT_TEMPERATURE or
                                 idVariable == VARIABLE_IDS.CONTACT_LOCAL_TEMP or
                                 idVariable == VARIABLE_IDS.CONTACT_REMOTE_TEMP) then
        if gMQTTConnected then
            -- Get naming using helper function
            local customName, nameSuffix, deviceName = GetContactSensorNaming(actualDeviceID)
            if customName then
                -- Build entity names using helper function
                local entities = BuildContactSensorEntityNames(customName, nameSuffix)

                -- Publish battery level
                if idVariable == VARIABLE_IDS.CONTACT_BATTERY_LEVEL then
                    local topic = string.format("homeassistant/sensor/%s/state", entities.battery.id)
                    PublishMQTT(topic, strValue, 0, true)

                -- Publish battery voltage
                elseif idVariable == VARIABLE_IDS.CONTACT_BATTERY_VOLTAGE then
                    local topic = string.format("homeassistant/sensor/%s/state", entities.voltage.id)
                    PublishMQTT(topic, strValue, 0, true)

                -- Publish temperature (all temperature variables go to same topic)
                elseif idVariable == VARIABLE_IDS.CONTACT_TEMPERATURE or
                       idVariable == VARIABLE_IDS.CONTACT_LOCAL_TEMP or
                       idVariable == VARIABLE_IDS.CONTACT_REMOTE_TEMP then
                    local topic = string.format("homeassistant/sensor/%s/state", entities.temperature.id)
                    PublishMQTT(topic, strValue, 0, true)
                end
            end
        end
        local timestamp = os.date("%H:%M:%S")
        C4:UpdateProperty("Last Event", deviceName .. " @ " .. timestamp)

    -- Handle LED color variables (idDevice is already the device ID for these)
    elseif (isLight or isSwitch) and IsLEDControlEnabled() and gMQTTConnected and
           (idVariable == VARIABLE_IDS.TOP_BUTTON_ON_COLOR or
            idVariable == VARIABLE_IDS.TOP_BUTTON_OFF_COLOR or
            idVariable == VARIABLE_IDS.BOTTOM_BUTTON_ON_COLOR or
            idVariable == VARIABLE_IDS.BOTTOM_BUTTON_OFF_COLOR) then

        -- LED variables come from device ID directly, use actualDeviceID
        if idVariable == VARIABLE_IDS.TOP_BUTTON_ON_COLOR then
            PublishLEDState(actualDeviceID, "top_on", VARIABLE_IDS.TOP_BUTTON_ON_COLOR)
        elseif idVariable == VARIABLE_IDS.TOP_BUTTON_OFF_COLOR then
            PublishLEDState(actualDeviceID, "top_off", VARIABLE_IDS.TOP_BUTTON_OFF_COLOR)
        elseif idVariable == VARIABLE_IDS.BOTTOM_BUTTON_ON_COLOR then
            PublishLEDState(actualDeviceID, "bottom_on", VARIABLE_IDS.BOTTOM_BUTTON_ON_COLOR)
        elseif idVariable == VARIABLE_IDS.BOTTOM_BUTTON_OFF_COLOR then
            PublishLEDState(actualDeviceID, "bottom_off", VARIABLE_IDS.BOTTOM_BUTTON_OFF_COLOR)
        end

    -- Handle advanced dimmer control variables (these come from proxy ID, need reverse lookup)
    elseif isLight and IsAdvancedDimmerControlEnabled() and gMQTTConnected and
           GetDimmerControlForVariable(GetProxyID(actualDeviceID), idVariable) then

        -- Advanced control variables come from proxy ID, so actualDeviceID should be the device ID
        -- Publish the individual control's state (V1 and Light V2 keep them under different IDs)
        local proxyID = GetProxyID(actualDeviceID)
        if IsLightV2(proxyID) then
            -- Light V2: the Default On preset changed. The other settings have no variable to
            -- watch, so read them all again with it.
            RefreshLightV2Settings(proxyID)
            PublishDimmerAdvancedControlStates(actualDeviceID)
            PublishAllLEDStates(actualDeviceID)
        else
            local suffix = GetDimmerControlForVariable(proxyID, idVariable)
            local value = GetDimmerControlValue(actualDeviceID, proxyID, suffix) or "0"
            local stateTopic = "homeassistant/number/control4_" .. actualDeviceID .. "_" .. suffix .. "/state"
            PublishMQTT(stateTopic, value, 1, true)  -- QoS 1, retained
        end

        local timestamp = os.date("%H:%M:%S")
        C4:UpdateProperty("Last Event", deviceName .. " @ " .. timestamp)
    end
end

-- Handle device events from media rooms (play, pause, stop, etc.)
-- This allows us to track accurate playback state
function OnDeviceEvent(idDevice, eventId)
    local ok, err = pcall(HandleDeviceEvent, idDevice, eventId)
    if not ok then
        LogError("OnDeviceEvent(" .. tostring(idDevice) .. ", " .. tostring(eventId) .. "): " .. tostring(err))
    end
end

function HandleDeviceEvent(idDevice, eventId)
    -- Check if this is a monitored media room
    if not IsDeviceMonitored(idDevice, "MEDIA_ROOM") then
        return  -- Not a monitored media room
    end

    local roomName = C4:GetDeviceDisplayName(idDevice) or "Unknown Room"
    local eventName = "Unknown"
    local newState = nil

    -- Get current state for toggle logic
    local currentState = gMediaRoomPlaybackState[idDevice] or "idle"

    -- Map event ID to name and determine new playback state
    -- Note: C4 play/pause buttons toggle based on current state
    if eventId == ROOM_EVENTS.PLAY then
        eventName = "PLAY"
        newState = (currentState == "playing") and "paused" or "playing"
    elseif eventId == ROOM_EVENTS.PAUSE then
        eventName = "PAUSE"
        newState = (currentState == "paused") and "playing" or "paused"
    elseif eventId == ROOM_EVENTS.STOP then
        eventName = "STOP"
        newState = "idle"
    elseif eventId == ROOM_EVENTS.SKIP_FWD then
        eventName = "SKIP_FWD"
    elseif eventId == ROOM_EVENTS.SKIP_REV then
        eventName = "SKIP_REV"
    elseif eventId == ROOM_EVENTS.SCAN_FWD or eventId == ROOM_EVENTS.START_SCAN_FWD then
        eventName = "SCAN_FWD"
        newState = "playing"
    elseif eventId == ROOM_EVENTS.STOP_SCAN_FWD then
        eventName = "STOP_SCAN_FWD"
        newState = "paused"
    elseif eventId == ROOM_EVENTS.SCAN_REV or eventId == ROOM_EVENTS.START_SCAN_REV then
        eventName = "SCAN_REV"
        newState = "playing"
    elseif eventId == ROOM_EVENTS.STOP_SCAN_REV then
        eventName = "STOP_SCAN_REV"
        newState = "paused"
    else
        eventName = "UNKNOWN_EVENT_" .. eventId
        Log("WARNING: Unrecognized media room event: " .. eventId)
    end

    -- Update and publish state if changed
    if newState then
        gMediaRoomPlaybackState[idDevice] = newState
        Log(roomName .. " - " .. eventName .. " → " .. newState)

        if gMQTTConnected then
            PublishMediaRoomStateDebounced(idDevice)
        end
    else
        Log(roomName .. " - " .. eventName)
    end

    -- Update last event property
    local timestamp = os.date("%H:%M:%S")
    C4:UpdateProperty("Last Event", roomName .. " - " .. eventName .. " @ " .. timestamp)
end

-- ReceivedFromProxy: Called when a bound contact sensor changes state
function ReceivedFromProxy(idBinding, strCommand, tParams)
    local ok, err = pcall(HandleReceivedFromProxy, idBinding, strCommand, tParams)
    if not ok then
        LogError("ReceivedFromProxy(" .. tostring(idBinding) .. ", " .. tostring(strCommand) .. "): " .. tostring(err))
    end
end

function HandleReceivedFromProxy(idBinding, strCommand, tParams)
    Log("========================================")
    Log("ReceivedFromProxy CALLED!")
    Log("  Binding ID: " .. tostring(idBinding))
    Log("  Command: " .. tostring(strCommand))
    Log("  Params: " .. tostring(tParams))

    if tParams then
        for k, v in pairs(tParams) do
            Log("    " .. tostring(k) .. " = " .. tostring(v))
        end
    end

    -- Check if this is one of our contact sensor bindings (300-319)
    if idBinding >= 300 and idBinding <= 319 then
        -- Look up the binding mapping
        local binding = gContactSensorBindings[idBinding]

        if not binding then
            Log("WARNING: Binding " .. idBinding .. " is not configured in binding map")
            Log("Add this binding to 'Contact Sensor Binding Map' property")
            Log("Format: deviceID:binding:name (example: 720:302:Garage Door)")
            return
        end

        local deviceID = binding.deviceID
        local customName = binding.customName

        -- This contact's own entity (a device can have several contacts)
        local stateEntity = GetContactStateEntity(idBinding)

        -- Determine state from command
        -- Contact sensors send "OPENED" or "CLOSED" commands
        local state = "unknown"
        local cmdUpper = string.upper(strCommand or "")

        if string.find(cmdUpper, "OPEN") then
            state = "open"
        elseif string.find(cmdUpper, "CLOS") then
            state = "closed"
        else
            state = "unknown"
            Log("WARNING: Unknown contact sensor command: " .. tostring(strCommand))
        end

        -- Cache the state
        gContactSensorStates[idBinding] = {
            deviceID = deviceID,
            customName = customName,
            entityID = stateEntity.id,
            state = state,
            timestamp = os.time()
        }

        Log(string.format("Contact Sensor: %s (Device %d, Binding %d) → %s", customName, deviceID, idBinding, state))
        C4:UpdateProperty("Last Event", customName .. " " .. state .. " @ " .. os.date("%H:%M:%S"))

        -- Publish to MQTT using entity name
        if gMQTTConnected then
            local topic = string.format("homeassistant/binary_sensor/%s/state", stateEntity.id)
            local payload = ContactStatePayload(state)
            PublishMQTT(topic, payload, 1, true)  -- QoS 1, retained
            Log("Published to MQTT: " .. topic .. " = " .. payload)
        end
    else
        Log("WARNING: Received from unknown binding: " .. tostring(idBinding))
    end

    Log("========================================")
end

function PublishLightState(lightID)
    -- lightID is the device ID - get proxy ID for reading state variables
    local proxyID = GetProxyID(lightID)
    local lightName = C4:GetDeviceDisplayName(proxyID)

    if not lightName then
        -- A name that can't be read once (a project still loading, a driver restarting) is no
        -- reason to drop the light: only 3 misses at least a minute apart count as deleted. The
        -- Cleanup Deleted Devices action removes at once.
        local id = tonumber(lightID)
        local now = os.time()
        local miss = gLightMisses[id] or {count = 0, last = nil}
        if not miss.last or now - miss.last >= TIMER_INTERVALS.DELETED_MISS_SPACING then
            miss.count = miss.count + 1
            miss.last = now
        end
        gLightMisses[id] = miss
        LogError("Light " .. lightID .. " not found - may have been deleted (miss " .. miss.count .. " of 3)")
        if miss.count >= 3 then
            gLightMisses[id] = nil
            RemoveDeletedDevice(lightID)
        end
        return false
    end
    gLightMisses[tonumber(lightID)] = nil

    local level = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.LIGHT_LEVEL)
    local brightness = 0
    local state = "OFF"
    local deviceType = "dimmer"

    if level and level ~= "" then
        deviceType = "dimmer"
        local c4Level = tonumber(level) or 0
        -- Convert C4 (0-100) to HA (0-255)
        brightness = math.floor((c4Level * 255) / 100)
        state = (c4Level > 0) and "ON" or "OFF"
    else
        local switchState = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.SWITCH_STATE)
        if switchState then
            deviceType = "switch"
            if switchState == "1" or switchState == "true" or switchState == "ON" or switchState == "True" then
                state = "ON"
                brightness = 255  -- Full brightness for switches
            else
                state = "OFF"
                brightness = 0
            end
        else
            LogError("Could not read state for device " .. lightID)
            return false
        end
    end

    -- Use device ID for topic (consistent with discovery)
    local topic = "homeassistant/light/control4_" .. lightID .. "/state"

    -- Determine color mode: "onoff" for switches, "brightness" for dimmers
    local colorMode = (deviceType == "dimmer") and "brightness" or "onoff"

    local payload
    local caps = (deviceType == "dimmer") and GetLightColorCaps(proxyID)
    if caps then
        -- Light V2 color light: also the color it's showing, a color temperature or a chromaticity
        local lightState = {state = state, brightness = brightness}
        -- Color temperature if either mode says so, or if the color is on the white curve: when a
        -- color temperature fade ends, the proxy has been seen to report the color as full color
        -- (mode 0), which made Home Assistant swap its color temperature slider for a color wheel
        local chromaticity = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.CURRENT_CHROMATICITY)
        local modeVar = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.CURRENT_COLOR_MODE)
        local cctVar = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.CURRENT_CCT)
        local x, y, mode = ParseChromaticity(chromaticity)
        local kelvin = tonumber(cctVar or "")
        local isColorTemp = mode == 1 or tonumber(modeVar or "") == 1
        if not isColorTemp and IsOnWhiteCurve(x, y) then
            isColorTemp = true
            kelvin = C4:ColorXYtoCCT(x, y)  -- the CCT variable may still be from an earlier color
        end
        Log(string.format("  Current color: %s, mode %s, %s K", tostring(chromaticity), tostring(modeVar), tostring(cctVar)))
        if caps.minK and (isColorTemp or not caps.color or not x) then
            lightState.color_mode = "color_temp"
            if kelvin and kelvin > 0 then
                lightState.color_temp = math.max(caps.minK, math.min(caps.maxK, math.floor(kelvin + 0.5)))
            end
        else
            lightState.color_mode = "xy"
            if x then
                lightState.color = {x = x, y = y}
            end
        end
        colorMode = lightState.color_mode
        payload = EncodeJSON(lightState)
    else
        payload = string.format(
            '{"state":"%s","brightness":%d,"color_mode":"%s"}',
            state, brightness, colorMode
        )
    end

    Log("Publishing light state:")
    Log("  Light: " .. lightName .. " (ID: " .. lightID .. ")")
    Log("  Type: " .. deviceType)
    Log("  C4 Level: " .. (level or "N/A"))
    Log("  HA Brightness: " .. brightness)
    Log("  State: " .. state)
    if caps then
        Log("  Color: " .. payload)
    end
    Log("  Topic: " .. topic)
    
    return PublishMQTT(topic, payload, 0, true)
end

-- Helper function to sanitize device names for Home Assistant entity IDs
function SanitizeEntityName(name)
    -- Convert to lowercase and replace spaces and special chars with underscores
    local sanitized = name:lower()
    sanitized = sanitized:gsub("[%s%-%.]+", "_")  -- Replace spaces, hyphens, dots with underscores
    sanitized = sanitized:gsub("[^%w_]", "")      -- Remove any non-alphanumeric chars except underscores
    sanitized = sanitized:gsub("_+", "_")         -- Collapse multiple underscores
    sanitized = sanitized:gsub("^_", "")          -- Remove leading underscore
    sanitized = sanitized:gsub("_$", "")          -- Remove trailing underscore
    return sanitized
end

-- The entity ID a new Home Assistant entity should get. Home Assistant 2026.4 stopped reading
-- object_id, which stays in the payloads for older versions. It never renames existing entities.
-- A name with no usable characters (all non-Latin, say) falls back to the device ID.
function DefaultEntityID(domain, objectID, deviceID)
    if objectID == "" then
        objectID = "control4_" .. deviceID
    end
    return domain .. "." .. objectID
end

-- Every entity is unavailable in Home Assistant while the bridge is offline (BRIDGE_STATUS_TOPIC)
function AddAvailability(config)
    config.availability_topic = BRIDGE_STATUS_TOPIC
    config.payload_available = "online"
    config.payload_not_available = "offline"
    return config
end

-- The same for a discovery payload built as JSON text: added at the start of the object
local AVAILABILITY_JSON = '\n  "availability_topic": "' .. BRIDGE_STATUS_TOPIC .. '",' ..
    '\n  "payload_available": "online",\n  "payload_not_available": "offline",'
function WithAvailability(json)
    return (string.gsub(json, "^(%s*){", "%1{" .. AVAILABILITY_JSON, 1))
end

-- Home Assistant Auto-Discovery
function PublishLightDiscovery(lightID)
    -- lightID is the device ID - get proxy ID for reading variables and display name
    local proxyID = GetProxyID(lightID)
    local lightName = C4:GetDeviceDisplayName(proxyID)

    if not lightName then
        return false
    end

    local level = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.LIGHT_LEVEL)
    local isDimmer = (level and level ~= "")

    -- Use device ID for topic to maintain consistency across renames
    -- This ensures renaming a device updates the same entity instead of creating a new one
    local discoveryTopic = "homeassistant/light/control4_" .. lightID .. "/config"

    -- Sanitize the device name for use as entity_id
    local objectID = SanitizeEntityName(lightName)

    -- Light V2 color lights: color temperature (in Kelvin) and/or full color (CIE xy)
    local caps = isDimmer and GetLightColorCaps(proxyID)
    local colorModes = isDimmer and {"brightness"} or {"onoff"}
    if caps then
        colorModes = {}
        if caps.minK then
            table.insert(colorModes, "color_temp")
        end
        if caps.color then
            table.insert(colorModes, "xy")
        end
    end

    -- Build discovery payload
    local config = {
        name = JSON_NULL,  -- null = entity represents the device itself, displays as device name only
        object_id = objectID,
        default_entity_id = DefaultEntityID("light", objectID, lightID),
        unique_id = "control4_light_" .. lightID,
        state_topic = "homeassistant/light/control4_" .. lightID .. "/state",
        command_topic = "homeassistant/light/control4_" .. lightID .. "/set",
        schema = "json",
        brightness = isDimmer,
        optimistic = false,
        supported_color_modes = colorModes,
        device = {
            identifiers = {"control4_" .. lightID},
            name = lightName,
            manufacturer = "Control4",
            model = caps and "Color Light" or (isDimmer and "Dimmer" or "Switch")
        }
    }
    if caps and caps.minK then
        config.color_temp_kelvin = true
        config.min_kelvin = caps.minK
        config.max_kelvin = caps.maxK
    end
    
    local payload = EncodeJSON(AddAvailability(config))

    Log("Publishing auto-discovery for: " .. lightName)
    Log("  Topic: " .. discoveryTopic)

    -- What this config was built from: a capabilities change republishes it only if this changes
    gLightColorCapsSig[tonumber(lightID)] = LightDiscoverySignature(proxyID)

    -- Use QoS 1 for reliable discovery message delivery
    local ok = PublishMQTT(discoveryTopic, payload, 1, true)
    PublishEnergyDiscovery(lightID)
    return ok
end

-- What a light's discovery config depends on: dimmer or not, and its color capabilities
function LightDiscoverySignature(proxyID)
    local level = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.LIGHT_LEVEL)
    if not (level and level ~= "") then
        return "switch"
    end
    return "dimmer:" .. ColorCapsSignature(proxyID)
end

-- Switch State Publishing
function PublishSwitchState(switchID)
    -- switchID is the device ID - get proxy ID for reading state variables
    local proxyID = GetProxyID(switchID)
    local switchName = C4:GetDeviceDisplayName(proxyID)

    if not switchName then
        LogError("Switch " .. switchID .. " not found")
        return false
    end

    local switchState = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.SWITCH_STATE)
    local state = "OFF"

    if switchState == "1" or switchState == "true" or switchState == "ON" or switchState == "True" then
        state = "ON"
    end

    local topic = "homeassistant/switch/control4_" .. switchID .. "/state"

    Log("Publishing switch state: " .. switchName .. " - " .. state)

    return PublishMQTT(topic, state, 0, true)
end

-- Switch Auto-Discovery
function PublishSwitchDiscovery(switchID)
    local proxyID = GetProxyID(switchID)
    local switchName = C4:GetDeviceDisplayName(proxyID)

    if not switchName then
        return false
    end

    local discoveryTopic = "homeassistant/switch/control4_" .. switchID .. "/config"

    -- Sanitize the device name for use as entity_id
    local objectID = SanitizeEntityName(switchName)

    local config = {
        name = JSON_NULL,  -- null = entity represents the device itself, displays as device name only
        object_id = objectID,
        default_entity_id = DefaultEntityID("switch", objectID, switchID),
        unique_id = "control4_switch_" .. switchID,
        state_topic = "homeassistant/switch/control4_" .. switchID .. "/state",
        command_topic = "homeassistant/switch/control4_" .. switchID .. "/set",
        payload_on = "ON",
        payload_off = "OFF",
        optimistic = false,
        device = {
            identifiers = {"control4_" .. switchID},
            name = switchName,
            manufacturer = "Control4",
            model = "Switch"
        }
    }

    local payload = EncodeJSON(AddAvailability(config))
    Log("Publishing switch discovery: " .. switchName)

    local ok = PublishMQTT(discoveryTopic, payload, 1, true)
    PublishEnergyDiscovery(switchID)
    return ok
end

-- Outlet State Publishing
function PublishOutletState(outletID)
    -- outletID is the device ID - get proxy ID for reading state variables
    local proxyID = GetProxyID(outletID)
    local outletName = C4:GetDeviceDisplayName(proxyID)

    if not outletName then
        LogError("Outlet " .. outletID .. " not found")
        return false
    end

    local switchState = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.SWITCH_STATE)
    local state = "OFF"

    if switchState == "1" or switchState == "true" or switchState == "ON" or switchState == "True" then
        state = "ON"
    end

    local topic = "homeassistant/switch/control4_" .. outletID .. "/state"

    Log("Publishing outlet state: " .. outletName .. " - " .. state)

    return PublishMQTT(topic, state, 0, true)
end

-- Outlet Auto-Discovery
function PublishOutletDiscovery(outletID)
    local proxyID = GetProxyID(outletID)
    local outletName = C4:GetDeviceDisplayName(proxyID)

    if not outletName then
        return false
    end

    local discoveryTopic = "homeassistant/switch/control4_" .. outletID .. "/config"

    -- Sanitize the device name for use as entity_id
    local objectID = SanitizeEntityName(outletName)

    local config = {
        name = JSON_NULL,  -- null = entity represents the device itself, displays as device name only
        object_id = objectID,
        default_entity_id = DefaultEntityID("switch", objectID, outletID),
        unique_id = "control4_outlet_" .. outletID,
        state_topic = "homeassistant/switch/control4_" .. outletID .. "/state",
        command_topic = "homeassistant/switch/control4_" .. outletID .. "/set",
        payload_on = "ON",
        payload_off = "OFF",
        optimistic = false,
        device = {
            identifiers = {"control4_" .. outletID},
            name = outletName,
            manufacturer = "Control4",
            model = "Outlet Switch"
        }
    }

    local payload = EncodeJSON(AddAvailability(config))
    Log("Publishing outlet discovery: " .. outletName)

    return PublishMQTT(discoveryTopic, payload, 1, true)
end

-- LED Discovery and State Functions
function PublishLEDDiscovery(deviceID, deviceType)
    if not IsLEDControlEnabled() then
        return
    end

    local deviceName = C4:GetDeviceDisplayName(deviceID)
    if not deviceName then
        LogError("Could not get device name for " .. deviceID)
        return
    end

    -- A Light V2 light without top and bottom buttons (a Hue light) has no LEDs: remove any
    -- entities published for it before
    local proxyID = GetProxyID(deviceID)
    if IsLightV2(proxyID) then
        local settings = RefreshLightV2Settings(proxyID)
        if gSettingsCacheOnly and not settings then
            return  -- not read yet (automatic run): leave its LED entities as they are
        end
        if not (settings and settings.leds[0] and settings.leds[1]) then
            for _, suffix in ipairs({"top_on", "top_off", "bottom_on", "bottom_off"}) do
                PublishMQTT("homeassistant/text/control4_" .. deviceID .. "_" .. suffix .. "/config", "", 1, true)
            end
            return
        end
    end

    -- Define the 4 LED entities for this device
    local ledConfigs = {
        {
            suffix = "top_on",
            name = deviceName .. " - Top LED On",
            unique_id = "control4_" .. deviceID .. "_top_led_on",
            variable_id = VARIABLE_IDS.TOP_BUTTON_ON_COLOR,
            command = "SET_TOP_LED_ON"
        },
        {
            suffix = "top_off",
            name = deviceName .. " - Top LED Off",
            unique_id = "control4_" .. deviceID .. "_top_led_off",
            variable_id = VARIABLE_IDS.TOP_BUTTON_OFF_COLOR,
            command = "SET_TOP_LED_OFF"
        },
        {
            suffix = "bottom_on",
            name = deviceName .. " - Bottom LED On",
            unique_id = "control4_" .. deviceID .. "_bottom_led_on",
            variable_id = VARIABLE_IDS.BOTTOM_BUTTON_ON_COLOR,
            command = "SET_BOTTOM_LED_ON"
        },
        {
            suffix = "bottom_off",
            name = deviceName .. " - Bottom LED Off",
            unique_id = "control4_" .. deviceID .. "_bottom_led_off",
            variable_id = VARIABLE_IDS.BOTTOM_BUTTON_OFF_COLOR,
            command = "SET_BOTTOM_LED_OFF"
        }
    }

    -- Publish discovery for each LED entity as Text inputs (hex color codes)
    for _, ledConfig in ipairs(ledConfigs) do
        local discoveryTopic = "homeassistant/text/control4_" .. deviceID .. "_" .. ledConfig.suffix .. "/config"
        local objectID = SanitizeEntityName(ledConfig.name)

        local config = {
            name = ledConfig.name,
            object_id = objectID,
            default_entity_id = DefaultEntityID("text", objectID, deviceID),
            unique_id = ledConfig.unique_id,
            state_topic = "homeassistant/text/control4_" .. deviceID .. "/" .. ledConfig.suffix .. "/state",
            command_topic = "homeassistant/text/control4_" .. deviceID .. "/" .. ledConfig.suffix .. "/set",
            pattern = "[0-9A-Fa-f]{6}",  -- Validates 6-character hex codes
            mode = "text",
            icon = "mdi:palette",
            entity_category = "config",  -- Show in device config section
            device = {
                identifiers = {"control4_" .. deviceID},
                name = deviceName,
                manufacturer = "Control4",
                model = deviceType == "LIGHT" and "Switch" or "Switch"
            }
        }

        local payload = EncodeJSON(AddAvailability(config))
        Log("  Publishing LED text entity: " .. ledConfig.name .. " -> " .. discoveryTopic)
        PublishMQTT(discoveryTopic, payload, 1, true)
    end

    Log("Published LED discovery for: " .. deviceName)
end

-- LED entity suffix -> Light V2 button ID and which of its colors
local LIGHT_V2_LEDS = {
    top_on = {button = 0, color = "on"}, top_off = {button = 0, color = "off"},
    bottom_on = {button = 1, color = "on"}, bottom_off = {button = 1, color = "off"}
}

function PublishLEDState(deviceID, ledSuffix, variableID)
    if not IsLEDControlEnabled() then
        return
    end

    -- Light V2: the proxy keeps the button colors (GET_PROPERTIES)
    local proxyID = GetProxyID(deviceID)
    if IsLightV2(proxyID) then
        local settings = GetLightV2Settings(proxyID)
        local led = LIGHT_V2_LEDS[ledSuffix]
        local button = settings and led and settings.leds[led.button]
        local color = button and button[led.color]
        if not color or color == "" then
            return
        end
        local stateTopic = "homeassistant/text/control4_" .. deviceID .. "/" .. ledSuffix .. "/state"
        return PublishMQTT(stateTopic, string.upper(color), 0, true)
    end

    -- LED variables exist on the device, not the proxy
    -- Use GetDeviceVariables (plural) to get all variables
    -- Variable IDs are stored as STRING keys, not numbers
    local vars = C4:GetDeviceVariables(deviceID)
    local hexColor = nil

    if vars then
        local varKey = tostring(variableID)
        if vars[varKey] and vars[varKey].value then
            hexColor = vars[varKey].value
        end
    end

    if not hexColor or hexColor == "" then
        hexColor = "000000"  -- Default to black if not set
    end

    hexColor = string.upper(hexColor)

    -- Publish state to MQTT (use device ID in topic for consistency)
    local stateTopic = "homeassistant/text/control4_" .. deviceID .. "/" .. ledSuffix .. "/state"
    return PublishMQTT(stateTopic, hexColor, 0, true)
end

function PublishAllLEDStates(deviceID)
    if not IsLEDControlEnabled() then
        return
    end

    -- Publish state for all 4 LED entities (deviceID already has LED variables)
    PublishLEDState(deviceID, "top_on", VARIABLE_IDS.TOP_BUTTON_ON_COLOR)
    PublishLEDState(deviceID, "top_off", VARIABLE_IDS.TOP_BUTTON_OFF_COLOR)
    PublishLEDState(deviceID, "bottom_on", VARIABLE_IDS.BOTTOM_BUTTON_ON_COLOR)
    PublishLEDState(deviceID, "bottom_off", VARIABLE_IDS.BOTTOM_BUTTON_OFF_COLOR)
end

--- Advanced Dimmer Control Discovery and State Functions
function PublishDimmerAdvancedControlDiscovery(deviceID)
    if not IsAdvancedDimmerControlEnabled() then
        return
    end

    local proxyID = GetProxyID(deviceID)
    local dimmerName = C4:GetDeviceDisplayName(proxyID)

    if not dimmerName then
        LogError("Dimmer " .. deviceID .. " not found")
        return false
    end

    -- Only publish for actual dimmers, not switches
    -- Dimmers have LIGHT_LEVEL variable, switches only have SWITCH_STATE
    local level = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.LIGHT_LEVEL)
    local isDimmer = (level and level ~= "")

    if not isDimmer then
        return false  -- This is a switch, not a dimmer - skip advanced controls
    end

    -- Define the 7 advanced controls with their configuration
    local controls = {
        {
            suffix = "min_on_level",
            name = "Min On Level",
            varID = VARIABLE_IDS.MIN_ON_LEVEL,
            min = 0,
            max = 100,
            unit = "%",
            icon = "mdi:brightness-4"
        },
        {
            suffix = "max_on_level",
            name = "Max On Level",
            varID = VARIABLE_IDS.MAX_ON_LEVEL,
            min = 0,
            max = 100,
            unit = "%",
            icon = "mdi:brightness-7"
        },
        {
            suffix = "preset_level",
            name = "Preset Level",
            varID = VARIABLE_IDS.PRESET_LEVEL,
            min = 0,
            max = 100,
            unit = "%",
            icon = "mdi:brightness-6"
        },
        {
            suffix = "click_ramp_rate_up",
            name = "Click Ramp Rate Up",
            varID = VARIABLE_IDS.CLICK_RAMP_RATE_UP,
            min = 0,
            max = 5000,
            unit = "ms",
            icon = "mdi:arrow-up-bold"
        },
        {
            suffix = "click_ramp_rate_down",
            name = "Click Ramp Rate Down",
            varID = VARIABLE_IDS.CLICK_RAMP_RATE_DOWN,
            min = 0,
            max = 5000,
            unit = "ms",
            icon = "mdi:arrow-down-bold"
        },
        {
            suffix = "hold_ramp_rate_up",
            name = "Hold Ramp Rate Up",
            varID = nil,  -- No variable for hold ramp rates
            min = 0,
            max = 10,
            unit = "s",
            icon = "mdi:arrow-up-thick"
        },
        {
            suffix = "hold_ramp_rate_down",
            name = "Hold Ramp Rate Down",
            varID = nil,  -- No variable for hold ramp rates
            min = 0,
            max = 10,
            unit = "s",
            icon = "mdi:arrow-down-thick"
        },
        {
            suffix = "auto_off_time",
            name = "Auto Off Time",
            varID = nil,  -- Gen3: read from the device, in seconds (0 = auto off disabled)
            min = 0,
            max = 65535,
            unit = "s",
            icon = "mdi:timer-off-outline"
        }
    }

    -- A Light V2 light has only the settings its proxy reports (a Hue light has no hold rates or
    -- min/max): remove any entity published for the others before. Its limits come from the proxy.
    if IsLightV2(proxyID) then
        local settings = RefreshLightV2Settings(proxyID)
        if not settings and gSettingsCacheOnly then
            return false  -- not read yet (automatic run): leave its setting entities as they are
        end
        local available = {}
        for _, control in ipairs(controls) do
            if GetDimmerControlValue(deviceID, proxyID, control.suffix) then
                table.insert(available, control)
            else
                PublishMQTT("homeassistant/number/control4_" .. deviceID .. "_" .. control.suffix .. "/config", "", 1, true)
            end
        end
        controls = available
        PublishDeviceFlagDiscovery(deviceID, dimmerName, settings)
    else
        -- V1 dimmers: every control but the Light V2 only ones
        local v1Controls = {}
        for _, control in ipairs(controls) do
            if not DIMMER_CONTROL_VARS[control.suffix].v2only then
                table.insert(v1Controls, control)
            end
        end
        controls = v1Controls
    end

    -- Publish discovery for each control
    for _, control in ipairs(controls) do
        local discoveryTopic = "homeassistant/number/control4_" .. deviceID .. "_" .. control.suffix .. "/config"
        local objectID = SanitizeEntityName(dimmerName .. " " .. control.name)

        local low, high = GetDimmerControlRange(proxyID, control.suffix)
        local config = {
            name = dimmerName .. " - " .. control.name,
            object_id = objectID,
            default_entity_id = DefaultEntityID("number", objectID, deviceID),
            unique_id = "control4_" .. deviceID .. "_" .. control.suffix,
            state_topic = "homeassistant/number/control4_" .. deviceID .. "_" .. control.suffix .. "/state",
            command_topic = "homeassistant/number/control4_" .. deviceID .. "_" .. control.suffix .. "/set",
            min = low,
            max = high,
            step = (DIMMER_CONTROL_VARS[control.suffix].seconds and IsLightV2(proxyID)) and 0.1 or 1,  -- Light V2 hold rates are in ms
            mode = "box",
            unit_of_measurement = control.unit,
            icon = control.icon,
            entity_category = "config",
            device = {
                identifiers = {"control4_" .. deviceID},
                name = dimmerName,
                manufacturer = "Control4",
                model = "Dimmer"
            }
        }

        local payload = EncodeJSON(AddAvailability(config))
        PublishMQTT(discoveryTopic, payload, 1, true)
    end

    Log("Published advanced dimmer control discovery for: " .. dimmerName)

    -- Publish initial states
    PublishDimmerAdvancedControlStates(deviceID)

    return true
end

-- Read a Light V2 light's settings and LED colors back once, a little after a change from Home
-- Assistant, and publish them: what the light took, or the old value if it refused.
gLightV2ConfirmTimers = {}
function ConfirmLightV2Settings(deviceID)
    local pending = gLightV2ConfirmTimers[deviceID]
    if pending then
        pcall(function() pending:Cancel() end)
    end
    gLightV2ConfirmTimers[deviceID] = SafeSetTimer(TIMER_INTERVALS.LIGHT_V2_CONFIRM, function()
        gLightV2ConfirmTimers[deviceID] = nil
        RefreshLightV2Settings(GetProxyID(deviceID))
        PublishDimmerAdvancedControlStates(deviceID)
        PublishAllLEDStates(deviceID)
    end)
end

function PublishDimmerAdvancedControlStates(deviceID)
    if not IsAdvancedDimmerControlEnabled() then
        return
    end

    local proxyID = GetProxyID(deviceID)

    -- Only publish for actual dimmers, not switches
    local level = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.LIGHT_LEVEL)
    local isDimmer = (level and level ~= "")

    if not isDimmer then
        return false  -- This is a switch, not a dimmer - skip advanced controls
    end

    -- Publish each control's value from its proxy variable (V1 and Light V2 keep them under
    -- different IDs). V1 hold rates have no variable: only published once set from Home Assistant.
    for suffix in pairs(DIMMER_CONTROL_VARS) do
        local value = GetDimmerControlValue(deviceID, proxyID, suffix)
        if value then
            local stateTopic = "homeassistant/number/control4_" .. deviceID .. "_" .. suffix .. "/state"
            PublishMQTT(stateTopic, value, 1, true)  -- QoS 1, retained
        end
    end

    -- Gen3 device settings shown read-only (Light V2, as last read)
    local settings = IsLightV2(proxyID) and GetLightV2Settings(proxyID)
    for suffix in pairs(DEVICE_FLAG_SETTINGS) do
        local on = settings and settings.flags and settings.flags[suffix]
        if on ~= nil then
            PublishMQTT("homeassistant/binary_sensor/control4_" .. deviceID .. "_" .. suffix .. "/state", on and "ON" or "OFF", 1, true)
        end
    end

    return true
end

-- Read-only Gen3 device settings (binary sensors), for those the light's device reports; any
-- published before that it no longer reports are removed. settings: its cached Light V2 settings.
function PublishDeviceFlagDiscovery(deviceID, dimmerName, settings)
    for suffix, flag in pairs(DEVICE_FLAG_SETTINGS) do
        local topic = "homeassistant/binary_sensor/control4_" .. deviceID .. "_" .. suffix .. "/config"
        if settings and settings.flags and settings.flags[suffix] ~= nil then
            local objectID = SanitizeEntityName(dimmerName .. " " .. flag.name)
            local config = {
                name = dimmerName .. " - " .. flag.name,
                object_id = objectID,
                default_entity_id = DefaultEntityID("binary_sensor", objectID, deviceID),
                unique_id = "control4_" .. deviceID .. "_" .. suffix,
                state_topic = "homeassistant/binary_sensor/control4_" .. deviceID .. "_" .. suffix .. "/state",
                payload_on = "ON",
                payload_off = "OFF",
                icon = flag.icon,
                entity_category = "diagnostic",
                device = {
                    identifiers = {"control4_" .. deviceID},
                    name = dimmerName,
                    manufacturer = "Control4",
                    model = "Dimmer"
                }
            }
            PublishMQTT(topic, EncodeJSON(AddAvailability(config)), 1, true)
        else
            PublishMQTT(topic, "", 1, true)
        end
    end
end

-- Power and energy a light, switch or outlet driver reports in its own variables (a Gen3 dimmer:
-- CURRENT_POWER, ENERGY_USED, ENERGY_USED_TODAY, in W and Wh, confirmed 2026-11-19). Found by name,
-- as the controller numbers a driver's own variables itself. Published as sensors Home Assistant's
-- Energy dashboard takes: the day's total resets at midnight, which total_increasing allows.
ENERGY_SENSORS = {
    {suffix = "power", variable = "CURRENT_POWER", name = "Power", device_class = "power", unit = "W", state_class = "measurement"},
    {suffix = "energy", variable = "ENERGY_USED", name = "Energy", device_class = "energy", unit = "Wh", state_class = "total_increasing"},
    {suffix = "energy_today", variable = "ENERGY_USED_TODAY", name = "Energy Today", device_class = "energy", unit = "Wh", state_class = "total_increasing"}
}
-- Watched energy variables by device ID: [deviceID] = {[varID] = sensor}
gEnergyVars = {}

function EnergySensorTopic(deviceID, suffix)
    return "homeassistant/sensor/control4_" .. deviceID .. "_" .. suffix
end

-- Look up (by name) a device's energy variables and watch them
function ResolveEnergyVariables(deviceID)
    deviceID = tonumber(deviceID)
    if not deviceID then
        return
    end
    UnwatchEnergyVariables(deviceID)
    local byName = {}
    for _, sensor in ipairs(ENERGY_SENSORS) do
        byName[sensor.variable] = sensor
    end
    local found = {}
    local any = false
    for varID, var in pairs(C4:GetDeviceVariables(deviceID) or {}) do
        local sensor = type(var) == "table" and byName[var.name]
        if sensor and tonumber(varID) then
            found[tonumber(varID)] = sensor
            C4:RegisterVariableListener(deviceID, tonumber(varID))
            any = true
        end
    end
    gEnergyVars[deviceID] = any and found or nil
end

function UnwatchEnergyVariables(deviceID)
    deviceID = tonumber(deviceID)
    for varID in pairs(gEnergyVars[deviceID] or {}) do
        C4:UnregisterVariableListener(deviceID, varID)
    end
    gEnergyVars[deviceID] = nil
end

-- Discovery for a device's power and energy sensors (those it has), then their states
function PublishEnergyDiscovery(deviceID)
    local vars = gEnergyVars[tonumber(deviceID)]
    if not vars then
        return
    end
    local name = C4:GetDeviceDisplayName(GetProxyID(deviceID)) or C4:GetDeviceDisplayName(deviceID) or ("Device " .. deviceID)
    for _, sensor in pairs(vars) do
        local objectID = SanitizeEntityName(name .. " " .. sensor.name)
        local config = {
            name = name .. " - " .. sensor.name,
            object_id = objectID,
            default_entity_id = DefaultEntityID("sensor", objectID, deviceID),
            unique_id = "control4_" .. deviceID .. "_" .. sensor.suffix,
            state_topic = EnergySensorTopic(deviceID, sensor.suffix) .. "/state",
            device_class = sensor.device_class,
            state_class = sensor.state_class,
            unit_of_measurement = sensor.unit,
            device = {
                identifiers = {"control4_" .. deviceID},
                name = name,
                manufacturer = "Control4"
            }
        }
        PublishMQTT(EnergySensorTopic(deviceID, sensor.suffix) .. "/config", EncodeJSON(AddAvailability(config)), 1, true)
    end
    PublishEnergyStates(deviceID)
end

function PublishEnergyState(deviceID, varID, value)
    local sensor = gEnergyVars[tonumber(deviceID)] and gEnergyVars[tonumber(deviceID)][tonumber(varID)]
    value = tonumber(value)
    if sensor and value then
        PublishMQTT(EnergySensorTopic(deviceID, sensor.suffix) .. "/state", tostring(value), 0, true)
    end
end

function PublishEnergyStates(deviceID)
    for varID in pairs(gEnergyVars[tonumber(deviceID)] or {}) do
        PublishEnergyState(deviceID, varID, C4:GetDeviceVariable(deviceID, varID))
    end
end

-- Paced discovery for every monitored device (one device per DISCOVERY_DELAY). auto: run by the
-- driver itself (on connect, or Home Assistant restarting) rather than the Publish Auto-Discovery
-- action. onComplete: called when the run has gone through every device.
function PublishAllDiscovery(auto, onComplete)
    if not gMQTTConnected then
        LogError("Cannot publish discovery - not connected to MQTT")
        return
    end

    gDiscoveryInProgress = true
    Log("========================================")
    Log("Publishing auto-discovery for all devices...")

    -- One device's publishing: from cached Light V2 settings in an automatic run, with a full
    -- read of the light (as before) from the action
    local function runStep(fn)
        if auto then
            RunWithCachedSettings(fn)
        else
            fn()
        end
    end

    -- Forward declarations for mutual recursion
    local PublishNextLight
    local PublishNextSwitch
    local PublishNextOutlet
    local PublishNextThermostat
    local PublishNextMediaRoom
    local PublishNextContactSensor

    -- Publish light discovery
    local lightIndex = 1
    PublishNextLight = function()
        if lightIndex <= #gMonitoredLights then
            local lightID = gMonitoredLights[lightIndex]
            -- An automatic run uses cached Light V2 settings only (no blocking proxy reads)
            runStep(function()
                PublishLightDiscovery(lightID)

                -- Also publish LED discovery and state if enabled
                if IsLEDControlEnabled() then
                    PublishLEDDiscovery(lightID, "LIGHT")
                    PublishAllLEDStates(lightID)
                end

                -- Publish advanced dimmer control discovery and state if enabled
                if IsAdvancedDimmerControlEnabled() then
                    PublishDimmerAdvancedControlDiscovery(lightID)
                end
            end)

            lightIndex = lightIndex + 1
            -- Delay to prevent overwhelming the socket
            SafeSetTimer(TIMER_INTERVALS.DISCOVERY_DELAY, function()
                PublishNextLight()
            end)
        else
            Log("Auto-discovery complete for " .. #gMonitoredLights .. " lights")
            -- After lights, publish switches
            PublishNextSwitch()
        end
    end

    -- Publish switch discovery
    local switchIndex = 1
    PublishNextSwitch = function()
        if switchIndex <= #gMonitoredSwitches then
            local switchID = gMonitoredSwitches[switchIndex]
            runStep(function()
                PublishSwitchDiscovery(switchID)

                -- Also publish LED discovery and state if enabled
                if IsLEDControlEnabled() then
                    PublishLEDDiscovery(switchID, "SWITCH")
                    PublishAllLEDStates(switchID)
                end
            end)

            switchIndex = switchIndex + 1
            -- Delay to prevent overwhelming the socket
            SafeSetTimer(TIMER_INTERVALS.DISCOVERY_DELAY, function()
                PublishNextSwitch()
            end)
        else
            Log("Auto-discovery complete for " .. #gMonitoredSwitches .. " switches")
            -- After switches, publish outlets
            PublishNextOutlet()
        end
    end

    -- Publish outlet discovery
    local outletIndex = 1
    PublishNextOutlet = function()
        if outletIndex <= #gMonitoredOutlets then
            local outletID = gMonitoredOutlets[outletIndex]
            PublishOutletDiscovery(outletID)

            outletIndex = outletIndex + 1
            -- Delay to prevent overwhelming the socket
            SafeSetTimer(TIMER_INTERVALS.DISCOVERY_DELAY, function()
                PublishNextOutlet()
            end)
        else
            Log("Auto-discovery complete for " .. #gMonitoredOutlets .. " outlets")
            -- After outlets, publish thermostats
            PublishNextThermostat()
        end
    end

    -- Publish thermostat discovery
    local thermostatIndex = 1
    PublishNextThermostat = function()
        if thermostatIndex <= #gMonitoredThermostats then
            PublishThermostatDiscovery(gMonitoredThermostats[thermostatIndex])
            thermostatIndex = thermostatIndex + 1
            -- Delay to prevent overwhelming the socket
            SafeSetTimer(TIMER_INTERVALS.DISCOVERY_DELAY, function()
                PublishNextThermostat()
            end)
        else
            Log("Auto-discovery complete for " .. #gMonitoredThermostats .. " thermostats")
            -- After thermostats, publish media rooms
            PublishNextMediaRoom()
        end
    end

    -- Publish media room discovery
    local mediaRoomIndex = 1
    PublishNextMediaRoom = function()
        if mediaRoomIndex <= #gMonitoredMediaRooms then
            local roomID = gMonitoredMediaRooms[mediaRoomIndex]
            if auto then
                -- The mqtt_media_player custom component adds an entity for every config it
                -- receives (a second one is refused with an error in Home Assistant's log), and
                -- its retained config already reaches it when Home Assistant restarts: only the
                -- room's availability and state here
                PublishMQTT("homeassistant/media_player/control4_room_" .. roomID .. "/availability", "online", 1, true)
                PublishMediaRoomState(roomID)
            else
                PublishMediaRoomDiscovery(roomID)
            end
            mediaRoomIndex = mediaRoomIndex + 1
            -- Delay to prevent overwhelming the socket
            SafeSetTimer(TIMER_INTERVALS.DISCOVERY_DELAY, function()
                PublishNextMediaRoom()
            end)
        else
            Log("Auto-discovery complete for " .. #gMonitoredMediaRooms .. " media rooms")
            -- After media rooms, publish contact sensors
            PublishNextContactSensor()
        end
    end

    -- Publish contact sensor discovery
    local contactSensorIndex = 1
    PublishNextContactSensor = function()
        if contactSensorIndex <= #gMonitoredContactSensors then
            PublishContactSensorDiscovery(gMonitoredContactSensors[contactSensorIndex])
            contactSensorIndex = contactSensorIndex + 1
            -- Delay to prevent overwhelming the socket
            SafeSetTimer(TIMER_INTERVALS.DISCOVERY_DELAY, function()
                PublishNextContactSensor()
            end)
        else
            Log("Auto-discovery complete for " .. #gMonitoredContactSensors .. " contact sensors")
            Log("========================================")
            gDiscoveryInProgress = false
            if onComplete then
                onComplete()
            end
        end
    end

    -- Each step moves on to the next one when it has nothing to do
    PublishNextLight()
end

-- Every discovery config topic one monitored device can have published (an empty retained config
-- removes an entity, and is harmless for one never published)
function DeviceConfigTopics(deviceType, deviceID)
    local topics = {}
    local function add(topic) table.insert(topics, topic) end
    local function addLEDTexts()
        for _, suffix in ipairs({"top_on", "top_off", "bottom_on", "bottom_off"}) do
            add("homeassistant/text/control4_" .. deviceID .. "_" .. suffix .. "/config")
        end
    end
    local function addEnergySensors()
        for _, sensor in ipairs(ENERGY_SENSORS) do
            add(EnergySensorTopic(deviceID, sensor.suffix) .. "/config")
        end
    end
    if deviceType == "LIGHT" then
        add("homeassistant/light/control4_" .. deviceID .. "/config")
        addLEDTexts()
        for _, suffix in ipairs({"min_on_level", "max_on_level", "preset_level", "click_ramp_rate_up",
                                 "click_ramp_rate_down", "hold_ramp_rate_up", "hold_ramp_rate_down",
                                 "auto_off_time"}) do
            add("homeassistant/number/control4_" .. deviceID .. "_" .. suffix .. "/config")
        end
        for suffix in pairs(DEVICE_FLAG_SETTINGS) do
            add("homeassistant/binary_sensor/control4_" .. deviceID .. "_" .. suffix .. "/config")
        end
        addEnergySensors()
    elseif deviceType == "SWITCH" then
        add("homeassistant/switch/control4_" .. deviceID .. "/config")
        addLEDTexts()
        addEnergySensors()
    elseif deviceType == "OUTLET" then
        add("homeassistant/switch/control4_" .. deviceID .. "/config")
    elseif deviceType == "THERMOSTAT" then
        add("homeassistant/climate/control4_" .. deviceID .. "/config")
        add("homeassistant/text/control4_thermostat_" .. deviceID .. "_button_led/config")
    elseif deviceType == "MEDIA_ROOM" then
        add("homeassistant/media_player/control4_room_" .. deviceID .. "/config")
    elseif deviceType == "CONTACT_SENSOR" then
        -- Each contact's binary sensor, and the battery, voltage and temperature sensors
        local deviceInfo = gContactSensorDevices[deviceID]
        if deviceInfo then
            for bindingID in pairs(deviceInfo.bindings or {}) do
                local stateEntity = GetContactStateEntity(bindingID)
                if stateEntity then
                    add("homeassistant/binary_sensor/" .. stateEntity.id .. "/config")
                end
            end
            local customName, nameSuffix = GetContactSensorNaming(deviceID)
            if customName then
                local entities = BuildContactSensorEntityNames(customName, nameSuffix)
                for _, entity in ipairs({entities.battery, entities.voltage, entities.temperature}) do
                    add("homeassistant/sensor/" .. entity.id .. "/config")
                end
            end
        end
    end
    return topics
end

-- Monitored device types, in the order they are listed and removed
TRACKED_TYPES = {
    {"LIGHT", "light"}, {"SWITCH", "switch"}, {"OUTLET", "outlet"}, {"THERMOSTAT", "thermostat"},
    {"MEDIA_ROOM", "media room"}, {"CONTACT_SENSOR", "contact sensor"}
}

function RemoveAllEntities()
    if not gMQTTConnected then
        LogError("Cannot remove entities - not connected to MQTT")
        return
    end

    Log("========================================")
    Log("Removing all entities from Home Assistant...")

    for _, entry in ipairs(TRACKED_TYPES) do
        for _, deviceID in ipairs(GetMonitoredList(entry[1])) do
            for _, topic in ipairs(DeviceConfigTopics(entry[1], deviceID)) do
                PublishMQTT(topic, "", 1, true)
            end
            Log("  Removed " .. entry[2] .. " " .. deviceID)
        end
    end

    Log("All entities removed - wait 5 seconds then run 'Publish Auto-Discovery'")
    Log("========================================")
end

function InspectDevice(deviceID)
    Log("========================================")
    Log("Inspecting Device ID: " .. deviceID)

    local deviceName = C4:GetDeviceDisplayName(deviceID)
    Log("  Device Name: " .. tostring(deviceName))

    Log("")
    Log("Variables:")
    local vars = C4:GetDeviceVariables(deviceID)
    if vars then
        for k, v in pairs(vars) do
            Log(string.format("  [%s] %s = %s", tostring(k), tostring(v.name or "unnamed"), tostring(v.value or "nil")))
        end
    else
        Log("  No variables found")
    end

    Log("")
    Log("Device Data:")
    -- Try common device data keys
    local dataKeys = {"IP_ADDRESS", "IP", "IPAddress", "ipaddress",
                     "CONTACT_STATE", "ContactState", "contact_state",
                     "CONTACT_1", "CONTACT_2", "CONTACT_3",
                     "STATE", "state", "Status", "STATUS"}
    for _, key in ipairs(dataKeys) do
        local value = C4:GetDeviceData(deviceID, key)
        if value ~= nil then
            Log("  " .. key .. ": " .. tostring(value))
        end
    end

    Log("")
    Log("Proxy Information:")
    local proxyID = GetProxyID(deviceID)
    if proxyID and proxyID ~= deviceID then
        Log("  Proxy ID: " .. proxyID)
        Log("  Proxy Name: " .. tostring(C4:GetDeviceDisplayName(proxyID)))
    else
        Log("  No separate proxy")
    end

    Log("")
    Log("Connection IDs (from .c4i: 200, 201, 202):")
    Log("  Attempting to read connection states...")
    -- Try to read connection states for the three contacts
    for connID = 200, 202 do
        local state = C4:GetDeviceData(deviceID, "CONNECTION_" .. connID)
        if state then
            Log("  Connection " .. connID .. ": " .. tostring(state))
        end
    end

    Log("========================================")
end

function HandleThermostatCommand(topic, payload, thermostatID)
    -- thermostatID is device ID, use proxy for variable operations
    local proxyID = GetProxyID(thermostatID)
    local commandSent = false

    -- Determine command type from topic
    if string.find(topic, "/mode/set$") then
        -- HVAC mode command (payload is plain text: "off", "heat", "cool", "heat_cool")
        local c4Mode = HVAC_MODE_HA_TO_C4[payload]
        if c4Mode then
            commandSent = pcall(function()
                C4:SendToDevice(proxyID, "SET_MODE_HVAC", {MODE = c4Mode})
            end)
        else
            LogError("Unknown HVAC mode: " .. payload)
        end

    elseif string.find(topic, "/temperature/set$") then
        -- Single temperature command (payload is plain number like "72")
        local temp = tonumber(payload)
        if temp then
            local currentMode = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.HVAC_MODE) or "Off"

            if currentMode == "Heat" then
                commandSent = pcall(function() C4:SetDeviceVariable(proxyID, 1132, temp) end)
            elseif currentMode == "Cool" then
                commandSent = pcall(function() C4:SetDeviceVariable(proxyID, 1134, temp) end)
            elseif currentMode == "Auto" then
                commandSent = pcall(function() C4:SetDeviceVariable(proxyID, 1132, temp) end)
            end
        else
            LogError("Invalid temperature value: " .. tostring(payload))
        end

    elseif string.find(topic, "/temperature_low/set$") then
        -- Low temperature setpoint for auto mode
        local tempLow = tonumber(payload)
        if tempLow then
            commandSent = pcall(function() C4:SetDeviceVariable(proxyID, 1132, tempLow) end)
        else
            LogError("Invalid temperature_low value: " .. tostring(payload))
        end

    elseif string.find(topic, "/temperature_high/set$") then
        -- High temperature setpoint for auto mode
        local tempHigh = tonumber(payload)
        if tempHigh then
            commandSent = pcall(function() C4:SetDeviceVariable(proxyID, 1134, tempHigh) end)
        else
            LogError("Invalid temperature_high value: " .. tostring(payload))
        end

    elseif string.find(topic, "/fan_mode/set$") then
        -- Fan mode command (payload is plain text: "auto", "on", "circulate")
        local c4FanMode = FAN_MODE_HA_TO_C4[payload]
        if c4FanMode then
            commandSent = pcall(function()
                C4:SendToDevice(proxyID, "SET_MODE_FAN", {MODE = c4FanMode})
            end)
        else
            LogError("Unknown fan mode: " .. payload)
        end

    else
        LogError("Unknown command topic: " .. topic)
    end

    if commandSent then
        local thermostatName = C4:GetDeviceDisplayName(proxyID)
        C4:UpdateProperty("Last Command", thermostatName .. " @ " .. os.date("%H:%M:%S"))
        return true
    end

    return false
end

-- Control from Home Assistant
-- Home Assistant light commands can nest objects ("color": {"x": .., "y": ..}), which ParseJSON
-- doesn't handle: use the controller's JSON decoder
function DecodeLightCommand(payload)
    if C4.JsonDecode then
        local ok, result = pcall(C4.JsonDecode, C4, payload)
        if ok and type(result) == "table" then
            return result
        end
    end
    return ParseJSON(payload)
end

function IsLightOn(proxyID)
    return (tonumber(C4:GetDeviceVariable(proxyID, VARIABLE_IDS.LIGHT_LEVEL) or "") or 0) > 0
end

-- Send a Home Assistant color to a Light V2 light: color_temp (Kelvin) or color {x, y}. Returns
-- true if the command had a color. The mode goes under both names: the proxy drops
-- LIGHT_COLOR_TARGET_MODE, and a color temperature-only light (Hue) rejects a full color target.
function SendLightColor(proxyID, cmd, transitionMs)
    local x, y, mode
    local kelvin = tonumber(cmd.color_temp)
    if kelvin and kelvin > 0 and C4.ColorCCTtoXY then
        if kelvin < 1000 then
            kelvin = 1000000 / kelvin  -- mireds, from a Home Assistant not using Kelvin
        end
        x, y = C4:ColorCCTtoXY(kelvin)
        mode = 1
    elseif type(cmd.color) == "table" and tonumber(cmd.color.x) and tonumber(cmd.color.y) then
        x, y, mode = tonumber(cmd.color.x), tonumber(cmd.color.y), 0
    else
        return false
    end
    C4:SendToDevice(proxyID, "SET_COLOR_TARGET", {
        LIGHT_COLOR_TARGET_X = x,
        LIGHT_COLOR_TARGET_Y = y,
        LIGHT_COLOR_TARGET_MODE = mode,        -- 1 = color temperature, 0 = full color
        LIGHT_COLOR_TARGET_COLOR_MODE = mode,  -- the name the proxy's own notifications use
        LIGHT_COLOR_TARGET_RATE = transitionMs
    })
    Log(string.format("Light %d color: x %.4f y %.4f mode %d%s", proxyID, x, y, mode,
        kelvin and mode == 1 and string.format(" (%.0f K)", kelvin) or ""))
    return true
end

function HandleMQTTCommand(topic, payload)
    -- The command subscriptions are wildcards: other integrations' command topics under
    -- homeassistant/ arrive too. Only this driver's (control4_ objects) are handled.
    if not (string.find(topic, "^homeassistant/[^/]+/control4_") and string.find(topic, "/set$")) then
        return
    end

    -- Try to parse as light command (format: homeassistant/light/control4_<ID>/set)
    local lightIDStr = string.match(topic, "homeassistant/light/control4_(%d+)/set")

    if lightIDStr then
        -- Handle light command
        local targetLightID = tonumber(lightIDStr)  -- This is device ID from topic

        -- Verify device is in our monitored list
        if not IsDeviceMonitored(targetLightID, "LIGHT") then
            LogError("Light " .. targetLightID .. " not in monitored list")
            return
        end

        -- Get proxy ID for sending commands (commands go to proxy, not device)
        local proxyID = GetProxyID(targetLightID)

        local cmd = DecodeLightCommand(payload)
        if not cmd then
            LogError("Failed to parse JSON command")
            return
        end

        -- Light V2 lights fade over Home Assistant's transition (seconds)
        local isV2 = IsLightV2(proxyID)
        local transitionMs = isV2 and tonumber(cmd.transition) and math.floor(tonumber(cmd.transition) * 1000 + 0.5) or nil

        if cmd.state == "ON" then
            -- Color first, so a light that's off comes on in its new color
            local colorSent = isV2 and SendLightColor(proxyID, cmd, transitionMs)
            if cmd.brightness then
                -- Convert HA brightness (0-255) to C4 level (0-100)
                local haBrightness = tonumber(cmd.brightness) or 255
                local c4Level = math.floor((haBrightness * 100 / 255) + 0.5)

                -- Ensure minimum brightness of 1 when turning on
                if c4Level == 0 and haBrightness > 0 then
                    c4Level = 1
                end

                if transitionMs then
                    C4:SendToDevice(proxyID, "RAMP_TO_LEVEL", {LEVEL = c4Level, TIME = transitionMs})
                else
                    C4:SendToDevice(proxyID, "SET_LEVEL", {LEVEL = c4Level})
                end
            elseif not (colorSent and IsLightOn(proxyID)) then
                -- (A color change on a light that's on doesn't send ON: that would also take it
                -- to its Default On level)
                C4:SendToDevice(proxyID, "ON", {})
            end
        elseif cmd.state == "OFF" then
            if transitionMs then
                C4:SendToDevice(proxyID, "RAMP_TO_LEVEL", {LEVEL = 0, TIME = transitionMs})
            else
                C4:SendToDevice(proxyID, "OFF", {})
            end
        else
            LogError("Unknown state: " .. tostring(cmd.state))
        end

        local fullName = C4:GetDeviceDisplayName(proxyID)
        C4:UpdateProperty("Last Command", fullName .. " @ " .. os.date("%H:%M:%S"))
        return
    end

    -- Try to parse as switch/outlet command (both use format: homeassistant/switch/control4_<ID>/set)
    local switchDeviceIDStr = string.match(topic, "homeassistant/switch/control4_(%d+)/set")

    if switchDeviceIDStr then
        local targetDeviceID = tonumber(switchDeviceIDStr)  -- This is device ID from topic

        -- Check if it's monitored as either a switch or outlet (both use HA switch platform)
        local isSwitch = IsDeviceMonitored(targetDeviceID, "SWITCH")
        local isOutlet = IsDeviceMonitored(targetDeviceID, "OUTLET")

        if not isSwitch and not isOutlet then
            LogError("Switch/Outlet " .. targetDeviceID .. " not in monitored list")
            return
        end

        -- Get proxy ID for sending commands (commands go to proxy, not device)
        local proxyID = GetProxyID(targetDeviceID)

        if payload == "ON" then
            C4:SendToDevice(proxyID, "ON", {})
        elseif payload == "OFF" then
            C4:SendToDevice(proxyID, "OFF", {})
        else
            LogError("Unknown switch/outlet state: " .. tostring(payload))
        end

        local fullName = C4:GetDeviceDisplayName(proxyID)
        local deviceType = isSwitch and "switch" or "outlet"
        C4:UpdateProperty("Last Command", fullName .. " (" .. deviceType .. ") @ " .. os.date("%H:%M:%S"))
        return
    end

    -- Try to parse as thermostat command (format: homeassistant/climate/control4_<ID>/<command_type>/set)
    -- Matches: /mode/set, /temperature/set, /temperature_low/set, /temperature_high/set, /fan_mode/set
    local thermostatIDStr = string.match(topic, "homeassistant/climate/control4_(%d+)/.*set$")

    if thermostatIDStr then
        -- Handle thermostat command
        local targetThermostatID = tonumber(thermostatIDStr)

        -- Verify device is in our monitored list
        if not IsDeviceMonitored(targetThermostatID, "THERMOSTAT") then
            LogError("Thermostat " .. targetThermostatID .. " not in monitored list")
            return
        end

        HandleThermostatCommand(topic, payload, targetThermostatID)
        return
    end

    -- Try to parse as media room command (format: homeassistant/media_player/control4_room_<ID>/set)
    local roomIDStr = string.match(topic, "homeassistant/media_player/control4_room_(%d+)/set")

    if roomIDStr then
        local targetRoomID = tonumber(roomIDStr)

        -- Verify device is in our monitored list
        if not IsDeviceMonitored(targetRoomID, "MEDIA_ROOM") then
            LogError("Media room " .. targetRoomID .. " not in monitored list")
            return
        end

        -- Home Assistant sends different payloads based on the command type:
        -- - Power: "ON" or "OFF" (simple string)
        -- - Volume: "0.5" (numeric string, 0.0-1.0)
        -- - Mute: "true" or "false" (string boolean)

        -- Handle simple ON/OFF commands
        if payload == "ON" then
            Log("Turning on media room " .. targetRoomID)
            C4:SendToDevice(targetRoomID, "ON", {})
        elseif payload == "OFF" then
            Log("Turning off media room " .. targetRoomID)
            C4:SendToDevice(targetRoomID, "ROOM_OFF", {})

        -- Handle mute commands (sent as string "true" or "false")
        elseif payload == "true" then
            Log("Muting room " .. targetRoomID)
            C4:SendToDevice(targetRoomID, "MUTE_ON", {})
        elseif payload == "false" then
            Log("Unmuting room " .. targetRoomID)
            C4:SendToDevice(targetRoomID, "MUTE_OFF", {})

        -- Try to parse as volume level (numeric string 0.0-1.0)
        else
            local volumeLevel = tonumber(payload)
            if volumeLevel then
                -- Convert HA volume (0.0-1.0) to C4 volume (0-100)
                local c4Volume = math.floor(volumeLevel * 100)
                Log("Setting volume for room " .. targetRoomID .. " to " .. c4Volume)
                C4:SendToDevice(targetRoomID, "SET_VOLUME_LEVEL", {LEVEL = c4Volume})
            else
                -- Try to parse as JSON for advanced commands
                local cmd = ParseJSON(payload)
                if cmd then
                    if cmd.command == "volume_up" then
                        Log("Volume up for room " .. targetRoomID)
                        C4:SendToDevice(targetRoomID, "PULSE_VOL_UP", {})
                    elseif cmd.command == "volume_down" then
                        Log("Volume down for room " .. targetRoomID)
                        C4:SendToDevice(targetRoomID, "PULSE_VOL_DOWN", {})
                    elseif cmd.command == "media_play" then
                        Log("Play command for room " .. targetRoomID)
                        C4:SendToDevice(targetRoomID, "PLAY", {})
                        -- Don't update state here - C4:SendToDevice triggers OnDeviceEvent which handles state
                    elseif cmd.command == "media_pause" then
                        Log("Pause command for room " .. targetRoomID)
                        C4:SendToDevice(targetRoomID, "PAUSE", {})
                        -- Don't update state here - C4:SendToDevice triggers OnDeviceEvent which handles state
                    elseif cmd.command == "media_stop" then
                        Log("Stop command for room " .. targetRoomID)
                        C4:SendToDevice(targetRoomID, "STOP", {})
                        -- Don't update state here - C4:SendToDevice triggers OnDeviceEvent which handles state
                    elseif cmd.command == "media_next_track" then
                        Log("Next track command for room " .. targetRoomID)
                        C4:SendToDevice(targetRoomID, "SKIP_FWD", {})
                    elseif cmd.command == "media_previous_track" then
                        Log("Previous track command for room " .. targetRoomID)
                        C4:SendToDevice(targetRoomID, "SKIP_REV", {})
                    elseif cmd.command == "scan_forward" then
                        Log("Scan forward for room " .. targetRoomID)
                        C4:SendToDevice(targetRoomID, "SCAN_FWD", {})
                    elseif cmd.command == "scan_reverse" then
                        Log("Scan reverse for room " .. targetRoomID)
                        C4:SendToDevice(targetRoomID, "SCAN_REV", {})
                    elseif cmd.command == "request_state" then
                        Log("State request for room " .. targetRoomID)
                        -- Publish current state immediately (no debounce)
                        if gMQTTConnected then
                            PublishMediaRoomState(targetRoomID)
                        end
                    elseif cmd.command == "sync_state" then
                        -- HA automation polled Roku and is telling us the actual state
                        -- Update our internal tracking to match Roku's reality without sending commands
                        local actualState = cmd.state
                        if actualState and (actualState == "playing" or actualState == "paused" or actualState == "idle" or actualState == "off") then
                            local oldState = gMediaRoomPlaybackState[targetRoomID] or "unknown"
                            if actualState == "off" then
                                gMediaRoomPlaybackState[targetRoomID] = "idle"
                            else
                                gMediaRoomPlaybackState[targetRoomID] = actualState
                            end
                            Log("Syncing state for room " .. targetRoomID .. " from " .. oldState .. " to " .. actualState)
                            -- Publish corrected state to HA
                            if gMQTTConnected then
                                PublishMediaRoomState(targetRoomID)
                            end
                        else
                            LogError("Invalid state in sync_state command: " .. tostring(actualState))
                        end
                    else
                        LogError("Unknown media room command: " .. tostring(cmd.command))
                    end
                else
                    LogError("Unknown media room payload: " .. tostring(payload))
                end
            end
        end

        local fullName = C4:GetDeviceDisplayName(targetRoomID)
        C4:UpdateProperty("Last Command", fullName .. " @ " .. os.date("%H:%M:%S"))
        return
    end

    -- Try to parse as LED text command (format: homeassistant/text/control4_<ID>/<suffix>/set)
    -- Matches: /text/control4_577/top_on/set, /text/control4_577/top_off/set, etc.
    local ledIDStr, ledSuffix = string.match(topic, "homeassistant/text/control4_(%d+)/([^/]+)/set")

    if ledIDStr and ledSuffix then
        if not IsLEDControlEnabled() then
            return
        end

        local deviceID = tonumber(ledIDStr)  -- Topic uses device ID

        -- Check if device is monitored as either light or switch
        local isLight = IsDeviceMonitored(deviceID, "LIGHT")
        local isSwitch = IsDeviceMonitored(deviceID, "SWITCH")

        if not isLight and not isSwitch then
            LogError("LED control device " .. deviceID .. " not in monitored list")
            return
        end

        -- Get proxy ID for display name
        local proxyID = GetProxyID(deviceID)

        -- Payload is plain hex string (e.g., "00FF00" or "ff0000")
        local hexColor = payload

        -- Validate hex format (6 characters, hex digits)
        if not hexColor or not string.match(hexColor, "^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$") then
            LogError("Invalid hex color format: " .. tostring(payload) .. " (expected 6-char hex like 00FF00)")
            return
        end

        -- Ensure uppercase for consistency
        hexColor = string.upper(hexColor)

        -- Determine which command to send based on suffix
        local commandMap = {
            top_on = "SET_TOP_LED_ON",
            top_off = "SET_TOP_LED_OFF",
            bottom_on = "SET_BOTTOM_LED_ON",
            bottom_off = "SET_BOTTOM_LED_OFF"
        }

        local command = commandMap[ledSuffix]

        if not command then
            LogError("Unknown LED suffix: " .. ledSuffix)
            return
        end

        if IsLightV2(proxyID) then
            -- Light V2: SET_BUTTON_COLOR to the proxy, with the button's other color as it is
            local led = LIGHT_V2_LEDS[ledSuffix]
            local settings = GetLightV2Settings(proxyID)
            local button = settings and settings.leds[led.button] or {}
            local colors = { on = button.on, off = button.off }
            colors[led.color] = string.lower(hexColor)
            if not (colors.on and colors.off) then
                LogError("LED colors of " .. deviceID .. " unknown: not sent")
                return
            end
            Log("Sending SET_BUTTON_COLOR to proxy " .. proxyID .. ": button " .. led.button ..
                " on " .. colors.on .. " off " .. colors.off)
            C4:SendToDevice(proxyID, "SET_BUTTON_COLOR", {BUTTON_ID = led.button, ON_COLOR = colors.on, OFF_COLOR = colors.off})
            button[led.color] = colors[led.color]   -- so a second change before the read keeps this one
            ConfirmLightV2Settings(deviceID)
        else
            -- Send command to Control4 device (not proxy)
            Log("Sending LED command to device " .. deviceID .. " (proxy " .. proxyID .. "): " .. command .. " with color " .. hexColor)
            C4:SendToDevice(deviceID, command, {RGB = hexColor})
        end

        -- Publish state back to Home Assistant immediately
        local variableMap = {
            top_on = VARIABLE_IDS.TOP_BUTTON_ON_COLOR,
            top_off = VARIABLE_IDS.TOP_BUTTON_OFF_COLOR,
            bottom_on = VARIABLE_IDS.BOTTOM_BUTTON_ON_COLOR,
            bottom_off = VARIABLE_IDS.BOTTOM_BUTTON_OFF_COLOR
        }

        local variableID = variableMap[ledSuffix]
        if variableID then
            -- Publish the state we just set (use device ID in topic for consistency)
            local stateTopic = "homeassistant/text/control4_" .. deviceID .. "/" .. ledSuffix .. "/state"
            PublishMQTT(stateTopic, hexColor, 0, true)
        end

        local deviceName = C4:GetDeviceDisplayName(proxyID)
        Log("LED color set: " .. deviceName .. " " .. ledSuffix .. " = " .. hexColor)
        C4:UpdateProperty("Last Command", deviceName .. " LED @ " .. os.date("%H:%M:%S"))
        return
    end

    -- Try to parse as advanced dimmer control command (format: homeassistant/number/control4_<ID>_<control>/set)
    local dimmerIDStr, controlSuffix = string.match(topic, "homeassistant/number/control4_(%d+)_([^/]+)/set")

    if dimmerIDStr and controlSuffix then
        if not IsAdvancedDimmerControlEnabled() then
            return
        end

        local dimmerID = tonumber(dimmerIDStr)  -- Device ID from topic

        -- Verify device is in our monitored light list
        if not IsDeviceMonitored(dimmerID, "LIGHT") then
            LogError("Dimmer " .. dimmerID .. " not in monitored list")
            return
        end

        -- Map control suffix to variable ID and validate value
        local controlMap = {
            min_on_level = {varID = VARIABLE_IDS.MIN_ON_LEVEL, min = 0, max = 100, name = "Min On Level", unit = "%"},
            max_on_level = {varID = VARIABLE_IDS.MAX_ON_LEVEL, min = 0, max = 100, name = "Max On Level", unit = "%"},
            preset_level = {varID = VARIABLE_IDS.PRESET_LEVEL, min = 0, max = 100, name = "Preset Level", unit = "%"},
            click_ramp_rate_up = {varID = VARIABLE_IDS.CLICK_RAMP_RATE_UP, min = 0, max = 5000, name = "Click Ramp Rate Up", unit = "ms"},
            click_ramp_rate_down = {varID = VARIABLE_IDS.CLICK_RAMP_RATE_DOWN, min = 0, max = 5000, name = "Click Ramp Rate Down", unit = "ms"},
            hold_ramp_rate_up = {varID = nil, min = 0, max = 10, name = "Hold Ramp Rate Up", unit = "s"},
            hold_ramp_rate_down = {varID = nil, min = 0, max = 10, name = "Hold Ramp Rate Down", unit = "s"},
            auto_off_time = {varID = nil, min = 0, max = 65535, name = "Auto Off Time", unit = "s"}
        }

        local control = controlMap[controlSuffix]
        if not control then
            LogError("Unknown dimmer control: " .. controlSuffix)
            return
        end

        local proxyID = GetProxyID(dimmerID)
        if DIMMER_CONTROL_VARS[controlSuffix].v2only and not IsLightV2(proxyID) then
            LogError(control.name .. " is not supported by dimmer " .. dimmerID)
            return
        end
        local dimmerName = C4:GetDeviceDisplayName(proxyID)
        control.min, control.max = GetDimmerControlRange(proxyID, controlSuffix)

        -- Parse and validate value
        local value = tonumber(payload)
        if not value then
            local errorMsg = "Invalid value for " .. control.name .. ": " .. tostring(payload)
            LogError(errorMsg)

            -- Revert to current valid value in HA (visual feedback) - only if a value exists
            local currentValue = GetDimmerControlValue(dimmerID, proxyID, controlSuffix)
            local shouldPublish = currentValue ~= nil

            if shouldPublish then
                local stateTopic = "homeassistant/number/control4_" .. dimmerID .. "_" .. controlSuffix .. "/state"
                PublishMQTT(stateTopic, currentValue, 1, true)
            end

            C4:UpdateProperty("Last Command", "ERROR: " .. dimmerName .. " - " .. errorMsg)
            return
        end

        -- Validate range
        if value < control.min or value > control.max then
            local errorMsg = control.name .. " out of range: " .. value .. control.unit .. " (valid: " .. control.min .. "-" .. control.max .. control.unit .. ")"
            LogError(errorMsg)

            -- Revert to current valid value in HA (visual feedback) - only if a value exists
            local currentValue = GetDimmerControlValue(dimmerID, proxyID, controlSuffix)
            local shouldPublish = currentValue ~= nil

            if shouldPublish then
                local stateTopic = "homeassistant/number/control4_" .. dimmerID .. "_" .. controlSuffix .. "/state"
                PublishMQTT(stateTopic, currentValue, 1, true)
            end

            C4:UpdateProperty("Last Command", "ERROR: " .. dimmerName .. " - " .. errorMsg)
            return
        end

        -- Initialize hold ramp rates tracking table if not exists
        if not gHoldRampRates[dimmerID] then
            gHoldRampRates[dimmerID] = {}
        end

        -- Dependency validation: click ramp rate must be <= hold ramp rate
        if controlSuffix == "click_ramp_rate_up" then
            -- Only validate if hold ramp rate up is known
            local holdUp = tonumber(GetDimmerControlValue(dimmerID, proxyID, "hold_ramp_rate_up"))
            if holdUp then
                local holdRampUp = holdUp * 1000  -- Convert seconds to ms
                if value > holdRampUp then
                    local errorMsg = "Click Ramp Rate Up (" .. value .. "ms) cannot be greater than Hold Ramp Rate Up (" .. holdRampUp .. "ms)"
                    LogError(errorMsg)

                    -- Revert to current valid value in HA (visual feedback)
                    local currentValue = GetDimmerControlValue(dimmerID, proxyID, controlSuffix) or "0"
                    local stateTopic = "homeassistant/number/control4_" .. dimmerID .. "_" .. controlSuffix .. "/state"
                    PublishMQTT(stateTopic, currentValue, 1, true)

                    -- Update Last Command with error
                    C4:UpdateProperty("Last Command", "ERROR: " .. dimmerName .. " - " .. errorMsg)
                    return
                end
            end
        elseif controlSuffix == "click_ramp_rate_down" then
            -- Only validate if hold ramp rate down is known
            local holdDown = tonumber(GetDimmerControlValue(dimmerID, proxyID, "hold_ramp_rate_down"))
            if holdDown then
                local holdRampDown = holdDown * 1000  -- Convert seconds to ms
                if value > holdRampDown then
                    local errorMsg = "Click Ramp Rate Down (" .. value .. "ms) cannot be greater than Hold Ramp Rate Down (" .. holdRampDown .. "ms)"
                    LogError(errorMsg)

                    -- Revert to current valid value in HA (visual feedback)
                    local currentValue = GetDimmerControlValue(dimmerID, proxyID, controlSuffix) or "0"
                    local stateTopic = "homeassistant/number/control4_" .. dimmerID .. "_" .. controlSuffix .. "/state"
                    PublishMQTT(stateTopic, currentValue, 1, true)

                    -- Update Last Command with error
                    C4:UpdateProperty("Last Command", "ERROR: " .. dimmerName .. " - " .. errorMsg)
                    return
                end
            end
        elseif controlSuffix == "hold_ramp_rate_up" then
            local clickRampUp = tonumber(GetDimmerControlValue(dimmerID, proxyID, "click_ramp_rate_up")) or 0
            local valueInMs = value * 1000  -- Convert seconds to ms
            if valueInMs < clickRampUp then
                local errorMsg = "Hold Ramp Rate Up (" .. valueInMs .. "ms) must be >= Click Ramp Rate Up (" .. clickRampUp .. "ms)"
                LogError(errorMsg)

                -- Revert to current valid value in HA if one was previously set
                local currentValue = GetDimmerControlValue(dimmerID, proxyID, controlSuffix)
                if currentValue then
                    local stateTopic = "homeassistant/number/control4_" .. dimmerID .. "_" .. controlSuffix .. "/state"
                    PublishMQTT(stateTopic, currentValue, 1, true)
                end

                -- Update Last Command with error
                C4:UpdateProperty("Last Command", "ERROR: " .. dimmerName .. " - " .. errorMsg)
                return
            end
        elseif controlSuffix == "hold_ramp_rate_down" then
            local clickRampDown = tonumber(GetDimmerControlValue(dimmerID, proxyID, "click_ramp_rate_down")) or 0
            local valueInMs = value * 1000  -- Convert seconds to ms
            if valueInMs < clickRampDown then
                local errorMsg = "Hold Ramp Rate Down (" .. valueInMs .. "ms) must be >= Click Ramp Rate Down (" .. clickRampDown .. "ms)"
                LogError(errorMsg)

                -- Revert to current valid value in HA if one was previously set
                local currentValue = GetDimmerControlValue(dimmerID, proxyID, controlSuffix)
                if currentValue then
                    local stateTopic = "homeassistant/number/control4_" .. dimmerID .. "_" .. controlSuffix .. "/state"
                    PublishMQTT(stateTopic, currentValue, 1, true)
                end

                -- Update Last Command with error
                C4:UpdateProperty("Last Command", "ERROR: " .. dimmerName .. " - " .. errorMsg)
                return
            end
        end

        -- Execute the command
        local isV2 = IsLightV2(proxyID)
        if isV2 then
            -- Light V2: the proxy's own setting commands. The light answers the proxy in its own
            -- time (a Zigbee dimmer after the device confirms), so read the settings back once
            -- shortly after: Home Assistant shows what the light actually took.
            local spec = DIMMER_CONTROL_VARS[controlSuffix]
            local setting = value
            if spec.seconds then
                setting = math.floor(value * 1000 + 0.5)
            elseif spec.integer then
                setting = math.floor(value + 0.5)
                value = setting
            end
            C4:SendToDevice(proxyID, spec.command, {[spec.param] = setting})
            ConfirmLightV2Settings(dimmerID)
        elseif control.varID == VARIABLE_IDS.CLICK_RAMP_RATE_UP then
            C4:SendToDevice(dimmerID, "SET_CLICK_RAMP_RATE_UP", {RATE = value})
        elseif control.varID == VARIABLE_IDS.CLICK_RAMP_RATE_DOWN then
            C4:SendToDevice(dimmerID, "SET_CLICK_RAMP_RATE_DOWN", {RATE = value})
        elseif controlSuffix == "hold_ramp_rate_up" then
            -- Hold ramp rates: convert seconds to milliseconds and send command
            local valueInMs = value * 1000
            C4:SendToDevice(dimmerID, "SET_HOLD_RAMP_RATE_UP", {RATE = valueInMs})
            -- Update tracking
            gHoldRampRates[dimmerID].up = value
        elseif controlSuffix == "hold_ramp_rate_down" then
            -- Hold ramp rates: convert seconds to milliseconds and send command
            local valueInMs = value * 1000
            C4:SendToDevice(dimmerID, "SET_HOLD_RAMP_RATE_DOWN", {RATE = valueInMs})
            -- Update tracking
            gHoldRampRates[dimmerID].down = value
        else
            -- For min/max/preset, set variable on proxy ID
            C4:SetDeviceVariable(proxyID, control.varID, value)
        end

        -- Publish state back to Home Assistant immediately (a Light V2 setting the light doesn't
        -- take is put back by the read that follows)
        local stateTopic = "homeassistant/number/control4_" .. dimmerID .. "_" .. controlSuffix .. "/state"
        PublishMQTT(stateTopic, tostring(value), 1, true)  -- QoS 1, retained

        Log("Advanced dimmer control set: " .. dimmerName .. " " .. control.name .. " = " .. value .. control.unit)
        C4:UpdateProperty("Last Command", dimmerName .. " " .. control.name .. " @ " .. os.date("%H:%M:%S"))
        return
    end

    -- Try to parse as thermostat button LED command (format: homeassistant/text/control4_thermostat_<ID>_button_led/set)
    local thermostatLEDIDStr = string.match(topic, "homeassistant/text/control4_thermostat_(%d+)_button_led/set")

    if thermostatLEDIDStr then
        if not IsLEDControlEnabled() then
            return
        end

        local thermostatID = tonumber(thermostatLEDIDStr)  -- Device ID from topic (we store device IDs)

        -- Verify device is in our monitored list (we now store device IDs for consistency)
        if not IsDeviceMonitored(thermostatID, "THERMOSTAT") then
            LogError("Thermostat " .. thermostatID .. " not in monitored list")
            return
        end

        -- Payload is plain hex string (e.g., "00FF00" or "ff0000")
        local hexColor = payload

        -- Validate hex format (6 characters, hex digits)
        if not hexColor or not string.match(hexColor, "^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$") then
            LogError("Invalid hex color format: " .. tostring(payload) .. " (expected 6-char hex like 00FF00)")
            return
        end

        -- Ensure uppercase for consistency
        hexColor = string.upper(hexColor)

        -- Convert hex to RGB string format "255,0,0" for Control4
        local rgbString = HexToRGBString(hexColor)

        -- Send UPDATE_PROPERTY to the device (consistent with how LED commands work on dimmers/switches)
        Log("Sending UPDATE_PROPERTY to thermostat device " .. thermostatID .. ": Button LED Color = " .. rgbString)

        C4:SendToDevice(thermostatID, "UPDATE_PROPERTY", {
            Name = "Button LED Color",
            Value = rgbString
        })

        -- Publish state back to Home Assistant immediately
        local stateTopic = "homeassistant/text/control4_thermostat_" .. thermostatID .. "_button_led/state"
        PublishMQTT(stateTopic, hexColor, 1, true)  -- QoS 1, retained

        local proxyID = GetProxyID(thermostatID)
        local thermostatName = C4:GetDeviceDisplayName(proxyID)
        Log("Thermostat button LED color set: " .. thermostatName .. " = " .. hexColor .. " (C4: " .. rgbString .. ")")
        C4:UpdateProperty("Last Command", thermostatName .. " LED @ " .. os.date("%H:%M:%S"))
        return
    end

    -- Could not parse topic
    if IsLoggingEnabled() then
        Log("Unknown command topic: " .. topic)
    end
end


-- LED Color Conversion Functions
function HexToRGB(hex)
    -- Convert hex color string (e.g., "00FF00") to RGB table {r=0, g=255, b=0}
    if not hex or type(hex) ~= "string" then
        return {r = 0, g = 0, b = 0}
    end

    -- Remove any # prefix if present
    hex = string.gsub(hex, "^#", "")

    -- Ensure it's 6 characters
    if string.len(hex) ~= 6 then
        LogError("Invalid hex color: " .. hex .. " (must be 6 characters)")
        return {r = 0, g = 0, b = 0}
    end

    local r = tonumber(string.sub(hex, 1, 2), 16) or 0
    local g = tonumber(string.sub(hex, 3, 4), 16) or 0
    local b = tonumber(string.sub(hex, 5, 6), 16) or 0

    return {r = r, g = g, b = b}
end

function RGBToHex(r, g, b)
    -- Convert RGB values (0-255) to hex string (e.g., "00FF00")
    r = tonumber(r) or 0
    g = tonumber(g) or 0
    b = tonumber(b) or 0

    -- Clamp values to 0-255 range
    r = math.max(0, math.min(255, r))
    g = math.max(0, math.min(255, g))
    b = math.max(0, math.min(255, b))

    return string.format("%02x%02x%02x", r, g, b)
end

function RGBStringToHex(rgbString)
    -- Convert RGB string format "255,0,0" or "255, 0, 0" to hex string "FF0000"
    if not rgbString or type(rgbString) ~= "string" then
        return "000000"
    end

    -- Parse R,G,B values from comma-separated string (with optional spaces)
    local r, g, b = string.match(rgbString, "^(%d+)%s*,%s*(%d+)%s*,%s*(%d+)$")
    if not r or not g or not b then
        LogError("Invalid RGB string format: " .. rgbString .. " (expected format: R,G,B)")
        return "000000"
    end

    return RGBToHex(r, g, b)
end

function HexToRGBString(hex)
    -- Convert hex string "FF0000" to RGB string format "255,0,0"
    local rgb = HexToRGB(hex)
    return string.format("%d,%d,%d", rgb.r, rgb.g, rgb.b)
end

function IsLEDControlEnabled()
    local enabled = Properties["Enable LED Color Control"] or "Disabled"
    return enabled == "Enabled"
end

function IsAdvancedDimmerControlEnabled()
    local enabled = Properties["Enable Advanced Dimmer Controls"] or "Enabled"  -- Default to Enabled
    return enabled == "Enabled"
end

-- JSON Functions
-- Special marker for JSON null values
JSON_NULL = {}

-- Escape a value for use inside a JSON string. Device names can contain quotes and backslashes.
function EscapeJSON(value)
    return (string.gsub(tostring(value), '[%c"\\]', function(c)
        if c == '"' then
            return '\\"'
        elseif c == "\\" then
            return "\\\\"
        end
        return string.format("\\u%04x", string.byte(c))
    end))
end

function EncodeJSON(tbl)
    -- Check for JSON null marker
    if tbl == JSON_NULL then
        return "null"
    end

    if type(tbl) ~= "table" then
        if type(tbl) == "string" then
            return '"' .. EscapeJSON(tbl) .. '"'
        else
            return tostring(tbl)
        end
    end

    local result = {}
    local isArray = true
    local count = 0

    for k, v in pairs(tbl) do
        count = count + 1
        if type(k) ~= "number" or k ~= count then
            isArray = false
            break
        end
    end

    if isArray then
        for i, v in ipairs(tbl) do
            table.insert(result, EncodeJSON(v))
        end
        return "[" .. table.concat(result, ",") .. "]"
    else
        for k, v in pairs(tbl) do
            local key = '"' .. tostring(k) .. '"'
            local value = EncodeJSON(v)
            table.insert(result, key .. ":" .. value)
        end
        return "{" .. table.concat(result, ",") .. "}"
    end
end

function ParseJSON(str)
    if not str or str == "" then return nil end

    -- Improved JSON parser for our use case
    local result = {}

    -- Remove outer braces and whitespace
    str = string.gsub(str, "^%s*{%s*", "")
    str = string.gsub(str, "%s*}%s*$", "")

    -- Pattern to match key-value pairs handling both quoted and numeric values
    -- This handles: "key":"value", "key":123, "key":"value with spaces"
    local pos = 1
    while pos <= #str do
        -- Match key (always quoted)
        local keyStart = string.find(str, '"', pos)
        if not keyStart then break end

        local keyEnd = string.find(str, '"', keyStart + 1)
        if not keyEnd then break end

        local key = string.sub(str, keyStart + 1, keyEnd - 1)

        -- Find the colon
        local colonPos = string.find(str, ':', keyEnd)
        if not colonPos then break end

        -- Determine value type and extract it
        local valueStart = colonPos + 1
        -- Skip whitespace
        while valueStart <= #str and string.match(string.sub(str, valueStart, valueStart), '%s') do
            valueStart = valueStart + 1
        end

        local value
        local nextComma

        if string.sub(str, valueStart, valueStart) == '"' then
            -- String value
            local valueEnd = string.find(str, '"', valueStart + 1)
            if not valueEnd then break end
            value = string.sub(str, valueStart + 1, valueEnd - 1)
            nextComma = string.find(str, ',', valueEnd)
            pos = nextComma and nextComma + 1 or #str + 1
        else
            -- Numeric or boolean value
            nextComma = string.find(str, ',', valueStart)
            local valueEnd = nextComma and nextComma - 1 or #str
            local rawValue = string.sub(str, valueStart, valueEnd)
            -- Trim whitespace
            rawValue = string.gsub(rawValue, '^%s*(.-)%s*$', '%1')

            -- Try to convert to number
            local numValue = tonumber(rawValue)
            if numValue then
                value = numValue
            elseif rawValue == "true" then
                value = true
            elseif rawValue == "false" then
                value = false
            else
                value = rawValue
            end

            pos = nextComma and nextComma + 1 or #str + 1
        end

        result[key] = value
    end

    return result
end


function ClearAllMonitoredLights()
    Log("========================================")
    Log("Clearing all monitored lights...")
    
    for _, lightID in ipairs(gMonitoredLights) do
        UnsubscribeFromLight(lightID)
    end
    
    gMonitoredLights = {}
    SaveMonitoredLights()
    UpdateLightCount()
    
    Log("All lights cleared from monitoring")
    Log("========================================")
end


-- Remove deleted switches or outlets (no display name any more) from the monitored list and from
-- Home Assistant. Returns how many were removed.
function CleanupDeletedOfType(deviceType)
    local config = DEVICE_TYPES[deviceType]
    local list = GetMonitoredList(deviceType)
    local removed = 0

    for i = #list, 1, -1 do
        local deviceID = list[i]
        if not C4:GetDeviceDisplayName(deviceID) then
            Log("  Found deleted " .. string.lower(config.name) .. ": " .. deviceID)
            UnsubscribeFromDevice(deviceID, deviceType)
            table.remove(list, i)
            removed = removed + 1
            if gMQTTConnected then
                -- Empty payload removes the entity (switches and outlets are both HA switches)
                PublishMQTT("homeassistant/switch/control4_" .. deviceID .. "/config", "", 1, true)
            end
        end
    end

    if removed > 0 then
        SaveMonitoredDevices(deviceType)
        UpdateDeviceCount(deviceType)
        Log("  Removed " .. removed .. " deleted " .. string.lower(removed == 1 and config.name or config.plural))
    end
    return removed
end

function CleanupDeletedDevices()
    Log("========================================")
    Log("Scanning for deleted devices...")

    local deletedDevices = {}

    for _, lightID in ipairs(gMonitoredLights) do
        local lightName = C4:GetDeviceDisplayName(lightID)
        if not lightName then
            table.insert(deletedDevices, lightID)
            Log("  Found deleted device: " .. lightID)
        end
    end

    if #deletedDevices > 0 then
        Log("")
        Log("Removing " .. #deletedDevices .. " deleted device(s)...")

        for _, lightID in ipairs(deletedDevices) do
            RemoveDeletedDevice(lightID)
        end
    end

    local removedOthers = CleanupDeletedOfType("SWITCH") + CleanupDeletedOfType("OUTLET")
    local total = #deletedDevices + removedOthers

    Log("")
    if total == 0 then
        Log("  No deleted devices found")
    else
        Log("Cleanup complete - removed " .. total .. " device(s)")
    end
    Log("========================================")
end


-- Devices deleted from the project ------------------------------------------------------------
-- Composer's delete of an item raises the OnItemRemoved system event. The event is only a hint:
-- its payload isn't relied on. 3 s after the last event every monitored device is checked against
-- C4:GetDevices(); one that is missing there and has no display name is checked again 5 s later
-- (a driver being updated keeps its ID and comes back), and only then removed: from Home
-- Assistant (empty retained configs), its listeners, the saved list and the caches. Nothing here
-- runs on the command or state paths. (OnProjectChanged is deliberately not watched: it fires on
-- almost every Composer edit.)
DELETE_CHECK_DEBOUNCE = 3000
DELETE_CHECK_CONFIRM = 5000
ON_ITEM_REMOVED_FALLBACK = 11 -- C4SystemEvents.OnItemRemoved, if the global is missing
gDeleteCheckTimer = nil
gDeleteConfirmTimer = nil
gSystemEventRawLogged = false
gTrackedNames = {} -- Last display name seen of each monitored device: [id] = name (for the log)
gPendingConfigRemovals = {} -- Config topics to empty on the next connection: [topic] = true

function OnItemRemovedEventID()
    return (C4SystemEvents and C4SystemEvents.OnItemRemoved) or ON_ITEM_REMOVED_FALLBACK
end

function RegisterProjectEvents()
    if not C4.RegisterSystemEvent then
        Log("System events not available: deleted devices are only removed by 'Cleanup Deleted Devices'")
        return
    end
    local eventID = OnItemRemovedEventID()
    local ok, err = pcall(function() C4:RegisterSystemEvent(eventID, 0) end)
    if ok then
        Log("Watching system event OnItemRemoved (" .. tostring(eventID) .. ") for deleted devices")
    else
        LogError("RegisterSystemEvent OnItemRemoved failed: " .. tostring(err))
    end
end

function UnregisterProjectEvents()
    if C4.UnregisterSystemEvent then
        pcall(function() C4:UnregisterSystemEvent(OnItemRemovedEventID(), 0) end)
    end
end

function OnSystemEvent(event)
    local ok, err = pcall(HandleSystemEvent, event)
    if not ok then
        LogError("OnSystemEvent: " .. tostring(err))
    end
end

function HandleSystemEvent(event)
    local raw = tostring(event)
    -- A Light V2 light's setting changed (watched per light, see WatchLightSettingsEvents): not a
    -- project change, and frequent (each step of a slider in Composer)
    if string.find(raw, 'name="OnDataToUI"', 1, true) then
        HandleDataToUI(raw)
        return
    end
    -- The payload format isn't documented: show it (always in debug mode, once per load regardless)
    local line = "System event (raw): " .. string.sub(raw, 1, 500)
    if not gSystemEventRawLogged then
        gSystemEventRawLogged = true
        print(line)  -- shown even with Debug Mode off, once per driver load
        C4:DebugLog(line)
    elseif IsLoggingEnabled() then
        Log(line)
    end
    local name = string.match(raw, 'name%s*=%s*"([^"]*)"') or "?"
    local id = string.match(raw, '[%s<]itemid%s*=%s*"(%d+)"') or string.match(raw, '[%s<]devid%s*=%s*"(%d+)"')
        or string.match(raw, '[%s<]id%s*=%s*"(%d+)"') or string.match(raw, "<itemid>(%d+)</itemid>")
        or string.match(raw, "<devid>(%d+)</devid>") or string.match(raw, "<id>(%d+)</id>")
    Log("System event " .. name .. (id and (": item " .. id) or "") .. " - checking monitored devices in 3 s")
    ScheduleDeletedDeviceCheck()
end

-- Live Light V2 settings. A Light V2 proxy changes no variable when a setting is changed in
-- Composer or on a touchscreen, but the controller raises the OnDataToUI system event for it, from
-- the proxy (CLICK_RATE_UP, HOLD_RATE_DOWN, ...) and from a Gen3 light's device (AUTO_OFF_TIME, ...),
-- with the new value (confirmed on a Gen3 adaptive dimmer, 2026-11-19):
--   <c4soap name="OnDataToUI"><param name="iddevice">888</param><param name="data" type="xml">
--   <HOLD_RATE_UP>5100</HOLD_RATE_UP></param>...</c4soap>
-- Watched for each monitored Light V2 light's device and proxy: [watched ID] = light's device ID
gDataToUIIds = {}

function OnDataToUIEventID()
    return C4SystemEvents and C4SystemEvents.OnDataToUI
end

function WatchLightSettingsEvents(deviceID)
    deviceID = tonumber(deviceID)
    local eventID = OnDataToUIEventID()
    if not (deviceID and eventID and C4.RegisterSystemEvent) then
        return
    end
    for _, id in ipairs({deviceID, tonumber(GetProxyID(deviceID))}) do
        if id and not gDataToUIIds[id] then
            local ok = pcall(function() C4:RegisterSystemEvent(eventID, id) end)
            if ok then
                gDataToUIIds[id] = deviceID
            end
        end
    end
end

function UnwatchLightSettingsEvents(deviceID)
    deviceID = tonumber(deviceID)
    local eventID = OnDataToUIEventID()
    for id, owner in pairs(gDataToUIIds) do
        if owner == deviceID then
            if eventID and C4.UnregisterSystemEvent then
                pcall(function() C4:UnregisterSystemEvent(eventID, id) end)
            end
            gDataToUIIds[id] = nil
        end
    end
    if deviceID and gV1HoldRateTimers[deviceID] then
        CancelTimerObject(gV1HoldRateTimers[deviceID])
        gV1HoldRateTimers[deviceID] = nil
    end
end

-- A setting in the event updates the light's cached settings, and is published. Only settings the
-- light was found to have are taken (the proxy reports every setting for any light); a light not
-- read yet is left for its next read.
function HandleDataToUI(raw)
    local id = tonumber(string.match(raw, '<param name="iddevice"[^>]*>(%d+)</param>'))
    local data = string.match(raw, '<param name="data"[^>]*>(.-)</param>')
    local deviceID = id and gDataToUIIds[id]
    if not (deviceID and data) then
        return
    end
    local proxyID = tonumber(GetProxyID(deviceID))
    if not IsLightV2(proxyID) then
        HandleV1DataToUI(deviceID, id, data)
        return
    end
    local settings = gLightV2Settings[proxyID]
    if not settings then
        return
    end
    local fromDevice = (id ~= proxyID)
    local changed = false
    for tag, value in string.gmatch(data, "<([%w_]+)>([^<]*)</%1>") do
        for suffix, control in pairs(DIMMER_CONTROL_VARS) do
            local controlTag = control.tag
            if fromDevice then
                controlTag = control.device_tag
            elseif control.device_tag then
                controlTag = nil
            end
            if controlTag == tag and settings.values[suffix] ~= nil and settings.values[suffix] ~= value then
                settings.values[suffix] = value
                changed = true
            end
        end
        if fromDevice then
            for suffix, flag in pairs(DEVICE_FLAG_SETTINGS) do
                if flag.tag == tag and settings.flags and settings.flags[suffix] ~= nil then
                    local on = (value == "True" or value == "true" or value == "1")
                    if settings.flags[suffix] ~= on then
                        settings.flags[suffix] = on
                        changed = true
                    end
                end
            end
        end
    end
    if changed and gMQTTConnected and IsAdvancedDimmerControlEnabled() then
        Log("Light " .. deviceID .. " setting changed in Control4: " .. string.sub(data, 1, 100))
        RunWithCachedSettings(function()
            RunSkippingUnchanged(function() PublishDimmerAdvancedControlStates(deviceID) end)
        end)
    end
end

-- V1 dimmers: their hold rates have no variable, but the dimmer's device reports them in
-- OnDataToUI (lowercase, in ms: <hold_ramp_rate_up>3000</hold_ramp_rate_up>). Its other settings
-- are proxy variables, already watched. On a change the V1 driver sends its whole state several
-- times over, with old and new values interleaved (confirmed on a V1 dimmer, 2026-11-19), so the
-- last value is published 1 s after the last report.
V1_HOLD_RATE_SETTLE = 1000
gV1HoldRateTimers = {}

function HandleV1DataToUI(deviceID, id, data)
    if id ~= deviceID then
        return
    end
    local reported = false
    for tag, value in string.gmatch(data, "<([%w_]+)>([^<]*)</%1>") do
        local ms = tonumber(value)
        local key = (tag == "hold_ramp_rate_up" and "up") or (tag == "hold_ramp_rate_down" and "down")
        if key and ms then
            gHoldRampRates[deviceID] = gHoldRampRates[deviceID] or {}
            gHoldRampRates[deviceID][key] = ms / 1000
            reported = true
        end
    end
    if not reported then
        return
    end
    CancelTimerObject(gV1HoldRateTimers[deviceID])
    gV1HoldRateTimers[deviceID] = SafeSetTimer(V1_HOLD_RATE_SETTLE, function()
        gV1HoldRateTimers[deviceID] = nil
        if gMQTTConnected and IsAdvancedDimmerControlEnabled() then
            RunSkippingUnchanged(function() PublishDimmerAdvancedControlStates(deviceID) end)
        end
    end)
end

-- One check 3 s after the last of a burst of events (deleting several devices raises several)
function ScheduleDeletedDeviceCheck()
    CancelTimerObject(gDeleteCheckTimer)
    CancelTimerObject(gDeleteConfirmTimer)
    gDeleteConfirmTimer = nil
    gDeleteCheckTimer = SetUntrackedTimer(DELETE_CHECK_DEBOUNCE, function()
        gDeleteCheckTimer = nil
        local first = FindDeletedDevices()
        if not first or #first == 0 then
            return
        end
        Log(#first .. " monitored device(s) missing from the project - checking again in 5 s")
        gDeleteConfirmTimer = SetUntrackedTimer(DELETE_CHECK_CONFIRM, function()
            gDeleteConfirmTimer = nil
            local again = FindDeletedDevices()
            if not again then
                return
            end
            local stillMissing = {}
            for _, item in ipairs(again) do
                stillMissing[item.deviceType .. ":" .. item.id] = true
            end
            for _, item in ipairs(first) do
                if stillMissing[item.deviceType .. ":" .. item.id] then
                    RemoveDeletedTrackedDevice(item.deviceType, item.id)
                else
                    Log("Device " .. item.id .. " is back in the project: kept")
                end
            end
        end)
    end)
end

-- Monitored devices that are gone from the project, as {deviceType, id}; nil when the project
-- couldn't be read (never take everything as deleted on a failed lookup) or when the result
-- looks wrong (more than half of the monitored devices gone at once)
function FindDeletedDevices()
    local ok, devices = pcall(function() return C4:GetDevices() end)
    if not ok or type(devices) ~= "table" or next(devices) == nil then
        LogError("Deleted device check: the project's device list couldn't be read - nothing removed")
        return nil
    end
    local present = {}
    for deviceID, info in pairs(devices) do
        present[tonumber(deviceID) or deviceID] = true
        if type(info) == "table" then
            for proxyID in pairs(info.proxies or {}) do
                present[tonumber(proxyID) or proxyID] = true
            end
        end
    end

    local deleted, total = {}, 0
    for _, entry in ipairs(TRACKED_TYPES) do
        for _, item in ipairs(GetMonitoredList(entry[1])) do
            local id = tonumber(item)
            if id then
                total = total + 1
                local name = C4:GetDeviceDisplayName(id)
                if name then
                    gTrackedNames[id] = name
                elseif not present[id] then
                    table.insert(deleted, {deviceType = entry[1], id = id})
                end
            end
        end
    end

    -- A single deletion is always taken; several are refused when they are over half of everything
    if #deleted > 1 and #deleted * 2 > total then
        LogError("Deleted device check: " .. #deleted .. " of " .. total .. " monitored devices seem gone at once - " ..
                 "probably the project is still loading, nothing removed. If they really were deleted, run 'Cleanup Deleted Devices'.")
        return nil
    end
    return deleted
end

-- Empty a discovery config now, or on the next connection
function ClearDiscoveryConfig(topic)
    if gMQTTConnected then
        PublishMQTT(topic, "", 1, true)
        gPendingConfigRemovals[topic] = nil
    else
        gPendingConfigRemovals[topic] = true
    end
end

function PublishPendingConfigRemovals()
    for topic in pairs(gPendingConfigRemovals) do
        PublishMQTT(topic, "", 1, true)
    end
    gPendingConfigRemovals = {}
end

-- Drop a contact sensor's entries from the binding map property, so it isn't loaded again
function RemoveFromContactSensorBindingMap(deviceID)
    local kept = {}
    for entry in string.gmatch(Properties["Contact Sensor Binding Map"] or "", "([^,]+)") do
        local entryDevice = tonumber(string.match(entry, "^%s*(%d+)%s*:"))
        if entryDevice ~= deviceID then
            table.insert(kept, (string.match(entry, "^%s*(.-)%s*$")))
        end
    end
    local value = table.concat(kept, ",")
    Properties["Contact Sensor Binding Map"] = value
    C4:UpdateProperty("Contact Sensor Binding Map", value)
end

-- Take one monitored device that was deleted from the project out of everything
function RemoveDeletedTrackedDevice(deviceType, deviceID)
    local list = GetMonitoredList(deviceType)
    local index
    for i, item in ipairs(list) do
        if tonumber(item) == deviceID then
            index = i
            break
        end
    end
    if not index then
        return false
    end

    -- Topics first: a contact sensor's entity names come from its bindings
    local topics = DeviceConfigTopics(deviceType, deviceID)
    local proxyID = nil
    if deviceType == "LIGHT" or deviceType == "SWITCH" or deviceType == "OUTLET" then
        proxyID = GetProxyID(deviceID)
    end

    if deviceType == "CONTACT_SENSOR" then
        for _, varID in ipairs(DEVICE_TYPES.CONTACT_SENSOR.variable_ids) do
            pcall(function() C4:UnregisterVariableListener(deviceID, varID) end)
        end
        local deviceInfo = gContactSensorDevices[deviceID]
        for bindingID in pairs((deviceInfo and deviceInfo.bindings) or {}) do
            gContactSensorBindings[bindingID] = nil
            gContactSensorStates[bindingID] = nil
        end
        gContactSensorDevices[deviceID] = nil
        RemoveFromContactSensorBindingMap(deviceID)
    else
        local ok, err = pcall(UnsubscribeFromDevice, deviceID, deviceType)
        if not ok then
            LogError("Unsubscribing deleted device " .. deviceID .. ": " .. tostring(err))
        end
    end
    if deviceType == "MEDIA_ROOM" then
        CancelTimerObject(gMediaRoomDebounceTimers[deviceID])
        gMediaRoomDebounceTimers[deviceID] = nil
        gMediaRoomPlaybackState[deviceID] = nil
    end

    table.remove(list, index)
    SaveMonitoredDevices(deviceType)
    UpdateDeviceCount(deviceType)
    InvalidateDeviceLookup()

    if proxyID then
        gLightV2Settings[tonumber(proxyID)] = nil
    end
    gLightColorCapsSig[deviceID] = nil
    gLightMisses[deviceID] = nil

    for _, topic in ipairs(topics) do
        ClearDiscoveryConfig(topic)
    end

    local name = gTrackedNames[deviceID] or "(name unknown)"
    gTrackedNames[deviceID] = nil
    Log("Device " .. deviceID .. " " .. name .. " deleted from project: removed from Home Assistant")
    C4:UpdateProperty("Last Event", "Removed deleted " .. name .. " @ " .. os.date("%H:%M:%S"))
    return true
end

-- Names of the monitored devices as they are now (a deleted one has none any more)
function RememberTrackedNames()
    for _, entry in ipairs(TRACKED_TYPES) do
        for _, item in ipairs(GetMonitoredList(entry[1])) do
            local id = tonumber(item)
            local name = id and C4:GetDeviceDisplayName(id)
            if name then
                gTrackedNames[id] = name
            end
        end
    end
end


-- MQTT Protocol Functions
function EncodeMQTTLength(length)
    local encoded = ""
    repeat
        local digit = length % 128
        length = math.floor(length / 128)
        if length > 0 then
            digit = digit + 128
        end
        encoded = encoded .. string.char(digit)
    until length <= 0
    return encoded
end

function DecodeMQTTLength(data, offset)
    local multiplier = 1
    local value = 0
    local index = offset
    
    repeat
        if index > #data then
            return nil, index
        end
        local byte = string.byte(data, index)
        value = value + (byte % 128) * multiplier
        multiplier = multiplier * 128
        index = index + 1
    until (byte < 128)
    
    return value, index
end

-- An MQTT UTF-8 string: two-byte length, then the bytes
function MQTTString(s)
    return string.char(math.floor(#s / 256), #s % 256) .. s
end

-- Packet identifiers for QoS 1 PUBLISH and SUBSCRIBE, from one counter (1-65535, never 0)
function NextPacketID()
    gPacketID = gPacketID + 1
    if gPacketID > 65535 then
        gPacketID = 1
    end
    return gPacketID
end

-- Client ID: unique per driver instance and the same across reconnects, so two bridges on one
-- broker don't take each other's connection: "Control4_HA_<device ID>_<4 hex digits>", the digits
-- chosen once and kept (at most 23 characters, the length every MQTT 3.1.1 broker accepts).
function GetClientID()
    local deviceID = tonumber(C4:GetDeviceID() or "") or 0
    local suffix = C4:PersistGetValue("MQTTClientIDSuffix")
    if type(suffix) ~= "string" or not string.match(suffix, "^%x%x%x%x$") then
        math.randomseed(os.time() + deviceID)
        suffix = string.format("%04x", math.random(0, 65535))
        C4:PersistSetValue("MQTTClientIDSuffix", suffix)
    end
    return "Control4_HA_" .. string.format("%d", deviceID) .. "_" .. suffix
end

function BuildMQTTConnect()
    Log("Building MQTT CONNECT packet...")

    local clientID = GetClientID()
    local username = Properties["MQTT Username"] or ""
    local password = Properties["MQTT Password"] or ""

    local variableHeader = MQTTString("MQTT") .. string.char(0x04)  -- protocol level 4 = MQTT 3.1.1

    -- Connect flags: clean session (0x02), Will (0x04) at QoS 1 (0x08) and retained (0x20), so the
    -- broker publishes "offline" to BRIDGE_STATUS_TOPIC if the connection is lost. User name (0x80)
    -- and password (0x40): MQTT 3.1.1 allows a password only with a user name.
    local connectFlags = 0x02 + 0x04 + 0x08 + 0x20
    if username ~= "" then
        connectFlags = connectFlags + 0x80
        Log("  Username: " .. username)
        if password ~= "" then
            connectFlags = connectFlags + 0x40
            Log("  Password: [SET]")
        end
    elseif password ~= "" then
        LogError("MQTT Password is set without an MQTT Username: the password is not sent")
    end

    variableHeader = variableHeader .. string.char(connectFlags)
    variableHeader = variableHeader .. string.char(math.floor(MQTT_KEEPALIVE_SECONDS / 256), MQTT_KEEPALIVE_SECONDS % 256)

    -- Payload order: client ID, Will topic, Will message, user name, password
    local payload = MQTTString(clientID) .. MQTTString(BRIDGE_STATUS_TOPIC) .. MQTTString("offline")
    if username ~= "" then
        payload = payload .. MQTTString(username)
        if password ~= "" then
            payload = payload .. MQTTString(password)
        end
    end

    local remainingLength = #variableHeader + #payload
    local packet = string.char(0x10) .. EncodeMQTTLength(remainingLength) .. variableHeader .. payload

    Log("  Client ID: " .. clientID)
    Log("  Will: " .. BRIDGE_STATUS_TOPIC .. " = offline (retained, QoS 1)")
    Log("  Packet size: " .. #packet .. " bytes")

    return packet
end

-- One SUBSCRIBE for one topic filter or a list of them, all at the same QoS. Returns the packet and
-- its packet ID.
function BuildMQTTSubscribe(topics, qos)
    if type(topics) == "string" then
        topics = {topics}
    end
    qos = qos or 0

    local packetID = NextPacketID()
    local variableHeader = string.char(math.floor(packetID / 256), packetID % 256)

    local payload = ""
    for _, topic in ipairs(topics) do
        Log("  Subscribing to: " .. topic .. " (QoS " .. qos .. ")")
        payload = payload .. MQTTString(topic) .. string.char(qos)
    end

    local remainingLength = #variableHeader + #payload
    local packet = string.char(0x82) .. EncodeMQTTLength(remainingLength) .. variableHeader .. payload  -- SUBSCRIBE (flags 0010)

    return packet, packetID
end

function BuildMQTTPublish(topic, message, qos, retain)
    qos = qos or 0
    retain = retain or false

    local fixedHeader = 0x30
    if retain then
        fixedHeader = fixedHeader + 0x01
    end
    fixedHeader = fixedHeader + (qos * 2)

    local variableHeader = MQTTString(topic)

    if qos > 0 then
        local packetID = NextPacketID()
        variableHeader = variableHeader .. string.char(math.floor(packetID / 256), packetID % 256)
    end

    local payload = message
    local remainingLength = #variableHeader + #payload
    local packet = string.char(fixedHeader) .. EncodeMQTTLength(remainingLength) .. variableHeader .. payload

    return packet
end

function BuildMQTTPubAck(packetID)
    -- PUBACK packet: fixed header (0x40) + remaining length (2) + packet ID (2 bytes)
    local fixedHeader = string.char(0x40, 0x02)
    local variableHeader = string.char(math.floor(packetID / 256), packetID % 256)
    return fixedHeader .. variableHeader
end

function BuildMQTTPingReq()
    return string.char(0xC0, 0x00)
end

-- Topic filters of SUBSCRIBEs not yet answered, by packet ID (to name a refused one)
gPendingSubscribes = {}

function ParseMQTTPacket(data)
    if #data < 2 then
        return nil
    end

    local firstByte = string.byte(data, 1)
    local messageType = math.floor(firstByte / 16)
    local remainingLength, offset = DecodeMQTTLength(data, 2)

    if not remainingLength then
        return nil
    end

    -- CONNACK (type 2)
    if messageType == MQTT_TYPES.CONNACK and #data >= offset + 1 then
        local returnCode = string.byte(data, offset + 1)

        if returnCode == 0 then
            return "CONNACK_SUCCESS"
        else
            local messages = {
                [1] = "Unacceptable protocol version",
                [2] = "Identifier rejected",
                [3] = "Server unavailable",
                [4] = "Bad username or password",
                [5] = "Not authorized"
            }
            LogError("MQTT connection refused: " .. (messages[returnCode] or "Unknown"))
            return "CONNACK_FAILED"
        end
    end

    -- SUBACK (type 9): packet ID, then one return code per topic filter (0-2 granted QoS, 0x80 failure)
    if messageType == MQTT_TYPES.SUBACK then
        local packetID = (string.byte(data, offset) or 0) * 256 + (string.byte(data, offset + 1) or 0)
        local topics = gPendingSubscribes[packetID] or {}
        gPendingSubscribes[packetID] = nil
        local refused = 0
        for i = offset + 2, offset + remainingLength - 1 do
            local code = string.byte(data, i)
            local index = i - offset - 1
            if code == 0x80 then
                refused = refused + 1
                LogError("Broker refused subscription to " .. tostring(topics[index] or ("filter " .. index)) ..
                    " - commands from Home Assistant on it will not arrive (check the broker's ACL)")
            elseif IsLoggingEnabled() then
                Log("SUBACK: " .. tostring(topics[index] or ("filter " .. index)) .. " granted QoS " .. tostring(code))
            end
        end
        if refused == 0 then
            Log("SUBACK received - subscribed successfully")
        end
        return "SUBACK"
    end

    -- PUBLISH (type 3)
    if messageType == MQTT_TYPES.PUBLISH then
        -- Check we have enough data for topic length
        if #data < offset + 2 then
            if IsLoggingEnabled() then
                Log("Incomplete PUBLISH packet - need more data")
            end
            return nil
        end

        -- Parse topic length (2 bytes, big-endian)
        local topicLen = string.byte(data, offset) * 256 + string.byte(data, offset + 1)
        offset = offset + 2

        -- Check we have enough data for the topic
        if #data < offset + topicLen - 1 then
            if IsLoggingEnabled() then
                Log("Incomplete topic - need more data")
            end
            return nil
        end

        -- Extract topic
        local topic = string.sub(data, offset, offset + topicLen - 1)
        offset = offset + topicLen

        -- QoS from fixed header (bits 1-2, above the retain bit and below the DUP bit); retain = bit 0
        local qos = math.floor((firstByte % 8) / 2)
        local retained = (firstByte % 2) == 1

        -- If QoS > 0, extract packet ID (2 bytes)
        local packetID = nil
        if qos > 0 then
            packetID = string.byte(data, offset) * 256 + string.byte(data, offset + 1)
            offset = offset + 2
        end

        -- Rest is payload
        local payload = string.sub(data, offset)

        -- Acknowledge a QoS 1 message before handling it: the handler can't delay or (by failing)
        -- prevent the acknowledgement, which would make the broker send the command again
        if qos == 1 and packetID then
            SendToBroker(BuildMQTTPubAck(packetID))
            if IsLoggingEnabled() then
                Log("PUBACK sent for packet ID: " .. packetID)
            end
        end

        -- A retained message on a command topic was left on the broker by some client; the broker
        -- delivers it (retain flag set) when we subscribe. It is an old command, not a new one.
        if retained and string.find(topic, "/set$") then
            if not gRetainedSetLogged[topic] then
                gRetainedSetLogged[topic] = true
                LogError("Ignoring retained command on " .. topic ..
                    " (clear it on the broker with an empty retained message)")
            end
            return "PUBLISH"
        end

        if topic == HA_STATUS_TOPIC then
            HandleHomeAssistantStatus(payload, retained)
            return "PUBLISH"
        end

        -- Handle the command
        local ok, err = pcall(HandleMQTTCommand, topic, payload)
        if not ok then
            LogError("Command on " .. topic .. " failed: " .. tostring(err))
        end

        return "PUBLISH"
    end

    -- PUBACK (type 4)
    if messageType == MQTT_TYPES.PUBACK then
        return "PUBACK"
    end

    -- PINGRESP (type 13)
    if messageType == MQTT_TYPES.PINGRESP then
        Log("PINGRESP received - connection alive")
        return "PINGRESP"
    end

    return "UNKNOWN"
end

-- Home Assistant's birth message ("online" on homeassistant/status): Home Assistant has (re)started
-- and forgotten entities whose discovery isn't retained, so send discovery again, then states.
-- A retained birth message is delivered (retain flag set) only because we have just subscribed:
-- that is not a restart, and discovery is being sent for the new connection anyway.
function HandleHomeAssistantStatus(payload, retained)
    if payload ~= "online" then
        Log("Home Assistant status: " .. tostring(payload))
        return
    end
    if retained then
        Log("Home Assistant status 'online' (retained): no restart, nothing to do")
        return
    end
    Log("Home Assistant (re)started: sending discovery and states again")
    gLastPublished = {}
    PublishMQTT(BRIDGE_STATUS_TOPIC, "online", 1, true)
    RepublishDiscoveryAndStates("Home Assistant started")
end

-- Paced discovery for every device, then every state. Only one run at a time: a request during a
-- run makes it run once more at its end.
function RepublishDiscoveryAndStates(reason)
    if not gMQTTConnected then
        return
    end
    if gDiscoveryInProgress then
        Log("Discovery already being sent: once more when it finishes (" .. tostring(reason) .. ")")
        gDiscoveryRerun = true
        return
    end
    Log("Sending discovery for all devices (" .. tostring(reason) .. ")")
    PublishAllDiscovery(true, function()
        RunWithCachedSettings(PublishAllStates)
        if gDiscoveryRerun then
            gDiscoveryRerun = false
            RepublishDiscoveryAndStates("requested during the last run")
        end
    end)
end

-- Every monitored device's current state, from what the controller and the cached Light V2 settings
-- say (no new reads from the light proxies)
function PublishAllStates()
    if not gMQTTConnected then
        return
    end
    for _, lightID in ipairs(gMonitoredLights) do
        PublishLightState(lightID)
        if IsLEDControlEnabled() then
            PublishAllLEDStates(lightID)
        end
        if IsAdvancedDimmerControlEnabled() then
            PublishDimmerAdvancedControlStates(lightID)
        end
        PublishEnergyStates(lightID)
    end
    for _, switchID in ipairs(gMonitoredSwitches) do
        PublishSwitchState(switchID)
        PublishEnergyStates(switchID)
        if IsLEDControlEnabled() then
            PublishAllLEDStates(switchID)
        end
    end
    for _, outletID in ipairs(gMonitoredOutlets) do
        PublishOutletState(outletID)
    end
    for _, thermostatID in ipairs(gMonitoredThermostats) do
        PublishThermostatState(thermostatID)
        PublishThermostatButtonLEDState(thermostatID)
    end
    for _, roomID in ipairs(gMonitoredMediaRooms) do
        PublishMediaRoomState(roomID)
    end
    for _, sensorID in ipairs(gMonitoredContactSensors) do
        PublishContactSensorState(sensorID)
    end
end

-- Connection Functions
function IsBrokerConfigured()
    local ip = Properties["MQTT Broker IP"]
    return ip ~= nil and ip ~= "" and ip ~= BROKER_IP_PLACEHOLDER
end

-- The broker port of the current connection (the property may have changed since it was opened)
function GetConnPort()
    return gConnPort or tonumber(Properties["MQTT Broker Port"]) or 1883
end

function SendToBroker(packet)
    C4:SendToNetwork(MQTT_BINDING_ID, GetConnPort(), packet)
end

function ConnectToBroker()
    local ip = Properties["MQTT Broker IP"]
    local port = tonumber(Properties["MQTT Broker Port"]) or 1883

    if not IsBrokerConfigured() then
        LogError("Cannot connect: No IP configured")
        C4:UpdateProperty("Connection Status", "Error: No IP")
        return false
    end

    -- This is the connect attempt in flight: a pending reconnect is no longer needed
    if gReconnectTimer then
        CancelTimerObject(gReconnectTimer)
        gReconnectTimer = nil
    end
    -- Already connected (the start-up timer after a connect by other means): nothing to do. The
    -- Connect action closes a connection first.
    if gConnected then
        Log("Already connected to the MQTT broker")
        return true
    end

    Log("========================================")
    Log("Connecting to MQTT Broker: " .. ip .. ":" .. port)
    Log("========================================")

    C4:UpdateProperty("Connection Status", "Connecting...")

    -- The address this connection uses until it is closed
    gConnIP, gConnPort = ip, port
    gConnecting = true
    gConnectStarted = os.time()

    -- Create dynamic network connection using C4's native network stack
    C4:CreateNetworkConnection(MQTT_BINDING_ID, ip, "TCP")

    -- Connect to the MQTT broker
    C4:NetConnect(MQTT_BINDING_ID, port, "TCP")

    Log("Network connection initiated (event-driven mode)...")

    return true
end

-- Reconnect after a lost or failed connection: 2 s, then doubling up to 60 s while attempts fail
-- (reset by a CONNACK). Only one reconnect is ever pending. force: replace a pending one and
-- reconnect even with Auto Reconnect disabled (the broker settings were changed).
function ScheduleReconnect(force)
    if gReconnectTimer then
        if not force then
            return
        end
        CancelTimerObject(gReconnectTimer)
        gReconnectTimer = nil
    end
    local delay = math.floor(math.min(TIMER_INTERVALS.RECONNECT_MIN * 2 ^ gReconnectAttempts, TIMER_INTERVALS.RECONNECT_MAX))
    gReconnectAttempts = gReconnectAttempts + 1
    gStats.reconnects = gStats.reconnects + 1
    Log("Reconnecting in " .. (delay / 1000) .. " s")
    local timer
    timer = SetUntrackedTimer(delay, function()
        if gReconnectTimer ~= timer then
            return  -- replaced or cancelled
        end
        gReconnectTimer = nil
        if gManualDisconnect then
            return
        end
        if not force and (Properties["Auto Reconnect"] or "Enabled") ~= "Enabled" then
            return
        end
        if gConnected or gMQTTConnected then
            return
        end
        if gConnecting and os.time() - gConnectStarted < 30 then
            return
        end
        ConnectToBroker()
    end)
    gReconnectTimer = timer
end

-- C4 Network Callback: Called when connection status changes
function OnConnectionStatusChanged(idBinding, nPort, strStatus)
    if idBinding ~= MQTT_BINDING_ID then
        return
    end

    Log("Connection status changed: " .. tostring(strStatus) .. " (port " .. tostring(nPort) .. ")")

    -- A late event of a connection on a port no longer used (the port property was changed)
    if gConnPort and tonumber(nPort) and tonumber(nPort) ~= gConnPort then
        Log("  ignored: not the current connection's port (" .. gConnPort .. ")")
        return
    end

    if strStatus == "ONLINE" then
        Log("TCP connected!")
        gConnecting = false
        gConnected = true
        gMQTTBuffer = ""  -- A partial packet from the last connection would swallow the CONNACK
        gLastInbound = os.time()
        C4:UpdateProperty("Connection Status", "TCP Connected")

        SendMQTTConnect()
        -- Note: No need to call StartReceiveLoop() - data will arrive via ReceivedFromNetwork callback
    elseif strStatus == "OFFLINE" then
        Log("TCP connection lost")
        gConnecting = false
        gConnected = false
        gMQTTConnected = false
        gMQTTBuffer = ""
        CancelConnectionTimers()
        C4:UpdateProperty("Connection Status", "Disconnected")
        if not gManualDisconnect and (Properties["Auto Reconnect"] or "Enabled") == "Enabled" and IsBrokerConfigured() then
            ScheduleReconnect()
        end
    end
end

function SendMQTTConnect()
    if not gConnected then
        return false
    end

    SendToBroker(BuildMQTTConnect())

    Log("MQTT CONNECT sent")
    C4:UpdateProperty("Connection Status", "Waiting for CONNACK...")

    return true
end

-- Command topics: wildcard filters that cover every entity's /set topic (see COMMAND_TOPIC_FILTERS),
-- so a device added later is controllable at once; HandleMQTTCommand picks out the topics of
-- monitored devices. Also Home Assistant's birth message. One SUBSCRIBE packet.
function SubscribeToCommandTopics()
    if not gMQTTConnected then
        Log("Cannot subscribe - not connected")
        return false
    end

    local topics = {}
    for _, filter in ipairs(COMMAND_TOPIC_FILTERS) do
        table.insert(topics, filter)
    end
    table.insert(topics, HA_STATUS_TOPIC)

    local packet, packetID = BuildMQTTSubscribe(topics, 1)
    gPendingSubscribes[packetID] = topics
    SendToBroker(packet)
    Log("Subscribed to command topics and Home Assistant status")
    return true
end

-- The broker accepted the connection
function OnMQTTConnected()
    gMQTTConnected = true
    gReconnectAttempts = 0
    gLastPublished = {}
    gPendingSubscribes = {}
    gLastInbound = os.time()
    C4:UpdateProperty("Connection Status", "MQTT Connected ✓")
    Log("========================================")
    Log("SUCCESS! MQTT Connected")
    Log("========================================")

    -- Entities become available again (the Will said offline)
    PublishMQTT(BRIDGE_STATUS_TOPIC, "online", 1, true)

    -- Devices deleted from the project while disconnected leave Home Assistant now
    PublishPendingConfigRemovals()

    StartKeepAlive()

    -- Commands are taken from here on
    SubscribeToCommandTopics()

    -- States first (anything that changed while disconnected), then discovery paced device by
    -- device, then all states again. All from variables and cached Light V2 settings: no
    -- blocking SendUIRequest reads, so a command from Home Assistant is never kept waiting.
    if #gMonitoredLights > 0 or #gMonitoredSwitches > 0 or #gMonitoredOutlets > 0 or #gMonitoredThermostats > 0 or #gMonitoredMediaRooms > 0 then
        Log("Publishing initial states...")
        SafeSetTimer(TIMER_INTERVALS.RECONNECT_DELAY, function()
            RunWithCachedSettings(PublishAllStates)
        end)
    end
    SafeSetTimer(TIMER_INTERVALS.RECONNECT_DELAY + TIMER_INTERVALS.DISCOVERY_DELAY, function()
        RepublishDiscoveryAndStates("connected")
    end)
end

-- C4 Network Callback: Called when data is received from the network
function ReceivedFromNetwork(idBinding, nPort, strData)
    if idBinding ~= MQTT_BINDING_ID then
        return
    end

    if not gConnected then
        return
    end

    if not strData or #strData == 0 then
        return
    end

    gLastInbound = os.time()
    gStats.messagesReceived = gStats.messagesReceived + 1
    UpdateStatsProperties()

    -- Out of step with the broker (a packet larger than we take, or a stream we can't parse): start
    -- a clean connection rather than guess where the next packet begins
    if #gMQTTBuffer + #strData > LIMITS.MAX_BUFFER_SIZE then
        LogError("Receive buffer overflow (" .. (#gMQTTBuffer + #strData) .. " bytes) - reconnecting")
        DisconnectFromBroker()
        ScheduleReconnect()
        return
    end

    -- Add to buffer
    gMQTTBuffer = gMQTTBuffer .. strData

    -- Process all complete packets in buffer
    while #gMQTTBuffer >= 2 do
        local remainingLength, offset = DecodeMQTTLength(gMQTTBuffer, 2)

        if not remainingLength then
            break
        end

        -- Validate packet size
        if remainingLength > LIMITS.MAX_PACKET_SIZE then
            LogError("Invalid packet size: " .. remainingLength .. " bytes (max " .. LIMITS.MAX_PACKET_SIZE .. ") - reconnecting")
            DisconnectFromBroker()
            ScheduleReconnect()
            return
        end

        -- Total packet length = fixed header (1 byte) + encoded length bytes + remaining length
        local totalLength = 1 + (offset - 2) + remainingLength

        if #gMQTTBuffer < totalLength then
            break
        end

        -- Extract complete packet
        local packet = string.sub(gMQTTBuffer, 1, totalLength)
        gMQTTBuffer = string.sub(gMQTTBuffer, totalLength + 1)

        -- Process packet (an error in one packet doesn't stop the ones after it)
        local ok, result = pcall(ParseMQTTPacket, packet)
        if not ok then
            LogError("MQTT packet handling failed: " .. tostring(result))
            result = nil
        end

        if result == "CONNACK_SUCCESS" then
            OnMQTTConnected()
        elseif result == "CONNACK_FAILED" then
            DisconnectFromBroker()
            if not gManualDisconnect and (Properties["Auto Reconnect"] or "Enabled") == "Enabled" then
                ScheduleReconnect()
            end
            return
        end

        if not gConnected then
            return  -- a handler closed the connection
        end
    end
end

function DisconnectFromBroker()
    Log("Disconnecting from MQTT broker...")

    CancelConnectionTimers()
    if gReconnectTimer then
        CancelTimerObject(gReconnectTimer)
        gReconnectTimer = nil
    end

    -- Disconnect using C4 network stack, on the port the connection was opened with
    C4:NetDisconnect(MQTT_BINDING_ID, GetConnPort())

    gConnected = false
    gMQTTConnected = false
    gConnecting = false
    gMQTTBuffer = ""
    C4:UpdateProperty("Connection Status", "Disconnected")
    Log("Disconnected")
end

-- Keep alive: a PINGREQ every PINGREQ_INTERVAL seconds, and a liveness check every tick. The
-- broker answers every PINGREQ, so nothing from it for 1.5x the keep alive means the connection
-- is dead (a half-open TCP connection never reports OFFLINE): reconnect.
function StartKeepAlive()
    CancelTimerObject(gKeepAliveTimer)
    gLastPingSent = os.time()
    gLastInbound = os.time()

    gKeepAliveTimer = C4:SetTimer(TIMER_INTERVALS.KEEPALIVE_TICK, function(timer)
        local ok, err = pcall(KeepAliveTick)
        if not ok then
            LogError("Keep-alive error: " .. tostring(err))
        end
    end, true)

    Log("Keep-alive started (PINGREQ every " .. TIMER_INTERVALS.PINGREQ_INTERVAL .. " s, dead after " ..
        (MQTT_KEEPALIVE_SECONDS * 1.5) .. " s of silence)")
end

function KeepAliveTick()
    if not gMQTTConnected then
        return
    end
    local now = os.time()
    if now - gLastInbound > MQTT_KEEPALIVE_SECONDS * 1.5 then
        LogError("Nothing from the broker for " .. (now - gLastInbound) .. " s - connection dead, reconnecting")
        DisconnectFromBroker()
        ScheduleReconnect()
        return
    end
    if now - gLastPingSent >= TIMER_INTERVALS.PINGREQ_INTERVAL then
        SendPingReq()
    end
end

function SendPingReq()
    if not gMQTTConnected then
        -- The connection watchdog does the reconnecting, if Auto Reconnect is enabled
        Log("PINGREQ skipped - not connected")
        return
    end

    gLastPingSent = os.time()
    SendToBroker(BuildMQTTPingReq())
    Log("PINGREQ sent")
end

-- Timers that only apply to the current connection. The watchdog isn't one of them: it keeps
-- running through a disconnect so that it can reconnect.
function CancelConnectionTimers()
    if gKeepAliveTimer then
        CancelTimerObject(gKeepAliveTimer)
        gKeepAliveTimer = nil
    end
    -- Cancel all tracked timers
    for timer in pairs(gActiveTimers) do
        pcall(function() timer:Cancel() end)
    end
    gActiveTimers = {}
    -- Their work stops with them
    gDiscoveryInProgress = false
    gDiscoveryRerun = false
end

-- Every timer, for when the driver shuts down
function CancelTimers()
    CancelConnectionTimers()
    if gReconnectTimer then
        CancelTimerObject(gReconnectTimer)
        gReconnectTimer = nil
    end
    if gStatsTimer then
        CancelTimerObject(gStatsTimer)
        gStatsTimer = nil
    end
    if gRescanTimer then
        CancelTimerObject(gRescanTimer)
        gRescanTimer = nil
    end
    if gWatchdogTimer then
        gWatchdogTimer:Cancel()
        gWatchdogTimer = nil
    end
    if gDebugModeTimer then
        gDebugModeTimer:Cancel()
        gDebugModeTimer = nil
    end
end

-- Messages Sent / Received properties: at most every STATS_PROPERTY_INTERVAL seconds (a property
-- update per message is work for Director and every Composer connected)
function UpdateStatsProperties()
    local now = os.time()
    if now - gLastStatsUpdate >= TIMER_INTERVALS.STATS_PROPERTY_INTERVAL then
        gLastStatsUpdate = now
        C4:UpdateProperty("Messages Sent", tostring(gStats.messagesSent))
        C4:UpdateProperty("Messages Received", tostring(gStats.messagesReceived))
    elseif not gStatsTimer then
        gStatsTimer = SetUntrackedTimer(TIMER_INTERVALS.STATS_PROPERTY_INTERVAL * 1000, function()
            gStatsTimer = nil
            gLastStatsUpdate = os.time()
            C4:UpdateProperty("Messages Sent", tostring(gStats.messagesSent))
            C4:UpdateProperty("Messages Received", tostring(gStats.messagesReceived))
        end)
    end
end

function PublishMQTT(topic, message, qos, retain)
    if not gMQTTConnected then
        LogError("Cannot publish - not connected")
        return false
    end

    -- A state change publish (see RunSkippingUnchanged) doesn't send what was last sent
    if gSkipUnchanged and gLastPublished[topic] == message then
        return true
    end

    local success, result = pcall(function()
        SendToBroker(BuildMQTTPublish(topic, message, qos, retain))
        return true
    end)

    if not success then
        LogError("Publish failed with exception: " .. tostring(result))
        -- Trigger reconnect
        DisconnectFromBroker()
        ScheduleReconnect()
        return false
    end

    -- Remember state payloads (not discovery configs, which are large and always sent)
    if not string.find(topic, "/config$") then
        gLastPublished[topic] = message
    end
    gStats.messagesSent = gStats.messagesSent + 1
    UpdateStatsProperties()
    return true
end

-- UI Request Handler for Dynamic Actions
function UIRequest(request)
    return {}
end

-- Command Handler
function ExecuteCommand(cmd, params)
    Log("Command: " .. cmd)
    
    if cmd == "LUA_ACTION" and params and params.ACTION then
        cmd = params.ACTION
    end
    
    if cmd == "Connect" then
        gManualDisconnect = false
        if gConnected then
            DisconnectFromBroker()  -- (re)connect with the current settings
        end
        ConnectToBroker()
        
    elseif cmd == "Disconnect" then
        gManualDisconnect = true
        if gMQTTConnected then
            PublishMQTT(BRIDGE_STATUS_TOPIC, "offline", 1, true)
        end
        DisconnectFromBroker()
        
    elseif cmd == "PublishTest" then
        local topic = "homeassistant/control4/test"
        local message = "Test from Control4 at " .. os.date("%Y-%m-%d %H:%M:%S")
        PublishMQTT(topic, message, 0, false)
        
    elseif cmd == "CleanupDeleted" then
        CleanupDeletedDevices()

    elseif cmd == "PublishDiscovery" then
        PublishAllDiscovery()

    elseif cmd == "RemoveAllEntities" then
        RemoveAllEntities()

    elseif cmd == "ShowInfo" then
        Log("========================================")
        Log("Connection Info:")
        Log("  TCP: " .. tostring(gConnected))
        Log("  MQTT: " .. tostring(gMQTTConnected))
        Log("  Broker: " .. Properties["MQTT Broker IP"] .. ":" .. Properties["MQTT Broker Port"])
        Log("  Monitored Lights: " .. #gMonitoredLights)
        Log("  Monitored Switches: " .. #gMonitoredSwitches)
        Log("  Monitored Outlets: " .. #gMonitoredOutlets)
        Log("  Total Devices: " .. (#gMonitoredLights + #gMonitoredSwitches + #gMonitoredOutlets) .. "/" .. LIMITS.MAX_MONITORED_LIGHTS)
        Log("  Monitored Thermostats: " .. #gMonitoredThermostats)
        Log("  Monitored Media Rooms: " .. #gMonitoredMediaRooms)
        Log("  Monitored Contact Sensors: " .. #gMonitoredContactSensors)
        Log("  Bidirectional: Yes")
        Log("  Auto-Discovery: Enabled")
        Log("")
        Log("Statistics:")
        Log("  Messages Sent: " .. gStats.messagesSent)
        Log("  Messages Received: " .. gStats.messagesReceived)
        Log("  Errors: " .. gStats.errors)
        Log("  Reconnects: " .. gStats.reconnects)
        Log("  Last Error: " .. gStats.lastError)
        Log("  Buffer Size: " .. #gMQTTBuffer .. " bytes")
        Log("========================================")

    -- Unified Device Management Commands
    elseif cmd == "DiscoverAll" then
        Log("Auto-discovering all device types...")
        LoadSwitchIDsFromProperty()  -- Refresh switch IDs first
        DiscoverAllDevices("LIGHT")
        DiscoverAllDevices("SWITCH")
        DiscoverAllDevices("OUTLET")
        DiscoverAllDevices("THERMOSTAT")
        Log("All device discovery complete")

        -- No re-subscribing: the wildcard command subscriptions already cover new devices

    elseif cmd == "ListAll" then
        ListMonitoredDevices("LIGHT")
        ListMonitoredDevices("SWITCH")
        ListMonitoredDevices("OUTLET")
        ListMonitoredDevices("THERMOSTAT")
        ListMonitoredDevices("MEDIA_ROOM")
        ListMonitoredDevices("CONTACT_SENSOR")

    elseif cmd == "RefreshAll" then
        RefreshAllDeviceStates("LIGHT")
        RefreshAllDeviceStates("SWITCH")
        RefreshAllDeviceStates("OUTLET")
        RefreshAllDeviceStates("THERMOSTAT")
        RefreshAllDeviceStates("MEDIA_ROOM")
        RefreshAllDeviceStates("CONTACT_SENSOR")

    elseif cmd == "Add Light to Monitor" then
        local lightID = params["Light Device ID"]
        if lightID then
            AddLightToMonitor(lightID)
        end
        
    elseif cmd == "Remove Light from Monitor" then
        local lightID = params["Light Device ID"]
        if lightID then
            RemoveLightFromMonitor(lightID)
        end
        
    elseif cmd == "Clear All Monitored Lights" then
        ClearAllMonitoredLights()

    elseif cmd == "Inspect Device" then
        local deviceID = tonumber(params["Device ID"])
        if deviceID then
            InspectDevice(deviceID)
        else
            LogError("Invalid device ID for inspection")
        end

    elseif cmd == "Send MQTT Command" then
        local topic = params["Topic"]
        local payload = params["Payload"]
        if topic then
            -- Default payload to "on" if not specified
            if not payload or payload == "" then
                payload = "on"
            end

            if PublishMQTT(topic, payload, 0, false) then
                Log("MQTT command sent - Topic: " .. topic .. ", Payload: " .. payload)
                C4:UpdateProperty("Last Command", "MQTT: " .. topic .. " @ " .. os.date("%H:%M:%S"))
            else
                LogError("Failed to send MQTT command to topic: " .. topic)
            end
        else
            LogError("Topic required for MQTT command")
        end

    elseif cmd == "Add Thermostat to Monitor" then
        local thermostatID = params["Thermostat Device ID"]
        if thermostatID then
            AddThermostatToMonitor(thermostatID)
        else
            LogError("Thermostat Device ID required")
        end

    elseif cmd == "Remove Thermostat from Monitor" then
        local thermostatID = params["Thermostat Device ID"]
        if thermostatID then
            RemoveThermostatFromMonitor(thermostatID)
        else
            LogError("Thermostat Device ID required")
        end

    elseif cmd == "Add Switch to Monitor" then
        local switchID = params["Control4 Device ID"]
        if switchID then
            AddSwitchToMonitor(switchID)
        else
            LogError("Control4 Device ID required")
        end

    elseif cmd == "Remove Switch from Monitor" then
        local switchID = params["Control4 Device ID"]
        if switchID then
            RemoveSwitchFromMonitor(switchID)
        else
            LogError("Control4 Device ID required")
        end

    elseif cmd == "Add Outlet to Monitor" then
        local outletID = params["Outlet Device ID"]
        if outletID then
            AddOutletToMonitor(outletID)
        else
            LogError("Outlet Device ID required")
        end

    elseif cmd == "Remove Outlet from Monitor" then
        local outletID = params["Outlet Device ID"]
        if outletID then
            RemoveOutletFromMonitor(outletID)
        else
            LogError("Outlet Device ID required")
        end

    elseif cmd == "Add Media Room to Monitor" then
        local roomID = params["Room ID"]
        if roomID then
            AddMediaRoomToMonitor(roomID)
        else
            LogError("Room ID required")
        end

    elseif cmd == "Remove Media Room from Monitor" then
        local roomID = params["Room ID"]
        if roomID then
            RemoveMediaRoomFromMonitor(roomID)
        else
            LogError("Room ID required")
        end

    else
        if IsLoggingEnabled() then
            Log("Unknown command: " .. cmd)
        end
    end
end