#!/bin/bash

install=true

while getopts "D" flg; do
	case "${flg}" in
		D) install=false
	esac
done

if $install; then
	echo "INFO: Updating repositories and installing packages (hostapd, dnsmasq, iptables)..."
	apt install -y hostapd

	if [ $? -ne 0 ]; then
		echo "ERROR: Failed to install packages"
		exit 1
	fi

	echo "INFO: Configuring hostapd (/etc/hostapd/hostapd.conf)..."
	cat > /etc/hostapd/hostapd.conf <<- EOF
		interface=wlan0
		hw_mode=g
		channel=6

		ieee80211d=1
		country_code=PL

		ssid=dsadasd
		auth_algs=1

		wpa=2
		wpa_key_mgmt=WPA-PSK
		rsn_pairwise=CCMP
		wpa_passphrase=cycki123

		ieee80211n=1
		wmm_enabled=1
		ht_capab=[HT20]
		beacon_int=100
		dtim_period=2
		# reduce TX queue bursts (prevents firmware freeze)
		tx_queue_data2_burst=2
	EOF

	echo "INFO: Updating /etc/default/hostapd..."
	# Point daemon to the config file
	echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' > /etc/default/hostapd

	echo "INFO: Creating Unisoc WiFi fix script (/usr/local/bin/unisoc-wifi-fix.sh)..."
	# We use 'EOF' (with quotes) to prevent variable expansion ($IFACE) during creation
	cat > /usr/local/bin/unisoc-wifi-fix.sh <<- EOF
		#!/bin/bash
		IFACE="wlan0"

		for i in {1..10}; do
		    if ip link show $IFACE > /dev/null 2>&1; then
		        break
		    fi
		    sleep 1
		done

		# Disable WiFi power-save
		iw dev $IFACE set power_save off 2>/dev/null

		# Reduce TX queue length to avoid firmware TX lockups
		ip link set $IFACE txqueuelen 100 2>/dev/null

		ethtool -K $IFACE gro off 2>/dev/null
		ethtool -K $IFACE lro off 2>/dev/null

		# Bring interface up (some versions come up DOWN)
		ip link set $IFACE up 2>/dev/null

		exit 0
	EOF

	# Make the script executable
	chmod +x /usr/local/bin/unisoc-wifi-fix.sh

	echo "INFO: Creating systemd service for WiFi fix..."
	cat > /etc/systemd/system/unisoc-wifi-fix.service <<- EOF
		[Unit]
		Description=Apply Unisoc WiFi stability fixes (power-save off, txqueuelen fix, GRO/LRO off)
		After=network-pre.target
		Before=hostapd.service
		Wants=hostapd.service

		[Service]
		Type=oneshot
		ExecStart=/usr/local/bin/unisoc-wifi-fix.sh
		RemainAfterExit=yes

		[Install]
		WantedBy=multi-user.target
	EOF

	echo "INFO: Reloading systemd and enabling fix service..."
	systemctl daemon-reload
	systemctl enable --now unisoc-wifi-fix.service

	echo "INFO: Stopping conflicting network services (Must be done via UART/Console)..."
	# Stopping networkd and wpa_supplicant as requested to free up the interface
	systemctl stop systemd-networkd
	systemctl stop systemd-networkd.socket
	systemctl stop wpa_supplicant

	# Killing any remaining wpa_supplicant processes
	# pkill is safer and easier than 'ps aux | grep ...' in a script
	pkill -9 wpa_supplicant

	echo "INFO: Enabling and restarting hostapd..."
	# Unmask in case it was masked by default
	systemctl unmask hostapd
	systemctl enable hostapd
	systemctl restart hostapd


	echo "INFO: Access Point setup complete."
else
	systemctl stop hostapd
	systemctl disable hostapd
	apt purge -y --auto-remove hostapd
	rm -f /etc/systemd/system/unisoc-wifi-fix.service
	rm -f /usr/local/bin/unisoc-wifi-fix.sh
fi
