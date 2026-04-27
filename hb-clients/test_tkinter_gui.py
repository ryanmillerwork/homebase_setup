#!/usr/bin/env python3
"""
Provisioning wizard - Tkinter GUI for first-boot setup.

Designed for a 10" touchscreen (typical 1280x800).
Inputs are kept in the top half of the screen so an on-screen
keyboard docked at the bottom won't cover them.
"""

import tkinter as tk
from tkinter import ttk, messagebox

# ---- Fake data (replace with real wifi scan, e.g. `nmcli -t -f SSID dev wifi`) ----
FAKE_SSIDS = [
    "HomeNetwork_5G",
    "HomeNetwork_2.4G",
    "Linksys_Guest",
    "ATT-WiFi-8821",
    "xfinitywifi",
    "NETGEAR42",
    "TP-Link_Lab",
]


# ---- Theme / sizing ----
BG = "#1e1e2e"
FG = "#cdd6f4"
ACCENT = "#89b4fa"
ACCENT_ACTIVE = "#74a0e8"
ENTRY_BG = "#313244"
ERROR = "#f38ba8"

FONT_TITLE = ("DejaVu Sans", 22, "bold")
FONT_LABEL = ("DejaVu Sans", 14)
FONT_INPUT = ("DejaVu Sans", 16)
FONT_BTN = ("DejaVu Sans", 14, "bold")


