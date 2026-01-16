#!/usr/bin/env bash
set -euo pipefail

# Provision an NVMe boot drive from a running Raspberry Pi OS system (Bookworm+),
# intended to be executed while booted from eMMC (or at least an mmc device).
#
# High-level:
# - Verify we're on Bookworm+ and rooted on eMMC/mmc, and that an NVMe disk exists
# - Install required packages
# - Download latest Raspberry Pi OS Lite arm64 image and write it to NVMe
# - Mount NVMe partitions and preconfigure: enable SSH, create user, configure Wi-Fi
# - Configure EEPROM boot order to prefer NVMe
# - Reboot

LOG_PREFIX=""
DEBUG="${HB_DEBUG:-0}"
REQUIRE_WIFI_INTERNET="${HB_REQUIRE_WIFI_INTERNET:-0}"

# Used by EXIT trap for cleanup (must not be local vars, because traps can run after scope exits).
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

debug() {
  [[ "$DEBUG" == "1" ]] || return 0
  if [[ -n "$LOG_PREFIX" ]]; then
    echo "$LOG_PREFIX DEBUG: $*" >&2
  else
    echo "DEBUG: $*" >&2
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
  # Tries TCP connect to a public IP over HTTPS port (more likely to be permitted than raw DNS).
  if have_cmd timeout; then
    timeout 3 bash -c 'cat < /dev/null > /dev/tcp/1.1.1.1/443' >/dev/null 2>&1 && return 0
  else
    bash -c 'cat < /dev/null > /dev/tcp/1.1.1.1/443' >/dev/null 2>&1 && return 0
  fi
  return 1
}

have_internet_via_iface() {
  # Verifies internet reachability over a specific interface by binding the socket to that interface.
  # This avoids false positives when ethernet is the default route.
  local iface="$1"
  [[ -n "$iface" ]] || return 1

  # Preferred: python3 socket with SO_BINDTODEVICE (we're root).
  if have_cmd python3; then
    IFACE="$iface" python3 - <<'PY' >/dev/null 2>&1
import os
import socket

iface = os.environ.get("IFACE", "")
if not iface:
    raise SystemExit(2)

opt = iface.encode("utf-8", errors="strict")
if not opt.endswith(b"\0"):
    opt += b"\0"

targets = [
    ("1.1.1.1", 443),           # Cloudflare
    ("1.0.0.1", 443),           # Cloudflare alt
    ("93.184.216.34", 443),     # example.com
    ("93.184.216.34", 80),      # example.com
]

last = None
for host, port in targets:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(3)
    s.setsockopt(socket.SOL_SOCKET, 25, opt)  # SO_BINDTODEVICE = 25
    try:
        s.connect((host, port))
        s.close()
        raise SystemExit(0)
    except Exception as e:
        last = e
    finally:
        try:
            s.close()
        except Exception:
            pass

raise SystemExit(1)
PY
    return $?
  fi

  # Fallback: ping bound to interface (requires iputils-ping).
  if have_cmd ping; then
    ping -I "$iface" -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 && return 0
  fi

  return 1
}

