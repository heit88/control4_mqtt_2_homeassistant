-- Control4 to Home Assistant MQTT Bridge
-- Author: John Heit
-- Copyright 2025 Heit Automation
-- Licensed under the MIT License, see the LICENSE file
-- Version 4.5 - Native C4 Network Stack (Event-Driven), Light V2 color lights

-- Constants
local MQTT_BINDING_ID = 6001  -- Network binding ID for MQTT broker connection
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

    -- Light V2 (light_v2.c4i) proxy variables: the level, state and click rates match V1 above,
    -- but the other settings moved (1004 is Hold Rate Up here, not the preset)
    V2_HOLD_RATE_UP = 1004,         -- Hold rate up (ms)
    V2_HOLD_RATE_DOWN = 1005,       -- Hold rate down (ms)
    V2_PRESET_LEVEL = 1006,         -- Default On preset brightness (%)
    V2_MAX_ON_LEVEL = 1007,         -- Max brightness (%)
    V2_MIN_ON_LEVEL = 1008,         -- Min brightness (%)
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
    RECONNECT_DELAY = 2000
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
        proxy_names = {"outlet_light.c4i"},
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

-- Initialization
function OnDriverInit()
    Log("========================================")
    Log("Control4 to Home Assistant MQTT Bridge")
    Log("Author: John Heit - Version 4.5")
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
                gStats.reconnects = gStats.reconnects + 1
                DisconnectFromBroker()
                SafeSetTimer(TIMER_INTERVALS.RECONNECT_DELAY, function()
                    ConnectToBroker()
                end)
            elseif not gConnected then
                -- Not connected at all
                if IsBrokerConfigured() then
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

    -- Cancel all media room debounce timers
    for roomID, timerID in pairs(gMediaRoomDebounceTimers) do
        if timerID and type(timerID) == "number" then
            pcall(function() C4:KillTimer(timerID) end)
        end
    end
    gMediaRoomDebounceTimers = {}

    -- Unregister all device events for media rooms
    for _, roomID in ipairs(gMonitoredMediaRooms) do
        Log("Unregistering device events for media room " .. roomID .. " on shutdown")
        for eventName, eventID in pairs(ROOM_EVENTS) do
            pcall(function() C4:UnregisterDeviceEvent(roomID, eventID) end)
        end
    end

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

    elseif (prop == "MQTT Broker IP" or prop == "MQTT Broker Port" or
        prop == "MQTT Username" or prop == "MQTT Password") and gConnected then
        Log("Connection settings changed - reconnect required")
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
end

function IsLightV2(proxyID)
    if not gLightV2Proxies then
        RefreshLightV2Proxies()
    end
    return gLightV2Proxies[tonumber(proxyID)] == true
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

-- Advanced dimmer controls: the proxy variable holding each on V1 (light.c4i) and Light V2 lights,
-- and the Light V2 proxy command that changes it. The two proxies keep these settings under
-- different variable IDs, and only Light V2 has variables for the hold rates (shown in seconds).
local DIMMER_CONTROL_VARS = {
    min_on_level = {v1 = VARIABLE_IDS.MIN_ON_LEVEL, v2 = VARIABLE_IDS.V2_MIN_ON_LEVEL, command = "SET_MIN_ON_LEVEL", param = "LEVEL"},
    max_on_level = {v1 = VARIABLE_IDS.MAX_ON_LEVEL, v2 = VARIABLE_IDS.V2_MAX_ON_LEVEL, command = "SET_MAX_ON_LEVEL", param = "LEVEL"},
    preset_level = {v1 = VARIABLE_IDS.PRESET_LEVEL, v2 = VARIABLE_IDS.V2_PRESET_LEVEL, command = "SET_PRESET_LEVEL", param = "LEVEL"},
    click_ramp_rate_up = {v1 = VARIABLE_IDS.CLICK_RAMP_RATE_UP, v2 = VARIABLE_IDS.CLICK_RAMP_RATE_UP, command = "SET_CLICK_RATE_UP", param = "RATE"},
    click_ramp_rate_down = {v1 = VARIABLE_IDS.CLICK_RAMP_RATE_DOWN, v2 = VARIABLE_IDS.CLICK_RAMP_RATE_DOWN, command = "SET_CLICK_RATE_DOWN", param = "RATE"},
    hold_ramp_rate_up = {v2 = VARIABLE_IDS.V2_HOLD_RATE_UP, command = "SET_HOLD_RATE_UP", param = "RATE", seconds = true},
    hold_ramp_rate_down = {v2 = VARIABLE_IDS.V2_HOLD_RATE_DOWN, command = "SET_HOLD_RATE_DOWN", param = "RATE", seconds = true}
}

