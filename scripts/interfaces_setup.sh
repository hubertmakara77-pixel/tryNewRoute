#!/bin/bash
install=true

while getopts "D" flg; do
	case "${flg}" in
		D) install=false
	esac
done

source $(dirname "$0")/../config.inc

IN_INT_CONF="/etc/systemd/network/10-wlan0.network"
OUT_INT_CONF="/etc/systemd/network/10-end0.network"

if $install; then
	echo "INFO: Configuring ${IN_INTERFACE} interface (Static IP)"
	cat > ${IN_INT_CONF} <<- EOF
		[Match]
		Name=${IN_INTERFACE}
		
		[Network]
		Address=${IN_INT_IP}/24
		DNS=${DHCP_DNS_1}
	EOF
    
	echo "INFO: Configuring ${OUT_INTERFACE} interface (DHCP)"
	cat > ${OUT_INT_CONF} <<- EOF
		[Match]
		Name=${OUT_INTERFACE}

		[Network]
		DHCP=yes
	EOF

	chmod 644 ${IN_INT_CONF} ${OUT_INT_CONF}
	
	systemctl enable systemd-networkd
	if [ $? -ne 0 ]; then
		echo "ERROR: Failed to restart network service"
		exit 1
	fi
	
	# Remove all netplans as armbian is configured to takes that configs in first place
	# (Easier than reconfiguring :D)
	rm -f /etc/netplan/*
	echo "INFO: Network configured successfully."
else
	rm -f ${IN_INT_CONF} ${OUT_INT_CONF}
	systemctl restart systemd-networkd
fi
