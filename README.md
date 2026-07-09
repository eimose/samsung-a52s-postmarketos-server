# postmarketOS Deployment Walkthrough: Samsung Galaxy A52s 5G (samsung-a52sxq)

## Preamble to guide below

Note to reader: this guide has been automatically generated with the purpose of sharing learnings from turning a Samsung Galaxy A52s into a postmarketOS server.

---

This guide walks you through turning your Samsung Galaxy A52s 5G into a headless postmarketOS server.

It details the workarounds for critical hardware and firmware constraints encountered when installing custom operating systems on modern Samsung Qualcomm devices.

---

## 1. Prerequisites & Host Requirements

Before beginning, ensure your host computer (Linux client desktop) has the required utilities installed:

```bash
sudo apt update
sudo apt install adb fastboot python3 openssl kpartx wget curl expect -y
```

> [!TIP]
> This guide recommends using **Thor** (an open-source Odin-protocol flashing tool) as it handles Samsung's USB protocol boundaries much more reliably than Heimdall. The included `install_pmos_samsung_a52sxq.sh` script automatically fetches and sets up Thor.

---

## 2. Preparing the Device (OEM Unlocking)

The bootloader must be completely unlocked before the device will accept custom partition writes:
1. Boot into stock Android, go to **Settings -> About Phone -> Software Information** and tap **Build Number** 7 times to enable Developer Options.
2. Go to **Settings -> Developer Options** and enable **OEM Unlocking** and **USB Debugging**.
3. Power down the device.
4. Unplug the USB cable.
5. Hold **Volume Up + Volume Down** simultaneously and insert the USB cable connected to your PC.
6. A warning screen will appear. **Long-press Volume Up** (approx. 5 seconds) to enter the bootloader unlock screen, and confirm the unlock by pressing **Volume Up** once.
   * *Note: This will wipe all user data and reboot the device.*
7. Boot back into Android, finish the setup wizard, re-enable **Developer Options**, **OEM Unlocking** (it should show unlocked/greyed out), and **USB Debugging**.

---

## 3. The Core Challenge: Boot Image Header Version 2 & Flash Offsets

Modern Samsung devices using the Qualcomm SM7325 chipset (Snapdragon 778G) boot with strict boot image layout expectations. Setting up `samsung-a52sxq` (which is archived/unmaintained in the main `pmaports` tree) requires modifying two key configuration files inside the pmaports directory on your **Host PC**:
`~/.local/var/pmbootstrap/cache_git/pmaports/device/archived/device-samsung-a52sxq/`

### A. Adjusting `deviceinfo`
You must enforce **boot image header version 2** and specify the precise physical load address offsets for the kernel, ramdisk, and Device Tree Blob (DTB). Without these, the device will bootloop immediately or the build will fail.

Edit the `deviceinfo` file to include:
```bash
# Force Header Version 2 for modern bootloaders
deviceinfo_header_version="2"

# Define precise physical memory offsets
deviceinfo_flash_offset_base="0x00000000"
deviceinfo_flash_offset_kernel="0x00008000"
deviceinfo_flash_offset_ramdisk="0x01000000"
deviceinfo_flash_offset_second="0x00000000"
deviceinfo_flash_offset_tags="0x00000100"
deviceinfo_flash_offset_dtb="0x01f00000"
```

### B. Updating `APKBUILD` Checksums
Since the `deviceinfo` file has been modified, the Alpine package builder (`abuild`) will fail with a checksum mismatch unless the `APKBUILD` is updated. 

1. Calculate the new sha512 checksum:
   ```bash
   sha512sum deviceinfo
   ```
2. Open the `APKBUILD` file in the same directory and update the `sha512sums` block with the calculated hash:
   ```bash
   sha512sums="
   <your-new-sha512-checksum>  deviceinfo
   "
   ```

---

## 4. Automated postmarketOS Flashing & Installation

Once the configuration files are edited and checksummed, run the automated installation script:

```bash
sudo ./install_pmos_samsung_a52sxq.sh
```

### What the script automates:
1. **Host Dependencies**: Installs ADB, Fastboot, and builds/caches the `thor` binary.
2. **USB Contention Resolution**: Automatically stops `ModemManager` and unloads the `cdc_acm` kernel module to prevent USB serial port lockups during the Thor Odin flash phase.
3. **Compilation**: Force-builds the `device-samsung-a52sxq` package with our updated offsets.
4. **Odin Flashing**: Puts the device in Download Mode, launches `thor` via an automated `expect` wrapper, disables AVB verification (`vbmeta.img`), and writes LineageOS Recovery.
5. **Fastbootd Transition**: Boots the device to recovery, utilizes ADB to reboot the phone into `FASTBOOTD` mode, and runs `pmbootstrap flasher` to flash the system rootfs and kernel.
6. **Final Reboot**: Boots the phone directly into postmarketOS.

---

## 5. Connecting and Accessing the Server

