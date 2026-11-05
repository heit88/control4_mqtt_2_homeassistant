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
mock = { vars = {}, names = {}, proxies = {}, persist = {}, sent = {}, props = {}, timers = {}, connects = 0 }
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
function C4:UpdateProperty(k, v) mock.props[k] = v end
function C4:SendToNetwork(_, _, data) table.insert(mock.sent, data) end
function C4:NetConnect() mock.connects = mock.connects + 1 end
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
        local tl = string.byte(pkt, i + 2) * 256 + string.byte(pkt, i + 3)
        return "SUB", string.sub(pkt, i + 4, i + 3 + tl), "", 0
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
        self.lua.execute(SRC + "\nfunction _timer_count() local n = 0; for _ in pairs(gActiveTimers) do n = n + 1 end; return n end\n")
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
b.connect(); b.clear()
b.fire(4)
check("homeassistant/switch/control4_110/set" in b.topics("SUB"), "outlets-only system subscribes to commands")

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

print()
if failures:
    print(f"{len(failures)} FAILED")
    sys.exit(1)
print("all passed")
