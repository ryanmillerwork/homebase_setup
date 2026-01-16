# provision_nvme_from_emmc

Provision an NVMe boot drive on **Raspberry Pi OS Bookworm (or later)** while booted from **eMMC/mmc**, by flashing **`raspios_lite_arm64_latest`** to NVMe and applying minimal “headless” config (SSH + user + Wi-Fi), then switching EEPROM boot order to NVMe-first and rebooting.

## What it does

- **Validates**: Bookworm+; root filesystem is on an `mmcblk*` device; NVMe disk exists.
- **Prompts for Wi-Fi first (always)**: it asks for SSID/password up front, attempts to connect the *current* system via `nmcli`, and **requires verified internet** before continuing (so package install + image download work).
- **Installs packages**: `wget`, `xz-utils`, `openssl`, `iw`, `network-manager`, `rpi-eeprom`, etc.
- **Flashes**: downloads `raspios_lite_arm64_latest` and streams it to the NVMe via `xzcat | dd`.
- **Configures on the NVMe image**:
  - enables SSH (creates `ssh` on the boot partition)
  - creates user/password (writes `userconf.txt` on the boot partition)
  - configures Wi-Fi for the installed NVMe OS (creates a NetworkManager `*.nmconnection` profile in the NVMe **rootfs**)
  - prompts for a **hostname** and writes it into the NVMe rootfs (`/etc/hostname` + `/etc/hosts`)
  - ensures `dtparam=pciex1=on` in NVMe `config.txt` (if present)
- **Sets EEPROM boot order**: best-effort non-interactive edit to `BOOT_ORDER=0xf416` and `PCIE_PROBE=1`.
- **Reboots**.

## Usage

Copy the script to the Pi and run:

```bash
chmod +x ./provision_nvme_from_emmc.sh
sudo ./provision_nvme_from_emmc.sh
```

You will be prompted to:

- enter Wi-Fi SSID/password (used to connect the current system; then also applied to the NVMe OS)
- choose the NVMe disk (if there are multiple)
- type **`ERASE`** to confirm destroying that disk
- enter desired **hostname**
- enter a username/password for first boot

## Notes / caveats

- This script is **destructive** to the selected NVMe disk.
- “Running on eMMC” is checked via `mmcblk*` root device **plus** a heuristic for `/dev/mmcblk*boot0`. If you really are on microSD and want to proceed, set:

```bash
sudo HB_ALLOW_NON_EMMC=1 ./provision_nvme_from_emmc.sh
```

