"""Mock test of the bridge's outlet handling across the outlet driver generations: the original
outlet light (its own proxy), the stock V2 outlet light (a Light V2 proxy) and the community Lua
outlet driver (one device, a keypad proxy and two Light V2 proxies). Runs driver.lua in lupa with
a mock C4 API.

    pip install lupa
    python tests/outlet_test.py
"""
import sys
from pathlib import Path

from lupa import LuaRuntime

DRIVER = Path(__file__).resolve().parent.parent / "driver.lua"

lua = LuaRuntime(unpack_returned_tuples=True)
failures = []


def check(cond, msg):
    print(("PASS  " if cond else "FAIL  ") + msg)
    if not cond:
        failures.append(msg)


lua.execute(r'''
Properties = { ["Debug Mode"] = "Off", ["Enable Advanced Dimmer Controls"] = "Disabled", ["Enable LED Control"] = "Disabled" }
mock = { vars = {}, cmds = {}, published = {}, listeners = {}, proxies = {}, byfile = {}, names = {}, devices = {} }
C4 = setmetatable({}, { __index = function() return function() end end })
-- Like the controller: a missing variable returns no value (not nil)
function C4:GetDeviceVariable(id, var)
    local v = mock.vars[id] and mock.vars[id][var]
    if v == nil then return end
    return v
end
function C4:SendToDevice(id, cmd, params) table.insert(mock.cmds, { id = id, cmd = cmd, params = params or {} }) end
function C4:GetProxyDevicesById(id) return mock.proxies[id] end
function C4:GetDevicesByC4iName(name) return mock.byfile[name] or {} end
function C4:GetDeviceDisplayName(id) return mock.names[id] end
function C4:RegisterVariableListener(id, var) mock.listeners[id .. ":" .. var] = true end
function C4:UnregisterVariableListener(id, var) mock.listeners[id .. ":" .. var] = nil end
function C4:SetTimer() return { Cancel = function() end } end
function C4:GetDevices() return mock.devices end

-- Original outlet light (outlet_light.c4i): 602 is its own proxy
mock.byfile["outlet_light.c4i"] = { ["602"] = "Porch Outlet" }
mock.names[602] = "Porch Outlet"
mock.vars[602] = { [1000] = "0" }

-- Stock V2 outlet light (outlet_nondimmable_light.c4i): device 848, Light V2 proxy 849
mock.byfile["outlet_nondimmable_light.c4i"] = { ["848"] = "Office Outlet" }
mock.proxies[848] = "849"
mock.names[848], mock.names[849] = "Office Outlet", "Office Outlet"
mock.vars[849] = { [1000] = "1" }
mock.devices[848] = { proxies = { [849] = {} } }

-- Community Lua outlet driver: device 900, keypad proxy 901, Light V2 proxies 902 and 903
-- As on a real controller: C4:GetDevicesByC4iName finds nothing for the .c4z, C4:GetDevices names its file
mock.proxies[900] = "901,902,903"
mock.names[900], mock.names[901] = "Wireless Outlet Switch", "Wireless Outlet Switch"
mock.names[902], mock.names[903] = "Outlet 1", "Outlet 2"
mock.vars[902] = { [1000] = "0" }
mock.vars[903] = { [1000] = "1" }
mock.devices[900] = { driverFileName = "outlet_switch_loz5s1_lua.c4z", proxies = { [901] = {}, [902] = {}, [903] = {} } }

-- An ordinary Light V2 light: device 300, proxy 301
mock.proxies[300] = "301"
mock.names[300], mock.names[301] = "Den Lamp", "Den Lamp"
mock.vars[301] = { [1000] = "1", [1001] = "55" }
mock.devices[300] = { driverFileName = "hue_light.c4z", proxies = { [301] = {} } }

mock.byfile["light_v2.c4i"] = { ["849"] = "Office Outlet", ["902"] = "Outlet 1", ["903"] = "Outlet 2", ["301"] = "Den Lamp" }
''')

src = DRIVER.read_text(encoding="utf-8")
src += "\nfunction _test_connect() gMQTTConnected = true end\n"
lua.execute(src)
lua.execute(r'''
function PublishMQTT(topic, message) table.insert(mock.published, { topic = topic, msg = message }) return true end
_test_connect()
''')
g = lua.globals()
mock = g.mock


