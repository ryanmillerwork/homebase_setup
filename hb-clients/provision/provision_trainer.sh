#!/usr/bin/env bash
set -euo pipefail

# Provision a Raspberry Pi OS Trixie Lite system to boot into stim2 in kiosk mode.

MONITOR_WIDTH_CM_DEFAULT="21.7"
MONITOR_HEIGHT_CM_DEFAULT="13.6"
MONITOR_DISTANCE_CM_DEFAULT="30.0"
ESS_SOURCE_DEFAULT="https://github.com/homebase-sheinberg/ess.git"

MONITOR_WIDTH_CM="$MONITOR_WIDTH_CM_DEFAULT"
MONITOR_HEIGHT_CM="$MONITOR_HEIGHT_CM_DEFAULT"
MONITOR_DISTANCE_CM="$MONITOR_DISTANCE_CM_DEFAULT"

RUN_USER=""
RUN_UID=""
RUN_HOME=""

DEFAULTS_FILE=""
DEFAULTS_SECTION=""
ESS_SOURCE="$ESS_SOURCE_DEFAULT"

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

ini_list_sections() {
  local file="$1"
  awk '
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      line=$0
      sub(/^[[:space:]]*\[/, "", line)
      sub(/\][[:space:]]*$/, "", line)
      print line
    }' "$file"
}

ini_list_device_sections() {
  local file="$1"
  ini_list_sections "$file" | grep -v '\.meta$' || true
}

ini_list_groups() {
  local file="$1"
  ini_list_device_sections "$file" | awk -F. '
    NF>=2 {
      group=$1
      for (i=2; i<NF; i++) group=group "." $i
      print group
    }' | sort -u
}

ini_list_device_types_for_group() {
  local file="$1"
  local group="$2"
  ini_list_device_sections "$file" | awk -F. -v g="$group" '
    NF>=2 {
      grp=$1
      for (i=2; i<NF; i++) grp=grp "." $i
      if (grp==g) print $NF
    }' | sort -u
}

ini_section_exists() {
  local file="$1"
  local section="$2"
  ini_list_sections "$file" | grep -Fxq "$section"
}

