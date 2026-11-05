"""Mock test of the bridge's light handling: V1 dimmers, Light V2 color lights (Hue) and a Gen3
keypad dimmer (two proxies). Runs driver.lua in lupa with a mock C4 API.

    pip install lupa
    python tests/light_v2_test.py
"""
import json
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


def json_decode(_self, text):
    return lua.table_from(json.loads(text), recursive=True)


lua.execute(r'''
Properties = { ["Debug Mode"] = "Off", ["Enable Advanced Dimmer Controls"] = "Enabled", ["Enable LED Control"] = "Disabled" }
mock = { vars = {}, cmds = {}, published = {}, listeners = {}, proxies = {}, v2 = {}, names = {}, devices = {} }
C4 = setmetatable({}, { __index = function() return function() end end })
-- Like the controller: a missing variable returns no value (not nil)
function C4:GetDeviceVariable(id, var)
    local v = mock.vars[id] and mock.vars[id][var]
    if v == nil then return end
    return v
end
function C4:SetDeviceVariable(id, var, value)
    table.insert(mock.cmds, { id = id, cmd = "SETVAR", var = var, value = value })
    mock.vars[id][var] = tostring(value)
end
function C4:SendToDevice(id, cmd, params) table.insert(mock.cmds, { id = id, cmd = cmd, params = params or {} }) end
function C4:GetProxyDevicesById(id) return mock.proxies[id] end
function C4:GetDevicesByC4iName(name) if name == "light_v2.c4i" then return mock.v2 end return {} end
function C4:GetDeviceDisplayName(id) return mock.names[id] end
function C4:RegisterVariableListener(id, var) mock.listeners[id .. ":" .. var] = true end
function C4:UnregisterVariableListener(id, var) mock.listeners[id .. ":" .. var] = nil end
function C4:ColorCCTtoXY(k) return 0.25 + 500 / k, 0.40 end
-- Inverse of the above, and the mock's white curve: y = 0.40, or the two Bedroom points below
function C4:ColorXYtoCCT(x, y)
    if math.abs(x - 0.4526) < 1e-6 then return 2795 end
    return 500 / (x - 0.25)
end
local cctToXY = C4.ColorCCTtoXY
function C4:ColorCCTtoXY(k)
    if k == 2795 then return 0.4526, 0.4088 end
    return cctToXY(self, k)
end
function C4:SetTimer() return { Cancel = function() end } end
function C4:GetDevices() return mock.devices end
''')
lua.globals().C4.JsonDecode = json_decode

caps = ("<DynamicCapabilities><dimmer>True</dimmer><supports_color>{c}</supports_color>"
        "<supports_color_correlated_temperature>{t}</supports_color_correlated_temperature>"
        "<color_correlated_temperature_min>2000</color_correlated_temperature_min>"
        "<color_correlated_temperature_max>6500</color_correlated_temperature_max></DynamicCapabilities>")
lua.execute(r'''
local hueCaps, gen3Caps = ...
-- V1 dimmer: device 200, light.c4i proxy 201 (1004 preset, 1005 max, 1006 min)
mock.proxies[200] = 201
mock.names[200], mock.names[201] = "Kitchen", "Kitchen"
mock.vars[201] = { [1000] = "1", [1001] = "50", [1002] = "500", [1003] = "750", [1004] = "80", [1005] = "100", [1006] = "10" }
-- Hue light (Hue Light (Event Stream) driver): device 300, Light V2 proxy 301; only what it supports
mock.proxies[300] = "301"
mock.names[300], mock.names[301] = "Den Left Lamp", "Den Left Lamp"
mock.v2["301"] = { name = "Den Left Lamp" }
mock.vars[301] = { [1000] = "1", [1001] = "55", [1002] = "0", [1003] = "0", [1006] = "100",
    [1200] = "0.459858,0.410599,1", [1202] = "2700", [6661] = hueCaps }
-- Gen3 keypad dimmer: device 400 with Light V2 proxy 401 and keypad proxy 402
mock.proxies[400] = "402,401"
mock.names[400], mock.names[401] = "Hall", "Hall"
mock.v2["401"] = { name = "Hall" }
mock.vars[401] = { [1000] = "0", [1001] = "0", [1002] = "500", [1003] = "500", [1004] = "3000", [1005] = "3000",
    [1006] = "75", [1007] = "100", [1008] = "5", [6661] = gen3Caps }
''', caps.format(c="True", t="True"), caps.format(c="False", t="False"))