Once the phone boots into the postmarketOS console, you can access it via USB networking:
* **USB NCM Interface**: By default, postmarketOS sets up USB NCM interface.
  * **Phone (Server)**: `172.16.42.1`
  * **Host PC (Controller)**: `172.16.42.2`
* **SSH Access**:
  ```bash
  ssh user@172.16.42.1
  ```
  *(Default password is `1234`)*

---

## 6. Stabilizing Wi-Fi (Bypassing NetworkManager Handshake Failures)

Some Qualcomm-based devices (like the Snapdragon 778G / `qca6750`) fail to complete the WPA-PSK 4-way handshake when controlled by NetworkManager. This is due to a protocol mismatch where NetworkManager inadvertently forces WPA3/PMF transition cap fields (`WPA-PSK-SHA256` and `SAE`) in the handshake beacons, causing the AP to drop the connection.

To bypass this and achieve rock-solid connectivity, you should configure the device to run standard `wpa_supplicant` directly via Alpine's native network interfaces controller:

### A. Unmanage `wlan0` in NetworkManager
Instruct NetworkManager to completely ignore the wireless interface:
```bash
sudo sh -c 'cat > /etc/NetworkManager/conf.d/unmanage-wlan0.conf << "EOF"
[keyfile]
unmanaged-devices=interface-name:wlan0
EOF'
```

### B. Configure `wpa_supplicant`
Create a static configuration for the wireless interface:
1. Set the target interface in `/etc/conf.d/wpa_supplicant`:
   ```bash
   sudo sh -c 'cat > /etc/conf.d/wpa_supplicant << "EOF"
   wpa_supplicant_if="wlan0"
   wpa_supplicant_args="-Dnl80211,wext -dd"
   output_log="/var/log/wpa_supplicant.log"
   error_log="/var/log/wpa_supplicant.log"
   EOF'
   ```
2. Write credentials directly to `/etc/wpa_supplicant/wpa_supplicant.conf`:
   ```bash
   sudo sh -c 'cat > /etc/wpa_supplicant/wpa_supplicant.conf << "EOF"
   ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
   update_config=1

   network={
       ssid="YOUR_SSID"
       psk="YOUR_PASSWORD"
       key_mgmt=WPA-PSK
   }
   EOF'
   ```

### C. Configure DHCP and Interface Autostart
1. Tell Alpine's interfaces system to bring up `wlan0` using DHCP by creating `/etc/network/interfaces`:
   ```bash
   sudo sh -c 'cat > /etc/network/interfaces << "EOF"
   auto lo
   iface lo inet loopback

   auto wlan0
   iface wlan0 inet dhcp
   EOF'
   ```
2. Add the networking service to the boot manager:
   ```bash
   sudo rc-update add networking default
   ```

### D. Apply Changes
Restart all services to bind the new network stack:
```bash
sudo rc-service networkmanager restart
sudo rc-service wpa_supplicant restart
sudo rc-service networking start
```
The device will now associate directly using standard WPA-PSK and fetch an IP address via `udhcpc` automatically on boot.

---

## 7. Display & Console Workarounds (kmscon & Backlight)

### A. Preventing kmscon Modesetting Crashes
On the Galaxy A52s, `kmscon` can crash early in the boot process when attempting to modeset on the display due to virtual connectors. To bypass this, force it to use the fbdev (framebuffer) device instead of DRM modesetting:
1. Open `/etc/init.d/kmsconvt` on the phone.
2. Edit the command arguments line to add `--no-drm`:
   ```bash
   command_args_foreground="--vt=${port} --no-switchvt --no-drm"
   ```
3. Additionally, you can disable the virtual connector (Virtual-1) by adding it to the kernel command line:
   Create `/etc/kernel-cmdline.d/90-disable-virtual.conf` containing:
   ```bash
   video=Virtual-1:d
   ```
   And regenerate the boot image using `pmbootstrap bootimg`.

### B. Display Backlight & Power Controls
The AMOLED screen backlight sysfs node is located at `/sys/class/backlight/panel0-backlight` (max brightness 486). The node `/sys/class/backlight/panel` is a virtual node with `max_brightness=0` that returns I/O errors.
Any backlight detection script must filter out nodes with a `max_brightness` of `0` to avoid incorrectly targeting the virtual node. Add these robust aliases to `~/.bashrc`:
```bash
BACKLIGHT_PATH=""
for path in /sys/class/backlight/*; do
  if [ -d "$path" ] && [ -f "$path/max_brightness" ]; then
    max_b=$(cat "$path/max_brightness" 2>/dev/null || echo 0)
    if [ "$max_b" -gt 0 ]; then
      BACKLIGHT_PATH="$path"
      break
    fi
  fi
done
if [ -z "$BACKLIGHT_PATH" ]; then
  for path in /sys/class/backlight/*; do
    if [ -d "$path" ]; then
      BACKLIGHT_PATH="$path"
      break
    fi
  done
fi

if [ -n "$BACKLIGHT_PATH" ]; then
  MAX_BRIGHTNESS=$(cat "$BACKLIGHT_PATH/max_brightness" 2>/dev/null || echo "255")
  alias screen-off="echo 4 | sudo tee $BACKLIGHT_PATH/bl_power > /dev/null 2>&1 || echo 0 | sudo tee $BACKLIGHT_PATH/brightness > /dev/null"
  alias screen-on="echo 0 | sudo tee $BACKLIGHT_PATH/bl_power > /dev/null 2>&1; echo $MAX_BRIGHTNESS | sudo tee $BACKLIGHT_PATH/brightness > /dev/null"
else
  alias screen-off='echo "No backlight device found"'
  alias screen-on='echo "No backlight device found"'
fi
```

