#!/bin/sh

# ==========================================
# Pi WiFi Configurator Install Script
# Version: 1.0.0 
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
import re
import json
import glob
import socket
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

def get_oled_dir():
    """Detects if the OLED Monitor script is installed by locating its directory."""
    for d in glob.glob('/home/*/oled_monitor'):
        if os.path.isdir(d): return d
    if os.path.isdir('/root/oled_monitor'): return '/root/oled_monitor'
    return None

# ==========================================
# STARTUP RESET LOGIC
# ==========================================
if os.path.exists(reset_file):
    try:
        if os.path.exists(user_file): os.remove(user_file)
        os.remove(reset_file)
        print("Startup: Reset file detected. Authentication has been removed.")
    except Exception as e:
        print(f"Startup: Error resetting user: {e}")

def get_credentials():
    """Retrieves the currently saved username and hashed password from the user file."""
    if os.path.exists(user_file):
        with open(user_file, 'r') as f:
            content = f.read().strip()
            if ':' in content: return content.split(':', 1)
    return None, None

def get_current_port():
    """Reads the active webport file to determine which port the app should bind to."""
    try:
        if os.path.exists(port_file_path):
            with open(port_file_path, 'r') as f:
                p = f.read().strip()
                if p.isdigit(): return int(p)
    except: pass
    return 8080

def get_interfaces_info():
    """
    Uses nmcli to detect all active network interfaces and identifies if any 
    of them are currently broadcasting a Hotspot (Access Point mode).
    Returns a list of interfaces and a safe default interface.
    """
    try:
        res = subprocess.run(['nmcli', '-t', '-f', 'DEVICE,TYPE,STATE,CONNECTION', 'dev'], capture_output=True, text=True)
        interfaces = []
        default_iface = None
        for line in res.stdout.splitlines():
            if ':wifi:' in line:
                parts = line.split(':')
                dev, state = parts[0], parts[2]
                conn = parts[3] if len(parts) > 3 else ''
                is_hotspot = False
                if state == 'connected' and conn:
                    mode_res = subprocess.run(['nmcli', '-g', '802-11-wireless.mode', 'con', 'show', conn], capture_output=True, text=True)
                    if mode_res.stdout.strip() == 'ap': is_hotspot = True
                interfaces.append({'name': dev, 'is_hotspot': is_hotspot})
        
        # Pick a default interface that is not a hotspot
        for iface in interfaces:
            if not iface['is_hotspot']:
                default_iface = iface['name']
                break
        
        if not default_iface and interfaces: default_iface = interfaces[0]['name']
        return {'interfaces': interfaces, 'default': default_iface}
    except Exception:
        return {'interfaces': [], 'default': ''}

def get_hotspot_policy():
    """Reads the user's saved policy on whether Hotspots should persist on boot with high priority."""
    if os.path.exists(hotspot_policy_file):
        with open(hotspot_policy_file, 'r') as f: return f.read().strip() == 'true'
    # Default to true if currently running
    info = get_interfaces_info()
    for iface in info['interfaces']:
        if iface['is_hotspot']:
            with open(hotspot_policy_file, 'w') as f: f.write('true')
            return True
    return False

def set_hotspot_priority(priority):
    """Modifies NetworkManager profiles to apply the chosen hotspot autoconnect priority."""
    res = subprocess.run(['nmcli', '-t', '-f', 'NAME,TYPE', 'con', 'show'], capture_output=True, text=True)
    for line in res.stdout.splitlines():
        if '802-11-wireless' in line:
            name = line.split(':')[0]
            mode_res = subprocess.run(['nmcli', '-g', '802-11-wireless.mode', 'con', 'show', name], capture_output=True, text=True)
            if mode_res.stdout.strip() == 'ap':
                subprocess.run(['nmcli', 'con', 'modify', name, 'connection.autoconnect', 'yes', 'connection.autoconnect-priority', str(priority)])

@app.before_request
def check_auth():
    """Middleware: Validates login status before allowing access to private application routes."""
    if os.path.exists(user_file):
        if request.endpoint not in ['login', 'static'] and not session.get('logged_in'):
            return redirect(url_for('login'))

@app.context_processor
def inject_global_vars():
    """Injects globally accessible state variables into all Jinja2 templates."""
    return {
        'auth_enabled': os.path.exists(user_file),
        'oled_installed': get_oled_dir() is not None,
        'current_port': get_current_port()
    }

@app.route('/')
def index():
    """Renders the main WiFi Configuration dashboard."""
    return render_template('index.html')

@app.route('/login', methods=['GET', 'POST'])
def login():
    """Handles user authentication. Validates credentials and sets the permanent secure session cookie."""
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
    """Destroys the current user session and redirects to the login screen."""
    session.pop('logged_in', None)
    return redirect(url_for('login'))

@app.route('/settings', methods=['GET', 'POST'])
def settings():
    """Handles the Web Application Settings: updates Hotspot policies, Auth credentials, and Port bindings."""
    if request.method == 'POST':
        # Save Hotspot Policy
        force_hs = request.form.get('force_hotspot') == 'on'
        with open(hotspot_policy_file, 'w') as f:
            f.write('true' if force_hs else 'false')
        set_hotspot_priority(100 if force_hs else 0)
        
        # Process User Credentials
        new_user = request.form.get('username')
        new_pw = request.form.get('password')
        if new_user and new_pw:
            hashed = generate_password_hash(new_pw)
            with open(user_file, 'w') as f: f.write(f"{new_user}:{hashed}")
            session.permanent = True
            session['logged_in'] = True
            
        # Process Port Change
        new_port_str = request.form.get('port')
        port_changed_to = None
        if new_port_str and new_port_str.isdigit():
            new_port = int(new_port_str)
            current_port = get_current_port()
            if new_port != current_port:
                with open(port_file_path + '.bak', 'w') as f: f.write(str(current_port))
                with open(port_file_path, 'w') as f: f.write(str(new_port))
                subprocess.Popen(['/bin/sh', '-c', 'sleep 1.5 && systemctl restart pi-wifi-app.service'])
                port_changed_to = new_port
                
        # Handle Redirection if port was changed
        if port_changed_to:
            return f"""
            <html>
            <body style='font-family:sans-serif; text-align:center; margin-top:50px; background:#121212; color:white;'>
                <h2>Changing Port to {port_changed_to}...</h2>
                <p>Please wait while the service restarts. You will be redirected automatically.</p>
                <script>
                    setTimeout(() => {{
                        window.location.href = window.location.protocol + '//' + window.location.hostname + ':{port_changed_to}/';
                    }}, 3500);
                </script>
            </body>
            </html>
            """
            
        return redirect(url_for('index'))
    return render_template('settings.html', current_user=get_credentials()[0], force_hotspot=get_hotspot_policy())

