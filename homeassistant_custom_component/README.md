# MQTT Media Player Custom Component for Home Assistant

> **Experimental:** media room support is experimental. It works in basic use, but playback state tracking in particular is not fully reliable. Expect rough edges, and treat this component as unsupported compared with the rest of the bridge.

This custom component adds MQTT auto-discovery support for media_player entities in Home Assistant, enabling seamless integration with the Control4 to Home Assistant MQTT Bridge.

## Why This Component?

Home Assistant's built-in MQTT integration supports auto-discovery for many platforms (lights, switches, sensors, etc.) but **does not support media_player entities**. This custom component fills that gap by:

- Adding `mqtt_media_player` platform with full auto-discovery support
- Following Home Assistant's standard MQTT discovery patterns
- Enabling Control4 media rooms to appear automatically in Home Assistant
- Supporting volume control, mute, power, and state tracking

## Installation

### Method 1: Manual Installation

1. Copy the `mqtt_media_player` folder to your Home Assistant `custom_components` directory:
   ```
   <config_dir>/custom_components/mqtt_media_player/
   ```

2. Your directory structure should look like:
   ```
   config/
   ├── custom_components/
   │   └── mqtt_media_player/
   │       ├── __init__.py
   │       ├── manifest.json
   │       └── media_player.py
   └── configuration.yaml
   ```

3. Add the component to `configuration.yaml` (see Configuration below)

4. Restart Home Assistant

### Method 2: Using HACS (Future)

This component could be added to HACS for easier installation and updates.

## Configuration

Add this line to `configuration.yaml`. The component has no config flow, so Home Assistant won't load it without this entry:

```yaml
mqtt_media_player:
```

Entities are then created through MQTT auto-discovery.

Once installed:
1. Install and configure the Control4 to Home Assistant MQTT Bridge driver
2. Add a room ID to the "Media Room IDs" property in the driver
3. Run "Publish Auto-Discovery" action in Control4
4. The media player entity will automatically appear in Home Assistant

## MQTT Topics

The driver publishes to these topics:

### Discovery
- `homeassistant/media_player/control4_room_{id}/config` - Auto-discovery configuration

### State
- `homeassistant/media_player/control4_room_{id}/state` - Media player state (JSON)
- `homeassistant/media_player/control4_room_{id}/availability` - Publishes `online`. The driver never publishes `offline`, so entities don't become unavailable if the bridge goes down

### Commands
- `homeassistant/media_player/control4_room_{id}/set` - Control commands

## State Format

The state topic publishes JSON with the following fields:

```json
{
  "state": "off|idle|playing|paused",
  "volume_level": 0.5,
  "is_volume_muted": false
}
```

- `state`: Current playback state (off, idle, playing, paused)
- `volume_level`: Volume level from 0.0 to 1.0
- `is_volume_muted`: Boolean mute state

## Command Format

Commands are sent to the command topic in two formats:

### Simple String Commands
- `ON` - Turn on the media room
- `OFF` - Turn off the media room (ROOM_OFF command)
- `0.0` to `1.0` - Set volume level (0% to 100%)
- `true` - Mute audio
- `false` - Unmute audio

### JSON Commands (for transport controls)
```json
{"command": "media_play"}        // Play
{"command": "media_pause"}       // Pause
{"command": "media_stop"}        // Stop
{"command": "media_next_track"}  // Skip forward
{"command": "media_previous_track"} // Skip backward
{"command": "scan_forward"}      // Fast forward / Scan forward
{"command": "scan_reverse"}      // Rewind / Scan reverse
```

## Supported Features

- Turn On/Off
- Volume Control (0-100%)
- Mute/Unmute
- State Tracking (off/idle/playing/paused)
- Transport Controls (Play/Pause/Stop)
- Next/Previous Track (Skip)
- Scan Forward/Reverse (Fast Forward/Rewind)

## Troubleshooting

### Entity Not Appearing

1. **Verify custom component is installed**
   - Check `config/custom_components/mqtt_media_player/` exists
   - Check `mqtt_media_player:` is in `configuration.yaml`
   - Check Home Assistant logs for component loading errors

2. **Check MQTT topics**
   - Use MQTT Explorer to verify topics are being published
   - Verify discovery topic exists: `homeassistant/media_player/control4_room_{id}/config`

3. **Verify MQTT discovery is enabled**
   - In Home Assistant, go to Settings → Devices & Services → MQTT
   - Ensure "Enable discovery" is checked (usually enabled by default)

4. **Check Home Assistant logs**
   - Look for errors related to `mqtt_media_player`
   - Enable debug logging for more details:
     ```yaml
     logger:
       logs:
         custom_components.mqtt_media_player: debug
     ```

5. **Restart Home Assistant**
   - After installing the component
   - After publishing discovery messages

### Commands Not Working

1. **Check command topic subscription** in Home Assistant logs
2. **Verify Control4 driver** is receiving MQTT messages (check driver logs)
3. **Test with MQTT Explorer** by manually publishing to command topics

## Development

### Testing Discovery Messages

You can manually publish discovery messages using MQTT Explorer or mosquitto_pub:

```bash
mosquitto_pub -h YOUR_BROKER_IP -t "homeassistant/media_player/test/config" -m '{
  "name": "Test Media Player",
  "unique_id": "test_player",
  "state_topic": "homeassistant/media_player/test/state",
  "command_topic": "homeassistant/media_player/test/set",
  "platform": "mqtt_media_player"
}'
```

Then publish a state:

```bash
mosquitto_pub -h YOUR_BROKER_IP -t "homeassistant/media_player/test/state" -m '{
  "state": "idle",
  "volume_level": 0.5,
  "is_volume_muted": false
}'
```

## Credits

Created to enable full Control4 to Home Assistant integration via MQTT with auto-discovery support.

## License

MIT License. See the `LICENSE` file in the root of this repository.
