#!/usr/bin/env bash
set -euo pipefail

# Provision the eMMC with Raspberry Pi OS (desktop) and set it up to
# auto-run NVMe provisioning on every boot.
#
# Intended to be run while booted from NVMe or microSD.

LOG_PREFIX=""

# Used by EXIT trap for cleanup (must not be local vars).
HB_BOOT_MNT=""
HB_ROOT_MNT=""

die() {
  if [[ -n "$LOG_PREFIX" ]]; then
    echo "$LOG_PREFIX ERROR: $*" >&2
  else
    echo "ERROR: $*" >&2
  fi
  exit 1
}

log() {
  # Logs go to stderr so functions that "return data" via stdout can be safely captured.
  if [[ -n "$LOG_PREFIX" ]]; then
    echo "$LOG_PREFIX $*" >&2
  else
    echo "$*" >&2
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run as root (e.g. sudo $0)"
  fi
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

check_bookworm_or_later() {
  local codename
  codename="$(read_os_codename)"
  if [[ -z "$codename" ]]; then
    log "WARNING: Could not read OS codename from /etc/os-release; continuing."
    return 0
  fi
  case "$codename" in
    bookworm|trixie|forky|sid)
      return 0
      ;;
    *)
      die "Expected Raspberry Pi OS Bookworm or later, got VERSION_CODENAME='$codename'"
      ;;
  esac
}

have_internet() {
  # Best-effort connectivity check without requiring curl/ping.
  if have_cmd timeout; then
    timeout 3 bash -c 'cat < /dev/null > /dev/tcp/1.1.1.1/443' >/dev/null 2>&1 && return 0
  else
    bash -c 'cat < /dev/null > /dev/tcp/1.1.1.1/443' >/dev/null 2>&1 && return 0
  fi
  return 1
}

nmcli_connected() {
  have_cmd nmcli || return 1
  nmcli -t -f STATE g 2>/dev/null | grep -q '^connected$'
}

wifi_iface() {
  # Returns the first connected wifi interface (e.g. wlan0), or empty.
  have_cmd nmcli || { echo ""; return 0; }
  nmcli -t -f DEVICE,TYPE,STATE dev status 2>/dev/null \
    | awk -F: '$2=="wifi" && $3=="connected"{print $1; exit}'
}

connected_wifi_ssid() {
  # Returns the SSID currently in use (best-effort), or empty.
  have_cmd nmcli || { echo ""; return 0; }
  nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}'
}

nmcli_cleanup_temp_connection() {
  local con_name="$1"
  have_cmd nmcli || return 0
  [[ -n "$con_name" ]] || return 0
  nmcli -w 5 con delete "$con_name" >/dev/null 2>&1 || true
}

iface_has_ipv4() {
  local iface="$1"
  [[ -n "$iface" ]] || return 1
  have_cmd ip || return 1
  ip -4 addr show dev "$iface" 2>/dev/null | grep -qE '^\s*inet\s+'
}