class ProvisioningWizard(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Device Provisioning")
        self.configure(bg=BG)

        # Fullscreen on the device; comment out for desktop testing.
        # self.attributes("-fullscreen", True)
        self.geometry("1280x800")

        # Collected answers
        self.answers = {}

        # Step pipeline
        self.steps = [
            self._step_username,
            self._step_password,
            self._step_wifi_ssid,
            self._step_wifi_password,
            self._step_screen_width,
            self._step_review,
        ]
        self.step_index = 0

        self._build_layout()
        self._render_current_step()

    # ------------------------------------------------------------------
    # Layout: a top "content" frame (kept in upper half) and a bottom
    # "nav" frame with Back/Next buttons. The on-screen keyboard, when
    # docked at the bottom, sits below this whole window or overlays
    # the bottom — either way the inputs stay visible.
    # ------------------------------------------------------------------
    def _build_layout(self):
        # Content area - top portion of screen
        self.content = tk.Frame(self, bg=BG, padx=40, pady=30)
        self.content.place(x=0, y=0, relwidth=1.0, height=380)

        # Nav area - just above the midline
        self.nav = tk.Frame(self, bg=BG, padx=40, pady=10)
        self.nav.place(x=0, y=380, relwidth=1.0, height=80)

        self.btn_back = self._make_button(self.nav, "← Back", self._on_back)
        self.btn_back.pack(side="left")

        self.btn_next = self._make_button(self.nav, "Next →", self._on_next, primary=True)
        self.btn_next.pack(side="right")

        # Progress label
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
            text="Finish" if self.step_index == len(self.steps) - 1 else "Next →"
        )
        # Render the current step
        self.steps[self.step_index]()

    def _on_next(self):
        # Validate the current step before advancing
        if not self._validate_current_step():
            return
        if self.step_index < len(self.steps) - 1:
            self.step_index += 1
            self._render_current_step()
        else:
            self._on_finish()

    def _on_back(self):
        if self.step_index > 0:
            self.step_index -= 1
            self._render_current_step()

    def _on_finish(self):
        # In your real script: write answers to a config file and exit
        # so the shell wrapper can read it and continue provisioning.
        print("Collected answers:")
        for k, v in self.answers.items():
            print(f"  {k}: {v}")
        messagebox.showinfo(
            "Done",
            "Provisioning configuration saved.\n\n" + "\n".join(
                f"{k}: {v}" for k, v in self.answers.items()
            ),
        )
        self.destroy()

    # ------------------------------------------------------------------
    # Helpers for building consistent step UIs
    # ------------------------------------------------------------------
    def _add_title(self, text):
        tk.Label(
            self.content, text=text, bg=BG, fg=FG, font=FONT_TITLE
        ).pack(anchor="w", pady=(0, 20))

    def _add_label(self, text):
        tk.Label(
            self.content, text=text, bg=BG, fg=FG, font=FONT_LABEL
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

    def _add_error(self, text):
        tk.Label(
            self.content, text=text, bg=BG, fg=ERROR, font=FONT_LABEL
        ).pack(anchor="w", pady=(5, 0))

    # ------------------------------------------------------------------
    # Steps
    # ------------------------------------------------------------------
    def _step_username(self):
        self._add_title("Choose a username")
        self._add_label("This will be the system login name.")
        self._username_var, entry = self._add_entry(
            initial=self.answers.get("username", "")
        )
        entry.focus_set()

    def _step_password(self):
        self._add_title("Set a password")
        self._add_label("Password (visible — set a secure one):")
        self._password_var, entry = self._add_entry(
            initial=self.answers.get("password", "")
        )
        entry.focus_set()

    def _step_wifi_ssid(self):
        self._add_title("Select Wi-Fi network")
        self._add_label("Choose your network from the list:")

        self._ssid_var = tk.StringVar(value=self.answers.get("wifi_ssid", ""))

        # Listbox with scrollbar - sized to fit in upper area
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
            height=5,
            activestyle="none",
        )
        for ssid in FAKE_SSIDS:
            listbox.insert("end", ssid)
        listbox.pack(side="left", fill="x", expand=True)

        scrollbar = tk.Scrollbar(list_frame, command=listbox.yview)
        scrollbar.pack(side="right", fill="y")
        listbox.config(yscrollcommand=scrollbar.set)

        # Restore previous selection
        if self._ssid_var.get() in FAKE_SSIDS:
            idx = FAKE_SSIDS.index(self._ssid_var.get())
            listbox.selection_set(idx)
            listbox.see(idx)

        def on_select(event):
            sel = listbox.curselection()
            if sel:
                self._ssid_var.set(listbox.get(sel[0]))

        listbox.bind("<<ListboxSelect>>", on_select)
        self._ssid_listbox = listbox

    def _step_wifi_password(self):
        ssid = self.answers.get("wifi_ssid", "(none)")
        self._add_title("Wi-Fi password")
        self._add_label(f"Password for: {ssid}")
        self._wifi_password_var, entry = self._add_entry(
            initial=self.answers.get("wifi_password", "")
        )
        entry.focus_set()

    def _step_screen_width(self):
        self._add_title("Screen width")
        self._add_label("Screen width in pixels:")
        self._width_var, entry = self._add_entry(
            initial=str(self.answers.get("screen_width", "1280"))
        )
        entry.focus_set()

    def _step_review(self):
        self._add_title("Review")
        self._add_label("Confirm these settings, then tap Finish:")

        review_frame = tk.Frame(self.content, bg=ENTRY_BG, padx=20, pady=15)
        review_frame.pack(fill="x", pady=10)

        rows = [
            ("Username", self.answers.get("username", "")),
            ("Password", self.answers.get("password", "")),
            ("Wi-Fi SSID", self.answers.get("wifi_ssid", "")),
            ("Wi-Fi password", self.answers.get("wifi_password", "")),
            ("Screen width", str(self.answers.get("screen_width", ""))),
        ]
        for label, value in rows:
            row = tk.Frame(review_frame, bg=ENTRY_BG)
            row.pack(fill="x", pady=2)
            tk.Label(
                row, text=f"{label}:", bg=ENTRY_BG, fg=FG,
                font=FONT_LABEL, width=15, anchor="w"
            ).pack(side="left")
            tk.Label(
                row, text=value, bg=ENTRY_BG, fg=ACCENT,
                font=FONT_LABEL, anchor="w"
            ).pack(side="left", fill="x", expand=True)

    # ------------------------------------------------------------------
    # Validation
    # ------------------------------------------------------------------
    def _validate_current_step(self):
        step_name = self.steps[self.step_index].__name__

        if step_name == "_step_username":
            v = self._username_var.get().strip()
            if not v:
                messagebox.showerror("Required", "Please enter a username.")
                return False
            if not v.replace("_", "").replace("-", "").isalnum():
                messagebox.showerror(
                    "Invalid", "Username must be alphanumeric (- and _ allowed)."
                )
                return False
            self.answers["username"] = v

        elif step_name == "_step_password":
            v = self._password_var.get()
            if len(v) < 6:
                messagebox.showerror(
                    "Too short", "Password must be at least 6 characters."
                )
                return False
            self.answers["password"] = v

        elif step_name == "_step_wifi_ssid":
            v = self._ssid_var.get()
            if not v:
                messagebox.showerror("Required", "Please select a Wi-Fi network.")
                return False
            self.answers["wifi_ssid"] = v

        elif step_name == "_step_wifi_password":
            # Allow empty for open networks, but warn
            self.answers["wifi_password"] = self._wifi_password_var.get()

        elif step_name == "_step_screen_width":
            v = self._width_var.get().strip()
            try:
                width = int(v)
                if width < 320 or width > 7680:
                    raise ValueError
                self.answers["screen_width"] = width
            except ValueError:
                messagebox.showerror(
                    "Invalid", "Screen width must be a number between 320 and 7680."
                )
                return False

        return True


if __name__ == "__main__":
    app = ProvisioningWizard()
    app.mainloop()
