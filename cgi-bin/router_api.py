#!/usr/bin/env python3
import json
import subprocess
import os
import sys
import re
import traceback

# --- KONFIGURACJA ---
# Ustaw na False na produkcji (Orange Pi)
DEV_MODE = False

if DEV_MODE:
    HOSTAPD_CONF = "mock_hostapd.conf"
    DNSMASQ_CONF = "mock_dnsmasq.conf"
else:
    HOSTAPD_CONF = "/etc/hostapd/hostapd.conf"
    DNSMASQ_CONF = "/etc/dnsmasq.conf"

def run_command(command):
    """Wykonywanie komend z obsługą błędów"""
    if DEV_MODE:
        if "ip -4" in command:
            return "192.168.100.1"
        return ""

    try:
        # Używamy shell=True, aby obsłużyć potoki i sudo
        result = subprocess.check_output(command, shell=True, text=True, stderr=subprocess.STDOUT)
        return result.strip()
    except subprocess.CalledProcessError:
        return ""
    except Exception:
        return ""

def get_current_config():
    data = {}

    # 1. IP
    data['ip_address'] = run_command("ip -4 addr show wlan0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1") or run_command("hostname -I | awk '{print $1}'") or "0.0.0.0"

    # 2. WiFi Config
    try:
        if os.path.exists(HOSTAPD_CONF):
            with open(HOSTAPD_CONF, 'r') as f:
                content = f.read()
                
                ssid_match = re.search(r'^ssid=(.*)', content, re.MULTILINE)
                pass_match = re.search(r'^wpa_passphrase=(.*)', content, re.MULTILINE)

                data['ssid'] = ssid_match.group(1).strip() if ssid_match else ""
                data['wifi_pass'] = pass_match.group(1).strip() if pass_match else ""
        else:
            data['ssid'] = "Brak pliku config"
            data['wifi_pass'] = ""

    except Exception as e:
        data['ssid'] = f"Error reading config: {str(e)}"
        data['wifi_pass'] = ""

    # 3. DHCP (Stała wartość lub odczytana z dnsmasq)
    data['dhcp_start'] = "192.168.0.10" 

    return data

def save_wifi_config(ssid, password):
    # Walidacja podstawowa
    if not ssid or len(ssid) < 1:
        return {"status": "error", "message": "SSID cannot be empty"}
    
    # --- ZAPIS BEZPOŚREDNI (Najpewniejsza metoda) ---
    try:
        # Odczytujemy stary plik
        current_lines = []
        if os.path.exists(HOSTAPD_CONF):
            with open(HOSTAPD_CONF, 'r') as f:
                current_lines = f.readlines()
        
        # Jeśli plik był pusty, dodajemy podstawy
        if not current_lines:
            current_lines = ["interface=wlan0\n", "hw_mode=g\n", "channel=7\n", "wpa=2\n", "wpa_key_mgmt=WPA-PSK\n", "rsn_pairwise=CCMP\n"]

        new_lines = []
        found_ssid = False
        found_pass = False

        for line in current_lines:
            if line.strip().startswith('ssid='):
                new_lines.append(f"ssid={ssid}\n")
                found_ssid = True
            elif line.strip().startswith('wpa_passphrase='):
                new_lines.append(f"wpa_passphrase={password}\n")
                found_pass = True
            else:
                new_lines.append(line)
        
        if not found_ssid:
            new_lines.append(f"ssid={ssid}\n")
        if not found_pass:
            new_lines.append(f"wpa_passphrase={password}\n")

        # Zapisujemy BEZPOŚREDNIO do pliku (wymaga, aby właścicielem był www-data)
        if not DEV_MODE:
            with open(HOSTAPD_CONF, 'w') as f:
                f.writelines(new_lines)
            
            # Restartujemy usługę (to wymaga sudo, ale mamy to w sudoers)
            run_command("sudo systemctl restart hostapd")

        return {"status": "success", "message": "WiFi settings saved directly."}

    except Exception as e:
        return {"status": "error", "message": f"Save failed: {str(e)}"}

# --- GŁÓWNA OBSŁUGA ---
if __name__ == "__main__":
    # Musimy wypisać nagłówek Content-Type, inaczej przeglądarka zgłosi błąd 500
    print("Content-Type: application/json\n")

    try:
        method = os.environ.get("REQUEST_METHOD", "GET")

        if method == "GET":
            print(json.dumps(get_current_config()))

        elif method == "POST":
            # Ręczne pobieranie danych POST (zastępuje cgi.FieldStorage)
            try:
                content_length = int(os.environ.get('CONTENT_LENGTH', 0))
            except (ValueError, TypeError):
                content_length = 0

            if content_length > 0:
                post_body = sys.stdin.read(content_length)
                try:
                    request_data = json.loads(post_body)
                    
                    action = request_data.get('action')
                    if action == 'save_wifi':
                        result = save_wifi_config(request_data.get('ssid'), request_data.get('password'))
                        print(json.dumps(result))
                    else:
                        print(json.dumps({"status": "error", "message": "Unknown action"}))
                except json.JSONDecodeError:
                    print(json.dumps({"status": "error", "message": "Invalid JSON data"}))
            else:
                print(json.dumps({"status": "error", "message": "No data received"}))
        
        else:
             print(json.dumps({"status": "error", "message": "Method not allowed"}))

    except Exception as e:
        # Awaryjna obsługa błędów - zastępuje cgitb
        error_msg = {
            "status": "critical_error",
            "message": str(e),
            "trace": traceback.format_exc()
        }
        print(json.dumps(error_msg))
