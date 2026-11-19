"""Mock test of the bridge's connection handling, contact sensors and discovery. Runs driver.lua in
lupa with a mock C4 API, and decodes the MQTT packets the driver sends.

    pip install lupa
    python tests/bridge_test.py
"""
import json
import sys
from pathlib import Path

from lupa import LuaRuntime

ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
# latin-1 passes every byte through, as MQTT packets are binary
SRC = (ROOT / "driver.lua").read_bytes().decode("latin-1")
XML = (ROOT / "driver.xml").read_text(encoding="utf-8")
failures = []

MOCK = r'''
os.setlocale("C")
Properties = { ["Debug Mode"] = "Off", ["Enable Advanced Dimmer Controls"] = "Disabled",
    ["Enable LED Color Control"] = "Disabled", ["MQTT Broker IP"] = "10.0.0.5", ["MQTT Broker Port"] = "1883",
    ["MQTT Username"] = "", ["MQTT Password"] = "", ["Auto Reconnect"] = "Enabled",
    ["Contact Sensor Binding Map"] = "", ["Media Room IDs (comma separated)"] = "",
    ["Switch Device IDs (comma separated)"] = "" }
mock = { vars = {}, names = {}, proxies = {}, persist = {}, sent = {}, props = {}, timers = {}, connects = 0,
    cmds = {}, propCount = {}, disconnects = {}, addresses = {}, listeners = {} }
C4 = setmetatable({}, { __index = function() return function() end end })
function C4:GetDeviceVariable(id, var)
    local v = mock.vars[id] and mock.vars[id][var]
    if v == nil then return end
    return v
end
function C4:GetProxyDevicesById(id) return mock.proxies[id] end
function C4:GetDevicesByC4iName() return {} end
function C4:GetDevices() return {} end
function C4:GetDeviceDisplayName(id) return mock.names[id] end
function C4:PersistGetValue(k) return mock.persist[k] end
function C4:PersistSetValue(k, v) mock.persist[k] = v end
function C4:UpdateProperty(k, v) mock.props[k] = v; mock.propCount[k] = (mock.propCount[k] or 0) + 1 end
function C4:SendToNetwork(_, _, data) table.insert(mock.sent, data) end
function C4:NetConnect() mock.connects = mock.connects + 1 end
function C4:NetDisconnect(_, port) table.insert(mock.disconnects, port) end
function C4:CreateNetworkConnection(_, ip) table.insert(mock.addresses, ip) end
function C4:SendToDevice(id, cmd, params) table.insert(mock.cmds, { id = id, cmd = cmd, params = params or {} }) end
function C4:GetDeviceID() return 1234 end
function C4:RegisterVariableListener(id, var) mock.listeners[id .. ":" .. var] = true end
function C4:SetTimer(delay, fn, rep)
    local t = { delay = delay, fn = fn, rep = rep, cancelled = false }
    t.Cancel = function(self) self.cancelled = true end
    table.insert(mock.timers, t)
    return t
end
-- Run every live timer once: repeating timers stay, one-shot timers are used up
function fire_timers()
    local batch = mock.timers
    mock.timers = {}
    for _, t in ipairs(batch) do
        if not t.cancelled then
            t.fn(t)
            if t.rep then table.insert(mock.timers, t) end
        end
    end
end
function live_repeating(delay)
    local n = 0
    for _, t in ipairs(mock.timers) do
        if not t.cancelled and t.rep and t.delay == delay then n = n + 1 end
    end
    return n
end
-- Split a packet the driver sent into its type, topic, payload and retain flag
function decode(pkt)
    local b = string.byte(pkt, 1)
    local i, mult = 2, 1
    repeat local c = string.byte(pkt, i); mult = mult * 128; i = i + 1 until c < 128
    local kind = math.floor(b / 16)
    if kind == 3 then
        local tl = string.byte(pkt, i) * 256 + string.byte(pkt, i + 1)
        local j = i + 2 + tl
        if math.floor(b / 2) % 4 > 0 then j = j + 2 end
        return "PUB", string.sub(pkt, i + 2, i + 1 + tl), string.sub(pkt, j), b % 2
    elseif kind == 8 then
        -- every topic filter, space separated
        local filters, j = {}, i + 2
        while j <= #pkt do
            local tl = string.byte(pkt, j) * 256 + string.byte(pkt, j + 1)
            table.insert(filters, string.sub(pkt, j + 2, j + 1 + tl))
            j = j + 3 + tl
        end
        return "SUB", table.concat(filters, " "), "", 0
    elseif kind == 4 then
        return "PUBACK", "", "", 0
    end
    return "OTHER", "", "", 0
end
function incoming_publish(flags, topic, payload, packetID)
    local vh = string.char(math.floor(#topic / 256), #topic % 256) .. topic
    if packetID then vh = vh .. string.char(math.floor(packetID / 256), packetID % 256) end
    return string.char(flags, #vh + #payload) .. vh .. payload
end
-- Fields of a CONNECT packet the driver sent
function decode_connect(pkt)
    local i = 2
    repeat local c = string.byte(pkt, i); i = i + 1 until c < 128
    local function str(at) local n = string.byte(pkt, at) * 256 + string.byte(pkt, at + 1); return string.sub(pkt, at + 2, at + 1 + n), at + 2 + n end
    local proto, j = str(i)
    local flags = string.byte(pkt, j + 1)
    local keepalive = string.byte(pkt, j + 2) * 256 + string.byte(pkt, j + 3)
    local r = { flags = flags, keepalive = keepalive }
    r.client, j = str(j + 4)
    if math.floor(flags / 4) % 2 == 1 then r.willTopic, j = str(j); r.willMessage, j = str(j) end
    if math.floor(flags / 128) % 2 == 1 then r.user, j = str(j) end
    if math.floor(flags / 64) % 2 == 1 then r.password, j = str(j) end
    return r
end
function find_connect()
    for _, p in ipairs(mock.sent) do if string.byte(p, 1) == 0x10 then return decode_connect(p) end end
end
CONNACK_OK = string.char(0x20, 0x02, 0x00, 0x00)
CONNACK_REFUSED = string.char(0x20, 0x02, 0x00, 0x05)
'''


def check(cond, msg):
    print(("PASS  " if cond else "FAIL  ") + msg)
    if not cond:
        failures.append(msg)


