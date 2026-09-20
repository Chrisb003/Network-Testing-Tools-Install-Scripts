#!/bin/bash

# ==================================================
# OLED Monitor, PoE Fan & Captive Portal Manager
# ==================================================
SCRIPT_VERSION="1.0.0"

# Request sudo upfront and keep-alive
sudo -v || { echo "This script requires sudo privileges. Exiting."; exit 1; }

# Determine the actual invoking user and home directory
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    USER_NAME="$SUDO_USER"
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    USER_NAME=$(id -un)
    USER_HOME="$HOME"
fi

OLED_DIR="$USER_HOME/oled_monitor"

echo "=================================================="
echo " OLED, Fan & Captive Portal Manager (v$SCRIPT_VERSION)"
echo "=================================================="

# Check if already installed
INSTALLED=0
if [ -f /etc/systemd/system/oled_monitor.service ] || [ -d "$OLED_DIR" ]; then
    INSTALLED=1
fi

if [ $INSTALLED -eq 1 ]; then
    echo "Status: An existing installation was detected."
    echo "1) Update (keep existing environment, update scripts & configs)"
    echo "2) Full Reinstall (rebuild virtual environment and reinstall packages)"
    echo "3) Reset Settings to Default (restores settings.json instantly)"
    echo "4) Uninstall completely"
    echo "5) Exit"
    
    read -r -p "Select an option [1-5]: " choice < /dev/tty
    case "$choice" in
        1)
            ACTION="update"
            ;;
        2)
            ACTION="reinstall"
            ;;
        3)
            echo ">>> Resetting settings.json to default..."
            touch "$OLED_DIR/reset"
            sudo systemctl restart oled_monitor.service 2>/dev/null
            echo "=========================================="
            echo " Settings Reset Complete!"
            echo "=========================================="
            exit 0
            ;;
        4)
            echo ">>> Starting complete uninstallation..."
            sudo systemctl stop oled_monitor.service 2>/dev/null
            sudo systemctl disable oled_monitor.service 2>/dev/null
            sudo rm -f /etc/systemd/system/oled_monitor.service
            sudo systemctl daemon-reload
            
            sudo rm -f /etc/NetworkManager/dnsmasq-shared.d/captive.conf
            sudo rm -f /var/www/html/index.sh
            sudo systemctl restart NetworkManager 2>/dev/null
            sudo systemctl restart lighttpd 2>/dev/null
            
            rm -rf "$OLED_DIR"
            
            echo "=========================================="
            echo " Uninstallation Complete!"
            echo "=========================================="
            exit 0
            ;;
        5)
            echo "Exiting without making changes."
            exit 0
            ;;
        *)
            echo "Invalid selection. Exiting."
            exit 1
            ;;
    esac
else
    echo "Status: NOT currently installed"
    read -r -p "Do you want to proceed with the installation? (y/N): " confirm < /dev/tty
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Installation cancelled."
        exit 0
    fi
    ACTION="install"
fi

echo "=========================================="
echo " Running: $ACTION (v$SCRIPT_VERSION)"
echo "=========================================="

echo ">>> Safely Enabling I2C Interface..."
sudo raspi-config nonint do_i2c 0
sudo modprobe i2c-dev 2>/dev/null || true
sudo modprobe i2c-bcm2835 2>/dev/null || true

echo ">>> Checking and installing system packages..."
sudo apt update
sudo apt install -y swig liblgpio-dev python3-lgpio python3-rpi.gpio python3-venv python3-pip python3-pil i2c-tools lighttpd python3-smbus

if [ "$ACTION" = "reinstall" ] || [ ! -d "$OLED_DIR/env" ]; then
    echo ">>> Setting up Python Virtual Environment..."
    mkdir -p "$OLED_DIR"
    python3 -m venv --system-site-packages "$OLED_DIR/env"
    echo ">>> Installing Adafruit Libraries in virtual environment..."
    "$OLED_DIR/env/bin/pip" install --upgrade adafruit-circuitpython-ssd1306 adafruit-blinka Pillow
