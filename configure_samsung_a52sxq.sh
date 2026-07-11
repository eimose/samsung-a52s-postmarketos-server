#!/bin/bash

# =============================================================================
# Headless postmarketOS Node Configurator — Samsung Galaxy A52s 5G (samsung-a52sxq)
# Runs on the host controller to set up the newly flashed worker node.
# =============================================================================

set -e

DEFAULT_IP="172.16.42.1"
DEFAULT_PASS="1234"

echo "============================================================"
echo " Headless Node Configurator — postmarketOS (Galaxy A52s 5G)"
echo "============================================================"
echo ""

PHONE_IP="${1:-}"
if [ -z "$PHONE_IP" ]; then
    read -p "Enter phone IP address [$DEFAULT_IP]: " PHONE_IP
    PHONE_IP=${PHONE_IP:-$DEFAULT_IP}
fi

PHONE_PASS="${2:-}"
if [ -z "$PHONE_PASS" ]; then
    read -p "Enter SSH password [$DEFAULT_PASS]: " PHONE_PASS
    PHONE_PASS=${PHONE_PASS:-$DEFAULT_PASS}
fi

# Clear old SSH host key if it exists
ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$PHONE_IP" 2>/dev/null || true

# Step 1: Copy SSH public key to the phone for passwordless SSH
echo ""
echo ">>> [1/4] Configuring passwordless SSH login..."
PUB_KEY="$HOME/.ssh/id_ed25519.pub"
if [ ! -f "$PUB_KEY" ] && [ -f "$HOME/.ssh/id_rsa.pub" ]; then
    PUB_KEY="$HOME/.ssh/id_rsa.pub"
fi

if [ ! -f "$PUB_KEY" ]; then
    echo "    No SSH key found. Generating one on host..."
    ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N ""
    PUB_KEY="$HOME/.ssh/id_ed25519.pub"
fi

echo "    Copying SSH public key to the phone..."
if command -v expect >/dev/null 2>&1; then
    expect -c "
        spawn ssh-copy-id -o StrictHostKeyChecking=no -i $PUB_KEY user@$PHONE_IP
        expect \"*assword:*\" { send \"$PHONE_PASS\r\" }
        expect eof
    "
else
    echo "    (Expect not found; please enter password if prompted)"
    ssh-copy-id -o StrictHostKeyChecking=no -i "$PUB_KEY" user@"$PHONE_IP"
fi

# Step 2: Configure shell settings, colors, aliases, and screen power controls
echo ""
echo ">>> [2/4] Customizing shell environment (~/.bashrc, ~/.bash_profile)..."

# Generate local temporary bashrc config with auto-backlight detection
TMP_BASHRC="/tmp/phone_bashrc_$$"
cat > "$TMP_BASHRC" << 'EOF'
# User aliases
alias ll='ls -hall --color=auto'
alias ls='ls --color=auto'
alias grep='grep --color=auto'

# Auto-detect backlight sysfs path (preferring paths with max_brightness > 0)
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

# Set pleasant Ubuntu-like colors for prompt
PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

# Enable bash completion
if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi

# Run neofetch on login
neofetch
EOF

# Copy bashrc configuration
scp "$TMP_BASHRC" user@"$PHONE_IP":~/.bashrc
rm -f "$TMP_BASHRC"

# Write bash_profile to trigger bashrc
ssh user@"$PHONE_IP" 'cat > ~/.bash_profile << "EOF"
if [ -f ~/.bashrc ]; then
    . ~/.bashrc
fi
EOF'

# Step 3: Configure Wi-Fi & Firmware
echo ""
echo ">>> [3/4] Configuring Wi-Fi network and staging firmware..."
CONNECT_WIFI="${5:-}"
if [ -z "$CONNECT_WIFI" ]; then
    read -p "Would you like to connect the phone to Wi-Fi? (y/n): " CONNECT_WIFI
fi