src = DRIVER.read_text(encoding="utf-8")
# Test hooks inside the chunk, where the driver's locals are visible
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


def cmds_since(n):
    return [mock.cmds[i] for i in range(n + 1, len(mock.cmds) + 1)]


def changed(proxy, var, value):
    """A proxy variable changes: the controller updates it, then calls the listener."""
    mock.vars[proxy][var] = value
    g.OnWatchedVariableChanged(proxy, var, value)


def command(topic, payload):
    n = len(mock.cmds)
    g.HandleMQTTCommand(topic, payload)
    return cmds_since(n)


# --- proxies ---
check(g.GetProxyID(200) == 201 and g.GetProxyID(300) == 301, "proxy IDs resolve (number or string from the controller)")
check(g.GetProxyID(400) == 401, "Gen3 keypad dimmer (two proxies): the Light V2 proxy, not the keypad")
check(g.IsLightV2(301) and g.IsLightV2(401) and not g.IsLightV2(201), "Light V2 proxies found by light_v2.c4i")

for dev in (200, 300, 400):
    g.AddLightToMonitor(dev)

# --- discovery ---
d = json.loads(published("homeassistant/light/control4_300/config"))
check(d["supported_color_modes"] == ["color_temp", "xy"] and d["color_temp_kelvin"] is True
      and d["min_kelvin"] == 2000 and d["max_kelvin"] == 6500,
      f"Hue light: color temperature (Kelvin, 2000-6500) and xy color ({d['supported_color_modes']})")
d = json.loads(published("homeassistant/light/control4_200/config"))
check(d["supported_color_modes"] == ["brightness"] and "color_temp_kelvin" not in d, "V1 dimmer: brightness only, as before")
d = json.loads(published("homeassistant/light/control4_400/config"))
check(d["supported_color_modes"] == ["brightness"], "Gen3 dimmer without color: brightness only")

# --- state ---
st = json.loads(published("homeassistant/light/control4_300/state"))
check(st == {"state": "ON", "brightness": 140, "color_mode": "color_temp", "color_temp": 2700},
      f"Hue state in color temperature mode: {st}")
changed(301, 1200, "0.3,0.32,0")
st = json.loads(published("homeassistant/light/control4_300/state"))
check(st["color_mode"] == "xy" and st["color"] == {"x": 0.3, "y": 0.32}, f"Hue color change from Control4 published as xy: {st}")
# the proxy reports a color temperature as full color (mode 0) when a fade ends: still color temperature
changed(301, 1200, "0.4526,0.4088,0")
st = json.loads(published("homeassistant/light/control4_300/state"))
check(st["color_mode"] == "color_temp" and st["color_temp"] == 2795,
      f"white-curve color reported as mode 0: still color temperature, Kelvin from the xy ({st})")
changed(301, 1200, "0.4526,0.4088")
changed(301, 1201, "1")
st = json.loads(published("homeassistant/light/control4_300/state"))
check(st["color_mode"] == "color_temp", "no mode in 1200 but Current Color Mode (1201) = 1: color temperature")
changed(301, 1201, "0")
changed(301, 1200, "0.3,0.32,0")
check(published("homeassistant/light/control4_200/state") == '{"state":"ON","brightness":127,"color_mode":"brightness"}',
      "V1 state payload unchanged")

