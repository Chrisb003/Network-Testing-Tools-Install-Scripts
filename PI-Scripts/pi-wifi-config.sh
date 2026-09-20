#!/bin/sh

# ==========================================
# Pi WiFi Configurator Install Script
# Version: 1.0.0 (Multi-Interface & Hotspot Aware)
# ==========================================
VERSION="1.0.0"

# Determine the current user and home directory using standard POSIX commands
if [ "$(id -u)" -eq 0 ]; then
    if [ -n "$SUDO_USER" ]; then
        ACTUAL_USER="$SUDO_USER"
        USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        ACTUAL_USER="root"
        USER_HOME="/root"
    fi
else
    ACTUAL_USER=$(id -un)
    USER_HOME="$HOME"
fi

APP_DIR="$USER_HOME/pi-wifi-app"
SERVICE_FILE="/etc/systemd/system/pi-wifi-app.service"
PORT_FILE="$APP_DIR/webport"
DEFAULT_PORT="8080"
INSTALL_MODE="install"

# ==========================================
# UPDATE / UNINSTALLATION LOGIC
# ==========================================
ALREADY_INSTALLED="no"
if [ -d "$APP_DIR" ] || [ -f "$SERVICE_FILE" ]; then
    ALREADY_INSTALLED="yes"
fi

if [ "$ALREADY_INSTALLED" = "yes" ]; then
    echo "=================================================="
    echo " OLED, Fan & Captive Portal Manager (v$VERSION)"
    echo "=================================================="
    echo "Status: An existing installation was detected."
    echo "1) Update (keep existing environment, update scripts & configs)"
    echo "2) Full Reinstall (rebuild virtual environment and reinstall packages)"
    echo "3) Uninstall completely"
    echo "4) Exit"
    printf "Select an option [1-4]: "
    read menu_choice < /dev/tty
    
    case "$menu_choice" in
        1)
            INSTALL_MODE="update"
            echo "Proceeding with update. Your settings will be preserved..."
            ;;
        2)
            INSTALL_MODE="reinstall"
            echo "Proceeding with full reinstall..."
            sudo systemctl stop pi-wifi-app >/dev/null 2>&1
            sudo rm -rf "$APP_DIR"
            ;;
        3)
            echo "Escalating privileges to stop and remove services..."
            if [ -f "$SERVICE_FILE" ]; then
                sudo systemctl stop pi-wifi-app
                sudo systemctl disable pi-wifi-app
                sudo rm -f "$SERVICE_FILE"
                sudo systemctl daemon-reload
            fi
            
            echo "Removing application files..."
            sudo rm -rf "$APP_DIR"
            
            echo "Uninstallation complete."
            exit 0
            ;;
        4|* )
            echo "Exiting without making changes."
            exit 0
            ;;
    esac
else
    echo "Ready to install Pi WiFi Configurator v$VERSION in $APP_DIR."
    printf "Proceed with installation? (y/N): "
    read install_choice < /dev/tty

    case "$install_choice" in
        [Yy]* )
            # User agreed, continue
            ;;
        * )
            echo "Installation aborted."
            exit 0
            ;;
    esac
fi

# ==========================================
# INSTALLATION CORE
# ==========================================
echo "Escalating privileges to install system dependencies..."
sudo apt-get update
sudo apt-get install -y python3-flask network-manager

echo "Creating application directories..."
mkdir -p "$APP_DIR/templates"

# Only write the default port file if one doesn't already exist
if [ ! -f "$PORT_FILE" ]; then
    echo "Creating port configuration file ($PORT_FILE)..."
    echo "$DEFAULT_PORT" > "$PORT_FILE"
fi

# ==========================================
# AUTHENTICATION SETUP
# ==========================================
# If we are updating, skip the auth prompt entirely.
if [ "$INSTALL_MODE" != "update" ]; then
    if [ ! -f "$APP_DIR/user" ]; then
        printf "Do you want to enable web authentication? (y/N): "
        read auth_choice < /dev/tty

        case "$auth_choice" in
            [Yy]* )
                printf "Enter username: "
                read WEB_USER < /dev/tty
                
                printf "Enter password: "
                stty -echo < /dev/tty
                read WEB_PASS < /dev/tty
                stty echo < /dev/tty
                echo ""
                
                WEB_HASH=$(python3 -c "import sys; from werkzeug.security import generate_password_hash; print(generate_password_hash(sys.argv[1]))" "$WEB_PASS")
                echo "$WEB_USER:$WEB_HASH" > "$APP_DIR/user"
                echo "Authentication configured."
                ;;
        esac
    fi