fi

mkdir -p "$OLED_DIR"

echo ">>> Creating/Updating monitor.py..."
cat << 'EOF' > "$OLED_DIR/monitor.py"
import time
import datetime
import subprocess
import board
import busio
import glob
import json
import os
import re
import smbus
from PIL import Image, ImageDraw, ImageFont
import adafruit_ssd1306

i2c = busio.I2C(board.SCL, board.SDA)
disp = adafruit_ssd1306.SSD1306_I2C(128, 32, i2c)

FAN_I2C_ADDR = 0x20
try:
    bus = smbus.SMBus(1)
    fan_present = True
except Exception:
    fan_present = False

width = disp.width
height = disp.height
image = Image.new("1", (width, height))
draw = ImageDraw.Draw(image)
font = ImageFont.load_default()

DEFAULT_JSON = """{
    // =====================================================================
    // OLED MONITOR SETTINGS
    // =====================================================================
    // Welcome to the configuration file! You can edit these values to change
    // how the OLED screen behaves. 
    // 
    // NOTE: This file is only read when the background service starts.
    // If you edit this file, you MUST restart the service for changes to apply:
    // sudo systemctl restart oled_monitor.service
    // 
    // DYNAMIC VARIABLES FOR CUSTOM PAGES:
    // {time}      - 14:30:00        {hour}       - 14
    // {minute}    - 30              {second}     - 00
    // {date}      - 2026-09-20      {day}        - 20
    // {month}     - 09              {year}       - 2026
    // {temp}      - 48.5            {ap_ip}      - 10.42.0.1
    // {ap_ssid}   - Your_Hotspot    {ap_pw}      - Password123
    // {wifi_ssid} - Connected_Wifi  {web_port}   - 80/8080
    //
    // IF YOU BREAK THIS FILE: Just run this command in your terminal to 
    // restore the default settings: touch ~/oled_monitor/reset
    // =====================================================================
    
    // --- Hardware & Warning Settings ---
    // Temperature (in Celsius) at which the PoE HAT fan turns ON
    "fan_on_temp": 55.0,
    // Temperature at which the fan turns OFF
    "fan_off_temp": 45.0,
    
    // Show flashing "HOT!" and "VOLT DROP!" screens if there is an issue?
    "show_warnings": true,
    // Temperature that triggers the HOT! warning screen
    "warning_temp": 75.0,
    
    // --- Global Display & Timing Settings ---
    // Default time each page is shown (in seconds) if not specified per-page
    "page_duration_seconds": 20,
    // How often to scan for new IP addresses and Wifi changes (in seconds)
    "network_update_interval_seconds": 20,
    
    // =====================================================================
    // Pages Configuration
    // =====================================================================
    // This is the list of screens to show. 
    // Set "duration": 0 on any page to completely hide/disable it.
    "pages": [
        {
            "type": "network_list",
            // Set to true to append the Hotspot IP to the bottom of the list 
            // ONLY when a device is actively connected to the hotspot.
            "show_ap_ip_when_connected": true,
            "duration": 20,
            "align": "left",
            "scroll_vertical": true,
            "scroll_horizontal": true
        },
        {
            "type": "hotspot_details",
            // Set to true to automatically hide the Hotspot SSID/Password 
            // page when a device successfully connects.
            "hide_when_connected": true,
            "duration": 20,
            "align": "left",
            "scroll_vertical": true,
            "scroll_horizontal": true
        },
        {
            // ==========================================
            // EXAMPLE CUSTOM PAGE (Disabled by default)
            // ==========================================
            // Change "duration" to 20 to enable this page!
            "type": "custom",
            "duration": 0, 
            
            // Text alignment: "left" (default), "center", or "right"
            "align": "center",
            
            // Scrolling: set to false to lock text in place
            "scroll_vertical": true,
            "scroll_horizontal": true,
            
            "lines": [
                "Time: {time}",
                "Date: {date}",
                "WiFi: {wifi_ssid}",
                "CPU Temp: {temp}C"
            ]
        }
    ]
}"""

