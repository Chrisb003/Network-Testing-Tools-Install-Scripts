#!/bin/sh

# Ensure we run as a standard user for paths
if [ "$(id -u)" -eq 0 ]; then
    echo "[!] Please do NOT run this script with 'sudo'. Run it as your normal user."
    echo "    The script will prompt for sudo credentials only when necessary."
    exit 1
fi

# --- 0. OS COMPATIBILITY CHECK ---
OS_NAME=$(uname -s)
if [ "$OS_NAME" != "Darwin" ]; then
    echo "[!] ERROR: This script is designed specifically for macOS."
    echo "    Your operating system is identified as '$OS_NAME'."
    echo "    Please use the appropriate installer for your system (e.g., Linux-Installer.sh or Windows-Installer.ps1)."
    exit 1
fi

# --- 1. CONFIGURATION ---
cd "$(dirname "$0")" || exit

TARGET_DIR="$HOME/Network-Testing-Tools"
REPO_OWNER="Chrisb003"
REPO_NAME="Network-Testing-Tools"
BRANCH="main"
TOKEN=""
APP_DIR="/Applications"
APP_PATH="$APP_DIR/Network Diagnostics.app"
DAEMON_PLIST="/Library/LaunchDaemons/com.network.diagnostics.plist"
SCRIPT_VERSION="1.0.0"

# --- 2. EXISTING INSTALLATION CHECK & UNINSTALL OPTION ---
if [ -d "$TARGET_DIR" ]; then
    echo "========================================================"
    echo "   NETWORK DIAGNOSTICS - MACOS INSTALLER & MANAGER"
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
                
                # Cleanup background LaunchDaemon if it existed
                if [ -f "$DAEMON_PLIST" ]; then
                    echo "[*] Stopping system service..."
                    sudo launchctl unload "$DAEMON_PLIST" >/dev/null 2>&1
                    sudo rm -f "$DAEMON_PLIST"
                fi
                
                # Cleanup Login Item if it existed
                osascript -e 'tell application "System Events" to delete login item "Network Diagnostics"' >/dev/null 2>&1
                
                # Cleanup Sudoers Passwordless Rule if it existed
                if [ -f "/private/etc/sudoers.d/network-diagnostics" ]; then
                    sudo rm -f "/private/etc/sudoers.d/network-diagnostics"
                fi
                
                # --- BACKUP LOGIC (DATABASE ONLY) ---
                case "$keep_db" in
                    [Yy]* )
                        BACKUP_DIR="$HOME/Desktop/Network-Diagnostics-Backup"
                        echo "[*] Backing up database files to $BACKUP_DIR..."
                        mkdir -p "$BACKUP_DIR"
                        # Use sudo to copy in case the files are currently owned by root (LaunchDaemon)
                        sudo find "$TARGET_DIR" -type f \( -name "*.db" -o -name "*.sqlite" \) -exec cp {} "$BACKUP_DIR/" \;
                        # Ensure the user has full permissions to edit or delete the backed-up files
                        sudo chown -R "$USER" "$BACKUP_DIR"
                        sudo chmod -R 777 "$BACKUP_DIR"
                        echo "[+] Data backed up safely."
                        ;;
                esac
                
                echo "[*] Deleting application directory..."
                sudo rm -rf "$TARGET_DIR"
                
                echo "[*] Removing application bundle..."
                sudo rm -rf "$APP_PATH"
                rm -rf "$HOME/Applications/Network Diagnostics.app" >/dev/null 2>&1
                
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
echo "   NETWORK DIAGNOSTICS - MACOS INSTALLER & MANAGER"
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

