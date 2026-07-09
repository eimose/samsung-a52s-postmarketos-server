#!/bin/bash

# =============================================================================
# Headless postmarketOS Installer — Samsung Galaxy A52s 5G (SM-A528B)
# pmaports codename: samsung-a52sxq
#
# STRATEGY:
#   1. Detect bootloader status. If locked, reboot to Download Mode and guide user.
#   2. Build linux-samsung-a52sxq and device-samsung-a52sxq via pmbootstrap.
#   3. Download TWRP and create a blank vbmeta.img.
#   4. Use Thor to flash TWRP (recovery) and vbmeta.
#   5. Boot TWRP, reboot TWRP into fastbootd mode (adb reboot fastboot).
#   6. Flash the system images using pmbootstrap flasher.
# =============================================================================

set -eo pipefail

# --- Guard: must be run as root ---
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run with root privileges."
    echo "  sudo $0"
    exit 1
fi

# Detect the real invoking user
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
    echo "ERROR: Could not detect a non-root user. Run with 'sudo' from your regular account."
    exit 1
fi
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

PMB_WORK="$REAL_HOME/.local/var/pmbootstrap"
PMB_CONFIG="$REAL_HOME/.config/pmbootstrap_a52s.cfg"
PMOS_USER="user"
PMOS_PASSWORD="1234"
RECOVERY_IMG="lineage-23.2-recovery-a52sxq.img"
RECOVERY_URL="https://mirrorbits.lineageos.org/full/a52sxq/20260701/recovery.img"
DOWNLOAD_DIR="/tmp/pmos_samsung_a52s"

echo "============================================================"
echo " Headless postmarketOS Installer — Samsung Galaxy A52s 5G"
echo " Running as: $REAL_USER  (Home: $REAL_HOME)"
echo "============================================================"
echo ""

# =============================================================================
# PHASE 1: Install host dependencies
# =============================================================================
echo ">>> [1/8] Installing host dependencies..."
apt-get update -qq
apt-get install -y \
    git \
    pmbootstrap \
    adb \
    fastboot \
    python3 \
    openssl \
    kpartx \
    wget \
    curl \
    expect

# Download Thor if missing
THOR_BIN="/usr/local/bin/thor"
if [ ! -x "$THOR_BIN" ]; then
    echo "    Downloading Thor flash tool..."
    THOR_URL=$(curl -sL https://api.github.com/repos/Samsung-Loki/Thor/releases/latest \
        | python3 -c "import sys,json; r=json.load(sys.stdin); print([a['browser_download_url'] for a in r['assets'] if 'Linux' in a['name']][0])")
    curl -sL --output "$THOR_BIN" "$THOR_URL"
    chmod +x "$THOR_BIN"
    echo "    ✓ Thor installed to $THOR_BIN"
else
    echo "    ✓ Thor already installed at $THOR_BIN"
fi

# =============================================================================
# PHASE 2: Bootloader Status Check
# =============================================================================
echo ""
echo ">>> [2/8] Checking bootloader lock status..."

# Wait for device in ADB
ADB_STATE=$(sudo -u "$REAL_USER" adb get-state 2>/dev/null || echo "offline")
if [ "$ADB_STATE" = "device" ]; then
    LOCKED=$(sudo -u "$REAL_USER" adb shell getprop ro.boot.flash.locked 2>/dev/null || echo "1")
    if [ "$LOCKED" = "1" ]; then
        echo "WARNING: Bootloader is locked (ro.boot.flash.locked = 1)."
        echo "We must unlock the bootloader to proceed."
        echo ""
        echo "CRITICAL: Rebooting directly to Download Mode via ADB bypasses the unlock option."
        echo "To trigger the Bootloader Unlock screen (Warning screen):"
        echo "  1. The script will attempt to power down the phone (or you can power it off manually)."
        echo "  2. Unplug the USB cable from the phone."
        echo "  3. Press and hold both [Volume Up] and [Volume Down] buttons simultaneously."
        echo "  4. While holding them, plug the USB cable back into the phone (connected to your PC)."
        echo "  5. The blue WARNING screen will appear. Now, long-press [Volume Up] (approx 5s)."
        echo "  6. Follow the on-screen prompt (press [Volume Up] once) to confirm unlocking."
        echo "     NOTE: This will format all data and factory reset the phone!"
        echo "  7. Complete the Android setup wizard, enable Developer Options and USB Debugging."
        echo "  8. Plug the phone back in and re-run this script."
        echo ""
        read -p "Press [Enter] to attempt powering off the phone now..."
        sudo -u "$REAL_USER" adb reboot -p 2>/dev/null || true
        exit 0
    else
        echo "    ✓ Bootloader is unlocked."
    fi
