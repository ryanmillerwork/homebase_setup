#!/usr/bin/env python3
"""
Provisioning wizard - Tkinter GUI for collecting NVMe provisioning answers.

This mirrors the interactive questions currently asked by
provision/full_provision_nvme.sh, using the same touch-friendly style as the
original test wizard. It only collects answers for now; the shell integration
can read the JSON output in a later step.
"""

import argparse
import configparser
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tkinter as tk
from tkinter import messagebox


# ---- Theme / sizing ----
BG = "#1e1e2e"
FG = "#cdd6f4"
ACCENT = "#89b4fa"
ACCENT_ACTIVE = "#74a0e8"
ENTRY_BG = "#313244"
ERROR = "#f38ba8"
MUTED = "#a6adc8"

FONT_TITLE = ("DejaVu Sans", 22, "bold")
FONT_LABEL = ("DejaVu Sans", 14)
FONT_INPUT = ("DejaVu Sans", 16)
FONT_BTN = ("DejaVu Sans", 14, "bold")

DEFAULT_WIFI_COUNTRY = "US"
DEFAULT_TIMEZONE = "America/New_York"
DEFAULT_LOCALE = "en_us"
DEFAULT_MONITOR_WIDTH_CM = "21.7"
DEFAULT_MONITOR_HEIGHT_CM = "13.6"
DEFAULT_MONITOR_DISTANCE_CM = "30.0"
DEFAULT_SCREEN_ROTATION = "0"
DEFAULT_OUTPUT = "/tmp/hb_provision_answers.json"
WIFI_SCAN_FILE = os.environ.get("HB_WIFI_SCAN_FILE", "/tmp/hb_wifi_scan_ssids.txt")


def script_defaults_file():
    return Path(__file__).resolve().parent / "provision" / "device_defaults.ini"


def load_defaults_config(path):
    config = configparser.ConfigParser(interpolation=None)
    config.optionxform = str
    if path.is_file():
        config.read(path)
    return config


def device_groups(config):
    groups = set()
    for section in config.sections():
        parts = section.split(".")
        if len(parts) >= 3:
            groups.add(".".join(parts[:-1]))
    return sorted(groups)


def device_types_for_group(config, group):
    types = []
    prefix = f"{group}."
    for section in config.sections():
        if section.startswith(prefix) and len(section.split(".")) >= 3:
            types.append(section[len(prefix):])
    return sorted(types)


def read_hostname_default():
    try:
        return Path("/etc/hostname").read_text(encoding="utf-8").strip()
    except OSError:
        return socket.gethostname()


def scan_wifi_ssids():
    scan_file = Path(WIFI_SCAN_FILE)
    if scan_file.is_file():
        ssids = [line.strip() for line in scan_file.read_text(encoding="utf-8").splitlines()]
        return sorted({ssid for ssid in ssids if ssid})

    commands = [
        ["nmcli", "-t", "-f", "SSID", "dev", "wifi", "list", "--rescan", "yes"],
        ["nmcli", "-t", "-f", "SSID", "dev", "wifi", "list"],
    ]
    for cmd in commands:
        try:
            result = subprocess.run(
                cmd,
                check=False,
                capture_output=True,
                text=True,
                timeout=8,
            )
        except (OSError, subprocess.TimeoutExpired):
            continue
        if result.returncode == 0 and result.stdout.strip():
            ssids = [line.strip() for line in result.stdout.splitlines()]
            return sorted({ssid for ssid in ssids if ssid})
    return []