# --- watched variables ---
L = mock.listeners
check(L["301:1200"] and L["301:1201"] and L["301:1202"] and L["301:6661"] and L["301:1006"] and L["301:1002"],
      "Hue light: color, capabilities, preset and click rates watched")
check(not L["301:1004"] and not L["301:1007"] and not L["301:1008"], "Hue light: no hold/min/max variables watched (it has none)")
check(all(L[f"401:{v}"] for v in (1002, 1003, 1004, 1005, 1006, 1007, 1008)), "Gen3: all its settings watched on the Light V2 proxy")
check(all(L[f"201:{v}"] for v in (1002, 1003, 1004, 1005, 1006)), "V1: settings watched as before")

# --- advanced control discovery ---
hue_cfg = {s: published(f"homeassistant/number/control4_300_{s}/config") for s in
           ("preset_level", "click_ramp_rate_up", "hold_ramp_rate_up", "min_on_level", "max_on_level")}
check(hue_cfg["preset_level"] and hue_cfg["click_ramp_rate_up"], "Hue light: Default On preset and click rate exposed")
check(hue_cfg["hold_ramp_rate_up"] == "" and hue_cfg["min_on_level"] == "" and hue_cfg["max_on_level"] == "",
      "Hue light: settings it doesn't have are removed from HA (empty config)")
check(published("homeassistant/number/control4_300_preset_level/state") == "100", "Hue preset state from variable 1006")
check(published("homeassistant/number/control4_400_hold_ramp_rate_up/state") == "3", "Gen3 hold rate state in seconds")
check(published("homeassistant/number/control4_400_min_on_level/state") == "5"
      and published("homeassistant/number/control4_400_max_on_level/state") == "100", "Gen3 min/max from 1008/1007")
check(published("homeassistant/number/control4_200_preset_level/state") == "80"
      and published("homeassistant/number/control4_200_min_on_level/state") == "10", "V1 preset/min from 1004/1006 as before")

# --- light commands ---
T = "homeassistant/light/control4_{}/set"
c = command(T.format(300), '{"state":"ON","color_temp":3000}')
check(len(c) == 1 and c[0].cmd == "SET_COLOR_TARGET" and c[0].id == 301
      and c[0].params.LIGHT_COLOR_TARGET_MODE == 1 and c[0].params.LIGHT_COLOR_TARGET_COLOR_MODE == 1
      and abs(c[0].params.LIGHT_COLOR_TARGET_X - (0.25 + 500 / 3000)) < 1e-9,
      "color temperature on a light that's on: SET_COLOR_TARGET (mode under both names), no ON")
mock.vars[301][1001] = "0"
c = command(T.format(300), '{"state":"ON","color_temp":3000}')
check([x.cmd for x in c] == ["SET_COLOR_TARGET", "ON"], "color temperature on a light that's off: color, then ON")
mock.vars[301][1001] = "55"
c = command(T.format(300), '{"state":"ON","color":{"x":0.2,"y":0.3},"brightness":255,"transition":2}')
check([x.cmd for x in c] == ["SET_COLOR_TARGET", "RAMP_TO_LEVEL"] and c[0].params.LIGHT_COLOR_TARGET_MODE == 0
      and c[0].params.LIGHT_COLOR_TARGET_X == 0.2 and c[0].params.LIGHT_COLOR_TARGET_RATE == 2000
      and c[1].params.LEVEL == 100 and c[1].params.TIME == 2000,
      "xy color + brightness + transition: full color target and a 2 s fade")
c = command(T.format(300), '{"state":"ON","color_temp":333}')
check(abs(c[0].params.LIGHT_COLOR_TARGET_X - (0.25 + 500 / (1e6 / 333))) < 1e-9, "a mireds value is converted to Kelvin")
c = command(T.format(300), '{"state":"OFF","transition":1.5}')
check(len(c) == 1 and c[0].cmd == "RAMP_TO_LEVEL" and c[0].params.LEVEL == 0 and c[0].params.TIME == 1500,
      "off with transition: fade to 0")