else
    echo "Update mode: Existing authentication settings preserved."
fi

echo "Writing app.py..."
cat << 'EOF' > "$APP_DIR/app.py"
from flask import Flask, render_template, request, jsonify, session, redirect, url_for
import subprocess
import os
from datetime import timedelta
from werkzeug.security import generate_password_hash, check_password_hash

app = Flask(__name__)
app.secret_key = os.urandom(24)
app.permanent_session_lifetime = timedelta(days=365)

script_dir = os.path.dirname(os.path.abspath(__file__))
user_file = os.path.join(script_dir, 'user')
reset_file = os.path.join(script_dir, 'reset')
port_file_path = os.path.join(script_dir, 'webport')
hotspot_policy_file = os.path.join(script_dir, 'hotspot_policy')

if os.path.exists(reset_file):
    try:
        if os.path.exists(user_file):
            os.remove(user_file)
        os.remove(reset_file)
        print("Startup: Reset file detected. Authentication has been removed.")
    except Exception as e:
        print(f"Startup: Error resetting user: {e}")

def get_credentials():
    """
    Reads the 'user' file to retrieve the currently saved username and hashed password.
    Returns (username, hash) if found, otherwise (None, None).
    """
    if os.path.exists(user_file):
        with open(user_file, 'r') as f:
            content = f.read().strip()
            if ':' in content:
                return content.split(':', 1)
    return None, None

def get_interfaces_info():
    """
    Retrieves all available WiFi network interfaces (e.g., wlan0, wlan1).
    It checks active connections to determine if any interface is currently running
    an Access Point (Hotspot). It automatically recommends an interface that is 
    NOT currently being used as a hotspot.
    """
    try:
        res = subprocess.run(['nmcli', '-t', '-f', 'DEVICE,TYPE,STATE,CONNECTION', 'dev'], capture_output=True, text=True)
        interfaces = []
        default_iface = None
        
        for line in res.stdout.splitlines():
            if ':wifi:' in line:
                parts = line.split(':')
                dev = parts[0]
                state = parts[2]
                conn = parts[3] if len(parts) > 3 else ''
                
                is_hotspot = False
                # If connected, check if the connection mode is 'ap' (Access Point)
                if state == 'connected' and conn:
                    mode_res = subprocess.run(['nmcli', '-g', '802-11-wireless.mode', 'con', 'show', conn], capture_output=True, text=True)
                    if mode_res.stdout.strip() == 'ap':
                        is_hotspot = True
                
                interfaces.append({'name': dev, 'is_hotspot': is_hotspot})
        
        # Determine the best default interface (prefer one that isn't running a hotspot)
        for iface in interfaces:
            if not iface['is_hotspot']:
                default_iface = iface['name']
                break
        
        if not default_iface and interfaces:
            default_iface = interfaces[0]['name']
            
        return {'interfaces': interfaces, 'default': default_iface}
    except Exception as e:
        return {'interfaces': [], 'default': ''}

def get_hotspot_policy():
    """
    Checks if the user has opted to force Hotspots to start on boot.
    If the setting hasn't been saved yet, it intelligently defaults to True 
    if a hotspot is actively running right now.
    """
    if os.path.exists(hotspot_policy_file):
        with open(hotspot_policy_file, 'r') as f:
            return f.read().strip() == 'true'
    
    # Intelligent default: if a hotspot is currently running, assume they want it to persist
    info = get_interfaces_info()
    for iface in info['interfaces']:
        if iface['is_hotspot']:
            with open(hotspot_policy_file, 'w') as f:
                f.write('true')
            return True
    return False

