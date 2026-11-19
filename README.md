# Control4 to Home Assistant MQTT Bridge

A Control4 DriverWorks driver that connects a Control4 system to Home Assistant through an MQTT broker. Devices appear in Home Assistant through MQTT discovery and can be controlled from either side.

Updates are event-driven, with no polling. The driver holds an open MQTT connection to the broker over Control4's network stack (TCP), so commands from Home Assistant are pushed to it as they're sent. Control4 notifies the driver when a device changes, and the driver publishes the new state straight away. Its only recurring traffic is an MQTT keep-alive, and it reads device states once after connecting so Home Assistant starts out correct.

## Supported devices

- Lights and dimmers, including Light V2 color lights
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

## Dimmer settings and LED colors on Light V2 lights

With **Enable Advanced Dimmer Controls** and **Enable LED Color Control**, dimmers get number entities for their settings (preset, min/max on level, click and hold rates) and text entities for their top and bottom button LED colors.

A Light V2 light (Gen3 dimmers, Hue lights, the community Lua dimmers) keeps these in its proxy rather than in variables: only the Default On preset is a variable. From version 4.7 the driver asks the proxy for them instead:

- It shows only the settings and LEDs the light's driver declares in its capabilities (`click_rates`, `hold_rates`, `min_max`, `supports_default_on`, `has_leds` or `has_button_events`), with the click and hold rate ranges the light reports. The proxy itself reports every setting and three buttons for any light, so a Hue light gets just its preset and click rates.
- Changes from Home Assistant go to the proxy (`SET_PRESET_LEVEL`, `SET_HOLD_RATE_UP`, `SET_BUTTON_COLOR`, ...), and the settings are read back 3 seconds later, so a value the light refused is put back.
- Settings are read again on connect, when a light is discovered, and whenever its Default On preset changes. The proxy announces nothing when another setting is changed in Composer or on a touchscreen, so a light driver can announce it instead: from version 4.8 the driver watches a driver variable named `SETTINGS_CHANGED` on the light's own driver, and reads the settings again whenever it changes. The Hue Light driver has it from v0.4.6. For lights without it (Gen3 dimmers), such a change reaches Home Assistant at the next of the reads above.

V1 lights work as before.

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
- **Light V2 settings changed in Control4:** see [Future work](#future-work).

## Future work

**Light V2 settings changed in Control4 reach Home Assistant late.** A V1 light keeps its dimmer settings (click and hold rates, preset, min/max on level) in proxy variables, which the driver watches, so a change made in Composer or on a touchscreen is published at once. A Light V2 proxy keeps them internally and changes no variable (only the Default On preset, 1006, is one), so the driver only sees such a change at its next read: on connect, on discovery, when the preset changes, or 3 seconds after a change from Home Assistant. A light driver can announce the change with a `SETTINGS_CHANGED` variable (above), but only if we can change that driver.

| Light | Driver | Live updates |
|---|---|---|
| Hue Light | ours | yes, from v0.4.6 |
| Community gen2 Lua dimmers and switches | ours | not yet: add `SETTINGS_CHANGED` as the Hue Light driver does |
| Gen3 dimmers | Control4's | no: the driver can't be changed |

To investigate for Gen3, without polling:

- whether the Light V2 proxy sends any notification, event or Director message another driver can subscribe to when a setting changes (watch `OnDeviceEvent` and `OnWatchedVariableChanged` on the proxy and on the Gen3 driver device while changing a click rate in Composer);
- whether the Gen3 driver device has variables of its own that follow the settings (`C4:GetDeviceVariables` on the driver device, not the proxy);
- whether any variable the driver already watches changes alongside the setting, so it can be used as the trigger to read the proxy again.

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
