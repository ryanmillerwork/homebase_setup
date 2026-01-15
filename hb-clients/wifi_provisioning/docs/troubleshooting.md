# Troubleshooting

## 1) The setup SSID doesn’t appear on my phone

- Confirm the daemon is running:
  - `sudo systemctl status pi-provisiond --no-pager`
  - `sudo journalctl -u pi-provisiond -n 100 --no-pager`
- Confirm the AP interface exists:
  - `iw dev` should show `ap0` (default).
- Confirm the AP connection is up:
  - `nmcli connection show --active`
  - You should see `SetupAP` (default `AP_CON_NAME`).

Common causes:

- **Single-radio limitations / band coupling**: The daemon tries to match the AP band/channel to the STA (`wlan0`). If the STA ends up on **5 GHz**, your AP can become 5 GHz too (your phone must support 5 GHz).
- **Regulatory domain**: If country/REGDOMAIN is unset, AP behavior can be flaky. Set the correct Wi‑Fi country for your image.

## 2) Phone can connect to Pi-Setup but the UI doesn’t load

- NetworkManager “shared” mode usually uses `10.42.0.1` as the gateway, but confirm:
  - `ip -4 addr show ap0`
- Then browse to:
  - `http://<AP_IP>:8080/` (default port `HTTP_PORT=8080`)

## 3) Captive portal never “clears”

This setup relies on getting **HTTP 204** from:

- `http://connectivitycheck.gstatic.com/generate_204`

Check it manually (must route via Wi‑Fi):

- `curl --interface wlan0 -s -o /dev/null -w "%{http_code}" http://connectivitycheck.gstatic.com/generate_204`

If Ethernet is plugged in, ensure Wi‑Fi is still preferred during setup:

- The daemon sets route metrics: `WIFI_METRIC` (default 100) and `ETH_METRIC` (default 600).
- Confirm:
  - `ip route`

## 4) nftables errors / no NAT

- Confirm nftables is present:
  - `nft --version`
- Confirm setup tables exist:
  - `sudo nft list tables`
  - Expect `table inet setup` and `table ip setupnat` while in setup mode.

If you already have a firewall, ensure it doesn’t block forwarding between `ap0` and `wlan0`.

