#!/usr/bin/env bash
set -euo pipefail

# Simple power stress + monitoring helper for Raspberry Pi.
# - Generates CPU load (stress-ng if available, else openssl speed)
# - Generates IO load (dd to /tmp)
# - Samples throttling flags periodically
# - Logs recent kernel messages at the end for USB/power errors

usage() {
  cat <<'EOF'
Usage: sudo ./stress_power_test.sh [--seconds N] [--log PATH]

Defaults:
  --seconds 120
  --log /tmp/power_stress_YYYYmmdd_HHMMSS.log

Notes:
  - Run as root for vcgencmd and dmesg access.
  - For best results, keep all USB devices attached.
EOF
}

SECONDS_TOTAL=120
LOG_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --seconds)
      SECONDS_TOTAL="${2:-}"
      shift 2
      ;;
    --log)
      LOG_PATH="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$LOG_PATH" ]]; then
  LOG_PATH="/tmp/power_stress_$(date +%Y%m%d_%H%M%S).log"
fi

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "ERROR: run as root (sudo $0 ...)" >&2
  exit 1
fi

if ! command -v vcgencmd >/dev/null 2>&1; then
  echo "ERROR: vcgencmd not found (install rpi-tools or run on a Pi)." >&2
  exit 1
fi

log() {
  echo "[$(date +%F\ %T)] $*" | tee -a "$LOG_PATH"
}

log "Starting power stress test for ${SECONDS_TOTAL}s"
log "Logging to: ${LOG_PATH}"

CPU_WORKERS="$(nproc 2>/dev/null || echo 4)"
IO_TMP="/tmp/power_stress_io.tmp"

run_cpu_stress() {
  if command -v stress-ng >/dev/null 2>&1; then
    log "Using stress-ng with ${CPU_WORKERS} CPU workers"
    stress-ng --cpu "$CPU_WORKERS" --timeout "${SECONDS_TOTAL}s" --metrics-brief >/tmp/stress-ng.out 2>&1 &
    echo $!
    return 0
  fi

  if command -v openssl >/dev/null 2>&1; then
    log "Using openssl speed as CPU load"
    (timeout "${SECONDS_TOTAL}"s openssl speed -multi "$CPU_WORKERS" sha256 >/tmp/openssl-speed.out 2>&1) &
    echo $!
    return 0
  fi

  log "No stress-ng/openssl found; skipping CPU load"
  echo ""
}

run_io_stress() {
  log "Starting IO load (dd to ${IO_TMP})"
  (
    end=$((SECONDS + SECONDS_TOTAL))
    while [[ "$SECONDS" -lt "$end" ]]; do
      dd if=/dev/zero of="$IO_TMP" bs=4M count=256 oflag=direct,dsync status=none || true
      rm -f "$IO_TMP" || true
    done
  ) &
  echo $!
}

CPU_PID=""
IO_PID=""

cleanup() {
  log "Stopping stress processes..."
  [[ -n "${CPU_PID:-}" ]] && kill "$CPU_PID" >/dev/null 2>&1 || true
  [[ -n "${IO_PID:-}" ]] && kill "$IO_PID" >/dev/null 2>&1 || true
  rm -f "$IO_TMP" >/dev/null 2>&1 || true
}

trap 'log "Interrupted."; cleanup; exit 130' INT TERM

CPU_PID="$(run_cpu_stress)"
IO_PID="$(run_io_stress)"

log "Sampling throttling flags every second..."
end_time=$((SECONDS + SECONDS_TOTAL))
while [[ "$SECONDS" -lt "$end_time" ]]; do
  throttled="$(vcgencmd get_throttled 2>/dev/null | tr -d '\r')"
  log "throttled=${throttled#throttled=}"
  sleep 1
done

cleanup

log "Recent kernel messages (USB/power related):"
dmesg -T | grep -iE 'under-voltage|over-current|brown|usb|xhci|reset|error|timeout' | tail -n 200 | tee -a "$LOG_PATH" >/dev/null || true

log "Done."
