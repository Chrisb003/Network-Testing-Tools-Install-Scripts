#!/bin/sh

# Ensure we run as a standard user for paths, but keep sudo available for apt commands
if [ "$(id -u)" -eq 0 ]; then
    echo "[!] Please do NOT run this script directly with 'sudo'. Run it as your normal user."
    echo "    The script will prompt for sudo credentials only when necessary."
    exit 1
fi

# --- 0. OS COMPATIBILITY CHECK ---
OS_NAME=$(uname -s)
if [ "$OS_NAME" = "Darwin" ]; then
    echo "[!] macOS detected. Please use the 'MacOS-Installer.sh' script instead."
    exit 1
elif [ "$OS_NAME" != "Linux" ]; then
    echo ""
    echo "[!] WARNING: This script is designed specifically for Linux."
    echo "    Your operating system is identified as '$OS_NAME'."
    printf "    Do you want to attempt the installation anyway? (y/N): "
    read force_install < /dev/tty
    case "$force_install" in
        [Yy]* ) 
            echo "    [*] Proceeding with installation at your own risk..." 
            ;;
        * ) 
            echo "    [*] Installation aborted."
            exit 1 
            ;;
    esac
fi

# --- 1. CONFIGURATION ---
TARGET_DIR="$HOME/Network-Testing-Tools"
REPO_OWNER="Chrisb003"
REPO_NAME="Network-Testing-Tools"
BRANCH="main"
TOKEN=""
SERVICE_NAME="network-dashboard.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
AUTOSTART_DIR="$HOME/.config/autostart"
AUTOSTART_FILE="$AUTOSTART_DIR/Network-Diagnostics.desktop"
SCRIPT_VERSION="1.0.2"

# --- 2. EXISTING INSTALLATION CHECK & UNINSTALL OPTION ---
if [ -d "$TARGET_DIR" ]; then
    echo "========================================================"
    echo "   NETWORK DIAGNOSTICS - LINUX INSTALLER & MANAGER"
    echo "   Installer Version: $SCRIPT_VERSION"
    echo "========================================================"
    echo ""
    echo "[*] Existing installation detected at $TARGET_DIR."
    printf "[?] Do you want to REMOVE the existing installation? (y/N): "
    read remove_app < /dev/tty
    
    case "$remove_app" in
        [Yy]* )
            printf "[?] Do you want to KEEP your database files? (y/N): "
            read keep_db < /dev/tty
            
            printf "[?] Are you ABSOLUTELY sure you want to uninstall? Type 'yes' to confirm: "
            read confirm_wipe < /dev/tty
            
            if [ "$confirm_wipe" = "yes" ]; then
                
                # Cleanup old systemd service if it existed
                if [ -f "$SERVICE_FILE" ]; then
                    echo "[*] Stopping system service..."
                    sudo systemctl stop "$SERVICE_NAME" >/dev/null 2>&1
                    sudo systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
                    sudo rm -f "$SERVICE_FILE"
                    sudo systemctl daemon-reload
                fi
                
                # --- BACKUP LOGIC (DATABASE ONLY) ---
                case "$keep_db" in
                    [Yy]* )
                        BACKUP_DIR="$HOME/Desktop/Network-Diagnostics-Backup"
                        echo "[*] Backing up database files to $BACKUP_DIR..."
                        mkdir -p "$BACKUP_DIR"
                        # Use sudo to copy in case the files are currently owned by root (systemd)
                        sudo find "$TARGET_DIR" -type f \( -name "*.db" -o -name "*.sqlite" \) -exec cp {} "$BACKUP_DIR/" \;
                        # Ensure the user has full permissions to edit or delete the backed-up files
                        sudo chown -R "$USER:$USER" "$BACKUP_DIR"
                        sudo chmod -R 777 "$BACKUP_DIR"
                        echo "[+] Data backed up safely."
                        ;;
                esac
                
                echo "[*] Deleting application directory..."
                sudo rm -rf "$TARGET_DIR"
                
                echo "[*] Removing shortcuts..."
                rm -f "$HOME/Desktop/Network-Diagnostics.desktop"
                rm -f "$HOME/.local/share/applications/Network-Diagnostics.desktop"
                rm -f "$AUTOSTART_FILE"
                
                echo "[✓] Application completely removed."
                exit 0
            else
                echo "[*] Deletion cancelled."
            fi
            ;;
    esac
fi

