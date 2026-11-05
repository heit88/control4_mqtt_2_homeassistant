"""Support for MQTT media players with auto-discovery.

EXPERIMENTAL: this component is experimental and not fully reliable.
"""
import json
import logging
from typing import Any

import voluptuous as vol

from homeassistant.components import mqtt
from homeassistant.components.media_player import (
    MediaPlayerEntity,
    MediaPlayerEntityFeature,
    MediaPlayerState,
)
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import CONF_NAME, CONF_UNIQUE_ID
from homeassistant.core import HomeAssistant, callback
from homeassistant.helpers import config_validation as cv
from homeassistant.helpers.entity_platform import AddEntitiesCallback
from homeassistant.helpers.typing import ConfigType, DiscoveryInfoType

_LOGGER = logging.getLogger(__name__)

CONF_STATE_TOPIC = "state_topic"
CONF_COMMAND_TOPIC = "command_topic"
CONF_AVAILABILITY_TOPIC = "availability_topic"
CONF_DEVICE = "device"

PLATFORM_SCHEMA = vol.Schema(
    {
        vol.Required(CONF_NAME): cv.string,
        vol.Required(CONF_STATE_TOPIC): mqtt.valid_subscribe_topic,
        vol.Optional(CONF_COMMAND_TOPIC): mqtt.valid_publish_topic,
        vol.Optional(CONF_AVAILABILITY_TOPIC): mqtt.valid_subscribe_topic,
        vol.Optional(CONF_UNIQUE_ID): cv.string,
        vol.Optional(CONF_DEVICE): vol.Schema(
            {
                vol.Optional("identifiers"): vol.All(cv.ensure_list, [cv.string]),
                vol.Optional("name"): cv.string,
                vol.Optional("manufacturer"): cv.string,
                vol.Optional("model"): cv.string,
            }
        ),
    },
    extra=vol.ALLOW_EXTRA,
)


async def async_setup_platform(
    hass: HomeAssistant,
    config: ConfigType,
    async_add_entities: AddEntitiesCallback,
    discovery_info: DiscoveryInfoType | None = None,
) -> None:
    """Set up MQTT media player through configuration.yaml or discovery."""
    if discovery_info is not None:
        # MQTT Discovery
        config = PLATFORM_SCHEMA(discovery_info)

    async_add_entities([MqttMediaPlayer(hass, config)])


