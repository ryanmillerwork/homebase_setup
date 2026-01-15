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

install -D -m 0644 "${ROOT_DIR}/systemd/pi-provisiond.default" /etc/default/pi-provisiond

# Ensure required defaults are present/updated (idempotent-ish)
ensure_kv() {
  local key="$1"
  local val="$2"
  if grep -qE "^${key}=" /etc/default/pi-provisiond; then
    sed -i -E "s|^${key}=.*|${key}=${val}|" /etc/default/pi-provisiond
  else
    echo "${key}=${val}" >>/etc/default/pi-provisiond
  fi
}

# Always force the setup AP to 2.4GHz channel 6 (per project choice).
ensure_kv "AP_FORCE_BAND" "bg"
ensure_kv "AP_FORCE_CHANNEL" "6"

# If nginx is present (common on Pi images), keep daemon on :8080 and let nginx own :80.
if command -v nginx >/dev/null 2>&1; then
  ensure_kv "HTTP_PORT" "8080"
  ensure_kv "CAPTIVE_HTTP_PORT" "80"
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