class Bridge:
    """A fresh driver with the mock C4 API, started up."""

    def __init__(self, setup="", init=True):
        self.lua = LuaRuntime(unpack_returned_tuples=True, encoding="latin-1")
        self.lua.execute(MOCK)
        if setup:
            self.lua.execute(setup)
        # Test hooks inside the chunk, where the driver's locals are visible
        self.lua.execute(SRC + "\nfunction _timer_count() local n = 0; for _ in pairs(gActiveTimers) do n = n + 1 end; return n end\n"
                         "function _age_inbound(s) gLastInbound = gLastInbound - s end\n"
                         "function _connected() return gConnected and gMQTTConnected end\n")
        if init:
            self.run("OnDriverInit(); OnDriverLateInit()")

    def run(self, code):
        self.lua.execute(code)

    def value(self, code):
        return self.lua.eval(code)

    def fire(self, times=1):
        for _ in range(times):
            self.run("fire_timers()")

    def online(self):
        self.run('OnConnectionStatusChanged(6001, 1883, "ONLINE")')

    def offline(self):
        self.run('OnConnectionStatusChanged(6001, 1883, "OFFLINE")')

    def connect(self):
        self.online()
        self.run("ReceivedFromNetwork(6001, 1883, CONNACK_OK)")

    def settle(self):
        """Let the startup timers finish, then forget what was sent."""
        self.fire(6)
        self.clear()

    def clear(self):
        self.run("mock.sent = {}")

    def sent(self):
        out = []
        mock = self.lua.globals().mock
        for i in range(1, len(mock.sent) + 1):
            out.append(self.lua.globals().decode(mock.sent[i]))
        return out

    def topics(self, kind="PUB"):
        return [s[1] for s in self.sent() if s[0] == kind]

    def payloads(self, topic):
        return [s[2] for s in self.sent() if s[0] == "PUB" and s[1] == topic]


GARAGE = 'homeassistant/binary_sensor/garage_door_contact_sensor_state/'
FRONT = 'homeassistant/binary_sensor/front_door_contact_sensor_state/'
TWO_CONTACTS = ('Properties["Contact Sensor Binding Map"] = "720:302:Garage Door,720:303:Front Door"; '
                'mock.names[720] = "Sensor"; mock.vars[720] = { [1010] = "90", [1011] = "3000", [1003] = "70" }')
ONE_CONTACT = ('Properties["Contact Sensor Binding Map"] = "720:302:Garage Door"; '
               'mock.names[720] = "Sensor"; mock.vars[720] = { [1010] = "90", [1011] = "3000", [1003] = "70" }')
LIGHT = ('mock.proxies[100] = 101; mock.names[100] = "Lamp"; mock.names[101] = "Lamp"; '
         'mock.vars[101] = { [1000] = "0", [1001] = "0" }; mock.persist["MonitoredLights"] = "100"')
OUTLET = ('mock.proxies[110] = 111; mock.names[110] = "Socket"; mock.names[111] = "Socket"; '
          'mock.vars[111] = { [1000] = "0" }; mock.persist["MonitoredOutlets"] = "110"')
ROOM = 'mock.proxies[5] = 5; mock.names[5] = "Den"; mock.vars[5] = { [1010] = "0" }; mock.persist["MonitoredMediaRooms"] = "5"'
THERMOSTAT = ('mock.proxies[50] = 51; mock.names[50] = "Hall"; mock.names[51] = "Hall"; mock.vars[51] = { [1130] = "72", '
              '[1132] = "68", [1134] = "74", [1104] = "Heat" }; mock.persist["MonitoredThermostats"] = "50"')


print("--- Contact sensors: each contact has its own entity ---")
b = Bridge(TWO_CONTACTS)
b.connect(); b.settle()
b.run("PublishContactSensorDiscovery(720)")
configs = [t for t in b.topics() if "binary_sensor" in t and t.endswith("/config")]
check(sorted(configs) == sorted([GARAGE + "config", FRONT + "config"]), "two contacts on a device: two entities")
ids = {json.loads(b.payloads(t)[0])["unique_id"] for t in configs}
check(ids == {"control4_contact_720_302", "control4_contact_720_303"}, "two contacts: each keeps its own unique ID")
b.clear()
b.run('ReceivedFromProxy(302, "OPENED", {}); ReceivedFromProxy(303, "CLOSED", {})')
check(b.payloads(GARAGE + "state") == ["ON"] and b.payloads(FRONT + "state") == ["OFF"], "two contacts: state goes to the right entity")
b.clear()
b.run("PublishContactSensorState(720)")
check(b.payloads(GARAGE + "state") == ["ON"] and b.payloads(FRONT + "state") == ["OFF"], "two contacts: a refresh doesn't mix up states")

b = Bridge(ONE_CONTACT)
b.connect(); b.settle()
b.run("PublishContactSensorDiscovery(720)")
check(GARAGE + "config" in b.topics() and "homeassistant/sensor/garage_door_contact_sensor_battery/config" in b.topics(),
      "one contact: same topics as before")

b = Bridge('Properties["Contact Sensor Binding Map"] = "720:302:Door,721:303:Door"; mock.names[720] = "A"; mock.names[721] = "B"')
b.connect(); b.settle()
b.run('ReceivedFromProxy(302, "OPENED", {}); ReceivedFromProxy(303, "OPENED", {})')
topics = b.topics()
check("homeassistant/binary_sensor/door_contact_sensor_state_1/state" in topics
      and "homeassistant/binary_sensor/door_contact_sensor_state_2/state" in topics, "same name twice: numbered by binding")

print("--- Contact sensors: unknown stays unknown ---")
b = Bridge(ONE_CONTACT)
b.connect(); b.settle()
b.run('ReceivedFromProxy(302, "OPENED", {})')
check(b.payloads(GARAGE + "state") == ["ON"], "open reports ON")
b.clear()
b.run('ReceivedFromProxy(302, "CLOSED", {})')
check(b.payloads(GARAGE + "state") == ["OFF"], "closed reports OFF")
b.clear()
b.run('ReceivedFromProxy(302, "SOME_OTHER_COMMAND", {})')
check(b.payloads(GARAGE + "state") == ["None"], "unrecognized command reports unknown, not closed")
b.clear()
b.run("PublishContactSensorState(720)")
check(b.payloads(GARAGE + "state") == ["None"], "a refresh keeps it unknown")

