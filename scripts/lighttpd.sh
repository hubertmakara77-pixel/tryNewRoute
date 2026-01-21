#!/bin/bash

install=true

while getopts "D" flg; do
	case "${flg}" in
		D) install=false
	esac
done

if $install; then
	echo "INFO: Installing lighttpd server"
	apt install -y lighttpd lighttpd-mod-openssl
	if [ $? -ne 0 ]; then
		echo "ERROR: failed to install lighttpd server"
		exit 1
	fi

	echo "INFO: Generating TLS certs"
	cert_path=/etc/lighttpd/router.pem
	key_path=/etc/lighttpd/router.key
	tls_combo=/etc/lighttpd/lighttpd.pem

	openssl req -new -x509 -newkey rsa:2048 -nodes -days 365 \
	  -keyout ${key_path} \
	  -out ${cert_path} \
	  -subj "/CN=router.local"
	if [ $? -ne 0 ]; then
		echo "ERROR: failed to generate TLS certs"
		exit 1
	fi
	cat ${cert_path} ${key_path} > ${tls_combo}
	rm -f ${cert_path} ${key_path}
	chmod 400 ${tls_combo}

	echo "INFO: Configuring lighttpd server"
	cat > /etc/lighttpd/lighttpd.conf <<- EOF
	server.document-root = "/var/www/html"
	server.indexfiles = ( "index.lighttpd.html" )
	server.port = 443
	
	server.modules = ( "mod_openssl" )
	
	\$SERVER["socket"] == ":443" {
	    ssl.engine = "enable"
	    ssl.pemfile = "${tls_combo}"
	}
	EOF

	lighty-enable-mod ssl
	if [ $? -ne 0 ]; then
		echo "ERROR: failed to load ssl module"
		exit 1
	fi
	rm -rf /etc/lighttpd/conf-enabled/*

	systemctl enable lighttpd
	if [ $? -ne 0 ]; then
		echo "ERROR: failed to enable lighttpd service"
		exit 1
	fi

	echo "INFO: lighttpd installation successful"
else
	systemctl stop lighttpd
	rm -rf /etc/lighttpd/*
	rm -rf /var/www/html/*
	apt purge -y --auto-remove lighttpd lighttpd-mod-openssl
	echo "INFO: lighttpd uninstalled"
fi
