"""MQTT Media Player custom component for Home Assistant.

EXPERIMENTAL: this component is experimental and not fully reliable.

Requires a `mqtt_media_player:` entry in configuration.yaml, as it has no config flow.
"""
import json
import logging

from homeassistant.components import mqtt
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant, callback
from homeassistant.helpers.discovery import async_load_platform

_LOGGER = logging.getLogger(__name__)

DOMAIN = "mqtt_media_player"
DISCOVERY_PREFIX = "homeassistant"


async def async_setup(hass: HomeAssistant, config: dict) -> bool:
    """Set up the MQTT Media Player component."""

    @callback
    async def async_discover(msg):
        """Process discovery message."""
        try:
            # Parse JSON payload from MQTT message
            payload_str = msg.payload
            if isinstance(payload_str, bytes):
                payload_str = payload_str.decode("utf-8")

            if not payload_str:
                _LOGGER.debug("Empty discovery payload, ignoring")
                return

            discovery_data = json.loads(payload_str)

            _LOGGER.info("MQTT Media Player discovery received: %s", discovery_data.get("name", "unknown"))
            _LOGGER.debug("Full discovery data: %s", discovery_data)

            # Load the media_player platform with the discovery info
            await async_load_platform(
                hass,
                "media_player",
                DOMAIN,
                discovery_data,
                config,
            )
        except json.JSONDecodeError as e:
            _LOGGER.error("Failed to parse discovery JSON: %s", e)
        except Exception as e:
            _LOGGER.error("Error processing discovery message: %s", e)

    # Subscribe to MQTT discovery topic for media_player
    await mqtt.async_subscribe(
        hass,
        f"{DISCOVERY_PREFIX}/media_player/+/config",
        async_discover,
        0,
    )

    _LOGGER.info("MQTT Media Player component initialized and listening for discovery")
    return True


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    """Set up MQTT Media Player from a config entry."""
    return True