c = command(T.format(300), '{"state":"OFF"}')
check([x.cmd for x in c] == ["OFF"], "plain off: OFF")
c = command(T.format(200), '{"state":"ON","brightness":128,"transition":2}')
check(len(c) == 1 and c[0].cmd == "SET_LEVEL" and c[0].id == 201 and c[0].params.LEVEL == 50,
      "V1: SET_LEVEL as before (transition ignored)")
c = command(T.format(200), '{"state":"ON","color_temp":3000}')
check([x.cmd for x in c] == ["ON"], "V1: a color is ignored")
c = command(T.format(400), '{"state":"ON","brightness":255}')
check(len(c) == 1 and c[0].id == 401 and c[0].cmd == "SET_LEVEL", "Gen3: commands go to the Light V2 proxy")

# --- advanced control commands ---
N = "homeassistant/number/control4_{}_{}/set"
n = len(mock.published)
c = command(N.format(300, "preset_level"), "60")
check(len(c) == 1 and c[0].cmd == "SET_PRESET_LEVEL" and c[0].id == 301 and c[0].params.LEVEL == 60,
      "Hue Default On from HA: SET_PRESET_LEVEL to the proxy (not a write to 1004)")
check(not any(mock.published[i].topic.endswith("_preset_level/state") for i in range(n + 1, len(mock.published) + 1)),
      "Light V2: no optimistic state; the light's variable reports it")
changed(301, 1006, "60")
check(published("homeassistant/number/control4_300_preset_level/state") == "60", "Hue preset change reported back to HA")
c = command(N.format(400, "min_on_level"), "8")
check(c[0].cmd == "SET_MIN_ON_LEVEL" and c[0].id == 401 and c[0].params.LEVEL == 8, "Gen3 min on: SET_MIN_ON_LEVEL")
c = command(N.format(400, "max_on_level"), "90")
check(c[0].cmd == "SET_MAX_ON_LEVEL" and c[0].params.LEVEL == 90, "Gen3 max on: SET_MAX_ON_LEVEL")
c = command(N.format(400, "hold_ramp_rate_up"), "4")
check(c[0].cmd == "SET_HOLD_RATE_UP" and c[0].params.RATE == 4000, "Gen3 hold rate up: SET_HOLD_RATE_UP in ms")
c = command(N.format(400, "click_ramp_rate_up"), "5000")
check(not c, "Gen3: click rate above its hold rate (3 s from its variable) refused")
changed(401, 1004, "2500")
check(published("homeassistant/number/control4_400_hold_ramp_rate_up/state") == "2.5", "Gen3 hold rate change reported in seconds")
changed(401, 1008, "7")
check(published("homeassistant/number/control4_400_min_on_level/state") == "7", "Gen3 min (1008) change reported as min, not hold")
c = command(N.format(200, "preset_level"), "60")
check(len(c) == 1 and c[0].cmd == "SETVAR" and c[0].id == 201 and c[0].var == 1004 and c[0].value == 60,
      "V1 preset: proxy variable 1004 as before")
check(published("homeassistant/number/control4_200_preset_level/state") == "60", "V1: optimistic state as before")
c = command(N.format(200, "min_on_level"), "5")
check(c[0].var == 1006, "V1 min on: variable 1006 as before")
changed(201, 1004, "70")
check(published("homeassistant/number/control4_200_preset_level/state") == "70", "V1 1004 change reported as preset")

# --- capabilities change ---
n = len(mock.published)
changed(301, 6661, caps.format(c="False", t="True"))
d = json.loads(published("homeassistant/light/control4_300/config"))
check(d["supported_color_modes"] == ["color_temp"], "capabilities change (color temperature only): discovery republished")

print()
print(f"{len(failures)} failures" if failures else "all passed")
sys.exit(1 if failures else 0)
