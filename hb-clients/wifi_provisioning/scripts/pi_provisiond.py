#!/usr/bin/env python3
"""
pi_provisiond: setup-mode daemon for guest Wi-Fi + captive portal provisioning.

Responsibilities:
- Bring up a setup AP on a virtual interface (default: ap0) while STA uses wlan0
- Provide a minimal local web UI/API to scan/connect Wi-Fi and open captive portal
- Apply scoped nftables NAT/forwarding rules from ap0 -> wlan0
- Prefer wlan0 routing during setup via route metrics (so portal clears on Wi-Fi)
- Detect "internet open" via HTTP 204 connectivity check and tear down setup mode
"""

from __future__ import annotations

import os
import pathlib
import subprocess
import sys
import threading
import time
from dataclasses import dataclass

from flask import Flask, jsonify, request


def log(msg: str) -> None:
    print(f"[pi-provisiond] {msg}", flush=True)


def env_bool(name: str, default: bool) -> bool:
    v = os.environ.get(name)
    if v is None:
        return default
    return v.strip().lower() in ("1", "true", "yes", "y", "on")


def env_int(name: str, default: int) -> int:
    v = os.environ.get(name)
    if v is None or not v.strip():
        return default
    return int(v)


def env_float(name: str, default: float) -> float:
    v = os.environ.get(name)
    if v is None or not v.strip():
        return default
    return float(v)


@dataclass(frozen=True)
class Config:
    wlan_if: str = os.environ.get("WLAN_IF", "wlan0")
    ap_if: str = os.environ.get("AP_IF", "ap0")

    setup_ssid: str = os.environ.get("SETUP_SSID", "Pi-Setup")
    setup_psk: str = os.environ.get("SETUP_PSK", "setup1234")
    ap_con_name: str = os.environ.get("AP_CON_NAME", "SetupAP")

    # UI port for the daemon itself. We default to 8080 because many images already
    # run nginx/lighttpd on :80 (and we can proxy :80 -> :8080 for a friendly UX).
    http_port: int = env_int("HTTP_PORT", 8080)

    # Port that captive clients will be redirected to (usually 80 on the AP gateway).
    # If nginx is present, it should listen on this port and proxy to HTTP_PORT.
    captive_http_port: int = env_int("CAPTIVE_HTTP_PORT", 80)

    # "Shared" mode gateway IP is commonly 10.42.0.1 on NetworkManager. Some NM builds
    # ignore custom addresses in shared mode; treat this as a best-effort preference.
    ap_ipv4_cidr: str = os.environ.get("AP_IPV4_CIDR", "10.42.0.1/24")

    # Optional: force AP band/channel for maximum phone compatibility.
    # Examples:
    #   AP_FORCE_BAND=bg
    #   AP_FORCE_CHANNEL=6
    ap_force_band: str = os.environ.get("AP_FORCE_BAND", "").strip()
    ap_force_channel: str = os.environ.get("AP_FORCE_CHANNEL", "").strip()

    # Route metrics during setup: prefer Wi-Fi so captive portal clearance happens on wlan0.
    wifi_metric: int = env_int("WIFI_METRIC", 100)
    eth_metric: int = env_int("ETH_METRIC", 600)
    eth_con_name: str = os.environ.get("ETH_CON_NAME", "")  # optional; auto-detect if empty
    wifi_con_name: str = os.environ.get("WIFI_CON_NAME", "")  # optional; auto-detect if empty

    # Connectivity check (HTTP 204 when open).
    check_url: str = os.environ.get(
        "CHECK_URL", "http://connectivitycheck.gstatic.com/generate_204"
    )
    check_interval_s: float = env_float("CHECK_INTERVAL", 3.0)
    required_successes: int = env_int("REQUIRED_SUCCESSES", 3)

    # Behavior:
    auto_teardown: bool = env_bool("AUTO_TEARDOWN", True)
    exit_on_online: bool = env_bool("EXIT_ON_ONLINE", False)

    # Optional: write a marker when provisioned.
    provisioned_marker: str = os.environ.get(
        "PROVISIONED_MARKER", "/var/lib/pi-provisiond/provisioned"
    )

    # Shipping default: once provisioned, don't bring up the setup AP again.
    # To force setup mode (for re-provisioning / debugging), set FORCE_SETUP=1.
    force_setup: bool = env_bool("FORCE_SETUP", False)
    skip_if_provisioned: bool = env_bool("SKIP_IF_PROVISIONED", True)

    # If true, fail startup if the AP interface does not report AP mode after NM activates it.
    # Some drivers report confusing types; default is warn-only.
    strict_ap_mode: bool = env_bool("STRICT_AP_MODE", False)


