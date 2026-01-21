#!/bin/bash

install=true

while getopts "D" flg; do
	case "${flg}" in
		D) install=false
	esac
done

source $(dirname "$0")/../config.inc

if $install; then
	echo "INFO: Installing hostapd"
	apt install -y hostapd

	if [ $? -ne 0 ]; then
		echo "ERROR: Failed to install hostapd"
		exit 1
	fi

	echo "INFO: Configuring hostapd"
	cat > /etc/hostapd/hostapd.conf <<- EOF
		interface=wlan0
		hw_mode=a
		channel=36
		ieee80211ac=1
		country_code=PL
		ssid=${AP_SSID}
		auth_algs=1
		wpa=2
		wpa_key_mgmt=WPA-PSK
		rsn_pairwise=CCMP
		wpa_passphrase=${AP_PASS}
		wmm_enabled=1
	EOF
	echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' > /etc/default/hostapd

	systemctl unmask hostapd
	systemctl enable hostapd
	systemctl disable wpa_supplicant
	echo "INFO: Access Point setup complete."
else
	systemctl stop hostapd
	systemctl disable hostapd
	systemctl enable wpa_supplicant
	rm -f /etc/hostapd/hostapd.conf
	apt purge -y --auto-remove hostapd
fi
