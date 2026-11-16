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
- The Lua outlet driver is recognized by its file name, so a renamed copy of it is not found.
- From version 4.6 an outlet's entity ID is based on the outlet's own ID, so outlets discovered by an earlier version get new entity IDs.

**Cleanup Deleted Devices** removes deleted lights, switches and outlets from the monitored lists and from Home Assistant.

## Known limitations

- **No TLS:** the driver uses plain MQTT, so credentials and messages are sent unencrypted. Use it only on a trusted network.
- **Password visibility:** the MQTT password is a plain text driver property, so it is visible in Composer.
- **Home Assistant only:** topics are fixed, and the discovery prefix must be the default `homeassistant`.
- **Thermostats:** only tested with an Aprilaire thermostat, and other brands may not work. Modes other than Off, Heat, Cool and Auto show as off in Home Assistant, and every thermostat is labelled "Aprilaire".
- **Contact sensors:** the driver has 20 contact sensor inputs (bindings 300-319). A sensor shows as unknown if the driver receives a command it doesn't recognize, and stays that way until the sensor next opens or closes.
- **No availability reporting:** if the bridge or controller goes offline, entities keep their last state instead of showing as unavailable.
- **Changing feature settings:** after changing **Enable LED Color Control** or **Enable Advanced Dimmer Controls**, run **Auto-Discover All Devices** and then **Publish Auto-Discovery**.
- **Media room playback state (experimental):** play and pause events are treated as toggles, which suits a Roku but can drift on other sources. The Roku automations in `homeassistant_custom_component` use one specific Roku and room, so they need editing for your system.

## Tests

The tests run `driver.lua` against a mock of the Control4 API:

```
pip install lupa
python tests/light_v2_test.py
python tests/outlet_test.py
python tests/bridge_test.py
```

## License

Copyright 2025 John Heit. Released under the [MIT License](LICENSE).