-- Light proxy variables (V1 and Light V2): their changes arrive with the proxy ID
local LIGHT_PROXY_VARIABLES = {}
for _, varID in ipairs({VARIABLE_IDS.SWITCH_STATE, VARIABLE_IDS.LIGHT_LEVEL, VARIABLE_IDS.CLICK_RAMP_RATE_UP,
        VARIABLE_IDS.CLICK_RAMP_RATE_DOWN, VARIABLE_IDS.V2_HOLD_RATE_UP, VARIABLE_IDS.V2_HOLD_RATE_DOWN,
        VARIABLE_IDS.V2_PRESET_LEVEL, VARIABLE_IDS.V2_MAX_ON_LEVEL, VARIABLE_IDS.V2_MIN_ON_LEVEL,
        VARIABLE_IDS.CURRENT_CHROMATICITY, VARIABLE_IDS.CURRENT_COLOR_MODE, VARIABLE_IDS.CURRENT_CCT,
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

-- Advanced control variables to watch: all of them on V1 dimmers, the ones the proxy has on
-- Light V2 lights (a Hue light has no hold rates or min/max)
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
-- if the light doesn't have it. V1 hold rates have no variable: the last value set from Home Assistant.
function GetDimmerControlValue(deviceID, proxyID, suffix)
    local varID = GetDimmerControlVariable(proxyID, suffix)
    if varID then
        local value = C4:GetDeviceVariable(proxyID, varID)
        if value == nil or value == "" then
            return nil
        end
        if DIMMER_CONTROL_VARS[suffix].seconds then
            return string.format("%g", (tonumber(value) or 0) / 1000)
        end
        return tostring(value)
    end
    local rates = gHoldRampRates[deviceID]
    if suffix == "hold_ramp_rate_up" and rates and rates.up then
        return tostring(rates.up)
    elseif suffix == "hold_ramp_rate_down" and rates and rates.down then
        return tostring(rates.down)
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

-- Check if a device is being monitored
function IsDeviceMonitored(deviceID, deviceType)
    local list = GetMonitoredList(deviceType)
    local config = DEVICE_TYPES[deviceType]

    for _, item in ipairs(list) do
        local id = (config.uses_table and item.id) or item
        if id == deviceID then
            return true
        end
    end
    return false
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

    if deviceType == "LIGHT" or deviceType == "SWITCH" or deviceType == "OUTLET" then
        -- For lights/switches/outlets, state variables are on the proxy
        local proxyID = GetProxyID(deviceID)
        for _, varID in ipairs(config.variable_ids) do
            C4:RegisterVariableListener(proxyID, varID)
        end

        -- Light V2 color lights: their current color and capabilities too
        if deviceType == "LIGHT" and GetLightColorCaps(proxyID) then
            for _, varID in ipairs(LIGHT_V2_COLOR_VARIABLES) do
                C4:RegisterVariableListener(proxyID, varID)
            end
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

    if deviceType == "LIGHT" or deviceType == "SWITCH" or deviceType == "OUTLET" then
        -- For lights/switches/outlets, unregister from proxy variables
        local proxyID = GetProxyID(deviceID)
        for _, varID in ipairs(config.variable_ids) do
            C4:UnregisterVariableListener(proxyID, varID)
        end

        if deviceType == "LIGHT" and GetLightColorCaps(proxyID) then
            for _, varID in ipairs(LIGHT_V2_COLOR_VARIABLES) do
                C4:UnregisterVariableListener(proxyID, varID)
            end
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

    -- Build proxy->device map for all device types except media rooms (which don't have separate device/proxy)
    local proxyToDevice = {}
    if deviceType ~= "MEDIA_ROOM" and deviceType ~= "CONTACT_SENSOR" then
        proxyToDevice = BuildProxyToDeviceMap()
    end

    local foundDevices = {}

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

        -- Use device ID for topic (consistent with discovery)
        local discoveryTopic = "homeassistant/light/control4_" .. lightID .. "/config"

        -- Empty payload removes the entity
        PublishMQTT(discoveryTopic, "", 1, true)
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
    local existingTimer = gMediaRoomDebounceTimers[roomID]
    if existingTimer and type(existingTimer) == "number" then
        C4:KillTimer(existingTimer)
    end
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
}]], currentTemp, coolSetpoint, heatSetpoint, haMode, haFanMode, haAction, humidity)
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
}]], currentTemp, temperature, haMode, haFanMode, haAction, humidity)
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
    -- Cancel any existing timer for this room
    local existingTimer = gMediaRoomDebounceTimers[roomID]
    if existingTimer and type(existingTimer) == "number" then
        C4:KillTimer(existingTimer)
    end

    -- Create a new timer to publish after 300ms (non-repeating)
    gMediaRoomDebounceTimers[roomID] = SafeSetTimer(300, function(timer)
        gMediaRoomDebounceTimers[roomID] = nil
        if gMQTTConnected then
            PublishMediaRoomState(roomID)
        end
    end, false)  -- false = non-repeating
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
    local discoveryPayload = string.format([[{
  "name": "%s",
  "object_id": "%s",
  "unique_id": "%s",
  "state_topic": "%s",
  "command_topic": "%s",
  "availability_topic": "%s",
  "device": {
    "identifiers": ["%s"],
    "name": "%s",
    "manufacturer": "Control4",
    "model": "Media Room"
  }
}]], EscapeJSON(deviceName), objectID, uniqueID, stateTopic, commandTopic, availabilityTopic, uniqueID, EscapeJSON(deviceName))

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

        PublishMQTT(configTopic, discoveryPayload, 1, true)
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

        PublishMQTT(batteryConfigTopic, batteryPayload, 1, true)
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

        PublishMQTT(voltageConfigTopic, voltagePayload, 1, true)
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

        PublishMQTT(tempConfigTopic, tempPayload, 1, true)
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

