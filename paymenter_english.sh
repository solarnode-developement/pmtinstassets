#!/bin/bash

# Interactive user input
read -p "Enter the domain you want to use for Paymenter (e.g., paymenter.com): " domain
read -p "Do you want to configure an SSL certificate? (y/n): " configure_ssl

# Domain validation
if [ -z "$domain" ]; then
    echo "The domain cannot be empty."
    exit 1
fi

# openssl verification
if ! command -v openssl &> /dev/null; then
    echo "openssl is not installed. Please install it before continuing."
    exit 1
fi

# Dependencies
apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg

LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php

apt update

apt -y install php8.2 php8.2-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} mariadb-server nginx tar unzip git redis-server

# Composer installation
if ! command -v composer &> /dev/null; then
    echo "Installing Composer..."
    curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/local/bin --filename=composer
fi

# Nginx installation
if ! command -v nginx &> /dev/null; then
    echo "Installing Nginx..."
    apt -y install nginx
fi

# Check the existence of the /var/www/paymenter directory
if [ -d "/var/www/paymenter" ]; then
    read -p "The directory /var/www/paymenter already exists. Do you want to delete it and continue? (y/n): " delete_existing
    if [ "$delete_existing" = "y" ]; then
        rm -rf /var/www/paymenter
        echo "Existing directory deleted."
    else
        echo "Operation canceled. No changes have been made."
        exit 1
    fi
fi

# SSL Configuration
if [ "$configure_ssl" = "y" ]; then
    # Certbot installation
    apt -y install certbot python3-certbot-nginx

    # Request SSL certificate with Certbot
    certbot --nginx -d $domain
fi

# Create directory for Paymenter
mkdir /var/www/paymenter
cd /var/www/paymenter

# Download Paymenter
curl -Lo paymenter.tar.gz https://github.com/paymenter/paymenter/releases/latest/download/paymenter.tar.gz
tar -xzvf paymenter.tar.gz
chmod -R 755 storage/* bootstrap/cache/

# Create MySQL user and database
read -p "Enter the database name (press Enter to use 'paymenter'): " db_name
db_name=${db_name:-paymenter}
read -p "Enter the database username (press Enter to use 'paymenter'): " db_user
db_user=${db_user:-paymenter}
read -p "Enter the database password (press Enter to generate a random password): " db_password
db_password=${db_password:-$(openssl rand -hex 16)}

# Check existence of the database and user
if mysql -e "USE $db_name;" 2>/dev/null && mysql -e "SELECT User FROM mysql.user WHERE User='$db_user';" 2>/dev/null; then
    # Test database connection
    if ! mysql -h localhost -u "$db_user" -p"$db_password" -e "EXIT;" 2>/dev/null; then
        echo "The database connection test has failed. Changing the user password..."
        mysql -e "ALTER USER '$db_user'@'localhost' IDENTIFIED BY '$db_password';"
        echo "Password changed."
    fi
else
    mysql -e "CREATE DATABASE $db_name;"
    mysql -e "CREATE USER '$db_user'@'localhost' IDENTIFIED BY '$db_password';"
    mysql -e "GRANT ALL PRIVILEGES ON $db_name.* TO '$db_user'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"
fi

# Configure .env file
cp .env.example .env
# Composer dependencies
composer install --no-dev --optimize-autoloader

# Edit .env file
sed -i "/^DB_DATABASE=/s/.*/DB_DATABASE=$db_name/" .env
sed -i "/^DB_USERNAME=/s/.*/DB_USERNAME=$db_user/" .env
sed -i "/^DB_PASSWORD=/s/.*/DB_PASSWORD=$db_password/" .env

# Generate application key
php artisan key:generate --force

# Run migrations and seeders
php artisan migrate --force --seed

# Create symbolic link for storage
php artisan storage:link

# Create user password
php artisan p:user:create

# Configure Nginx
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

# Create symbolic link and restart Nginx
ln -s $nginx_conf /etc/nginx/sites-enabled/
chown -R www-data:www-data /var/www/paymenter/*
systemctl restart nginx

# Add cronjob for Laravel Scheduler
(crontab -l ; echo "* * * * * php /var/www/paymenter/artisan schedule:run >> /dev/null 2>&1") | crontab -

# Configure Paymenter service
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

# Enable and start Paymenter service
systemctl enable --now paymenter

echo "Configuration complete. Paymenter is ready to use."
if [ "$configure_ssl" = "y" ]; then
    echo "Your Paymenter installation is available at: https://$domain"
else
    echo "Your Paymenter installation is available at: http://$domain"
fi
echo "Thanks for using this installer!"
echo "Made by SantiagolxxGG"