print("--- Contact sensors: only what the sensor has ---")
b = Bridge('Properties["Contact Sensor Binding Map"] = "720:302:Garage Door"; mock.names[720] = "Wired"')
b.connect(); b.settle()
b.run("PublishContactSensorDiscovery(720); PublishContactSensorState(720)")
check(not [t for t in b.topics() if "/sensor/" in t], "no battery or temperature: no entities or zero values")
check(GARAGE + "config" in b.topics(), "no battery or temperature: open/closed entity still there")
b = Bridge('Properties["Contact Sensor Binding Map"] = "720:302:Garage Door"; mock.names[720] = "Probe"; mock.vars[720] = { [1012] = "68" }')
b.connect(); b.settle()
b.run("PublishContactSensorDiscovery(720)")
topic = "homeassistant/sensor/garage_door_contact_sensor_temperature/state"
check(b.payloads(topic) == ["68"], "local temperature probe is used when there's no main temperature")
b = Bridge(ONE_CONTACT)
b.connect(); b.settle()
b.run("PublishContactSensorState(720)")
check(b.payloads("homeassistant/sensor/garage_door_contact_sensor_battery/state") == ["90"], "real battery value still published")

print("--- Reconnecting ---")
b = Bridge()
b.fire()
check(b.value("mock.connects") >= 1, "connects at startup")
b.online()
b.run("ReceivedFromNetwork(6001, 1883, CONNACK_REFUSED)")
before = b.value("mock.connects")
check(b.value("live_repeating(60000)") == 1, "refused login: a 60 second watchdog is still running")
b.fire()
check(b.value("mock.connects") == before + 1, "refused login: tries again on the next watchdog tick")

b = Bridge()
b.fire(); b.connect(); b.settle()
b.offline()
before = b.value("mock.connects")
b.fire()
check(b.value("mock.connects") == before + 1, "dropped connection: one reconnect per tick")
b.connect()
check(b.value("live_repeating(60000)") == 1, "watchdog still running after reconnecting")

b = Bridge()
b.fire(); b.connect(); b.settle()
b.run('ExecuteCommand("Disconnect", {})')
before = b.value("mock.connects")
b.fire(3)
check(b.value("mock.connects") == before, "manual Disconnect stays disconnected")
b.run('ExecuteCommand("Connect", {})')
check(b.value("mock.connects") == before + 1, "manual Connect connects")
b.connect(); b.offline()
before = b.value("mock.connects")
b.fire()
check(b.value("mock.connects") == before + 1, "after a manual Connect, reconnecting works again")

b = Bridge('Properties["Auto Reconnect"] = "Disabled"')
b.fire(); b.connect(); b.settle()
b.offline()
before = b.value("mock.connects")
b.fire(3)
check(b.value("mock.connects") == before, "Auto Reconnect disabled: no reconnecting")

b = Bridge()
b.fire(); b.connect(); b.settle()
b.run('Properties["Debug Mode"] = "Log"; OnPropertyChanged("Debug Mode")')
b.run('ExecuteCommand("Disconnect", {})')
check(b.value('(function() for _, t in ipairs(mock.timers) do if t.delay == 3600000 and not t.cancelled then return true end end return false end)()'),
      "a disconnect doesn't cancel debug mode's 1 hour auto-off")

b = Bridge()
b.fire(); b.connect(); b.settle()
b.run('local p = incoming_publish(0x30, "homeassistant/light/control4_1/set", "{}"); ReceivedFromNetwork(6001, 1883, string.sub(p, 1, 10))')
b.offline(); b.connect()
check("MQTT Connected" in str(b.value('mock.props["Connection Status"]')), "a partial packet doesn't block the next connection")

print("--- Broker address ---")
check("<default>192.168.1.xxx</default>" in XML, "default broker IP is a placeholder")
b = Bridge('Properties["MQTT Broker IP"] = "192.168.1.xxx"')
b.fire(3)
check(b.value("mock.connects") == 0, "placeholder: doesn't connect by itself")
b.run('ExecuteCommand("Connect", {})')
check(b.value("mock.connects") == 0, "placeholder: Connect reports an error instead of trying")
b = Bridge('Properties["MQTT Broker IP"] = "192.168.1.100"')
b.fire()
check(b.value("mock.connects") >= 1, "a broker really at 192.168.1.100 connects")

print("--- Discovery with no lights ---")
b = Bridge(OUTLET + "; " + ROOM + '; Properties["Contact Sensor Binding Map"] = "720:302:Garage Door"; mock.names[720] = "Sensor"')
b.connect(); b.settle()
b.run("PublishAllDiscovery()")
b.fire(6)
configs = [t for t in b.topics() if t.endswith("/config")]
check(any("control4_110" in t for t in configs) and any("control4_room_5" in t for t in configs) and GARAGE + "config" in configs,
      "outlet, media room and contact sensor are discovered")
b = Bridge(OUTLET)
b.clear(); b.connect()
subs = " ".join(b.topics("SUB")).split()
check("homeassistant/+/+/set" in subs, "outlets-only system subscribes to commands (wildcard covers its /set)")

print("--- default_entity_id ---")
b = Bridge(LIGHT + "; " + THERMOSTAT + "; " + ONE_CONTACT)
b.connect(); b.settle()
b.run("PublishLightDiscovery(100); PublishThermostatDiscovery(50); PublishContactSensorDiscovery(720)")
config = {t: json.loads(b.payloads(t)[0]) for t in b.topics() if t.endswith("/config")}
check(config["homeassistant/light/control4_100/config"].get("default_entity_id") == "light.lamp", "light")
check(config["homeassistant/climate/control4_50/config"].get("default_entity_id") == "climate.hall", "thermostat")
check(config[GARAGE + "config"].get("default_entity_id") == "binary_sensor.garage_door_contact_sensor_state", "contact sensor")
check(config["homeassistant/sensor/garage_door_contact_sensor_battery/config"].get("default_entity_id")
      == "sensor.garage_door_contact_sensor_battery", "battery sensor")