# ==========================================
# SYSTEM API & OLED ROUTES
# ==========================================
@app.route('/api/system/temp', methods=['GET'])
def system_temp():
    """Returns the current internal hardware CPU temperature of the Raspberry Pi."""
    try:
        out = subprocess.check_output(['vcgencmd', 'measure_temp'], stderr=subprocess.DEVNULL).decode('utf-8')
        temp = float(out.replace('temp=', '').replace('\'C\n', ''))
        return jsonify({'temp': temp})
    except Exception:
        return jsonify({'temp': 0.0})

@app.route('/oled')
def oled_page():
    """Renders the OLED Configuration UI, dynamically loading settings.json from the oled_monitor directory."""
    oled_dir = get_oled_dir()
    if not oled_dir: return "OLED Monitor is not installed on this system.", 404
    
    settings_file = os.path.join(oled_dir, 'settings.json')
    current_data = "{}"
    if os.path.exists(settings_file):
        try:
            with open(settings_file, 'r') as f:
                content = f.read()
                content = re.sub(r'^\s*//.*$', '', content, flags=re.MULTILINE)
                loaded = json.loads(content)
                current_data = json.dumps(loaded)
        except Exception:
            current_data = "{}"
            
    return render_template('oled.html', current_settings=current_data)

@app.route('/api/oled/save', methods=['POST'])
def oled_save():
    """API Endpoint: Receives JSON data from the UI, validates it, overwrites settings.json, and restarts the OLED service."""
    oled_dir = get_oled_dir()
    if not oled_dir: return jsonify({"status":"error", "message":"OLED not installed"})
    
    data = request.json
    if not isinstance(data, dict) or 'pages' not in data:
        return jsonify({"status":"error", "message":"Invalid format"})
        
    settings_file = os.path.join(oled_dir, 'settings.json')
    try:
        with open(settings_file, 'w') as f:
            json.dump(data, f, indent=4)
        subprocess.run(['systemctl', 'restart', 'oled_monitor.service'])
        return jsonify({"status":"success", "message":"Settings Saved & Service Restarted"})
    except Exception as e:
        return jsonify({"status":"error", "message":str(e)})

@app.route('/api/oled/reset', methods=['POST'])
def oled_reset():
    """API Endpoint: Triggers a factory reset of the OLED settings by creating a physical 'reset' file."""
    oled_dir = get_oled_dir()
    if not oled_dir: return jsonify({"status":"error", "message":"OLED not installed"})
    try:
        open(os.path.join(oled_dir, 'reset'), 'w').close()
        subprocess.run(['systemctl', 'restart', 'oled_monitor.service'])
        return jsonify({"status":"success", "message":"Settings Reset to Defaults"})
    except Exception as e:
        return jsonify({"status":"error", "message":str(e)})

# ==========================================
# WIFI API ROUTES
# ==========================================
@app.route('/interfaces', methods=['GET'])
def interfaces():
    """API Endpoint: Returns JSON metadata about available network interfaces."""
    return jsonify(get_interfaces_info())

@app.route('/scan', methods=['GET'])
def scan():
    """API Endpoint: Executes an nmcli WiFi scan on the requested network adapter and returns a list of SSIDs."""
    try:
        device = request.args.get('device')
        cmd = ['nmcli', '-t', '-f', 'SSID,SIGNAL', 'dev', 'wifi']
        if device: cmd.extend(['ifname', device])
            
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
    """API Endpoint: Executes nmcli to connect to a specific SSID. Applies autoconnect policies after success."""
    data = request.json
    ssid = data.get('ssid')
    password = data.get('password', '')
    autoconnect = data.get('autoconnect', True)
    device = data.get('device')

    if not ssid: return jsonify({'status': 'error', 'message': 'SSID is required'})
    try:
        cmd = ['nmcli', 'dev', 'wifi', 'connect', ssid]
        if password: cmd.extend(['password', password])
        if device: cmd.extend(['ifname', device])
            
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode == 0:
            ac_val = 'yes' if autoconnect else 'no'
            subprocess.run(['nmcli', 'con', 'modify', ssid, 'connection.autoconnect', ac_val, 'connection.autoconnect-priority', '0'])
            if get_hotspot_policy(): set_hotspot_priority(100)
            return jsonify({'status': 'success', 'message': f'Successfully connected to {ssid}.'})
        else:
            return jsonify({'status': 'error', 'message': result.stderr.strip()})
    except Exception as e: return jsonify({'status': 'error', 'message': str(e)})

@app.route('/disconnect', methods=['POST'])
def disconnect():
    """API Endpoint: Gracefully disconnects the specified network adapter from its current connection."""
    try:
        device = request.json.get('device', 'wlan0')
        result = subprocess.run(['nmcli', 'dev', 'disconnect', device], capture_output=True, text=True)
        if result.returncode == 0: return jsonify({'status': 'success', 'message': f'Disconnected from {device}.'})
        else: return jsonify({'status': 'error', 'message': result.stderr.strip()})
    except Exception as e: return jsonify({'status': 'error', 'message': str(e)})

