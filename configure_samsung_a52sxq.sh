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

read -p "Enter phone IP address [$DEFAULT_IP]: " PHONE_IP
PHONE_IP=${PHONE_IP:-$DEFAULT_IP}

read -p "Enter SSH password [$DEFAULT_PASS]: " PHONE_PASS
PHONE_PASS=${PHONE_PASS:-$DEFAULT_PASS}

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

# Step 2: Install terminal packages on the phone
echo ""
echo ">>> [2/4] Installing btop, neofetch, bash, and bash-completion..."
ssh -o StrictHostKeyChecking=no user@"$PHONE_IP" "echo '$PHONE_PASS' | sudo -S sh -c 'yes | apk add bash bash-completion btop neofetch'"

# Step 3: Configure shell settings, colors, aliases, and screen power controls
echo ""
echo ">>> [3/4] Customizing shell environment (~/.bashrc, ~/.bash_profile)..."

# Change default shell to bash
ssh user@"$PHONE_IP" "echo '$PHONE_PASS' | sudo -S chsh -s /bin/bash user"

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

# Step 4: Configure Wi-Fi connection
echo ""
echo ">>> [4/4] Configuring Wi-Fi network..."
read -p "Would you like to connect the phone to Wi-Fi? (y/n): " CONNECT_WIFI
if [[ "$CONNECT_WIFI" =~ ^[Yy]$ ]]; then
    read -p "  Enter Wi-Fi SSID: " WIFI_SSID
    read -sp "  Enter Wi-Fi Password: " WIFI_PASS
    echo ""
    
    # Auto-detect interface
    WIFI_IFACE=$(ssh user@"$PHONE_IP" "ip -o link show | awk -F': ' '{print \$2}' | grep -E '^wl' | head -n 1" || echo "wlan0")
    if [ -z "$WIFI_IFACE" ]; then WIFI_IFACE="wlan0"; fi
    
    echo "  Connecting phone using interface $WIFI_IFACE to $WIFI_SSID..."
    ssh user@"$PHONE_IP" "echo '$PHONE_PASS' | sudo -S nmcli device wifi connect '$WIFI_SSID' password '$WIFI_PASS' ifname $WIFI_IFACE"
    
    echo "  Disabling Wi-Fi power saving..."
    ssh user@"$PHONE_IP" "echo '$PHONE_PASS' | sudo -S nmcli connection modify id '$WIFI_SSID' 802-11-wireless.powersave 2"
    ssh user@"$PHONE_IP" "echo '$PHONE_PASS' | sudo -S nmcli connection up id '$WIFI_SSID'"
    
    echo "  Checking Wi-Fi IP address..."
    ssh user@"$PHONE_IP" "ip address show dev $WIFI_IFACE | grep inet"
fi

echo ""
echo "============================================================"
echo " Configuration Complete!"
echo "============================================================"
echo " The node is now configured."
echo " You can connect via SSH over Wi-Fi or USB."
echo "============================================================"