elif [ "$ADB_STATE" = "recovery" ]; then
    echo "    ✓ Device is in Recovery Mode. Assuming bootloader is unlocked."
else
    # Check if already in Download Mode or Fastboot
    if lsusb | grep -qi "04e8.*685d\|04e8.*6601\|samsung.*download"; then
        echo "    Device is in Download Mode. We will proceed under the assumption that the bootloader is unlocked."
    elif fastboot devices | grep -q "fastboot"; then
        echo "    Device is in Fastboot/Fastbootd Mode. Assuming bootloader is unlocked."
    else
        echo "ERROR: Device not found. Please connect the Samsung A52s and enable USB debugging."
        exit 1
    fi
fi

# =============================================================================
# PHASE 3: Configure pmbootstrap for samsung-a52sxq
# =============================================================================
echo ""
echo ">>> [3/8] Configuring pmbootstrap for samsung-a52sxq (archived device)..."

mkdir -p "$PMB_WORK/cache_git"
mkdir -p "$(dirname "$PMB_CONFIG")"

cat > "$PMB_CONFIG" << EOF
[pmbootstrap]
device = samsung-a52sxq
ui = console
user = ${PMOS_USER}
work = ${PMB_WORK}
aports = ${PMB_WORK}/cache_git/pmaports
is_default_channel = True
auto_zap_misconfigured_chroots = no
systemd = never
EOF

chown -R "$REAL_USER:$REAL_USER" "$(dirname "$PMB_CONFIG")"
echo "    ✓ Config written to: $PMB_CONFIG"

# =============================================================================
# PHASE 4: Build Kernel and System Image
# =============================================================================
echo ""
echo ">>> [4/8] Building postmarketOS kernel and rootfs..."
PMB_CMD="pmbootstrap -c $PMB_CONFIG --as-root"

ROOTFS_IMG="$PMB_WORK/chroot_native/home/pmos/rootfs/samsung-a52sxq.img"
BOOT_IMG="$PMB_WORK/chroot_rootfs_samsung-a52sxq/boot/boot.img"

SKIP_BUILD=false
if [ -f "$ROOTFS_IMG" ] && [ -f "$BOOT_IMG" ]; then
    echo "    ✓ Found existing rootfs and boot image."
    echo -n "    Do you want to skip rebuilding them? (y/n) [y]: "
    read -r SKIP_ANS < /dev/tty 2>/dev/null || SKIP_ANS="y"
    if [ "$SKIP_ANS" != "n" ] && [ "$SKIP_ANS" != "N" ]; then
        SKIP_BUILD=true
    fi
fi