b = Bridge('mock.proxies[100] = 101; mock.names[100] = "x"; mock.names[101] = string.char(227, 131, 169); mock.vars[101] = { [1001] = "0" }')
b.connect(); b.settle()
b.run("PublishLightDiscovery(100)")
check(json.loads(b.payloads("homeassistant/light/control4_100/config")[0]).get("default_entity_id") == "light.control4_100",
      "a name with no usable characters falls back to the device ID")

print("--- Outlets ---")
# Device and proxy IDs differ
b = Bridge(OUTLET)
b.connect(); b.settle()
b.run('mock.vars[111][1000] = "1"; OnWatchedVariableChanged(111, 1000, "1")')
check(b.payloads("homeassistant/switch/control4_110/state") == ["ON"], "outlet with a separate proxy: a change reaches Home Assistant")
# Device and proxy IDs are the same
b = Bridge('mock.names[602] = "Office Lamp"; mock.vars[602] = { [1000] = "0" }; mock.proxies[602] = 602; mock.persist["MonitoredOutlets"] = "602"')
b.connect(); b.settle()
b.run('mock.vars[602][1000] = "1"; OnWatchedVariableChanged(602, 1000, "1")')
check(b.payloads("homeassistant/switch/control4_602/state") == ["ON"], "outlet that is its own proxy: a change reaches Home Assistant")

print("--- Device names that need escaping ---")
NAME = r'TV 65" Back\lamp'
TRICKY = ("""Properties["Enable LED Color Control"] = "Enabled"; Properties["Enable Advanced Dimmer Controls"] = "Enabled";
tricky = [[TV 65" Back\lamp]]
for _, id in ipairs({100, 101, 110, 111, 120, 121, 50, 51, 5}) do mock.names[id] = tricky end
mock.proxies[100] = 101; mock.vars[101] = { [1000] = "1", [1001] = "50", [1002] = "1", [1003] = "1", [1004] = "1", [1005] = "1", [1006] = "1" }
mock.proxies[110] = 111; mock.vars[111] = { [1000] = "0" }
mock.proxies[120] = 121; mock.vars[121] = { [1000] = "0" }
mock.proxies[50] = 51; mock.vars[51] = { [1130] = "72", [1132] = "68", [1134] = "74", [1104] = "Heat" }; mock.vars[50] = { [1001] = "255,0,0" }
mock.proxies[5] = 5; mock.vars[5] = { [1010] = "1" }
mock.persist["MonitoredLights"] = "100"; mock.persist["MonitoredOutlets"] = "110"; mock.persist["MonitoredSwitches"] = "120"
mock.persist["MonitoredThermostats"] = "50"; mock.persist["MonitoredMediaRooms"] = "5"
Properties["Contact Sensor Binding Map"] = [[720:302:Gate "A"]]; mock.names[720] = "Sensor"; mock.vars[720] = { [1010] = "90", [1011] = "3000", [1003] = "70" }""")
b = Bridge(TRICKY)
b.connect(); b.settle()
b.run("PublishAllDiscovery()")
b.fire(12)
kinds, bad, names = set(), [], []
for t in b.topics():
    if t.endswith("/config"):
        kinds.add(t.split("/")[1])
        try:
            names.append(json.loads(b.payloads(t)[0])["device"]["name"])
        except ValueError:
            bad.append(t)
check(not bad, f"every discovery message is valid JSON ({len(names)} checked, invalid: {bad[:3]})")
check(kinds >= {"light", "switch", "climate", "text", "number", "media_player", "binary_sensor", "sensor"},
      f"that covers every entity type ({sorted(kinds)})")
check(NAME in names, "the device name reaches Home Assistant unchanged")
check('Gate "A" Contact Sensor' in names, "a contact sensor name with quotes reaches Home Assistant unchanged")
b = Bridge('mock.proxies[100] = 101; mock.names[100] = "x"; mock.names[101] = "Line" .. string.char(9) .. "Tab"; mock.vars[101] = { [1001] = "0" }')
b.connect(); b.settle()
b.run("PublishLightDiscovery(100)")
check(json.loads(b.payloads("homeassistant/light/control4_100/config")[0])["device"]["name"] == "Line\tTab", "control characters are escaped too")

print("--- Device list ---")
b = Bridge(ROOM + '; mock.vars[5][1011] = "35"; Properties["Debug Mode"] = "Log"; mock.logs = {}; function C4:DebugLog(m) table.insert(mock.logs, m) end; print = function() end')
b.run('ExecuteCommand("ListAll", {})')
logs = b.lua.globals().mock.logs
text = "\n".join(str(logs[i]) for i in range(1, len(logs) + 1))
check("[5] Den - Power: OFF, Volume: 35, Playback: idle" in text, "the device list shows media rooms")

print("--- Smaller fixes ---")
b = Bridge(OUTLET + '; Properties["Debug Mode"] = "Log"; mock.logs = {}; function C4:DebugLog(m) table.insert(mock.logs, m) end; print = function() end')
b.run('ExecuteCommand("ListAll", {})')
logs = b.lua.globals().mock.logs
text = "\n".join(str(logs[i]) for i in range(1, len(logs) + 1))
check("[110] Socket - State: OFF (proxy 111)" in text, "the device list shows outlets")

b = Bridge(THERMOSTAT)
b.connect(); b.settle()
b.run("PublishThermostatState(50)")
check([s[3] for s in b.sent() if s[1] == "homeassistant/climate/control4_50/state"] == [1], "thermostat state is retained")

b = Bridge(LIGHT)
b.connect(); b.settle()
topic = "homeassistant/light/control4_100/set"
for flags, label in ((0x32, "QoS 1"), (0x3A, "QoS 1 redelivery (DUP)")):
    b.clear()
    b.run(f"""ReceivedFromNetwork(6001, 1883, incoming_publish({flags}, "{topic}", '{{"state":"ON"}}', 7))""")
    check(len([s for s in b.sent() if s[0] == "PUBACK"]) == 1, f"{label} is acknowledged")

b = Bridge(ROOM)
b.connect(); b.settle()
b.run("for i = 1, 500 do PublishMediaRoomStateDebounced(5); fire_timers() end")
check(b.value("_timer_count()") == 0, "fired timers aren't kept forever")
b.run("PublishMediaRoomStateDebounced(5)")
check(b.value("_timer_count()") == 1, "a pending timer is tracked")
b.run('ExecuteCommand("Disconnect", {})')
check(b.value("_timer_count()") == 0 and b.value("#mock.timers >= 0"), "a disconnect cancels pending timers")