class ProvisioningWizard(tk.Tk):
    def __init__(self, output_path=DEFAULT_OUTPUT):
        super().__init__()
        self.title("Device Provisioning")
        self.configure(bg=BG)

        # Fullscreen on the device; comment out for desktop testing.
        # self.attributes("-fullscreen", True)
        self.geometry("1280x800")

        self.output_path = output_path
        self.defaults_path = Path(os.environ.get("DEVICE_DEFAULTS_FILE", script_defaults_file()))
        self.config = load_defaults_config(self.defaults_path)
        self.groups = device_groups(self.config)
        self.wifi_ssids = scan_wifi_ssids()

        self.answers = {
            "wifi_country": DEFAULT_WIFI_COUNTRY,
            "timezone": DEFAULT_TIMEZONE,
            "locale": DEFAULT_LOCALE,
            "screen_rotation": DEFAULT_SCREEN_ROTATION,
            "hostname": read_hostname_default(),
            "monitor_width_cm": DEFAULT_MONITOR_WIDTH_CM,
            "monitor_height_cm": DEFAULT_MONITOR_HEIGHT_CM,
            "monitor_distance_cm": DEFAULT_MONITOR_DISTANCE_CM,
        }

        self.steps = [
            self._step_defaults_group,
            self._step_defaults_device_type,
            self._step_wifi_country,
            self._step_timezone,
            self._step_locale,
            self._step_screen_width,
            self._step_screen_height,
            self._step_screen_refresh_rate,
            self._step_screen_rotation,
            self._step_wifi_ssid,
            self._step_wifi_password,
            self._step_hostname,
            self._step_username,
            self._step_password,
            self._step_monitor_width,
            self._step_monitor_height,
            self._step_monitor_distance,
            self._step_review,
        ]
        self.step_index = 0

        self._build_layout()
        self._render_current_step()

    # ------------------------------------------------------------------
    # Layout: a top content frame and a nav frame kept above the area an
    # on-screen keyboard is likely to cover.
    # ------------------------------------------------------------------
    def _build_layout(self):
        self.content = tk.Frame(self, bg=BG, padx=40, pady=30)
        self.content.place(x=0, y=0, relwidth=1.0, height=380)

        self.nav = tk.Frame(self, bg=BG, padx=40, pady=10)
        self.nav.place(x=0, y=380, relwidth=1.0, height=80)

        self.btn_back = self._make_button(self.nav, "< Back", self._on_back)
        self.btn_back.pack(side="left")

        self.btn_next = self._make_button(self.nav, "Next >", self._on_next, primary=True)
        self.btn_next.pack(side="right")

        self.progress_label = tk.Label(
            self.nav, text="", bg=BG, fg=FG, font=FONT_LABEL
        )
        self.progress_label.pack(side="top", pady=5)

    def _make_button(self, parent, text, command, primary=False):
        bg = ACCENT if primary else ENTRY_BG
        active = ACCENT_ACTIVE if primary else "#45475a"
        return tk.Button(
            parent,
            text=text,
            command=command,
            bg=bg,
            fg=FG,
            activebackground=active,
            activeforeground=FG,
            font=FONT_BTN,
            relief="flat",
            padx=30,
            pady=12,
            borderwidth=0,
            highlightthickness=0,
            cursor="hand2",
        )

    def _clear_content(self):
        for child in self.content.winfo_children():
            child.destroy()

    def _render_current_step(self):
        self._clear_content()
        self.progress_label.config(
            text=f"Step {self.step_index + 1} of {len(self.steps)}"
        )
        self.btn_back.config(state="normal" if self.step_index > 0 else "disabled")
        self.btn_next.config(
            text="Finish" if self.step_index == len(self.steps) - 1 else "Next >"
        )
        self.steps[self.step_index]()

    def _next_index(self, index):
        next_index = index + 1
        if (
            next_index < len(self.steps)
            and self.steps[next_index].__name__ == "_step_wifi_password"
            and not self.answers.get("wifi_ssid")
        ):
            next_index += 1
        return next_index

    def _previous_index(self, index):
        previous_index = index - 1
        if (
            previous_index >= 0
            and self.steps[previous_index].__name__ == "_step_wifi_password"
            and not self.answers.get("wifi_ssid")
        ):
            previous_index -= 1
        return previous_index

    def _on_next(self):
        if not self._validate_current_step():
            return
        if self.step_index < len(self.steps) - 1:
            self.step_index = self._next_index(self.step_index)
            self._render_current_step()
        else:
            self._on_finish()

    def _on_back(self):
        if self.step_index > 0:
            self.step_index = self._previous_index(self.step_index)
            self._render_current_step()

    def _on_finish(self):
        try:
            Path(self.output_path).write_text(
                json.dumps(self.answers, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
        except OSError as exc:
            messagebox.showerror("Save failed", f"Could not write {self.output_path}:\n{exc}")
            return

        print(json.dumps(self.answers, indent=2, sort_keys=True))
        messagebox.showinfo(
            "Done",
            f"Provisioning answers saved to:\n{self.output_path}",
        )
        self.destroy()

    # ------------------------------------------------------------------
    # Helpers for building consistent step UIs
    # ------------------------------------------------------------------
    def _add_title(self, text):
        tk.Label(
            self.content, text=text, bg=BG, fg=FG, font=FONT_TITLE
        ).pack(anchor="w", pady=(0, 20))

    def _add_label(self, text, fg=FG):
        tk.Label(
            self.content, text=text, bg=BG, fg=fg, font=FONT_LABEL, justify="left"
        ).pack(anchor="w", pady=(10, 5))

    def _add_entry(self, initial=""):
        var = tk.StringVar(value=initial)
        entry = tk.Entry(
            self.content,
            textvariable=var,
            font=FONT_INPUT,
            bg=ENTRY_BG,
            fg=FG,
            insertbackground=FG,
            relief="flat",
            highlightthickness=2,
            highlightbackground=ENTRY_BG,
            highlightcolor=ACCENT,
        )
        entry.pack(fill="x", ipady=8, pady=5)
        return var, entry

    def _add_listbox(self, entries, selected_value=""):
        var = tk.StringVar(value=selected_value)
        list_frame = tk.Frame(self.content, bg=BG)
        list_frame.pack(fill="x", pady=5)

        listbox = tk.Listbox(
            list_frame,
            font=FONT_INPUT,
            bg=ENTRY_BG,
            fg=FG,
            selectbackground=ACCENT,
            selectforeground=BG,
            relief="flat",
            highlightthickness=2,
            highlightbackground=ENTRY_BG,
            highlightcolor=ACCENT,
            height=min(5, max(1, len(entries))),
            activestyle="none",
        )
        for item in entries:
            listbox.insert("end", item)
        listbox.pack(side="left", fill="x", expand=True)

        scrollbar = tk.Scrollbar(list_frame, command=listbox.yview)
        scrollbar.pack(side="right", fill="y")
        listbox.config(yscrollcommand=scrollbar.set)

        if selected_value in entries:
            idx = entries.index(selected_value)
            listbox.selection_set(idx)
            listbox.see(idx)

        def on_select(_event):
            sel = listbox.curselection()
            if sel:
                var.set(listbox.get(sel[0]))

        listbox.bind("<<ListboxSelect>>", on_select)
        return var, listbox

    def _show_default_hint(self, key):
        value = self.answers.get(key, "")
        if value not in ("", None):
            self._add_label(f"Default: {value}", fg=MUTED)

    def _apply_defaults_section(self, section):
        if not section or not self.config.has_section(section):
            return

        key_map = {
            "username": "username",
            "timezone": "timezone",
            "locale": "locale",
            "wifi_country": "wifi_country",
            "screen_pixels_width": "screen_pixels_width",
            "screen_pixels_height": "screen_pixels_height",
            "screen_refresh_rate": "screen_refresh_rate",
            "screen_rotation": "screen_rotation",
            "monitor_width_cm": "monitor_width_cm",
            "monitor_height_cm": "monitor_height_cm",
            "monitor_distance_cm": "monitor_distance_cm",
        }
        for ini_key, answer_key in key_map.items():
            value = self.config.get(section, ini_key, fallback="").strip()
            if value:
                self.answers[answer_key] = value

    # ------------------------------------------------------------------
    # Steps
    # ------------------------------------------------------------------
    def _step_defaults_group(self):
        self._add_title("Select defaults group")
        if not self.groups:
            self._add_label(
                f"No device defaults found at {self.defaults_path}. Built-in defaults will be used."
            )
            self._defaults_group_var = tk.StringVar(value="")
            return

        self._add_label("Choose a defaults group, or skip defaults:")
        options = ["(skip defaults)"] + self.groups
        selected = self.answers.get("defaults_group") or "(skip defaults)"
        self._defaults_group_var, _ = self._add_listbox(options, selected)

    def _step_defaults_device_type(self):
        group = self.answers.get("defaults_group", "")
        if not group:
            self._add_title("Defaults skipped")
            self._add_label("No device defaults will be applied.")
            self._defaults_type_var = tk.StringVar(value="")
            return

        self._add_title("Select device type")
        self._add_label(f"Defaults group: {group}")
        types = device_types_for_group(self.config, group)
        self._defaults_type_options = types
        self._defaults_type_var, _ = self._add_listbox(
            types,
            self.answers.get("defaults_device_type", types[0] if types else ""),
        )

    def _step_wifi_country(self):
        self._add_title("Wi-Fi country")
        self._add_label("Enter Wi-Fi country code (2 letters, e.g. US, CA, GB, DE, FR, JP).")
        self._show_default_hint("wifi_country")
        self._wifi_country_var, entry = self._add_entry(
            self.answers.get("wifi_country", DEFAULT_WIFI_COUNTRY)
        )
        entry.focus_set()

    def _step_timezone(self):
        self._add_title("Timezone")
        self._add_label("Enter timezone, e.g. America/New_York or Europe/London.")
        self._show_default_hint("timezone")
        self._timezone_var, entry = self._add_entry(
            self.answers.get("timezone", DEFAULT_TIMEZONE)
        )
        entry.focus_set()

    def _step_locale(self):
        self._add_title("Locale")
        self._add_label("Enter locale, e.g. en_us, en_gb, fr_fr, or de_de.")
        self._show_default_hint("locale")
        locale = self.answers.get("locale", DEFAULT_LOCALE)
        if locale.endswith(".UTF-8"):
            locale = locale[:-6].lower()
        self._locale_var, entry = self._add_entry(locale)
        entry.focus_set()

    def _step_screen_width(self):
        self._add_title("Screen pixel width")
        self._add_label("Leave blank to skip display mode settings.")
        self._show_default_hint("screen_pixels_width")
        self._screen_width_var, entry = self._add_entry(
            self.answers.get("screen_pixels_width", "")
        )
        entry.focus_set()

    def _step_screen_height(self):
        self._add_title("Screen pixel height")
        self._add_label("Leave blank to skip display mode settings.")
        self._show_default_hint("screen_pixels_height")
        self._screen_height_var, entry = self._add_entry(
            self.answers.get("screen_pixels_height", "")
        )
        entry.focus_set()

    def _step_screen_refresh_rate(self):
        self._add_title("Screen refresh rate")
        self._add_label("Refresh rate in Hz. Leave blank to skip display mode settings.")
        self._show_default_hint("screen_refresh_rate")
        self._screen_refresh_var, entry = self._add_entry(
            self.answers.get("screen_refresh_rate", "")
        )
        entry.focus_set()

    def _step_screen_rotation(self):
        self._add_title("Screen rotation")
        self._add_label("Enter screen rotation degrees: 0, 90, 180, or 270.")
        self._show_default_hint("screen_rotation")
        self._screen_rotation_var, entry = self._add_entry(
            self.answers.get("screen_rotation", DEFAULT_SCREEN_ROTATION)
        )
        entry.focus_set()

    def _step_wifi_ssid(self):
        self._add_title("Wi-Fi network")
        self._add_label("Select a discovered network or type an SSID. Leave blank to skip Wi-Fi.")

        if self.wifi_ssids:
            selected = self.answers.get("wifi_ssid", "")
            self._ssid_list_var, listbox = self._add_listbox(self.wifi_ssids, selected)
            listbox.bind("<<ListboxSelect>>", self._on_ssid_list_select, add="+")
        else:
            self._add_label("No scanned Wi-Fi networks found. You can type the SSID manually.", fg=MUTED)
            self._ssid_list_var = tk.StringVar(value="")

        self._wifi_ssid_var, entry = self._add_entry(self.answers.get("wifi_ssid", ""))
        entry.focus_set()

    def _on_ssid_list_select(self, _event):
        self._wifi_ssid_var.set(self._ssid_list_var.get())

    def _step_wifi_password(self):
        ssid = self.answers.get("wifi_ssid", "")
        self._add_title("Wi-Fi password")
        self._add_label(f"Password for: {ssid}")
        self._wifi_password_var, entry = self._add_entry(
            self.answers.get("wifi_password", "")
        )
        entry.focus_set()

    def _step_hostname(self):
        self._add_title("Hostname")
        self._add_label("Enter hostname for the provisioned device.")
        self._show_default_hint("hostname")
        self._hostname_var, entry = self._add_entry(self.answers.get("hostname", ""))
        entry.focus_set()

    def _step_username(self):
        self._add_title("Username")
        self._add_label("Enter system login username.")
        self._show_default_hint("username")
        self._username_var, entry = self._add_entry(self.answers.get("username", ""))
        entry.focus_set()

    def _step_password(self):
        username = self.answers.get("username", "the user")
        self._add_title("Password")
        self._add_label(f"Password for {username} (shown):")
        self._password_var, entry = self._add_entry(self.answers.get("password", ""))
        entry.focus_set()

    def _step_monitor_width(self):
        self._add_title("Monitor width")
        self._add_label("Screen width in centimeters for stim2 monitor settings.")
        self._show_default_hint("monitor_width_cm")
        self._monitor_width_var, entry = self._add_entry(
            self.answers.get("monitor_width_cm", DEFAULT_MONITOR_WIDTH_CM)
        )
        entry.focus_set()

    def _step_monitor_height(self):
        self._add_title("Monitor height")
        self._add_label("Screen height in centimeters for stim2 monitor settings.")
        self._show_default_hint("monitor_height_cm")
        self._monitor_height_var, entry = self._add_entry(
            self.answers.get("monitor_height_cm", DEFAULT_MONITOR_HEIGHT_CM)
        )
        entry.focus_set()

    def _step_monitor_distance(self):
        self._add_title("Monitor distance")
        self._add_label("Distance to monitor in centimeters for stim2 monitor settings.")
        self._show_default_hint("monitor_distance_cm")
        self._monitor_distance_var, entry = self._add_entry(
            self.answers.get("monitor_distance_cm", DEFAULT_MONITOR_DISTANCE_CM)
        )
        entry.focus_set()

    def _step_review(self):
        self._add_title("Review")
        self._add_label("Confirm these settings, then tap Finish:")

        review_frame = tk.Frame(self.content, bg=ENTRY_BG, padx=20, pady=15)
        review_frame.pack(fill="x", pady=10)

        rows = [
            ("Defaults", self.answers.get("defaults_section", "(skipped)")),
            ("Wi-Fi country", self.answers.get("wifi_country", "")),
            ("Timezone", self.answers.get("timezone", "")),
            ("Locale", self.answers.get("locale", "")),
            ("Screen", self._screen_summary()),
            ("Wi-Fi SSID", self.answers.get("wifi_ssid", "(skipped)") or "(skipped)"),
            ("Hostname", self.answers.get("hostname", "")),
            ("Username", self.answers.get("username", "")),
            ("Password", self.answers.get("password", "")),
            ("Monitor", self._monitor_summary()),
        ]
        for label, value in rows:
            row = tk.Frame(review_frame, bg=ENTRY_BG)
            row.pack(fill="x", pady=2)
            tk.Label(
                row,
                text=f"{label}:",
                bg=ENTRY_BG,
                fg=FG,
                font=FONT_LABEL,
                width=14,
                anchor="w",
            ).pack(side="left")
            tk.Label(
                row,
                text=str(value),
                bg=ENTRY_BG,
                fg=ACCENT,
                font=FONT_LABEL,
                anchor="w",
            ).pack(side="left", fill="x", expand=True)

    def _screen_summary(self):
        width = self.answers.get("screen_pixels_width", "")
        height = self.answers.get("screen_pixels_height", "")
        rate = self.answers.get("screen_refresh_rate", "")
        rotation = self.answers.get("screen_rotation", "")
        if not (width and height and rate):
            return "(skipped)"
        return f"{width}x{height} @ {rate} Hz, rotation {rotation}"

    def _monitor_summary(self):
        width = self.answers.get("monitor_width_cm", "")
        height = self.answers.get("monitor_height_cm", "")
        distance = self.answers.get("monitor_distance_cm", "")
        return f"{width} x {height} cm, distance {distance} cm"

    # ------------------------------------------------------------------
    # Validation
    # ------------------------------------------------------------------
    def _validate_current_step(self):
        step_name = self.steps[self.step_index].__name__

        if step_name == "_step_defaults_group":
            value = self._defaults_group_var.get()
            if value == "(skip defaults)":
                value = ""
            self.answers["defaults_group"] = value
            self.answers.pop("defaults_device_type", None)
            self.answers.pop("defaults_section", None)

        elif step_name == "_step_defaults_device_type":
            group = self.answers.get("defaults_group", "")
            if not group:
                return True
            device_type = self._defaults_type_var.get().strip()
            if not device_type:
                messagebox.showerror("Required", "Please select a device type.")
                return False
            section = f"{group}.{device_type}"
            if not self.config.has_section(section):
                messagebox.showerror("Invalid", f"Defaults section not found: {section}")
                return False
            self.answers["defaults_device_type"] = device_type
            self.answers["defaults_section"] = section
            self._apply_defaults_section(section)

        elif step_name == "_step_wifi_country":
            value = self._wifi_country_var.get().strip().upper() or DEFAULT_WIFI_COUNTRY
            if not re.fullmatch(r"[A-Z]{2}", value):
                messagebox.showerror("Invalid", "Wi-Fi country must be 2 letters like US.")
                return False
            self.answers["wifi_country"] = value

        elif step_name == "_step_timezone":
            value = self._timezone_var.get().strip() or DEFAULT_TIMEZONE
            if not Path("/usr/share/zoneinfo", value).is_file():
                messagebox.showerror(
                    "Invalid",
                    "Timezone not found. Example: America/Los_Angeles, Europe/London, Asia/Tokyo.",
                )
                return False
            self.answers["timezone"] = value

        elif step_name == "_step_locale":
            value = self._locale_var.get().strip().lower() or DEFAULT_LOCALE
            if not re.fullmatch(r"[a-z]{2}_[a-z]{2}", value):
                messagebox.showerror("Invalid", "Locale must look like en_us, en_gb, fr_fr, or de_de.")
                return False
            base = f"{value[:2]}_{value[3:].upper()}"
            if not Path("/usr/share/i18n/locales", base).is_file():
                messagebox.showerror("Invalid", f"Locale not found on this system: {value}")
                return False
            self.answers["locale"] = f"{base}.UTF-8"

        elif step_name == "_step_screen_width":
            value = self._screen_width_var.get().strip()
            if value and not self._valid_int(value, 320, 7680):
                messagebox.showerror("Invalid", "Screen width must be a number between 320 and 7680.")
                return False
            self.answers["screen_pixels_width"] = value

        elif step_name == "_step_screen_height":
            value = self._screen_height_var.get().strip()
            if value and not self._valid_int(value, 240, 4320):
                messagebox.showerror("Invalid", "Screen height must be a number between 240 and 4320.")
                return False
            self.answers["screen_pixels_height"] = value

        elif step_name == "_step_screen_refresh_rate":
            value = self._screen_refresh_var.get().strip()
            if value and not self._valid_int(value, 1, 360):
                messagebox.showerror("Invalid", "Refresh rate must be a number between 1 and 360.")
                return False
            self.answers["screen_refresh_rate"] = value

        elif step_name == "_step_screen_rotation":
            value = self._screen_rotation_var.get().strip() or DEFAULT_SCREEN_ROTATION
            if value not in {"0", "90", "180", "270"}:
                messagebox.showerror("Invalid", "Screen rotation must be 0, 90, 180, or 270.")
                return False
            self.answers["screen_rotation"] = value

        elif step_name == "_step_wifi_ssid":
            value = self._wifi_ssid_var.get().strip()
            if "\n" in value or "\r" in value:
                messagebox.showerror("Invalid", "Wi-Fi SSID cannot contain newline characters.")
                return False
            self.answers["wifi_ssid"] = value
            if not value:
                self.answers["wifi_password"] = ""

        elif step_name == "_step_wifi_password":
            value = self._wifi_password_var.get()
            if not value:
                messagebox.showerror("Required", "Wi-Fi password cannot be empty. Go Back to skip Wi-Fi.")
                return False
            if "\n" in value or "\r" in value:
                messagebox.showerror("Invalid", "Wi-Fi password cannot contain newline characters.")
                return False
            self.answers["wifi_password"] = value

        elif step_name == "_step_hostname":
            value = self._hostname_var.get().strip().lower()
            if not re.fullmatch(r"[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?", value):
                messagebox.showerror("Invalid", "Hostname must use a-z, 0-9, and hyphen, max 63 chars.")
                return False
            self.answers["hostname"] = value

        elif step_name == "_step_username":
            value = self._username_var.get().strip()
            if not re.fullmatch(r"[a-z_][a-z0-9_-]*", value):
                messagebox.showerror(
                    "Invalid",
                    "Username must use a-z, 0-9, '_' or '-', and start with a letter or '_'.",
                )
                return False
            self.answers["username"] = value

        elif step_name == "_step_password":
            value = self._password_var.get()
            if not value:
                messagebox.showerror("Required", "Empty password is not allowed.")
                return False
            self.answers["password"] = value

        elif step_name == "_step_monitor_width":
            return self._validate_float_step("monitor_width_cm", self._monitor_width_var)

        elif step_name == "_step_monitor_height":
            return self._validate_float_step("monitor_height_cm", self._monitor_height_var)

        elif step_name == "_step_monitor_distance":
            return self._validate_float_step("monitor_distance_cm", self._monitor_distance_var)

        return True

    def _validate_float_step(self, key, var):
        value = var.get().strip()
        try:
            number = float(value)
        except ValueError:
            messagebox.showerror("Invalid", "Please enter a number.")
            return False
        if number <= 0:
            messagebox.showerror("Invalid", "Value must be greater than zero.")
            return False
        self.answers[key] = value
        return True

    def _valid_int(self, value, low, high):
        try:
            number = int(value)
        except ValueError:
            return False
        return low <= number <= high


def parse_args():
    parser = argparse.ArgumentParser(description="Collect NVMe provisioning answers in a Tkinter GUI.")
    parser.add_argument(
        "--output",
        default=DEFAULT_OUTPUT,
        help=f"Path to write JSON answers (default: {DEFAULT_OUTPUT})",
    )
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    app = ProvisioningWizard(output_path=args.output)
    app.mainloop()