def set_hotspot_priority(priority):
    """
    Finds all NetworkManager profiles configured as Access Points (Hotspots) 
    and applies a high boot priority so they launch automatically over standard WiFi.
    """
    res = subprocess.run(['nmcli', '-t', '-f', 'NAME,TYPE', 'con', 'show'], capture_output=True, text=True)
    for line in res.stdout.splitlines():
        if '802-11-wireless' in line:
            name = line.split(':')[0]
            mode_res = subprocess.run(['nmcli', '-g', '802-11-wireless.mode', 'con', 'show', name], capture_output=True, text=True)
            if mode_res.stdout.strip() == 'ap':
                subprocess.run(['nmcli', 'con', 'modify', name, 'connection.autoconnect', 'yes', 'connection.autoconnect-priority', str(priority)])

@app.before_request
def check_auth():
    """
    Middleware that runs before every request.
    If authentication is enabled, it ensures the user has an active session.
    If not, redirects them to the login page.
    """
    if os.path.exists(user_file):
        if request.endpoint not in ['login', 'static'] and not session.get('logged_in'):
            return redirect(url_for('login'))

@app.route('/')
def index():
    """
    Serves the main frontend UI. Determines if the logout button should be shown
    based on whether authentication is enabled.
    """
    auth_enabled = os.path.exists(user_file)
    return render_template('index.html', auth_enabled=auth_enabled)

@app.route('/login', methods=['GET', 'POST'])
def login():
    """
    Handles user login. Validates the submitted username and hashed password.
    Sets a permanent session upon success.
    """
    if request.method == 'POST':
        user = request.form.get('username')
        pw = request.form.get('password')
        saved_user, saved_hash = get_credentials()
        
        if saved_user == user and saved_hash and check_password_hash(saved_hash, pw):
            session.permanent = True
            session['logged_in'] = True
            return redirect(url_for('index'))
        return render_template('login.html', error="Invalid credentials")
    return render_template('login.html')

@app.route('/logout')
def logout():
    """
    Destroys the current user session and redirects to the login page.
    """
    session.pop('logged_in', None)
    return redirect(url_for('login'))

@app.route('/settings', methods=['GET', 'POST'])
def settings():
    """
    Manages the settings page. Allows updating credentials and configuring 
    the Hotspot Boot Priority settings.
    """
    if request.method == 'POST':
        # Save Hotspot Policy
        force_hs = request.form.get('force_hotspot') == 'on'
        with open(hotspot_policy_file, 'w') as f:
            f.write('true' if force_hs else 'false')
        
        # Apply the priority immediately
        set_hotspot_priority(100 if force_hs else 0)
        
        # Update credentials only if provided
        new_user = request.form.get('username')
        new_pw = request.form.get('password')
        if new_user and new_pw:
            hashed = generate_password_hash(new_pw)
            with open(user_file, 'w') as f:
                f.write(f"{new_user}:{hashed}")
            session.permanent = True
            session['logged_in'] = True
            
        return redirect(url_for('index'))
    
    saved_user, _ = get_credentials()
    hs_policy = get_hotspot_policy()
    return render_template('settings.html', current_user=saved_user, force_hotspot=hs_policy)

@app.route('/interfaces', methods=['GET'])
def interfaces():
    """
    API Route: Returns JSON metadata about available WiFi adapters and 
    which ones are currently broadcasting a hotspot.
    """
    return jsonify(get_interfaces_info())

@app.route('/scan', methods=['GET'])
def scan():
    """
    API Route: Executes an active WiFi scan via nmcli.
    Optionally restricts the scan to a specific WiFi adapter if 'device' is passed.
    """
    try:
        device = request.args.get('device')
        cmd = ['nmcli', '-t', '-f', 'SSID,SIGNAL', 'dev', 'wifi']
        if device:
            cmd.extend(['ifname', device])
            
        result = subprocess.run(cmd, capture_output=True, text=True)
        networks = []
        if result.returncode == 0:
            lines = result.stdout.strip().split('\n')
            seen = set()
            for line in lines:
                if ':' in line:
                    ssid, signal = line.split(':', 1)
                    if ssid and ssid not in seen:
                        seen.add(ssid)
                        networks.append({'ssid': ssid, 'signal': signal})
        return jsonify({'networks': networks, 'status': 'success'})
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)})

