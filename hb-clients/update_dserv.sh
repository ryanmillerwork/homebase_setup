#!/usr/bin/env bash
set -euo pipefail

# Optional: export VERSION=v0.8.5 to pin a specific release (with or without the leading v)
: "${VERSION:=}"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

get_latest_url() {
  local api_url="https://api.github.com/repos/SheinbergLab/dserv/releases/latest"
  local body
  if have_cmd curl; then
    body="$(curl -s "$api_url")"
  elif have_cmd wget; then
    body="$(wget -qO- "$api_url")"
  else
    echo "Need curl or wget installed." >&2
    return 1
  fi

  echo "$body" \
    | grep -m 1 -oE '"browser_download_url":\s*"[^"]*arm64\.deb"' \
    | sed -E 's/.*"([^"]+)".*/\1/'
}

main() {
  TMPDIR="$(mktemp -d)"
  cd "$TMPDIR"

  local download_url deb_name
  if [[ -n "$VERSION" ]]; then
    ver="${VERSION#v}"
    download_url="https://github.com/SheinbergLab/dserv/releases/download/${ver}/dserv_${ver}_arm64.deb"
  else
    if ! download_url="$(get_latest_url)"; then
      echo "Could not determine latest arm64 .deb" >&2
      exit 1
    fi
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
  sudo apt-get install -y "./$deb_name"

  echo "Enabling & restarting dserv..."
  sudo systemctl daemon-reload
  sudo systemctl enable dserv
  sudo systemctl restart dserv

  echo "Status:"
  sudo systemctl status --no-pager dserv
}

main "$@"