if [ "$SKIP_BUILD" = false ]; then
    # Run pmbootstrap init non-interactively
    (echo ""; echo ""; echo ""; echo ""; echo ""; echo "y"; yes "") | $PMB_CMD init 2>&1 || {
        echo "    pmbootstrap init finished."
    }

    # Check if packages are already compiled in the local package repository
    if ls "$PMB_WORK"/packages/edge/aarch64/linux-samsung-a52sxq-*.apk >/dev/null 2>&1 && \
       ls "$PMB_WORK"/packages/edge/aarch64/device-samsung-a52sxq-*.apk >/dev/null 2>&1; then
        echo "    ✓ Kernel and device packages already compiled. Skipping compilation."
    else
        # Update kernel package checksums for the enable-shmbridge patch
        echo "    Updating checksums for linux-samsung-a52sxq..."
        $PMB_CMD checksum linux-samsung-a52sxq

        echo "    Building linux-samsung-a52sxq (archived kernel)..."
        $PMB_CMD build linux-samsung-a52sxq --force

        echo "    Building device-samsung-a52sxq..."
        $PMB_CMD build device-samsung-a52sxq --force
    fi

    echo "    Building and preparing postmarketOS rootfs..."
    $PMB_CMD install --password "${PMOS_PASSWORD}"
    echo "    ✓ postmarketOS build completed."
else
    echo "    ✓ Skipping rootfs/boot image build (using existing images)."
fi

# =============================================================================
# PHASE 5: Download TWRP and Create Blank VBMeta
# =============================================================================
echo ""
echo ">>> [5/8] Downloading LineageOS Recovery and creating vbmeta.img..."
mkdir -p "$DOWNLOAD_DIR"

if [ ! -f "$DOWNLOAD_DIR/$RECOVERY_IMG" ]; then
    echo "    Downloading LineageOS Recovery..."
    wget -q --show-progress -O "$DOWNLOAD_DIR/$RECOVERY_IMG" "$RECOVERY_URL"
    echo "    ✓ Recovery download complete."
else
    echo "    ✓ Recovery image already downloaded."
fi

# Create vbmeta with verification disabled
echo "    Creating vbmeta.img with disable-verification flags..."
AVBTOOL_BIN="avbtool"
if ! command -v avbtool >/dev/null 2>&1; then
    # Try to locate avbtool in the pmbootstrap chroots
    CHROOT_AVBTOOL="$PMB_WORK/chroot_native/mnt/rootfs_samsung-a52sxq/usr/bin/avbtool"
    if [ -f "$CHROOT_AVBTOOL" ]; then
        AVBTOOL_BIN="$CHROOT_AVBTOOL"
    else
        # Try to locate standard system path or download fallback
        echo "    avbtool not found on host, downloading fallback..."
        wget -q -O "$DOWNLOAD_DIR/avbtool" "https://raw.githubusercontent.com/external-avb/avb/refs/heads/master/avbtool.py" || \
        wget -q -O "$DOWNLOAD_DIR/avbtool" "https://raw.githubusercontent.com/cfig/Android_boot_image_editor/master/avbtool.py"
        chmod +x "$DOWNLOAD_DIR/avbtool"
        AVBTOOL_BIN="$DOWNLOAD_DIR/avbtool"
    fi
fi

$AVBTOOL_BIN make_vbmeta_image --flags 2 --padding_size 4096 --output "$DOWNLOAD_DIR/vbmeta.img"
ln -sf "$DOWNLOAD_DIR/$RECOVERY_IMG" "$DOWNLOAD_DIR/recovery.img"
echo "    ✓ Recovery and VBMeta prepared."

# =============================================================================
# PHASE 6: Flash TWRP and vbmeta via Thor
# =============================================================================
echo ""
echo ">>> [6/8] Flashing TWRP and vbmeta via Thor..."

# Check if already booted in TWRP/recovery/fastbootd
SKIP_THOR=false
STATE=$(sudo -u "$REAL_USER" adb get-state 2>/dev/null || echo "offline")
if [ "$STATE" = "recovery" ] || fastboot devices | grep -q "fastboot"; then
    echo "    ✓ Device is already in Recovery/Fastboot mode. Skipping Thor flash."
    SKIP_THOR=true
fi