class MqttMediaPlayer(MediaPlayerEntity):
    """Representation of a MQTT-controlled media player."""

    def __init__(self, hass: HomeAssistant, config: dict) -> None:
        """Initialize the MQTT media player."""
        self.hass = hass
        self._attr_name = config[CONF_NAME]
        self._attr_unique_id = config.get(CONF_UNIQUE_ID)
        self._state_topic = config[CONF_STATE_TOPIC]
        self._command_topic = config.get(CONF_COMMAND_TOPIC)
        self._availability_topic = config.get(CONF_AVAILABILITY_TOPIC)

        # Device info for grouping in HA
        device_config = config.get(CONF_DEVICE, {})
        if device_config:
            self._attr_device_info = {
                "identifiers": set(device_config.get("identifiers", [])),
                "name": device_config.get("name"),
                "manufacturer": device_config.get("manufacturer"),
                "model": device_config.get("model"),
            }

        # State attributes
        self._attr_state = MediaPlayerState.OFF
        self._attr_volume_level = 0.0
        self._attr_is_volume_muted = False
        self._attr_available = False

        # Supported features
        self._attr_supported_features = (
            MediaPlayerEntityFeature.TURN_ON
            | MediaPlayerEntityFeature.TURN_OFF
            | MediaPlayerEntityFeature.VOLUME_SET
            | MediaPlayerEntityFeature.VOLUME_MUTE
            | MediaPlayerEntityFeature.PLAY
            | MediaPlayerEntityFeature.PAUSE
            | MediaPlayerEntityFeature.STOP
            | MediaPlayerEntityFeature.NEXT_TRACK
            | MediaPlayerEntityFeature.PREVIOUS_TRACK
            | MediaPlayerEntityFeature.SEEK
        )

    async def async_added_to_hass(self) -> None:
        """Subscribe to MQTT topics."""

        # Flag to track initialization
        self._initialized = False

        @callback
        def state_message_received(msg):
            """Handle new MQTT state messages."""
            try:
                payload = json.loads(msg.payload)

                # Update state
                state_str = payload.get("state", "off").lower()
                if state_str == "off":
                    self._attr_state = MediaPlayerState.OFF
                elif state_str in ["playing", "on"]:
                    self._attr_state = MediaPlayerState.PLAYING
                elif state_str == "paused":
                    self._attr_state = MediaPlayerState.PAUSED
                elif state_str == "idle":
                    self._attr_state = MediaPlayerState.IDLE
                else:
                    self._attr_state = MediaPlayerState.OFF

                # Update volume (0.0-1.0)
                if "volume_level" in payload:
                    self._attr_volume_level = float(payload["volume_level"])

                # Update mute
                if "is_volume_muted" in payload:
                    mute_val = payload["is_volume_muted"]
                    self._attr_is_volume_muted = (
                        mute_val if isinstance(mute_val, bool) else mute_val == "true"
                    )

                # If no availability topic, mark as available when we receive state
                if not self._availability_topic:
                    self._attr_available = True

                self.async_write_ha_state()
                _LOGGER.debug("State updated for %s: %s", self.name, state_str)

                # Mark as initialized after first state received
                self._initialized = True

            except json.JSONDecodeError:
                _LOGGER.error("Invalid JSON in state topic: %s", msg.payload)
            except Exception as e:
                _LOGGER.error("Error processing state message: %s", e)

        @callback
        def availability_message_received(msg):
            """Handle new MQTT availability messages."""
            try:
                # Handle both string and bytes payloads
                if isinstance(msg.payload, bytes):
                    payload = msg.payload.decode("utf-8")
                else:
                    payload = str(msg.payload)

                payload = payload.lower().strip()
                self._attr_available = payload == "online"
                self.async_write_ha_state()
                _LOGGER.info(
                    "Availability updated for %s: payload='%s' available=%s",
                    self.name,
                    payload,
                    self._attr_available,
                )
            except Exception as e:
                _LOGGER.error("Error processing availability message: %s", e)

        # Subscribe to availability topic first if configured
        if self._availability_topic:
            await mqtt.async_subscribe(
                self.hass, self._availability_topic, availability_message_received, 1
            )
            _LOGGER.info(
                "Subscribed to availability topic: %s", self._availability_topic
            )
        else:
            # No availability topic, default to available
            self._attr_available = True

        # Subscribe to state topic
        await mqtt.async_subscribe(
            self.hass, self._state_topic, state_message_received, 1
        )
        _LOGGER.info("Subscribed to state topic: %s", self._state_topic)

        _LOGGER.info(
            "Entity %s initialized - Current availability: %s",
            self.name,
            self._attr_available,
        )

        # Request initial state from Control4 on startup/reload
        # This ensures HA has the correct state even if restarted
        if self._command_topic:
            _LOGGER.info("Requesting initial state for %s", self.name)
            await mqtt.async_publish(
                self.hass,
                self._command_topic,
                json.dumps({"command": "request_state"}),
                0,
                False,
            )

    async def async_turn_on(self) -> None:
        """Turn the media player on."""
        if self._command_topic:
            await mqtt.async_publish(self.hass, self._command_topic, "ON", 0, False)

    async def async_turn_off(self) -> None:
        """Turn the media player off."""
        if self._command_topic:
            await mqtt.async_publish(self.hass, self._command_topic, "OFF", 0, False)

    async def async_set_volume_level(self, volume: float) -> None:
        """Set volume level, range 0..1."""
        if self._command_topic:
            await mqtt.async_publish(
                self.hass, self._command_topic, str(volume), 0, False
            )

    async def async_mute_volume(self, mute: bool) -> None:
        """Mute the volume."""
        if self._command_topic:
            payload = "true" if mute else "false"
            await mqtt.async_publish(self.hass, self._command_topic, payload, 0, False)

    async def async_media_play(self) -> None:
        """Send play command."""
        if self._command_topic:
            payload = json.dumps({"command": "media_play"})
            await mqtt.async_publish(self.hass, self._command_topic, payload, 0, False)

    async def async_media_pause(self) -> None:
        """Send pause command."""
        if self._command_topic:
            payload = json.dumps({"command": "media_pause"})
            await mqtt.async_publish(self.hass, self._command_topic, payload, 0, False)

    async def async_media_next_track(self) -> None:
        """Send next track command."""
        if self._command_topic:
            payload = json.dumps({"command": "media_next_track"})
            await mqtt.async_publish(self.hass, self._command_topic, payload, 0, False)

    async def async_media_previous_track(self) -> None:
        """Send previous track command."""
        if self._command_topic:
            payload = json.dumps({"command": "media_previous_track"})
            await mqtt.async_publish(self.hass, self._command_topic, payload, 0, False)

    async def async_media_stop(self) -> None:
        """Send stop command."""
        if self._command_topic:
            payload = json.dumps({"command": "media_stop"})
            await mqtt.async_publish(self.hass, self._command_topic, payload, 0, False)

    async def async_media_seek(self, position: float) -> None:
        """Send seek command (used for scan forward/reverse)."""
        if self._command_topic:
            # Use seek as fast forward/rewind
            # Positive position = scan forward, negative = scan reverse
            if position > 0:
                payload = json.dumps({"command": "scan_forward"})
            else:
                payload = json.dumps({"command": "scan_reverse"})
            await mqtt.async_publish(self.hass, self._command_topic, payload, 0, False)