b = Bridge()
b.connect()
try:
    b.run("OnDriverDestroyed()")
    check(b.value('mock.props["Connection Status"]') == "Disconnected", "driver shutdown runs to the end and disconnects")
except Exception as e:
    check(False, f"driver shutdown runs to the end and disconnects ({str(e).splitlines()[0][:80]})")
try:
    b.run('UIRequest("GET_ACTIONS")')
    check(True, "UIRequest doesn't crash")
except Exception as e:
    check(False, f"UIRequest doesn't crash ({str(e).splitlines()[0][:80]})")
b = Bridge('mock.names[9] = "Thing"; mock.inspected = false; function C4:GetDeviceVariables(id) mock.inspected = true; return {} end')
b.run('ExecuteCommand("Inspect Device", {["Device ID"] = "9"})')
check(b.value("mock.inspected") is True, "the Inspect Device command works")

check("<default>Off</default>" in XML and "<default>Print and Log</default>" not in XML, "debug logging is off by default")

STATUS = "control4/bridge/status"

import re
xml_version = re.search(r"<version>([^<]+)</version>", XML).group(1)
lua_version = re.search(r'local DRIVER_VERSION = "([^"]+)"', SRC).group(1)
check(xml_version == lua_version and f"<model>MQTT Bridge v{xml_version}</model>" in XML,
      f"driver.lua version matches driver.xml ({lua_version} / {xml_version})")

print("--- Bridge availability: Will, online, offline ---")
b = Bridge(LIGHT)
b.online()
c = b.value("find_connect()")
check(c.flags & 0x04 and c.flags & 0x08 and not c.flags & 0x10 and c.flags & 0x20,
      f"CONNECT has a Will at QoS 1, retained (flags {c.flags:#04x})")
check(c.willTopic == STATUS and c.willMessage == "offline", "Will: control4/bridge/status = offline")
check(c.keepalive == 60 and c.flags & 0x02, "keep alive 60 s, clean session as before")
check(c.client.startswith("Control4_HA_1234_") and len(c.client) <= 23, f"client ID per instance: {c.client}")
first_client = c.client
b.run("ReceivedFromNetwork(6001, 1883, CONNACK_OK)")
pubs = [s for s in b.sent() if s[0] == "PUB" and s[1] == STATUS]
check(pubs and pubs[0][2] == "online" and pubs[0][3] == 1, "CONNACK: online published, retained")
b.offline(); b.clear(); b.online()
check(b.value("find_connect()").client == first_client, "the client ID stays the same when reconnecting")

b = Bridge('Properties["MQTT Username"] = ""; Properties["MQTT Password"] = "secret"')
b.online()
c = b.value("find_connect()")
check(not c.flags & 0x40 and not c.flags & 0x80 and c.password is None, "password without a user name: no password flag")
b = Bridge('Properties["MQTT Username"] = "ha"; Properties["MQTT Password"] = "secret"')
b.online()
c = b.value("find_connect()")
check(c.flags & 0xC0 == 0xC0 and c.user == "ha" and c.password == "secret", "user name and password: both sent, after the Will")

b = Bridge(LIGHT)
b.connect(); b.settle()
b.run("OnDriverDestroyed()")
pubs = [s for s in b.sent() if s[0] == "PUB" and s[1] == STATUS]
check(pubs and pubs[-1][2] == "offline" and pubs[-1][3] == 1, "driver removed: offline published (retained) before disconnecting")

print("--- Availability in every discovery config ---")
b = Bridge(TRICKY)
b.connect(); b.settle()
b.run("PublishAllDiscovery()")
b.fire(12)
missing = []
for t in b.topics():
    if t.endswith("/config"):
        cfg = json.loads(b.payloads(t)[0])
        if not (cfg.get("availability_topic") == STATUS and cfg.get("payload_available") == "online"
                and cfg.get("payload_not_available") == "offline"):
            missing.append(t)
check(not missing, f"every config depends on the bridge status ({missing[:3]})")
room = json.loads(b.payloads("homeassistant/media_player/control4_room_5/config")[0])
check(room["availability_mode"] == "all" and {"topic": "homeassistant/media_player/control4_room_5/availability"} in room["availability"],
      "media room: bridge and its own topic, both must be online")
check(json.loads(b.payloads("homeassistant/light/control4_100/config")[0])["unique_id"] == "control4_light_100", "unique IDs unchanged")

print("--- Commands: wildcard subscriptions, retained /set ignored ---")
b = Bridge(LIGHT)
b.connect(); b.settle()
check(not b.topics("SUB"), "no per-device SUBSCRIBEs any more")
b.run('mock.proxies[200] = 201; mock.names[200] = "New"; mock.names[201] = "New"; mock.vars[201] = { [1000] = "0", [1001] = "0" }')
b.run("AddLightToMonitor(200)")
check(not b.topics("SUB"), "a light added later needs no new subscription")
b.run('ReceivedFromNetwork(6001, 1883, incoming_publish(0x30, "homeassistant/light/control4_200/set", \'{"state":"ON"}\'))')
check(b.value("#mock.cmds") == 1 and b.value("mock.cmds[1].id") == 201, "... and is controllable at once")
b.run("mock.cmds = {}")
b.run('ReceivedFromNetwork(6001, 1883, incoming_publish(0x31, "homeassistant/light/control4_100/set", \'{"state":"ON"}\'))')
check(b.value("#mock.cmds") == 0, "a retained command (left on the broker) is ignored")
check("retained" in str(b.value('mock.props["Last Error"]')), "and logged")
b.clear()
b.run('ReceivedFromNetwork(6001, 1883, incoming_publish(0x33, "homeassistant/light/control4_100/set", \'{"state":"ON"}\', 9))')
check(b.value("#mock.cmds") == 0 and [s for s in b.sent() if s[0] == "PUBACK"], "retained QoS 1 command: acknowledged, not run")
b.run('ReceivedFromNetwork(6001, 1883, incoming_publish(0x30, "homeassistant/light/somebody_else/set", \'{"state":"ON"}\'))')
b.run('ReceivedFromNetwork(6001, 1883, incoming_publish(0x30, "homeassistant/switch/control4_999/set", "ON"))')
check(b.value("#mock.cmds") == 0, "other integrations' and unmonitored devices' commands are ignored")
b.run('function HandleMQTTCommand() error("boom") end')
b.clear()
b.run('ReceivedFromNetwork(6001, 1883, incoming_publish(0x32, "homeassistant/light/control4_100/set", "x", 5) .. string.char(0xD0, 0x00))')
check([s for s in b.sent() if s[0] == "PUBACK"] and b.value("_connected()"), "a failing command is still acknowledged; the next packet is handled")
b.run("mock.props['Last Error'] = nil; ReceivedFromNetwork(6001, 1883, string.char(0x90, 0x05, 0x00, 0x02, 0x01, 0x80, 0x01))")
check("refused" in str(b.value('mock.props["Last Error"]')), "SUBACK failure (0x80) is logged")