def published(topic):
    """Last message published to topic, or None."""
    msgs = [mock.published[i].msg for i in range(1, len(mock.published) + 1) if mock.published[i].topic == topic]
    return msgs[-1] if msgs else None


def monitored(kind):
    return sorted(g.GetMonitoredList(kind).values())


def command(topic, payload):
    n = len(mock.cmds)
    g.HandleMQTTCommand(topic, payload)
    return [(mock.cmds[i].id, mock.cmds[i].cmd) for i in range(n + 1, len(mock.cmds) + 1)]


# --- finding outlets ---
found = sorted(g.FindOutletProxies().values())
check(found == [602, 849, 902, 903], f"outlets of all three driver generations found by proxy: {found}")
check(not g.IsOutletProxy(901) and not g.IsOutletProxy(301), "the keypad proxy and an ordinary light are not outlets")
check(g.GetProxyID(903) == 903 and g.GetProxyID(602) == 602, "an outlet is its own proxy")
check(g.GetProxyID(300) == 301, "ordinary lights resolve their proxy as before")

# --- discovery ---
g.DiscoverAllDevices("OUTLET")
check(monitored("OUTLET") == [602, 849, 902, 903], f"outlet discovery monitors each outlet separately: {monitored('OUTLET')}")
for pid in (602, 849, 902, 903):
    check(mock.listeners[f"{pid}:1000"] is True, f"listening for state changes on outlet {pid}")

g.AddLightToMonitor(900)  # as before this version: the two-outlet device listed as one light
g.DiscoverAllDevices("LIGHT")
check(published("homeassistant/light/control4_900/config") == "", "the outlet device's old light entity is removed from Home Assistant")
check(published("homeassistant/text/control4_900_top_on/config") == ""
      and published("homeassistant/text/control4_900_bottom_off/config") == ""
      and published("homeassistant/number/control4_900_preset_level/config") == "",
      "and so are its LED color and dimmer control entities")
check(published("homeassistant/text/control4_300_top_on/config") is None, "an ordinary light's entities are left alone")
check(monitored("LIGHT") == [300], f"light discovery leaves the outlets out: {monitored('LIGHT')}")

# --- state ---
g.PublishOutletState(902)
g.PublishOutletState(903)
check(published("homeassistant/switch/control4_902/state") == "OFF"
      and published("homeassistant/switch/control4_903/state") == "ON",
      "the two outlets of one device publish their own states")
mock.vars[902][1000] = "1"
g.OnWatchedVariableChanged(902, 1000, "1")
check(published("homeassistant/switch/control4_902/state") == "ON", "a state change on one outlet is published for that outlet")

# --- commands ---
check(command("homeassistant/switch/control4_903/set", "OFF") == [(903, "OFF")], "command for Outlet 2 goes to its proxy")
check(command("homeassistant/switch/control4_849/set", "ON") == [(849, "ON")], "command for the stock V2 outlet goes to its proxy")
check(command("homeassistant/switch/control4_602/set", "ON") == [(602, "ON")], "command for the original outlet goes to its proxy")

# --- deleted outlets ---
mock.names[602] = None
g.CleanupDeletedDevices()
check(monitored("OUTLET") == [849, 902, 903], f"Cleanup Deleted Devices removes a deleted outlet: {monitored('OUTLET')}")
check(published("homeassistant/switch/control4_602/config") == "", "and removes it from Home Assistant")
check(monitored("LIGHT") == [300], "lights are untouched by the cleanup")

# nothing left to find: the stale entries go instead of staying listed
for pid in (849, 902, 903):
    mock.names[pid] = None
mock.byfile["outlet_nondimmable_light.c4i"] = lua.table()
mock.devices[900] = None
mock.byfile["outlet_light.c4i"] = lua.table()
g.DiscoverAllDevices("OUTLET")
check(monitored("OUTLET") == [], f"discovery with no outlets left clears deleted ones: {monitored('OUTLET')}")

print()
if failures:
    print(f"{len(failures)} FAILED")
    sys.exit(1)
print("all passed")