wait_for_ipv4() {
  local iface="$1"
  local timeout_s="${2:-45}"
  local waited=0

  while [[ "$waited" -lt "$timeout_s" ]]; do
    if iface_has_ipv4 "$iface"; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

connect_wifi_current() {
  local ssid="$1"
  local pass="$2"

  have_cmd nmcli || die "nmcli not found. Install NetworkManager or connect networking manually, then re-run."

  log "Attempting to connect current system to Wi-Fi via NetworkManager (nmcli)..."
  nmcli radio wifi on >/dev/null 2>&1 || true
  nmcli dev wifi rescan >/dev/null 2>&1 || true

  local iface
  iface="$(wifi_iface)"
  if [[ -z "$iface" ]]; then
    iface="$(nmcli -t -f DEVICE,TYPE dev status 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')"
  fi
  [[ -n "$iface" ]] || die "No Wi-Fi interface found (nmcli shows no wifi devices)."

  local con_name="hb-wifi-${ssid//[^A-Za-z0-9_.-]/_}-$RANDOM"
  nmcli_cleanup_temp_connection "$con_name"
  trap 'nmcli_cleanup_temp_connection "'"$con_name"'"' RETURN

  nmcli -w 5 dev disconnect "$iface" >/dev/null 2>&1 || true

  nmcli -w 30 con add type wifi ifname "$iface" con-name "$con_name" ssid "$ssid" >/dev/null 2>&1 \
    || die "Failed to create temporary Wi-Fi connection for SSID '$ssid'."
  nmcli -w 30 con modify "$con_name" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$pass" >/dev/null 2>&1 \
    || die "Failed to apply Wi-Fi password for SSID '$ssid' (nmcli rejected it)."
  nmcli -w 60 con up "$con_name" ifname "$iface" >/dev/null 2>&1 \
    || die "Failed to connect to Wi-Fi SSID '$ssid' (auth may have failed)."

  local got_ssid
  got_ssid="$(connected_wifi_ssid)"
  if [[ "$got_ssid" != "$ssid" ]]; then
    die "Connected Wi-Fi SSID mismatch. Expected '$ssid', got '${got_ssid:-<none>}'"
  fi

  if ! nmcli_connected; then
    die "NetworkManager did not reach connected state after Wi-Fi connect."
  fi

  if wait_for_ipv4 "$iface" 60; then
    :
  else
    die "Wi-Fi connected to '$ssid' on '$iface' but no IPv4 address was acquired within 60s."
  fi
}

wifi_scan_ssids() {
  local ssids=""
  if command -v nmcli >/dev/null 2>&1; then
    nmcli radio wifi on >/dev/null 2>&1 || true
    nmcli dev wifi rescan >/dev/null 2>&1 || true
    sleep 2
    ssids="$(
      nmcli -t -f SSID dev wifi list --rescan yes 2>/dev/null \
        | sed '/^$/d' \
        | sort -u \
        || nmcli -t -f SSID dev wifi list 2>/dev/null | sed '/^$/d' | sort -u \
        || true
    )"
  fi
  if [[ -z "$ssids" ]] && command -v iw >/dev/null 2>&1; then
    local iface
    iface="$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}' || true)"
    if [[ -n "$iface" ]]; then
      ssids="$(iw dev "$iface" scan 2>/dev/null | grep -E '^\s*SSID:' | sed 's/^\s*SSID:\s*//' | sed '/^$/d' | sort -u || true)"
    fi
  fi
  echo "$ssids"
}

prompt_wifi() {
  local ssids ssid pass choice
  log "Scanning for Wi-Fi SSIDs..."
  ssids="$(wifi_scan_ssids)"

  if [[ -n "$ssids" ]]; then
    log "Discovered Wi-Fi SSIDs:"
    mapfile -t _ssids_list < <(printf '%s\n' "$ssids")
    local i
    for i in "${!_ssids_list[@]}"; do
      printf '  [%d] %s\n' "$i" "${_ssids_list[$i]}" >&2
    done
    echo >&2
    read -r -p "Select Wi-Fi by number, or type an SSID (leave blank to skip Wi-Fi): " choice
    if [[ -z "$choice" ]]; then
      echo ""
      echo ""
      return 0
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 0 && "$choice" -lt "${#_ssids_list[@]}" ]]; then
      ssid="${_ssids_list[$choice]}"
    else
      ssid="$choice"
    fi
  else
    log "WARNING: Could not scan Wi-Fi SSIDs."
    read -r -p "Enter Wi-Fi SSID to use (leave blank to skip Wi-Fi): " ssid
    if [[ -z "$ssid" ]]; then
      echo ""
      echo ""
      return 0
    fi
  fi

  [[ "$ssid" != *$'\n'* && "$ssid" != *$'\r'* ]] || die "SSID contains newline characters; refusing."
  read -r -s -p "Enter Wi-Fi password for '$ssid': " pass
  echo >&2
  [[ -n "$pass" ]] || die "Empty Wi-Fi password not allowed."
  [[ "$pass" != *$'\n'* && "$pass" != *$'\r'* ]] || die "Wi-Fi password contains newline characters; refusing."
  echo "$ssid"
  echo "$pass"
}

