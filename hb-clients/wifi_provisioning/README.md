# wifi_connection_helper

Production-shaped **setup mode** for a Raspberry Pi (or similar Linux device) to join a **guest Wi‑Fi with a captive portal**.

It runs a temporary **Setup AP** (so your phone can connect), provides a small **local web UI** to scan/connect, and then detects when the captive portal is cleared by polling:

`http://connectivitycheck.gstatic.com/generate_204` (expects **HTTP 204**).

Once “internet is open” (204 for a streak), it **tears down** the setup AP + firewall/NAT rules.

## What’s in this repo

- `scripts/pi_provisiond.py`: Python daemon (Flask UI + NetworkManager + nftables state machine)
- `systemd/pi-provisiond.service`: systemd unit
- `systemd/pi-provisiond.default`: `/etc/default/pi-provisiond` template
- `scripts/install.sh`: installs deps, copies files into place, enables service
- `scripts/uninstall.sh`: removes service and installed files
- `docs/`: background, design, and troubleshooting

## Quick start (on the Pi)

Clone/copy this repo onto the Pi, then:

```bash
sudo bash scripts/install.sh
sudo systemctl status pi-provisiond --no-pager
```

From your phone:

- Connect to the setup AP SSID (default **Pi-Setup**)
- Browse to `http://10.42.0.1:8080/` (the gateway IP is usually `10.42.0.1` when NetworkManager uses “shared” IPv4)
- Scan → select SSID → connect
- Tap “Open portal” to accept guest terms
- Wait for “internet_open=true” and the AP will shut down automatically

## Configure

Edit `/etc/default/pi-provisiond` then restart:

```bash
sudo nano /etc/default/pi-provisiond
sudo systemctl restart pi-provisiond
```

Key settings:

- `SETUP_SSID`, `SETUP_PSK`
- `HTTP_PORT`
- `WLAN_IF`, `AP_IF`
- `CHECK_URL`, `REQUIRED_SUCCESSES`
- Route preference during setup: `WIFI_METRIC`, `ETH_METRIC`

## Why this works (the important bits)

- **Captive portals apply to the path you actually route through.** During setup we prefer `wlan0` via route metrics so the portal clearance happens on Wi‑Fi, even if Ethernet is plugged in.
- **Success criterion is automatable:** repeated `204` from the connectivity check endpoint.
- **Teardown is scoped:** setup firewall rules live in their own nftables tables so removal doesn’t clobber the rest of your ruleset.

See `docs/` for details and gotchas.