# --- 3. WELCOME BANNER & INSTALL PROMPT ---
echo "========================================================"
echo "   NETWORK DIAGNOSTICS - LINUX INSTALLER & MANAGER"
echo "   Installer Version: $SCRIPT_VERSION"
echo "========================================================"
echo "This script installs, updates, or manages the Network"
echo "Diagnostics Dashboard, Python dependencies, and tools."
echo ""
printf "[?] Do you want to proceed with the installation of system prerequisites? (y/N): "
read proceed < /dev/tty

SKIP_PREREQS=false
case "$proceed" in
    [Yy]* ) ;;
    * ) 
        echo "[*] Skipping system prerequisites. Moving to application updates and configuration..."
        SKIP_PREREQS=true 
        ;;
esac

# --- 4. PREREQUISITES (Multi-Distro Support) ---
if [ "$SKIP_PREREQS" = false ]; then
    echo ""
    echo "[*] Step 1: Installing system prerequisites (sudo password may be required)..."

    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update
        sudo apt-get install -y python3 python3-venv python3-pip python3-dev build-essential net-tools libpcap-dev unzip curl network-manager python3-gi gir1.2-gtk-3.0 libayatana-appindicator3-1 python3-xlib
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y python3 python3-pip python3-devel gcc net-tools libpcap-devel unzip curl NetworkManager python3-gobject gtk3 libappindicator-gtk3 python3-xlib
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -Syu --noconfirm python python-pip base-devel net-tools libpcap unzip curl networkmanager python-gobject gtk3 libappindicator-gtk3 python-xlib
    elif command -v zypper >/dev/null 2>&1; then
        sudo zypper refresh
        sudo zypper install -y python3 python3-pip python3-devel gcc net-tools libpcap-devel unzip curl NetworkManager python3-gobject gtk3 libappindicator-gtk3 python3-xlib
    else
        echo "[!] Warning: Unknown package manager. Please ensure Python 3, venv, pip, libpcap, and curl are installed manually."
    fi
fi

# --- 4b. RASPBERRY PI WI-FI COUNTRY CHECK ---
if command -v raspi-config >/dev/null 2>&1; then
    # Check if the Wi-Fi country is set. On Pi OS, an unset country returns empty.
    CURRENT_COUNTRY=$(raspi-config nonint get_wifi_country 2>/dev/null)
    if [ -z "$CURRENT_COUNTRY" ] || [ "$CURRENT_COUNTRY" = "00" ]; then
        echo ""
        echo "[!] Raspberry Pi detected, but Wi-Fi country is NOT set."
        echo "    This will prevent Wi-Fi interfaces and Hotspots from working properly."
        printf "    Enter your 2-letter Wi-Fi country code (e.g., GB, US, DE) or press Enter to skip: "
        read WIFI_COUNTRY < /dev/tty
        
        if [ -n "$WIFI_COUNTRY" ]; then
            # Convert input to uppercase and grab the first 2 characters
            WIFI_COUNTRY=$(echo "$WIFI_COUNTRY" | tr 'a-z' 'A-Z' | cut -c 1-2)
            echo "    [*] Setting Wi-Fi country to $WIFI_COUNTRY..."
            sudo raspi-config nonint do_wifi_country "$WIFI_COUNTRY" >/dev/null 2>&1
            # Explicitly unblock Wi-Fi now that a legal country is defined
            sudo rfkill unblock wifi >/dev/null 2>&1
            echo "    [✓] Wi-Fi country successfully configured."
        else
            echo "    [*] Skipping Wi-Fi country configuration."
        fi
    fi
fi

