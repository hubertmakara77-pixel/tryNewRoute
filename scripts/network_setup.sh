#!/bin/bash
install=true

while getopts "D" flg; do
	case "${flg}" in
		D) install=false
	esac
done
NET_CONF="/etc/systemd/network/10-wlan0.network"

if $install; then
	# Path to the configuration file
	
	
	echo "INFO: Configuring wlan0 interface (Static IP)..."
	
	# 1. Write the configuration to the file using Here-Doc
	cat > ${NET_CONF} <<- EOF
		[Match]
		Name=wlan0
		
		[Network]
		Address=192.168.0.1/24
		Gateway=0.0.0.0
		DNS=8.8.8.8
	EOF
    
	# Check for errors during file creation
	If [ $? -ne 0 ]; then
		echo "ERROR: Failed to create network configuration file"
		exit 1
	Fi
	
	# 2. Set file permissions (read/write for root, read-only for others)
	Chmod 644 ${NET_CONF}
	
	Echo "INFO: Enabling and restarting systemd-networkd service..."
	
	# Enable the service to start at boot
	Systemctl enable systemd-networkd
	
	# Restart the service to apply changes immediately
	Systemctl restart systemd-networkd
	
	# Check if the service restarted successfully
	If [ $? -ne 0 ]; then
		echo "ERROR: Failed to restart network service"
		exit 1
	Fi
	
	
	Echo "INFO: Network configured successfully."
else
	rm -f ${NET_CONF}
	systemctl restart systemd-networkd
fi