b = Bridge(THERMOSTAT)
b.connect(); b.settle()
b.run('ReceivedFromNetwork(6001, 1883, incoming_publish(0x30, "homeassistant/climate/control4_50/mode/set", "cool"))')
check(b.value("#mock.cmds") == 1 and b.value("mock.cmds[1].cmd") == "SET_MODE_HVAC" and b.value("mock.cmds[1].id") == 51
      and b.value("mock.cmds[1].params.MODE") == "Cool", "thermostat mode command reaches the thermostat as before")

print("--- Home Assistant restarts ---")
b = Bridge(LIGHT)
b.connect(); b.settle(); b.fire(6); b.clear()
b.run('ReceivedFromNetwork(6001, 1883, incoming_publish(0x31, "homeassistant/status", "online"))')
b.fire(6)
check("homeassistant/light/control4_100/config" not in b.topics(), "retained birth message (on subscribing): no second discovery run")
b.run('ReceivedFromNetwork(6001, 1883, incoming_publish(0x30, "homeassistant/status", "online"))')
b.fire(6)
check("homeassistant/light/control4_100/config" in b.topics() and "homeassistant/light/control4_100/state" in b.topics(),
      "birth message: discovery, then states, sent again")
b = Bridge(LIGHT)
b.clear(); b.connect(); b.fire(8)
check("homeassistant/light/control4_100/config" in b.topics(), "discovery is sent again after every CONNACK")

print("--- State publishing: immediate, no repeats ---")
b = Bridge(LIGHT)
b.connect(); b.settle(); b.fire(8); b.clear()
LS = "homeassistant/light/control4_100/state"
STATS_MS = 10000
b.run("fire_timers()")  # the Messages Sent property: updated at most every 10 s, not part of a state publish
timers_before = [b.value("mock.timers[%d].delay" % i) for i in range(1, b.value("#mock.timers") + 1)]
b.run('mock.vars[101][1001] = "40"; OnWatchedVariableChanged(101, 1001, "40")')
check([json.loads(p)["brightness"] for p in b.payloads(LS)] == [102], "a change is published within the callback")
b.run('mock.vars[101][1001] = "60"; OnWatchedVariableChanged(101, 1001, "60")')
b.run('mock.vars[101][1001] = "80"; OnWatchedVariableChanged(101, 1001, "80")')
check([json.loads(p)["brightness"] for p in b.payloads(LS)] == [102, 153, 204], "each distinct change at once, none held back")
check([b.value("mock.timers[%d].delay" % i) for i in range(1, b.value("#mock.timers") + 1) if b.value("mock.timers[%d].delay" % i) != STATS_MS] == [d for d in timers_before if d != STATS_MS],
      "no timer started on the state path (only the 10 s statistics property throttle)")
b.run('OnWatchedVariableChanged(101, 1000, "1")')
check(len(b.payloads(LS)) == 3, "an identical payload is not sent again")
b.run('mock.vars[101][1001] = "10"; OnWatchedVariableChanged(101, 1001, "10")')
check(len(b.payloads(LS)) == 4 and json.loads(b.payloads(LS)[-1])["brightness"] == 25, "a change after an identical one is published at once")
b.run('mock.vars[101][1001] = "40"; OnWatchedVariableChanged(101, 1001, "40"); mock.vars[101][1001] = "10"; OnWatchedVariableChanged(101, 1001, "10")')
check([json.loads(p)["brightness"] for p in b.payloads(LS)][-2:] == [102, 25], "a quick change and back: both published")
b.run("ExecuteCommand('RefreshAll', {})")
check(len(b.payloads(LS)) == 7, "a refresh always publishes")
b.run('OnWatchedVariableChanged(101, 1001, nil)')  # error inside: protected
check(b.value("_connected()"), "an error in a variable change handler doesn't escape")

b = Bridge(LIGHT)
b.connect(); b.settle()
before = b.value('mock.propCount["Messages Sent"]') or 0
b.run("for i = 1, 50 do PublishMQTT('t/' .. i, 'x', 0, false) end")
check((b.value('mock.propCount["Messages Sent"]') or 0) - before <= 1, "Messages Sent property not updated per message")
b.run("fire_timers()")
check(b.value('mock.props["Messages Sent"]') is not None and int(b.value('mock.props["Messages Sent"]')) >= 50,
      "... but brought up to date within 10 s")

print("--- Liveness and reconnecting ---")
b = Bridge(LIGHT)
b.connect(); b.settle()
b.run("_age_inbound(80)"); b.fire()
check(b.value("_connected()"), "80 s without a packet from the broker: still connected")
b.run("_age_inbound(20)"); b.fire()
check(not b.value("_connected()") and b.value("#mock.disconnects") >= 1, "over 90 s (1.5x keep alive) without a packet: disconnected")
before = b.value("mock.connects")
b.fire()
check(b.value("mock.connects") == before + 1, "... and reconnects")
b.connect()
b.run("_age_inbound(60)"); b.run('ReceivedFromNetwork(6001, 1883, string.char(0xD0, 0x00))'); b.fire()
check(b.value("_connected()"), "a PINGRESP counts as life")

b = Bridge(LIGHT)
b.fire(); b.connect(); b.settle()
delays = []
for _ in range(7):
    b.offline()
    delays.append(b.value("(function() for _, t in ipairs(mock.timers) do if t.delay >= 2000 and t.delay <= 60000 and t.delay ~= 15000 and not t.rep and not t.cancelled then return t.delay end end end)()"))
    b.run("for _, t in ipairs(mock.timers) do if t.delay == %d then t.fn(t); t.cancelled = true end end" % delays[-1])
    b.online()
