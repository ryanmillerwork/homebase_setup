# wifi_provisioning

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
- In most cases, your phone will pop a captive portal “Sign in to Wi‑Fi” page automatically and land on the setup UI.
- If not, browse to `http://10.42.0.1/` (if nginx proxy is installed) or `http://10.42.0.1:8080/` (daemon direct)
- Scan → select SSID → connect
- Tap “Open portal” to accept guest terms
- Wait for “internet_open=true” and the AP will shut down automatically

## Ports and “no-port” UX (nginx proxy)

Many Pi images already run **nginx on port 80**. This project is designed to work with that:

- **Daemon**: listens on `HTTP_PORT` (default **8080**)
- **Friendly URL**: nginx listens on `http://10.42.0.1/` (port 80) and proxies to `http://127.0.0.1:8080/`
- **Captive portal trigger**: setup-client HTTP is redirected to port 80, and Android/iOS captive probe URLs are handled

`scripts/install.sh` will install an nginx site config automatically if nginx is present.

## Configure

Edit `/etc/default/pi-provisiond` then restart:

```bash
sudo nano /etc/default/pi-provisiond
sudo systemctl restart pi-provisiond
```

Key settings:

- `SETUP_SSID`, `SETUP_PSK` (blank = open setup AP)
- `AP_IPV4_CIDR`, `HTTP_PORT`, `CAPTIVE_HTTP_PORT`
- `AP_FORCE_BAND`, `AP_FORCE_CHANNEL` (default forces the setup AP to **2.4GHz channel 6**)
- `WLAN_IF`, `AP_IF`
- `CHECK_URL`, `REQUIRED_SUCCESSES`
- Route preference during setup: `WIFI_METRIC`, `ETH_METRIC`
- Re-provisioning: `FORCE_SETUP`, `AUTO_TEARDOWN`, `PROVISIONED_MARKER`

## Re-provisioning / debugging

By default, once the device is provisioned it writes a marker file and won’t keep “setup mode” up forever.

- **Provisioned marker**: `/var/lib/pi-provisiond/provisioned` (configurable via `PROVISIONED_MARKER`)
- **Re-enter setup mode**:

```bash
sudo rm -f /var/lib/pi-provisiond/provisioned
sudo systemctl restart pi-provisiond
```

If you want the setup AP to stay up even when the device already has internet:

- Set `FORCE_SETUP=1` and `AUTO_TEARDOWN=0` in `/etc/default/pi-provisiond`, then restart.

### Easy “re-provision now” command

If you want to change the Wi‑Fi the device is on (even while it’s already connected), use the helper:

```bash
wifi_provision
```

When you’re done and want to go back to normal behavior:

```bash
wifi_provision_stop
```

This works by writing `/run/pi-provisiond.override` (an optional env override file loaded by the systemd unit).

## Priority / routing (Wi‑Fi vs Ethernet)

During setup mode, the daemon sets **route metrics** so Wi‑Fi is preferred:

- `WIFI_METRIC` (default 100)
- `ETH_METRIC` (default 600)

This ensures captive portal acceptance happens on the Wi‑Fi path even if Ethernet is plugged in.

## Why this works (the important bits)

- **Captive portals apply to the path you actually route through.** During setup we prefer `wlan0` via route metrics so the portal clearance happens on Wi‑Fi, even if Ethernet is plugged in.
- **Success criterion is automatable:** repeated `204` from the connectivity check endpoint.
- **Teardown is scoped:** setup firewall rules live in their own nftables tables so removal doesn’t clobber the rest of your ruleset.

See `docs/` for details and gotchas.

