#!/bin/bash
set -e

install=true

while getopts "D" flg; do
  case "${flg}" in
    D) install=false ;;
  esac
done

# ZAWSZE bierzemy konfigurację z jednego miejsca po instalacji
CFG="/etc/orangepi-router/config.inc"
if [ -f "$CFG" ]; then
  source "$CFG"
else
  # fallback dla uruchamiania z repo (opcjonalnie)
  source "$(dirname "$0")/../config.inc"
fi

if $install; then
  echo "INFO: Installing iptables"
  echo "iptables-persistent iptables-persistent/autosave_v4 boolean false" | debconf-set-selections
  echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | debconf-set-selections
  apt install -y iptables iptables-persistent

  # 1) NAT + filter reset (żeby nie dublować reguł)
  iptables -F
  iptables -t nat -F
  iptables -X || true

  # 2) Bezpieczne domyślne polityki (ale nie zabijamy istniejących sesji)
  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT ACCEPT

  # 3) Loopback + established/related (to ratuje SSH i wiele innych rzeczy)
  iptables -A INPUT -i lo -j ACCEPT
  iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  # 4) Dostęp do panelu WWW z LAN (jeśli panel jest na routerze)
  # Jeśli nie chcesz — usuń.
  iptables -A INPUT -i "${IN_INTERFACE}" -p tcp --dport 80 -j ACCEPT

  # 5) SSH z LAN (zostawione)
  iptables -A INPUT -i "${IN_INTERFACE}" -p tcp --dport 22 -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT

  # 6) (Opcjonalnie) zezwól na resztę z LAN w fazie dev
  iptables -A INPUT -i "${IN_INTERFACE}" -j ACCEPT

  # 7) Forward LAN -> WAN i powroty
  iptables -A FORWARD -i "${IN_INTERFACE}" -o "${OUT_INTERFACE}" -j ACCEPT
  iptables -A FORWARD -i "${OUT_INTERFACE}" -o "${IN_INTERFACE}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  # 8) NAT (najważniejsze)
  iptables -t nat -A POSTROUTING -o "${OUT_INTERFACE}" -j MASQUERADE

  # 9) ip_forward – natychmiast + na stałe
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  cat > /etc/sysctl.d/ip_forward.conf <<-EOF
net.ipv4.ip_forward=1
EOF
  sysctl --system >/dev/null || true

  # 10) Zapis reguł
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4

  echo "INFO: iptables configured and saved"
else
  echo "INFO: Uninstalling iptables"
  # Czyścimy
  iptables -F || true
  iptables -t nat -F || true
  iptables -P INPUT ACCEPT || true
  iptables -P FORWARD ACCEPT || true
  iptables -P OUTPUT ACCEPT || true

  rm -f /etc/sysctl.d/ip_forward.conf
  rm -f /etc/iptables/rules.v4

  apt purge -y --auto-remove iptables iptables-persistent
  echo "INFO: iptables uninstalled"
fi