cfg = Config()
app = Flask(__name__)

state = {
    "mode": "starting",  # starting | setup | provisioning | online | error
    "last_error": "",
    "internet_open": False,
    "success_streak": 0,
    "last_internet_check_http_code": "",
}


def run(cmd: list[str], check: bool = True) -> str:
    p = subprocess.run(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
    )
    if check and p.returncode != 0:
        raise RuntimeError(f"cmd failed ({p.returncode}): {' '.join(cmd)}\n{p.stdout}")
    return p.stdout


def run_sh(cmd: str, check: bool = True) -> str:
    # Used only for nft heredoc convenience; keep usage minimal.
    p = subprocess.run(
        cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
    )
    if check and p.returncode != 0:
        raise RuntimeError(f"cmd failed ({p.returncode}): {cmd}\n{p.stdout}")
    return p.stdout


def iface_exists(ifname: str) -> bool:
    out = run(["iw", "dev"], check=False)
    return f"Interface {ifname}" in out


def iface_type(ifname: str) -> str:
    """
    Best-effort parse of `iw dev` to return the interface type (e.g. managed, AP, __ap).
    Returns empty string if unknown/not found.
    """
    out = run(["iw", "dev"], check=False)
    lines = out.splitlines()
    for i, line in enumerate(lines):
        if line.strip() == f"Interface {ifname}":
            # look ahead a few lines for the `type ...` stanza
            for j in range(i + 1, min(i + 12, len(lines))):
                s = lines[j].strip()
                if s.startswith("type "):
                    return s.split(" ", 1)[1].strip()
            return ""
    return ""


def nm_active_con_for_device(dev: str) -> str:
    out = run(["nmcli", "-t", "-f", "DEVICE,CONNECTION", "device", "status"], check=False)
    for line in out.splitlines():
        if not line.strip():
            continue
        device, con = (line.split(":", 1) + [""])[:2]
        if device == dev:
            return con.strip()
    return ""


def nm_find_active_ethernet_connection() -> str:
    # Best-effort: pick the active connection for eth0 if present, else any ethernet device.
    out = run(["nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device", "status"], check=False)
    eth_candidates: list[tuple[str, str]] = []
    for line in out.splitlines():
        parts = (line.split(":", 3) + ["", "", "", ""])[:4]
        dev, typ, st, con = [p.strip() for p in parts]
        if typ == "ethernet" and st.lower() == "connected" and con and con != "--":
            eth_candidates.append((dev, con))
    for dev, con in eth_candidates:
        if dev == "eth0":
            return con
    return eth_candidates[0][1] if eth_candidates else ""


def ensure_ip_forwarding() -> None:
    run(["sysctl", "-w", "net.ipv4.ip_forward=1"], check=False)
    run(["mkdir", "-p", "/etc/sysctl.d"], check=False)
    run_sh("bash -lc 'echo net.ipv4.ip_forward=1 > /etc/sysctl.d/99-ipforward.conf'", check=False)


def apply_setup_nft() -> None:
    # Scoped ruleset: remove only our tables on teardown.
    rules = f"""
table ip setupnat {{
  chain prerouting {{
    type nat hook prerouting priority -100; policy accept;
    iifname "{cfg.ap_if}" udp dport 53 redirect to :53
    iifname "{cfg.ap_if}" tcp dport 53 redirect to :53

    # Captive-portal friendliness: force all HTTP from setup clients to the AP gateway
    # web server (usually :80). That server can proxy to the daemon.
    iifname "{cfg.ap_if}" tcp dport 80 redirect to :{cfg.captive_http_port}
  }}
  chain postrouting {{
    type nat hook postrouting priority 100; policy accept;
    oifname "{cfg.wlan_if}" masquerade
  }}
}}

table inet setup {{
  chain forward {{
    type filter hook forward priority 0; policy drop;
    ct state established,related accept
    iifname "{cfg.ap_if}" oifname "{cfg.wlan_if}" accept
    iifname "{cfg.wlan_if}" oifname "{cfg.ap_if}" accept
  }}
}}
"""
    run_sh("nft -f - <<'EOF'\n" + rules + "\nEOF", check=True)


def remove_setup_nft() -> None:
    run(["nft", "delete", "table", "inet", "setup"], check=False)
    run(["nft", "delete", "table", "ip", "setupnat"], check=False)


