#!/usr/bin/env bash
set -euo pipefail

# Enter "re-provision" setup mode even if the device is already online.
#
# Usage:
#   sudo bash scripts/reprovision.sh start
#   sudo bash scripts/reprovision.sh stop
#
# start:
# - removes provisioned marker
# - writes /run/pi-provisiond.override to force setup mode
# - restarts pi-provisiond
#
# stop:
# - removes /run/pi-provisiond.override
# - restarts pi-provisiond (returns to normal behavior)

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo bash scripts/reprovision.sh <start|stop>" >&2
  exit 1
fi

cmd="${1:-}"

case "${cmd}" in
  start)
    rm -f /var/lib/pi-provisiond/provisioned || true
    cat >/run/pi-provisiond.override <<'EOF'
# Runtime overrides for re-provisioning (loaded by systemd unit)
FORCE_SETUP=1
SKIP_IF_PROVISIONED=0

# Don't immediately tear down the AP just because we are already online.
ARM_CHECK_ON_CONNECT=1

# Normal behavior after the user hits "Connect": teardown once 204-check succeeds.
AUTO_TEARDOWN=1

# Keep setup AP on 2.4GHz ch6 for phone compatibility.
AP_FORCE_BAND=bg
AP_FORCE_CHANNEL=6

# Ensure daemon stays on 8080; nginx (if present) can proxy :80 to it.
HTTP_PORT=8080
CAPTIVE_HTTP_PORT=80
EOF

    systemctl daemon-reload
    systemctl restart pi-provisiond
    echo "[pi-provisiond] Re-provision mode started."
    echo "  - Join the setup SSID and open: http://10.42.0.1/"
    echo "  - After you hit Connect, the internet-check will arm and teardown will happen once portal is cleared."
    ;;

  stop)
    rm -f /run/pi-provisiond.override || true
    systemctl daemon-reload
    systemctl restart pi-provisiond
    echo "[pi-provisiond] Re-provision mode stopped (override removed)."
    ;;

  *)
    echo "Usage: sudo bash scripts/reprovision.sh <start|stop>" >&2
    exit 2
    ;;
esac

