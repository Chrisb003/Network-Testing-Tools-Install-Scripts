#!/bin/bash

# ==========================================
# Pi WiFi Configurator Install Script
# Version: 1.0
# ==========================================
VERSION="1.0"

# Determine the current user and home directory
if [ "$EUID" -eq 0 ]; then
    if [ -n "$SUDO_USER" ]; then
        ACTUAL_USER="$SUDO_USER"
        USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        ACTUAL_USER="root"
        USER_HOME="/root"
    fi
else
    ACTUAL_USER="$USER"
    USER_HOME="$HOME"
fi

APP_DIR="$USER_HOME/pi-wifi-app"
SERVICE_FILE="/etc/systemd/system/pi-wifi-app.service"
PORT_FILE="$APP_DIR/webport"
DEFAULT_PORT="8080"

# ==========================================
# UNINSTALLATION LOGIC
# ==========================================
if [ -d "$APP_DIR" ] \vert{}\vert{} [ -f "$SERVICE_FILE" ]; then
    echo "The WiFi Configurator (v$VERSION) appears to be already installed in$APP_DIR."
    read -p "Do you want to uninstall it? (y/N): " uninstall_choice
    if [[ "$uninstall_choice" =~ ^[Yy]$ ]]; then
        echo "Escalating privileges to stop and remove services..."
        if [ -f "$SERVICE_FILE" ]; then
            sudo systemctl stop pi-wifi-app
            sudo systemctl disable pi-wifi-app
            sudo rm "$SERVICE_FILE"
            sudo systemctl daemon-reload
        fi
        
        echo "Removing application files..."
        rm -rf "$APP_DIR"
        
        echo "Uninstallation complete."
        exit 0
    else
        echo "Exiting without making changes."
        exit 0
    fi
fi

# ==========================================
# INSTALLATION LOGIC
# ==========================================
echo "Ready to install Pi WiFi Configurator v$VERSION in$APP_DIR."
read -p "Proceed with installation? (y/N): " install_choice
if [[ ! "$install_choice" =~ ^[Yy]$ ]]; then
    echo "Installation aborted."
    exit 0
fi

echo "Escalating privileges to install system dependencies..."
sudo apt-get update
sudo apt-get install -y python3-flask network-manager

echo "Creating application directories..."
mkdir -p "$APP_DIR/templates"

echo "Creating port configuration file ($PORT_FILE)..."
echo "$DEFAULT_PORT" > "$PORT_FILE"

# ==========================================
# AUTHENTICATION SETUP
# ==========================================
read -p "Do you want to enable web authentication? (y/N): " auth_choice
if [[ "$auth_choice" =~ ^[Yy]$ ]]; then
    read -p "Enter username: " WEB_USER
    read -s -p "Enter password: " WEB_PASS
    echo ""
    # Use python to safely generate a secure hash
    WEB_HASH=$(python3 -c "import sys; from werkzeug.security import generate_password_hash; print(generate_password_hash(sys.argv[1]))" "$WEB_PASS")
    echo "$WEB_USER:$WEB_HASH" > "$APP_DIR/user"
    echo "Authentication configured."
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
# Set session to last a full year so users don't get logged out on the same device
app.permanent_session_lifetime = timedelta(days=365)

script_dir = os.path.dirname(os.path.abspath(__file__))
user_file = os.path.join(script_dir, 'user')
reset_file = os.path.join(script_dir, 'reset')
port_file_path = os.path.join(script_dir, 'webport')

# ==========================================
# STARTUP LOGIC
# ==========================================
if os.path.exists(reset_file):
    try:
        if os.path.exists(user_file):
            os.remove(user_file)
        os.remove(reset_file)
        print("Startup: Reset file detected. Authentication has been removed.")
    except Exception as e:
        print(f"Startup: Error resetting user: {e}")

def get_credentials():
    if os.path.exists(user_file):
        with open(user_file, 'r') as f:
            content = f.read().strip()
            if ':' in content:
                return content.split(':', 1)
    return None, None

@app.before_request
def check_auth():
    if os.path.exists(user_file):
        if request.endpoint not in ['login', 'static'] and not session.get('logged_in'):
            return redirect(url_for('login'))

@app.route('/')
def index():
    auth_enabled = os.path.exists(user_file)
    return render_template('index.html', auth_enabled=auth_enabled)

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        user = request.form.get('username')
        pw = request.form.get('password')
        saved_user, saved_hash = get_credentials()
        
        if saved_user == user and saved_hash and check_password_hash(saved_hash, pw):
            session.permanent = True # Enables the 365-day persistency
            session['logged_in'] = True
            return redirect(url_for('index'))
        return render_template('login.html', error="Invalid credentials")
    return render_template('login.html')

@app.route('/logout')
def logout():
    session.pop('logged_in', None)
    return redirect(url_for('login'))

@app.route('/settings', methods=['GET', 'POST'])
def settings():
    if request.method == 'POST':
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
    return render_template('settings.html', current_user=saved_user)

@app.route('/scan', methods=['GET'])
def scan():
    try:
        result = subprocess.run(['nmcli', '-t', '-f', 'SSID,SIGNAL', 'dev', 'wifi'], capture_output=True, text=True)
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
    data = request.json
    ssid = data.get('ssid')
    password = data.get('password')

    if not ssid or not password:
        return jsonify({'status': 'error', 'message': 'SSID and password are required'})

    try:
        result = subprocess.run(
            ['nmcli', 'dev', 'wifi', 'connect', ssid, 'password', password], 
            capture_output=True, 
            text=True
        )
        if result.returncode == 0:
            return jsonify({'status': 'success', 'message': f'Successfully connected to {ssid}. Network saved!'})
        else:
            return jsonify({'status': 'error', 'message': result.stderr.strip()})
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)})

