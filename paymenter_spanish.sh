#__________           _________              __  .__                      .__                   ________  ________ 
#\______   \___.__.  /   _____/____    _____/  |_|__|____     ____   ____ |  | ___  ______  ___/  _____/ /  _____/ 
# |    |  _<   |  |  \_____  \\__  \  /    \   __\  \__  \   / ___\ /  _ \|  | \  \/  /\  \/  /   \  ___/   \  ___ 
# |    |   \\___  |  /        \/ __ \|   |  \  | |  |/ __ \_/ /_/  >  <_> )  |__>    <  >    <\    \_\  \    \_\  \
# |______  // ____| /_______  (____  /___|  /__| |__(____  /\___  / \____/|____/__/\_ \/__/\_ \\______  /\______  /
#        \/ \/              \/     \/     \/             \//_____/                   \/      \/       \/        \/ 
#!/bin/bash

# Preguntas interactivas al usuario
read -p "Ingresa el dominio que deseas utilizar en Paymenter (por ejemplo, paymenter.com): " domain
read -p "¿Deseas configurar SSL automáticamente? (y/n): " configure_ssl
read -p "¿Quieres utilizar un certificado SSL con Certbot? (y/n): " use_certbot

# Validación del dominio
if [ -z "$domain" ]; then
    echo "El dominio no puede estar vacío."
    exit 1
fi

# Verificación de openssl
if ! command -v openssl &> /dev/null; then
    echo "openssl no está instalado. Por favor, instálalo antes de continuar."
    exit 1
fi

# Dependencias
apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg

LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php

apt update

apt -y install php8.2 php8.2-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} mariadb-server nginx tar unzip git redis-server

# Instalación de Composer
if ! command -v composer &> /dev/null; then
    echo "Instalando Composer..."
    curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/local/bin --filename=composer
fi

# Instalación de Nginx
if ! command -v nginx &> /dev/null; then
    echo "Instalando Nginx..."
    apt -y install nginx
fi

# Verificar la existencia del directorio /var/www/paymenter
if [ -d "/var/www/paymenter" ]; then
    read -p "El directorio /var/www/paymenter ya existe. ¿Quieres eliminarlo y continuar? (y/n): " delete_existing
    if [ "$delete_existing" = "y" ]; then
        rm -rf /var/www/paymenter
        echo "Directorio existente eliminado."
    else
        echo "Operación cancelada. No se ha realizado ningún cambio."
        exit 1
    fi
fi

# Configuración SSL
if [ "$configure_ssl" = "y" ]; then
    # Instalación de Certbot
    apt -y install certbot python3-certbot-nginx

    # Solicitar certificado SSL con Certbot
    if [ "$use_certbot" = "y" ]; then
        certbot --nginx -d $domain
    fi
fi

# Crear directorio para Paymenter
mkdir /var/www/paymenter
cd /var/www/paymenter

# Descargar Paymenter
curl -Lo paymenter.tar.gz https://github.com/paymenter/paymenter/releases/latest/download/paymenter.tar.gz
tar -xzvf paymenter.tar.gz
chmod -R 755 storage/* bootstrap/cache/

# Crear usuario y base de datos en MySQL
read -p "Ingresa el nombre de la base de datos (presiona Enter para usar 'paymenter'): " db_name
db_name=${db_name:-paymenter}
read -p "Ingresa el nombre de usuario de la base de datos (presiona Enter para usar 'paymenter'): " db_user
db_user=${db_user:-paymenter}
read -p "Ingresa la contraseña de la base de datos (presiona Enter para generar una contraseña aleatoria): " db_password
db_password=${db_password:-$(openssl rand -hex 16)}

# Creación de usuario y base de datos en MySQL
mysql -e "CREATE DATABASE IF NOT EXISTS $db_name;"
mysql -e "CREATE USER IF NOT EXISTS '$db_user'@'localhost' IDENTIFIED BY '$db_password';"
mysql -e "GRANT ALL PRIVILEGES ON $db_name.* TO '$db_user'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# Configurar archivo .env
cp .env.example .env
# dependecias de composer
composer install --no-dev --optimize-autoloader

# Edición del archivo .env
sed -i "/^DB_DATABASE=/s/.*/DB_DATABASE=$db_name/" .env
sed -i "/^DB_USERNAME=/s/.*/DB_USERNAME=$db_user/" .env
sed -i "/^DB_PASSWORD=/s/.*/DB_PASSWORD=$db_password/" .env

# Generar clave de la aplicación
php artisan key:generate --force

# Ejecutar migraciones y seeders
php artisan migrate --force --seed

# Crear enlace simbólico para el almacenamiento
php artisan storage:link

# Crear contraseña
php artisan p:user:create

# Configurar Nginx
nginx_conf="/etc/nginx/sites-available/paymenter"
echo "server {" > $nginx_conf
echo "    listen 80;" >> $nginx_conf
echo "    listen [::]:80;" >> $nginx_conf
echo "    server_name $domain;" >> $nginx_conf

if [ "$configure_ssl" = "y" ]; then
    echo "    return 301 https://\$host\$request_uri;" >> $nginx_conf
    echo "}" >> $nginx_conf
    echo "" >> $nginx_conf
    echo "server {" >> $nginx_conf
    echo "    listen 443 ssl http2;" >> $nginx_conf
    echo "    listen [::]:443 ssl http2;" >> $nginx_conf
    echo "    server_name $domain;" >> $nginx_conf
    echo "" >> $nginx_conf
    echo "    root /var/www/paymenter/public;" >> $nginx_conf
    echo "    index index.php;" >> $nginx_conf
    echo "" >> $nginx_conf
    echo "    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;" >> $nginx_conf
    echo "    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;" >> $nginx_conf
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

# Crear enlace simbólico y reiniciar Nginx
ln -s $nginx_conf /etc/nginx/sites-enabled/
chown -R www-data:www-data /var/www/paymenter/*
systemctl restart nginx

# Agregar cronjob para Laravel Scheduler
(crontab -l ; echo "* * * * * php /var/www/paymenter/artisan schedule:run >> /dev/null 2>&1") | crontab -

# Configurar el servicio de Paymenter
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

# Habilitar y iniciar el servicio Paymenter
systemctl enable --now paymenter

# Mensaje de finalización
if [ "$configure_ssl" = "y" ]; then
    echo "Tu instalación de Paymenter está disponible en: https://$domain"
else
    echo "Tu instalación de Paymenter está disponible en: http://$domain"
fi
echo "¡Gracias por usar este script!"