function OnWatchedVariableChanged(idDevice, idVariable, strValue)
    -- Note: idDevice can be either a device ID or proxy ID depending on which variable changed
    -- - For light/switch state variables (LIGHT_LEVEL, SWITCH_STATE): idDevice is the PROXY ID
    -- - For LED color variables: idDevice is the DEVICE ID
    -- - For thermostat state variables (temperature, mode, etc.): idDevice is the PROXY ID
    -- - For thermostat LED color variable: idDevice is the DEVICE ID
    -- - For media rooms: idDevice is the same for both device and proxy

    -- Determine the actual device ID we store in our lists
    local actualDeviceID = idDevice
    local deviceName = C4:GetDeviceDisplayName(idDevice) or "Unknown"

    -- Check what type of variable this is and find the device ID accordingly
    if LIGHT_PROXY_VARIABLES[idVariable] then
        -- State variables and advanced control variables come from proxy ID - need to find device ID
        -- For lights/fans, we need to check if this proxy corresponds to a monitored device
        -- Build a reverse map: check if any monitored device has this as its proxy
        for _, deviceID in ipairs(gMonitoredLights) do
            if GetProxyID(deviceID) == idDevice then
                actualDeviceID = deviceID
                break
            end
        end
        for _, deviceID in ipairs(gMonitoredSwitches) do
            if GetProxyID(deviceID) == idDevice then
                actualDeviceID = deviceID
                break
            end
        end
        for _, deviceID in ipairs(gMonitoredOutlets) do
            if GetProxyID(deviceID) == idDevice then
                actualDeviceID = deviceID
                break
            end
        end
    elseif idVariable == VARIABLE_IDS.TEMPERATURE_F or
           idVariable == VARIABLE_IDS.HEAT_SETPOINT_F or
           idVariable == VARIABLE_IDS.COOL_SETPOINT_F or
           idVariable == VARIABLE_IDS.HVAC_MODE or
           idVariable == VARIABLE_IDS.FAN_MODE or
           idVariable == VARIABLE_IDS.HVAC_STATE or
           idVariable == VARIABLE_IDS.HUMIDITY then
        -- Thermostat state variables come from proxy ID - need to find device ID
        for _, deviceID in ipairs(gMonitoredThermostats) do
            if GetProxyID(deviceID) == idDevice then
                actualDeviceID = deviceID
                break
            end
        end
    end

    -- Now check if actualDeviceID is monitored
    local isLight = IsDeviceMonitored(actualDeviceID, "LIGHT")
    local isSwitch = IsDeviceMonitored(actualDeviceID, "SWITCH")
    local isOutlet = IsDeviceMonitored(actualDeviceID, "OUTLET")
    local isThermostat = IsDeviceMonitored(actualDeviceID, "THERMOSTAT")
    local isMediaRoom = IsDeviceMonitored(actualDeviceID, "MEDIA_ROOM")
    local isContactSensor = IsDeviceMonitored(actualDeviceID, "CONTACT_SENSOR")

    if not isLight and not isSwitch and not isOutlet and not isThermostat and not isMediaRoom and not isContactSensor then
        return  -- Not monitoring this device
    end

    -- Handle light variables (Light V2 color lights also report their color)
    if isLight and (idVariable == VARIABLE_IDS.LIGHT_LEVEL or idVariable == VARIABLE_IDS.SWITCH_STATE or
                    idVariable == VARIABLE_IDS.CURRENT_CHROMATICITY or idVariable == VARIABLE_IDS.CURRENT_COLOR_MODE or
                    idVariable == VARIABLE_IDS.CURRENT_CCT) then
        if gMQTTConnected then
            PublishLightState(actualDeviceID)
        end
        local timestamp = os.date("%H:%M:%S")
        C4:UpdateProperty("Last Event", deviceName .. " @ " .. timestamp)

    -- Light V2 capabilities changed (color support, color temperature range): update the entity
    elseif isLight and idVariable == VARIABLE_IDS.DYNAMIC_CAPABILITIES then
        if gMQTTConnected then
            PublishLightDiscovery(actualDeviceID)
            PublishLightState(actualDeviceID)
        end

    -- Handle switch variables
    elseif isSwitch and idVariable == VARIABLE_IDS.SWITCH_STATE then
        if gMQTTConnected then
            PublishSwitchState(actualDeviceID)
        end
        local timestamp = os.date("%H:%M:%S")
        C4:UpdateProperty("Last Event", deviceName .. " @ " .. timestamp)

    -- Handle outlet variables
    elseif isOutlet and idVariable == VARIABLE_IDS.SWITCH_STATE then
        if gMQTTConnected then
            PublishOutletState(actualDeviceID)
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
        local suffix = GetDimmerControlForVariable(proxyID, idVariable)
        local value = GetDimmerControlValue(actualDeviceID, proxyID, suffix) or "0"
        local stateTopic = "homeassistant/number/control4_" .. actualDeviceID .. "_" .. suffix .. "/state"
        PublishMQTT(stateTopic, value, 1, true)  -- QoS 1, retained

        local timestamp = os.date("%H:%M:%S")
        C4:UpdateProperty("Last Event", deviceName .. " @ " .. timestamp)
    end
end

-- Handle device events from media rooms (play, pause, stop, etc.)
-- This allows us to track accurate playback state
function OnDeviceEvent(idDevice, eventId)
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
        LogError("Light " .. lightID .. " not found - may have been deleted")
        RemoveDeletedDevice(lightID)
        return false
    end

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
    
    local payload = EncodeJSON(config)

    Log("Publishing auto-discovery for: " .. lightName)
    Log("  Topic: " .. discoveryTopic)

    -- Use QoS 1 for reliable discovery message delivery
    return PublishMQTT(discoveryTopic, payload, 1, true)
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

    local payload = EncodeJSON(config)
    Log("Publishing switch discovery: " .. switchName)

    return PublishMQTT(discoveryTopic, payload, 1, true)
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

    local payload = EncodeJSON(config)
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

        local payload = EncodeJSON(config)
        Log("  Publishing LED text entity: " .. ledConfig.name .. " -> " .. discoveryTopic)
        PublishMQTT(discoveryTopic, payload, 1, true)
    end

    Log("Published LED discovery for: " .. deviceName)
end