def get_text_width(text, font):
    try: return int(draw.textlength(text, font=font))
    except AttributeError:
        try: return font.getsize(text)[0]
        except Exception: return len(text) * 6

def load_settings():
    """
    Loads configuration from settings.json. 
    Handles file resets and invalid JSON gracefully.
    """
    settings_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'settings.json')
    reset_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'reset')
    
    # Self-healing / Reset Trigger
    if os.path.exists(reset_file) or not os.path.exists(settings_file):
        try:
            with open(settings_file, 'w') as f:
                f.write(DEFAULT_JSON)
            if os.path.exists(reset_file):
                os.remove(reset_file)
        except Exception: pass
            
    default_dict = {
        "fan_on_temp": 55.0, "fan_off_temp": 45.0,
        "show_warnings": True, "warning_temp": 75.0,
        "page_duration_seconds": 20, "network_update_interval_seconds": 20,
        "pages": [
            {"type": "network_list", "show_ap_ip_when_connected": True, "duration": 20},
            {"type": "hotspot_details", "hide_when_connected": True, "duration": 20}
        ]
    }
    
    try:
        with open(settings_file, 'r') as f:
            content = f.read()
            # Strip // comments
            content = re.sub(r'^\s*//.*$', '', content, flags=re.MULTILINE)
            loaded = json.loads(content)
            for k, v in loaded.items():
                default_dict[k] = v
    except json.JSONDecodeError:
        return {"_error": True}
    except Exception:
        pass
        
    return default_dict

def format_custom_line(text, temp, ap_ssid, ap_ip, ap_psk, wifi_ssid, web_port):
    now = datetime.datetime.now()
    replacements = {
        "{time}": now.strftime("%H:%M:%S"),
        "{hour}": now.strftime("%H"),
        "{minute}": now.strftime("%M"),
        "{second}": now.strftime("%S"),
        "{date}": now.strftime("%Y-%m-%d"),
        "{day}": now.strftime("%d"),
        "{month}": now.strftime("%m"),
        "{year}": now.strftime("%Y"),
        "{temp}": str(temp),
        "{ap_ssid}": ap_ssid or "N/A",
        "{ap_pw}": ap_psk or "N/A",
        "{ap_ip}": ap_ip or "N/A",
        "{wifi_ssid}": wifi_ssid or "Not Connected",
        "{web_port}": web_port or "80"
    }
    for k, v in replacements.items():
        text = text.replace(k, v)
    return text

def get_webport():
    ports = []
    try:
        files1 = glob.glob('/home/*/Network-Testing-Tools/webport')
        if files1:
            with open(files1[0], 'r') as f:
                p1 = f.read().strip()
                if p1: ports.append(p1)
    except Exception: pass
    try:
        files2 = glob.glob('/home/*/pi-wifi-app/webport')
        if files2:
            with open(files2[0], 'r') as f:
                p2 = f.read().strip()
                if p2 and p2 not in ports: ports.append(p2)
    except Exception: pass
    if ports: return "/".join(ports)
    return "80"

def get_networks():
    networks = []
    try:
        out = subprocess.check_output(['ip', '-o', '-4', 'addr', 'show'], stderr=subprocess.DEVNULL).decode('utf-8')
        for line in out.split('\n'):
            if line.strip():
                parts = line.split()
                iface = parts[1]
                ip = parts[3].split('/')[0]
                if iface != "lo" and not iface.startswith("docker") and not iface.startswith("veth"):
                    networks.append((iface, ip))
    except Exception: pass
    return networks

