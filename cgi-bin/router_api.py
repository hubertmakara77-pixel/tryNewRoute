#!/usr/bin/env python3
import json, subprocess, os, sys, re

# Konfiguracja
HOSTAPD_CONF = "/etc/hostapd/hostapd.conf"

def run(cmd):
    try: return subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.STDOUT).strip()
    except: return ""

def get_conf():
    ip = run("hostname -I | awk '{print $1}'") or "192.168.0.1"
    data = {'ip_address': ip, 'dhcp_start': '192.168.0.10', 'ssid': '', 'wifi_pass': ''}
    try:
        if os.path.exists(HOSTAPD_CONF):
            with open(HOSTAPD_CONF, 'r') as f: c = f.read()
            s = re.search(r'^ssid=(.*)', c, re.MULTILINE)
            p = re.search(r'^wpa_passphrase=(.*)', c, re.MULTILINE)
            data['ssid'] = s.group(1).strip() if s else ""
            data['wifi_pass'] = p.group(1).strip() if p else ""
    except: pass
    return data

def save(ssid, password):
    if not ssid: return {"status": "error", "message": "Nazwa sieci nie moze byc pusta"}
    
    try:
        # 1. ODCZYT
        lines = []
        if os.path.exists(HOSTAPD_CONF):
            with open(HOSTAPD_CONF, 'r') as f: lines = f.readlines()
        
        # 2. EDYCJA
        new_l = []
        fs, fp = False, False
        for l in lines:
            if l.startswith('ssid='): new_l.append(f"ssid={ssid}\n"); fs=True
            elif l.startswith('wpa_passphrase='): new_l.append(f"wpa_passphrase={password}\n"); fp=True
            else: new_l.append(l)
        if not fs: new_l.append(f"ssid={ssid}\n")
        if not fp: new_l.append(f"wpa_passphrase={password}\n")
        
        # 3. ZAPIS (Kluczowy moment)
        with open(HOSTAPD_CONF, 'w') as f: f.writelines(new_l)
        
        # 4. RESTART (Dzięki sudoers to zadziała bez hasła)
        subprocess.check_output("sudo systemctl restart hostapd", shell=True, stderr=subprocess.STDOUT)
        
        return {"status": "success", "message": "Zapisano! Router restartuje sie..."}

    except PermissionError:
        return {"status": "error", "message": "Blad uprawnien (Permission denied) przy zapisie pliku!"}
    except subprocess.CalledProcessError as e:
        err = e.output if e.output else str(e)
        return {"status": "error", "message": f"Blad restartu WiFi: {err}"}
    except Exception as e:
        return {"status": "error", "message": f"Blad: {str(e)}"}

# OBSŁUGA ŻĄDAŃ
print("Content-Type: application/json\n")
try:
    if os.environ.get("REQUEST_METHOD") == "POST":
        ln = int(os.environ.get('CONTENT_LENGTH', 0))
        d = json.loads(sys.stdin.read(ln))
        if d.get('action') == 'save_wifi': print(json.dumps(save(d.get('ssid'), d.get('password'))))
    else: print(json.dumps(get_conf()))
except Exception as e: print(json.dumps({"status": "error", "message": str(e)}))