# --- 5. DOWNLOAD OR UPDATE CODE ---
echo ""
echo "[*] Step 2: Managing application files..."
if [ ! -d "$TARGET_DIR" ]; then
    echo "[*] Downloading latest project files from GitHub..."
    if [ -n "$TOKEN" ]; then
        curl -s -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github.v3+json" -L "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/zipball/$BRANCH" -o /tmp/network_dashboard.zip
    else
        curl -s -L "https://github.com/$REPO_OWNER/$REPO_NAME/archive/refs/heads/$BRANCH.zip" -o /tmp/network_dashboard.zip
    fi
    
    mkdir -p /tmp/network_dashboard_extract
    unzip -q /tmp/network_dashboard.zip -d /tmp/network_dashboard_extract
    EXTRACTED_FOLDER=$(ls -d /tmp/network_dashboard_extract/*/)
    mv "$EXTRACTED_FOLDER" "$TARGET_DIR"
    rm -rf /tmp/network_dashboard.zip /tmp/network_dashboard_extract
    echo "[✓] Files downloaded into $TARGET_DIR."
else
    echo "[✓] Code directory already exists. Skipping full re-download to preserve existing configs/database."
    printf "[?] Do you want to pull/update latest code changes from GitHub repository? (y/N): "
    read update_code < /dev/tty
    case "$update_code" in
        [Yy]* )
            if [ -n "$TOKEN" ]; then
                curl -s -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github.v3+json" -L "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/zipball/$BRANCH" -o /tmp/network_dashboard.zip
            else
                curl -s -H "Accept: application/vnd.github.v3+json" -L "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/zipball/$BRANCH" -o /tmp/network_dashboard.zip
            fi
            mkdir -p /tmp/network_dashboard_extract
            unzip -q /tmp/network_dashboard.zip -d /tmp/network_dashboard_extract
            EXTRACTED_FOLDER=$(ls -d /tmp/network_dashboard_extract/*/)
            
            # Move code files over without overwriting database/logs/configs
            if command -v rsync >/dev/null 2>&1; then
                rsync -av --ignore-existing --exclude="webport" --exclude="standalone" --exclude="disablecleanup" "$EXTRACTED_FOLDER/" "$TARGET_DIR/" >/dev/null 2>&1
            else
                cp -rn "$EXTRACTED_FOLDER/"* "$TARGET_DIR/" >/dev/null 2>&1
            fi
            
            rm -rf /tmp/network_dashboard.zip /tmp/network_dashboard_extract
            echo "[✓] Code updated."
            ;;
    esac
fi

# --- 6. APP CONFIGURATION & DEDICATED DEVICE ---
echo ""
echo "--------------------------------------------------------"

# 6a. Web Port Prompt
CURRENT_PORT="81"
if [ -f "$TARGET_DIR/webport" ]; then
    CURRENT_PORT=$(cat "$TARGET_DIR/webport" 2>/dev/null)
fi

printf "[?] Enter the port for the Web Dashboard [Default: %s]: " "$CURRENT_PORT"
read user_port < /dev/tty
user_port=${user_port:-$CURRENT_PORT}

# Validate that the user entered numbers only
if ! echo "$user_port" | grep -Eq '^[0-9]+$'; then
    echo "    [!] Invalid port format. Reverting to $CURRENT_PORT."
    user_port=$CURRENT_PORT
fi

mkdir -p "$TARGET_DIR"
echo "$user_port" > "$TARGET_DIR/webport"
echo "    [✓] Web port configured to $user_port."
echo ""

# 6b. Dedicated Device Prompt
printf "[?] Are you using this device as a dedicated test device? (y/N): "
read is_dedicated < /dev/tty
HOTSPOT_ACTIVE=false

