#!/usr/bin/env python3
import os
import sys
import json
import re
import subprocess
import tempfile

CFG = "/etc/orangepi-router/config.inc"
APPLY_HOSTAPD = ["/usr/bin/sudo", "/usr/local/orangepi-router/scripts/hostapd.sh"]

def respond(code: int, payload: dict):
    print("Content-Type: application/json")
    print(f"Status: {code}")
    print()
    print(json.dumps(payload))

def load_cfg() -> dict:
    cfg = {}
    if not os.path.exists(CFG):
        return cfg
    with open(CFG, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip()
    return cfg

def save_cfg(cfg: dict):
    # zapis atomowy
    fd, tmp = tempfile.mkstemp()
    with os.fdopen(fd, "w") as f:
        f.write("#!/bin/bash\n\n")
        for k in sorted(cfg.keys()):
            f.write(f"{k}={cfg[k]}\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, CFG)

def get_ip():
    try:
        out = subprocess.check_output(["hostname", "-I"], text=True).strip()
        return out.split()[0] if out else "---"
    except Exception:
        return "---"

def sanitize_value(s: str) -> str:
    # usuń znaki końca linii, żeby nie rozwalić configu
    return s.replace("\r", "").replace("\n", "").strip()

def handle_get():
    cfg = load_cfg()
    respond(200, {
        "ip_address": get_ip(),
        "ssid": cfg.get("AP_SSID", ""),
        "wifi_pass": cfg.get("AP_PASS", ""),
        "dhcp_start": cfg.get("DHCP_RANGE_START", ""),
        "dhcp_stop": cfg.get("DHCP_RANGE_STOP", ""),
        "dns_1": cfg.get("DHCP_DNS_1", ""),
        "dns_2": cfg.get("DHCP_DNS_2", ""),
        "in_interface": cfg.get("IN_INTERFACE", ""),
        "out_interface": cfg.get("OUT_INTERFACE", ""),
        "internal_ip": cfg.get("IN_INT_IP", "")
    })

def handle_post():
    ln = int(os.environ.get("CONTENT_LENGTH", "0") or "0")
    raw = sys.stdin.read(ln)
    data = json.loads(raw) if raw else {}

    action = data.get("action", "")

    if action != "save_wifi":
        respond(400, {"status": "error", "message": "Nieznana akcja"})
        return

    ssid = sanitize_value(str(data.get("ssid", "")))
    password = sanitize_value(str(data.get("password", "")))

    if not (1 <= len(ssid) <= 32):
        respond(400, {"status": "error", "message": "SSID musi mieć 1–32 znaki"})
        return

    if len(password) < 8 or len(password) > 63:
        respond(400, {"status": "error", "message": "Hasło WPA2 musi mieć 8–63 znaki"})
        return

    # opcjonalnie: ogranicz znaki
    if not re.match(r'^[ -~]+$', ssid) or not re.match(r'^[ -~]+$', password):
        respond(400, {"status": "error", "message": "Niedozwolone znaki w SSID/haśle"})
        return

    cfg = load_cfg()
    cfg["AP_SSID"] = ssid
    cfg["AP_PASS"] = password
    save_cfg(cfg)

    try:
        subprocess.check_output(APPLY_HOSTAPD, stderr=subprocess.STDOUT, text=True)
        respond(200, {"status": "success", "message": "Zapisano. Zastosowano ustawienia Wi-Fi."})
    except subprocess.CalledProcessError as e:
        msg = e.output.strip() if e.output else "Błąd uruchomienia hostapd.sh"
        respond(500, {"status": "error", "message": msg})

def main():
    method = os.environ.get("REQUEST_METHOD", "GET").upper()
    try:
        if method == "GET":
            handle_get()
        elif method == "POST":
            handle_post()
        else:
            respond(405, {"status": "error", "message": "Metoda niedozwolona"})
    except Exception as e:
        respond(500, {"status": "error", "message": str(e)})

if __name__ == "__main__":
    main()
