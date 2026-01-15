# Troubleshooting

## 1) The setup SSID doesn’t appear on my phone

- Confirm the daemon is running:
  - `sudo systemctl status pi-provisiond --no-pager`
  - `sudo journalctl -u pi-provisiond -n 100 --no-pager`
- Confirm the AP interface exists:
  - `iw dev` should show `ap0` (default).
- Confirm it is actually in **AP mode**:
  - `iw dev ap0 info` should show `type AP` (or `__ap`)
- Confirm the AP connection is up:
  - `nmcli connection show --active`
  - You should see `SetupAP` (default `AP_CON_NAME`).

Common causes:

- **Single-radio limitations / band coupling**: even if AP mode works, the AP may flap/disconnect when the device connects to the target Wi‑Fi. For a “phone stays connected” UX, use a second Wi‑Fi interface (USB) for the setup AP.
- **Regulatory domain**: If country/REGDOMAIN is unset, AP behavior can be flaky. Set the correct Wi‑Fi country for your image.
- **Driver can’t create AP virtual interface while STA is connected**: Some chipsets won’t form `ap0` in AP mode if `wlan0` is already associated. The daemon retries once by disconnecting/downing `wlan0`; if it still fails, you likely need a second Wi‑Fi interface (USB) (or accept a “no AP+STA concurrency” flow).

## 2) Phone can connect to Pi-Setup but the UI doesn’t load

- NetworkManager “shared” mode usually uses `10.42.0.1` as the gateway, but confirm:
  - `ip -4 addr show ap0`
- Then browse to one of:
  - `http://10.42.0.1/` (preferred if nginx proxy is installed)
  - `http://10.42.0.1:8080/` (daemon direct)

If you see **502 Bad Gateway** at `http://10.42.0.1/`, nginx is up but the daemon isn’t listening:

- Check daemon:
  - `sudo systemctl status pi-provisiond --no-pager -l`
  - `sudo journalctl -u pi-provisiond -n 120 --no-pager`
- Confirm ports:
  - `sudo ss -ltnp | egrep ':(80|8080)\\b' || true`

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

## 5) The setup SSID disappears right after it appears

This usually means the device is already online and setup mode is being torn down.

- Check if the device is already connected:
  - `nmcli -f NAME,TYPE,DEVICE,STATE connection show --active`
- Check for the provisioned marker:
  - `sudo ls -l /var/lib/pi-provisiond/provisioned || true`

To re-enter setup:

- `sudo rm -f /var/lib/pi-provisiond/provisioned`
- Optionally set `FORCE_SETUP=1` and `AUTO_TEARDOWN=0` in `/etc/default/pi-provisiond` for repeated testing.

If the device is already online and you want to re-provision without the AP immediately tearing down:

- `wifi_provision`

## 6) “Scan Networks” does nothing / errors

The UI now reports scan errors in-page. On the Pi you can also test:

- `curl -sS http://127.0.0.1:8080/scan`

If it returns `status=error`, the message is usually an `nmcli`/NetworkManager issue (Wi‑Fi blocked, interface name mismatch, etc.).

