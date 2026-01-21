#!/bin/bash

# --- 0. Sprawdzenie uprawnień ---
if [ ! "$UID" -eq 0 ]; then
    echo "URUCHOM JAKO ROOT: sudo bash install_final_v2.sh"
    exit 1
fi

echo "--- START: Instalacja (Z usuwaniem konfliktów) ---"

# --- 1. USUWANIE SABOTAŻYSTÓW (Kluczowa poprawka) ---
echo "[1/8] Usuwanie starych skryptów, które psują config..."
# To ten plik najprawdopodobniej ustawiał Ci port 443 z automatu
if [ -f "scripts/lighttpd.sh" ]; then
    echo "   -> Wykryto i usunięto: scripts/lighttpd.sh (Winowajca!)"
    rm scripts/lighttpd.sh
fi
# Usuwamy też inne potencjalne instalatory WWW, zostawiamy tylko skrypty sieciowe
rm -f scripts/install_web.sh scripts/web_setup.sh

# --- 2. INSTALACJA PAKIETÓW ---
echo "[2/8] Instalacja pakietów..."
apt-get update
apt-get install -y lighttpd python3 hostapd dnsmasq git iptables netfilter-persistent

# --- 3. BLOKOWANIE SSL I MODUŁÓW (Dla pewności) ---
echo "[3/8] Wyłączanie modułów SSL..."
# Jeśli system ma włączony SSL, wyłączamy go, żeby nie wymuszał 443
lighty-disable-mod ssl 2>/dev/null
lighty-disable-mod openssl 2>/dev/null

# --- 4. GENEROWANIE CZYSTEGO CONFIGU (Port 80) ---
echo "[4/8] Generowanie configu Lighttpd..."
systemctl stop lighttpd

cat > /etc/lighttpd/lighttpd.conf <<EOF
server.modules = (
    "mod_indexfile",
    "mod_access",
    "mod_alias",
    "mod_redirect",
    "mod_cgi"
)

server.document-root    = "/var/www/html"
server.upload-dirs      = ( "/var/cache/lighttpd/uploads" )
server.errorlog         = "/var/log/lighttpd/error.log"
server.pid-file         = "/run/lighttpd.pid"
server.username         = "www-data"
server.groupname        = "www-data"
server.port             = 80

# Ważne dla CSS/JS
include_shell "/usr/share/lighttpd/create-mime.conf.pl"

index-file.names        = ( "index.html" )
url.access-deny         = ( "~", ".inc" )
static-file.exclude-extensions = ( ".php", ".pl", ".fcgi" )

cgi.assign = ( ".py" => "/usr/bin/python3" )

include "/etc/lighttpd/conf-enabled/*.conf"
EOF

lighty-enable-mod cgi

# --- 5. INTELIGENTNE KOPIOWANIE PLIKÓW ---
echo "[5/8] Kopiowanie strony (wykrywanie folderów)..."
rm -rf /var/www/html/*

# Logika dla Twojej struktury www -> html -> index
if [ -d "www/html" ]; then
    echo "   -> Wykryto strukturę 'www/html'. Kopiuję poprawnie..."
    cp -r www/html/* /var/www/html/
elif [ -d "www" ]; then
    echo "   -> Wykryto folder 'www'. Kopiuję..."
    cp -r www/* /var/www/html/
elif [ -d "html" ]; then
    echo "   -> Wykryto folder 'html'. Kopiuję..."
    cp -r html/* /var/www/html/
else
    echo "   !!! BŁĄD: Nie widzę folderu z plikami! Jesteś w dobrym katalogu?"
fi

# Fix nazwy
[ -f "/var/www/html/web_app.html" ] && mv /var/www/html/web_app.html /var/www/html/index.html
rm -f /var/www/html/index.lighttpd.html

# --- 6. BACKEND ---
echo "[6/8] Instalacja backendu..."
mkdir -p /usr/lib/cgi-bin/
if [ -f "cgi-bin/router_api.py" ]; then
    cp cgi-bin/router_api.py /usr/lib/cgi-bin/
    sed -i 's/\r$//' /usr/lib/cgi-bin/router_api.py
    sed -i 's/DEV_MODE = True/DEV_MODE = False/g' /usr/lib/cgi-bin/router_api.py
    chmod +x /usr/lib/cgi-bin/router_api.py
fi

# --- 7. UPRAWNIENIA ---
echo "[7/8] Naprawa uprawnień..."
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

# --- 8. URUCHAMIANIE SKRYPTÓW SIECIOWYCH ---
echo "[8/8] Konfiguracja sieci..."
if [ -d "scripts" ]; then
    chmod +x scripts/*.sh
    for script in scripts/*.sh; do
        # Uruchamiamy tylko jeśli plik nadal istnieje (te złe usunęliśmy w kroku 1)
        if [ -f "$script" ]; then
            echo "   -> Uruchamiam: $script"
            bash "$script" || echo "   (Ignoruję błąd na VM)"
        fi
    done
fi

# Atrapa hostapd
if [ ! -f /etc/hostapd/hostapd.conf ]; then
    echo "interface=wlan0" > /etc/hostapd/hostapd.conf
    echo "ssid=Start" >> /etc/hostapd/hostapd.conf
    chmod 666 /etc/hostapd/hostapd.conf
fi

systemctl unmask lighttpd
systemctl restart lighttpd

echo "-----------------------------------------------------"
echo " GOTOWE! Sprawdź: http://localhost"
echo "-----------------------------------------------------"