default_route_iface() {
  # Prints the interface used to reach 1.1.1.1 (best-effort). Empty if unknown.
  have_cmd ip || { echo ""; return 0; }
  ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
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
  # Don't error if it doesn't exist.
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

  have_cmd nmcli || die "nmcli not found. On Bookworm it should exist; install NetworkManager or connect networking manually, then re-run."

  log "Attempting to connect current system to Wi-Fi via NetworkManager (nmcli)..."
  nmcli radio wifi on >/dev/null 2>&1 || true
  nmcli dev wifi rescan >/dev/null 2>&1 || true

  local iface
  iface="$(wifi_iface)"
  if [[ -z "$iface" ]]; then
    # pick any wifi device if not already connected
    iface="$(nmcli -t -f DEVICE,TYPE dev status 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')"
  fi
  [[ -n "$iface" ]] || die "No Wi-Fi interface found (nmcli shows no wifi devices)."

  # Create a temp connection that uses exactly the provided password, so we don't accidentally
  # reuse a previously-saved profile with different credentials.
  local con_name="hb-wifi-${ssid//[^A-Za-z0-9_.-]/_}-$RANDOM"
  nmcli_cleanup_temp_connection "$con_name"
  trap 'nmcli_cleanup_temp_connection "'"$con_name"'"' RETURN

  # Disconnect iface first to avoid "already activating" edge cases.
  nmcli -w 5 dev disconnect "$iface" >/dev/null 2>&1 || true

  nmcli -w 30 con add type wifi ifname "$iface" con-name "$con_name" ssid "$ssid" >/dev/null 2>&1 \
    || die "Failed to create temporary Wi-Fi connection for SSID '$ssid'."
  nmcli -w 30 con modify "$con_name" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$pass" >/dev/null 2>&1 \
    || die "Failed to apply Wi-Fi password for SSID '$ssid' (nmcli rejected it)."
  nmcli -w 60 con up "$con_name" ifname "$iface" >/dev/null 2>&1 \
    || die "Failed to connect to Wi-Fi SSID '$ssid' (auth may have failed)."

  # Verify we really connected to the requested SSID.
  local got_ssid
  got_ssid="$(connected_wifi_ssid)"
  if [[ "$got_ssid" != "$ssid" ]]; then
    die "Connected Wi-Fi SSID mismatch. Expected '$ssid', got '${got_ssid:-<none>}'"
  fi

  if ! nmcli_connected; then
    die "NetworkManager did not reach connected state after Wi-Fi connect."
  fi

  # Verify that *these* credentials work by proving we can reach the internet over Wi-Fi,
  # even if the system's default route prefers ethernet.
  if wait_for_ipv4 "$iface" 60; then
    debug "Wi-Fi iface '$iface' has an IPv4 address."
  else
    die "Wi-Fi connected to '$ssid' on '$iface' but no IPv4 address was acquired within 60s (DHCP may have failed)."
  fi

  if have_internet_via_iface "$iface"; then
    log "Wi-Fi connected to '$ssid' and internet is reachable via Wi-Fi."
  else
    if [[ "$REQUIRE_WIFI_INTERNET" == "1" ]]; then
      die "Wi-Fi connected to '$ssid' on '$iface' but internet is not reachable via Wi-Fi."
    fi
    log "WARNING: Wi-Fi connected to '$ssid' but internet probe via Wi-Fi failed (captive portal/firewall?). Continuing anyway."
    log "         To require Wi-Fi internet reachability, re-run with HB_REQUIRE_WIFI_INTERNET=1"
  fi
}

root_source() {
  need_cmd findmnt
  local src
  src="$(findmnt -n -o SOURCE /)"
  # Sometimes this is reported as PARTUUID=.../UUID=.../LABEL=...
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
  # /dev/mmcblk0p2 -> /dev/mmcblk0 ; /dev/nvme0n1p2 -> /dev/nvme0n1 ; /dev/sda2 -> /dev/sda
  local src="$1"
  if [[ "$src" =~ ^/dev/mmcblk[0-9]+p[0-9]+$ ]]; then
    echo "${src%p*}"
  elif [[ "$src" =~ ^/dev/nvme[0-9]+n[0-9]+p[0-9]+$ ]]; then
    echo "${src%p*}"
  else
    echo "${src%[0-9]*}"
  fi
}

check_root_on_emmc_and_nvme_present() {
  local root_src root_dev
  root_src="$(root_source)"
  root_dev="$(strip_partition_suffix "$root_src")"

  log "Root filesystem source: $root_src"
  log "Root block device: $root_dev"

  if [[ "$root_dev" != /dev/mmcblk* ]]; then
    die "Root is not on an mmc device (expected eMMC/mmc). Root device: $root_dev"
  fi

  # Heuristic: eMMC devices expose /dev/mmcblkXboot0; microSD typically does not.
  if ! compgen -G "/dev/mmcblk*boot0" >/dev/null; then
    log "WARNING: Could not find /dev/mmcblk*boot0; this may be microSD rather than eMMC."
    log "If you're sure this is OK, re-run with HB_ALLOW_NON_EMMC=1"
    [[ "${HB_ALLOW_NON_EMMC:-0}" == "1" ]] || die "Aborting due to non-eMMC heuristic."
  fi

  if ! lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}' | grep -q '^nvme'; then
    if [[ "$DEBUG" == "1" ]]; then
      debug "NVMe disk not detected (expected /dev/nvme*)."
      debug "Common causes on Pi 5: PCIe disabled in config, adapter power/seat, or missing EEPROM/firmware support."
      if [[ -f /boot/firmware/config.txt ]]; then
        if ! grep -qE '^\s*dtparam=pciex1(=on)?\s*$' /boot/firmware/config.txt; then
          debug "Hint: add this to /boot/firmware/config.txt and reboot, then re-run:"
          debug "  dtparam=pciex1=on"
        fi
      fi
      if have_cmd lspci; then
        debug "Diagnostics: lspci (trimmed)"
        lspci -nn 2>/dev/null | sed -n '1,80p' >&2 || true
      else
        debug "Diagnostics: 'lspci' not found (install 'pciutils' to inspect PCIe)."
      fi
      if have_cmd dmesg; then
        debug "Diagnostics: dmesg (pcie/nvme lines)"
        dmesg 2>/dev/null | grep -Ei 'pcie|nvme' | tail -n 80 >&2 || true
      fi
    fi
    die "No NVMe disk detected (expected /dev/nvme*)."
  fi
}