root_source() {
  need_cmd findmnt
  local src
  src="$(findmnt -n -o SOURCE /)"
  if [[ "$src" == /dev/* ]]; then
    echo "$src"
    return 0
  fi
  if command -v blkid >/dev/null 2>&1; then
    case "$src" in
      PARTUUID=*|UUID=*|LABEL=*)
        local dev
        dev="$(blkid -t "$src" -o device 2>/dev/null | head -n1 || true)"
        if [[ -n "$dev" ]]; then
          echo "$dev"
          return 0
        fi
        ;;
    esac
  fi
  echo "$src"
}

strip_partition_suffix() {
  local src="$1"
  if [[ "$src" =~ ^/dev/mmcblk[0-9]+p[0-9]+$ ]]; then
    echo "${src%p*}"
  elif [[ "$src" =~ ^/dev/nvme[0-9]+n[0-9]+p[0-9]+$ ]]; then
    echo "${src%p*}"
  else
    echo "${src%[0-9]*}"
  fi
}

list_emmc_candidates() {
  # Output lines: dev|size|model|is_emmc
  local name size model dev is_emmc
  while read -r name size model; do
    dev="/dev/${name}"
    is_emmc="no"
    if compgen -G "${dev}boot0" >/dev/null; then
      is_emmc="yes"
    fi
    echo "${dev}|${size}|${model}|${is_emmc}"
  done < <(
    lsblk -dn -o NAME,TYPE,SIZE,MODEL \
      | awk '$2=="disk" && $1 ~ /^mmcblk[0-9]+$/ {print $1, $3, $4}'
  )
}

pick_emmc_device() {
  local entries=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    entries+=("$line")
  done < <(list_emmc_candidates)

  [[ "${#entries[@]}" -gt 0 ]] || die "No mmcblk disks found. Is eMMC present?"

  if [[ "${#entries[@]}" -eq 1 ]]; then
    echo "${entries[0]%%|*}"
    return 0
  fi

  log "Multiple mmcblk disks found:"
  local i line dev size model is_emmc
  for i in "${!entries[@]}"; do
    line="${entries[$i]}"
    IFS="|" read -r dev size model is_emmc <<< "$line"
    printf '  [%d] %s (%s, %s, emmc=%s)\n' "$i" "$dev" "$size" "$model" "$is_emmc" >&2
  done
  local idx
  read -r -p "Select eMMC disk index to ERASE and provision: " idx
  [[ "$idx" =~ ^[0-9]+$ ]] || die "Invalid index."
  [[ "$idx" -ge 0 && "$idx" -lt "${#entries[@]}" ]] || die "Index out of range."
  echo "${entries[$idx]%%|*}"
}

confirm_erase_device() {
  local dev="$1"
  log "About to ERASE and overwrite the entire disk: $dev"
  log "This is destructive. All data on $dev will be lost."
  read -r -p "Type ERASE to continue: " answer
  [[ "$answer" == "ERASE" ]] || die "User did not confirm ERASE."
}

install_packages() {
  need_cmd apt-get
  log "Installing required packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    wget xz-utils openssl ca-certificates \
    util-linux coreutils gawk grep sed \
    parted \
    dosfstools e2fsprogs \
    iw network-manager \
    git
}

download_image_xz() {
  local out_xz="$1"
  local url="https://downloads.raspberrypi.org/raspios_arm64_latest"
  local meta="${out_xz}.meta"

  remote_meta() {
    wget -S --spider --max-redirect=20 "$url" 2>&1 | awk '
      BEGIN{etag=""; lm=""; len=""}
      {
        line=$0
        sub(/^[[:space:]]+/, "", line)
        if (tolower(substr(line,1,5))=="etag:") {
          sub(/^ETag:[[:space:]]*/, "", line)
          etag=line
        } else if (tolower(substr(line,1,14))=="last-modified:") {
          sub(/^Last-Modified:[[:space:]]*/, "", line)
          lm=line
        } else if (tolower(substr(line,1,7))=="length:") {
          n=split(line, a, /[[:space:]]+/)
          if (n>=2) len=a[2]
        }
      }
      END{
        print etag
        print lm
        print len
      }'
  }

  if [[ -f "$out_xz" && -f "$meta" ]]; then
    local old_etag old_lm old_len
    old_etag="$(sed -n '1p' "$meta" 2>/dev/null || true)"
    old_lm="$(sed -n '2p' "$meta" 2>/dev/null || true)"
    old_len="$(sed -n '3p' "$meta" 2>/dev/null || true)"

    local new_etag new_lm new_len
    {
      read -r new_etag
      read -r new_lm
      read -r new_len
    } < <(remote_meta || true)

    local local_len=""
    if command -v stat >/dev/null 2>&1; then
      local_len="$(stat -c%s "$out_xz" 2>/dev/null || true)"
    fi

    if [[ -n "$new_len" && -n "$old_len" && "$new_len" == "$old_len" && "$local_len" == "$new_len" ]] \
      && [[ -n "$new_etag" && -n "$old_etag" && "$new_etag" == "$old_etag" ]] \
      && [[ -n "$new_lm" && -n "$old_lm" && "$new_lm" == "$old_lm" ]]; then
      log "Local image is already the latest (ETag/Last-Modified/Length match). Skipping download."
      return 0
    fi
  fi

  log "Downloading latest Raspberry Pi OS desktop arm64 image (.xz) from $url ..."
  wget -O "$out_xz" "$url"

  remote_meta > "$meta" 2>/dev/null || true
}

