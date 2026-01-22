# provision_nvme_from_emmc

Provision an NVMe boot drive on **Raspberry Pi OS Bookworm (or later)** while booted from **eMMC/mmc**, by flashing **`raspios_lite_arm64_latest`** to NVMe and applying minimal “headless” config (SSH + user + Wi-Fi), then switching EEPROM boot order to NVMe-first and rebooting.

## What it does

- **Validates**: Bookworm+; root filesystem is on an `mmcblk*` device; NVMe disk exists.
- **Prompts for Wi-Fi first (always)**: it asks for SSID/password up front, attempts to connect the *current* system via `nmcli`, and verifies internet reachability. If no internet is detected, you can choose to continue anyway.
- **Prompts for region + locale**: Wi‑Fi country code, timezone, locale (with defaults and validation).
- **Installs packages**: `wget`, `xz-utils`, `openssl`, `iw`, `network-manager`, `rpi-eeprom`, etc.
- **Flashes**: downloads `raspios_lite_arm64_latest` and streams it to the NVMe via `xzcat | dd`.
- **Configures on the NVMe image**:
  - enables SSH (creates `ssh` on the boot partition)
  - creates user/password (writes `userconf.txt` on the boot partition)
  - configures Wi-Fi for the installed NVMe OS (creates a NetworkManager `*.nmconnection` profile in the NVMe **rootfs**)
  - prompts for a **hostname** and writes it into the NVMe rootfs (`/etc/hostname` + `/etc/hosts`)
  - sets timezone + locale (and keyboard layout for US/GB)
  - ensures `dtparam=pciex1=on` and `dtparam=ant2` in NVMe `config.txt` (if present)
  - disables camera auto‑detect and applies `dtoverlay=imx708`
  - propagates display rotation if the current system uses a `video=...rotate=180` kernel arg
  - copies `/etc/udev/rules.d/99-touchscreen-rotate.rules` if present
  - expands the NVMe rootfs to fill the disk
- **Updates NVMe OS packages** (in chroot): full upgrade, installs dev tools + `libcamera-apps`, disables bluetooth.
- **Sets EEPROM boot order**: best-effort non-interactive edit to `BOOT_ORDER=0xf416` and `PCIE_PROBE=1`.
- **Reboots**.

## Usage

Copy the script to the Pi and run:

```bash
sudo ./provision_nvme_from_emmc.sh
```

You will be prompted to:

- enter Wi-Fi SSID/password (used to connect the current system; then also applied to the NVMe OS)
- enter Wi-Fi country code (2 letters, e.g. `US`, `CA`, `GB`, `DE`, `FR`, `JP`) to avoid rfkill block warning on first boot (default `US`)
- enter timezone (default `America/New_York`)
- enter locale (e.g. `en_us`, `en_gb`, `fr_fr`)
- enter hostname (defaults to current system hostname)
- enter a username/password for first boot
- choose the NVMe disk (if there are multiple)
- type **`ERASE`** to confirm destroying that disk

## Notes / caveats

- This script is **destructive** to the selected NVMe disk.
- “Running on eMMC” is checked via `mmcblk*` root device **plus** a heuristic for `/dev/mmcblk*boot0`. If you really are on microSD, the script will ask you to **type `YES`** to proceed.

## stim2 trainer provisioning

`provision_trainer.sh` prepares a fresh **Raspberry Pi OS Trixie Lite** install to boot directly into stim2 in kiosk mode. High‑level steps:

- installs dependencies (`cage`, `labwc`, `libtcl9.0`, `wget`, `ca-certificates`)
- downloads the latest `stim2` arm64 `.deb` from GitHub releases and installs it
- ensures `stim2` is on `PATH` (`/usr/local/bin/stim2` symlink if needed)
- prompts for monitor geometry and writes `/usr/local/stim2/local/monitor.tcl`
- installs and enables systemd services from vendor packages:
  - `/usr/local/stim2/systemd/stim2.service`
  - `/usr/local/dserv/systemd/dserv.service`
  - `/usr/local/dserv/systemd/dserv-agent.service`
- applies kiosk-style boot settings via `raspi-config` (console autologin + Wayland/labwc where supported)

Run it on the target Pi:

```bash
sudo ./provision_trainer.sh
```

## eMMC fallback provisioning

`provision_emmc_for_nvme_fallback.sh` installs the **desktop** Raspberry Pi OS image to eMMC and prepares it to auto-run NVMe provisioning on every boot. It:

- downloads `raspios_arm64_latest` and flashes it to eMMC
- creates the default `provision/provision` user
- enables SSH on first boot
- enables passwordless sudo for that user
- prompts for a hostname and writes it to the eMMC rootfs
- sets `dtparam=pciex1=on` and `dtparam=ant2`
- clones `https://github.com/ryanmillerwork/homebase_setup` onto the eMMC image
- sets desktop autostart to run `sudo ./provision_nvme_from_emmc.sh` in a terminal on every boot

Run it from **NVMe or microSD** (it refuses to overwrite the current root device):

```bash
sudo ./provision_emmc_for_nvme_fallback.sh
```