case "$is_dedicated" in
    [Yy]* )
        echo "    [*] Configuring for dedicated test device mode..."

        if [ ! -f "$TARGET_DIR/standalone" ]; then
            touch "$TARGET_DIR/standalone"
            echo "        [+] Created 'standalone' file."
        fi

        if [ ! -f "$TARGET_DIR/disablecleanup" ]; then
            touch "$TARGET_DIR/disablecleanup"
            echo "        [+] Created 'disablecleanup' file."
        fi

        # --- OPTIONAL WI-FI HOTSPOT SETUP ---
        echo ""
        echo "    [?] Wi-Fi Hotspot Configuration:"
        
        WIFI_IFACE=""
        if command -v iw >/dev/null 2>&1; then
            WIFI_IFACE=$(iw dev | awk '$1=="Interface"{print $2}' | head -n 1)
        elif command -v ip >/dev/null 2>&1; then
            WIFI_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep '^wl' | head -n 1)
        fi

        if [ -z "$WIFI_IFACE" ]; then
            WIFI_IFACE="wlan0"
        fi

        # --- FIX: Ensure Wi-Fi adapter is unblocked and powered on ---
        echo "        [*] Waking up Wi-Fi adapter ($WIFI_IFACE)..."
        sudo rfkill unblock all >/dev/null 2>&1
        sudo ip link set "$WIFI_IFACE" up >/dev/null 2>&1
        sudo nmcli radio wifi on >/dev/null 2>&1
        sleep 3 # Give NetworkManager a moment to register the state change
        # -------------------------------------------------------------

        DO_HOTSPOT_SETUP=false

        if nmcli connection show "Hotspot" >/dev/null 2>&1; then
            printf "    [?] A Wi-Fi Hotspot profile exists. (D)isable/remove, (R)econfigure, or (K)eep? [D/R/K]: "
            read toggle_hotspot < /dev/tty
            case "$toggle_hotspot" in
                [Dd]* )
                    sudo nmcli connection delete Hotspot >/dev/null 2>&1
                    echo "        [✓] Hotspot successfully disabled and removed."
                    ;;
                [Rr]* )
                    sudo nmcli connection delete Hotspot >/dev/null 2>&1
                    DO_HOTSPOT_SETUP=true
                    ;;
                [Kk]* | * )
                    echo "        [*] Keeping existing Hotspot configuration."
                    # Explicitly bring the connection up just in case it was off
                    sudo nmcli connection up Hotspot >/dev/null 2>&1
                    sleep 3
                    if nmcli connection show --active | grep -q "Hotspot"; then
                        echo "        [✓] Hotspot is active and broadcasting."
                        HOTSPOT_ACTIVE=true 
                    else
                        echo "        [X] Failed to bring up the existing Hotspot."
                    fi
                    ;;
            esac
        else
            printf "    [?] Do you want to ENABLE a Wi-Fi Hotspot to access the dashboard? (y/N): "
            read toggle_hotspot < /dev/tty
            case "$toggle_hotspot" in
                [Yy]* )
                    DO_HOTSPOT_SETUP=true
                    ;;
            esac
        fi

        if [ "$DO_HOTSPOT_SETUP" = true ]; then
            MAC_ADDR=$(cat /sys/class/net/$WIFI_IFACE/address 2>/dev/null | tr -d ':')
            if [ -n "$MAC_ADDR" ]; then
                MAC_SUFFIX=$(echo "$MAC_ADDR" | awk '{print substr($0,length($0)-5,6)}' | tr 'a-z' 'A-Z')
            else
                MAC_SUFFIX=$RANDOM
            fi
            DEFAULT_SSID="Network-Dashboard-$MAC_SUFFIX"

            printf "        Enter Hotspot SSID [Default: %s]: " "$DEFAULT_SSID"
            read HOTSPOT_SSID < /dev/tty
            HOTSPOT_SSID=${HOTSPOT_SSID:-$DEFAULT_SSID}
            
            while true; do
                printf "        Enter Hotspot Password (min 8 chars) [Default: dashboard123]: "
                read HOTSPOT_PASS < /dev/tty
                HOTSPOT_PASS=${HOTSPOT_PASS:-dashboard123}
                
                if [ ${#HOTSPOT_PASS} -ge 8 ]; then
                    break
                else
                    echo "        [!] Invalid password. WPA2 requires a minimum of 8 characters."
                fi
            done
            
            echo "        [*] Configuring Wi-Fi Hotspot on $WIFI_IFACE..."
            sudo nmcli connection add type wifi ifname "$WIFI_IFACE" con-name Hotspot autoconnect yes ssid "$HOTSPOT_SSID" >/dev/null 2>&1
            sudo nmcli connection modify Hotspot 802-11-wireless.mode ap 802-11-wireless.band bg ipv4.method shared
            sudo nmcli connection modify Hotspot wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$HOTSPOT_PASS"
            
            # Bring up the hotspot and explicitly check after a brief network stabilization delay
            sudo nmcli connection up Hotspot >/dev/null 2>&1
            sleep 8 # Increased to allow the Pi extra time to initialize the interface
            
            if nmcli connection show --active | grep -q "Hotspot"; then
                echo "        [✓] Hotspot successfully activated!"
                HOTSPOT_ACTIVE=true
            else
                echo "        [X] Failed to bring up Hotspot. Check your Wi-Fi adapter capabilities."
            fi
        fi
        ;;
    * ) echo "    [*] Skipping dedicated test device configurations and hotspot setup." ;;
esac
echo "--------------------------------------------------------"

sudo chown -R "$USER:$USER" "$TARGET_DIR"
sudo chmod -R 777 "$TARGET_DIR"

# --- 7. AUTOSTART CONFIGURATION (DESKTOP OR HEADLESS) ---
echo ""
echo "--------------------------------------------------------"
SERVICE_ACTIVE=false

# Check if ANY autostart method is currently enabled
if [ -f "$AUTOSTART_FILE" ] || systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo "[?] Autostart (Desktop or Background Service) is currently ENABLED."
    printf "[?] Do you want to DISABLE/REMOVE the startup behavior? (y/N): "
    read toggle_service < /dev/tty
    case "$toggle_service" in
        [Yy]* )
            # Remove Desktop autostart
            rm -f "$AUTOSTART_FILE"
            # Remove Systemd service
            if [ -f "$SERVICE_FILE" ]; then
                sudo systemctl stop "$SERVICE_NAME" >/dev/null 2>&1
                sudo systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
                sudo rm -f "$SERVICE_FILE"
                sudo systemctl daemon-reload
            fi
            echo "    [✓] All startup configurations removed."
            ;;
    esac
