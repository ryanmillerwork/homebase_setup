#!/usr/bin/env bash
set -euo pipefail

# wifi_provisioning uninstaller
#
# Removes:
# - /usr/local/bin/pi_provisiond.py
# - /etc/default/pi-provisiond (optional)
# - /etc/systemd/system/pi-provisiond.service
#
# And disables/stops pi-provisiond.

REMOVE_DEFAULT="${REMOVE_DEFAULT:-0}" # set to 1 to remove /etc/default/pi-provisiond

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo bash scripts/uninstall.sh" >&2
  exit 1
fi

echo "[pi-provisiond] Stopping/disabling service..."
systemctl disable --now pi-provisiond.service 2>/dev/null || true

echo "[pi-provisiond] Removing files..."
rm -f /usr/local/bin/pi_provisiond.py
rm -f /etc/systemd/system/pi-provisiond.service

if [[ "${REMOVE_DEFAULT}" == "1" ]]; then
  rm -f /etc/default/pi-provisiond
else
  echo "[pi-provisiond] Leaving /etc/default/pi-provisiond in place (set REMOVE_DEFAULT=1 to remove)."
fi

systemctl daemon-reload

echo "[pi-provisiond] Removing nftables setup tables (best effort)..."
nft delete table inet setup 2>/dev/null || true
nft delete table ip setupnat 2>/dev/null || true

echo "[pi-provisiond] Done."

