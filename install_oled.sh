#!/bin/bash

echo "=========================================="
echo " Starting OLED, Fan & Captive Portal Setup"
echo "=========================================="

# Get current user and home directory
USER_NAME=$(whoami)
USER_HOME=$HOME
OLED_DIR="$USER_HOME/oled_monitor"

echo ">>> Enabling I2C Interface..."
sudo raspi-config nonint do_i2c 0

# Ensure it is enabled in both old and new Raspberry Pi OS config locations
grep -q "^dtparam=i2c_arm=on" /boot/firmware/config.txt 2>/dev/null || echo "dtparam=i2c_arm=on" | sudo tee -a /boot/firmware/config.txt > /dev/null
grep -q "^dtparam=i2c_arm=on" /boot/config.txt 2>/dev/null || echo "dtparam=i2c_arm=on" | sudo tee -a /boot/config.txt > /dev/null

# Force the kernel to load I2C immediately so we don't have to reboot
sudo modprobe i2c-dev
sudo modprobe i2c-bcm2835 2>/dev/null || true

echo ">>> Installing System Dependencies..."
sudo apt update
sudo apt install -y swig liblgpio-dev python3-lgpio python3-rpi.gpio python3-venv python3-pip python3-pil i2c-tools lighttpd python3-smbus

echo ">>> Setting up Python Virtual Environment..."
mkdir -p "$OLED_DIR"
python3 -m venv --system-site-packages "$OLED_DIR/env"

echo ">>> Installing Adafruit Libraries..."
"$OLED_DIR/env/bin/pip" install adafruit-circuitpython-ssd1306 adafruit-blinka Pillow

echo ">>> Creating monitor.py..."
cat << 'EOF' > "$OLED_DIR/monitor.py"
import time
import subprocess
import board
import busio
import glob
from PIL import Image, ImageDraw, ImageFont
import adafruit_ssd1306

# Initialize OLED Screen
i2c = busio.I2C(board.SCL, board.SDA)
disp = adafruit_ssd1306.SSD1306_I2C(128, 32, i2c)

width = disp.width
height = disp.height
image = Image.new("1", (width, height))
draw = ImageDraw.Draw(image)
font = ImageFont.load_default()

def get_webport():
    try:
        files = glob.glob('/home/*/Network-Testing-Tools/webport')
        if files:
            with open(files[0], 'r') as f:
                port = f.read().strip()
                if port:
                    return port
    except Exception:
        pass
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
    except Exception:
        pass
    return networks

def get_hotspot_details():
    try:
        active_conns = subprocess.check_output(['nmcli', '-t', '-f', 'NAME,TYPE', 'connection', 'show', '--active'], stderr=subprocess.DEVNULL).decode('utf-8').split('\n')
        for conn in active_conns:
            if 'wireless' in conn or '802-11-wireless' in conn:
                name = conn.split(':')[0]
                mode = subprocess.check_output(['nmcli', '-g', '802-11-wireless.mode', 'connection', 'show', name], stderr=subprocess.DEVNULL).decode('utf-8').strip()
                if mode == 'ap':
                    ssid = subprocess.check_output(['nmcli', '-g', '802-11-wireless.ssid', 'connection', 'show', name], stderr=subprocess.DEVNULL).decode('utf-8').strip()
                    psk = subprocess.check_output(['sudo', 'nmcli', '--show-secrets', '-g', '802-11-wireless-security.psk', 'connection', 'show', name], stderr=subprocess.DEVNULL).decode('utf-8').strip()
                    iface = subprocess.check_output(['nmcli', '-g', 'GENERAL.DEVICES', 'connection', 'show', name], stderr=subprocess.DEVNULL).decode('utf-8').strip()
                    
                    has_clients = False
                    if iface:
                        try:
                            stations = subprocess.check_output(['sudo', 'iw', 'dev', iface, 'station', 'dump'], stderr=subprocess.DEVNULL).decode('utf-8')
                            if "Station" in stations:
                                has_clients = True
                        except Exception:
                            pass
                    return ssid, psk, has_clients, iface
    except Exception:
        pass
    return None, None, False, None

def get_temp():
    try:
        out = subprocess.check_output(['vcgencmd', 'measure_temp'], stderr=subprocess.DEVNULL).decode('utf-8')
        return float(out.replace('temp=', '').replace('\'C\n', ''))
    except Exception:
        return 0.0

def get_undervoltage():
    try:
        out = subprocess.check_output(['vcgencmd', 'get_throttled'], stderr=subprocess.DEVNULL).decode('utf-8')
        val = int(out.replace('throttled=', '').strip(), 16)
        return (val & 1) == 1
    except Exception:
        return False

last_hw_fetch = 0
last_net_fetch = 0