def set_route_metrics_setup_mode() -> None:
    try:
        wifi_con = cfg.wifi_con_name or nm_active_con_for_device(cfg.wlan_if)
        eth_con = cfg.eth_con_name or nm_find_active_ethernet_connection()

        if wifi_con and wifi_con != "--":
            run(["nmcli", "connection", "modify", wifi_con, "ipv4.route-metric", str(cfg.wifi_metric)], check=False)
        if eth_con and eth_con != "--":
            run(["nmcli", "connection", "modify", eth_con, "ipv4.route-metric", str(cfg.eth_metric)], check=False)

        # Bounce to apply quickly. Safe even if already down.
        if wifi_con and wifi_con != "--":
            run(["nmcli", "connection", "down", wifi_con], check=False)
            run(["nmcli", "connection", "up", wifi_con], check=False)
        if eth_con and eth_con != "--":
            run(["nmcli", "connection", "down", eth_con], check=False)
            run(["nmcli", "connection", "up", eth_con], check=False)
    except Exception as e:
        # Not fatal, but important for captive correctness.
        state["last_error"] = f"route metrics: {e}"


def ap_channel_and_band_from_wlan() -> tuple[str, str]:
    """
    Try to match AP to STA channel/band on single-radio devices.
    Returns (band, channel) where band is 'bg' (2.4GHz) or 'a' (5GHz).
    """
    out = run(["iw", "dev", cfg.wlan_if, "info"], check=False)
    ch = ""
    mhz = 0
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("channel "):
            # "channel 6 (2437 MHz), width: 20 MHz, center1: 2437 MHz"
            try:
                ch = s.split()[1]
                mhz = int(s.split("(")[1].split()[0])
            except Exception:
                pass
    if not ch:
        return ("bg", "6")
    if mhz >= 4900:
        return ("a", ch)
    return ("bg", ch)


def wait_for_nm_device(dev: str, timeout_s: float = 3.0) -> None:
    """
    Best-effort wait for NetworkManager to notice a newly created interface.
    Avoids a race where `nmcli connection up` runs before NM has the device.
    """
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        out = run(["nmcli", "-t", "-f", "DEVICE", "device", "status"], check=False)
        if any(line.strip() == dev for line in out.splitlines() if line.strip()):
            return
        time.sleep(0.1)


def ensure_ap_interface() -> None:
    # We require ap_if to be an AP-capable virtual iface. If an iface already exists
    # with the right name but wrong type (common when a previous attempt created it
    # incorrectly), delete and recreate it.
    if iface_exists(cfg.ap_if):
        t = iface_type(cfg.ap_if).lower()
        # `iw` usually reports AP ifaces as `AP`. Keep this conservative: if it's not
        # clearly AP-ish, recreate.
        if t and t not in ("ap", "__ap"):
            log(f"Interface {cfg.ap_if} exists but iw reports type={t}; deleting and recreating as __ap")
            run(["iw", "dev", cfg.ap_if, "del"], check=False)
        else:
            return

    def _create() -> None:
        run(["iw", "dev", cfg.wlan_if, "interface", "add", cfg.ap_if, "type", "__ap"], check=True)
        run(["nmcli", "device", "set", cfg.ap_if, "managed", "yes"], check=False)

    log(f"Creating AP interface {cfg.ap_if} from {cfg.wlan_if}...")
    _create()

    # Note: On many systems the interface type only flips to "AP" once NetworkManager
    # (wpa_supplicant) activates the hotspot. So we do not hard-fail here if `iw` still
    # reports "managed". We'll validate (optionally) after NM activation instead.
    t_after = iface_type(cfg.ap_if).lower()
    if t_after and t_after not in ("ap", "__ap"):
        log(
            f"After creating {cfg.ap_if}, iw reports type={t_after}. "
            "This can be normal until the hotspot is activated; continuing."
        )

    # Give NetworkManager a moment to notice the new interface before binding a connection to it.
    wait_for_nm_device(cfg.ap_if, timeout_s=3.0)