def can_bind_port(check_port):
    """Safely checks if a requested port is available for binding by the Flask application."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(('0.0.0.0', check_port))
        s.close()
        return True
    except:
        return False

if __name__ == '__main__':
    port = get_current_port()
    bak_port = 8080
    
    try:
        if os.path.exists(port_file_path + '.bak'):
            with open(port_file_path + '.bak', 'r') as f:
                p = f.read().strip()
                if p.isdigit(): bak_port = int(p)
    except: pass

    if not can_bind_port(port):
        print(f"Port {port} is in use or unavailable. Falling back to {bak_port}...")
        port = bak_port
        if not can_bind_port(port):
            print(f"Fallback port {port} is ALSO unavailable. Falling back to 8080...")
            port = 8080
            
        try:
            with open(port_file_path, 'w') as f:
                f.write(str(port))
        except: pass

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
        :root { --bg-color: #121212; --container-bg: #1e1e1e; --text-color: #ffffff; --input-bg: #2d2d2d; --input-border: #444; --link-color: #ff4d79; }
        body.light-mode { --bg-color: #f0f2f5; --container-bg: #ffffff; --text-color: #333333; --input-bg: #ffffff; --input-border: #ddd; --link-color: #e60042; }
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
    <script>if (localStorage.getItem('theme') === 'light') document.body.classList.add('light-mode');</script>
    <div class="container">
        <div class="top-bar">
            <div>Pi WiFi Manager</div>
            <div style="display:flex; align-items:center;">
                <button id="themeToggle" class="theme-toggle" onclick="toggleTheme()">☀️ Light</button>
                {% if oled_installed %}<a href="/oled" style="margin-right:10px;">OLED Config</a>{% endif %}
                <a href="/settings">Settings</a>
                {% if auth_enabled %}&nbsp;|&nbsp; <a href="/logout">Logout</a>{% endif %}
            </div>
        </div>
        
        <select id="interfaceSelect" onchange="checkWarning()"></select>
        <div id="hotspotWarning" class="hidden warning-box">
            ⚠️ <b>Note:</b> Connecting to a WiFi network on this adapter will temporarily disable your active Hotspot.
        </div>

        <h2>WiFi Configurator</h2>
        <button id="scanBtn" class="primary-btn" onclick="scanNetworks()">Search for WiFi Networks</button>
        
        <div id="connectForm" class="hidden">
            <select id="ssidSelect"><option value="">Select a network...</option></select>
            <input type="password" id="password" placeholder="Password (leave empty if known/open)">
            <label class="checkbox-label"><input type="checkbox" id="autoconnect" checked> Auto-connect in the future</label>
            <button id="connectBtn" class="primary-btn" onclick="connectNetwork()">Connect</button>
        </div>
        
        <button id="disconnectBtn" class="secondary-btn" onclick="disconnectNetwork()">Disconnect Current WiFi</button>
        <div id="message" class="hidden"></div>
    </div>

    <script>
        let interfacesData = [];
        
        // Toggles the interface between dark and light themes, saving preference in localStorage
        function toggleTheme() {
            const isLight = document.body.classList.toggle('light-mode');
            localStorage.setItem('theme', isLight ? 'light' : 'dark');
            document.getElementById('themeToggle').innerText = isLight ? '🌙 Dark' : '☀️ Light';
        }
        document.getElementById('themeToggle').innerText = document.body.classList.contains('light-mode') ? '🌙 Dark' : '☀️ Light';

        // Fetches available network interfaces from the backend to populate the interface selector
        async function loadInterfaces() {
            try {
                const res = await fetch('/interfaces');
                const data = await res.json();
                interfacesData = data.interfaces;
                const select = document.getElementById('interfaceSelect');
                select.innerHTML = '';
                if (data.interfaces.length === 0) { select.style.display = 'none'; return; }
                data.interfaces.forEach(iface => {
                    const opt = document.createElement('option');
                    opt.value = iface.name;
                    opt.innerText = iface.name + (iface.is_hotspot ? ' (Running Hotspot)' : '');
                    select.appendChild(opt);
                });
                if (data.default) select.value = data.default;
                checkWarning();
                if (data.interfaces.length <= 1) select.style.display = 'none';
            } catch (err) {}
        }

        // Checks if the selected interface is running a hotspot and displays a warning to the user
        function checkWarning() {
            const selected = document.getElementById('interfaceSelect').value;
            const iface = interfacesData.find(i => i.name === selected);
            const warning = document.getElementById('hotspotWarning');
            if (iface && iface.is_hotspot) warning.classList.remove('hidden');
            else warning.classList.add('hidden');
        }

        // Triggers a network scan via the backend and updates the SSID dropdown list
        async function scanNetworks() {
            const scanBtn = document.getElementById('scanBtn');
            const connectForm = document.getElementById('connectForm');
            const ssidSelect = document.getElementById('ssidSelect');
            const device = document.getElementById('interfaceSelect').value;
            scanBtn.innerText = "Searching..."; scanBtn.disabled = true; showMessage('', '');
            try {
                const response = await fetch('/scan?device=' + encodeURIComponent(device));
                const data = await response.json();
                if (data.status === 'success') {
                    ssidSelect.innerHTML = '<option value="">Select a network...</option>';
                    data.networks.forEach(net => {
                        const option = document.createElement('option');
                        option.value = net.ssid; option.innerText = `${net.ssid} (Signal: ${net.signal}%)`;
                        ssidSelect.appendChild(option);
                    });
                    connectForm.classList.remove('hidden');
                    scanBtn.innerText = "Refresh Networks";
                } else {
                    showMessage('error', 'Error: ' + data.message); scanBtn.innerText = "Search";
                }
            } catch (err) { showMessage('error', 'Network error.'); scanBtn.innerText = "Search"; }
            scanBtn.disabled = false;
        }

        // Packages user input and posts connection request to the backend API
        async function connectNetwork() {
            const connectBtn = document.getElementById('connectBtn');
            const ssid = document.getElementById('ssidSelect').value;
            const password = document.getElementById('password').value;
            const autoconnect = document.getElementById('autoconnect').checked;
            const device = document.getElementById('interfaceSelect').value;
            if (!ssid) return showMessage('error', 'Select a network.');
            connectBtn.innerText = "Connecting..."; connectBtn.disabled = true; showMessage('', '');
            try {
                const response = await fetch('/connect', {
                    method: 'POST', headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ ssid, password, autoconnect, device })
                });
                const data = await response.json();
                if (data.status === 'success') { showMessage('success', data.message); document.getElementById('password').value = ''; loadInterfaces(); }
                else { showMessage('error', 'Failed: ' + data.message); }
            } catch (err) { showMessage('error', 'Network error.'); }
            connectBtn.innerText = "Connect"; connectBtn.disabled = false;
        }

        // Sends a disconnect request for the selected interface to the backend API
        async function disconnectNetwork() {
            const btn = document.getElementById('disconnectBtn');
            const device = document.getElementById('interfaceSelect').value;
            btn.innerText = "Disconnecting..."; btn.disabled = true; showMessage('', '');
            try {
                const response = await fetch('/disconnect', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ device }) });
                const data = await response.json();
                if (data.status === 'success') { showMessage('success', data.message); loadInterfaces(); }
                else { showMessage('error', 'Failed: ' + data.message); }
            } catch (err) { showMessage('error', 'Network error.'); }
            btn.innerText = "Disconnect Current WiFi"; btn.disabled = false;
        }

        // Utility function to inject status messages (success/error) into the DOM briefly
        function showMessage(type, text) {
            const msgDiv = document.getElementById('message');
            if (!text) { msgDiv.className = 'hidden'; return; }
            msgDiv.innerText = text; msgDiv.className = type;
        }
        
        // Execute UI initialization on load
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
        :root { --bg-color: #121212; --container-bg: #1e1e1e; --text-color: #ffffff; --input-bg: #2d2d2d; --input-border: #444; }
        body.light-mode { --bg-color: #f0f2f5; --container-bg: #ffffff; --text-color: #333333; --input-bg: #ffffff; --input-border: #ddd; }
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
    <script>if (localStorage.getItem('theme') === 'light') document.body.classList.add('light-mode');</script>
    <div class="container">
        <button id="themeToggle" class="theme-toggle" onclick="toggleTheme()">☀️ Light</button>
        <h2 style="margin-top: 15px;">Login required</h2>
        {% if error %}<div class="error">{{ error }}</div>{% endif %}
        <form method="POST">
            <input type="text" name="username" placeholder="Username" required>
            <input type="password" name="password" placeholder="Password" required>
            <button type="submit">Login</button>
        </form>
    </div>
    <script>
        // Toggles the interface between dark and light themes, saving preference in localStorage
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
        :root { --bg-color: #121212; --container-bg: #1e1e1e; --text-color: #ffffff; --input-bg: #2d2d2d; --input-border: #444; --info-bg: #2a2a2a; --info-text: #ccc; --link-color: #aaa; }
        body.light-mode { --bg-color: #f0f2f5; --container-bg: #ffffff; --text-color: #333333; --input-bg: #ffffff; --input-border: #ddd; --info-bg: #e9ecef; --info-text: #555; --link-color: #666; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background-color: var(--bg-color); color: var(--text-color); margin: 0; padding: 20px; display: flex; justify-content: center; transition: background-color 0.3s, color 0.3s; }
        .container { background: var(--container-bg); padding: 30px; border-radius: 10px; box-shadow: 0 4px 15px rgba(0,0,0,0.2); width: 100%; max-width: 400px; margin-top: 20px; position: relative; }
        h2 { text-align: center; margin-top: 0; }
        .theme-toggle { position: absolute; top: 15px; right: 15px; background: transparent; color: var(--text-color); border: 1px solid var(--input-border); padding: 4px 8px; border-radius: 4px; cursor: pointer; font-size: 12px; }
        .theme-toggle:hover { background: var(--input-bg); }
        input[type="text"], input[type="password"], input[type="number"] { width: 100%; padding: 12px; margin-bottom: 15px; border: 1px solid var(--input-border); background: var(--input-bg); color: var(--text-color); border-radius: 6px; box-sizing: border-box; font-size: 16px; }
        button[type="submit"] { background: #e60042; color: white; border: none; padding: 12px; border-radius: 6px; cursor: pointer; width: 100%; font-size: 16px; font-weight: bold; transition: background 0.3s; margin-bottom: 15px;}
        button[type="submit"]:hover { background: #bf0037; }
        .back-link { display: block; text-align: center; text-decoration: none; color: var(--link-color); font-size: 14px;}
        .back-link:hover { color: var(--text-color); }
        .checkbox-label { display: flex; align-items: center; font-size: 14px; margin-bottom: 15px; cursor: pointer; }
        .checkbox-label input { width: auto; margin: 0 10px 0 0; cursor: pointer; }
    </style>
</head>
<body>
    <script>if (localStorage.getItem('theme') === 'light') document.body.classList.add('light-mode');</script>
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

            <hr style="border: 0; border-top: 1px solid var(--input-border); margin: 20px 0;">

            <label style="font-size:14px; font-weight:bold;">Web Port</label>
            <input type="number" name="port" value="{{ current_port }}" required>
            
            <button type="submit">Save Settings</button>
        </form>
        <a href="/" class="back-link">Cancel and return Home</a>
    </div>
    <script>
        // Toggles the interface between dark and light themes, saving preference in localStorage
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

echo "Writing templates/oled.html..."
cat << 'EOF' > "$APP_DIR/templates/oled.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>OLED Display Configurator</title>
    <style>
        :root { --bg-color: #121212; --container-bg: #1e1e1e; --text-color: #ffffff; --input-bg: #2d2d2d; --input-border: #444; --link-color: #ff4d79; --card-bg: #2a2a2a; }
        body.light-mode { --bg-color: #f0f2f5; --container-bg: #ffffff; --text-color: #333333; --input-bg: #ffffff; --input-border: #ddd; --link-color: #e60042; --card-bg: #f8f9fa; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background-color: var(--bg-color); color: var(--text-color); margin: 0; padding: 20px; transition: 0.3s; }
        .top-bar { display: flex; justify-content: space-between; align-items: center; max-width: 900px; margin: 0 auto 20px; font-size: 14px; }
        .top-bar a { color: var(--link-color); text-decoration: none; font-weight: bold; }
        .theme-toggle { background: transparent; color: var(--text-color); border: 1px solid var(--input-border); padding: 5px 10px; border-radius: 4px; cursor: pointer; font-size: 12px; }
        .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; max-width: 900px; margin: 0 auto; align-items: start;}
        @media(max-width: 768px){ .grid { grid-template-columns: 1fr; } }
        .panel { background: var(--container-bg); padding: 25px; border-radius: 10px; box-shadow: 0 4px 15px rgba(0,0,0,0.2); }
        h2, h3 { margin-top: 0; }
        label { display: block; font-size: 13px; font-weight: bold; margin-bottom: 5px; color: var(--link-color);}
        input[type="number"], input[type="time"], select, textarea { width: 100%; padding: 10px; margin-bottom: 15px; border: 1px solid var(--input-border); background: var(--input-bg); color: var(--text-color); border-radius: 6px; box-sizing: border-box; font-size: 14px; font-family: inherit;}
        input[type="range"] { width: 100%; margin-bottom: 15px; }
        textarea { resize: vertical; min-height: 80px; }
        .checkbox-label { display: flex; align-items: center; font-size: 14px; margin-bottom: 15px; cursor: pointer; font-weight: normal; color: var(--text-color);}
        .checkbox-label input { width: auto; margin: 0 10px 0 0; }
        
        .preview-container { text-align: center; margin-bottom: 25px; padding-bottom: 20px; border-bottom: 1px solid var(--input-border); }
        .oled-box { width: 256px; height: 64px; background: #000; margin: 0 auto; border: 4px solid #333; border-radius: 4px; padding: 4px; box-sizing: border-box; position: relative; overflow: hidden; box-shadow: 0 4px 10px rgba(0,0,0,0.5); transition: background 0.3s, transform 0.3s;}
        .oled-text { color: #fff; font-family: 'Courier New', Courier, monospace; font-size: 14px; line-height: 14px; white-space: pre; position: absolute; top: 4px; left: 4px; transition: color 0.3s, opacity 0.3s;}
        
        .page-card { background: var(--card-bg); border: 1px solid var(--input-border); padding: 15px; border-radius: 6px; margin-bottom: 15px; position: relative; }
        .page-card-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px; }
        .page-card-header strong { font-size: 14px; }
        .btn { background: #444; color: white; border: none; padding: 8px 12px; border-radius: 4px; cursor: pointer; font-size: 14px; font-weight: bold; transition: 0.3s; }
        .btn:hover { background: #555; }
        .btn-primary { background: #e60042; }
        .btn-primary:hover { background: #bf0037; }
        .btn-danger { background: transparent; color: #ff4d4d; border: 1px solid #ff4d4d; padding: 4px 8px; font-size: 12px;}
        .btn-danger:hover { background: #ff4d4d; color: white; }
        .flex-row { display: flex; gap: 10px; }
        .flex-row > div { flex: 1; }
        
        #message { text-align: center; padding: 10px; border-radius: 6px; font-weight: bold; display: none; margin-bottom: 20px;}
        .success { background-color: #1e4620; color: #a5d6a7; }
        body.light-mode .success { background-color: #d4edda; color: #155724; }
        .error { background-color: #4a141c; color: #ffb3b8; }
        body.light-mode .error { background-color: #f8d7da; color: #721c24; }

        .live-badge { font-size: 13px; font-weight: bold; padding: 4px 8px; background: #e60042; border-radius: 4px; color: white;}
    </style>
</head>
<body>
    <script>if (localStorage.getItem('theme') === 'light') document.body.classList.add('light-mode');</script>
    
    <div class="top-bar">
        <div>OLED Display Manager</div>
        <div>
            <button id="themeToggle" class="theme-toggle" onclick="toggleTheme()">☀️ Light</button>
            <a href="/">Back to WiFi Config</a>
        </div>
    </div>

    <div class="grid">
        <!-- Global Settings Panel -->
        <div class="panel">
            <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 15px;">
                <h2 style="margin: 0;">Global Settings</h2>
                <span id="liveTemp" class="live-badge">Pi: --.-°C</span>
            </div>
            
            <!-- FAN CONTROL -->
            <h3 style="margin-top: 15px; margin-bottom: 10px; font-size: 15px; color: var(--text-color);">Fan Control</h3>
            <label class="checkbox-label">
                <input type="checkbox" id="enable_fan"> Enable PoE Fan automatic control
            </label>
            <div class="flex-row">
                <div>
                    <label>Turn ON Temp (°C)</label>
                    <input type="number" id="fan_on" step="0.5">
                </div>
                <div>
                    <label>Turn OFF Temp (°C)</label>
                    <input type="number" id="fan_off" step="0.5">
                </div>
            </div>
            <label>Minimum Fan Run Time (sec, anti-flutter)</label>
            <input type="number" id="fan_min_run" step="1">

            <!-- DISPLAY SETTINGS -->
            <h3 style="margin-top: 15px; margin-bottom: 10px; font-size: 15px; color: var(--text-color);">OLED Display & Warnings</h3>
            <label class="checkbox-label">
                <input type="checkbox" id="enable_screen"> Enable OLED screen
            </label>
            
            <label>Brightness: <span id="brightness_val" style="color: var(--text-color); font-weight:normal;">255</span></label>
            <input type="range" id="brightness" min="0" max="255">

            <div class="flex-row">
                <div>
                    <label class="checkbox-label"><input type="checkbox" id="rotate_180"> Rotate 180°</label>
                </div>
                <div>
                    <label class="checkbox-label"><input type="checkbox" id="invert_colors"> Invert Colors</label>
                </div>
            </div>
            
            <label class="checkbox-label">
                <input type="checkbox" id="pixel_shift"> Enable Pixel Shift Screensaver (Anti-burn-in)
            </label>

            <label class="checkbox-label" style="margin-top: 10px;">
                <input type="checkbox" id="show_warnings"> Show flashing Temp/Voltage warnings
            </label>
            <label>Warning Trigger Temp (°C)</label>
            <input type="number" id="warn_temp" step="0.5">
            
            <!-- QUIET HOURS -->
            <h3 style="margin-top: 15px; margin-bottom: 10px; font-size: 15px; color: var(--text-color);">Quiet Hours (Night Mode)</h3>
            <label class="checkbox-label">
                <input type="checkbox" id="quiet_enabled"> Enable Quiet Hours (Disables Screen & Fan)
            </label>
            <div class="flex-row">
                <div>
                    <label>Start Time</label>
                    <input type="time" id="quiet_start">
                </div>
                <div>
                    <label>End Time</label>
                    <input type="time" id="quiet_end">
                </div>
            </div>

            <!-- TIMINGS -->
            <hr style="border: 0; border-top: 1px solid var(--input-border); margin: 20px 0;">
            <div class="flex-row">
                <div>
                    <label>Default Page Duration (sec)</label>
                    <input type="number" id="global_dur" step="1">
                </div>
                <div>
                    <label>Network Scan Interval (sec)</label>
                    <input type="number" id="net_interval" step="1">
                </div>
            </div>
            <div class="flex-row">
                <div>
                    <label>Hardware Scan Interval (sec)</label>
                    <input type="number" id="hw_interval" step="1">
                </div>
                <div></div>
            </div>
            
            <button class="btn btn-primary" style="width: 100%; margin-top: 10px;" onclick="saveConfig()">💾 Save & Apply to OLED</button>
            <button class="btn" style="width: 100%; margin-top: 10px; border: 1px solid #888;" onclick="resetConfig()">⚠️ Factory Reset Config</button>
            <div id="message" style="margin-top: 15px;"></div>
        </div>

        <!-- Pages Configuration Panel -->
        <div class="panel">
            <div class="preview-container">
                <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px;">
                    <h3 style="margin: 0;">OLED Live Preview</h3>
                    <select id="previewPageSelect" onchange="renderPreview()" style="width: auto; padding: 4px 8px; margin: 0; font-size: 13px;"></select>
                </div>
                <div class="oled-box" id="oledBoxElem">
                    <div id="oledPreviewText" class="oled-text"></div>
                </div>
                <div style="font-size: 12px; color: #888; margin-top: 5px;">(Simulated layout based on active settings)</div>
            </div>

            <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 15px;">
                <h3 style="margin: 0;">Screen Pages</h3>
                <button class="btn" onclick="addPage()">+ Add Page</button>
            </div>
            
            <div id="pagesContainer"></div>
            
            <!-- Documentation / Info Box -->
            <div style="margin-top: 25px; padding: 20px; background: var(--card-bg); border: 1px solid var(--input-border); border-radius: 8px;">
                <h3 style="margin-top: 0; margin-bottom: 15px; color: var(--text-color); border-bottom: 1px solid var(--input-border); padding-bottom: 10px;">Configuration Guide</h3>
                
                <strong style="color: var(--link-color); font-size: 14px;">Network IPs vs. Hotspot Details:</strong>
                <ul style="margin: 5px 0 15px 0; font-size: 13px; padding-left: 20px;">
                    <li><b>Network IPs:</b> Lists all active adapters (eth0, wlan0). Can append the Hotspot IP dynamically.</li>
                    <li><b>Hotspot Details:</b> Displays Hotspot SSID and Password. Option to auto-hide when a device connects.</li>
                </ul>

                <strong style="color: var(--link-color); font-size: 14px;">Custom Page Variables:</strong>
                <p style="margin: 5px 0 10px 0; font-size: 13px;">Type these exact markers in any custom text line to inject live data onto the screen:</p>
                <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px; font-family: 'Courier New', Courier, monospace; font-size: 12px; background: var(--input-bg); padding: 12px; border-radius: 6px; border: 1px solid var(--input-border); color: var(--text-color);">
                    <div>{time} &nbsp;&nbsp;→ 14:30:00</div>
                    <div>{date} &nbsp;&nbsp;→ 2026-09-20</div>
                    <div>{hour} / {minute} / {second}</div>
                    <div>{day} / {month} / {year}</div>
                    <div>{temp} &nbsp;&nbsp;→ 48.5</div>
                    <div>{web_port} → 8080</div>
                    <div>{wifi_ssid}→ Connected WiFi</div>
                    <div>{ap_ssid} &nbsp;→ Hotspot Name</div>
                    <div>{ap_pw} &nbsp;&nbsp;&nbsp;→ Hotspot PW</div>
                    <div>{ap_ip} &nbsp;&nbsp;&nbsp;→ Hotspot IP</div>
                </div>
            </div>
        </div>
    </div>

    <script>
        let settings = {};
        try {
            settings = JSON.parse('{{ current_settings|safe }}');
        } catch(e) {}
        
        // Ensures defaults are populated if the underlying JSON is missing fields
        const DEFAULTS = { 
            enable_screen: true, enable_fan: true, brightness: 255, 
            fan_on_temp: 55.0, fan_off_temp: 45.0, minimum_fan_run_time_seconds: 60,
            show_warnings: true, warning_temp: 75.0,
            rotate_180: false, invert_colors: false, pixel_shift_screensaver: true,
            quiet_hours_enabled: false, quiet_hours_start: "22:00", quiet_hours_end: "07:00",
            page_duration_seconds: 20, network_update_interval_seconds: 20, hardware_update_interval_seconds: 5, 
            pages: [] 
        };
        for(let k in DEFAULTS) { if(settings[k] === undefined) settings[k] = DEFAULTS[k]; }

        // Toggles the interface between dark and light themes, saving preference in localStorage
        function toggleTheme() {
            const isLight = document.body.classList.toggle('light-mode');
            localStorage.setItem('theme', isLight ? 'light' : 'dark');
            document.getElementById('themeToggle').innerText = isLight ? '🌙 Dark' : '☀️ Light';
        }
        document.getElementById('themeToggle').innerText = document.body.classList.contains('light-mode') ? '🌙 Dark' : '☀️ Light';

        // Repeatedly requests the system's live CPU temperature from the backend
        async function fetchLiveTemp() {
            try {
                const res = await fetch('/api/system/temp');
                const data = await res.json();
                if(data.temp !== undefined) {
                    document.getElementById('liveTemp').innerText = `Pi: ${data.temp.toFixed(1)}°C`;
                }
            } catch(e) {}
        }

        // Bootstraps the form values based on the loaded (or default) JSON configuration
        function initForm() {
            document.getElementById('enable_screen').checked = settings.enable_screen;
            document.getElementById('enable_fan').checked = settings.enable_fan;
            document.getElementById('fan_on').value = settings.fan_on_temp;
            document.getElementById('fan_off').value = settings.fan_off_temp;
            document.getElementById('fan_min_run').value = settings.minimum_fan_run_time_seconds;
            
            document.getElementById('brightness').value = settings.brightness;
            document.getElementById('brightness_val').innerText = settings.brightness;
            document.getElementById('rotate_180').checked = settings.rotate_180;
            document.getElementById('invert_colors').checked = settings.invert_colors;
            document.getElementById('pixel_shift').checked = settings.pixel_shift_screensaver;
            
            document.getElementById('show_warnings').checked = settings.show_warnings;
            document.getElementById('warn_temp').value = settings.warning_temp;
            
            document.getElementById('quiet_enabled').checked = settings.quiet_hours_enabled;
            document.getElementById('quiet_start').value = settings.quiet_hours_start;
            document.getElementById('quiet_end').value = settings.quiet_hours_end;
            
            document.getElementById('global_dur').value = settings.page_duration_seconds;
            document.getElementById('net_interval').value = settings.network_update_interval_seconds;
            document.getElementById('hw_interval').value = settings.hardware_update_interval_seconds;
            
            renderPages();
            
            // Add live re-rendering on all global settings inputs
            const inputs = document.querySelectorAll('.panel input');
            inputs.forEach(i => {
                i.addEventListener('input', () => {
                    if(i.id === 'brightness') document.getElementById('brightness_val').innerText = i.value;
                    renderPreview();
                });
            });
            document.getElementById('pagesContainer').addEventListener('input', renderPreview);
            
            // Start checking live temp loop
            fetchLiveTemp();
            setInterval(fetchLiveTemp, 5000);
        }

        // Dynamically renders the DOM elements for the list of OLED pages
        function renderPages() {
            const container = document.getElementById('pagesContainer');
            container.innerHTML = '';
            
            if(!settings.pages || settings.pages.length === 0) {
                container.innerHTML = '<div style="text-align:center; color:#888; font-size:14px; padding:20px;">No pages configured. Click Add Page.</div>';
            }

            // Sync the dropdown menu used for previews
            const previewSelect = document.getElementById('previewPageSelect');
            const currentPreview = previewSelect.value;
            previewSelect.innerHTML = '';
            (settings.pages || []).forEach((p, i) => {
                let opt = document.createElement('option');
                opt.value = i;
                let typeLabel = p.type === 'network_list' ? 'Network IPs' : (p.type === 'hotspot_details' ? 'Hotspot Details' : 'Custom Text');
                opt.innerText = `Preview Page ${i + 1} (${typeLabel})`;
                previewSelect.appendChild(opt);
            });
            if (currentPreview && currentPreview < (settings.pages || []).length) {
                previewSelect.value = currentPreview;
            } else if ((settings.pages || []).length > 0) {
                previewSelect.value = "0";
            }

            (settings.pages || []).forEach((page, index) => {
                const card = document.createElement('div');
                card.className = 'page-card';
                
                let specifics = '';
                if(page.type === 'custom') {
                    const linesText = (page.lines || []).join('\n');
                    specifics = `
                        <label>Custom Lines (variables: {time}, {temp}, {wifi_ssid}, {ap_ip})</label>
                        <textarea id="page_lines_${index}">${linesText}</textarea>
                    `;
                } else if(page.type === 'network_list') {
                    specifics = `
                        <label class="checkbox-label">
                            <input type="checkbox" id="page_apip_${index}" ${page.show_ap_ip_when_connected !== false ? 'checked' : ''}> Show Hotspot IP when clients connect
                        </label>
                    `;
                } else if(page.type === 'hotspot_details') {
                    specifics = `
                        <label class="checkbox-label">
                            <input type="checkbox" id="page_hide_${index}" ${page.hide_when_connected !== false ? 'checked' : ''}> Auto-hide this screen when a device connects
                        </label>
                    `;
                }

                card.innerHTML = `
                    <div class="page-card-header">
                        <strong>Page ${index + 1}</strong>
                        <button class="btn-danger" onclick="deletePage(${index})">Remove</button>
                    </div>
                    
                    <div class="flex-row">
                        <div>
                            <label>Page Type</label>
                            <select id="page_type_${index}" onchange="updatePageType(${index}, this.value)">
                                <option value="network_list" ${page.type === 'network_list' ? 'selected' : ''}>Network IPs</option>
                                <option value="hotspot_details" ${page.type === 'hotspot_details' ? 'selected' : ''}>Hotspot Details</option>
                                <option value="custom" ${page.type === 'custom' ? 'selected' : ''}>Custom Text</option>
                            </select>
                        </div>
                        <div>
                            <label>Duration (0 to disable)</label>
                            <input type="number" id="page_dur_${index}" value="${page.duration !== undefined ? page.duration : 20}">
                        </div>
                    </div>
                    
                    <div class="flex-row">
                        <div>
                            <label>Text Alignment</label>
                            <select id="page_align_${index}">
                                <option value="left" ${page.align === 'left' ? 'selected' : ''}>Left</option>
                                <option value="center" ${page.align === 'center' ? 'selected' : ''}>Center</option>
                                <option value="right" ${page.align === 'right' ? 'selected' : ''}>Right</option>
                            </select>
                        </div>
                    </div>
                    ${specifics}
                `;
                container.appendChild(card);
            });
            renderPreview();
        }

        // Swaps a page's layout type and re-renders the DOM elements
        function updatePageType(index, newType) {
            syncStateFromUI();
            settings.pages[index].type = newType;
            if(newType === 'custom' && !settings.pages[index].lines) settings.pages[index].lines = ['Time: {time}', 'Temp: {temp}C'];
            renderPages();
        }

        // Pushes a new default custom page to the end of the JSON object
        function addPage() {
            syncStateFromUI();
            if(!settings.pages) settings.pages = [];
            settings.pages.push({ type: 'custom', duration: 20, align: 'left', lines: ['New Custom Page'] });
            renderPages();
        }

        // Deletes a page from the JSON object
        function deletePage(index) {
            syncStateFromUI();
            settings.pages.splice(index, 1);
            renderPages();
        }

        // Scrapes every input field on the UI to keep the internal `settings` JS object identical to the screen state
        function syncStateFromUI() {
            settings.enable_screen = document.getElementById('enable_screen').checked;
            settings.enable_fan = document.getElementById('enable_fan').checked;
            settings.fan_on_temp = parseFloat(document.getElementById('fan_on').value);
            settings.fan_off_temp = parseFloat(document.getElementById('fan_off').value);
            settings.minimum_fan_run_time_seconds = parseInt(document.getElementById('fan_min_run').value);
            
            settings.brightness = parseInt(document.getElementById('brightness').value);
            settings.rotate_180 = document.getElementById('rotate_180').checked;
            settings.invert_colors = document.getElementById('invert_colors').checked;
            settings.pixel_shift_screensaver = document.getElementById('pixel_shift').checked;
            
            settings.show_warnings = document.getElementById('show_warnings').checked;
            settings.warning_temp = parseFloat(document.getElementById('warn_temp').value);
            
            settings.quiet_hours_enabled = document.getElementById('quiet_enabled').checked;
            settings.quiet_hours_start = document.getElementById('quiet_start').value;
            settings.quiet_hours_end = document.getElementById('quiet_end').value;
            
            settings.page_duration_seconds = parseInt(document.getElementById('global_dur').value);
            settings.network_update_interval_seconds = parseInt(document.getElementById('net_interval').value);
            settings.hardware_update_interval_seconds = parseInt(document.getElementById('hw_interval').value);
            
            (settings.pages || []).forEach((page, i) => {
                const typeSel = document.getElementById(`page_type_${i}`);
                if(!typeSel) return;
                page.type = typeSel.value;
                page.duration = parseInt(document.getElementById(`page_dur_${i}`).value);
                page.align = document.getElementById(`page_align_${i}`).value;
                
                if(page.type === 'custom') {
                    page.lines = document.getElementById(`page_lines_${i}`).value.split('\n');
                } else if(page.type === 'network_list') {
                    page.show_ap_ip_when_connected = document.getElementById(`page_apip_${i}`).checked;
                } else if(page.type === 'hotspot_details') {
                    page.hide_when_connected = document.getElementById(`page_hide_${i}`).checked;
                }
            });
        }

        // Paints the simulated 128x32 OLED display, applying color inversions, rotations, opacities, and variable injections
        function renderPreview() {
            syncStateFromUI();
            const box = document.getElementById('oledPreviewText');
            const oledBox = document.getElementById('oledBoxElem');
            
            // Apply visual modifiers
            if (settings.invert_colors) {
                oledBox.style.background = '#fff'; oledBox.style.color = '#000';
            } else {
                oledBox.style.background = '#000'; oledBox.style.color = '#fff';
            }
            oledBox.style.transform = settings.rotate_180 ? 'rotate(180deg)' : 'none';
            box.style.color = settings.invert_colors ? '#000' : '#fff';
            box.style.opacity = Math.max(0.1, settings.brightness / 255.0);

            if (!settings.pages || settings.pages.length === 0) {
                box.innerHTML = '<div style="text-align:center; padding-top:10px;">No Pages Configured</div>';
                return;
            }

            if (!settings.enable_screen) {
                box.innerHTML = '<div style="text-align:center; padding-top:10px; color:#ff4d4d;">[ OLED Screen is Disabled ]</div>';
                return;
            }

            let selectedIdx = parseInt(document.getElementById('previewPageSelect').value);
            if (isNaN(selectedIdx) || selectedIdx >= settings.pages.length) selectedIdx = 0;
            let p = settings.pages[selectedIdx];
            
            if(!p) { box.innerHTML = ''; return; }
            if(p.duration <= 0) {
                box.innerHTML = '<div style="text-align:center; padding-top:10px; color:#888;">[ Page Disabled (Duration 0) ]</div>';
                return;
            }

            let lines = [];
            if(p.type === 'network_list') {
                lines = ['wlan0: 192.168.1.10:80', 'eth0: 10.0.0.5:80'];
            } else if(p.type === 'hotspot_details') {
                lines = ['Pi: My_Hotspot', 'PW: Password123', 'IP: 10.42.0.1:80'];
            } else if(p.type === 'custom') {
                const curTempStr = document.getElementById('liveTemp').innerText.replace('Pi: ', '');
                lines = (p.lines || []).map(l => l
                    .replace('{time}', '14:30:00').replace('{temp}', curTempStr !== '--.-°C' ? curTempStr.replace('°C','') : '48.5')
                    .replace('{wifi_ssid}', 'HomeNetwork').replace('{ap_ip}', '10.42.0.1')
                    .replace('{ap_ssid}', 'Pi_Hotspot').replace('{date}', '2026-09-20')
                    .replace('{hour}', '14').replace('{minute}', '30').replace('{second}', '00')
                    .replace('{year}', '2026').replace('{month}', '09').replace('{day}', '20')
                    .replace('{web_port}', '8080')
                );
            }

            box.style.textAlign = p.align === 'center' ? 'center' : (p.align === 'right' ? 'right' : 'left');
            box.style.width = '100%';
            box.innerHTML = lines.map(l => `<div>${l}</div>`).join('');
        }

        // Utility to briefly display status notifications
        function showMessage(type, text) {
            const m = document.getElementById('message');
            m.className = type;
            m.innerText = text;
            m.style.display = 'block';
            setTimeout(() => m.style.display = 'none', 4000);
        }

        // Validates hardware constraints and posts the settings payload to the API
        async function saveConfig() {
            syncStateFromUI();
            
            let warnings = [];
            if (!settings.enable_screen) warnings.push("• The OLED screen display is disabled.");
            if (!settings.enable_fan) warnings.push("• The PoE Fan automatic control is disabled.");
            if (settings.quiet_hours_enabled) warnings.push(`• Quiet Hours are ON. Screen & Fan will be disabled between ${settings.quiet_hours_start} and ${settings.quiet_hours_end}.`);
            
            if (warnings.length > 0) {
                const msg = "WARNING / NOTICE:\n" + warnings.join("\n") + "\n\nAre you sure you want to save and apply these settings?";
                if (!confirm(msg)) return;
            }

            showMessage('success', 'Saving and restarting OLED...');
            try {
                const res = await fetch('/api/oled/save', {
                    method: 'POST',
                    headers:{'Content-Type':'application/json'},
                    body: JSON.stringify(settings)
                });
                const data = await res.json();
                showMessage(data.status, data.message);
            } catch(e) {
                showMessage('error', 'Network error.');
            }
        }

        // Submits an API request to force a factory reset of the OLED monitor settings file
        async function resetConfig() {
            if(!confirm("Are you sure you want to completely reset the OLED settings?")) return;
            showMessage('success', 'Sending reset command...');
            try {
                const res = await fetch('/api/oled/reset', { method: 'POST' });
                const data = await res.json();
                showMessage(data.status, data.message);
                if(data.status === 'success') setTimeout(() => window.location.reload(), 1500);
            } catch(e) {
                showMessage('error', 'Network error.');
            }
        }

        window.onload = initForm;
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