function PublishLEDState(deviceID, ledSuffix, variableID)
    if not IsLEDControlEnabled() then
        return
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
        }
    }

    -- A Light V2 light has only the settings its proxy has variables for (a Hue light has no hold
    -- rates or min/max): remove any entity published for the others before
    if IsLightV2(proxyID) then
        local available = {}
        for _, control in ipairs(controls) do
            if GetDimmerControlValue(deviceID, proxyID, control.suffix) then
                table.insert(available, control)
            else
                PublishMQTT("homeassistant/number/control4_" .. deviceID .. "_" .. control.suffix .. "/config", "", 1, true)
            end
        end
        controls = available
    end

    -- Publish discovery for each control
    for _, control in ipairs(controls) do
        local discoveryTopic = "homeassistant/number/control4_" .. deviceID .. "_" .. control.suffix .. "/config"
        local objectID = SanitizeEntityName(dimmerName .. " " .. control.name)

        local config = {
            name = dimmerName .. " - " .. control.name,
            object_id = objectID,
            default_entity_id = DefaultEntityID("number", objectID, deviceID),
            unique_id = "control4_" .. deviceID .. "_" .. control.suffix,
            state_topic = "homeassistant/number/control4_" .. deviceID .. "_" .. control.suffix .. "/state",
            command_topic = "homeassistant/number/control4_" .. deviceID .. "_" .. control.suffix .. "/set",
            min = control.min,
            max = control.max,
            step = 1,
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

        local payload = EncodeJSON(config)
        PublishMQTT(discoveryTopic, payload, 1, true)
    end

    Log("Published advanced dimmer control discovery for: " .. dimmerName)

    -- Publish initial states
    PublishDimmerAdvancedControlStates(deviceID)

    return true
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

    return true
end

function PublishAllDiscovery()
    if not gMQTTConnected then
        LogError("Cannot publish discovery - not connected to MQTT")
        return
    end

    Log("========================================")
    Log("Publishing auto-discovery for all devices...")

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
            PublishSwitchDiscovery(switchID)

            -- Also publish LED discovery and state if enabled
            if IsLEDControlEnabled() then
                PublishLEDDiscovery(switchID, "SWITCH")
                PublishAllLEDStates(switchID)
            end

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
            PublishMediaRoomDiscovery(gMonitoredMediaRooms[mediaRoomIndex])
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
        end
    end

    -- Each step moves on to the next one when it has nothing to do
    PublishNextLight()
end

function RemoveAllEntities()
    if not gMQTTConnected then
        LogError("Cannot remove entities - not connected to MQTT")
        return
    end

    Log("========================================")
    Log("Removing all entities from Home Assistant...")

    -- Remove all lights
    for _, lightID in ipairs(gMonitoredLights) do
        local discoveryTopic = "homeassistant/light/control4_" .. lightID .. "/config"
        PublishMQTT(discoveryTopic, "", 1, true)
        Log("  Removed light " .. lightID)
    end

    -- Remove all switches
    for _, switchID in ipairs(gMonitoredSwitches) do
        local discoveryTopic = "homeassistant/switch/control4_" .. switchID .. "/config"
        PublishMQTT(discoveryTopic, "", 1, true)
        Log("  Removed switch " .. switchID)
    end

    -- Remove all outlets
    for _, outletID in ipairs(gMonitoredOutlets) do
        local discoveryTopic = "homeassistant/switch/control4_" .. outletID .. "/config"
        PublishMQTT(discoveryTopic, "", 1, true)
        Log("  Removed outlet " .. outletID)
    end

    -- Remove all thermostats
    for _, thermostatID in ipairs(gMonitoredThermostats) do
        local discoveryTopic = "homeassistant/climate/control4_" .. thermostatID .. "/config"
        PublishMQTT(discoveryTopic, "", 1, true)
        Log("  Removed thermostat " .. thermostatID)
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

        -- Send command to Control4 device (not proxy)
        Log("Sending LED command to device " .. deviceID .. " (proxy " .. proxyID .. "): " .. command .. " with color " .. hexColor)
        C4:SendToDevice(deviceID, command, {RGB = hexColor})

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
            hold_ramp_rate_down = {varID = nil, min = 0, max = 10, name = "Hold Ramp Rate Down", unit = "s"}
        }

        local control = controlMap[controlSuffix]
        if not control then
            LogError("Unknown dimmer control: " .. controlSuffix)
            return
        end

        local proxyID = GetProxyID(dimmerID)
        local dimmerName = C4:GetDeviceDisplayName(proxyID)

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
                    local currentValue = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.CLICK_RAMP_RATE_UP) or "0"
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
                    local currentValue = C4:GetDeviceVariable(proxyID, VARIABLE_IDS.CLICK_RAMP_RATE_DOWN) or "0"
                    local stateTopic = "homeassistant/number/control4_" .. dimmerID .. "_" .. controlSuffix .. "/state"
                    PublishMQTT(stateTopic, currentValue, 1, true)

                    -- Update Last Command with error
                    C4:UpdateProperty("Last Command", "ERROR: " .. dimmerName .. " - " .. errorMsg)
                    return
                end
            end
        elseif controlSuffix == "hold_ramp_rate_up" then
            local clickRampUp = tonumber(C4:GetDeviceVariable(proxyID, VARIABLE_IDS.CLICK_RAMP_RATE_UP)) or 0
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
            local clickRampDown = tonumber(C4:GetDeviceVariable(proxyID, VARIABLE_IDS.CLICK_RAMP_RATE_DOWN)) or 0
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
            -- Light V2: the proxy's own setting commands (its variables are laid out differently)
            local spec = DIMMER_CONTROL_VARS[controlSuffix]
            local setting = spec.seconds and math.floor(value * 1000 + 0.5) or value
            C4:SendToDevice(proxyID, spec.command, {[spec.param] = setting})
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

        -- Publish state back to Home Assistant immediately (Light V2 lights report the new value
        -- through their variable, so a setting the light doesn't take shows as it is)
        if not isV2 then
            local stateTopic = "homeassistant/number/control4_" .. dimmerID .. "_" .. controlSuffix .. "/state"
            PublishMQTT(stateTopic, tostring(value), 1, true)  -- QoS 1, retained
        end

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

    if #deletedDevices == 0 then
        Log("  No deleted devices found")
        Log("========================================")
        return
    end

    Log("")
    Log("Removing " .. #deletedDevices .. " deleted device(s)...")

    for _, lightID in ipairs(deletedDevices) do
        RemoveDeletedDevice(lightID)
    end

    Log("")
    Log("Cleanup complete - removed " .. #deletedDevices .. " device(s)")
    Log("========================================")
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

function BuildMQTTConnect()
    Log("Building MQTT CONNECT packet...")
    
    local clientID = "Control4_HA_" .. tostring(os.time())
    local username = Properties["MQTT Username"] or ""
    local password = Properties["MQTT Password"] or ""
    
    local fixedHeader = string.char(0x10)
    local variableHeader = ""
    variableHeader = variableHeader .. string.char(0x00, 0x04)
    variableHeader = variableHeader .. "MQTT"
    variableHeader = variableHeader .. string.char(0x04)
    
    local connectFlags = 0x02
    if username ~= "" then
        connectFlags = connectFlags + 0x80
        Log("  Username: " .. username)
    end
    if password ~= "" then
        connectFlags = connectFlags + 0x40
        Log("  Password: [SET]")
    end
    
    variableHeader = variableHeader .. string.char(connectFlags)
    variableHeader = variableHeader .. string.char(0x00, 0x3C)
    
    local payload = string.char(math.floor(#clientID / 256), #clientID % 256) .. clientID
    
    if username ~= "" then
        payload = payload .. string.char(math.floor(#username / 256), #username % 256) .. username
    end
    
    if password ~= "" then
        payload = payload .. string.char(math.floor(#password / 256), #password % 256) .. password
    end
    
    local remainingLength = #variableHeader + #payload
    local packet = fixedHeader .. EncodeMQTTLength(remainingLength) .. variableHeader .. payload
    
    Log("  Client ID: " .. clientID)
    Log("  Packet size: " .. #packet .. " bytes")
    
    return packet
end

function BuildMQTTSubscribe(topic, qos)
    qos = qos or 0
    
    Log("Building MQTT SUBSCRIBE packet:")
    Log("  Topic: " .. topic)
    Log("  QoS: " .. qos)
    
    local fixedHeader = string.char(0x82) -- SUBSCRIBE with QoS 1
    
    gPacketID = gPacketID + 1
    if gPacketID > 65535 then gPacketID = 1 end
    
    local variableHeader = string.char(math.floor(gPacketID / 256), gPacketID % 256)
    
    local payload = string.char(math.floor(#topic / 256), #topic % 256) .. topic .. string.char(qos)
    
    local remainingLength = #variableHeader + #payload
    local packet = fixedHeader .. EncodeMQTTLength(remainingLength) .. variableHeader .. payload
    
    return packet
end

function BuildMQTTPublish(topic, message, qos, retain)
    qos = qos or 0
    retain = retain or false
    
    local fixedHeader = 0x30
    if retain then
        fixedHeader = fixedHeader + 0x01
    end
    fixedHeader = fixedHeader + (qos * 2)
    
    local variableHeader = string.char(math.floor(#topic / 256), #topic % 256) .. topic
    
    if qos > 0 then
        variableHeader = variableHeader .. string.char(math.floor(gPacketID / 256), gPacketID % 256)
        gPacketID = gPacketID + 1
        if gPacketID > 65535 then
            gPacketID = 1
        end
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

function ParseMQTTPacket(data)
    if #data < 2 then
        return nil
    end
    
    local messageType = math.floor(string.byte(data, 1) / 16)
    local remainingLength, offset = DecodeMQTTLength(data, 2)
    
    if not remainingLength then
        return nil
    end
    
    -- CONNACK (type 2)
    if messageType == 2 and #data >= offset + 1 then
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
    
    -- SUBACK (type 9)
    if messageType == 9 then
        Log("SUBACK received - subscribed successfully")
        return "SUBACK"
    end
    
    -- PUBLISH (type 3)
    if messageType == 3 then
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

        -- Get QoS from fixed header (bits 1-2, above the retain bit and below the DUP bit)
        local qos = math.floor((string.byte(data, 1) % 8) / 2)

        -- If QoS > 0, extract packet ID (2 bytes)
        local packetID = nil
        if qos > 0 then
            packetID = string.byte(data, offset) * 256 + string.byte(data, offset + 1)
            offset = offset + 2
        end

        -- Rest is payload
        local payload = string.sub(data, offset)

        -- Handle the command
        HandleMQTTCommand(topic, payload)

        -- Send PUBACK for QoS 1 messages
        if qos == 1 and packetID then
            local puback = BuildMQTTPubAck(packetID)
            C4:SendToNetwork(MQTT_BINDING_ID, tonumber(Properties["MQTT Broker Port"]) or 1883, puback)
            if IsLoggingEnabled() then
                Log("PUBACK sent for packet ID: " .. packetID)
            end
        end

        return "PUBLISH"
    end
    
    -- PUBACK (type 4)
    if messageType == 4 then
        return "PUBACK"
    end
    
    -- PINGRESP (type 13)
    if messageType == 13 then
        Log("PINGRESP received - connection alive")
        return "PINGRESP"
    end
    
    return "UNKNOWN"
end

-- Connection Functions
function IsBrokerConfigured()
    local ip = Properties["MQTT Broker IP"]
    return ip ~= nil and ip ~= "" and ip ~= BROKER_IP_PLACEHOLDER
end

function ConnectToBroker()
    local ip = Properties["MQTT Broker IP"]
    local port = tonumber(Properties["MQTT Broker Port"]) or 1883

    if not IsBrokerConfigured() then
        LogError("Cannot connect: No IP configured")
        C4:UpdateProperty("Connection Status", "Error: No IP")
        return false
    end

    Log("========================================")
    Log("Connecting to MQTT Broker: " .. ip .. ":" .. port)
    Log("========================================")

    C4:UpdateProperty("Connection Status", "Connecting...")

    -- Create dynamic network connection using C4's native network stack
    C4:CreateNetworkConnection(MQTT_BINDING_ID, ip, "TCP")

    -- Connect to the MQTT broker
    C4:NetConnect(MQTT_BINDING_ID, port, "TCP")

    Log("Network connection initiated (event-driven mode)...")

    return true
end

-- C4 Network Callback: Called when connection status changes
function OnConnectionStatusChanged(idBinding, nPort, strStatus)
    if idBinding ~= MQTT_BINDING_ID then
        return
    end

    Log("Connection status changed: " .. strStatus .. " (port " .. nPort .. ")")

    if strStatus == "ONLINE" then
        Log("TCP connected!")
        gConnected = true
        gMQTTBuffer = ""  -- A partial packet from the last connection would swallow the CONNACK
        C4:UpdateProperty("Connection Status", "TCP Connected")

        SendMQTTConnect()
        -- Note: No need to call StartReceiveLoop() - data will arrive via ReceivedFromNetwork callback
    elseif strStatus == "OFFLINE" then
        Log("TCP connection lost")
        gConnected = false
        gMQTTConnected = false
        C4:UpdateProperty("Connection Status", "Disconnected")
    end
end

function SendMQTTConnect()
    if not gConnected then
        return false
    end

    local packet = BuildMQTTConnect()
    C4:SendToNetwork(MQTT_BINDING_ID, tonumber(Properties["MQTT Broker Port"]) or 1883, packet)

    Log("MQTT CONNECT sent")
    C4:UpdateProperty("Connection Status", "Waiting for CONNACK...")

    return true
end

function SubscribeToCommandTopics()
    if not gMQTTConnected then
        Log("Cannot subscribe - not connected")
        return false
    end

    Log("========================================")
    Log("Subscribing to command topics for all devices...")

    -- Forward declarations for mutual recursion
    local SubscribeNextLight
    local SubscribeNextSwitch
    local SubscribeNextOutlet
    local SubscribeNextThermostat
    local SubscribeToLEDTopics
    local SubscribeToAdvancedDimmerControlTopics
    local SubscribeNextMediaRoom

    -- Subscribe to light command topics
    local lightIndex = 1
    SubscribeNextLight = function()
        if lightIndex <= #gMonitoredLights then
            local lightID = gMonitoredLights[lightIndex]
            local proxyID = GetProxyID(lightID)
            local lightName = C4:GetDeviceDisplayName(proxyID)

            if lightName then
                -- Use device ID for topic (consistent with discovery)
                local topic = "homeassistant/light/control4_" .. lightID .. "/set"

                local packet = BuildMQTTSubscribe(topic, 1)
                C4:SendToNetwork(MQTT_BINDING_ID, tonumber(Properties["MQTT Broker Port"]) or 1883, packet)
                Log("  Subscribed to: " .. topic .. " (" .. lightName .. ")")
            end

            lightIndex = lightIndex + 1
            -- Delay between subscriptions
            SafeSetTimer(TIMER_INTERVALS.SUBSCRIPTION_DELAY, function()
                SubscribeNextLight()
            end)
        else
            Log("Light subscription complete")
            -- After lights, subscribe to switches
            SubscribeNextSwitch()
        end
    end

    -- Subscribe to switch command topics
    local switchIndex = 1
    SubscribeNextSwitch = function()
        if switchIndex <= #gMonitoredSwitches then
            local switchID = gMonitoredSwitches[switchIndex]
            local proxyID = GetProxyID(switchID)
            local switchName = C4:GetDeviceDisplayName(proxyID)

            if switchName then
                local topic = "homeassistant/switch/control4_" .. switchID .. "/set"

                local packet = BuildMQTTSubscribe(topic, 1)
                C4:SendToNetwork(MQTT_BINDING_ID, tonumber(Properties["MQTT Broker Port"]) or 1883, packet)
                Log("  Subscribed to: " .. topic .. " (" .. switchName .. ")")
            end

            switchIndex = switchIndex + 1
            -- Delay between subscriptions
            SafeSetTimer(TIMER_INTERVALS.SUBSCRIPTION_DELAY, function()
                SubscribeNextSwitch()
            end)
        else
            Log("Switch subscription complete")
            -- After switches, subscribe to outlets
            SubscribeNextOutlet()
        end
    end

    -- Subscribe to outlet command topics
    local outletIndex = 1
    SubscribeNextOutlet = function()
        if outletIndex <= #gMonitoredOutlets then
            local outletID = gMonitoredOutlets[outletIndex]
            local proxyID = GetProxyID(outletID)
            local outletName = C4:GetDeviceDisplayName(proxyID)

            if outletName then
                local topic = "homeassistant/switch/control4_" .. outletID .. "/set"

                local packet = BuildMQTTSubscribe(topic, 1)
                C4:SendToNetwork(MQTT_BINDING_ID, tonumber(Properties["MQTT Broker Port"]) or 1883, packet)
                Log("  Subscribed to: " .. topic .. " (" .. outletName .. ")")
            end

            outletIndex = outletIndex + 1
            -- Delay between subscriptions
            SafeSetTimer(TIMER_INTERVALS.SUBSCRIPTION_DELAY, function()
                SubscribeNextOutlet()
            end)
        else
            Log("Outlet subscription complete")
            -- After outlets, subscribe to LED topics if enabled
            if IsLEDControlEnabled() then
                SubscribeToLEDTopics()
            elseif IsAdvancedDimmerControlEnabled() then
                SubscribeToAdvancedDimmerControlTopics()
            else
                SubscribeNextThermostat()
            end
        end
    end

    -- Subscribe to LED command topics for both lights and fans
    SubscribeToLEDTopics = function()
        -- Combine lights and switches into one list
        local allDevices = {}
        for _, lightID in ipairs(gMonitoredLights) do
            table.insert(allDevices, lightID)
        end
        for _, switchID in ipairs(gMonitoredSwitches) do
            table.insert(allDevices, switchID)
        end

        if #allDevices == 0 then
            Log("No LED devices to subscribe to")
            -- After LEDs, subscribe to advanced dimmer controls if enabled
            if IsAdvancedDimmerControlEnabled() then
                SubscribeToAdvancedDimmerControlTopics()
            else
                SubscribeNextThermostat()
            end
            return
        end

        local deviceIndex = 1
        local ledSuffixes = {"top_on", "top_off", "bottom_on", "bottom_off"}
        local ledIndex = 1

        local SubscribeNextLED
        SubscribeNextLED = function()
            if deviceIndex <= #allDevices then
                local deviceID = allDevices[deviceIndex]
                local proxyID = GetProxyID(deviceID)
                local deviceName = C4:GetDeviceDisplayName(proxyID)

                if deviceName and ledIndex <= #ledSuffixes then
                    local suffix = ledSuffixes[ledIndex]
                    local topic = "homeassistant/text/control4_" .. deviceID .. "/" .. suffix .. "/set"

                    local packet = BuildMQTTSubscribe(topic, 1)
                    C4:SendToNetwork(MQTT_BINDING_ID, tonumber(Properties["MQTT Broker Port"]) or 1883, packet)
                    Log("  Subscribed to LED text: " .. topic)

                    -- Move to next LED suffix
                    ledIndex = ledIndex + 1
                    if ledIndex > #ledSuffixes then
                        -- Move to next device
                        ledIndex = 1
                        deviceIndex = deviceIndex + 1
                    end

                    SafeSetTimer(TIMER_INTERVALS.SUBSCRIPTION_DELAY, function()
                        SubscribeNextLED()
                    end)
                else
                    -- Skip devices without names
                    deviceIndex = deviceIndex + 1
                    ledIndex = 1
                    if deviceIndex <= #allDevices then
                        SafeSetTimer(TIMER_INTERVALS.SUBSCRIPTION_DELAY, function()
                            SubscribeNextLED()
                        end)
                    else
                        Log("LED subscription complete")
                        -- After LEDs, subscribe to advanced dimmer controls if enabled
                        if IsAdvancedDimmerControlEnabled() then
                            SubscribeToAdvancedDimmerControlTopics()
                        else
                            SubscribeNextThermostat()
                        end
                    end
                end
            else
                Log("LED subscription complete")
                -- After LEDs, subscribe to advanced dimmer controls if enabled
                if IsAdvancedDimmerControlEnabled() then
                    SubscribeToAdvancedDimmerControlTopics()
                else
                    SubscribeNextThermostat()
                end
            end
        end

        -- Start LED subscriptions
        SubscribeNextLED()
    end

    -- Subscribe to advanced dimmer control command topics (only for lights/dimmers)
    SubscribeToAdvancedDimmerControlTopics = function()
        if #gMonitoredLights == 0 then
            Log("No dimmers to subscribe to for advanced controls")
            SubscribeNextThermostat()
            return
        end

        local lightIndex = 1
        local controlSuffixes = {"min_on_level", "max_on_level", "preset_level", "click_ramp_rate_up", "click_ramp_rate_down", "hold_ramp_rate_up", "hold_ramp_rate_down"}
        local controlIndex = 1

        local SubscribeNextControl
        SubscribeNextControl = function()
            if lightIndex <= #gMonitoredLights then
                local lightID = gMonitoredLights[lightIndex]
                local proxyID = GetProxyID(lightID)
                local lightName = C4:GetDeviceDisplayName(proxyID)

                if lightName and controlIndex <= #controlSuffixes then
                    local suffix = controlSuffixes[controlIndex]
                    local topic = "homeassistant/number/control4_" .. lightID .. "_" .. suffix .. "/set"

                    local packet = BuildMQTTSubscribe(topic, 1)
                    C4:SendToNetwork(MQTT_BINDING_ID, tonumber(Properties["MQTT Broker Port"]) or 1883, packet)
                    Log("  Subscribed to dimmer control: " .. topic)

                    -- Move to next control suffix
                    controlIndex = controlIndex + 1
                    if controlIndex > #controlSuffixes then
                        -- Move to next light
                        controlIndex = 1
                        lightIndex = lightIndex + 1
                    end

                    SafeSetTimer(TIMER_INTERVALS.SUBSCRIPTION_DELAY, function()
                        SubscribeNextControl()
                    end)
                else
                    -- Skip lights without names
                    lightIndex = lightIndex + 1
                    controlIndex = 1
                    if lightIndex <= #gMonitoredLights then
                        SafeSetTimer(TIMER_INTERVALS.SUBSCRIPTION_DELAY, function()
                            SubscribeNextControl()
                        end)
                    else
                        Log("Advanced dimmer control subscription complete")
                        SubscribeNextThermostat()
                    end
                end
            else
                Log("Advanced dimmer control subscription complete")
                SubscribeNextThermostat()
            end
        end

        -- Start advanced control subscriptions
        SubscribeNextControl()
    end

    -- Subscribe to thermostat command topics
    local thermostatIndex = 1
    local commandTopicIndex = 1
    local commandTopicSuffixes = {"/mode/set", "/temperature/set", "/temperature_low/set", "/temperature_high/set", "/fan_mode/set"}
    local subscribingLED = false

    SubscribeNextThermostat = function()
        if thermostatIndex <= #gMonitoredThermostats then
            local thermostatID = gMonitoredThermostats[thermostatIndex]
            -- thermostatID is device ID, get proxy for display name
            local proxyID = GetProxyID(thermostatID)
            local thermostatName = C4:GetDeviceDisplayName(proxyID)

            if thermostatName then
                if not subscribingLED then
                    -- Subscribe to the current command topic
                    local baseTopic = "homeassistant/climate/control4_" .. thermostatID
                    local topic = baseTopic .. commandTopicSuffixes[commandTopicIndex]

                    local packet = BuildMQTTSubscribe(topic, 1)
                    C4:SendToNetwork(MQTT_BINDING_ID, tonumber(Properties["MQTT Broker Port"]) or 1883, packet)
                    Log("  Subscribed to: " .. topic .. " (" .. thermostatName .. ")")

                    -- Move to next command topic
                    commandTopicIndex = commandTopicIndex + 1

                    -- If we've subscribed to all command topics for this thermostat, subscribe to LED if enabled
                    if commandTopicIndex > #commandTopicSuffixes then
                        commandTopicIndex = 1
                        if IsLEDControlEnabled() then
                            subscribingLED = true
                        else
                            thermostatIndex = thermostatIndex + 1
                        end
                    end
                else
                    -- Subscribe to LED topic for this thermostat
                    local topic = "homeassistant/text/control4_thermostat_" .. thermostatID .. "_button_led/set"
                    local packet = BuildMQTTSubscribe(topic, 1)
                    C4:SendToNetwork(MQTT_BINDING_ID, tonumber(Properties["MQTT Broker Port"]) or 1883, packet)
                    Log("  Subscribed to thermostat LED: " .. topic .. " (" .. thermostatName .. ")")

                    -- Move to next thermostat
                    subscribingLED = false
                    thermostatIndex = thermostatIndex + 1
                end
            else
                -- Skip thermostats without names
                commandTopicIndex = 1
                subscribingLED = false
                thermostatIndex = thermostatIndex + 1
            end

            -- Delay between subscriptions
            SafeSetTimer(TIMER_INTERVALS.SUBSCRIPTION_DELAY, function()
                SubscribeNextThermostat()
            end)
        else
            Log("Thermostat subscription complete")
            -- After thermostats, subscribe to media rooms
            SubscribeNextMediaRoom()
        end
    end

    -- Subscribe to media room command topics
    local mediaRoomIndex = 1
    SubscribeNextMediaRoom = function()
        if mediaRoomIndex <= #gMonitoredMediaRooms then
            local roomID = gMonitoredMediaRooms[mediaRoomIndex]
            local roomName = C4:GetDeviceDisplayName(roomID)

            if roomName then
                local topic = "homeassistant/media_player/control4_room_" .. roomID .. "/set"

                local packet = BuildMQTTSubscribe(topic, 1)
                C4:SendToNetwork(MQTT_BINDING_ID, tonumber(Properties["MQTT Broker Port"]) or 1883, packet)
                Log("  Subscribed to: " .. topic .. " (" .. roomName .. ")")
            end

            mediaRoomIndex = mediaRoomIndex + 1
            -- Delay between subscriptions
            SafeSetTimer(TIMER_INTERVALS.SUBSCRIPTION_DELAY, function()
                SubscribeNextMediaRoom()
            end)
        else
            Log("Media room subscription complete")
            Log("========================================")
        end
    end

    -- Each step moves on to the next one when it has nothing to do
    SubscribeNextLight()

    return true
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

    gStats.messagesReceived = gStats.messagesReceived + 1
    C4:UpdateProperty("Messages Received", tostring(gStats.messagesReceived))

    -- Check buffer size limit before adding
    if #gMQTTBuffer + #strData > LIMITS.MAX_BUFFER_SIZE then
        LogError("Buffer overflow detected - clearing buffer (was " .. #gMQTTBuffer .. " bytes)")
        gMQTTBuffer = ""
    end

    -- Add to buffer
    gMQTTBuffer = gMQTTBuffer .. strData

    -- Process all complete packets in buffer
    while #gMQTTBuffer >= 2 do
        local firstByte = string.byte(gMQTTBuffer, 1)
        local messageType = math.floor(firstByte / 16)

        local remainingLength, offset = DecodeMQTTLength(gMQTTBuffer, 2)

        if not remainingLength then
            break
        end

        -- Validate packet size
        if remainingLength > LIMITS.MAX_PACKET_SIZE then
            LogError("Invalid packet size: " .. remainingLength .. " bytes (max " .. LIMITS.MAX_PACKET_SIZE .. ")")
            gMQTTBuffer = ""
            break
        end

        -- Total packet length = fixed header (1 byte) + encoded length bytes + remaining length
        local totalLength = 1 + (offset - 2) + remainingLength

        if #gMQTTBuffer < totalLength then
            break
        end

        -- Extract complete packet
        local packet = string.sub(gMQTTBuffer, 1, totalLength)
        gMQTTBuffer = string.sub(gMQTTBuffer, totalLength + 1)

        -- Process packet
        local result = ParseMQTTPacket(packet)

        if result == "CONNACK_SUCCESS" then
            gMQTTConnected = true
            C4:UpdateProperty("Connection Status", "MQTT Connected ✓")
            Log("========================================")
            Log("SUCCESS! MQTT Connected")
            Log("========================================")

            StartKeepAlive()

            SafeSetTimer(TIMER_INTERVALS.AUTO_CONNECT_DELAY, function()
                Log("Initiating command topic subscriptions...")
                SubscribeToCommandTopics()
            end)

            if #gMonitoredLights > 0 or #gMonitoredSwitches > 0 or #gMonitoredOutlets > 0 or #gMonitoredThermostats > 0 or #gMonitoredMediaRooms > 0 then
                Log("Publishing initial states...")
                SafeSetTimer(TIMER_INTERVALS.RECONNECT_DELAY, function()
                    RefreshAllDeviceStates("LIGHT")
                    RefreshAllDeviceStates("SWITCH")
                    RefreshAllDeviceStates("OUTLET")
                    RefreshAllDeviceStates("THERMOSTAT")
                    RefreshAllDeviceStates("MEDIA_ROOM")
                end)
            end

        elseif result == "CONNACK_FAILED" then
            DisconnectFromBroker()
            return
        end
    end
end

function DisconnectFromBroker()
    Log("Disconnecting from MQTT broker...")

    CancelConnectionTimers()

    -- Disconnect using C4 network stack
    C4:NetDisconnect(MQTT_BINDING_ID, tonumber(Properties["MQTT Broker Port"]) or 1883)

    gConnected = false
    gMQTTConnected = false
    gMQTTBuffer = ""
    C4:UpdateProperty("Connection Status", "Disconnected")
    Log("Disconnected")
end

function StartKeepAlive()
    if gKeepAliveTimer then
        gKeepAliveTimer:Cancel()
    end
    
    gKeepAliveTimer = C4:SetTimer(45000, function(timer)
        SendPingReq()
    end, true)
    
    Log("Keep-alive started (45s interval)")
end

function SendPingReq()
    if not gMQTTConnected then
        -- The connection watchdog does the reconnecting, if Auto Reconnect is enabled
        Log("PINGREQ skipped - not connected")
        return
    end

    local packet = BuildMQTTPingReq()
    C4:SendToNetwork(MQTT_BINDING_ID, tonumber(Properties["MQTT Broker Port"]) or 1883, packet)
    Log("PINGREQ sent")
end

-- Timers that only apply to the current connection. The watchdog isn't one of them: it keeps
-- running through a disconnect so that it can reconnect.
function CancelConnectionTimers()
    if gKeepAliveTimer then
        gKeepAliveTimer:Cancel()
        gKeepAliveTimer = nil
    end
    -- Cancel all tracked timers
    for timer in pairs(gActiveTimers) do
        pcall(function() timer:Cancel() end)
    end
    gActiveTimers = {}
end

-- Every timer, for when the driver shuts down
function CancelTimers()
    CancelConnectionTimers()
    if gWatchdogTimer then
        gWatchdogTimer:Cancel()
        gWatchdogTimer = nil
    end
    if gDebugModeTimer then
        gDebugModeTimer:Cancel()
        gDebugModeTimer = nil
    end
end

function PublishMQTT(topic, message, qos, retain)
    if not gMQTTConnected then
        LogError("Cannot publish - not connected")
        return false
    end

    local success, result = pcall(function()
        local packet = BuildMQTTPublish(topic, message, qos, retain)
        C4:SendToNetwork(MQTT_BINDING_ID, tonumber(Properties["MQTT Broker Port"]) or 1883, packet)
        return true
    end)

    if not success then
        LogError("Publish failed with exception: " .. tostring(result))
        -- Trigger reconnect
        DisconnectFromBroker()
        SafeSetTimer(TIMER_INTERVALS.RECONNECT_DELAY, function()
            ConnectToBroker()
        end)
        return false
    end

    gStats.messagesSent = gStats.messagesSent + 1
    C4:UpdateProperty("Messages Sent", tostring(gStats.messagesSent))
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
        ConnectToBroker()
        
    elseif cmd == "Disconnect" then
        gManualDisconnect = true
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

        -- Re-subscribe to MQTT command topics for all devices (including newly discovered)
        if gMQTTConnected then
            Log("Re-subscribing to MQTT command topics for newly discovered devices...")
            SubscribeToCommandTopics()
        end

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