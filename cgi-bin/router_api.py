#!/usr/bin/env python3
import cgi
import cgitb
import json
import subprocess
import os
import sys

# Włączamy raportowanie błędów w przeglądarce
cgitb.enable()

# --- KONFIGURACJA ---
# Zmień na False przed wrzuceniem na Orange Pi!
DEV_MODE = False 

if DEV_MODE:
    # Ścieżki lokalne (Windows/Mac) do testów
    HOSTAPD_CONF = "mock_hostapd.conf" 
    DNSMASQ_CONF = "mock_dnsmasq.conf"
else:
    # Ścieżki prawdziwe (Orange Pi)
    HOSTAPD_CONF = "/etc/hostapd/hostapd.conf"
    DNSMASQ_CONF = "/etc/dnsmasq.conf"

def run_command(command):
    """Wykonywanie komend z obsługą trybu testowego"""
    if DEV_MODE:
        # Symulacja odpowiedzi systemu
        if "ip -4" in command:
            return "192.168.100.1" # Udajemy adres IP
        print(f"DEBUG (Command ignored): {command}", file=sys.stderr)
        return ""
    
    try:
        result = subprocess.check_output(command, shell=True, text=True)
        return result.strip()
    except subprocess.CalledProcessError:
        return ""

def get_current_config():
    data = {}
    
    # 1. IP
    data['ip_address'] = run_command("ip -4 addr show wlan0") or "0.0.0.0"
    
    # 2. WiFi Config
    try:
        # W trybie DEV musimy szukać pliku w folderze wyżej (bo skrypt jest w cgi-bin)
        file_path = f"../{HOSTAPD_CONF}" if DEV_MODE else HOSTAPD_CONF
        
        if os.path.exists(file_path):
            with open(file_path, 'r') as f:
                content = f.read()
                import re
                ssid_match = re.search(r'^ssid=(.*)', content, re.MULTILINE)
                pass_match = re.search(r'^wpa_passphrase=(.*)', content, re.MULTILINE)
                
                data['ssid'] = ssid_match.group(1).strip() if ssid_match else ""
                data['wifi_pass'] = pass_match.group(1).strip() if pass_match else ""
        else:
            data['ssid'] = "Brak pliku"
            data['wifi_pass'] = ""
            
    except Exception as e:
        data['ssid'] = f"Error: {str(e)}"

    # 3. DHCP (Mock stały na razie)
    data['dhcp_start'] = "192.168.0.10"
    
    return data

def save_wifi_config(ssid, password):
    file_path = f"../{HOSTAPD_CONF}" if DEV_MODE else HOSTAPD_CONF
    
    try:
        # Czytamy plik
        lines = []
        if os.path.exists(file_path):
            with open(file_path, 'r') as f:
                lines = f.readlines()
        else:
            # Tworzymy nowy jeśli nie ma
            lines = ["ssid=\n", "wpa_passphrase=\n"]

        # Zapisujemy do tymczasowego
        temp_path = file_path + ".tmp"
        with open(temp_path, 'w') as f:
            found_ssid = False
            found_pass = False
            
            for line in lines:
                if line.startswith('ssid='):
                    f.write(f'ssid={ssid}\n')
                    found_ssid = True
                elif line.startswith('wpa_passphrase='):
                    f.write(f'wpa_passphrase={password}\n')
                    found_pass = True
                else:
                    f.write(line)
            
            # Jeśli nie było tych linii, dodajemy je na końcu
            if not found_ssid: f.write(f'ssid={ssid}\n')
            if not found_pass: f.write(f'wpa_passphrase={password}\n')

        # Podmiana pliku
        if DEV_MODE:
            os.replace(temp_path, file_path)
            # Nie restartujemy usługi w trybie DEV
        else:
            run_command(f"sudo tee {HOSTAPD_CONF} < {temp_path}")
            run_command("sudo systemctl restart hostapd")
            
        return {"status": "success", "message": f"Saved SSID: {ssid}"}
    except Exception as e:
        return {"status": "error", "message": str(e)}

# --- OBSŁUGA CGI ---
print("Content-Type: application/json\n")

try:
    method = os.environ.get("REQUEST_METHOD", "GET")
    
    if method == "GET":
        print(json.dumps(get_current_config()))
        
    elif method == "POST":
        # Hack dla Windowsa (Windows rzadko ustawia CONTENT_LENGTH w prostym serwerze)
        try:
            length = int(os.environ.get('CONTENT_LENGTH', 0))
        except:
            length = 0
            
        if length > 0:
            post_data = sys.stdin.read(length)
            request = json.loads(post_data)
            
            if request.get('action') == 'save_wifi':
                print(json.dumps(save_wifi_config(request.get('ssid'), request.get('password'))))
            else:
                print(json.dumps({"status": "error", "message": "Unknown action"}))
        else:
             print(json.dumps({"status": "error", "message": "No data"}))

except Exception as e:
    print(json.dumps({"status": "critical_error", "message": str(e)}))