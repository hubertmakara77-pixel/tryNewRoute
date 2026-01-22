#!/bin/bash
set -e

install=true

while getopts "D" flg; do
  case "${flg}" in
    D) install=false ;;
  esac
done

# Docelowe źródło konfiguracji po instalacji
source /etc/orangepi-router/config.inc

if $install; then
  echo "INFO: Installing iptables"
  echo "iptables-persistent iptables-persistent/autosave_v4 boolean false" | debconf-set-selections
  echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | debconf-set-selections
  apt install -y iptables iptables-persistent
  if [ $? -ne 0 ]; then
    echo "ERROR: failed to install iptables"
    exit 1
  fi

  # Set default policy
  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT ACCEPT

  iptables -A INPUT -i lo -j ACCEPT

  # (Polecane) pozwól na ruch już zestawiony (stabilizuje SSH/WWW)
  iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  # enable DHCP(client & server) on WAN interface
  iptables -A INPUT -i ${OUT_INTERFACE} -p udp -m udp --sport 67:68 --dport 67:68 -j ACCEPT

  # enable DNS responses
  iptables -A INPUT -i ${OUT_INTERFACE} -p udp -m udp --sport 53 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  # enable NTP responses
  iptables -A INPUT -i ${OUT_INTERFACE} -p udp --sport 123 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  # enable SSH connections from private network
  iptables -A INPUT -i ${IN_INTERFACE} -p tcp -m tcp --dport 22 -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j ACCEPT

  # enable all connections from private network (for ease of devel now)
  iptables -A INPUT -i ${IN_INTERFACE} -j ACCEPT

  # pseudo bridge (Twoje reguły FORWARD)
  iptables -A FORWARD -i ${IN_INTERFACE} -o ${OUT_INTERFACE} -j ACCEPT
  iptables -A FORWARD -i ${OUT_INTERFACE} -o ${IN_INTERFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

  # ============================================================
  # Naprawa internetu (Twoje linie) – pewny NAT i forwarding
  # ============================================================

  # NAT + FORWARD reset (żeby MASQUERADE był zawsze i nie dublował się)
  sysctl -w net.ipv4.ip_forward=1

  iptables -t nat -F
  iptables -F FORWARD

  iptables -t nat -A POSTROUTING -o "$OUT_INTERFACE" -j MASQUERADE

  iptables -A FORWARD -i "$IN_INTERFACE" -o "$OUT_INTERFACE" -j ACCEPT
  iptables -A FORWARD -i "$OUT_INTERFACE" -o "$IN_INTERFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT

  # ============================================================
  # /Naprawa internetu
  # ============================================================

  iptables-save > /etc/iptables/rules.v4

  cat > /etc/sysctl.d/ip_forward.conf <<- EOF
net.ipv4.ip_forward=1
EOF

  echo "INFO: iptables configured and saved"
else
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