def get_hotspot_details():
    ap_ssid, ap_psk, ap_has_clients, ap_iface, wifi_ssid = None, None, False, None, None
    try:
        active_conns = subprocess.check_output(['nmcli', '-t', '-f', 'NAME,TYPE', 'connection', 'show', '--active'], stderr=subprocess.DEVNULL).decode('utf-8').split('\n')
        for conn in active_conns:
            if 'wireless' in conn or '802-11-wireless' in conn:
                name = conn.split(':')[0]
                mode = subprocess.check_output(['nmcli', '-g', '802-11-wireless.mode', 'connection', 'show', name], stderr=subprocess.DEVNULL).decode('utf-8').strip()
                if mode == 'ap':
                    ap_ssid = subprocess.check_output(['nmcli', '-g', '802-11-wireless.ssid', 'connection', 'show', name], stderr=subprocess.DEVNULL).decode('utf-8').strip()
                    ap_psk = subprocess.check_output(['sudo', 'nmcli', '--show-secrets', '-g', '802-11-wireless-security.psk', 'connection', 'show', name], stderr=subprocess.DEVNULL).decode('utf-8').strip()
                    ap_iface = subprocess.check_output(['nmcli', '-g', 'GENERAL.DEVICES', 'connection', 'show', name], stderr=subprocess.DEVNULL).decode('utf-8').strip()
                    if ap_iface:
                        try:
                            stations = subprocess.check_output(['sudo', 'iw', 'dev', ap_iface, 'station', 'dump'], stderr=subprocess.DEVNULL).decode('utf-8')
                            if "Station" in stations: ap_has_clients = True
                        except Exception: pass
                elif mode == 'infrastructure':
                    wifi_ssid = subprocess.check_output(['nmcli', '-g', '802-11-wireless.ssid', 'connection', 'show', name], stderr=subprocess.DEVNULL).decode('utf-8').strip()
    except Exception: pass
    return ap_ssid, ap_psk, ap_has_clients, ap_iface, wifi_ssid

def get_temp():
    try:
        out = subprocess.check_output(['vcgencmd', 'measure_temp'], stderr=subprocess.DEVNULL).decode('utf-8')
        return float(out.replace('temp=', '').replace('\'C\n', ''))
    except Exception: return 0.0

def get_undervoltage():
    try:
        out = subprocess.check_output(['vcgencmd', 'get_throttled'], stderr=subprocess.DEVNULL).decode('utf-8')
        val = int(out.replace('throttled=', '').strip(), 16)
        return (val & 1) == 1
    except Exception: return False


# Load settings ONLY once on startup to save SD card resources
settings = load_settings()

last_hw_fetch = 0
last_net_fetch = 0

networks = []
ap_ssid, ap_psk, ap_has_clients, ap_iface, wifi_ssid = None, None, False, None, None
web_port = "80"
temp, uv = 0.0, False

current_page_idx = 0
page_start_time = time.time()
FPS_DELAY = 0.05    