if [[ "$CONNECT_WIFI" =~ ^[Yy]$ ]]; then
    WIFI_SSID="${3:-}"
    if [ -z "$WIFI_SSID" ]; then
        read -p "  Enter Wi-Fi SSID: " WIFI_SSID
    fi
    WIFI_PASS="${4:-}"
    if [ -z "$WIFI_PASS" ]; then
        read -sp "  Enter Wi-Fi Password: " WIFI_PASS
        echo ""
    fi
    
    # 1. Firmware Check and Extraction
    echo "  Checking for proprietary connectivity firmware..."
    ssh user@"$PHONE_IP" "echo '$PHONE_PASS' | sudo -S sh -c '
        if [ ! -f /lib/firmware/wpss.mdt ] || [ ! -f /lib/firmware/yupik_ipa_fws.mdt ]; then
            echo \"  -> Staging firmware from logical vendor partition...\"
            if [ -f /dev/sda26 ]; then
                mkdir -p /tmp/vendor_extract /mnt/vendor
                lpunpack -p vendor /dev/sda26 /tmp/vendor_extract
                mount -o loop,ro /tmp/vendor_extract/vendor.img /mnt/vendor
                cp /mnt/vendor/firmware/yupik_ipa_fws.* /lib/firmware/
                cp /mnt/vendor/firmware/wpss.* /lib/firmware/
                umount /mnt/vendor
                rm -rf /tmp/vendor_extract
                echo \"  ✓ Firmware extracted successfully.\"
            else
                echo \"  ERROR: /dev/sda26 (super partition) not found. Cannot extract stock firmware.\"
                exit 1
            fi
        else
            echo \"  ✓ Firmware blobs already present.\"
        fi
    '"

    # 2. Configure NetworkManager to ignore wlan0
    echo "  Configuring NetworkManager to unmanage wlan0..."
    ssh user@"$PHONE_IP" "echo '$PHONE_PASS' | sudo -S sh -c '
        mkdir -p /etc/NetworkManager/conf.d
        cat > /etc/NetworkManager/conf.d/unmanage-wlan0.conf << \"EOF\"
[keyfile]
unmanaged-devices=interface-name:wlan0
EOF
    '"

    # 3. Create wpa_supplicant configuration
    echo "  Configuring wpa_supplicant..."
    ssh user@"$PHONE_IP" "echo '$PHONE_PASS' | sudo -S sh -c '
        cat > /etc/conf.d/wpa_supplicant << \"EOF\"
wpa_supplicant_if=\"wlan0\"
wpa_supplicant_args=\"-Dnl80211,wext -dd\"
output_log=\"/var/log/wpa_supplicant.log\"
error_log=\"/var/log/wpa_supplicant.log\"
EOF

        cat > /etc/wpa_supplicant/wpa_supplicant.conf << \"EOF\"
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

network={
    ssid=\"$WIFI_SSID\"
    psk=\"$WIFI_PASS\"
    key_mgmt=WPA-PSK
}
EOF
        chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf
    '"

    # 4. Create /etc/network/interfaces with MTU 1100 workaround
    echo "  Configuring /etc/network/interfaces (with MTU 1100 fix)..."
    ssh user@"$PHONE_IP" "echo '$PHONE_PASS' | sudo -S sh -c '
        cat > /etc/network/interfaces << \"EOF\"
auto lo
iface lo inet loopback

auto wlan0
iface wlan0 inet dhcp
    mtu 1100
EOF
    '"

    # 5. Create local startup script to boot WPSS and inject MAC address
    echo "  Creating OpenRC local startup script..."
    ssh user@"$PHONE_IP" "echo '$PHONE_PASS' | sudo -S sh -c '
        cat > /etc/local.d/wifi.start << \"EOF\"
#!/bin/sh
sleep 2
if [ -f /sys/devices/platform/soc/17a10040.qcom,wcn6750/wpss_boot ]; then
    echo 1 > /sys/devices/platform/soc/17a10040.qcom,wcn6750/wpss_boot
fi
if [ -f /sys/wifi/mac_addr ]; then
    echo \"00:03:7f:12:67:67\" > /sys/wifi/mac_addr
fi
for i in \$(seq 1 10); do
    if ip link show wlan0 >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
rc-service wpa_supplicant restart
ifup wlan0
sleep 2
if ! ip route | grep -q default; then
    ip route add default via 192.168.18.1 dev wlan0 2>/dev/null || true
fi
EOF
        chmod +x /etc/local.d/wifi.start
    '"

    # 6. Enable services and bring up interface
    echo "  Enabling services and connecting..."
    ssh user@"$PHONE_IP" "echo '$PHONE_PASS' | sudo -S sh -c '
        rc-update add local default >/dev/null 2>&1 || true
        rc-update add networking default >/dev/null 2>&1 || true
        rc-service local restart
    '"

    # 7. Check lease IP
    echo "  Waiting for Wi-Fi association and DHCP lease..."
    sleep 5
    ssh user@"$PHONE_IP" "ip address show dev wlan0 | grep inet" || echo "  Warning: wlan0 has not acquired an IP yet. It may take up to 10 seconds."
fi

# Step 4: Install terminal packages on the phone (now that Wi-Fi is online)
echo ""
echo ">>> [4/4] Installing btop, neofetch, bash, and bash-completion..."
ssh -o StrictHostKeyChecking=no user@"$PHONE_IP" "echo '$PHONE_PASS' | sudo -S sh -c 'yes | apk add bash bash-completion btop neofetch'"

# Change default shell to bash now that bash is installed
echo "  Changing default shell to bash..."
ssh user@"$PHONE_IP" "echo '$PHONE_PASS' | sudo -S chsh -s /bin/bash user"

echo ""
echo "============================================================"
echo " Configuration Complete!"
echo "============================================================"
echo " The node is now configured."
echo " You can connect via SSH over Wi-Fi or USB."
echo "============================================================"
