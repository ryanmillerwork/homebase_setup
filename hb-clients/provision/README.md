# provision_nvme

Provision an NVMe boot drive on **Raspberry Pi OS Bookworm (or later)** while booted from **fallback media (eMMC/microSD/USB)**, by flashing **`raspios_lite_arm64_latest`** to NVMe, applying headless config (SSH + user + Wi‑Fi), installing stim2/dserv/dlsh/ess, and switching EEPROM boot order to NVMe-first before rebooting.

## What it does

- **Validates**: Bookworm+; root filesystem is on fallback media (`mmcblk*` or `/dev/sd*`); NVMe disk exists.
- **Collects setup answers in the GUI**: `provision_nvme_gui.py` writes the answer JSON and launches the backend after the user types `ERASE`.
- **Checks expected accessories**: the GUI reports touchscreen, juicer, power monitor, and camera visibility after Wi-Fi checks. Missing accessories are warnings only; provisioning can continue.
- **Configures Wi-Fi first when provided**: it uses the JSON SSID/password up front, attempts to connect the *current* system via `nmcli`, and verifies internet reachability (required for downloads).
- **Applies region + locale + display answers**: Wi‑Fi country code, timezone, locale, optional screen mode/rotation, and monitor geometry.
- **Installs packages**: `wget`, `xz-utils`, `openssl`, `iw`, `network-manager`, `rpi-eeprom`, etc.
- **Flashes**: downloads `raspios_lite_arm64_latest` and streams it to the NVMe via `xzcat | dd`.
- **Logs**: writes a full provisioning log to `/var/log/provision/provision_nvme_YYYYMMDD_HHMMSS.log` on the NVMe rootfs.
- **Configures on the NVMe image**:
  - enables SSH (creates `ssh` on the boot partition)
  - creates user/password (writes `userconf.txt` on the boot partition)
  - configures Wi-Fi for the installed NVMe OS (creates a NetworkManager `*.nmconnection` profile in the NVMe **rootfs**)
  - ensures Wi‑Fi is enabled by default (`/var/lib/NetworkManager/NetworkManager.state`)
  - prompts for a **hostname** and writes it into the NVMe rootfs (`/etc/hostname` + `/etc/hosts`)
  - sets timezone + locale (and keyboard layout for US/GB)
  - ensures `dtparam=pciex1=on` and `dtparam=ant2` in NVMe `config.txt` (if present)
  - disables camera auto‑detect and applies `dtoverlay=imx708`
  - sets display mode/rotation in `cmdline.txt` (if screen values are provided)
  - copies `/etc/udev/rules.d/99-touchscreen-rotate.rules` if present
  - expands the NVMe rootfs to fill the disk
- **Updates NVMe OS packages** (in chroot): full upgrade, installs dev tools + `libcamera-apps`, disables bluetooth.
- **Installs stim2/dserv/dlsh + ESS repo** in the NVMe rootfs and enables their systemd services.
- **Configures kiosk settings** via `raspi-config` (console autologin + Wayland).
- **Configures seatd + stim2 startup delay** to avoid libseat/DRM timing issues at boot.
- **Sets EEPROM boot order**: best-effort non-interactive edit to `BOOT_ORDER=0xf416` and `PCIE_PROBE=1`.
- **Reboots**.

## Usage

Run the GUI on the fallback desktop:

```bash
./provision_nvme_gui.py
```

The GUI saves answers to `/tmp/hb_provision_answers.json`, asks you to type **`ERASE`**, then runs:

```bash
sudo ./provision_nvme.sh --answers /tmp/hb_provision_answers.json
```

The GUI collects:

- enter Wi-Fi SSID/password (used to connect the current system; then also applied to the NVMe OS)
- enter Wi-Fi country code (2 letters, e.g. `US`, `CA`, `GB`, `DE`, `FR`, `JP`) to avoid rfkill block warning on first boot (default `US`)
- enter timezone (default `America/New_York`)
- enter locale (e.g. `en_us`, `en_gb`, `fr_fr`)
- enter optional screen pixel width/height/refresh + rotation
- review accessory checks for touchscreen, juicer, power monitor, and camera (informational only)
- enter hostname (defaults to current system hostname)
- enter a username/password for first boot
- enter monitor geometry (cm) for stim2 calibration
- type **`ERASE`** to confirm destroying the NVMe disk

The backend automatically uses the only detected NVMe disk. If multiple NVMe disks are present, add `nvme_device` to the answers JSON before running the backend.

## Notes / caveats

- This script is **destructive** to the selected NVMe disk.
- If running from `mmcblk*`, a heuristic checks for `/dev/mmcblk*boot0` to detect eMMC. If you are on microSD, set `allow_possible_sd` to `YES` in the answers JSON to proceed.
- The script requires internet connectivity to fetch packages and releases. If Wi‑Fi/ethernet is unavailable, it will abort.
- Provision logs are saved to `/var/log/provision/provision_nvme_YYYYMMDD_HHMMSS.log` on the NVMe rootfs.
- The answers JSON contains Wi-Fi and login passwords and is written with user-only permissions by the GUI.

## stim2 trainer provisioning

`provision_trainer.sh` prepares a fresh **Raspberry Pi OS Trixie Lite** install to boot directly into stim2 in kiosk mode. High‑level steps:

- installs dependencies (`cage`, `labwc`, `libtcl9.0`, `wget`, `ca-certificates`)
- downloads the latest `stim2_*_arm64_{bookworm|trixie}.deb` matching the OS
- ensures `stim2` is on `PATH` (`/usr/local/bin/stim2` symlink if needed)
- prompts for monitor geometry and writes `/usr/local/stim2/local/monitor.tcl`
- downloads the latest `dserv_*_arm64.deb`, installs it, and copies default local configs:
  - `/usr/local/dserv/local/post-pins.tcl.EXAMPLE` → `post-pins.tcl`
  - `/usr/local/dserv/local/sound.tcl.EXAMPLE` → `sound.tcl`
- downloads the latest `dlsh-*.zip` to `/usr/local/dlsh/dlsh.zip`
- clones `https://github.com/homebase-sheinberg/ess.git` into `~/systems` and sets `ESS_SYSTEM_PATH`
- installs and enables systemd services from vendor packages:
  - `/usr/local/stim2/systemd/stim2.service`
  - `/usr/local/dserv/systemd/dserv.service`
  - `/usr/local/dserv/systemd/dserv-agent.service`
- applies kiosk-style boot settings via `raspi-config` (console autologin + Wayland/labwc where supported)

Run it on the target Pi:

```bash
sudo ./provision_trainer.sh
```

## Fallback media provisioning

`provision_fallback.sh` installs the **desktop** Raspberry Pi OS image to fallback media (eMMC, microSD, or USB) and prepares it to auto-run NVMe provisioning on every boot. It:

- downloads `raspios_arm64_latest` and flashes it to the selected fallback disk
- creates the default `provision/provision` user
- enables SSH on first boot
- enables passwordless sudo for that user
- prompts for a hostname and writes it to the fallback rootfs
- sets `dtparam=pciex1=on` and `dtparam=ant2`
- clones `https://github.com/ngage-systems/provision.git` onto the fallback image
- sets desktop autostart to run `./provision_nvme_gui.py` on every boot; the GUI launches `sudo ./provision_nvme.sh` after final confirmation

Run it from **NVMe or another non-target boot medium** (it refuses to overwrite the current root device):

```bash
sudo ./provision_fallback.sh
```