try:
    while True:
        current_time = time.time()
        
        # Hardware & Fan Checks
        if current_time - last_hw_fetch > 5:
            temp = get_temp()
            uv = get_undervoltage()
            if fan_present:
                try:
                    if temp >= settings.get("fan_on_temp", 55.0): bus.write_byte(FAN_I2C_ADDR, 0xFE)
                    elif temp <= settings.get("fan_off_temp", 45.0): bus.write_byte(FAN_I2C_ADDR, 0xFF)
                except Exception: pass
            last_hw_fetch = current_time

        # Network Checks
        net_interval = settings.get("network_update_interval_seconds", 20)
        if current_time - last_net_fetch > net_interval:
            networks = get_networks()
            ap_ssid, ap_psk, ap_has_clients, ap_iface, wifi_ssid = get_hotspot_details()
            web_port = get_webport()
            last_net_fetch = current_time

        draw.rectangle((0, 0, width, height), outline=0, fill=0)
        
        # 1. Invalid JSON check
        if settings.get("_error"):
            draw.text((0, 0), "Settings Invalid!", font=font, fill=255)
            draw.text((0, 11), "Check settings.json", font=font, fill=255)
            disp.image(image)
            disp.show()
            time.sleep(FPS_DELAY)
            continue
            
        # 2. Hardware Warnings check
        SHOW_WARN = settings.get("show_warnings", True)
        WARN_TEMP = settings.get("warning_temp", 75.0)
        if SHOW_WARN and (uv or temp > WARN_TEMP):
            if int(current_time * 2) % 2 == 0:
                if uv: draw.text((0, 0), "WARNING: VOLT DROP!", font=font, fill=255)
                if temp > WARN_TEMP: draw.text((0, 16), f"WARNING: HOT! {temp}C", font=font, fill=255)
            disp.image(image)
            disp.show()
            time.sleep(FPS_DELAY)
            continue
            
        # 3. Compile Active Pages
        pages_to_render = []
        ap_ip_current = ""
        for iface, ip in networks:
            if iface == ap_iface: ap_ip_current = ip
                
        global_dur = settings.get("page_duration_seconds", 20)
        
        for page_config in settings.get("pages", []):
            ptype = page_config.get("type")
            dur = page_config.get("duration", global_dur)
            s_v = page_config.get("scroll_vertical", True)
            s_h = page_config.get("scroll_horizontal", True)
            align = page_config.get("align", "left")
            
            if dur <= 0: continue
                
            if ptype == "network_list":
                nlines = []
                show_ap_ip = page_config.get("show_ap_ip_when_connected", True)
                for iface, ip in networks:
                    if iface == ap_iface:
                        if show_ap_ip and ap_has_clients:
                            nlines.append(f"Pi: {ip}:{web_port}")
                    else:
                        nlines.append(f"{iface}: {ip}:{web_port}")
                if nlines:
                    pages_to_render.append({"type": "custom", "lines": nlines, "duration": dur, "s_v": s_v, "s_h": s_h, "align": align})
                    
            elif ptype == "hotspot_details":
                if ap_ssid and ap_psk:
                    hide = page_config.get("hide_when_connected", True)
                    if not (hide and ap_has_clients):
                        ip_str = ap_ip_current if ap_ip_current else "10.42.0.1"
                        pages_to_render.append({
                            "type": "custom", "duration": dur,
                            "lines": [f"Pi: {ap_ssid}", f"PW: {ap_psk}", f"IP: {ip_str}:{web_port}"],
                            "s_v": s_v, "s_h": s_h, "align": align
                        })
                        
            elif ptype == "custom":
                clines = []
                for line in page_config.get("lines", []):
                    clines.append(format_custom_line(str(line), temp, ap_ssid, ap_ip_current, ap_psk, wifi_ssid, web_port))
                pages_to_render.append({"type": "custom", "lines": clines, "duration": dur, "s_v": s_v, "s_h": s_h, "align": align})
                
        # 4. Unified Rendering Engine
        if not pages_to_render:
            draw.text((0, 12), "No Active Pages", font=font, fill=255)
        else:
            if current_page_idx >= len(pages_to_render):
                current_page_idx = 0
                page_start_time = current_time
                
            current_page = pages_to_render[current_page_idx]
            active_dur = current_page["duration"]
            s_v = current_page["s_v"]
            s_h = current_page["s_h"]
            align = current_page["align"]
            elapsed = current_time - page_start_time
            
            # Switch to next page?
            if elapsed >= active_dur:
                current_page_idx = (current_page_idx + 1) % len(pages_to_render)
                current_page = pages_to_render[current_page_idx]
                page_start_time = current_time
                elapsed = 0
                active_dur = current_page["duration"]
                s_v = current_page["s_v"]
                s_h = current_page["s_h"]
                align = current_page["align"]
                
            line_height = 11
            total_height = len(current_page["lines"]) * line_height
            y_base = 0
            
            # Vertical Scrolling Logic
            if s_v and total_height > height:
                max_y = total_height - height
                sdur = active_dur - 2.0 # 1s pause at top and bottom
                if sdur <= 0.1: sdur = 0.1
                if elapsed < 1.0: y_base = 0
                elif elapsed > active_dur - 1.0: y_base = -max_y
                else: y_base = -int(((elapsed - 1.0)/sdur) * max_y)
                
            # Horizontal Scrolling & Alignment Logic
            for i, line in enumerate(current_page["lines"]):
                dy = y_base + (i * line_height)
                if -line_height < dy < height:
                    lw = get_text_width(line, font)
                    xb = 0
                    if lw > width and s_h:
                        mx = lw - width + 10
                        cyc = mx * 0.05 + 2.0
                        ph = (elapsed % (cyc * 2))
                        if ph < cyc: xp = max(0, ph - 1.0) / (cyc - 1.0) if cyc > 1 else 0
                        else: xp = max(0, (cyc * 2 - ph) - 1.0) / (cyc - 1.0) if cyc > 1 else 0
                        xb = max(min(-int(xp * mx), 0), -mx)
                    else:
                        if align == "center":
                            xb = (width - lw) // 2
                        elif align == "right":
                            xb = width - lw
                        else:
                            xb = 0
                    draw.text((xb, dy), line, font=font, fill=255)
                    
        disp.image(image)
        disp.show()
        time.sleep(FPS_DELAY)
        