pick_nvme_device() {
  local candidates
  mapfile -t candidates < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}' | grep '^/dev/nvme' || true)
  [[ "${#candidates[@]}" -gt 0 ]] || die "No NVMe disks found."

  if [[ "${#candidates[@]}" -eq 1 ]]; then
    echo "${candidates[0]}"
    return 0
  fi

  log "Multiple NVMe disks found:"
  local i
  for i in "${!candidates[@]}"; do
    echo "  [$i] ${candidates[$i]}"
  done
  local idx
  read -r -p "Select NVMe disk index to ERASE and provision: " idx
  [[ "$idx" =~ ^[0-9]+$ ]] || die "Invalid index."
  [[ "$idx" -ge 0 && "$idx" -lt "${#candidates[@]}" ]] || die "Index out of range."
  echo "${candidates[$idx]}"
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
    rpi-eeprom
}

download_image_xz() {
  local out_xz="$1"
  local url="https://downloads.raspberrypi.org/raspios_lite_arm64_latest"
  log "Downloading latest Raspberry Pi OS Lite arm64 image (.xz) from $url ..."
  wget -O "$out_xz" "$url"
}

unmount_device_partitions() {
  local dev="$1"
  # Unmount any mounted partitions for this disk.
  local mounts
  mounts="$(lsblk -nr -o MOUNTPOINT "$dev" 2>/dev/null || true)"
  if echo "$mounts" | grep -qE '.+'; then
    log "Unmounting any mounted partitions on $dev ..."
    # Use lsblk to get mounted child partitions
    while read -r mp; do
      [[ -n "$mp" ]] || continue
      umount "$mp" || true
    done < <(lsblk -nr -o MOUNTPOINT "$dev" | awk 'NF')
  fi
}

write_image_to_nvme() {
  local xz_path="$1"
  local dev="$2"

  need_cmd dd
  need_cmd xzcat
  unmount_device_partitions "$dev"

  log "Flashing image to $dev (this can take a while)..."
  # Stream-decompress to avoid storing a full .img on the boot medium.
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

find_nvme_partition() {
  local dev="$1"
  local want="$2" # "boot" or "root"
  local out=""

  # Prefer labels/partlabels found in RPi OS images: bootfs/rootfs.
  # Use lsblk -P to avoid whitespace parsing issues.
  while read -r line; do
    [[ -n "$line" ]] || continue
    # lsblk -P prints NAME="..." LABEL="..." PARTLABEL="..." (safe-ish to eval).
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

  # Fallback to partition numbering (p1/p2)
  case "$want" in
    boot) echo "${dev}p1" ;;
    root) echo "${dev}p2" ;;
  esac
}

