#!/usr/bin/env bash
set -euo pipefail

# Provision a Raspberry Pi OS Trixie Lite system to boot into stim2 in kiosk mode.

MONITOR_WIDTH_CM_DEFAULT="21.7"
MONITOR_HEIGHT_CM_DEFAULT="13.6"
MONITOR_DISTANCE_CM_DEFAULT="30.0"

MONITOR_WIDTH_CM="$MONITOR_WIDTH_CM_DEFAULT"
MONITOR_HEIGHT_CM="$MONITOR_HEIGHT_CM_DEFAULT"
MONITOR_DISTANCE_CM="$MONITOR_DISTANCE_CM_DEFAULT"

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

prompt_monitor_settings() {
  local input

  log "Configure stim2 monitor settings (press Enter to accept defaults)."

  read -r -p "Screen width cm [${MONITOR_WIDTH_CM_DEFAULT}]: " input
  if [[ -n "$input" ]]; then
    MONITOR_WIDTH_CM="$input"
  fi

  read -r -p "Screen height cm [${MONITOR_HEIGHT_CM_DEFAULT}]: " input
  if [[ -n "$input" ]]; then
    MONITOR_HEIGHT_CM="$input"
  fi

  read -r -p "Distance to monitor cm [${MONITOR_DISTANCE_CM_DEFAULT}]: " input
  if [[ -n "$input" ]]; then
    MONITOR_DISTANCE_CM="$input"
  fi
}

write_monitor_tcl() {
  local monitor_dir monitor_file
  monitor_dir="/usr/local/stim2/local"
  monitor_file="${monitor_dir}/monitor.tcl"

  mkdir -p "$monitor_dir"
  cat >"$monitor_file" <<EOF
# Monitor-specific settings
screen_set ScreenWidthCm       ${MONITOR_WIDTH_CM}
screen_set ScreenHeightCm      ${MONITOR_HEIGHT_CM}
screen_set DistanceToMonitor   ${MONITOR_DISTANCE_CM}
EOF
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

install_dserv_latest() {
  local tmp_dir url deb_path arch release_json all_debs
  tmp_dir="$(mktemp -d)"
  trap '[[ -n "${tmp_dir:-}" ]] && rm -rf "$tmp_dir"' RETURN

  arch="$(dpkg --print-architecture)"
  case "$arch" in
    arm64)
      deb_path="$tmp_dir/dserv_latest_arm64.deb"
      release_json="$(wget -qO- https://api.github.com/repos/SheinbergLab/dserv/releases/latest || true)"
      if [[ -z "$release_json" ]]; then
        die "Failed to fetch dserv release metadata from GitHub API"
      fi
      if echo "$release_json" | grep -q "API rate limit exceeded"; then
        die "GitHub API rate limit exceeded; try again later or use a cached .deb"
      fi
      all_debs="$(
        echo "$release_json" \
          | grep -o '"browser_download_url":[^"]*"[^"]*\.deb"' \
          | cut -d '"' -f 4
      )"
      url="$(echo "$all_debs" | grep -m 1 -E 'dserv_.*_arm64\.deb' || true)"
      ;;
    *)
      die "Unsupported architecture '$arch' (dserv release .deb expected for arm64)"
      ;;
  esac

  [[ -n "$url" ]] || die "Could not find dserv arm64 .deb in latest release"

  log "Downloading dserv from $url"
  wget -O "$deb_path" "$url"
  chmod 0644 "$deb_path"
  if id _apt >/dev/null 2>&1; then
    chown _apt:root "$deb_path" || true
  fi
  apt-get install -y "$deb_path"

  if ! command -v dserv >/dev/null 2>&1; then
    if [[ -x /usr/local/dserv/dserv ]]; then
      ln -sf /usr/local/dserv/dserv /usr/local/bin/dserv
    elif [[ -x /usr/bin/dserv ]]; then
      ln -sf /usr/bin/dserv /usr/local/bin/dserv
    else
      log "WARNING: dserv binary not found in expected locations; check dpkg -L dserv"
    fi
  fi
}

install_dlsh_latest() {
  local release_json url target_dir filename
  target_dir="/usr/local/dlsh"

  release_json="$(wget -qO- https://api.github.com/repos/SheinbergLab/dlsh/releases/latest || true)"
  if [[ -z "$release_json" ]]; then
    die "Failed to fetch dlsh release metadata from GitHub API"
  fi
  if echo "$release_json" | grep -q "API rate limit exceeded"; then
    die "GitHub API rate limit exceeded; try again later or use a cached .zip"
  fi

  url="$(
    echo "$release_json" \
      | grep -o '"browser_download_url":[^"]*"[^"]*\.zip"' \
      | cut -d '"' -f 4 \
      | grep -m 1 -E 'dlsh-.*\.zip' || true
  )"

  [[ -n "$url" ]] || die "Could not find dlsh .zip in latest release"

  filename="$(basename "$url")"
  mkdir -p "$target_dir"
  log "Downloading dlsh archive from $url"
  wget -O "${target_dir}/${filename}" "$url"
}

write_stim2_service() {
  local stim2_bin cage_bin run_user run_uid
  stim2_bin="$(command -v stim2 || true)"
  cage_bin="$(command -v cage || true)"
  run_user="${SUDO_USER:-}"
  if [[ -z "$run_user" || "$run_user" == "root" ]]; then
    run_user="$(id -un 1000 2>/dev/null || true)"
  fi
  if [[ -z "$run_user" || "$run_user" == "root" ]]; then
    run_user="lab"
  fi
  run_uid="$(id -u "$run_user" 2>/dev/null || true)"

  if [[ -z "$stim2_bin" && -x /usr/local/stim2/stim2 ]]; then
    stim2_bin="/usr/local/stim2/stim2"
  fi

  [[ -x "$stim2_bin" ]] || die "stim2 binary missing (expected in PATH or /usr/local/stim2/stim2)"
  [[ -x "$cage_bin" ]] || die "cage binary missing from PATH"
  [[ -n "$run_uid" ]] || die "Could not determine UID for user '$run_user'"

  cat >/etc/systemd/system/stim2.service <<EOF
[Unit]
Description=Stim2 Stimulus Presentation
After=systemd-user-sessions.service
Conflicts=getty@tty1.service

[Service]
Type=simple
User=${run_user}
Environment=XDG_RUNTIME_DIR=/run/user/${run_uid}
PAMName=login
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
StandardInput=tty
ExecStart=${cage_bin} -- ${stim2_bin} -F -f /usr/local/stim2/config/linux.cfg
Restart=always
RestartSec=5
CPUSchedulingPolicy=fifo
CPUSchedulingPriority=50

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable stim2.service
  systemctl restart stim2.service || true
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
  prompt_monitor_settings

  log "Installing dependencies..."
  apt-get update
  apt-get install -y ca-certificates wget cage labwc libtcl9.0

  log "Installing stim2..."
  install_stim2_latest

  log "Installing dserv..."
  install_dserv_latest

  log "Downloading dlsh archive..."
  install_dlsh_latest

  log "Writing stim2 monitor configuration..."
  write_monitor_tcl

  log "Configuring stim2 systemd service..."
  write_stim2_service

  log "Applying kiosk-style boot settings..."
  configure_raspi_config

  log "Done. Reboot to start stim2 in kiosk mode."
}

main "$@"
