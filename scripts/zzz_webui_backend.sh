#!/bin/bash
set -e

# Ten skrypt ma być odpalany na końcu (dlatego "zzz_"),
# bo Twój lighttpd.sh nadpisuje /etc/lighttpd/lighttpd.conf od zera.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "INFO: Installing CGI dependencies (python3 + lighttpd CGI module)"
apt install -y python3 lighttpd-mod-cgi

echo "INFO: Deploying web files"
install -d -m 0755 /var/www/html
install -d -m 0755 /var/www/cgi-bin

cp -f "${PROJECT_ROOT}/www/html/index.html" /var/www/html/index.html
cp -f "${PROJECT_ROOT}/cgi-bin/router_api.py" /var/www/cgi-bin/router_api.py
chmod 0755 /var/www/cgi-bin/router_api.py
chown root:root /var/www/cgi-bin/router_api.py

echo "INFO: Deploying router config to /etc/router/config.inc (source: repo config.inc)"
install -d -m 0755 /etc/router
cp -f "${PROJECT_ROOT}/config.inc" /etc/router/config.inc
chmod 0644 /etc/router/config.inc

echo "INFO: Creating root helper /usr/local/sbin/router_apply_wifi.sh"
cat > /usr/local/sbin/router_apply_wifi.sh << 'SH'
#!/bin/bash
set -e

CFG="/etc/router/config.inc"

# load AP_SSID/AP_PASS
# shellcheck disable=SC1090
source "$CFG"

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

systemctl restart hostapd
SH

chmod 0755 /usr/local/sbin/router_apply_wifi.sh
chown root:root /usr/local/sbin/router_apply_wifi.sh

echo "INFO: Allowing www-data to run only the WiFi apply helper via sudoers.d"
cat > /etc/sudoers.d/router-web << 'SUDO'
www-data ALL=(root) NOPASSWD: /usr/local/sbin/router_apply_wifi.sh
SUDO
chmod 0440 /etc/sudoers.d/router-web

echo "INFO: Patching lighttpd.conf to enable CGI and serve index.html"
CONF="/etc/lighttpd/lighttpd.conf"

# lighttpd.sh ustawia index.lighttpd.html; podmieniamy na index.html
sed -i 's/server.indexfiles = ( "index\.lighttpd\.html" )/server.indexfiles = ( "index.html" )/g' "$CONF"

# dopnij moduły CGI/alias, jeśli ich nie ma
if ! grep -q 'mod_cgi' "$CONF"; then
cat >> "$CONF" << 'LTCGI'

# --- Added by zzz_webui_backend.sh ---
server.modules += ( "mod_alias", "mod_cgi" )

alias.url += ( "/cgi-bin/" => "/var/www/cgi-bin/" )

$HTTP["url"] =~ "^/cgi-bin/" {
    cgi.assign = ( ".py" => "/usr/bin/python3" )
}
# --- End ---
LTCGI
fi

systemctl restart lighttpd

echo "INFO: WebUI ready: https://router.local/  (API: /cgi-bin/router_api.py)"