@app.route('/connect', methods=['POST'])
def connect():
    """
    API Route: Connects to a WiFi network.
    Accepts SSID, optional password, auto-connect toggle, and specific device selection.
    Automatically ensures Hotspot priority rules remain intact after connecting.
    """
    data = request.json
    ssid = data.get('ssid')
    password = data.get('password', '')
    autoconnect = data.get('autoconnect', True)
    device = data.get('device')

    if not ssid:
        return jsonify({'status': 'error', 'message': 'SSID is required'})

    try:
        cmd = ['nmcli', 'dev', 'wifi', 'connect', ssid]
        if password:
            cmd.extend(['password', password])
        if device:
            cmd.extend(['ifname', device])
            
        result = subprocess.run(cmd, capture_output=True, text=True)
        
        if result.returncode == 0:
            ac_val = 'yes' if autoconnect else 'no'
            subprocess.run(['nmcli', 'con', 'modify', ssid, 'connection.autoconnect', ac_val, 'connection.autoconnect-priority', '0'])
            
            # Re-apply hotspot priority rule in case NM altered behavior
            if get_hotspot_policy():
                set_hotspot_priority(100)
                
            return jsonify({'status': 'success', 'message': f'Successfully connected to {ssid}.'})
        else:
            return jsonify({'status': 'error', 'message': result.stderr.strip()})
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)})

@app.route('/disconnect', methods=['POST'])
def disconnect():
    """
    API Route: Forcefully drops the active WiFi connection on the target device.
    Falls back to wlan0 if the device cannot be explicitly determined.
    """
    try:
        device = request.json.get('device', 'wlan0')
        result = subprocess.run(['nmcli', 'dev', 'disconnect', device], capture_output=True, text=True)
        if result.returncode == 0:
            return jsonify({'status': 'success', 'message': f'Disconnected from {device}.'})
        else:
            return jsonify({'status': 'error', 'message': result.stderr.strip()})
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)})

if __name__ == '__main__':
    port = 8080
    try:
        if os.path.exists(port_file_path):
            with open(port_file_path, 'r') as f:
                port_content = f.read().strip()
                if port_content.isdigit():
                    port = int(port_content)
    except Exception as e:
        print(f"Could not read webport file, defaulting to {port}. Error: {e}")

    print(f"Starting web server on port {port}...")
    app.run(host='0.0.0.0', port=port)
EOF

