#!/usr/bin/env bash
set -euo pipefail

# Provision a Raspberry Pi OS Trixie Lite system to boot into stim2 in kiosk mode.

log() {
  echo "$@" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run as root (e.g. sudo $0)"
  fi
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

read_os_codename() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "${VERSION_CODENAME:-}"
  else
    echo ""
  fi
}

check_trixie_or_later() {
  local codename
  codename="$(read_os_codename)"
  if [[ -z "$codename" ]]; then
    log "WARNING: Could not read OS codename from /etc/os-release; continuing."
    return 0
  fi
  case "$codename" in
    trixie|forky|sid)
      return 0
      ;;
    *)
      log "WARNING: Expected Raspberry Pi OS Trixie or later, got VERSION_CODENAME='$codename'"
      ;;
  esac
}

install_stim2_latest() {
  local tmp_dir url deb_path arch all_debs
  tmp_dir="$(mktemp -d)"
  trap '[[ -n "${tmp_dir:-}" ]] && rm -rf "$tmp_dir"' RETURN

  arch="$(dpkg --print-architecture)"
  case "$arch" in
    arm64)
      deb_path="$tmp_dir/stim2_latest_arm64.deb"
      release_json="$(wget -qO- https://api.github.com/repos/SheinbergLab/stim2/releases/latest || true)"
      if [[ -z "$release_json" ]]; then
        die "Failed to fetch stim2 release metadata from GitHub API"
      fi
      if echo "$release_json" | grep -q "API rate limit exceeded"; then
        die "GitHub API rate limit exceeded; try again later or use a cached .deb"
      fi
      all_debs="$(
        echo "$release_json" \
          | grep -o '"browser_download_url":[^"]*"[^"]*\.deb"' \
          | cut -d '"' -f 4
      )"
      url="$(echo "$all_debs" | grep -m 1 -E 'arm64|aarch64' || true)"
      if [[ -z "$url" ]]; then
        url="$(echo "$all_debs" | head -n 1 || true)"
      fi
      ;;
    *)
      die "Unsupported architecture '$arch' (stim2 release .deb expected for arm64)"
      ;;
  esac

  [[ -n "$url" ]] || die "Could not find stim2 .deb in latest release"

  log "Downloading stim2 from $url"
  wget -O "$deb_path" "$url"
  chmod 0644 "$deb_path"
  if id _apt >/dev/null 2>&1; then
    chown _apt:root "$deb_path" || true
  fi
  apt-get install -y "$deb_path"

  if ! command -v stim2 >/dev/null 2>&1; then
    if [[ -x /usr/local/stim2/stim2 ]]; then
      ln -sf /usr/local/stim2/stim2 /usr/local/bin/stim2
    else
      die "stim2 binary not found after install"
    fi
  fi
}

write_stim2_service() {
  [[ -x /usr/local/stim2/stim2 ]] || die "stim2 binary missing at /usr/local/stim2/stim2"

  cat >/etc/systemd/system/stim2.service <<'EOF'
[Unit]
Description=Stim2 Stimulus Presentation

[Service]
Type=simple
Environment=XDG_RUNTIME_DIR=/tmp
ExecStart=/usr/bin/cage -- /usr/local/stim2/stim2 -F -f /usr/local/stim2/config/linux.cfg
Restart=always
RestartSec=5
CPUSchedulingPolicy=fifo
CPUSchedulingPriority=50

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable stim2.service
}

configure_raspi_config() {
  if ! have_cmd raspi-config; then
    log "WARNING: raspi-config not found; skipping console/autologin/wayland setup."
    return 0
  fi

  # Boot to console with auto-login.
  if ! raspi-config nonint do_boot_behaviour B2; then
    log "WARNING: raspi-config boot behaviour failed; verify console autologin manually."
  fi

  # Prefer Wayland with labwc (if supported by this raspi-config version).
  if ! raspi-config nonint do_wayland W1; then
    log "WARNING: raspi-config do_wayland W1 failed; verify Wayland/Labwc manually."
  fi
}

main() {
  require_root
  check_trixie_or_later

  log "Installing dependencies..."
  apt-get update
  apt-get install -y ca-certificates wget cage labwc

  log "Installing stim2..."
  install_stim2_latest

  log "Configuring stim2 systemd service..."
  write_stim2_service

  log "Applying kiosk-style boot settings..."
  configure_raspi_config

  log "Done. Reboot to start stim2 in kiosk mode."
}

main "$@"
