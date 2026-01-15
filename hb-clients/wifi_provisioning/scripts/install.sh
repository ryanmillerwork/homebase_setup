#!/usr/bin/env bash
set -euo pipefail

# wifi_provisioning installer
#
# Installs:
# - /usr/local/bin/pi_provisiond.py
# - /etc/default/pi-provisiond
# - /etc/systemd/system/pi-provisiond.service
#
# Then enables + starts NetworkManager (required) and the pi-provisiond service.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo bash scripts/install.sh" >&2
  exit 1
fi

echo "[pi-provisiond] Installing OS dependencies..."

if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    network-manager \
    nftables \
    python3 \
    python3-flask \
    iw \
    curl
else
  echo "Unsupported package manager. Install these packages manually:" >&2
  echo "  - NetworkManager (nmcli)" >&2
  echo "  - nftables (nft)" >&2
  echo "  - python3 + python3-flask" >&2
  echo "  - iw, curl" >&2
  exit 2
fi

echo "[pi-provisiond] Copying files into place..."

install -D -m 0755 "${ROOT_DIR}/scripts/pi_provisiond.py" /usr/local/bin/pi_provisiond.py

if [[ -f /etc/default/pi-provisiond ]]; then
  echo "[pi-provisiond] /etc/default/pi-provisiond already exists; leaving it in place."
else
  install -D -m 0644 "${ROOT_DIR}/systemd/pi-provisiond.default" /etc/default/pi-provisiond
fi

install -D -m 0644 "${ROOT_DIR}/systemd/pi-provisiond.service" /etc/systemd/system/pi-provisiond.service

mkdir -p /var/lib/pi-provisiond
chmod 0755 /var/lib/pi-provisiond

echo "[pi-provisiond] Enabling services..."
systemctl daemon-reload
systemctl enable --now NetworkManager.service || true
systemctl enable --now pi-provisiond.service

# Optional: nginx captive portal proxy on the AP gateway IP.
if command -v nginx >/dev/null 2>&1 && [[ -d /etc/nginx ]]; then
  echo "[pi-provisiond] nginx detected; installing captive-portal proxy config (binds 10.42.0.1:80)..."
  install -D -m 0644 "${ROOT_DIR}/nginx/pi-provisiond-ap.conf" /etc/nginx/sites-available/pi-provisiond-ap.conf
  ln -sf /etc/nginx/sites-available/pi-provisiond-ap.conf /etc/nginx/sites-enabled/pi-provisiond-ap.conf
  nginx -t
  systemctl restart nginx || true
else
  echo "[pi-provisiond] nginx not detected; setup UI will be at http://<ap-gateway>:8080/"
fi

echo
echo "[pi-provisiond] Installed."
echo "  - Check status: sudo systemctl status pi-provisiond --no-pager"
echo "  - Follow logs:  sudo journalctl -u pi-provisiond -f"
echo "  - Configure:    sudo nano /etc/default/pi-provisiond && sudo systemctl restart pi-provisiond"