# --- 4. MACOS PREREQUISITES (Python 3 Check) ---
if [ "$SKIP_PREREQS" = false ]; then
    echo ""
    echo "[*] Step 1: Checking macOS system prerequisites..."

    PYTHON_VALID=false
    
    if command -v python3 >/dev/null 2>&1; then
        PY_PATH=$(command -v python3)
        if [ "$PY_PATH" = "/usr/bin/python3" ] && ! xcode-select -p >/dev/null 2>&1; then
            echo "[*] Apple Python stub detected. Bypassing to avoid Xcode popup..."
        else
            if python3 --version >/dev/null 2>&1; then
                PYTHON_VALID=true
            fi
        fi
    fi

    if [ "$PYTHON_VALID" = false ]; then
        echo "[!] Valid Python 3 not found. Downloading official Python.org package..."
        PY_VERSION="3.14.7"
        PKG_NAME="python-${PY_VERSION}-macos11.pkg"
        PKG_URL="https://www.python.org/ftp/python/${PY_VERSION}/${PKG_NAME}"
        
        echo "[*] Downloading Python ${PY_VERSION}..."
        curl -O "$PKG_URL"
        
        echo "[*] Installing Python package (administrator password required)..."
        sudo installer -pkg "$PKG_NAME" -target /
        rm -f "$PKG_NAME"
        echo "[✓] Python installation completed."
    else
        echo "[✓] Python 3 is verified and working."
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
                curl -s -L "https://github.com/$REPO_OWNER/$REPO_NAME/archive/refs/heads/$BRANCH.zip" -o /tmp/network_dashboard.zip
            fi
            mkdir -p /tmp/network_dashboard_extract
            unzip -q /tmp/network_dashboard.zip -d /tmp/network_dashboard_extract
            EXTRACTED_FOLDER=$(ls -d /tmp/network_dashboard_extract/*/)
            
            if command -v rsync >/dev/null 2>&1; then
                rsync -a --exclude="network_data.db*" --exclude="logs" --exclude="backups" --exclude="venv" --exclude="webport" --exclude="standalone" --exclude="disablecleanup" "$EXTRACTED_FOLDER/" "$TARGET_DIR/" >/dev/null 2>&1
            else
                find "$EXTRACTED_FOLDER" -name "network_data.db*" -delete
                find "$EXTRACTED_FOLDER" -name "webport" -delete
                find "$EXTRACTED_FOLDER" -name "standalone" -delete
                find "$EXTRACTED_FOLDER" -name "disablecleanup" -delete
                cp -Rf "$EXTRACTED_FOLDER/"* "$TARGET_DIR/" >/dev/null 2>&1
            fi
            
            rm -rf /tmp/network_dashboard.zip /tmp/network_dashboard_extract
            echo "[✓] Code updated successfully."
            ;;
    esac
fi

# --- 6. APP CONFIGURATION & DEDICATED DEVICE ---
echo ""
echo "--------------------------------------------------------"

CURRENT_PORT="81"
if [ -f "$TARGET_DIR/webport" ]; then
    CURRENT_PORT=$(cat "$TARGET_DIR/webport" 2>/dev/null)
fi

printf "[?] Enter the port for the Web Dashboard [Default: %s]: " "$CURRENT_PORT"
read user_port < /dev/tty
user_port=${user_port:-$CURRENT_PORT}

if ! echo "$user_port" | grep -Eq '^[0-9]+$'; then
    echo "    [!] Invalid port format. Reverting to $CURRENT_PORT."
    user_port=$CURRENT_PORT
fi

mkdir -p "$TARGET_DIR"
echo "$user_port" > "$TARGET_DIR/webport"
echo "    [✓] Web port configured to $user_port."
echo ""

printf "[?] Are you using this device as a dedicated test device? (y/N): "
read is_dedicated < /dev/tty
case "$is_dedicated" in
    [Yy]* )
        echo "    [*] Configuring for dedicated test device mode..."
        if [ ! -f "$TARGET_DIR/standalone" ]; then
            touch "$TARGET_DIR/standalone"
        fi
        if [ ! -f "$TARGET_DIR/disablecleanup" ]; then
            touch "$TARGET_DIR/disablecleanup"
        fi
        ;;
esac
echo "--------------------------------------------------------"

chown -R "$USER" "$TARGET_DIR" >/dev/null 2>&1 || sudo chown -R "$USER" "$TARGET_DIR"
sudo chmod -R 777 "$TARGET_DIR"

FORCE_APP_CREATION=false
SERVICE_ACTIVE=false
WANTS_LOGIN_ITEM=false

# --- 7. MACOS AUTOSTART CONFIGURATION ---
echo ""
echo "--------------------------------------------------------"

LOGIN_ITEM_CHECK=$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null)

if echo "$LOGIN_ITEM_CHECK" | grep -q "Network Diagnostics" || [ -f "$DAEMON_PLIST" ]; then
    echo "[?] Autostart (Desktop or Background Service) is currently ENABLED."
    printf "[?] Do you want to DISABLE/REMOVE the startup behavior? (y/N): "
    read toggle_service < /dev/tty
    case "$toggle_service" in
        [Yy]* )
            osascript -e 'tell application "System Events" to delete login item "Network Diagnostics"' >/dev/null 2>&1
            if [ -f "$DAEMON_PLIST" ]; then
                sudo launchctl unload "$DAEMON_PLIST" >/dev/null 2>&1
                sudo rm -f "$DAEMON_PLIST"
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
            echo "      1) Native Desktop Application (Visible in Menu Bar)"
            echo "      2) Invisible Background Service (Runs silently as ROOT via LaunchDaemon)"
            printf "    Select option (1 or 2): "
            read start_mode < /dev/tty
            
            case "$start_mode" in
                1)
                    if [ -f "$DAEMON_PLIST" ]; then
                        sudo launchctl unload "$DAEMON_PLIST" >/dev/null 2>&1
                        sudo rm -f "$DAEMON_PLIST"
                    fi
                    echo "    [*] Flagging system for macOS Login Item setup..."
                    WANTS_LOGIN_ITEM=true
                    FORCE_APP_CREATION=true
                    ;;
                2)
                    osascript -e 'tell application "System Events" to delete login item "Network Diagnostics"' >/dev/null 2>&1
                    echo "    [*] Setting up LaunchDaemon background service (runs as root)..."
                    
                    sudo bash -c "cat > \"$DAEMON_PLIST\"" <<EOL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.network.diagnostics</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>$TARGET_DIR/setup_env.py</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$TARGET_DIR</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
</dict>
</plist>
EOL
                    sudo chown root:wheel "$DAEMON_PLIST"
                    sudo chmod 644 "$DAEMON_PLIST"
                    sudo launchctl load "$DAEMON_PLIST" >/dev/null 2>&1
                    
                    echo "0" > "$TARGET_DIR/autostart"
                    echo "    [✓] Background boot service enabled and started as Root."
                    SERVICE_ACTIVE=true
                    ;;
            esac
            ;;
    esac
fi
echo "--------------------------------------------------------"

# --- 8. APPLICATIONS FOLDER SHORTCUT (.APP BUNDLE) CREATION ---
echo ""

OLD_APP_PATH="$HOME/Applications/Network Diagnostics.app"
if [ -d "$OLD_APP_PATH" ]; then
    rm -rf "$OLD_APP_PATH"
fi

if [ -d "$APP_PATH" ]; then
    echo "[✓] Application shortcut already exists in your Applications folder ($APP_DIR)."
else
    if [ "$FORCE_APP_CREATION" = true ]; then
        create_app_shortcut="y"
    else
        printf "[?] Do you want to create an application shortcut in your Applications folder? (y/N): "
        read create_app_shortcut < /dev/tty
    fi

    case "$create_app_shortcut" in
        [Yy]* )
            echo "    [*] Building native macOS Application Bundle..."
            
            TEMP_APP="/tmp/Network Diagnostics.app"
            rm -rf "$TEMP_APP"
            mkdir -p "$TEMP_APP/Contents/MacOS"
            mkdir -p "$TEMP_APP/Contents/Resources"
            
            # Use standard bash execution (NOT exec) so macOS TCC attributes the process correctly
            cat << EOF > "$TEMP_APP/Contents/MacOS/launcher"
#!/bin/bash
cd "$TARGET_DIR" || exit 1

# 1. Trigger permissions as a standard user before sudo runs
/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -s >/dev/null 2>&1 &
"$TARGET_DIR/venv/bin/python" -c '
import CoreLocation, time
try:
    m = CoreLocation.CLLocationManager.alloc().init()
    m.requestAlwaysAuthorization()
    m.startUpdatingLocation()
except Exception as e:
    print(e)
' >/dev/null 2>&1 &

# 2. Hand off execution to setup_env.py
exec "$TARGET_DIR/venv/bin/python" "setup_env.py"
EOF
chmod +x "$TEMP_APP/Contents/MacOS/launcher"
            
            # --- BUGFIX: ADDED THE MISSING "ALWAYS" INFO.PLIST STRINGS! ---
            cat << 'EOF' > "$TEMP_APP/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>launcher</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.network.diagnostics</string>
    <key>CFBundleName</key>
    <string>Network Diagnostics</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>Location access is required by macOS to scan nearby Wi-Fi networks and SSIDs.</string>
    <key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
    <string>Location access is required by macOS to scan nearby Wi-Fi networks and SSIDs.</string>
    <key>NSLocationAlwaysUsageDescription</key>
    <string>Location access is required by macOS to scan nearby Wi-Fi networks and SSIDs.</string>
    <key>NSLocationUsageDescription</key>
    <string>Location access is required by macOS to scan nearby Wi-Fi networks and SSIDs.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Network access is required to scan and identify devices on your local subnet.</string>
</dict>
</plist>
EOF

            if [ -f "$TARGET_DIR/static/favicon.ico" ]; then
                sips -s format icns "$TARGET_DIR/static/favicon.ico" --out "$TEMP_APP/Contents/Resources/AppIcon.icns" >/dev/null 2>&1
            fi
            
            if [ ! -f "$TEMP_APP/Contents/Resources/AppIcon.icns" ] && [ -f "$TARGET_DIR/static/Logo.png" ]; then
                ICONSET_DIR="/tmp/icon.iconset"
                mkdir -p "$ICONSET_DIR"
                sips -z 16 16     "$TARGET_DIR/static/Logo.png" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null 2>&1
                sips -z 32 32     "$TARGET_DIR/static/Logo.png" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null 2>&1
                sips -z 32 32     "$TARGET_DIR/static/Logo.png" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null 2>&1
                sips -z 64 64     "$TARGET_DIR/static/Logo.png" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null 2>&1
                sips -z 128 128   "$TARGET_DIR/static/Logo.png" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null 2>&1
                sips -z 256 256   "$TARGET_DIR/static/Logo.png" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null 2>&1
                sips -z 256 256   "$TARGET_DIR/static/Logo.png" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null 2>&1
                sips -z 512 512   "$TARGET_DIR/static/Logo.png" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null 2>&1
                sips -z 512 512   "$TARGET_DIR/static/Logo.png" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null 2>&1
                sips -z 1024 1024 "$TARGET_DIR/static/Logo.png" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null 2>&1
                iconutil -c icns "$ICONSET_DIR" -o "$TEMP_APP/Contents/Resources/AppIcon.icns" >/dev/null 2>&1
                rm -rf "$ICONSET_DIR"
            fi
            
            echo "    [*] Moving shortcut to $APP_DIR (may require password)..."
            sudo rm -rf "$APP_PATH"
            sudo mv "$TEMP_APP" "$APP_PATH"
            sudo chown -R "$USER" "$APP_PATH"
            
            touch "$APP_PATH"
            xattr -cr "$APP_PATH" 2>/dev/null
            
            echo "[✓] Applications bundle created successfully at $APP_PATH."
            
            echo ""
            printf "    [?] Do you want this shortcut to launch without asking for your Mac password every time? (y/N): "
            read nopasswd_choice < /dev/tty
            case "$nopasswd_choice" in
                [Yy]* )
                    echo "        [*] Configuring passwordless execution (requires password one last time to set up)..."
                    SUDOERS_TMP="/tmp/netdiag_sudoers"
                    
                    REAL_DIR=$(python3 -c "import os; print(os.path.realpath(os.path.expanduser('$TARGET_DIR')))" 2>/dev/null)
                    if [ -z "$REAL_DIR" ]; then REAL_DIR="$TARGET_DIR"; fi
                    
                    echo "$USER ALL=(ALL) NOPASSWD: $TARGET_DIR/venv/bin/python $TARGET_DIR/app.py" > "$SUDOERS_TMP"
                    if [ "$REAL_DIR" != "$TARGET_DIR" ]; then
                        echo "$USER ALL=(ALL) NOPASSWD: $REAL_DIR/venv/bin/python $REAL_DIR/app.py" >> "$SUDOERS_TMP"
                    fi
                    
                    if sudo visudo -c -f "$SUDOERS_TMP" >/dev/null 2>&1; then
                        sudo cp "$SUDOERS_TMP" /private/etc/sudoers.d/network-diagnostics
                        sudo chown root:wheel /private/etc/sudoers.d/network-diagnostics
                        sudo chmod 440 /private/etc/sudoers.d/network-diagnostics
                        echo "        [✓] Passwordless startup enabled securely."
                    else
                        echo "        [X] Failed to configure passwordless startup."
                    fi
                    rm -f "$SUDOERS_TMP"
                    ;;
            esac
            ;;
    esac
fi

if [ "$WANTS_LOGIN_ITEM" = true ] && [ -d "$APP_PATH" ]; then
    osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$APP_PATH\", hidden:false}" >/dev/null 2>&1
    echo "    [✓] Startup on login securely assigned to Application Bundle."
fi

# --- 9. FINAL SUMMARY & IP INFO ---
LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
if [ -z "$LOCAL_IP" ]; then
    LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
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

if [ -n "$LOCAL_IP" ]; then
    echo "   💻 ACCESS THE DASHBOARD:"
    echo "      Open your browser to: http://$LOCAL_IP:$PORT"
    echo "      (Or locally at:       http://127.0.0.1:$PORT)"
    echo ""
fi
echo "========================================================"

if [ "$SERVICE_ACTIVE" = false ]; then
    echo "   [*] Checking for running instances..."
    if pgrep -f "setup_env.py" > /dev/null; then
        echo "   [✓] Network Diagnostics is already running. Skipping launch."
    else
        cd "$TARGET_DIR" || exit
        python3 setup_env.py
    fi
fi