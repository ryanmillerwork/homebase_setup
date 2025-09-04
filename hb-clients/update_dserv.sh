#!/usr/bin/env bash
set -euo pipefail

# Optional: export VERSION=v0.8.5 to pin a specific release (with or without the leading v)
: "${VERSION:=}"
# Optional: set to 1 to allow downgrades explicitly
: "${FORCE_DOWNGRADE:=0}"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

get_latest_url() {
  local api_url="https://api.github.com/repos/SheinbergLab/dserv/releases/latest"
  local body

  if have_cmd curl; then
    body="$(curl -sL \
      -H 'Accept: application/vnd.github+json' \
      -H 'User-Agent: dserv-updater' \
      "$api_url")"
  elif have_cmd wget; then
    body="$(wget -qO- "$api_url")"
  else
    echo "Need curl or wget installed." >&2
    return 1
  fi

  echo "$body" \
    | grep -m1 -oE '"browser_download_url":\s*"[^"]*arm64\.deb"' \
    | sed -E 's/.*"([^"]+)".*/\1/'
}

pkg_installed_version() {
  dpkg-query -W -f='${Version}\n' dserv 2>/dev/null || true
}

version_from_url() {
  # Extracts the X.Y.Z part from .../dserv_X.Y.Z_arm64.deb
  echo "$1" | sed -nE 's#.*/dserv_([0-9][^_/]*)_arm64\.deb#\1#p'
}

main() {
  TMPDIR="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR"' EXIT
  cd "$TMPDIR"

  local download_url ver target_ver installed_ver deb_name
  if [[ -n "$VERSION" ]]; then
    ver="${VERSION#v}"
    download_url="https://github.com/SheinbergLab/dserv/releases/download/${ver}/dserv_${ver}_arm64.deb"
    target_ver="$ver"
  else
    download_url="$(get_latest_url || true)"
    if [[ -z "${download_url:-}" ]]; then
      echo "Could not determine latest arm64 .deb" >&2
      exit 1
    fi
    target_ver="$(version_from_url "$download_url")"
    if [[ -z "$target_ver" ]]; then
      echo "Could not parse version from download URL: $download_url" >&2
      exit 1
    fi
  fi

  installed_ver="$(pkg_installed_version || true)"

  if [[ -n "$installed_ver" ]]; then
    if dpkg --compare-versions "$installed_ver" eq "$target_ver"; then
      echo "dserv is already at $installed_ver; nothing to do."
      exit 0
    elif dpkg --compare-versions "$installed_ver" gt "$target_ver"; then
      if [[ "$FORCE_DOWNGRADE" != "1" ]]; then
        echo "Installed version ($installed_ver) is NEWER than target ($target_ver)."
        echo "Refusing to downgrade automatically."
        echo "If you really want to downgrade, re-run with FORCE_DOWNGRADE=1"
        echo "Example: FORCE_DOWNGRADE=1 $0"
        exit 1
      else
        echo "WARNING: Proceeding with downgrade from $installed_ver -> $target_ver (FORCE_DOWNGRADE=1)."
      fi
    else
      echo "Upgrading dserv $installed_ver -> $target_ver"
    fi
  else
    echo "dserv not installed; will install $target_ver"
  fi

  deb_name="$(basename "$download_url")"

  echo "Stopping dserv if running..."
  if systemctl is-active --quiet dserv; then
    sudo systemctl stop dserv
  fi

  echo "Downloading $download_url ..."
  if have_cmd wget; then
    wget -qO "$deb_name" "$download_url"
  else
    curl -L -o "$deb_name" "$download_url"
  fi

  echo "Installing $deb_name ..."
  sudo apt-get update -y || true
  if [[ "$FORCE_DOWNGRADE" == "1" ]]; then
    sudo apt-get install -y --allow-downgrades "./$deb_name"
  else
    sudo apt-get install -y "./$deb_name"
  fi

  echo "Enabling & restarting dserv..."
  sudo systemctl daemon-reload
  sudo systemctl enable dserv
  sudo systemctl restart dserv

  echo "Status:"
  sudo systemctl status --no-pager dserv
}

main "$@"
