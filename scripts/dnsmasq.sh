#!/bin/bash

install=true

while getopts "D" flg; do
	case "${flg}" in
		D) install=false ;;
	esac
done

source $(dirname "$0")/../config.inc

STATIC_IP="${IN_INT_IP}/24"
GATEWAY="${IN_INT_IP}"
DHCP_START="${DHCP_RANGE_START}"
DHCP_END="${DHCP_RANGE_STOP}"
DHCP_LEASE_TIME="24h"
DNS_SERVERS="${DHCP_DNS_1},${DHCP_DNS_2}"

DNSMASQ_CONF="/etc/dnsmasq.d/lan.conf"

if $install; then
	echo "INFO: Installing dnsmasq"
	apt install -y dnsmasq
	if [ $? -ne 0 ]; then
		echo "ERROR: Failed to install dnsmasq"
		exit 1
	fi

	echo "INFO: Creating dnsmasq configuration in ${DNSMASQ_CONF}"
	systemctl stop dnsmasq
	cat <<- EOF | tee "${DNSMASQ_CONF}" >/dev/null
		interface=${IN_INTERFACE}
		bind-interfaces
		dhcp-range=${DHCP_START},${DHCP_END},${DHCP_LEASE_TIME}
		dhcp-option=3,${GATEWAY}
		dhcp-option=6,${DNS_SERVERS}
	EOF

	systemctl enable dnsmasq
	echo "INFO: dnsmasq configuration completed"
else
	echo "INFO: Uninstall"
	if [ -f "${DNSMASQ_CONF}" ]; then
		rm -f "${DNSMASQ_CONF}"
	fi
	apt remove --purge -y dnsmasq || true
	apt autoremove -y || true
	echo "INFO: dnsmasq uninstalled"
fi