unmount_device_partitions() {
  local dev="$1"
  local mounts
  mounts="$(lsblk -nr -o MOUNTPOINT "$dev" 2>/dev/null || true)"
  if echo "$mounts" | grep -qE '.+'; then
    log "Unmounting any mounted partitions on $dev ..."
    while read -r mp; do
      [[ -n "$mp" ]] || continue
      umount "$mp" || true
    done < <(lsblk -nr -o MOUNTPOINT "$dev" | awk 'NF')
  fi
}

write_image_to_emmc() {
  local xz_path="$1"
  local dev="$2"

  need_cmd dd
  need_cmd xzcat
  unmount_device_partitions "$dev"

  log "Flashing image to $dev (this can take a while)..."
  xzcat "$xz_path" | dd of="$dev" bs=4M conv=fsync status=progress
  sync
}

wait_for_partitions() {
  local dev="$1"
  need_cmd udevadm
  need_cmd partprobe

  partprobe "$dev" || true
  udevadm settle || true

  local tries=40
  while [[ "$tries" -gt 0 ]]; do
    if lsblk -pn -o NAME "$dev" | grep -qE "${dev}p?[0-9]+"; then
      return 0
    fi
    sleep 0.25
    tries=$((tries-1))
  done
  die "Timed out waiting for partitions to appear on $dev"
}

find_emmc_partition() {
  local dev="$1"
  local want="$2" # "boot" or "root"
  local out=""

  while read -r line; do
    [[ -n "$line" ]] || continue
    local NAME="" LABEL="" PARTLABEL=""
    eval "$line"
    local name="${NAME:-}" label="${LABEL:-}" partlabel="${PARTLABEL:-}"
    [[ -n "$name" ]] || continue
    case "$want" in
      boot)
        if [[ "$label" == "bootfs" || "$partlabel" == "bootfs" || "$label" == "boot" || "$partlabel" == "boot" ]]; then
          out="$name"; break
        fi
        ;;
      root)
        if [[ "$label" == "rootfs" || "$partlabel" == "rootfs" ]]; then
          out="$name"; break
        fi
        ;;
      *)
        die "Unknown partition type requested: $want"
        ;;
    esac
  done < <(lsblk -pn -P -o NAME,LABEL,PARTLABEL "$dev")

  if [[ -n "$out" ]]; then
    echo "$out"
    return 0
  fi

  case "$want" in
    boot) echo "${dev}p1" ;;
    root) echo "${dev}p2" ;;
  esac
}

