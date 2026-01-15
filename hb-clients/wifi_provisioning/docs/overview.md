# Overview

This folder provides a **production-shaped “setup mode”** for a Raspberry Pi (or similar Linux device) to join a **guest Wi‑Fi with a captive portal**.

At a high level:

- The Pi brings up a temporary **setup access point** (AP) so a phone can connect.
- A tiny local web UI lets the user **scan** and **connect** the Pi to the target SSID.
- The phone then opens the captive portal **through the Pi** (NAT from setup AP → Wi‑Fi STA).
- The daemon polls a connectivity check URL expecting **HTTP 204** to detect when the portal is cleared.
- Once it sees enough consecutive 204s, it **tears down** the setup AP and removes the setup firewall/NAT rules.

Key implementation choices:

- **NetworkManager** is the control plane (`nmcli`) for AP + STA.
- **nftables** rules are scoped to dedicated tables (`inet setup`, `ip setupnat`) so teardown doesn’t touch other firewall rules.
- **Route metrics** are set during setup so the default route prefers `wlan0` (important when Ethernet is present).

