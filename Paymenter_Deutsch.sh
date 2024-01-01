#__________           _________              __  .__                      .__                   ________  ________ 
#\______   \___.__.  /   _____/____    _____/  |_|__|____     ____   ____ |  | ___  ______  ___/  _____/ /  _____/ 
# |    |  _<   |  |  \_____  \__  \  /    \   __\  \__  \   / ___\ /  _ \|  | \  \/  /\  \/  /   \  ___/   \  ___ 
# |    |   \\___  |  /        \/ __ \|   |  \  | |  |/ __ \_/ /_/  >  <_> )  |__>    <  >    <\    \_\  \    \_\  \
# |______  // ____| /_______  (____  /___|  /__| |__(____  /\___  / \____/|____/__/\_ \/__/\_ \\______  /\______  /
#        \/ \/              \/     \/     \/             \//_____/                   \/      \/       \/        \/ 

#!/bin/bash

# Interaktive Benutzerabfragen
read -p "Geben Sie die Domain ein, die Sie für Paymenter verwenden möchten (z.B. paymenter.com): " domain
read -p "Möchten Sie SSL automatisch konfigurieren? (j/n): " configure_ssl
read -p "Möchten Sie ein SSL-Zertifikat mit Certbot verwenden? (Wenn Sie kein Zertifikat haben.) (j/n): " use_certbot

# Domänenvalidierung
if [ -z "$domain" ]; then
    echo "Die Domain darf nicht leer sein."
    exit 1
fi

# OpenSSL-Überprüfung
if ! command -v openssl &> /dev/null; then
    echo "OpenSSL ist nicht installiert. Bitte installieren Sie es, bevor Sie fortfahren."
    exit 1
fi

# Abhängigkeiten
apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg

LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php

apt update

apt -y install php8.2 php8.2-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} mariadb-server nginx tar unzip git redis-server

# Composer-Installation
if ! command -v composer &> /dev/null; then
    echo "Installiere Composer..."
    curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/local/bin --filename=composer
fi

# Nginx-Installation
if ! command -v nginx &> /dev/null; then
    echo "Installiere Nginx..."
    apt -y install nginx
fi

# Überprüfen Sie das Vorhandensein des Verzeichnisses /var/www/paymenter
if [ -d "/var/www/paymenter" ]; then
    read -p "Das Verzeichnis /var/www/paymenter existiert bereits. Möchten Sie es löschen und fortfahren? (j/n): " delete_existing
    if [ "$delete_existing" = "j" ]; then
        rm -rf /var/www/paymenter
        echo "Vorhandenes Verzeichnis gelöscht."
    else
        echo "Vorgang abgebrochen. Es wurden keine Änderungen vorgenommen."
        exit 1
    fi
fi

# SSL-Konfiguration
if [ "$configure_ssl" = "j" ]; then
    # Certbot-Installation
    apt -y install certbot python3-certbot-nginx

    # SSL-Zertifikat mit Certbot anfordern
    if [ "$use_certbot" = "j" ]; then
        certbot --nginx -d $domain
    fi
fi

# Verzeichnis für Paymenter erstellen
mkdir /var/www/paymenter
cd /var/www/paymenter

# Paymenter herunterladen
curl -Lo paymenter.tar.gz https://github.com/paymenter/paymenter/releases/latest/download/paymenter.tar.gz
tar -xzvf paymenter.tar.gz
chmod -R 755 storage/* bootstrap/cache/

# Benutzer und Datenbank in MySQL erstellen
read -p "Möchten Sie einen externen Host? (j/n): " external_host
if [ "$external_host" = "j" ]; then
    read -p "Geben Sie den externen Host ein, den Sie verwenden möchten. Wenn Sie nichts eingeben, wird er automatisch auf 127.0.0.1 festgelegt: " ext_host
    ext_host=${ext_host:-127.0.0.1}
    read -p "Geben Sie den Datenbanknamen ein (Drücken Sie die Eingabetaste, um 'paymenter' zu verwenden): " db_name
    db_name=${db_name:-paymenter}
    read -p "Geben Sie den Datenbankbenutzernamen ein (Drücken Sie die Eingabetaste, um 'paymenter' zu verwenden): " db_user
    db_user=${db_user:-paymenter}
    read -p "Geben Sie das Datenbankpasswort ein (Drücken Sie die Eingabetaste, um ein zufälliges Passwort zu generieren): " db_password
    db_password=${db_password:-$(openssl rand -hex 16)}
else
    # Der Rest des Codes für die Datenbank im Fall eines lokalen Hosts
fi

# Benutzer und Datenbank in MySQL erstellen
mysql -e "CREATE DATABASE IF NOT EXISTS $db_name;"
mysql -e "CREATE USER IF NOT EXISTS '$db_user'@'localhost' IDENTIFIED BY '$db_password';"
mysql -e "GRANT ALL PRIVILEGES ON $db_name.* TO '$db_user'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# .env-Datei konfigurieren
cp .env.example .env
# Composer-Abhängigkeiten
composer install --no-dev --optimize-autoloader

# .env-Datei bearbeiten
sed -i "/^DB_HOST=/s/.*/DB_HOST=$ext_host/" .env
sed -i "/^DB_DATABASE=/s/.*/DB_DATABASE=$db_name/" .env
sed -i "/^DB_USERNAME=/s/.*/DB_USERNAME=$db_user/" .env
sed -i "/^DB_PASSWORD=/s/.*/DB_PASSWORD=$db_password/" .env