networks = []
ap_ssid, ap_psk, ap_has_clients, ap_iface = None, None, False, None
web_port = "80"
temp, uv = 0.0, False

scroll_x = 0
scroll_dir = -1
pause_time = 2.0
PAGE_DURATION = 20
FPS_DELAY = 0.05    

try:
    while True:
        current_time = time.time()
        
        if current_time - last_hw_fetch > 5:
            temp = get_temp()
            uv = get_undervoltage()
            last_hw_fetch = current_time

        if current_time - last_net_fetch > 20:
            networks = get_networks()
            ap_ssid, ap_psk, ap_has_clients, ap_iface = get_hotspot_details()
            web_port = get_webport()
            last_net_fetch = current_time

        draw.rectangle((0, 0, width, height), outline=0, fill=0)
        
        if uv or temp > 75.0:
            if int(current_time * 2) % 2 == 0:
                if uv:
                    draw.text((0, 0), "WARNING: VOLT DROP!", font=font, fill=255)
                if temp > 75.0:
                    draw.text((0, 16), f"WARNING: HOT! {temp}C", font=font, fill=255)
            disp.image(image)
            disp.show()
            time.sleep(FPS_DELAY)
            continue
            
        pages = []
        network_lines = []
        ap_ip = ""
        
        for iface, ip in networks:
            if iface == ap_iface:
                ap_ip = ip
                network_lines.append(f"AP: {ip}:{web_port}")
            else:
                network_lines.append(f"{iface}: {ip}")

        if network_lines:
            pages.append("networks")
            
        if ap_ssid and ap_psk:
            pages.append("hotspot")
            
        if not pages:
            draw.text((0, 12), "No Network", font=font, fill=255)
        else:
            page_index = int(current_time / PAGE_DURATION) % len(pages)
            current_page = pages[page_index]
            
            if current_page == "networks":
                y_offset = 0
                for line in network_lines[:2]:
                    draw.text((0, y_offset), line, font=font, fill=255)
                    y_offset += 16
                scroll_x = 0 
                scroll_dir = -1
                pause_time = 2.0 
                
            elif current_page == "hotspot":
                ap_text = f"AP: {ap_ssid}"
                try:
                    text_width = int(draw.textlength(ap_text, font=font))
                except AttributeError:
                    try:
                        text_width = font.getsize(ap_text)[0]
                    except Exception:
                        text_width = len(ap_text) * 6
                
                if text_width > width:
                    draw.text((scroll_x, 0), ap_text, font=font, fill=255)
                    if pause_time > 0:
                        pause_time -= FPS_DELAY
                    else:
                        max_scroll = width - text_width - 12
                        scroll_x += scroll_dir * 2
                        if scroll_x <= max_scroll:
                            scroll_x = max_scroll
                            scroll_dir = 1
                            pause_time = 2.0
                        elif scroll_x >= 0:
                            scroll_x = 0
                            scroll_dir = -1
                            pause_time = 2.0
                else:
                    draw.text((0, 0), ap_text, font=font, fill=255)
                
                # Line 2 shows Password, Line 3 shows Hotspot IP + Port
                draw.text((0, 11), f"PW: {ap_psk}", font=font, fill=255)
                if ap_ip:
                    draw.text((0, 22), f"IP: {ap_ip}:{web_port}", font=font, fill=255)
                else:
                    draw.text((0, 22), f"IP: 10.42.0.1:{web_port}", font=font, fill=255)
                    
        disp.image(image)
        disp.show()
        time.sleep(FPS_DELAY)
except KeyboardInterrupt:
    pass
EOF

echo ">>> Configuring Lighttpd for Captive Portal..."
grep -q 'mod_cgi' /etc/lighttpd/lighttpd.conf || echo 'server.modules += ( "mod_cgi" )' | sudo tee -a /etc/lighttpd/lighttpd.conf
grep -q 'cgi.assign' /etc/lighttpd/lighttpd.conf || echo 'cgi.assign = ( ".sh" => "/bin/bash" )' | sudo tee -a /etc/lighttpd/lighttpd.conf
grep -q 'index.sh' /etc/lighttpd/lighttpd.conf || echo 'index-file.names += ( "index.sh" )' | sudo tee -a /etc/lighttpd/lighttpd.conf

echo ">>> Creating Dynamic Redirect Script (index.sh)..."
cat << 'EOF' | sudo tee /var/www/html/index.sh > /dev/null
#!/bin/bash
PORT=80
PORT_FILE=$(ls /home/*/Network-Testing-Tools/webport 2>/dev/null | head -n 1)
if [ -n "$PORT_FILE" ] && [ -r "$PORT_FILE" ]; then
PORT=$(cat "$PORT_FILE" | tr -d '[:space:]')
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
echo " Setup Complete!"
echo "=========================================="