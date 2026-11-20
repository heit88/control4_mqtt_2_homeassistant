# Control4 to Home Assistant MQTT Bridge

A Control4 DriverWorks driver that connects a Control4 system to Home Assistant through an MQTT broker. Devices appear in Home Assistant through MQTT discovery and can be controlled from either side.

Updates are event-driven, with no polling. The driver holds an open MQTT connection to the broker over Control4's network stack (TCP), so commands from Home Assistant are pushed to it as they're sent. Control4 notifies the driver when a device changes, and the driver publishes the new state straight away. Its only recurring traffic is an MQTT keep-alive, and it reads device states once after connecting so Home Assistant starts out correct.

## Supported devices

- Lights and dimmers: V1 (`light.c4i`) and Light V2 (`light_v2.c4i`) proxies, including Gen3 dimmers, switches and keypad dimmers, and Light V2 color lights (see [Light V2 and Gen3 lights](#light-v2-and-gen3-lights))
- Switches
- Wireless outlet switches (see [Outlets](#outlets))
- Thermostats
- Contact sensors
- Media rooms (**experimental**, see [the component README](homeassistant_custom_component/README.md))

## Setup

1. Add `mqtt_v2.c4z` to your project in Composer.
2. Set **MQTT Broker IP**, **MQTT Broker Port**, and **MQTT Username** and **MQTT Password** if your broker uses them.
3. If some loads should appear as switches rather than lights, list their device IDs in **Switch Device IDs**.
4. For contact sensors, bind each one to a Contact Sensor Input in Composer and fill in **Contact Sensor Binding Map**.
5. Run these actions in order: **Connect to MQTT Broker**, **Auto-Discover All Devices**, **Publish Auto-Discovery**.

Home Assistant needs its MQTT integration connected to the same broker.

## Outlets

Outlets appear in Home Assistant as switches. **Auto-Discover All Devices** finds them by driver, across three generations of outlet driver:

| Outlet driver | Driver file it is found by |
|---|---|
| Original Wireless Outlet Switch | `outlet_light.c4i` |
| Stock Wireless Outlet Switch V2 (non-dimmable light) | `outlet_nondimmable_light.c4i` |
| Community Lua outlet driver for the LOZ-5S1 | `outlet_switch_loz5s1_lua.c4z` |

- Each outlet is its own entity, so a two-outlet device gives two switches.
- Outlets are kept out of the lights list. A stock V2 outlet that an earlier version published as a light becomes a switch on the next discovery, and its old light entity is removed.
- Dimmable outlet lights (`outlet_dimmable_light.c4i`) stay in the lights list.
- The Lua outlet driver is recognized by its file name: from version 4.9 any file name starting `outlet_switch_loz5s1` (other builds of it) is found too.
- From version 4.6 an outlet's entity ID is based on the outlet's own ID, so outlets discovered by an earlier version get new entity IDs.

**Cleanup Deleted Devices** removes deleted lights, switches and outlets from the monitored lists and from Home Assistant.

## Light V2 and Gen3 lights

Gen3 dimmers, switches and keypad dimmers use Control4's Light V2 proxy (`light_v2.c4i`), as do the Hue Light driver, the community gen2 Lua dimmers and switches, and the WLED driver. **Auto-Discover All Devices** finds them alongside V1 lights, with nothing extra to set up.

- **Proxy selection:** a device can have more than one proxy. A Gen3 keypad dimmer has a light proxy and a keypad proxy, and the driver uses the Light V2 one. State is read from that proxy, and commands are sent to it.
- **On, off and brightness:** level and on/off state come from the same proxy variables as on V1 lights. Commands from Home Assistant are sent straight to the proxy, with no delay or batching:

  | Home Assistant command | Sent to the proxy |
  |---|---|
  | Turn on, no brightness | `ON` (the light goes to its Default On level) |
  | Brightness | `SET_LEVEL` |
  | Brightness with a transition | `RAMP_TO_LEVEL` with `TIME` in ms |
  | Turn off | `OFF` |
  | Turn off with a transition | `RAMP_TO_LEVEL` to 0 |

  The ramp time is Home Assistant's `transition` in seconds, converted to ms. V1 lights ignore `transition`.
- **Dimmer or switch:** a light with a level is published as a dimmer (`brightness`), and one with only an on/off state as `onoff`. A Gen3 switch shows as a light that is on or off. List its device ID in **Switch Device IDs** to make it a Home Assistant switch instead.
- **Color:** a light is published as a color light only if its proxy's capabilities (variable 6661) declare it. With color temperature it gets `color_temp`, in Kelvin, limited to the light's own range. With full color it gets `xy`. Gen3 dimmers declare neither, so they stay plain dimmers.
  - The current color is read from variables 1200, 1201 and 1202.
  - A color from Home Assistant goes to the proxy as `SET_COLOR_TARGET`, using the transition as its rate.
  - Changing the color of a light that is on doesn't send `ON`, so the light doesn't jump to its Default On level.
  - If a light only reports its capabilities after it is discovered, its Home Assistant entity is published again with them.
- **Dimmer settings and LEDs:** see the next section. A Gen3 dimmer's settings and top and bottom LED colors are read from the proxy. This was confirmed on a Gen3 dimmer on OS 3.4.3.
- **Settings changed in Control4:** brightness, state and color changes made in Control4 reach Home Assistant at once. From version 4.11 dimmer settings changed in Composer or on a touchscreen reach it at once too (see the next section).

## Dimmer settings and LED colors on Light V2 lights

With **Enable Advanced Dimmer Controls** and **Enable LED Color Control**, dimmers get number entities for their settings (preset, min/max on level, click and hold rates) and text entities for their top and bottom button LED colors.

A Light V2 light (Gen3 dimmers, Hue lights, the community Lua dimmers) keeps these in its proxy rather than in variables: only the Default On preset is a variable. From version 4.7 the driver asks the proxy for them instead:

- It shows only the settings and LEDs the light's driver declares in its capabilities (`click_rates`, `hold_rates`, `min_max`, `supports_default_on`, `has_leds` or `has_button_events`), with the click and hold rate ranges the light reports. The proxy itself reports every setting and three buttons for any light, so a Hue light gets just its preset and click rates.
- Changes from Home Assistant go to the proxy (`SET_PRESET_LEVEL`, `SET_HOLD_RATE_UP`, `SET_BUTTON_COLOR`, ...), and the settings are read back 3 seconds later, so a value the light refused is put back.
- Settings are read again on connect, when a light is discovered, and whenever its Default On preset changes. The proxy announces nothing when another setting is changed in Composer or on a touchscreen, so a light driver can announce it instead: from version 4.8 the driver watches a driver variable named `SETTINGS_CHANGED` on the light's own driver, and reads the settings again whenever it changes. The Hue Light driver has it from v0.4.6, and the community gen2 Lua dimmers and switches from v20. For lights without it (Gen3 dimmers), see the next point.
- From version 4.11 the driver also watches the `OnDataToUI` system event for each Light V2 light's device and proxy. The controller raises it when a setting is changed in Composer or on a touchscreen, with the new value (for example `<HOLD_RATE_UP>5100</HOLD_RATE_UP>` from the proxy, or `<AUTO_OFF_TIME>30</AUTO_OFF_TIME>` from a Gen3 dimmer's device), so the change is published at once with no read and no polling. This was confirmed on a Gen3 adaptive dimmer. Only settings the light was found to have are taken, and LED color changes made in Composer are not covered yet.
- V1 dimmers have no variable for their hold rates, so before 4.11 a hold rate was shown only once set from Home Assistant. Their device reports them in `OnDataToUI` too (`<hold_ramp_rate_up>3000</hold_ramp_rate_up>`, in ms), so from 4.11 a hold rate changed in Composer is shown. On a change the V1 driver sends its whole state several times, with old and new values interleaved, so the last value is published 1 second after the burst. A hold rate nobody has changed since the bridge started is still not shown.

V1 lights work as before.

## Gen3 auto off, keypad mode and energy

From version 4.11. A Gen3 dimmer's driver device (not its Light V2 proxy) answers `GET_PROPERTIES` with settings the proxy doesn't have, and keeps power and energy in variables of its own. This was confirmed on a Gen3 adaptive dimmer on 2026-11-19.

- **Auto Off Time** (with **Enable Advanced Dimmer Controls**): a number entity in seconds (0 to 65535, the dimmer's limit), 0 = auto off disabled. It is read from the device's `AUTO_OFF_TIME`, set with `SET_AUTO_OFF` (`TIME` in whole seconds) sent to the Light V2 proxy, and read back 3 seconds later like the other settings. It is shown only for lights whose device reports it.
- **Rocker As Keypad** (with **Enable Advanced Dimmer Controls**): a read-only binary sensor, from the device's `ROCKER_AS_KEYPAD`. No command that changes it was found (`SET_ROCKER_AS_KEYPAD` and similar were tried on the device and the proxy), so change it in Composer.
- Both are read whenever the dimmer's other settings are, and a change made in Composer reaches Home Assistant at once (`OnDataToUI`, above).
- **Power, Energy, Energy Today:** sensors for any monitored light or switch whose driver has variables named `CURRENT_POWER` (W), `ENERGY_USED` and `ENERGY_USED_TODAY` (Wh). They are found by name and published as they change. Power is a `measurement`, and both energy sensors are `total_increasing`, so they can be added to Home Assistant's Energy dashboard (Energy Today resets daily, which `total_increasing` allows). These don't depend on any driver property.
- "Turn on to previous level" is not exposed. It is not in `GET_PROPERTIES`, and it can't be followed with `OnDataToUI`: the device sometimes sends it (`PREVIOUS_ON_LEVEL_ENABLED`) in a burst with its firmware version and other status, but the value was the one from before the change, and toggling it again raised no event at all. No command to change it is known.

## Availability and Home Assistant restarts

From version 4.9:

- The driver connects with an MQTT Will: if its connection to the broker is lost (controller off, network down), the broker publishes `offline` (retained) to `control4/bridge/status`. The driver publishes `online` there when it connects, and `offline` when it is removed or the **Disconnect** action is used. Every entity's discovery config has `availability_topic: control4/bridge/status`, so all of them show as unavailable while the bridge is offline. Media rooms use the same topic (the `mqtt_media_player` component reads one availability topic).
- A connection that goes silent is noticed: if nothing arrives from the broker for 90 seconds (1.5 times the 60 second keep-alive; the broker answers a ping every 45 seconds), the driver reconnects. A lost connection is retried after 2 seconds, doubling to 60 seconds.
- Discovery is sent again, device by device, after every connect and whenever Home Assistant announces it has started (`online` on `homeassistant/status`), followed by every state. Media room configs are only sent by **Publish Auto-Discovery** (the component would add each one again); run it once after updating so media rooms get the new availability topic.
- Commands are taken through two wildcard subscriptions (`homeassistant/+/+/set`, `homeassistant/+/+/+/set`), so a device added later is controllable at once. A retained message on a `/set` topic (an old command left on the broker) is ignored and logged once.
- Every state change is published at once, with no delay or batching. A state identical to the one last published for that entity is not sent again.

From version 4.10:

- A monitored device (light, switch, outlet, thermostat, media room or contact sensor) that is deleted from the Control4 project is removed from Home Assistant automatically, as **Cleanup Deleted Devices** would: its entities (including LED color and dimmer setting entities) get empty retained configs, its listeners are dropped, and it leaves the monitored list (a contact sensor also leaves the **Contact Sensor Binding Map**). The driver watches the `OnItemRemoved` system event; 3 seconds after the last such event it checks every monitored device against the project's device list, and removes one only if it is still missing 5 seconds later (a driver being updated keeps its ID and comes back). Nothing is removed if the device list can't be read, or if more than half of the monitored devices (and more than one) seem gone at once; run **Cleanup Deleted Devices** then. A device deleted while the broker is unreachable is removed from Home Assistant when the bridge connects again.
- `OnProjectChanged` is deliberately not watched (it fires on almost every Composer edit). If the event doesn't fire, **Cleanup Deleted Devices** and the existing rule for lights (removed after 3 failed reads at least a minute apart) still apply.
- The first system event after the driver loads is written to the log in raw form even with Debug Mode off (every one with Debug Mode on), as `System event (raw): ...`.

## Known limitations

- **No TLS:** the driver uses plain MQTT, so credentials and messages are sent unencrypted. Use it only on a trusted network.
- **Password visibility:** the MQTT password is a plain text driver property, so it is visible in Composer.
- **Home Assistant only:** topics are fixed, and the discovery prefix must be the default `homeassistant`.
- **Thermostats:** only tested with an Aprilaire thermostat, and other brands may not work. Modes other than Off, Heat, Cool and Auto show as off in Home Assistant, and every thermostat is labelled "Aprilaire".
- **Contact sensors:** the driver has 20 contact sensor inputs (bindings 300-319). A sensor shows as unknown if the driver receives a command it doesn't recognize, and stays that way until the sensor next opens or closes.
- **Changing feature settings:** after changing **Enable LED Color Control** or **Enable Advanced Dimmer Controls**, run **Auto-Discover All Devices** and then **Publish Auto-Discovery**.
- **Media room playback state (experimental):** play and pause events are treated as toggles, which suits a Roku but can drift on other sources. The Roku automations in `homeassistant_custom_component` use one specific Roku and room, so they need editing for your system.
- **Light V2 LED colors changed in Control4:** see [Future work](#future-work).

## Future work

**Light V2 LED colors changed in Control4 may reach Home Assistant late.** Dimmer settings changed in Composer or on a touchscreen are published at once (`OnDataToUI`, from version 4.11, and `SETTINGS_CHANGED` for the Hue and community Lua drivers). Whether a button LED color change raises `OnDataToUI`, and in what form, is not known yet. Until then such a change is seen at the next read: on connect, on discovery, when the preset changes, or 3 seconds after a change from Home Assistant.

## Tests

The tests run `driver.lua` against a mock of the Control4 API:

```
pip install lupa
python tests/light_v2_test.py
python tests/outlet_test.py
python tests/bridge_test.py
```

The tests run on whatever Lua `lupa` ships (5.4 or 5.5), which is stricter than the controller's Lua 5.1 in places (`%d` with a fractional number is an error), so they also catch code that would break on a newer Lua.

## License

Copyright 2025 John Heit. Released under the [MIT License](LICENSE).