except KeyboardInterrupt:
    if fan_present:
        try: bus.write_byte(FAN_I2C_ADDR, 0xFF)
        except Exception: pass
EOF

chown -R "$USER_NAME:$USER_NAME" "$OLED_DIR"

echo ">>> Configuring Lighttpd for Captive Portal..."
grep -q 'mod_cgi' /etc/lighttpd/lighttpd.conf || echo 'server.modules += ( "mod_cgi" )' | sudo tee -a /etc/lighttpd/lighttpd.conf
grep -q 'cgi.assign' /etc/lighttpd/lighttpd.conf || echo 'cgi.assign = ( ".sh" => "/bin/bash" )' | sudo tee -a /etc/lighttpd/lighttpd.conf
grep -q 'index.sh' /etc/lighttpd/lighttpd.conf || echo 'index-file.names += ( "index.sh" )' | sudo tee -a /etc/lighttpd/lighttpd.conf

echo ">>> Creating Dynamic Redirect Script (index.sh)..."
cat << 'EOF' | sudo tee /var/www/html/index.sh > /dev/null
#!/bin/bash
PORT=80
PORT_FILE=$(ls /home/*/Network-Testing-Tools/webport 2>/dev/null | head -n 1)
if [ -z "$PORT_FILE" ]; then
    PORT_FILE=$(ls /home/*/pi-wifi-app/webport 2>/dev/null | head -n 1)
fi

if [ -n "$PORT_FILE" ] && [ -r "$PORT_FILE" ]; then
    EXTRACTED_PORT=$(cat "$PORT_FILE" | tr -d '[:space:]')
    [ -n "$EXTRACTED_PORT" ] && PORT="$EXTRACTED_PORT"
fi

echo "Status: 302 Found"
echo "Location: http://10.42.0.1:${PORT}/"
echo ""
EOF

sudo chmod +x /var/www/html/index.sh
sudo rm -f /var/www/html/index.html

echo ">>> Configuring NetworkManager DNS Hijacking..."
sudo mkdir -p /etc/NetworkManager/dnsmasq-shared.d
echo "address=/#/10.42.0.1" | sudo tee /etc/NetworkManager/dnsmasq-shared.d/captive.conf > /dev/null

echo ">>> Creating Systemd Service..."
cat << EOF | sudo tee /etc/systemd/system/oled_monitor.service > /dev/null
[Unit]
Description=OLED Network Monitor & Fan Controller
After=network.target

[Service]
Type=simple
ExecStart=$OLED_DIR/env/bin/python $OLED_DIR/monitor.py
WorkingDirectory=$OLED_DIR
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

echo ">>> Restarting Services..."
sudo systemctl daemon-reload
sudo systemctl enable oled_monitor.service
sudo systemctl restart oled_monitor.service
sudo systemctl restart lighttpd
sudo systemctl restart NetworkManager

echo "=========================================="
echo " Setup Complete! (v$SCRIPT_VERSION)"
echo "=========================================="