def ensure_ap_connection() -> None:
    # Ensure a known connection name exists in NM for the AP.
    out = run(["nmcli", "-t", "-f", "NAME", "connection", "show"], check=True)
    if cfg.ap_con_name not in out.splitlines():
        run(
            [
                "nmcli",
                "connection",
                "add",
                "type",
                "wifi",
                "ifname",
                cfg.ap_if,
                "con-name",
                cfg.ap_con_name,
                "ssid",
                cfg.setup_ssid,
            ],
            check=True,
        )

    if cfg.ap_force_band and cfg.ap_force_channel:
        band, chan = (cfg.ap_force_band, cfg.ap_force_channel)
        log(f"Forcing AP band/channel to {band}/{chan}")
    else:
        band, chan = ap_channel_and_band_from_wlan()

    base_args = [
        "nmcli",
        "connection",
        "modify",
        cfg.ap_con_name,
        "802-11-wireless.mode",
        "ap",
        "ipv4.method",
        "shared",
        "ipv4.addresses",
        cfg.ap_ipv4_cidr,
        "wifi-sec.key-mgmt",
        "wpa-psk",
        "wifi-sec.psk",
        cfg.setup_psk,
    ]

    # Prefer matching STA band/channel (single-radio friendliness), but fall back if NM rejects it.
    out = run(
        base_args
        + [
            "802-11-wireless.band",
            band,
            "802-11-wireless.channel",
            chan,
        ],
        check=False,
    )
    if "failed to modify 802-11-wireless.channel" in out.lower():
        log(f"WARNING: NM rejected AP channel {chan} (band={band}). Falling back to 2.4GHz ch6.")
        run(
            base_args
            + [
                "802-11-wireless.band",
                "bg",
                "802-11-wireless.channel",
                "6",
            ],
            check=True,
        )
    elif out and "error:" in out.lower():
        raise RuntimeError(f"nmcli modify AP connection failed:\n{out}")


