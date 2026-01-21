#!/bin/bash

# --- 0. Root Check ---
if [ ! "$UID" -eq 0 ]; then
    echo "URUCHOM JAKO ROOT: sudo bash install_fix.sh"
    exit 1
fi

echo "--- START: Instalacja z naprawą pliku lighttpd.sh ---"

# --- 1. CHIRURGIA: NAPRAWIAMY PLIK 'scripts/lighttpd.sh' ---
echo "[1/7] Modyfikacja skryptu lighttpd.sh (usuwamy szkodliwy fragment)..."

# Nadpisujemy ten plik wersją BEZPIECZNĄ.
# Zostawiamy generowanie certyfikatów, ale wywalamy konfigurację serwera.
cat > scripts/lighttpd.sh <<EOF
#!/bin/bash
echo "INFO: Generowanie certyfikatów SSL (Bezpieczna wersja)..."

# Instalacja narzędzi SSL (jeśli brakuje)
apt-get install -y lighttpd-mod-openssl openssl

# Ścieżki
cert_path=/etc/lighttpd/router.pem
key_path=/etc/lighttpd/router.key
tls_combo=/etc/lighttpd/lighttpd.pem

# Generowanie kluczy (TO JEST DOBRE, TO ZOSTAWIAMY)
mkdir -p /etc/lighttpd
openssl req -new -x509 -newkey rsa:2048 -nodes -days 365 \\
  -keyout \${key_path} \\
  -out \${cert_path} \\
  -subj "/CN=router.local" 2>/dev/null

# Łączenie kluczy
if [ \$? -eq 0 ]; then
    cat \${cert_path} \${key_path} > \${tls_combo}
    rm -f \${cert_path} \${key_path}
    chmod 400 \${tls_combo}
    echo "INFO: Certyfikaty wygenerowane pomyślnie."
else
    echo "ERROR: Błąd generowania certyfikatów."
fi

# KONIEC SKRYPTU - Usunęliśmy część, która nadpisywała lighttpd.conf!
EOF

chmod +x scripts/lighttpd.sh
echo "   -> Plik naprawiony. Teraz jest bezpieczny."

# --- 2. INSTALACJA PAKIETÓW ---
echo "[2/7] Instalacja pakietów..."
apt-get update
apt-get install -y lighttpd python3 hostapd dnsmasq git iptables netfilter-persistent lighttpd-mod-openssl

# --- 3. KONFIGURACJA LIGHTTPD (Nasza, poprawna) ---
echo "[3/7] Konfiguracja serwera WWW..."
systemctl stop lighttpd

cat > /etc/lighttpd/lighttpd.conf <<EOF
server.modules = (
    "mod_indexfile",
    "mod_access",
    "mod_alias",
    "mod_redirect",
    "mod_cgi",
    "mod_openssl"
)

server.document-root    = "/var/www/html"
server.upload-dirs      = ( "/var/cache/lighttpd/uploads" )
server.errorlog         = "/var/log/lighttpd/error.log"
server.pid-file         = "/run/lighttpd.pid"
server.username         = "www-data"
server.groupname        = "www-data"
server.port             = 80

# Ładujemy certyfikaty (ale na razie nie wymuszamy HTTPS, żeby działało łatwo)
# \$SERVER["socket"] == ":443" {
#     ssl.engine = "enable"
#     ssl.pemfile = "/etc/lighttpd/lighttpd.pem"
# }

include_shell "/usr/share/lighttpd/create-mime.conf.pl"
index-file.names        = ( "index.html" )
cgi.assign              = ( ".py" => "/usr/bin/python3" )
include "/etc/lighttpd/conf-enabled/*.conf"
EOF

lighty-enable-mod cgi

# --- 4. KOPIOWANIE PLIKÓW STRONY ---
echo "[4/7] Wgrywanie strony..."
rm -rf /var/www/html/*
if [ -d "www/html" ]; then cp -r www/html/* /var/www/html/;
elif [ -d "www" ]; then cp -r www/* /var/www/html/;
elif [ -d "html" ]; then cp -r html/* /var/www/html/; fi

[ -f "/var/www/html/web_app.html" ] && mv /var/www/html/web_app.html /var/www/html/index.html
rm -f /var/www/html/index.lighttpd.html

# --- 5. BACKEND PYTHON ---
echo "[5/7] Backend Python..."
mkdir -p /usr/lib/cgi-bin/
[ -f "cgi-bin/router_api.py" ] && cp cgi-bin/router_api.py /usr/lib/cgi-bin/
sed -i 's/\r$//' /usr/lib/cgi-bin/router_api.py 2>/dev/null
sed -i 's/DEV_MODE = True/DEV_MODE = False/g' /usr/lib/cgi-bin/router_api.py 2>/dev/null
chmod +x /usr/lib/cgi-bin/router_api.py

# --- 6. UPRAWNIENIA ---
echo "[6/7] Uprawnienia..."
cat > /etc/sudoers.d/router-web-ui << EOF
www-data ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart hostapd
www-data ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart dnsmasq
www-data ALL=(ALL) NOPASSWD: /usr/bin/ip
www-data ALL=(ALL) NOPASSWD: /usr/bin/tee
www-data ALL=(ALL) NOPASSWD: /usr/bin/rm
EOF
chmod 0440 /etc/sudoers.d/router-web-ui
chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html
mkdir -p /etc/hostapd
chmod 777 /etc/hostapd

# --- 7. URUCHAMIANIE SKRYPTÓW (Teraz bezpieczne!) ---
echo "[7/7] Uruchamianie skryptów z folderu scripts/..."
# Teraz możemy bezpiecznie uruchomić WSZYSTKIE skrypty,
# bo lighttpd.sh został "rozbrojony" w kroku 1.
if [ -d "scripts" ]; then
    chmod +x scripts/*.sh
    for script in scripts/*.sh; do
        if [ -f "$script" ]; then
            echo "   -> Uruchamiam: $script"
            bash "$script" || echo "   (Ignoruję błąd)"
        fi
    done
fi

# Fix dla hostapd na VM
if [ ! -f /etc/hostapd/hostapd.conf ]; then
    echo "interface=wlan0" > /etc/hostapd/hostapd.conf
    chmod 666 /etc/hostapd/hostapd.conf
fi

systemctl unmask lighttpd
systemctl restart lighttpd

echo "-----------------------------------------------------"
echo " GOTOWE! Certyfikaty wygenerowane, config poprawny."
echo " Wejdź na: http://localhost"
echo "-----------------------------------------------------"