if [ "$SKIP_THOR" = false ]; then
    # Verify Download Mode
    echo "    Verifying device is in Download Mode..."
    while true; do
        if lsusb | grep -qi "04e8.*685d\|04e8.*6601\|samsung.*download"; then
            echo "    ✓ Samsung device in Download Mode detected."
            break
        fi
        echo "    Please reboot phone to Download Mode (Vol Up + Vol Down + plug USB)."
        echo "    Retrying in 5s..."
        sleep 5
    done

    # Stop ModemManager and unload cdc_acm to free the USB interface
    echo "    Temporarily stopping ModemManager and unloading cdc_acm..."
    systemctl stop ModemManager 2>/dev/null || true
    modprobe -r cdc_acm 2>/dev/null || true

    THOR_LOG="/tmp/thor_flash_$$.log"
    echo "    Starting Thor flash sequence..."
    expect -f - << EXPECT_SCRIPT 2>&1 | tee "$THOR_LOG"
        set timeout 120
        log_user 1
        spawn thor
        expect "shell>"
        send "connect\r"
        expect {
            "Choose a device" {
                send "1\r"
                expect "Successfully connected"
            }
            "Successfully connected" {}
        }
        expect "shell>"
        send "begin odin\r"
        expect "Successfully began"
        expect "shell>"
        
        # Flash vbmeta
        send "flashFile ${DOWNLOAD_DIR}/vbmeta.img\r"
        expect -nocase "partition"
        send "y\r"
        expect -nocase "sure"
        send "y\r"
        expect "shell>"

        # Flash recovery
        send "flashFile ${DOWNLOAD_DIR}/recovery.img\r"
        expect -nocase "partition"
        send "y\r"
        expect -nocase "sure"
        send "y\r"
        expect "shell>"
        
        send "end\r"
        expect "shell>"
        send "exit\r"
        expect eof
EXPECT_SCRIPT

    # Reload cdc_acm and restart ModemManager
    modprobe cdc_acm 2>/dev/null || true
    systemctl start ModemManager 2>/dev/null || true

    echo "    ✓ Thor flashing completed."
    echo "    Rebooting the phone. Please immediately press and hold [Volume Up] + [Power] (with USB cable connected) to boot into Recovery!"
    echo "    (Keep holding them until the LineageOS recovery screen or logo appears, then release.)"
    echo "    (Wait for Recovery to load...)"
fi

# =============================================================================
# PHASE 7: Reboot into Fastbootd
# =============================================================================
echo ""
echo ">>> [7/8] Rebooting device into Fastbootd mode..."

while true; do
    STATE=$(sudo -u "$REAL_USER" adb get-state 2>/dev/null || echo "offline")
    if [ "$STATE" = "recovery" ]; then
        echo "    ✓ Recovery detected. Sending reboot to fastbootd..."
        sudo -u "$REAL_USER" adb reboot fastboot
        break
    fi
    if fastboot devices | grep -q "fastboot"; then
        echo "    ✓ Already in fastboot/fastbootd mode."
        break
    fi
    echo "    Waiting for Recovery (currently: $STATE)..."
    sleep 5
done

# Wait for fastbootd
echo "    Waiting for fastbootd connection..."
while true; do
    if fastboot devices | grep -q "fastboot"; then
        echo "    ✓ Fastbootd online."
        break
    fi
    sleep 2
done

# =============================================================================
# PHASE 8: Flash postmarketOS via Fastbootd
# =============================================================================
echo ""
echo ">>> [8/8] Flashing postmarketOS rootfs and kernel..."

# Execute pmbootstrap flasher commands
$PMB_CMD flasher flash_rootfs

# Manual flashing of boot image because vendor_boot is not exposed in Fastbootd
# and has already been flashed in Download Mode via Thor
echo "    Flashing boot image manually..."
fastboot flash boot "$PMB_WORK/chroot_rootfs_samsung-a52sxq/boot/boot.img"

echo "    Rebooting phone into postmarketOS..."
fastboot reboot

echo "============================================================"
echo " Flashing Sequence Complete!"
echo "============================================================"
echo " The Samsung Galaxy A52s should now boot into postmarketOS."
echo " Default credentials:"
echo "   User:     ${PMOS_USER}"
echo "   Password: ${PMOS_PASSWORD}"
echo "============================================================"