if __name__ == '__main__':
    port = 8080 # Fallback port
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
        select, input { width: 100%; padding: 12px; margin-bottom: 15px; border: 1px solid var(--input-border); background: var(--input-bg); color: var(--text-color); border-radius: 6px; box-sizing: border-box; font-size: 16px; }
        .hidden { display: none; }
        #message { padding: 12px; border-radius: 6px; text-align: center; font-size: 14px; }
        .success { background-color: #1e4620; color: #a5d6a7; border: 1px solid #2e7d32; }
        body.light-mode .success { background-color: #d4edda; color: #155724; border: 1px solid #c3e6cb; }
        .error { background-color: #4a141c; color: #ffb3b8; border: 1px solid #8e0015; }
        body.light-mode .error { background-color: #f8d7da; color: #721c24; border: 1px solid #f5c6cb; }
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
        <h2>WiFi Configurator</h2>
        <button id="scanBtn" class="primary-btn" onclick="scanNetworks()">Search for WiFi Networks</button>
        <div id="connectForm" class="hidden">
            <select id="ssidSelect">
                <option value="">Select a network...</option>
            </select>
            <input type="password" id="password" placeholder="WiFi Password">
            <button id="connectBtn" class="primary-btn" onclick="connectNetwork()">Connect & Save</button>
        </div>
        <div id="message" class="hidden"></div>
    </div>

    <script>
        function toggleTheme() {
            const isLight = document.body.classList.toggle('light-mode');
            localStorage.setItem('theme', isLight ? 'light' : 'dark');
            document.getElementById('themeToggle').innerText = isLight ? '🌙 Dark' : '☀️ Light';
        }
        document.getElementById('themeToggle').innerText = document.body.classList.contains('light-mode') ? '🌙 Dark' : '☀️ Light';

        async function scanNetworks() {
            const scanBtn = document.getElementById('scanBtn');
            const connectForm = document.getElementById('connectForm');
            const ssidSelect = document.getElementById('ssidSelect');
            scanBtn.innerText = "Searching... (This takes a few seconds)";
            scanBtn.disabled = true;
            showMessage('', '');
            try {
                const response = await fetch('/scan');
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
            if (!ssid) return showMessage('error', 'Please select a network.');
            if (!password) return showMessage('error', 'Please enter a password.');
            connectBtn.innerText = "Connecting...";
            connectBtn.disabled = true;
            showMessage('', '');
            try {
                const response = await fetch('/connect', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ ssid, password })
                });
                const data = await response.json();
                if (data.status === 'success') {
                    showMessage('success', data.message);
                    document.getElementById('password').value = ''; 
                } else {
                    showMessage('error', 'Failed: ' + data.message);
                }
            } catch (err) {
                showMessage('error', 'Network error occurred while connecting.');
            }
            connectBtn.innerText = "Connect & Save";
            connectBtn.disabled = false;
        }

        function showMessage(type, text) {
            const msgDiv = document.getElementById('message');
            if (!text) { msgDiv.className = 'hidden'; return; }
            msgDiv.innerText = text;
            msgDiv.className = type;
        }
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
        input { width: 100%; padding: 12px; margin-bottom: 15px; border: 1px solid var(--input-border); background: var(--input-bg); color: var(--text-color); border-radius: 6px; box-sizing: border-box; font-size: 16px; }
        button[type="submit"] { background: #e60042; color: white; border: none; padding: 12px; border-radius: 6px; cursor: pointer; width: 100%; font-size: 16px; font-weight: bold; transition: background 0.3s; margin-bottom: 15px;}
        button[type="submit"]:hover { background: #bf0037; }
        .back-link { display: block; text-align: center; text-decoration: none; color: var(--link-color); font-size: 14px;}
        .back-link:hover { color: var(--text-color); }
        .info { background: var(--info-bg); padding: 15px; border-radius: 6px; font-size: 13px; color: var(--info-text); margin-bottom: 15px;}
    </style>
</head>
<body>
    <script>
        if (localStorage.getItem('theme') === 'light') { document.body.classList.add('light-mode'); }
    </script>
    <div class="container">
        <button id="themeToggle" class="theme-toggle" onclick="toggleTheme()">☀️ Light</button>
        <h2 style="margin-top: 15px;">Web Settings</h2>
        <div class="info">
            Submitting this form will enforce a login requirement to access the WiFi page.
        </div>
        <form method="POST">
            <label style="font-size:14px; font-weight:bold;">Username</label>
            <input type="text" name="username" placeholder="New Username" value="{{ current_user or '' }}" required>
            
            <label style="font-size:14px; font-weight:bold;">Password</label>
            <input type="password" name="password" placeholder="New Password" required>
            
            <button type="submit">Update Credentials</button>
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
sudo systemctl start pi-wifi-app

echo "==================================================="
echo "Installation complete!"
echo "Port configuration is saved in: $PORT_FILE"
echo "To reset auth physically, run:"
echo "touch $APP_DIR/reset && sudo systemctl restart pi-wifi-app"
echo "==================================================="