ini_get() {
  local file="$1"
  local section="$2"
  local key="$3"
  awk -v section="$section" -v key="$key" '
    /^[[:space:]]*[#;]/ {next}
    /^[[:space:]]*\[/ {
      line=$0
      sub(/^[[:space:]]*\[/, "", line)
      sub(/\][[:space:]]*$/, "", line)
      in_section=(line==section)
      next
    }
    in_section {
      split($0, a, "=")
      k=a[1]
      sub(/^[[:space:]]+/, "", k); sub(/[[:space:]]+$/, "", k)
      if (k==key) {
        v=substr($0, index($0, "=")+1)
        sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
        print v
        exit
      }
    }
  ' "$file"
}

select_defaults_section() {
  local file="$1"
  local section="${DEVICE_DEFAULTS_SECTION:-}"
  local group="${DEVICE_DEFAULTS_GROUP:-}"
  local subgroup="${DEVICE_DEFAULTS_SUBGROUP:-}"

  if [[ -n "$section" ]] && ini_section_exists "$file" "$section"; then
    echo "$section"
    return 0
  fi

  if [[ -n "$group" && -n "$subgroup" ]]; then
    section="${group}.${subgroup}"
    if ini_section_exists "$file" "$section"; then
      echo "$section"
      return 0
    fi
  fi

  local groups group_choice
  groups="$(ini_list_groups "$file")"
  if [[ -z "$groups" ]]; then
    return 0
  fi

  log "Available groups:"
  mapfile -t _groups_list < <(printf '%s\n' "$groups" | sed '/^$/d')
  local i
  for i in "${!_groups_list[@]}"; do
    printf '  [%d] %s\n' "$i" "${_groups_list[$i]}" >&2
  done
  read -r -p "Select group by number, or type name (leave blank to skip defaults): " group_choice
  if [[ -z "$group_choice" ]]; then
    echo ""
    return 0
  fi
  if [[ "$group_choice" =~ ^[0-9]+$ ]] && [[ "$group_choice" -ge 0 && "$group_choice" -lt "${#_groups_list[@]}" ]]; then
    group="${_groups_list[$group_choice]}"
  else
    group="$group_choice"
  fi

  local types type_choice
  types="$(ini_list_device_types_for_group "$file" "$group")"
  if [[ -z "$types" ]]; then
    die "No device types found for group '$group'."
  fi

  log "Available device types for ${group}:"
  mapfile -t _types_list < <(printf '%s\n' "$types" | sed '/^$/d')
  for i in "${!_types_list[@]}"; do
    printf '  [%d] %s\n' "$i" "${_types_list[$i]}" >&2
  done
  read -r -p "Select device type by number, or type name (leave blank to skip defaults): " type_choice
  if [[ -z "$type_choice" ]]; then
    echo ""
    return 0
  fi
  if [[ "$type_choice" =~ ^[0-9]+$ ]] && [[ "$type_choice" -ge 0 && "$type_choice" -lt "${#_types_list[@]}" ]]; then
    subgroup="${_types_list[$type_choice]}"
  else
    subgroup="$type_choice"
  fi

  section="${group}.${subgroup}"
  if ini_section_exists "$file" "$section"; then
    echo "$section"
    return 0
  fi
  die "Defaults section '$section' not found in $file"
}

load_defaults() {
  local script_path script_dir
  script_path="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
  script_dir="$(cd "$(dirname "$script_path")" && pwd -P)"
  DEFAULTS_FILE="${DEVICE_DEFAULTS_FILE:-${script_dir}/device_defaults.ini}"

  if [[ ! -r "$DEFAULTS_FILE" ]]; then
    log "WARNING: Defaults file not found at $DEFAULTS_FILE; using built-in defaults."
    return 0
  fi

  DEFAULTS_SECTION="$(select_defaults_section "$DEFAULTS_FILE")" || die "Failed to select defaults section."
  if [[ -z "$DEFAULTS_SECTION" ]]; then
    log "No defaults selected; using built-in defaults."
    return 0
  fi
  log "Using defaults section: $DEFAULTS_SECTION"

  local group="${DEFAULTS_SECTION%.*}"
  local meta="${group}.meta"
  if ini_section_exists "$DEFAULTS_FILE" "$meta"; then
    local ess_source
    ess_source="$(ini_get "$DEFAULTS_FILE" "$meta" "ess_source")"
    [[ -n "$ess_source" ]] && ESS_SOURCE="$ess_source"
  fi

  local val
  val="$(ini_get "$DEFAULTS_FILE" "$DEFAULTS_SECTION" "monitor_width_cm")"
  [[ -n "$val" ]] && MONITOR_WIDTH_CM_DEFAULT="$val"
  val="$(ini_get "$DEFAULTS_FILE" "$DEFAULTS_SECTION" "monitor_height_cm")"
  [[ -n "$val" ]] && MONITOR_HEIGHT_CM_DEFAULT="$val"
  val="$(ini_get "$DEFAULTS_FILE" "$DEFAULTS_SECTION" "monitor_distance_cm")"
  [[ -n "$val" ]] && MONITOR_DISTANCE_CM_DEFAULT="$val"

  MONITOR_WIDTH_CM="$MONITOR_WIDTH_CM_DEFAULT"
  MONITOR_HEIGHT_CM="$MONITOR_HEIGHT_CM_DEFAULT"
  MONITOR_DISTANCE_CM="$MONITOR_DISTANCE_CM_DEFAULT"
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

detect_run_user() {
  if [[ -n "$RUN_USER" ]]; then
    return 0
  fi

  RUN_USER="${SUDO_USER:-}"
  if [[ -z "$RUN_USER" || "$RUN_USER" == "root" ]]; then
    RUN_USER="$(id -un 1000 2>/dev/null || true)"
  fi
  if [[ -z "$RUN_USER" || "$RUN_USER" == "root" ]]; then
    RUN_USER="lab"
  fi
  RUN_UID="$(id -u "$RUN_USER" 2>/dev/null || true)"
  RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"

  [[ -n "$RUN_UID" ]] || die "Could not determine UID for user '$RUN_USER'"
  [[ -n "$RUN_HOME" ]] || RUN_HOME="/home/${RUN_USER}"
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
  local tmp_dir url deb_path arch all_debs os_codename
  tmp_dir="$(mktemp -d)"
  trap '[[ -n "${tmp_dir:-}" ]] && rm -rf "$tmp_dir"' RETURN

  os_codename="$(read_os_codename)"
  case "$os_codename" in
    bookworm|trixie)
      ;;
    "")
      die "Could not determine OS codename for stim2 package selection"
      ;;
    *)
      die "Unsupported OS codename '$os_codename' for stim2 package selection"
      ;;
  esac

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
      url="$(echo "$all_debs" | grep -m 1 -E "stim2_.*_arm64_${os_codename}\.deb" || true)"
      if [[ -z "$url" ]]; then
        die "Could not find stim2 arm64 ${os_codename} .deb in latest release"
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

  if [[ -d /usr/local/dserv/local ]]; then
    if [[ -f /usr/local/dserv/local/post-pins.tcl.EXAMPLE ]]; then
      cp -n /usr/local/dserv/local/post-pins.tcl.EXAMPLE /usr/local/dserv/local/post-pins.tcl
    fi
    if [[ -f /usr/local/dserv/local/sound.tcl.EXAMPLE ]]; then
      cp -n /usr/local/dserv/local/sound.tcl.EXAMPLE /usr/local/dserv/local/sound.tcl
    fi
  fi
}

