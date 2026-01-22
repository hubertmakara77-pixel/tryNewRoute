#!/usr/bin/python3
# -*- coding: utf-8 -*-

import json
import os
import re
import subprocess
import sys
from typing import Dict, Tuple

CFG = "/etc/orangepi-router/config.inc"


def _print(status_code: int, payload: dict) -> None:
    sys.stdout.write("Content-Type: application/json\r\n")
    sys.stdout.write(f"Status: {status_code}\r\n\r\n")
    sys.stdout.write(json.dumps(payload))


def _read_cfg(path: str) -> Dict[str, str]:
    data: Dict[str, str] = {}
    if not os.path.exists(path):
        return data

    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            k, v = line.split("=", 1)
            data[k.strip()] = v.strip()
    return data


def _build_cfg_text(cfg: Dict[str, str]) -> str:
    # zachowujemy shebang, bo Twoje skrypty też to mają
    lines = ["#!/bin/bash", ""]
    # Utrzymujemy stałą kolejność pól (czytelność)
    order = [
        "IN_INTERFACE",
        "OUT_INTERFACE",
        "IN_INT_IP",
        "DHCP_RANGE_START",
        "DHCP_RANGE_STOP",
        "DHCP_DNS_1",
        "DHCP_DNS_2",
        "AP_SSID",
        "AP_PASS",
    ]
    for k in order:
        if k in cfg:
            lines.append(f"{k}={cfg[k]}")
    # dopisz inne klucze jeśli są, a nie ma ich w order
    for k in sorted(cfg.keys()):
        if k not in order:
            lines.append(f"{k}={cfg[k]}")
    lines.append("")
    return "\n".join(lines)


def _sudo_tee_write(path: str, content: str) -> None:
    # zapis jako root przez sudo tee (www-data nie musi mieć praw do katalogu)
    p = subprocess.run(
        ["sudo", "/usr/bin/tee", path],
        input=content.encode("utf-8"),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        check=False,
    )
    if p.returncode != 0:
        raise RuntimeError(p.stderr.decode("utf-8", errors="ignore").strip())


def _sync_to_scripts_cfg() -> None:
    # żeby skrypty (source ../config.inc) widziały to samo, nawet jeśli symlink nie zadziałał
    subprocess.run(
        ["sudo", "/bin/cp", "/etc/orangepi-router/config.inc", "/usr/local/orangepi-router/config.inc"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def _apply_hostapd(cfg: Dict[str, str]) -> None:
    # Minimalna aktualizacja: przepisz hostapd.conf i zrestartuj usługę
    ssid = cfg.get("AP_SSID", "")
    wpa = cfg.get("AP_PASS", "")

    hostapd_conf = (
        "interface=wlan0\n"
        "hw_mode=a\n"
        "channel=36\n"
        "ieee80211ac=1\n"
        "country_code=PL\n"
        f"ssid={ssid}\n"
        "auth_algs=1\n"
        "wpa=2\n"
        "wpa_key_mgmt=WPA-PSK\n"
        "rsn_pairwise=CCMP\n"
        f"wpa_passphrase={wpa}\n"
        "wmm_enabled=1\n"
    )

    # zapis hostapd.conf jako root (tu używamy tee bez sudoers “na wszystko”)
    p = subprocess.run(
        ["sudo", "/usr/bin/tee", "/etc/hostapd/hostapd.conf"],
        input=hostapd_conf.encode("utf-8"),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        check=False,
    )
    if p.returncode != 0:
        raise RuntimeError(p.stderr.decode("utf-8", errors="ignore").strip())

    subprocess.run(["sudo", "/usr/bin/systemctl", "restart", "hostapd"], check=False)


def _get_ip_address_fallback(cfg: Dict[str, str]) -> str:
    # dla frontu: pokazuj lokalny gateway = IN_INT_IP
    return cfg.get("IN_INT_IP", "undefined")


def _parse_body() -> dict:
    method = os.environ.get("REQUEST_METHOD", "GET").upper()
    if method != "POST":
        return {}

    try:
        length = int(os.environ.get("CONTENT_LENGTH", "0"))
    except ValueError:
        length = 0

    raw = sys.stdin.read(length) if length > 0 else ""
    if not raw.strip():
        return {}

    return json.loads(raw)


def _validate_wifi(ssid: str, password: str) -> Tuple[bool, str]:
    # SSID: 1..32 (praktycznie)
    if not (1 <= len(ssid) <= 32):
        return False, "SSID musi mieć 1–32 znaki."

    # WPA2: 8..63
    if not (8 <= len(password) <= 63):
        return False, "Hasło WPA2 musi mieć 8–63 znaki."

    # prosta ochrona przed wstrzyknięciem nowych linii do configu
    if re.search(r"[\r\n]", ssid) or re.search(r"[\r\n]", password):
        return False, "Nieprawidłowe znaki w SSID/haśle."

    return True, ""


def handle_get() -> None:
    cfg = _read_cfg(CFG)

    payload = {
        "ip_address": _get_ip_address_fallback(cfg),
        "ssid": cfg.get("AP_SSID", "undefined"),
        "wifi_pass": cfg.get("AP_PASS", "undefined"),
        "dhcp_start": cfg.get("DHCP_RANGE_START", ""),
        "dhcp_stop": cfg.get("DHCP_RANGE_STOP", ""),
        "dns_1": cfg.get("DHCP_DNS_1", ""),
        "dns_2": cfg.get("DHCP_DNS_2", ""),
        "in_interface": cfg.get("IN_INTERFACE", ""),
        "out_interface": cfg.get("OUT_INTERFACE", ""),
        "internal_ip": cfg.get("IN_INT_IP", ""),
    }

    _print(200, payload)


def handle_post() -> None:
    body = _parse_body()
    action = body.get("action", "")

    if action != "save_wifi":
        _print(400, {"status": "error", "message": "Nieznana akcja."})
        return

    ssid = str(body.get("ssid", "")).strip()
    password = str(body.get("password", "")).strip()

    ok, msg = _validate_wifi(ssid, password)
    if not ok:
        _print(400, {"status": "error", "message": msg})
        return

    cfg = _read_cfg(CFG)
    cfg["AP_SSID"] = ssid
    cfg["AP_PASS"] = password

    content = _build_cfg_text(cfg)

    # zapis configu jako root przez sudo tee (nie wymaga 775 na katalogu)
    _sudo_tee_write(CFG, content)
    _sync_to_scripts_cfg()

    # runtime forwarding – żeby nie “znikał” w trakcie pracy
    subprocess.run(["sudo", "/sbin/sysctl", "-w", "net.ipv4.ip_forward=1"], check=False)

    # zastosuj hostapd natychmiast
    _apply_hostapd(cfg)

    _print(200, {"status": "success", "message": "Zapisano. Hostapd zrestartowany."})


def main() -> None:
    try:
        method = os.environ.get("REQUEST_METHOD", "GET").upper()
        if method == "POST":
            handle_post()
        else:
            handle_get()
    except Exception as e:
        _print(50_