mount_emmc_partitions_for_config() {
  local boot_part="$1"
  local root_part="$2"
  local boot_mnt="$3"
  local root_mnt="$4"

  mkdir -p "$boot_mnt" "$root_mnt"
  mount "$root_part" "$root_mnt"
  mount "$boot_part" "$boot_mnt"
}

cleanup_mounts() {
  local boot_mnt="$1"
  local root_mnt="$2"

  sync || true
  if [[ -n "${boot_mnt:-}" ]]; then
    umount "$boot_mnt" 2>/dev/null || true
  fi
  if [[ -n "${root_mnt:-}" ]]; then
    umount "$root_mnt" 2>/dev/null || true
  fi
}

set_eeprom_boot_to_emmc() {
  # Best-effort non-interactive edit using EDITOR trick; falls back with instructions if it fails.
  need_cmd rpi-eeprom-update
  need_cmd rpi-eeprom-config

  log "Updating EEPROM package + applying latest EEPROM update (if available)..."
  rpi-eeprom-update -a || true

  log "Setting EEPROM BOOT_ORDER to prefer SD/eMMC (BOOT_ORDER=0xf41) ..."

  local editor="/tmp/hb_rpi_eeprom_editor_emmc.sh"
  cat > "$editor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
f="$1"

ensure_kv() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" "$f"; then
    sed -i -E "s/^${key}=.*/${key}=${val}/" "$f"
  else
    printf '%s=%s\n' "$key" "$val" >> "$f"
  fi
}

ensure_kv "BOOT_ORDER" "0xf41"
EOF
  chmod +x "$editor"

  if EDITOR="$editor" rpi-eeprom-config --edit >/dev/null 2>&1; then
    :
  elif EDITOR="$editor" rpi-eeprom-config -e >/dev/null 2>&1; then
    :
  else
    log "WARNING: Could not non-interactively edit EEPROM config."
    log "You can run manually:"
    log "  sudo rpi-eeprom-config -e"
    log "and set:"
    log "  BOOT_ORDER=0xf41"
  fi
}

write_emmc_config() {
  local boot_mnt="$1"
  local root_mnt="$2"

  log "Configuring eMMC OS (user/autostart/sudo)..."

  local username="provision"
  local password="provision"

  # Create user on first boot via userconf.txt.
  local pw_hash
  pw_hash="$(openssl passwd -6 "$password")"
  printf '%s:%s\n' "$username" "$pw_hash" > "${boot_mnt}/userconf.txt"

  # Ensure PCIe is enabled so NVMe is visible when booted from eMMC.
  local cfg="${boot_mnt}/config.txt"
  if [[ -f "$cfg" ]]; then
    if ! grep -qE '^\s*dtparam=pciex1(=on)?\s*$' "$cfg"; then
      echo "dtparam=pciex1=on" >> "$cfg"
    fi
  else
    log "WARNING: Did not find config.txt on boot partition ($cfg)."
  fi

  # Passwordless sudo for provision user.
  mkdir -p "${root_mnt}/etc/sudoers.d"
  printf '%s\n' "${username} ALL=(ALL) NOPASSWD:ALL" > "${root_mnt}/etc/sudoers.d/010-${username}-nopasswd"
  chmod 0440 "${root_mnt}/etc/sudoers.d/010-${username}-nopasswd"

  # Auto-login to desktop (best-effort; depends on display manager).
  if [[ -d "${root_mnt}/etc/lightdm" ]]; then
    mkdir -p "${root_mnt}/etc/lightdm/lightdm.conf.d"
    cat > "${root_mnt}/etc/lightdm/lightdm.conf.d/50-hb-autologin.conf" <<EOF
[Seat:*]
autologin-user=${username}
autologin-user-timeout=0
EOF
  fi

  # Create home directory skeleton + autostart entry.
  local home_dir="${root_mnt}/home/${username}"
  mkdir -p "${home_dir}/.config/autostart"

  cat > "${home_dir}/.config/autostart/hb-provision-nvme.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Homebase NVMe Provisioning
Comment=Run NVMe provisioning on boot
Exec=x-terminal-emulator -e bash -lc 'cd /home/provision/homebase_setup/hb-clients/provision_nvme_from_emmc && sudo ./provision_nvme_from_emmc.sh'
Terminal=false
X-GNOME-Autostart-enabled=true
EOF

  # Clone repo onto the eMMC image.
  local repo_dir="${home_dir}/homebase_setup"
  rm -rf "$repo_dir"
  git clone --depth 1 https://github.com/ryanmillerwork/homebase_setup.git "$repo_dir"

  # Ensure script is executable and ownership is correct.
  chmod +x "${repo_dir}/hb-clients/provision_nvme_from_emmc/provision_nvme_from_emmc.sh" || true
  chown -R 1000:1000 "$home_dir"
}

