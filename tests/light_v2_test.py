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
Properties = { ["Debug Mode"] = "Off", ["Enable Advanced Dimmer Controls"] = "Enabled", ["Enable LED Color Control"] = "Disabled" }
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
mock.timers = {}
function C4:SetTimer(ms, f)
    local t = { ms = ms, f = f }
    function t:Cancel() self.dead = true end
    table.insert(mock.timers, t)
    return t
end
-- Fire the pending one-shot timers of this length (the Light V2 read-back after a change)
function fireTimers(ms)
    local due = {}
    for i = #mock.timers, 1, -1 do
        local t = mock.timers[i]
        if t.ms == ms then table.insert(due, t); table.remove(mock.timers, i) end
    end
    for _, t in ipairs(due) do if not t.dead then t.f(t) end end
end
-- A Light V2 proxy keeps its settings to itself and answers GET_PROPERTIES / GET_SETUP with them,
-- as a Gen3 dimmer and the gen2 Lua dimmer do on the controller. mock.settings[proxy]: tag -> value,
-- mock.buttons[proxy]: button ID -> {on, off}, mock.setup[proxy]: extra GET_SETUP tags.
mock.settings, mock.buttons, mock.setup, mock.caps, mock.uiRequests = {}, {}, {}, {}, 0
function C4:SendUIRequest(id, cmd)
    mock.uiRequests = mock.uiRequests + 1
    local settings = mock.settings[id]
    if not settings then return nil end
    local parts = {}
    for _, tag in ipairs({"CLICK_RATE_UP", "CLICK_RATE_DOWN", "HOLD_RATE_UP", "HOLD_RATE_DOWN", "PRESET_LEVEL",
                          "MIN_ON_LEVEL", "MAX_ON_LEVEL", "COLD_START_LEVEL", "COLD_START_TIME"}) do
        if settings[tag] then table.insert(parts, "<" .. tag .. ">" .. settings[tag] .. "</" .. tag .. ">") end
    end
    local buttons = {}
    for bid = 0, 2 do
        local b = mock.buttons[id] and mock.buttons[id][bid]
        if b then
            table.insert(buttons, "<BUTTON_INFO><NAME>B" .. bid .. "</NAME><BUTTON_ID>" .. bid .. "</BUTTON_ID><ON_COLOR>" ..
                b.on .. "</ON_COLOR><OFF_COLOR>" .. b.off .. "</OFF_COLOR></BUTTON_INFO>")
        end
    end
    local body = "<ONLINE_CHANGED>True</ONLINE_CHANGED>" .. table.concat(parts) ..
        (#buttons > 0 and ("<BUTTON_LIST_INFO>" .. table.concat(buttons) .. "</BUTTON_LIST_INFO>") or "")
    if cmd == "GET_PROPERTIES" then return "<State>" .. body .. "<SceneMap/></State>" end
    if cmd == "GET_CAPABILITIES" then return mock.caps[id] end
    if cmd == "GET_SETUP" then return "<setup><dimmer>True</dimmer>" .. (mock.setup[id] or "") .. body .. "</setup>" end
end
-- A light that takes the proxy's setting commands (the light answers; the proxy then knows the value)
local SET_TAGS = { SET_CLICK_RATE_UP = "CLICK_RATE_UP", SET_CLICK_RATE_DOWN = "CLICK_RATE_DOWN",
    SET_HOLD_RATE_UP = "HOLD_RATE_UP", SET_HOLD_RATE_DOWN = "HOLD_RATE_DOWN", SET_PRESET_LEVEL = "PRESET_LEVEL",
    SET_MIN_ON_LEVEL = "MIN_ON_LEVEL", SET_MAX_ON_LEVEL = "MAX_ON_LEVEL" }
mock.refuses = {}
function lightTakes(c)
    local s = mock.settings[c.id]
    if not s or mock.refuses[c.id] then return end
    local tag = SET_TAGS[c.cmd]
    if tag then s[tag] = tostring(c.params.LEVEL or c.params.RATE) end
    if c.cmd == "SET_BUTTON_COLOR" then
        mock.buttons[c.id][c.params.BUTTON_ID] = { on = c.params.ON_COLOR, off = c.params.OFF_COLOR }
    end
end
function C4:GetDevices() return mock.devices end
-- A driver's own variables (C4:AddVariable), numbered from 1001 like the proxy's: by device ID
mock.driverVars = {}
function C4:GetDeviceVariables(id) return mock.driverVars[id] end
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
-- Hue Light driver v0.4.6: announces settings changes in its own variable 1001
mock.driverVars[300] = { ["1001"] = { name = "SETTINGS_CHANGED", value = "0" } }
mock.names[300], mock.names[301] = "Den Left Lamp", "Den Left Lamp"
mock.v2["301"] = { name = "Den Left Lamp" }
mock.vars[301] = { [1000] = "1", [1001] = "55", [1006] = "100",
    [1200] = "0.459858,0.410599,1", [1202] = "2700", [6661] = hueCaps }
-- Hue: the proxy reports every setting and three buttons anyway (as on the controller); the
-- capabilities its driver declares say it has click rates and Default On only
mock.settings[301] = { CLICK_RATE_UP = "250", CLICK_RATE_DOWN = "750", HOLD_RATE_UP = "5000", HOLD_RATE_DOWN = "5000",
    PRESET_LEVEL = "100", MIN_ON_LEVEL = "1", MAX_ON_LEVEL = "100", COLD_START_LEVEL = "0", COLD_START_TIME = "0" }
mock.buttons[301] = { [0] = { on = "0000ff", off = "000000" }, [1] = { on = "000000", off = "0000ff" },
    [2] = { on = "0000ff", off = "000000" } }
mock.caps[301] = "<capabilities><click_rates>True</click_rates><cold_start>False</cold_start><dimmer>True</dimmer>" ..
    "<has_button_events>False</has_button_events><has_leds>False</has_leds><hold_rates>False</hold_rates>" ..
    "<supports_default_on>True</supports_default_on></capabilities>"
-- Gen3 keypad dimmer: device 400 with Light V2 proxy 401 and keypad proxy 402
mock.proxies[400] = "402,401"
mock.names[400], mock.names[401] = "Hall", "Hall"
mock.v2["401"] = { name = "Hall" }
-- Variables as on the controller (Adaptive Phase Dimmer, 2026-11-17): no click/hold/min/max
mock.vars[401] = { [1000] = "0", [1001] = "0", [1006] = "75", [6661] = gen3Caps }
mock.settings[401] = { CLICK_RATE_UP = "500", CLICK_RATE_DOWN = "500", HOLD_RATE_UP = "3000", HOLD_RATE_DOWN = "3000",
    PRESET_LEVEL = "75", MIN_ON_LEVEL = "5", MAX_ON_LEVEL = "100", COLD_START_LEVEL = "0", COLD_START_TIME = "0" }
mock.buttons[401] = { [0] = { on = "0000ff", off = "000000" }, [1] = { on = "000000", off = "0000ff" },
    [2] = { on = "0000ff", off = "000000" } }
mock.setup[401] = "<CLICK_RATE_MIN>250</CLICK_RATE_MIN><CLICK_RATE_MAX>86400000</CLICK_RATE_MAX>" ..
    "<HOLD_RATE_MIN>1000</HOLD_RATE_MIN><HOLD_RATE_MAX>86400000</HOLD_RATE_MAX>"
-- Gen3 (its .c4i): min/max, click and hold rates, LEDs; no supports_default_on, yet it has 1006
mock.caps[401] = "<capabilities><dimmer>True</dimmer><min_max>True</min_max><click_rates>True</click_rates>" ..
    "<hold_rates>True</hold_rates><cold_start>True</cold_start><has_leds>True</has_leds></capabilities>"
-- Community Lua dimmer (gen2): device 500, Light V2 proxy 501; LEDs driven by the driver itself
-- (has_leds False) but it has buttons
mock.proxies[500] = "501"
mock.names[500], mock.names[501] = "Kids Bathroom", "Kids Bathroom"
mock.v2["501"] = { name = "Kids Bathroom" }
mock.vars[501] = { [1000] = "1", [1001] = "45", [1006] = "45", [6661] = gen3Caps }
mock.settings[501] = { CLICK_RATE_UP = "1000", CLICK_RATE_DOWN = "1000", HOLD_RATE_UP = "5000", HOLD_RATE_DOWN = "5000",
    PRESET_LEVEL = "45", MIN_ON_LEVEL = "1", MAX_ON_LEVEL = "100", COLD_START_LEVEL = "1", COLD_START_TIME = "1" }
mock.buttons[501] = { [0] = { on = "0d0015", off = "000000" }, [1] = { on = "000000", off = "0d0015" },
    [2] = { on = "0000ff", off = "000000" } }
mock.caps[501] = "<capabilities><dimmer>True</dimmer><min_max>True</min_max><click_rates>True</click_rates>" ..
    "<hold_rates>True</hold_rates><cold_start>True</cold_start><has_leds>False</has_leds>" ..
    "<has_button_events>True</has_button_events><supports_default_on>True</supports_default_on></capabilities>"
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
    """A proxy variable changes: the controller updates it, then calls the listener. Its state is
    published within that call (no timer is fired)."""
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

for dev in (200, 300, 400, 500):
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
check(L["301:1200"] and L["301:1201"] and L["301:1202"] and L["301:6661"] and L["301:1006"],
      "Hue light: color, capabilities and preset watched")
check(not any(L[f"301:{v}"] for v in (1002, 1003, 1004, 1005, 1007, 1008)), "Hue light: no made-up setting variables watched")
check(L["401:1006"] and not any(L[f"401:{v}"] for v in (1002, 1003, 1004, 1005, 1007, 1008)),
      "Gen3: only the preset (1006) watched; its other settings have no variables")
check(all(L[f"201:{v}"] for v in (1002, 1003, 1004, 1005, 1006)), "V1: settings watched as before")

# --- advanced control discovery ---
hue_cfg = {s: published(f"homeassistant/number/control4_300_{s}/config") for s in
           ("preset_level", "click_ramp_rate_up", "hold_ramp_rate_up", "min_on_level", "max_on_level")}
check(hue_cfg["preset_level"] and hue_cfg["click_ramp_rate_up"], "Hue light: Default On preset and click rate exposed")
check(hue_cfg["hold_ramp_rate_up"] == "" and hue_cfg["min_on_level"] == "" and hue_cfg["max_on_level"] == "",
      "Hue light: settings it does not have are removed from HA (empty config)")
check(published("homeassistant/number/control4_300_preset_level/state") == "100", "Hue preset state from the proxy")
check(published("homeassistant/number/control4_300_click_ramp_rate_up/state") == "250", "Hue click rate from the proxy")
gen2 = {s: published(f"homeassistant/number/control4_500_{s}/config") for s in
        ("preset_level", "click_ramp_rate_up", "hold_ramp_rate_up", "min_on_level", "max_on_level")}
check(all(gen2.values()), "Lua dimmer: every setting it declares exposed")
check(published("homeassistant/number/control4_400_preset_level/config"), "Gen3: preset exposed (has 1006, no supports_default_on)")
check(published("homeassistant/number/control4_400_hold_ramp_rate_up/state") == "3", "Gen3 hold rate state in seconds")
check(published("homeassistant/number/control4_400_min_on_level/state") == "5"
      and published("homeassistant/number/control4_400_max_on_level/state") == "100"
      and published("homeassistant/number/control4_400_click_ramp_rate_down/state") == "500",
      "Gen3 min/max and click rates from GET_PROPERTIES")
cfg = json.loads(published("homeassistant/number/control4_400_click_ramp_rate_up/config"))
check(cfg["min"] == 250 and cfg["max"] == 86400000, f"Gen3 click rate range from GET_SETUP ({cfg['min']}-{cfg['max']})")
cfg = json.loads(published("homeassistant/number/control4_400_hold_ramp_rate_up/config"))
check(cfg["min"] == 1 and cfg["max"] == 86400 and cfg["step"] == 0.1, f"Gen3 hold rate range in seconds ({cfg})")
cfg = json.loads(published("homeassistant/number/control4_200_click_ramp_rate_up/config"))
check(cfg["min"] == 0 and cfg["max"] == 5000, "V1 click rate range as before")
cfg = json.loads(published("homeassistant/number/control4_200_hold_ramp_rate_up/config"))
check(cfg["max"] == 10 and cfg["step"] == 1, "V1 hold rate range and step as before")
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


def confirm():
    """The light takes the commands sent, then the read-back timer fires."""
    for i in range(1, len(mock.cmds) + 1):
        g.lightTakes(mock.cmds[i])
    g.fireTimers(3000)


c = command(N.format(300, "preset_level"), "60")
check(len(c) == 1 and c[0].cmd == "SET_PRESET_LEVEL" and c[0].id == 301 and c[0].params.LEVEL == 60,
      "Hue Default On from HA: SET_PRESET_LEVEL to the proxy (not a write to 1004)")
check(published("homeassistant/number/control4_300_preset_level/state") == "60", "Light V2: new value shown at once")
c = command(N.format(400, "min_on_level"), "8")
check(c[0].cmd == "SET_MIN_ON_LEVEL" and c[0].id == 401 and c[0].params.LEVEL == 8, "Gen3 min on: SET_MIN_ON_LEVEL")
c = command(N.format(400, "max_on_level"), "90")
check(c[0].cmd == "SET_MAX_ON_LEVEL" and c[0].params.LEVEL == 90, "Gen3 max on: SET_MAX_ON_LEVEL")
c = command(N.format(400, "hold_ramp_rate_up"), "4.5")
check(c[0].cmd == "SET_HOLD_RATE_UP" and c[0].params.RATE == 4500, "Gen3 hold rate up 4.5 s: SET_HOLD_RATE_UP 4500 ms")
c = command(N.format(400, "hold_ramp_rate_down"), "20")
check(c and c[0].params.RATE == 20000, "Gen3 hold rate 20 s accepted (its range, not V1's 10 s)")
c = command(N.format(400, "click_ramp_rate_up"), "100")
check(not c, "Gen3 click rate below its 250 ms minimum refused")
confirm()
check(published("homeassistant/number/control4_400_min_on_level/state") == "8"
      and published("homeassistant/number/control4_400_hold_ramp_rate_up/state") == "4.5",
      "read back after the change: what the light took")
c = command(N.format(400, "click_ramp_rate_up"), "5000")
check(not c, "Gen3: click rate above its hold rate (4.5 s, read from the proxy) refused")
check(published("homeassistant/number/control4_400_click_ramp_rate_up/state") == "500", "refused click rate put back")
mock.refuses[401] = True
command(N.format(400, "preset_level"), "30")
check(published("homeassistant/number/control4_400_preset_level/state") == "30", "shown at once")
confirm()
check(published("homeassistant/number/control4_400_preset_level/state") == "75", "a setting the light refused is put back")
mock.refuses[401] = False
# a change made in Composer, then the preset (1006) changes: all settings read again
mock.settings[401]["HOLD_RATE_DOWN"] = "6000"
mock.settings[401]["PRESET_LEVEL"] = "50"
changed(401, 1006, "50")
check(published("homeassistant/number/control4_400_preset_level/state") == "50"
      and published("homeassistant/number/control4_400_hold_ramp_rate_down/state") == "6",
      "preset change (1006): every setting read again")
c = command(N.format(200, "preset_level"), "60")
check(len(c) == 1 and c[0].cmd == "SETVAR" and c[0].id == 201 and c[0].var == 1004 and c[0].value == 60,
      "V1 preset: proxy variable 1004 as before")
check(published("homeassistant/number/control4_200_preset_level/state") == "60", "V1: optimistic state as before")
c = command(N.format(200, "min_on_level"), "5")
check(c[0].var == 1006, "V1 min on: variable 1006 as before")
changed(201, 1004, "70")
check(published("homeassistant/number/control4_200_preset_level/state") == "70", "V1 1004 change reported as preset")
changed(201, 1006, "4")
check(published("homeassistant/number/control4_200_min_on_level/state") == "4", "V1 1006 change reported as min, not preset")

# --- settings changed in Control4 (Composer, touchscreen) ---
check(L["300:1001"] and not L["400:1001"], "Hue: its driver's SETTINGS_CHANGED watched; Gen3 driver has none")
mock.settings[301]["CLICK_RATE_UP"] = "1500"
n = len(mock.published)
g.OnWatchedVariableChanged(300, 1001, "1")
check(published("homeassistant/number/control4_300_click_ramp_rate_up/state") == "1500",
      "Hue click rate changed in Control4: read again and published")
check(published("homeassistant/light/control4_300/state") is None or
      not any(mock.published[i].topic == "homeassistant/light/control4_300/state" for i in range(n + 1, len(mock.published) + 1)),
      "SETTINGS_CHANGED (driver variable 1001) not taken for a level report (proxy variable 1001)")
g.UnsubscribeFromDevice(300, "LIGHT")
check(not L["300:1001"], "unsubscribed: SETTINGS_CHANGED no longer watched")
g.SubscribeToDevice(300, "LIGHT")

# --- LEDs ---
g.Properties["Enable LED Color Control"] = "Enabled"
for dev in (200, 300, 400, 500):
    g.PublishLEDDiscovery(dev, "LIGHT")
    g.PublishAllLEDStates(dev)
check(published("homeassistant/text/control4_500_top_on/config")
      and published("homeassistant/text/control4_500/top_on/state") == "0D0015",
      "Lua dimmer (has_leds False, has buttons): LEDs exposed")
check(published("homeassistant/text/control4_400_top_on/config")
      and published("homeassistant/text/control4_400/top_on/state") == "0000FF"
      and published("homeassistant/text/control4_400/bottom_off/state") == "0000FF"
      and published("homeassistant/text/control4_400/top_off/state") == "000000",
      "Gen3 LED colors from the proxy's BUTTON_INFO")
check(published("homeassistant/text/control4_300_top_on/config") == ""
      and published("homeassistant/text/control4_300/top_on/state") is None,
      "Hue light (reported buttons, but no LEDs or buttons declared): no LED entities")
check(published("homeassistant/text/control4_200_top_on/config")
      and published("homeassistant/text/control4_200/top_on/state") == "000000",
      "V1 LEDs as before (device variables)")
T2 = "homeassistant/text/control4_{}/{}/set"
c = command(T2.format(400, "bottom_on"), "FF8000")
check(len(c) == 1 and c[0].cmd == "SET_BUTTON_COLOR" and c[0].id == 401 and c[0].params.BUTTON_ID == 1
      and c[0].params.ON_COLOR == "ff8000" and c[0].params.OFF_COLOR == "0000ff",
      "Gen3 LED: SET_BUTTON_COLOR to the proxy, other color kept")
c = command(T2.format(400, "bottom_off"), "112233")
check(c[0].params.ON_COLOR == "ff8000" and c[0].params.OFF_COLOR == "112233", "a second change keeps the first")
check(published("homeassistant/text/control4_400/bottom_off/state") == "112233", "LED shown at once")
confirm()
check(published("homeassistant/text/control4_400/bottom_on/state") == "FF8000", "LED read back from the proxy")
c = command(T2.format(200, "top_on"), "00FF00")
check(len(c) == 1 and c[0].cmd == "SET_TOP_LED_ON" and c[0].id == 200, "V1 LED: SET_TOP_LED_ON to the device as before")

# --- capabilities change ---
n = len(mock.published)
changed(301, 6661, caps.format(c="False", t="True"))
d = json.loads(published("homeassistant/light/control4_300/config"))
check(d["supported_color_modes"] == ["color_temp"], "capabilities change (color temperature only): discovery republished")
n = len(mock.published)
changed(401, 6661, caps.format(c="False", t="False"))
check(not any(mock.published[i].topic == "homeassistant/light/control4_400/config" for i in range(n + 1, len(mock.published) + 1)),
      "capabilities reported again, color unchanged: discovery not republished")

# --- listeners at start-up, whatever the capabilities say then ---
check(all(L[f"401:{v}"] for v in (1200, 1201, 1202, 6661, 1006)),
      "Gen3 (no color now): color, capabilities and preset variables watched anyway")
check(not L["201:1200"] and not L["201:6661"], "V1 dimmer: no Light V2 variables watched")
# the gen2 Lua dimmer's driver gets SETTINGS_CHANGED after this driver started
check(not L["500:1005"], "gen2 dimmer without SETTINGS_CHANGED: nothing watched")
mock.driverVars[500] = lua.table_from({"1005": lua.table_from({"name": "SETTINGS_CHANGED", "value": "0"})})
changed(501, 6661, mock.vars[501][6661])
check(L["500:1005"], "capabilities reported: SETTINGS_CHANGED looked up again by name and watched")
g.OnDriverLateInit()
# the light's driver adds its variable after this driver has started
mock.driverVars[400] = lua.table_from({"1010": lua.table_from({"name": "SETTINGS_CHANGED", "value": "0"})})
check(not L["400:1010"], "start-up: not there yet")
g.fireTimers(45000)
check(L["400:1010"], "45 s after start-up: every light's SETTINGS_CHANGED looked up again")
mock.settings[401]["CLICK_RATE_DOWN"] = "900"
g.OnWatchedVariableChanged(400, 1010, "1")
check(published("homeassistant/number/control4_400_click_ramp_rate_down/state") == "900", "and it works")

# --- automatic discovery (connect, Home Assistant restart): cached settings only ---
def drain():
    """Fire the paced discovery steps and the connect timers until none are left."""
    for _ in range(40):
        for ms in (2000, 2500, 500):
            g.fireTimers(ms)


def published_since(n, topic):
    return [mock.published[i].msg for i in range(n + 1, len(mock.published) + 1) if mock.published[i].topic == topic]


drain()
g.Properties["Enable LED Color Control"] = "Enabled"
for dev in (300, 400, 500):
    g.RefreshLightV2Settings(g.GetProxyID(dev))  # cached, as after a manual run
g.gLightV2Settings[501] = None  # the gen2 dimmer: never read since start-up
cached_max = mock.settings[401]["MAX_ON_LEVEL"]
mock.settings[401]["MAX_ON_LEVEL"] = "95"  # changed on the light; the cache still has the old value
n, ui = len(mock.published), mock.uiRequests
g.OnMQTTConnected()
drain()
check(mock.uiRequests == ui, f"connect: states and discovery make no SendUIRequest calls ({mock.uiRequests - ui})")
check(published_since(n, "homeassistant/number/control4_400_preset_level/config")
      and published_since(n, "homeassistant/text/control4_400_top_on/config")
      and published_since(n, "homeassistant/number/control4_400_max_on_level/state")[-1] == cached_max != "95",
      "connect: setting and LED entities with cached settings republished, from the cache")
check(published_since(n, "homeassistant/light/control4_500/config") and published_since(n, "homeassistant/light/control4_500/state"),
      "connect: a light with no cached settings still gets its light config and state")
check(not published_since(n, "homeassistant/number/control4_500_preset_level/config")
      and not published_since(n, "homeassistant/text/control4_500_top_on/config"),
      "connect: its setting and LED entities are left as they are (not removed, not read)")
n, ui = len(mock.published), mock.uiRequests
g.HandleHomeAssistantStatus("online", False)
drain()
check(mock.uiRequests == ui and published_since(n, "homeassistant/light/control4_400/config"),
      "Home Assistant restart: discovery again, no SendUIRequest calls")
n, ui = len(mock.published), mock.uiRequests
g.PublishAllDiscovery()
drain()
check(mock.uiRequests > ui and published_since(n, "homeassistant/number/control4_500_preset_level/config")
      and published_since(n, "homeassistant/number/control4_400_max_on_level/state")[-1] == "95",
      "Publish Auto-Discovery action: lights read again as before")

print()
print(f"{len(failures)} failures" if failures else "all passed")
sys.exit(1 if failures else 0)