check(delays == [2000, 4000, 8000, 16000, 32000, 60000, 60000], f"reconnect backoff 2 s doubling to 60 s: {delays}")
b.run("ReceivedFromNetwork(6001, 1883, CONNACK_OK)"); b.offline()
check(b.value("(function() for _, t in ipairs(mock.timers) do if t.delay == 2000 and not t.cancelled and not t.rep then return true end end return false end)()"),
      "a CONNACK resets the backoff")
PENDING = "(function() local n = 0 for _, t in ipairs(mock.timers) do if ({[2000]=1,[4000]=1,[8000]=1,[16000]=1,[32000]=1,[60000]=1})[t.delay] and not t.rep and not t.cancelled then n = n + 1 end end return n end)()"
n = b.value(PENDING)
b.offline()
b.run('ExecuteCommand("Disconnect", {}); ExecuteCommand("Connect", {})'); b.offline()
n2 = b.value(PENDING)
check(n == n2 == 1, "only one reconnect pending at a time")

b = Bridge(LIGHT)
b.connect(); b.settle()
b.run('ReceivedFromNetwork(6001, 1883, string.char(0x30) .. string.char(0xFF, 0xFF, 0x03))')
check(not b.value("_connected()") and b.value('mock.props["Connection Status"]') == "Disconnected", "oversize packet: disconnect (not just clear the buffer)")
before = b.value("mock.connects")
b.fire()
check(b.value("mock.connects") == before + 1, "... and reconnect")

b = Bridge(LIGHT)
b.fire(); b.connect(); b.settle()
b.run('Properties["MQTT Broker IP"] = "10.0.0.9"; Properties["MQTT Broker Port"] = "1884"; OnPropertyChanged("MQTT Broker IP")')
check(b.value("mock.disconnects[#mock.disconnects]") == 1883, "broker changed: the old connection is closed on the port it was opened with")
b.fire()
check(b.value("mock.addresses[#mock.addresses]") == "10.0.0.9", "... and the new address is connected")
b.run('OnConnectionStatusChanged(6001, 1883, "OFFLINE")')
check(b.value('mock.props["Connection Status"]') == "Connecting...", "a late OFFLINE of the old port is ignored")
b.clear(); b.run('OnConnectionStatusChanged(6001, 1884, "ONLINE")')
check(b.value("find_connect()") is not None, "the new connection logs in")

print("--- Lights not found ---")
b = Bridge(LIGHT)
b.connect(); b.settle()
b.run("mock.names[101] = nil; mock.names[100] = nil; PublishLightState(100)")
check(b.value('mock.persist["MonitoredLights"]') == "100" and "homeassistant/light/control4_100/config" not in b.topics(),
      "a light whose name can't be read once is not removed")
b.run("PublishLightState(100); PublishLightState(100)")
check(b.value('mock.persist["MonitoredLights"]') == "100", "nor after 3 misses within a minute")
b.run("ExecuteCommand('CleanupDeleted', {})")
check(b.value('mock.persist["MonitoredLights"]') == "" and b.payloads("homeassistant/light/control4_100/config") == [""],
      "the Cleanup action removes it at once")

print("--- Thermostat: payload as before, fractional values safe on newer Lua ---")
b = Bridge(THERMOSTAT)
b.connect(); b.settle()
b.run("PublishThermostatState(50)")
st = json.loads(b.payloads("homeassistant/climate/control4_50/state")[-1])
check(st["current_temperature"] == 72 and st["temperature"] == 68 and st["mode"] == "heat", f"integer values as before: {st}")
raw_int = b.payloads("homeassistant/climate/control4_50/state")[-1]
b.run('mock.vars[51][1130] = "72.6"; mock.vars[51][1138] = "45.5"; PublishThermostatState(50)')
st = json.loads(b.payloads("homeassistant/climate/control4_50/state")[-1])
check(st["current_temperature"] == 72 and st["humidity"] == 45, f"fractional values cut as Lua 5.1 '%d' did (runs on Lua 5.5): {st}")
b.run('mock.vars[51][1130] = "72"; mock.vars[51][1138] = nil; PublishThermostatState(50)')
check(b.payloads("homeassistant/climate/control4_50/state")[-1] == raw_int, "payload text unchanged for integer values")

print("--- Remove All Entities ---")
b = Bridge(TRICKY)
b.connect(); b.settle()
b.run("ExecuteCommand('RemoveAllEntities', {})")
removed = {t for t in b.topics() if t.endswith("/config") and b.payloads(t) == [""]}
for t in ("homeassistant/text/control4_thermostat_50_button_led/config", "homeassistant/media_player/control4_room_5/config",
          "homeassistant/number/control4_100_preset_level/config", "homeassistant/text/control4_100_top_on/config",
          "homeassistant/text/control4_120_top_on/config", "homeassistant/binary_sensor/gate_a_contact_sensor_state/config",
          "homeassistant/sensor/gate_a_contact_sensor_battery/config"):
    check(t in removed, f"removes {t}")

print("--- Media room debounce ---")
b = Bridge(ROOM)
b.connect(); b.settle()
b.run("PublishMediaRoomStateDebounced(5); PublishMediaRoomStateDebounced(5); PublishMediaRoomStateDebounced(5)")
b.run("fire_timers()")
check(len(b.payloads("homeassistant/media_player/control4_room_5/state")) == 1, "three quick changes: one publish (earlier timers cancelled)")