---

## 8. WLAN & IPA Firmware Dependencies

The Snapdragon 778G chipset relies on two proprietary subsystems for networking to function:
1. **IPA (Internet Processor Accelerator)**: Handles hardware-accelerated packet routing.
2. **WPSS (Wireless Processor Subsystem)**: Drives the QCA6750 Wi-Fi chip via the `icnss2` kernel driver.

Without staging the correct proprietary firmware blobs and automating the subsystem boot handshakes, the wireless stack will remain inactive.

---

### A. Extracting Stock Firmware Blobs

Android 10+ devices package logical partitions (like `/vendor`) inside a physical `super` partition (`/dev/sda26`). Since the mainline kernel does not map these partitions automatically:

1. **Locate the Super physical partition** (usually `/dev/sda26` on the A52s).
2. **Unpack the logical vendor image** directly on the device using `lpunpack`:
   ```bash
   sudo lpunpack -p vendor /dev/sda26 /tmp/vendor_extract
   ```
3. **Mount the ext4 vendor image** to access its filesystem:
   ```bash
   sudo mkdir -p /mnt/vendor
   sudo mount -o loop,ro /tmp/vendor_extract/vendor.img /mnt/vendor
   ```
4. **Copy the IPA and WPSS firmware files** to the system's firmware directory:
   ```bash
   sudo cp /mnt/vendor/firmware/yupik_ipa_fws.* /lib/firmware/
   sudo cp /mnt/vendor/firmware/wpss.* /lib/firmware/
   ```
5. **Clean up** by unmounting the loop image and deleting the unpacked partition file:
   ```bash
   sudo umount /mnt/vendor
   sudo rm -rf /tmp/vendor_extract
   ```

---

### B. Automating the WPSS Boot & MAC Address Handshake

On mainline Linux, the WLAN driver (`icnss2`) requires a manual subsystem boot and a MAC address injection before it registers the `wlan0` interface. We handle this dynamically on every boot using an OpenRC local startup script.

> [!NOTE]
> The MAC address `00:03:7f:12:67:67` used below is a generic placeholder. You can replace it with your device's actual factory MAC address (found on the box, in stock Android settings, or on your router's lease history) or any valid custom MAC address.

1. **Create the local startup script** at `/etc/local.d/wifi.start`:
   ```bash
   sudo sh -c 'cat > /etc/local.d/wifi.start << "EOF"
   #!/bin/sh
   # Wait for the system/devices to settle
   sleep 2

   # Write 1 to WPSS boot to trigger processor startup
   if [ -f /sys/devices/platform/soc/17a10040.qcom,wcn6750/wpss_boot ]; then
       echo 1 > /sys/devices/platform/soc/17a10040.qcom,wcn6750/wpss_boot
   fi

   # Set MAC address to satisfy macloader interface and register wlan0
   if [ -f /sys/wifi/mac_addr ]; then
       echo "00:03:7f:12:67:67" > /sys/wifi/mac_addr
   fi

   # Wait for wlan0 interface registration
   for i in $(seq 1 10); do
       if ip link show wlan0 >/dev/null 2>&1; then
           break
       fi
       sleep 1
   done

   # Restart wpa_supplicant to bind to wlan0
   rc-service wpa_supplicant restart

   # Bring up wlan0
   ifup wlan0
   EOF'
   ```
2. **Make the script executable**:
   ```bash
   sudo chmod +x /etc/local.d/wifi.start
   ```

---

### C. Bypassing the Fresh-Boot MTU Drop Bug

On a fresh boot, the QCA6750 Wi-Fi driver suffers from a bug where it silently drops TCP/ICMP packets larger than **~1150 bytes**. During SSH key exchange (KEX), host keys exceeding this limit are sent, causing connections to hang at `expecting SSH2_MSG_KEX_ECDH_REPLY` and time out.

**Resolution**: Set the MTU of the `wlan0` interface to `1100`. This forces TCP connections to negotiate a smaller Maximum Segment Size (MSS) of `1060` bytes, bypassing the packet-dropping threshold.

Modify `/etc/network/interfaces` on the device:
```text
auto wlan0
iface wlan0 inet dhcp
    mtu 1100
```
This guarantees the interface automatically initializes with the correct MTU on boot, ensuring SSH connections remain fast and stable.