else
    echo "[?] Autostart is currently DISABLED."
    printf "[?] Do you want to ENABLE automatic start on boot/login? (y/N): "
    read toggle_service < /dev/tty
    case "$toggle_service" in
        [Yy]* )
            echo "    How should the dashboard start?"
            echo "      1) Visible Terminal Window (Standard User - Prompts for sudo)"
            echo "      2) Invisible Background Service (Runs silently as ROOT - Best for headless)"
            printf "    Select option (1 or 2): "
            read start_mode < /dev/tty
            
            case "$start_mode" in
                1)
                    # Clean up systemd if present to prevent double-starts
                    if [ -f "$SERVICE_FILE" ]; then
                        sudo systemctl stop "$SERVICE_NAME" >/dev/null 2>&1
                        sudo systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
                        sudo rm -f "$SERVICE_FILE"
                        sudo systemctl daemon-reload
                    fi
                    
                    echo "    [*] Setting up user login autostart..."
                    mkdir -p "$AUTOSTART_DIR"
                    
                    ICON_PATH="$TARGET_DIR/static/favicon.ico"
                    if [ ! -f "$ICON_PATH" ]; then
                        ICON_PATH="$TARGET_DIR/static/Logo.png"
                    fi
                    
                    cat <<EOL > "$AUTOSTART_FILE"
[Desktop Entry]
Name=Network Diagnostics
Comment=Open Network Diagnostics Dashboard
Exec=python3 "$TARGET_DIR/setup_env.py"
Path=$TARGET_DIR
Icon=$ICON_PATH
Terminal=true
Type=Application
Categories=Network;System;
EOL
                    chmod +x "$AUTOSTART_FILE"
                    
                    # --- NEW: Ensure browser autostart is enabled for visible mode ---
                    echo "1" > "$TARGET_DIR/autostart"
                    
                    echo "    [✓] Startup on login enabled (visible terminal window)."
                    ;;
                2)
                    # Clean up Desktop autostart if present to prevent double-starts
                    rm -f "$AUTOSTART_FILE"
                    
                    echo "    [*] Setting up systemd background service..."
                    # NOTE: User=root allows network sniffer and raw sockets to run seamlessly
                    sudo bash -c "cat > $SERVICE_FILE" <<EOL
[Unit]
Description=Network Diagnostics Dashboard
After=network.target

[Service]
Type=simple
WorkingDirectory=$TARGET_DIR
ExecStart=/usr/bin/python3 $TARGET_DIR/setup_env.py
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOL
                    sudo systemctl daemon-reload
                    sudo systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
                    sudo systemctl start "$SERVICE_NAME" >/dev/null 2>&1
                    
                    # --- NEW: Disable browser autostart for headless mode ---
                    echo "0" > "$TARGET_DIR/autostart"
                    
                    echo "    [✓] Background boot service enabled and started as Root."
                    SERVICE_ACTIVE=true
                    ;;
                *)
                    echo "    [!] Invalid option. Skipping autostart configuration."
                    ;;
            esac
            ;;
    esac
fi
echo "--------------------------------------------------------"

# --- 8. DESKTOP SHORTCUT CREATION ---
echo ""
DESKTOP_DIR="$HOME/Desktop"
SHORTCUT_FILE="$DESKTOP_DIR/Network-Diagnostics.desktop"

if [ -d "$DESKTOP_DIR" ] && [ ! -f "$SHORTCUT_FILE" ]; then
    printf "[?] Do you want to create a Desktop shortcut to launch the app? (y/N): "
    read create_shortcut < /dev/tty
    case "$create_shortcut" in
        [Yy]* )
            ICON_PATH="$TARGET_DIR/static/favicon.ico"
            if [ ! -f "$ICON_PATH" ]; then
                ICON_PATH="$TARGET_DIR/static/Logo.png"
            fi
            if [ ! -f "$ICON_PATH" ]; then
                ICON_PATH="applications-internet"
            fi

            cat <<EOL > "$SHORTCUT_FILE"
