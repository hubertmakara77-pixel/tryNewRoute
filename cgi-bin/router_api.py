#!/usr/bin/env python3
import json
import os
import re
import subprocess
import sys
from typing import Dict, List

# Po instalacji konfiguracja będzie trzymana tutaj:
CONFIG_PATH = "/etc/router/config.inc"

# Root-helper, który stosuje zmiany WiFi (zrobi hostapd.conf + restart hostapd)
APPLY_WIFI_HELPER = "/usr/local/sbin/router_apply_wifi.sh"


def _send_json(status_code: int, payload: dict) -> None:
    sys.stdout.write("Content-Type: application/json\r\n")
    sys.stdout.write(f"Status: {status_code}\r\n\r\n")
    sys.stdout.write(json.dumps(payload))


def _read_body() -> str:
    try:
        length = int(os.environ.get("CONTENT_LENGTH", "0"))
    except ValueError:
        length = 0
    if length <= 0:
        return ""
    return sys.stdin.read(length)


def _parse_config_lines(lines: List[str]) -> Dict[str, str]:
    cfg: Dict[str, str] = {}
    for line in lines:
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", s)
        if not m:
            continue
        k = m.group(1)
        v = m.group(2).strip()
        # Usuń ewentualne cudzysłowy (na wypadek gdyby ktoś je dodał)
        if len(v) >= 2 and ((v[0] == v[-1] == '"') or (v[0] == v[-1] == "'")):
            v = v[1:-1]
        cfg[k] = v
    return cfg


def _read_config_file(path: str) -> List[str]:
    with open(path, "r", encoding="utf-8") as f:
        return f.readlines()


def _write_config_file_atomic(path: str, lines: List[str]) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.writelines(lines)
    os.replace(tmp, path)


def _update_config_keys(path: str, updates: Dict[str, str]) -> None:
    lines = _read_config_file(path)

    found = set()
    out: List[str] = []

    for line in lines:
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line.strip())
        if m:
            k = m.group(1)
            if k in updates:
                # zapis w stylu Twojego config.inc: KEY=value (bez cudzysłowów)
                out.append(f"{k}={updates[k]}\n")
                found.add(k)
                continue
        out.append(line)

    missing = [k for k in updates.keys() if k not in found]
    if missing:
        out.append("\n# Added by router_api.py\n")
        for k in missing:
            out.append(f"{k}={updates[k]}\n")

    _write_config_file_atomic(path, out)


def _safe_text(v: str, max_len: int) -> str:
    v = (v or "").strip()
    if not v:
        raise ValueError("Empty value")
    if len(v) > max_len:
        raise ValueError("Value too long")
    if any(c in v for c in ["\r", "\n", "\t", "\0"]):
        raise ValueError("Invalid characters")
    return v


def handle_get() -> None:
    try:
        lines = _read_config_file(CONFIG_PATH)
    except FileNotFoundError:
        _send_json(500, {"status": "error", "message": f"Missing config: {CONFIG_PATH}"})
        return

    cfg = _parse_config_lines(lines)

    _send_json(200, {
        "ip_address": cfg.get("IN_INT_IP", "192.168.0.1"),
        "ssid": cfg.get("AP_SSID", ""),
        "wifi_pass": cfg.get("AP_PASS", ""),
        "dhcp_start": cfg.get("DHCP_RANGE_START", ""),
        "dhcp_stop": cfg.get("DHCP_RANGE_STOP", ""),
        "dns_1": cfg.get("DHCP_DNS_1", ""),
        "dns_2": cfg.get("DHCP_DNS_2", ""),
    })


def handle_post() -> None:
    body = _read_body()
    try:
        req = json.loads(body) if body else {}
    except json.JSONDecodeError:
        _send_json(400, {"status": "error", "message": "Invalid JSON"})
        return

    if req.get("action") != "save_wifi":
        _send_json(400, {"status": "error", "message": "Unknown action"})
        return

    try:
        ssid = _safe_text(req.get("ssid", ""), max_len=32)
        password = _safe_text(req.get("password", ""), max_len=63)
        if len(password) < 8:
            raise ValueError("Hasło musi mieć min. 8 znaków")
    except ValueError as e:
        _send_json(400, {"status": "error", "message": str(e)})
        return

    try:
        _update_config_keys(CONFIG_PATH, {"AP_SSID": ssid, "AP_PASS": password})
    except Exception as e:
        _send_json(500, {"status": "error", "message": f"Failed to update config: {e}"})
        return

    # Zastosuj zmiany: hostapd.conf + restart hostapd (root helper przez sudoers)
    try:
        subprocess.check_call(["/usr/bin/sudo", APPLY_WIFI_HELPER])
    except Exception as e:
        _send_json(500, {"status": "error", "message": f"Failed to apply WiFi: {e}"})
        return

    _send_json(200, {"status": "success", "message": "Zapisano. WiFi zaktualizowane."})


def main() -> None:
    method = os.environ.get("REQUEST_METHOD", "GET").upper()
    if method == "GET":
        handle_get()
    elif method == "POST":
        handle_post()
    else:
        _send_json(405, {"status": "error", "message": "Method not allowed"})


if __name__ == "__main__":
    main()