print("--- Devices deleted from the project ---")
PROJECT = (LIGHT + "; " + OUTLET + "; " + ROOM + "; " + THERMOSTAT + "; " + ONE_CONTACT + r"""
mock.sysEvents = {}
function C4:RegisterSystemEvent(id, item) table.insert(mock.sysEvents, id) end
function C4:UnregisterVariableListener(id, var) mock.listeners[id .. ":" .. var] = nil end
-- The room (5) is not a device in C4:GetDevices(), as on a controller
mock.devices = { [100] = { deviceName = "Lamp", proxies = { [101] = true } },
    [110] = { deviceName = "Socket", proxies = { [111] = true } },
    [50] = { deviceName = "Hall", proxies = { [51] = true } },
    [720] = { deviceName = "Sensor", proxies = {} } }
function C4:GetDevices() if mock.devicesFail then error("not ready") end return mock.devices end
function delete_device(id, proxy) mock.devices[id] = nil; mock.names[id] = nil; if proxy then mock.names[proxy] = nil end end
-- Fire the live one-shot timers of one delay (the delete check's own), nothing else
function fire_delay(d)
    local batch = mock.timers
    mock.timers = {}
    local due = {}
    for _, t in ipairs(batch) do
        if t.delay == d and not t.rep and not t.cancelled then table.insert(due, t) else table.insert(mock.timers, t) end
    end
    for _, t in ipairs(due) do t.fn(t) end
    return #due
end
function live_delay(d)
    local n = 0
    for _, t in ipairs(mock.timers) do if t.delay == d and not t.cancelled then n = n + 1 end end
    return n
end
""")
ITEM_REMOVED = 'OnSystemEvent(\'<systemevent name="OnItemRemoved"><itemid>100</itemid></systemevent>\')'


def project():
    b = Bridge(PROJECT)
    b.connect(); b.settle(); b.fire(8); b.clear()
    return b


def emptied(b):
    return [s[1] for s in b.sent() if s[0] == "PUB" and s[2] == "" and s[1].endswith("/config")]


b = project()
check([b.value("mock.sysEvents[%d]" % i) for i in range(1, b.value("#mock.sysEvents") + 1)] == [11],
      "only OnItemRemoved (11) registered, not OnProjectChanged")
check(b.value('mock.listeners["101:1001"]') is True, "light listener registered at start")
b.run("delete_device(100, 101)")
b.run(ITEM_REMOVED)
check(b.value("gSystemEventRawLogged") is True, "the raw event is logged (once per load)")
b.run("fire_delay(3000)")
check(emptied(b) == [] and b.value("live_delay(5000)") == 1, "3 s after the event: missing, checked again in 5 s, nothing removed yet")
b.run("fire_delay(5000)")
gone = emptied(b)
check("homeassistant/light/control4_100/config" in gone and "homeassistant/text/control4_100_top_on/config" in gone
      and "homeassistant/number/control4_100_preset_level/config" in gone and "homeassistant/number/control4_100_hold_ramp_rate_down/config" in gone,
      "deleted light: light, LED text and dimmer number configs emptied")
check(all(t.startswith("homeassistant/") and "control4_100" in t for t in gone), "nothing else removed")
check("100" not in (b.value('mock.persist["MonitoredLights"]') or "").split(","), "deleted light dropped from the saved list")
check(b.value('mock.listeners["101:1001"]') is None, "its listeners unregistered")
check("Lamp" in (b.value('mock.props["Last Event"]') or ""), "Last Event names it")

b = project()
b.run(ITEM_REMOVED + "; fire_delay(3000); fire_delay(5000)")
check(emptied(b) == [] and b.value('mock.persist["MonitoredLights"]') == "100", "an untracked deletion removes nothing")

b = project()
b.run("delete_device(100, 101); " + ITEM_REMOVED + "; fire_delay(3000)")
b.run('mock.devices[100] = { proxies = { [101] = true } }; mock.names[100] = "Lamp"; mock.names[101] = "Lamp"; fire_delay(5000)')
check(emptied(b) == [] and b.value('mock.persist["MonitoredLights"]') == "100", "back within 5 s (driver update): nothing removed")

b = project()
b.run("delete_device(100, 101); mock.devices = {}; " + ITEM_REMOVED + "; fire_delay(3000); fire_delay(5000)")
check(emptied(b) == [] and b.value('mock.persist["MonitoredLights"]') == "100", "empty device list: nothing removed")
b = project()
b.run("delete_device(100, 101); mock.devicesFail = true; " + ITEM_REMOVED + "; fire_delay(3000); fire_delay(5000)")
check(emptied(b) == [] and b.value('mock.persist["MonitoredLights"]') == "100", "device list fails: nothing removed")

b = project()
b.run("delete_device(100, 101); delete_device(110, 111); delete_device(50, 51); " + ITEM_REMOVED + "; fire_delay(3000); fire_delay(5000)")
check(emptied(b) == [] and b.value('mock.persist["MonitoredLights"]') == "100", "3 of 5 gone at once: refused, nothing removed")

b = project()
b.run("mock.names[5] = nil; " + ITEM_REMOVED + "; fire_delay(3000); fire_delay(5000)")
check(emptied(b) == ["homeassistant/media_player/control4_room_5/config"] and (b.value('mock.persist["MonitoredMediaRooms"]') or "") == "",
      "deleted media room removed")

b = project()
b.run("delete_device(720); " + ITEM_REMOVED + "; fire_delay(3000); fire_delay(5000)")
gone = emptied(b)
check(GARAGE + "config" in gone and any(t.startswith("homeassistant/sensor/") and "battery" in t for t in gone),
      "deleted contact sensor: contact and battery sensors removed")
check("720" not in (b.value('Properties["Contact Sensor Binding Map"]') or "") and (b.value('mock.persist["MonitoredContactSensors"]') or "") == "",
      "... and dropped from the binding map and the saved list")

b = project()
b.run("delete_device(100, 101); delete_device(110, 111)")
b.run(ITEM_REMOVED + "; " + ITEM_REMOVED + "; " + ITEM_REMOVED)
check(b.value("live_delay(3000)") == 1, "several delete events: one check pending")
b.run("fire_delay(3000)")
check(b.value("live_delay(5000)") == 1, "... one confirmation")
b.run("fire_delay(5000)")
gone = emptied(b)
check("homeassistant/light/control4_100/config" in gone and "homeassistant/switch/control4_110/config" in gone,
      "... which removes both")

b = Bridge(PROJECT)
b.run("delete_device(100, 101); " + ITEM_REMOVED + "; fire_delay(3000); fire_delay(5000)")
check(b.value('mock.persist["MonitoredLights"]') == "", "deleted while disconnected: dropped from the list at once")
b.clear(); b.connect()
check("homeassistant/light/control4_100/config" in emptied(b), "... and its configs emptied on connecting")

print()
if failures:
    print(f"{len(failures)} FAILED")
    sys.exit(1)
print("all passed")