# Anwendungsschlüssel generieren
php artisan key:generate --force

# Migrationen und Seeder ausführen
php artisan migrate --force --seed

# Symbolischen Link für die Speicherung erstellen
php artisan storage:link

# Passwort erstellen
php artisan p:user:create

# Nginx konfigurieren
nginx_conf="/etc/nginx/sites-available/paymenter.conf"
echo "server {" > $nginx_conf
echo "    listen 80;" >> $nginx_conf
echo "    listen [::]:80;" >> $nginx_conf
echo "    server_name $domain;" >> $nginx_conf

if [ "$configure_ssl" = "j" ]; then
    echo "    return 301 https://\$host\$request_uri;" >> $nginx_conf
    echo "}" >> $nginx_conf
    echo "" >> $nginx_conf
    echo "server {" >> $nginx_conf
    echo "    listen 443 ssl http2;" >> $nginx_conf
    echo "    listen [::]:443 ssl http2;" >> $nginx_conf
    echo "    server_name $domain;" >> $nginx_conf
    echo "    root /var/www/paymenter/public;" >> $nginx_conf
    echo "" >> $nginx_conf
    echo "    index index.php;" >> $nginx_conf
    echo "" >> $nginx_conf
    echo "    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;" >> $nginx_conf
    echo "    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;" >> $nginx_conf
    echo "" >> $nginx_conf
    echo "    location / {" >> $nginx_conf
    echo "        try_files \$uri \$uri/ /index.php?\$query_string;" >> $nginx_conf
    echo "    }" >> $nginx_conf
    echo "" >> $nginx_conf
    echo "    location ~ \.php\$ {" >> $nginx_conf
    echo "        include snippets/fastcgi-php.conf;" >> $nginx_conf
    echo "        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;" >> $nginx_conf
    echo "    }" >> $nginx_conf
else
    echo "    root /var/www/paymenter/public;" >> $nginx_conf
    echo "    index index.php;" >> $nginx_conf
    echo "" >> $nginx_conf
    echo "    location / {" >> $nginx_conf
    echo "        try_files \$uri \$uri/ /index.php?\$query_string;" >> $nginx_conf
    echo "    }" >> $nginx_conf
    echo "" >> $nginx_conf
    echo "    location ~ \.php\$ {" >> $nginx_conf
    echo "        include snippets/fastcgi-php.conf;" >> $nginx_conf
    echo "        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;" >> $nginx_conf
    echo "    }" >> $nginx_conf
fi

echo "}" >> $nginx_conf

# Symbolischen Link erstellen und Nginx neu starten
ln -s $nginx_conf /etc/nginx/sites-enabled/
chown -R www-data:www-data /var/www/paymenter/*
systemctl restart nginx

# Cronjob für Laravel Scheduler hinzufügen
(crontab -l ; echo "* * * * * php /var/www/paymenter/artisan schedule:run >> /dev/null 2>&1") | crontab -

# Paymenter-Service konfigurieren
paymenter_service="/etc/systemd/system/paymenter.service"
echo "[Unit]" > $paymenter_service
echo "Description=Paymenter Queue Worker" >> $paymenter_service
echo "" >> $paymenter_service
echo "[Service]" >> $paymenter_service
echo "User=www-data" >> $paymenter_service
echo "Group=www-data" >> $paymenter_service
echo "Restart=always" >> $paymenter_service
echo "ExecStart=/usr/bin/php /var/www/paymenter/artisan queue:work" >> $paymenter_service
echo "StartLimitInterval=180" >> $paymenter_service
echo "StartLimitBurst=30" >> $paymenter_service
echo "RestartSec=5s" >> $paymenter_service
echo "" >> $paymenter_service
echo "[Install]" >> $paymenter_service
echo "WantedBy=multi-user.target" >> $paymenter_service

# Paymenter-Service aktivieren und starten
systemctl enable --now paymenter

# Abschlussnachricht
if [ "$configure_ssl" = "j" ]; then
    echo "Ihre Paymenter-Installation ist unter https://$domain verfügbar"
else
    echo "Ihre Paymenter-Installation ist unter http://$domain verfügbar"
fi
echo "Vielen Dank für die Verwendung dieses Skripts!"