[Desktop Entry]
Name=Network Diagnostics
Comment=Open Network Diagnostics Dashboard
Exec=python3 "$TARGET_DIR/setup_env.py"
Path=$TARGET_DIR
Icon=$ICON_PATH
Terminal=true
Type=Application
Categories=Network;System;
EOL
            chmod +x "$SHORTCUT_FILE"
            
            # --- NEW: Automatically trust the shortcut on Ubuntu/GNOME ---
            if command -v gio >/dev/null 2>&1; then
                gio set "$SHORTCUT_FILE" metadata::trusted yes >/dev/null 2>&1
            fi
            
            echo "[✓] Desktop shortcut created at $SHORTCUT_FILE."
            ;;
    esac
elif [ -f "$SHORTCUT_FILE" ]; then
    echo "[✓] Desktop shortcut already exists."
fi

# --- 9. START MENU SHORTCUT CREATION ---
echo ""
STARTMENU_DIR="$HOME/.local/share/applications"
STARTMENU_FILE="$STARTMENU_DIR/Network-Diagnostics.desktop"

if [ ! -f "$STARTMENU_FILE" ]; then
    printf "[?] Do you want to create a Start Menu shortcut? (y/N): "
    read create_start_shortcut < /dev/tty
    case "$create_start_shortcut" in
        [Yy]* )
            mkdir -p "$STARTMENU_DIR"
            
            ICON_PATH="$TARGET_DIR/static/favicon.ico"
            if [ ! -f "$ICON_PATH" ]; then
                ICON_PATH="$TARGET_DIR/static/Logo.png"
            fi
            if [ ! -f "$ICON_PATH" ]; then
                ICON_PATH="applications-internet"
            fi

            cat <<EOL > "$STARTMENU_FILE"
[Desktop Entry]
Name=Network Diagnostics
Comment=Open Network Diagnostics Dashboard
Exec=python3 "$TARGET_DIR/setup_env.py"
Path=$TARGET_DIR
Icon=$ICON_PATH
Terminal=true
Type=Application
Categories=Network;System;
EOL
            chmod +x "$STARTMENU_FILE"
            echo "[✓] Start Menu shortcut created at $STARTMENU_FILE."
            ;;
    esac
elif [ -f "$STARTMENU_FILE" ]; then
    echo "[✓] Start Menu shortcut already exists."
fi

# --- 10. FINAL SUMMARY & IP INFO ---
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -z "$LOCAL_IP" ]; then
    LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk 'NR==1 {print $7}')
fi
PORT=$(cat "$TARGET_DIR/webport" 2>/dev/null || echo "81")

echo ""
echo "========================================================"
echo "   SETUP COMPLETE!"
echo "========================================================"

if [ "$SERVICE_ACTIVE" = false ]; then
    echo "   Starting dashboard via setup script..."
    echo ""
fi

if [ "$HOTSPOT_ACTIVE" = true ]; then
    DISPLAY_SSID=$(sudo nmcli -g 802-11-wireless.ssid connection show Hotspot 2>/dev/null)
    DISPLAY_PASS=$(sudo nmcli -s -g wifi-sec.psk connection show Hotspot 2>/dev/null)
    
    echo "   📱 CONNECT VIA HOTSPOT:"
    echo "      1. Connect to Wi-Fi: $DISPLAY_SSID"
    echo "      2. Password:         $DISPLAY_PASS"
    echo "      3. Open browser to:  http://10.42.0.1:$PORT"
    echo ""
fi

if [ -n "$LOCAL_IP" ]; then
    echo "   💻 ACCESS THE DASHBOARD:"
    echo "      Open your browser to: http://$LOCAL_IP:$PORT"
    echo "      (Or locally at:       http://127.0.0.1:$PORT)"
    echo ""
fi
echo "========================================================"

# --- 11. HANDOFF TO SETUP PYTHON SCRIPT ---
if [ "$SERVICE_ACTIVE" = false ]; then
    echo "   [*] Checking for running instances..."
    # Check if setup_env.py is currently in the process list
    if pgrep -f "setup_env.py" > /dev/null; then
        echo "   [✓] Network Diagnostics is already running. Skipping launch."
    else
        echo "   [*] Launching Network Diagnostics Dashboard..."
        
        # Ensure we lock the working directory to the target path before launching
        cd "$TARGET_DIR" || exit
        python3 "$TARGET_DIR/setup_env.py"
    fi
fi