prompt_username_password() {
  local username password
  read -r -p "Enter username to create on the NVMe OS: " username
  [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid username '$username'"
  read -r -s -p "Enter password for '$username': " password
  echo >&2
  [[ -n "$password" ]] || die "Empty password not allowed."
  echo "$username"
  echo "$password"
}

prompt_hostname() {
  local hn
  read -r -p "Enter desired hostname for the NVMe OS: " hn
  hn="${hn,,}"
  # Basic hostname validation: 1-63 chars, [a-z0-9-], no leading/trailing '-', no consecutive dots (we disallow dots).
  [[ "$hn" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "Invalid hostname '$hn' (use a-z, 0-9, and '-', max 63 chars)."
  echo "$hn"
}

wifi_scan_ssids() {
  local ssids=""
  if command -v nmcli >/dev/null 2>&1; then
    # Try hard to get a scan result. This is safe even if Wi‑Fi is already up.
    if command -v rfkill >/dev/null 2>&1; then
      rfkill unblock wifi >/dev/null 2>&1 || true
    fi
    nmcli radio wifi on >/dev/null 2>&1 || true
    nmcli dev wifi rescan >/dev/null 2>&1 || true
    sleep 2
    # --rescan yes is supported on many nmcli versions; ignore if unsupported.
    ssids="$(
      nmcli -t -f SSID dev wifi list --rescan yes 2>/dev/null \
        | sed '/^$/d' \
        | sort -u \
        || nmcli -t -f SSID dev wifi list 2>/dev/null | sed '/^$/d' | sort -u \
        || true
    )"
  fi
  if [[ -z "$ssids" ]] && command -v iw >/dev/null 2>&1; then
    # Best-effort scan; pick the first wireless interface name.
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
    log "Discovered Wi-Fi SSIDs from the current system:"
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
    log "WARNING: Could not scan Wi-Fi SSIDs (no scan results)."
    if command -v nmcli >/dev/null 2>&1; then
      log "nmcli diagnostics:"
      nmcli -t -f WIFI g 2>/dev/null >&2 || true
      nmcli -t -f DEVICE,TYPE,STATE dev status 2>/dev/null >&2 || true
    fi
    read -r -p "Enter Wi-Fi SSID to use (leave blank to skip Wi-Fi): " ssid
    if [[ -z "$ssid" ]]; then
      echo ""
      echo ""
      return 0
    fi
  fi

  if [[ -z "$ssid" ]]; then
    echo ""
    echo ""
    return 0
  fi
  [[ "$ssid" != *$'\n'* && "$ssid" != *$'\r'* ]] || die "SSID contains newline characters; refusing."
  read -r -s -p "Enter Wi-Fi password for '$ssid': " pass
  echo >&2
  [[ -n "$pass" ]] || die "Empty Wi-Fi password not allowed."
  [[ "$pass" != *$'\n'* && "$pass" != *$'\r'* ]] || die "Wi-Fi password contains newline characters; refusing."
  echo "$ssid"
  echo "$pass"
}

write_headless_config() {
  local boot_mnt="$1"
  local root_mnt="$2"
  local username="$3"
  local password="$4"
  local wifi_ssid="$5"
  local wifi_pass="$6"
  local hostname="$7"

  log "Configuring NVMe OS (SSH/user/Wi-Fi)..."

  # Enable SSH on first boot by creating an empty 'ssh' file in the boot partition root.
  : > "${boot_mnt}/ssh"

  # userconf.txt on the boot partition: username:sha512crypt(password)
  local pw_hash
  pw_hash="$(openssl passwd -6 "$password")"
  printf '%s:%s\n' "$username" "$pw_hash" > "${boot_mnt}/userconf.txt"

  # Ensure PCIe is enabled for NVMe boot (safe to append if missing).
  local cfg="${boot_mnt}/config.txt"
  if [[ -f "$cfg" ]]; then
    if ! grep -qE '^\s*dtparam=pciex1(=on)?\s*$' "$cfg"; then
      echo "dtparam=pciex1=on" >> "$cfg"
    fi
  else
    log "WARNING: Did not find config.txt on boot partition ($cfg)."
  fi

  # Wi-Fi on Bookworm uses NetworkManager; create a connection profile in rootfs.
  if [[ -n "$wifi_ssid" ]]; then
    local nm_dir="${root_mnt}/etc/NetworkManager/system-connections"
    mkdir -p "$nm_dir"

    # Sanitize filename (keep it simple).
    local nm_file
    # Use C locale to avoid tr range issues; keep '-' at the end of the set.
    nm_file="$(echo "$wifi_ssid" | LC_ALL=C tr -cd 'A-Za-z0-9._ -' | sed 's/  */ /g' | sed 's/ /_/g')"
    [[ -n "$nm_file" ]] || nm_file="wifi"
    nm_file="${nm_dir}/${nm_file}.nmconnection"

    cat > "$nm_file" <<EOF
[connection]
id=${wifi_ssid}
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=${wifi_ssid}

[wifi-security]
key-mgmt=wpa-psk
psk=${wifi_pass}

[ipv4]
method=auto

[ipv6]
method=auto
EOF

    chmod 600 "$nm_file"
    chown root:root "$nm_file"
  fi

  # Hostname for the installed system.
  if [[ -n "$hostname" ]]; then
    echo "$hostname" > "${root_mnt}/etc/hostname"
    if [[ -f "${root_mnt}/etc/hosts" ]]; then
      # Replace common 127.0.1.1 hostname line if present, else append.
      if grep -qE '^\s*127\.0\.1\.1\s+' "${root_mnt}/etc/hosts"; then
        sed -i -E "s/^\s*127\.0\.1\.1\s+.*/127.0.1.1\t${hostname}/" "${root_mnt}/etc/hosts"
      else
        printf '\n127.0.1.1\t%s\n' "$hostname" >> "${root_mnt}/etc/hosts"
      fi
    else
      log "WARNING: ${root_mnt}/etc/hosts not found; hostname may not fully apply."
    fi
  fi
}

mount_nvme_partitions_for_config() {
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

set_eeprom_boot_to_nvme() {
  # Best-effort non-interactive edit using EDITOR trick; falls back with instructions if it fails.
  need_cmd rpi-eeprom-update
  need_cmd rpi-eeprom-config

  log "Updating EEPROM package + applying latest EEPROM update (if available)..."
  rpi-eeprom-update -a || true

  log "Setting EEPROM BOOT_ORDER to prefer NVMe (BOOT_ORDER=0xf416) and PCIE_PROBE=1 ..."

  local editor="/tmp/hb_rpi_eeprom_editor.sh"
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

ensure_kv "BOOT_ORDER" "0xf416"
ensure_kv "PCIE_PROBE" "1"
EOF
  chmod +x "$editor"

  # Try common flags; different versions use --edit or -e.
  if EDITOR="$editor" rpi-eeprom-config --edit >/dev/null 2>&1; then
    :
  elif EDITOR="$editor" rpi-eeprom-config -e >/dev/null 2>&1; then
    :
  else
    log "WARNING: Could not non-interactively edit EEPROM config."
    log "You can run manually:"
    log "  sudo rpi-eeprom-config -e"
    log "and set:"
    log "  BOOT_ORDER=0xf416"
    log "  PCIE_PROBE=1"
  fi
}

main() {
  require_root
  need_cmd lsblk
  need_cmd awk
  need_cmd grep
  need_cmd sed

  # Always prompt for Wi-Fi first, then verify internet before we do any installs/downloads.
  local wifi_ssid="" wifi_pass=""
  log "Starting Wi-Fi selection (needed for downloads unless you already have internet via ethernet)."
  {
    read -r wifi_ssid
    read -r wifi_pass
  } < <(prompt_wifi)

  # If user skipped Wi-Fi, require that internet is already working (e.g. ethernet).
  if [[ -n "$wifi_ssid" ]]; then
    connect_wifi_current "$wifi_ssid" "$wifi_pass"
  fi
  if ! have_internet; then
    die "No internet connectivity. Provide Wi-Fi credentials (or connect ethernet) and re-run."
  fi
  # If the user provided Wi-Fi, connect_wifi_current already verified internet & route.
  # If they skipped Wi-Fi, they might be on ethernet; allow that.
  log "Internet connectivity verified."

  check_bookworm_or_later
  check_root_on_emmc_and_nvme_present

  local nvme_dev
  nvme_dev="$(pick_nvme_device)"
  [[ -b "$nvme_dev" ]] || die "Not a block device: $nvme_dev"

  confirm_erase_device "$nvme_dev"

  local hostname
  hostname="$(prompt_hostname)"

  install_packages

  local xz_path="/tmp/raspios_lite_arm64_latest.img.xz"
  download_image_xz "$xz_path"
  write_image_to_nvme "$xz_path" "$nvme_dev"

  wait_for_partitions "$nvme_dev"
  local boot_part root_part
  boot_part="$(find_nvme_partition "$nvme_dev" boot)"
  root_part="$(find_nvme_partition "$nvme_dev" root)"

  [[ -b "$boot_part" ]] || die "Boot partition not found: $boot_part"
  [[ -b "$root_part" ]] || die "Root partition not found: $root_part"

  log "NVMe boot partition: $boot_part"
  log "NVMe root partition: $root_part"

  HB_BOOT_MNT="/mnt/hb_nvme_boot"
  HB_ROOT_MNT="/mnt/hb_nvme_root"
  trap 'cleanup_mounts "${HB_BOOT_MNT:-}" "${HB_ROOT_MNT:-}"' EXIT
  mount_nvme_partitions_for_config "$boot_part" "$root_part" "$HB_BOOT_MNT" "$HB_ROOT_MNT"

  local username password
  {
    read -r username
    read -r password
  } < <(prompt_username_password)

  write_headless_config "$HB_BOOT_MNT" "$HB_ROOT_MNT" "$username" "$password" "$wifi_ssid" "$wifi_pass" "$hostname"

  cleanup_mounts "$HB_BOOT_MNT" "$HB_ROOT_MNT"
  trap - EXIT

  set_eeprom_boot_to_nvme

  log "Provisioning complete. Rebooting in 5 seconds..."
  sleep 5
  reboot
}

main "$@"