main() {
  require_root
  need_cmd lsblk
  need_cmd awk
  need_cmd grep
  need_cmd sed

  check_bookworm_or_later

  # Ensure we have internet for downloads.
  local wifi_ssid="" wifi_pass=""
  log "Wi-Fi selection (optional) for downloads."
  {
    read -r wifi_ssid
    read -r wifi_pass
  } < <(prompt_wifi)

  if [[ -n "$wifi_ssid" ]]; then
    connect_wifi_current "$wifi_ssid" "$wifi_pass"
  fi

  if ! have_internet; then
    die "No internet connectivity. Connect Ethernet or provide Wi-Fi credentials and re-run."
  fi
  log "Internet connectivity verified."

  local root_src root_dev
  root_src="$(root_source)"
  root_dev="$(strip_partition_suffix "$root_src")"
  log "Current root device: $root_dev"

  local emmc_dev
  emmc_dev="$(pick_emmc_device)"
  [[ -b "$emmc_dev" ]] || die "Not a block device: $emmc_dev"
  if [[ "$emmc_dev" == "$root_dev" ]]; then
    die "Refusing to overwrite the current root device ($root_dev). Boot from NVMe or SD and retry."
  fi

  confirm_erase_device "$emmc_dev"

  install_packages

  local xz_path="/tmp/raspios_arm64_latest.img.xz"
  download_image_xz "$xz_path"
  write_image_to_emmc "$xz_path" "$emmc_dev"

  wait_for_partitions "$emmc_dev"
  local boot_part root_part
  boot_part="$(find_emmc_partition "$emmc_dev" boot)"
  root_part="$(find_emmc_partition "$emmc_dev" root)"

  [[ -b "$boot_part" ]] || die "Boot partition not found: $boot_part"
  [[ -b "$root_part" ]] || die "Root partition not found: $root_part"

  log "eMMC boot partition: $boot_part"
  log "eMMC root partition: $root_part"

  HB_BOOT_MNT="/mnt/hb_emmc_boot"
  HB_ROOT_MNT="/mnt/hb_emmc_root"
  trap 'cleanup_mounts "${HB_BOOT_MNT:-}" "${HB_ROOT_MNT:-}"' EXIT
  mount_emmc_partitions_for_config "$boot_part" "$root_part" "$HB_BOOT_MNT" "$HB_ROOT_MNT"

  write_emmc_config "$HB_BOOT_MNT" "$HB_ROOT_MNT"

  cleanup_mounts "$HB_BOOT_MNT" "$HB_ROOT_MNT"
  trap - EXIT

  set_eeprom_boot_to_emmc

  log "eMMC provisioning complete."
}

main