def bring_up_ap() -> None:
    log("Bringing up setup AP via NetworkManager...")
    ensure_ap_interface()
    ensure_ap_connection()
    run(["nmcli", "connection", "up", cfg.ap_con_name], check=True)

    # After activation, confirm interface mode and warn if it's not AP.
    t = iface_type(cfg.ap_if).lower()
    if t and t not in ("ap", "__ap"):
        msg = (
            f"Hotspot connection is up, but iw reports {cfg.ap_if} type={t}. "
            "If your phone can't see the SSID, the driver likely can't do AP mode (or AP+STA). "
            "Try using a USB Wi‑Fi adapter for the setup AP."
        )
        if cfg.strict_ap_mode:
            raise RuntimeError(msg)
        log("WARNING: " + msg)

    # Validate AP came up (helps catch driver/capability issues early with a clear error).
    active = run(["nmcli", "-t", "-f", "NAME,DEVICE", "connection", "show", "--active"], check=False)
    if f"{cfg.ap_con_name}:{cfg.ap_if}" not in active:
        diag = "\n".join(
            [
                "=== nmcli device status ===",
                run(["nmcli", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device", "status"], check=False).strip(),
                "=== nmcli active connections ===",
                active.strip(),
                "=== iw dev ===",
                run(["iw", "dev"], check=False).strip(),
                "=== ip -4 addr ap_if ===",
                run(["ip", "-4", "addr", "show", cfg.ap_if], check=False).strip(),
            ]
        )
        raise RuntimeError(
            f"AP failed to come up (connection '{cfg.ap_con_name}' on '{cfg.ap_if}').\n{diag}\n"
            "Try: `sudo nmcli connection up SetupAP` manually to see the specific NetworkManager error."
        )
    log("Setup AP is active.")


def bring_down_ap() -> None:
    run(["nmcli", "connection", "down", cfg.ap_con_name], check=False)


def scan_wifi() -> list[dict]:
    out = run(
        [
            "nmcli",
            "-t",
            "-f",
            "SSID,SECURITY,SIGNAL",
            "device",
            "wifi",
            "list",
            "ifname",
            cfg.wlan_if,
        ],
        check=False,
    )
    if out.strip().lower().startswith("error:"):
        raise RuntimeError(out.strip())
    nets: list[dict] = []
    for line in out.splitlines():
        if not line.strip():
            continue
        parts = line.split(":", 2)
        ssid = (parts[0] if len(parts) > 0 else "").strip()
        sec = (parts[1] if len(parts) > 1 else "").strip()
        sig = (parts[2] if len(parts) > 2 else "").strip()
        if ssid:
            nets.append({"ssid": ssid, "security": sec, "signal": sig})

    # Deduplicate by SSID, keep strongest.
    best: dict[str, dict] = {}
    for n in nets:
        try:
            s = int(n.get("signal") or 0)
        except Exception:
            s = 0
        if n["ssid"] not in best:
            best[n["ssid"]] = n
            continue
        try:
            prev = int(best[n["ssid"]].get("signal") or 0)
        except Exception:
            prev = 0
        if s > prev:
            best[n["ssid"]] = n

    return sorted(best.values(), key=lambda x: int(x.get("signal") or 0), reverse=True)


def connect_wifi(ssid: str, password: str) -> str:
    args = ["nmcli", "device", "wifi", "connect", ssid, "ifname", cfg.wlan_if]
    if password:
        args += ["password", password]
    return run(args, check=True)


def check_internet_open() -> tuple[bool, str]:
    # Bind to wlan0; 204 is canonical "internet open" signal.
    out = run(
        [
            "curl",
            "--interface",
            cfg.wlan_if,
            "-s",
            "-o",
            "/dev/null",
            "-w",
            "%{http_code}",
            cfg.check_url,
        ],
        check=False,
    ).strip()
    return (out == "204", out)


def write_provisioned_marker() -> None:
    try:
        p = pathlib.Path(cfg.provisioned_marker)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(f"online_at={int(time.time())}\n", encoding="utf-8")
    except Exception:
        pass


def is_provisioned() -> bool:
    try:
        return pathlib.Path(cfg.provisioned_marker).exists()
    except Exception:
        return False


def monitor_loop() -> None:
    state["mode"] = "setup"
    while True:
        try:
            ok, code = check_internet_open()
            state["internet_open"] = ok
            state["last_internet_check_http_code"] = code
            state["success_streak"] = state["success_streak"] + 1 if ok else 0

            if ok and state["success_streak"] >= cfg.required_successes:
                if state["mode"] != "online":
                    state["mode"] = "online"
                    write_provisioned_marker()
                    if cfg.auto_teardown:
                        bring_down_ap()
                        remove_setup_nft()
                if cfg.exit_on_online:
                    os._exit(0)
            else:
                if state["mode"] != "provisioning":
                    state["mode"] = "setup"
        except Exception as e:
            state["last_error"] = str(e)
            state["mode"] = "error"

        time.sleep(cfg.check_interval_s)


@app.get("/")
def index():
    return f"""<!doctype html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Device Setup</title>
</head>
<body style="font-family: system-ui, sans-serif; max-width: 720px; margin: 24px auto; padding: 0 12px;">
  <h2>Device Wi‑Fi Setup</h2>
  <p><b>Setup AP SSID:</b> {cfg.setup_ssid}</p>
  <p><b>Setup URL:</b> <a href="/">http://{cfg.ap_ipv4_cidr.split('/')[0]}/</a></p>
  <p><b>Status:</b> <span id="st">loading…</span></p>

  <button onclick="scan()">Scan Networks</button>
  <div id="nets" style="margin-top:12px;"></div>

  <hr/>
  <h3>Connect</h3>
  <p style="color:#444; line-height:1.35">
    Note: on some single-radio devices, your phone may briefly disconnect from the setup SSID when the device
    joins the target Wi‑Fi (especially if the target network is 5GHz-only). If that happens, rejoin the setup SSID
    and reopen this page.
  </p>
  <label>SSID</label><br/>
  <input id="ssid" style="width:100%"><br/><br/>
  <label>Password (leave blank for open)</label><br/>
  <input id="pw" type="password" style="width:100%"><br/><br/>
  <button onclick="connect()">Connect</button>

  <hr/>
  <h3>Captive Portal</h3>
  <p>After connecting, use your phone browser to accept the guest portal:</p>
  <button onclick="window.location='http://1.1.1.1'">Open Portal (1.1.1.1)</button>
  <button onclick="window.location='http://example.com'">Open Portal (example.com)</button>

  <pre id="out" style="white-space:pre-wrap;margin-top:12px;"></pre>

  <script>
    async function refresh() {{
      const r = await fetch('/status');
      const j = await r.json();
      document.getElementById('st').textContent =
        `${{j.mode}} | internet_open=${{j.internet_open}} | streak=${{j.success_streak}} | last_code=${{j.last_internet_check_http_code}}`;
    }}
    async function scan() {{
      const outEl = document.getElementById('out');
      outEl.textContent = 'Scanning… (may take ~10s)';
      try {{
        const r = await fetch('/scan', {{ cache: 'no-store' }});
        const j = await r.json();
        if (!r.ok) {{
          throw new Error(j && j.error ? j.error : `scan failed (HTTP ${{r.status}})`);
        }}
        const nets = j;
        const div = document.getElementById('nets');
        div.innerHTML = '';
        for (const n of nets) {{
          const b = document.createElement('button');
          b.textContent = `${{n.ssid}}  (${{n.security||'open'}}  ${{n.signal||''}})`;
          b.style.display='block'; b.style.width='100%'; b.style.marginTop='6px';
          b.onclick = () => document.getElementById('ssid').value = n.ssid;
          div.appendChild(b);
        }}
        outEl.textContent = `Scan complete. Found ${{nets.length}} network(s).`;
      }} catch (e) {{
        outEl.textContent = `Scan error: ${{e && e.message ? e.message : e}}`;
      }}
    }}
    async function connect() {{
      const ssid = document.getElementById('ssid').value;
      const password = document.getElementById('pw').value;
      document.getElementById('out').textContent = 'Connecting…';
      const r = await fetch('/connect', {{
        method:'POST',
        headers:{{'Content-Type':'application/json'}},
        body: JSON.stringify({{ssid, password}})
      }});
      const j = await r.json();
      document.getElementById('out').textContent = JSON.stringify(j, null, 2);
    }}
    setInterval(refresh, 2000);
    refresh();
  </script>
</body>
</html>
"""


@app.get("/generate_204")
def android_generate_204():
    # Android captive portal check. Redirecting to "/" usually lands the user on our
    # setup page without an extra click.
    return ("", 302, {"Location": "/", "Cache-Control": "no-store"})


@app.get("/hotspot-detect.html")
def apple_hotspot_detect():
    # iOS/macOS captive portal check. Redirecting to "/" typically opens our setup UI.
    return ("", 302, {"Location": "/", "Cache-Control": "no-store"})


@app.get("/scan")
def api_scan():
    try:
        return jsonify(scan_wifi())
    except Exception as e:
        state["last_error"] = str(e)
        return jsonify({"status": "error", "error": str(e)}), 500


@app.post("/connect")
def api_connect():
    data = request.get_json(force=True) or {}
    ssid = (data.get("ssid") or "").strip()
    password = data.get("password") or ""
    if not ssid:
        return jsonify({"status": "error", "error": "missing ssid"}), 400

    try:
        state["mode"] = "provisioning"
        out = connect_wifi(ssid, password)

        # After connecting, re-tune AP channel/band to match STA, then bounce AP.
        ensure_ap_connection()
        run(["nmcli", "connection", "down", cfg.ap_con_name], check=False)
        run(["nmcli", "connection", "up", cfg.ap_con_name], check=False)

        state["mode"] = "setup"
        return jsonify({"status": "ok", "nmcli": out})
    except Exception as e:
        state["last_error"] = str(e)
        state["mode"] = "error"
        return jsonify({"status": "error", "error": str(e)}), 500


@app.get("/internet")
def api_internet():
    ok, code = check_internet_open()
    return jsonify({"internet_open": ok, "http_code": code})


@app.get("/status")
def api_status():
    routes = run(["ip", "route"], check=False)
    devs = run(["nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device", "status"], check=False)
    return jsonify(
        {
            **state,
            "routes": routes,
            "devices": devs,
            "wlan_if": cfg.wlan_if,
            "ap_if": cfg.ap_if,
            "setup_ssid": cfg.setup_ssid,
            "http_port": cfg.http_port,
            "check_url": cfg.check_url,
        }
    )


def bootstrap() -> None:
    # If we've already provisioned successfully in the past, don't re-enter setup mode
    # (unless explicitly forced). This prevents the AP from flapping on every boot.
    if cfg.skip_if_provisioned and not cfg.force_setup and is_provisioned():
        state["mode"] = "online"
        state["internet_open"] = True
        log(
            f"Provisioned marker found at {cfg.provisioned_marker}; skipping setup AP. "
            "(Set FORCE_SETUP=1 or delete the marker to re-enter setup.)"
        )
        # Use a normal exit so stdout is flushed to journald.
        sys.exit(0)

    log("Bootstrapping setup mode...")
    ensure_ip_forwarding()
    set_route_metrics_setup_mode()
    bring_up_ap()
    apply_setup_nft()
    log("Setup mode initialized (AP + nftables).")


def main() -> None:
    bootstrap()
    t = threading.Thread(target=monitor_loop, daemon=True)
    t.start()
    app.run(host="0.0.0.0", port=cfg.http_port)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        state["last_error"] = str(e)
        state["mode"] = "error"
        raise