install_dlsh_latest() {
  local release_json url target_dir filename version
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
  version="$(echo "$filename" | sed -nE 's/^dlsh-([0-9]+([.][0-9]+)*)\.zip$/\1/p')"

  mkdir -p "$target_dir"
  log "Downloading dlsh archive from $url"
  wget -O "${target_dir}/dlsh.zip" "$url"
  if [[ -n "$version" ]]; then
    echo "$version" > "${target_dir}/VERSION"
  fi
}

install_ess_repo() {
  local systems_dir
  detect_run_user

  systems_dir="${RUN_HOME}/systems"
  if [[ ! -d "${systems_dir}/ess" ]]; then
    mkdir -p "$systems_dir"
    log "Cloning ess into ${systems_dir}/ess from ${ESS_SOURCE}"
    git -C "$systems_dir" clone "$ESS_SOURCE"
  else
    log "ess repo already present at ${systems_dir}/ess"
  fi

  git config --system --add safe.directory "${systems_dir}/ess"
  mkdir -p /usr/local/dserv/local
  echo "set env(ESS_SYSTEM_PATH) ${systems_dir}" | tee -a /usr/local/dserv/local/pre-systemdir.tcl >/dev/null
}

install_systemd_service() {
  local source_service="$1"
  local service_name

  [[ -f "$source_service" ]] || die "Missing service file: $source_service"
  service_name="$(basename "$source_service")"

  install -m 0644 "$source_service" "/etc/systemd/system/${service_name}"
  systemctl daemon-reload
  systemctl enable "$service_name"
  systemctl restart "$service_name" || true
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
  load_defaults
  prompt_monitor_settings

  log "Installing dependencies..."
  apt-get update
  apt-get install -y ca-certificates wget cage labwc libtcl9.0 git

  log "Installing stim2..."
  install_stim2_latest

  log "Installing dserv..."
  install_dserv_latest

  log "Downloading dlsh archive..."
  install_dlsh_latest

  log "Installing ess repo and dserv system path..."
  install_ess_repo

  log "Writing stim2 monitor configuration..."
  write_monitor_tcl

  log "Configuring stim2 systemd service..."
  install_systemd_service /usr/local/stim2/systemd/stim2.service

  log "Configuring dserv systemd services..."
  install_systemd_service /usr/local/dserv/systemd/dserv.service
  install_systemd_service /usr/local/dserv/systemd/dserv-agent.service

  log "Applying kiosk-style boot settings..."
  configure_raspi_config

  log "Done. Reboot to start stim2 in kiosk mode."
}

main "$@"