echo "Writing templates/index.html..."
cat << 'EOF' > "$APP_DIR/templates/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Raspberry Pi WiFi Setup</title>
    <style>
        :root {
            --bg-color: #121212;
            --container-bg: #1e1e1e;
            --text-color: #ffffff;
            --input-bg: #2d2d2d;
            --input-border: #444;
            --link-color: #ff4d79;
        }
        body.light-mode {
            --bg-color: #f0f2f5;
            --container-bg: #ffffff;
            --text-color: #333333;
            --input-bg: #ffffff;
            --input-border: #ddd;
            --link-color: #e60042;
        }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background-color: var(--bg-color); color: var(--text-color); margin: 0; padding: 20px; display: flex; justify-content: center; transition: background-color 0.3s, color 0.3s; }
        .container { background: var(--container-bg); padding: 30px; border-radius: 10px; box-shadow: 0 4px 15px rgba(0,0,0,0.2); width: 100%; max-width: 400px; transition: background-color 0.3s; }
        h2 { text-align: center; margin-top: 0; }
        .top-bar { display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; font-size: 14px; }
        .top-bar a { color: var(--link-color); text-decoration: none; font-weight: bold; }
        .theme-toggle { background: transparent; color: var(--text-color); border: 1px solid var(--input-border); padding: 5px 10px; border-radius: 4px; cursor: pointer; font-size: 12px; transition: 0.3s; margin-right: 10px;}
        .theme-toggle:hover { background: var(--input-bg); }
        .primary-btn { background: #e60042; color: white; border: none; padding: 12px; border-radius: 6px; cursor: pointer; width: 100%; font-size: 16px; font-weight: bold; margin-bottom: 15px; transition: background 0.3s; }
        .primary-btn:hover { background: #bf0037; }
        .primary-btn:disabled { background: #555; color: #888; cursor: not-allowed; }
        .secondary-btn { background: #444; color: white; border: none; padding: 12px; border-radius: 6px; cursor: pointer; width: 100%; font-size: 16px; font-weight: bold; margin-bottom: 15px; transition: background 0.3s; }
        .secondary-btn:hover { background: #555; }
        .secondary-btn:disabled { background: #333; color: #666; cursor: not-allowed; }
        body.light-mode .secondary-btn { background: #6c757d; }
        body.light-mode .secondary-btn:hover { background: #5a6268; }
        select, input[type="password"], input[type="text"] { width: 100%; padding: 12px; margin-bottom: 15px; border: 1px solid var(--input-border); background: var(--input-bg); color: var(--text-color); border-radius: 6px; box-sizing: border-box; font-size: 16px; }
        .hidden { display: none; }
        #message { padding: 12px; border-radius: 6px; text-align: center; font-size: 14px; margin-bottom: 15px;}
        .success { background-color: #1e4620; color: #a5d6a7; border: 1px solid #2e7d32; }
        body.light-mode .success { background-color: #d4edda; color: #155724; border: 1px solid #c3e6cb; }
        .error { background-color: #4a141c; color: #ffb3b8; border: 1px solid #8e0015; }
        body.light-mode .error { background-color: #f8d7da; color: #721c24; border: 1px solid #f5c6cb; }
        .checkbox-label { display: flex; align-items: center; font-size: 14px; margin-bottom: 15px; cursor: pointer; }
        .checkbox-label input { width: auto; margin: 0 10px 0 0; cursor: pointer; }
        
        .warning-box { background-color: #3a2a00; color: #ffcc00; border: 1px solid #b38f00; padding: 10px; border-radius: 6px; font-size: 13px; margin-bottom: 15px; text-align: left; }
        body.light-mode .warning-box { background-color: #fff3cd; color: #856404; border-color: #ffeeba; }
    </style>
</head>
<body>
    <script>
        if (localStorage.getItem('theme') === 'light') { document.body.classList.add('light-mode'); }
    </script>
    <div class="container">
        <div class="top-bar">
            <div>Pi WiFi Manager</div>
            <div style="display:flex; align-items:center;">
                <button id="themeToggle" class="theme-toggle" onclick="toggleTheme()">☀️ Light</button>
                <a href="/settings">Settings</a>
                {% if auth_enabled %}
                &nbsp;|&nbsp; <a href="/logout">Logout</a>
                {% endif %}
            </div>
        </div>
        
        <select id="interfaceSelect" onchange="checkWarning()"></select>
        
        <div id="hotspotWarning" class="hidden warning-box">
            ⚠️ <b>Note:</b> Connecting to a WiFi network on this adapter will temporarily disable your active Hotspot.
        </div>

        <h2>WiFi Configurator</h2>
        <button id="scanBtn" class="primary-btn" onclick="scanNetworks()">Search for WiFi Networks</button>
        
        <div id="connectForm" class="hidden">
            <select id="ssidSelect">
                <option value="">Select a network...</option>
            </select>
            <input type="password" id="password" placeholder="Password (leave empty if known/open)">
            
            <label class="checkbox-label">
                <input type="checkbox" id="autoconnect" checked> Auto-connect in the future
            </label>
            
            <button id="connectBtn" class="primary-btn" onclick="connectNetwork()">Connect</button>
        </div>
        
        <button id="disconnectBtn" class="secondary-btn" onclick="disconnectNetwork()">Disconnect Current WiFi</button>
        
        <div id="message" class="hidden"></div>
    </div>

    <script>
        let interfacesData = [];

        function toggleTheme() {
            const isLight = document.body.classList.toggle('light-mode');
            localStorage.setItem('theme', isLight ? 'light' : 'dark');
            document.getElementById('themeToggle').innerText = isLight ? '🌙 Dark' : '☀️ Light';
        }
        document.getElementById('themeToggle').innerText = document.body.classList.contains('light-mode') ? '🌙 Dark' : '☀️ Light';

        async function loadInterfaces() {
            try {
                const res = await fetch('/interfaces');
                const data = await res.json();
                interfacesData = data.interfaces;
                
                const select = document.getElementById('interfaceSelect');
                select.innerHTML = '';
                
                if (data.interfaces.length === 0) {
                    select.style.display = 'none';
                    return;
                }
                
                data.interfaces.forEach(iface => {
                    const opt = document.createElement('option');
                    opt.value = iface.name;
                    opt.innerText = iface.name + (iface.is_hotspot ? ' (Running Hotspot)' : '');
                    select.appendChild(opt);
                });
                
                if (data.default) {
                    select.value = data.default;
                }
                checkWarning();
                
                // Hide select if only 1 interface exists
                if (data.interfaces.length <= 1) {
                    select.style.display = 'none';
                }
            } catch (err) {
                console.error("Failed to load interfaces");
            }
        }

        function checkWarning() {
            const selected = document.getElementById('interfaceSelect').value;
            const iface = interfacesData.find(i => i.name === selected);
            const warning = document.getElementById('hotspotWarning');
            if (iface && iface.is_hotspot) {
                warning.classList.remove('hidden');
            } else {
                warning.classList.add('hidden');
            }
        }

        async function scanNetworks() {
            const scanBtn = document.getElementById('scanBtn');
            const connectForm = document.getElementById('connectForm');
            const ssidSelect = document.getElementById('ssidSelect');
            const device = document.getElementById('interfaceSelect').value;
            
            scanBtn.innerText = "Searching... (This takes a few seconds)";
            scanBtn.disabled = true;
            showMessage('', '');
            try {
                const response = await fetch('/scan?device=' + encodeURIComponent(device));
                const data = await response.json();
                if (data.status === 'success') {
                    ssidSelect.innerHTML = '<option value="">Select a network...</option>';
                    data.networks.forEach(net => {
                        const option = document.createElement('option');
                        option.value = net.ssid;
                        option.innerText = `${net.ssid} (Signal: ${net.signal}%)`;
                        ssidSelect.appendChild(option);
                    });
                    connectForm.classList.remove('hidden');
                    scanBtn.innerText = "Refresh Networks";
                } else {
                    showMessage('error', 'Error scanning: ' + data.message);
                    scanBtn.innerText = "Search for WiFi Networks";
                }
            } catch (err) {
                showMessage('error', 'Network error occurred.');
                scanBtn.innerText = "Search for WiFi Networks";
            }
            scanBtn.disabled = false;
        }

        async function connectNetwork() {
            const connectBtn = document.getElementById('connectBtn');
            const ssid = document.getElementById('ssidSelect').value;
            const password = document.getElementById('password').value;
            const autoconnect = document.getElementById('autoconnect').checked;
            const device = document.getElementById('interfaceSelect').value;
            
            if (!ssid) return showMessage('error', 'Please select a network.');

            connectBtn.innerText = "Connecting...";
            connectBtn.disabled = true;
            showMessage('', '');
            try {
                const response = await fetch('/connect', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ ssid, password, autoconnect, device })
                });
                const data = await response.json();
                if (data.status === 'success') {
                    showMessage('success', data.message);
                    document.getElementById('password').value = '';
                    loadInterfaces(); // Refresh UI State 
                } else {
                    showMessage('error', 'Failed: ' + data.message);
                }
            } catch (err) {
                showMessage('error', 'Network error occurred while connecting.');
            }
            connectBtn.innerText = "Connect";
            connectBtn.disabled = false;
        }

        async function disconnectNetwork() {
            const btn = document.getElementById('disconnectBtn');
            const device = document.getElementById('interfaceSelect').value;
            
            btn.innerText = "Disconnecting...";
            btn.disabled = true;
            showMessage('', '');
            try {
                const response = await fetch('/disconnect', { 
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ device })
                });
                const data = await response.json();
                if (data.status === 'success') {
                    showMessage('success', data.message);
                    loadInterfaces(); // Refresh UI State
                } else {
                    showMessage('error', 'Failed: ' + data.message);
                }
            } catch (err) {
                showMessage('error', 'Network error occurred.');
            }
            btn.innerText = "Disconnect Current WiFi";
            btn.disabled = false;
        }

        function showMessage(type, text) {
            const msgDiv = document.getElementById('message');
            if (!text) { msgDiv.className = 'hidden'; return; }
            msgDiv.innerText = text;
            msgDiv.className = type;
        }

        // Initialize Interfaces on page load
        window.onload = loadInterfaces;
    </script>
</body>
</html>
EOF

echo "Writing templates/login.html..."
cat << 'EOF' > "$APP_DIR/templates/login.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Login - WiFi Configurator</title>
    <style>
        :root {
            --bg-color: #121212;
            --container-bg: #1e1e1e;
            --text-color: #ffffff;
            --input-bg: #2d2d2d;
            --input-border: #444;
        }
        body.light-mode {
            --bg-color: #f0f2f5;
            --container-bg: #ffffff;
            --text-color: #333333;
            --input-bg: #ffffff;
            --input-border: #ddd;
        }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background-color: var(--bg-color); color: var(--text-color); margin: 0; padding: 20px; display: flex; justify-content: center; align-items: center; height: 90vh; transition: background-color 0.3s, color 0.3s; }
        .container { background: var(--container-bg); padding: 30px; border-radius: 10px; box-shadow: 0 4px 15px rgba(0,0,0,0.2); width: 100%; max-width: 350px; position: relative; }
        h2 { text-align: center; margin-top: 0; }
        .theme-toggle { position: absolute; top: 15px; right: 15px; background: transparent; color: var(--text-color); border: 1px solid var(--input-border); padding: 4px 8px; border-radius: 4px; cursor: pointer; font-size: 12px; }
        .theme-toggle:hover { background: var(--input-bg); }
        input { width: 100%; padding: 12px; margin-bottom: 15px; border: 1px solid var(--input-border); background: var(--input-bg); color: var(--text-color); border-radius: 6px; box-sizing: border-box; font-size: 16px; }
        button[type="submit"] { background: #e60042; color: white; border: none; padding: 12px; border-radius: 6px; cursor: pointer; width: 100%; font-size: 16px; font-weight: bold; transition: background 0.3s; }
        button[type="submit"]:hover { background: #bf0037; }
        .error { background-color: #4a141c; color: #ffb3b8; border: 1px solid #8e0015; padding: 10px; border-radius: 5px; text-align: center; margin-bottom: 15px; font-size: 14px;}
        body.light-mode .error { background-color: #f8d7da; color: #721c24; border: 1px solid #f5c6cb; }
    </style>
</head>
<body>
    <script>
        if (localStorage.getItem('theme') === 'light') { document.body.classList.add('light-mode'); }
    </script>
    <div class="container">
        <button id="themeToggle" class="theme-toggle" onclick="toggleTheme()">☀️ Light</button>
        <h2 style="margin-top: 15px;">Login required</h2>
        {% if error %}
        <div class="error">{{ error }}</div>
        {% endif %}
        <form method="POST">
            <input type="text" name="username" placeholder="Username" required>
            <input type="password" name="password" placeholder="Password" required>
            <button type="submit">Login</button>
        </form>
    </div>
    <script>
        function toggleTheme() {
            const isLight = document.body.classList.toggle('light-mode');
            localStorage.setItem('theme', isLight ? 'light' : 'dark');
            document.getElementById('themeToggle').innerText = isLight ? '🌙 Dark' : '☀️ Light';
        }
        document.getElementById('themeToggle').innerText = document.body.classList.contains('light-mode') ? '🌙 Dark' : '☀️ Light';
    </script>
</body>
</html>
EOF

echo "Writing templates/settings.html..."
cat << 'EOF' > "$APP_DIR/templates/settings.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Settings - WiFi Configurator</title>
    <style>
        :root {
            --bg-color: #121212;
            --container-bg: #1e1e1e;
            --text-color: #ffffff;
            --input-bg: #2d2d2d;
            --input-border: #444;
            --info-bg: #2a2a2a;
            --info-text: #ccc;
            --link-color: #aaa;
        }
        body.light-mode {
            --bg-color: #f0f2f5;
            --container-bg: #ffffff;
            --text-color: #333333;
            --input-bg: #ffffff;
            --input-border: #ddd;
            --info-bg: #e9ecef;
            --info-text: #555;
            --link-color: #666;
        }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background-color: var(--bg-color); color: var(--text-color); margin: 0; padding: 20px; display: flex; justify-content: center; transition: background-color 0.3s, color 0.3s; }
        .container { background: var(--container-bg); padding: 30px; border-radius: 10px; box-shadow: 0 4px 15px rgba(0,0,0,0.2); width: 100%; max-width: 400px; margin-top: 20px; position: relative; }
        h2 { text-align: center; margin-top: 0; }
        .theme-toggle { position: absolute; top: 15px; right: 15px; background: transparent; color: var(--text-color); border: 1px solid var(--input-border); padding: 4px 8px; border-radius: 4px; cursor: pointer; font-size: 12px; }
        .theme-toggle:hover { background: var(--input-bg); }
        input[type="text"], input[type="password"] { width: 100%; padding: 12px; margin-bottom: 15px; border: 1px solid var(--input-border); background: var(--input-bg); color: var(--text-color); border-radius: 6px; box-sizing: border-box; font-size: 16px; }
        button[type="submit"] { background: #e60042; color: white; border: none; padding: 12px; border-radius: 6px; cursor: pointer; width: 100%; font-size: 16px; font-weight: bold; transition: background 0.3s; margin-bottom: 15px;}
        button[type="submit"]:hover { background: #bf0037; }
        .back-link { display: block; text-align: center; text-decoration: none; color: var(--link-color); font-size: 14px;}
        .back-link:hover { color: var(--text-color); }
        .checkbox-label { display: flex; align-items: center; font-size: 14px; margin-bottom: 15px; cursor: pointer; }
        .checkbox-label input { width: auto; margin: 0 10px 0 0; cursor: pointer; }
    </style>
</head>
<body>
    <script>
        if (localStorage.getItem('theme') === 'light') { document.body.classList.add('light-mode'); }
    </script>
    <div class="container">
        <button id="themeToggle" class="theme-toggle" onclick="toggleTheme()">☀️ Light</button>
        <h2 style="margin-top: 15px;">Web Settings</h2>
        
        <form method="POST">
            <label class="checkbox-label" style="font-weight: bold;">
                <input type="checkbox" name="force_hotspot" {% if force_hotspot %}checked{% endif %}>
                Force Hotspot to start on boot (High Priority)
            </label>
            
            <hr style="border: 0; border-top: 1px solid var(--input-border); margin: 20px 0;">
            <div style="font-size: 13px; color: var(--info-text); margin-bottom: 15px;">
                Leave fields below blank to keep existing web login credentials.
            </div>
            
            <label style="font-size:14px; font-weight:bold;">Username</label>
            <input type="text" name="username" placeholder="New Username" value="{{ current_user or '' }}">
            
            <label style="font-size:14px; font-weight:bold;">Password</label>
            <input type="password" name="password" placeholder="New Password">
            
            <button type="submit">Save Settings</button>
        </form>
        <a href="/" class="back-link">Cancel and return Home</a>
    </div>
    <script>
        function toggleTheme() {
            const isLight = document.body.classList.toggle('light-mode');
            localStorage.setItem('theme', isLight ? 'light' : 'dark');
            document.getElementById('themeToggle').innerText = isLight ? '🌙 Dark' : '☀️ Light';
        }
        document.getElementById('themeToggle').innerText = document.body.classList.contains('light-mode') ? '🌙 Dark' : '☀️ Light';
    </script>
</body>
</html>
EOF

echo "Setting file ownership for $ACTUAL_USER..."
sudo chown -R "$ACTUAL_USER:$ACTUAL_USER" "$APP_DIR"

echo "Creating systemd service..."
cat << EOF | sudo tee "$SERVICE_FILE" > /dev/null
[Unit]
Description=Pi WiFi Configurator Web App
After=network.target network-manager.service

[Service]
User=root
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/python3 $APP_DIR/app.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

echo "Enabling and starting the service..."
sudo systemctl daemon-reload
sudo systemctl enable pi-wifi-app
sudo systemctl restart pi-wifi-app

echo "==================================================="
echo "Installation complete!"
echo "Port configuration is saved in: $PORT_FILE"
echo "To reset auth physically, run:"
echo "touch $APP_DIR/reset && sudo systemctl restart pi-wifi-app"
echo "==================================================="