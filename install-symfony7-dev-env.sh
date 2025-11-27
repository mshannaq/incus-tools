#!/bin/bash
# install-symfony7-dev-env.sh
# Script to set up a Symfony 7.4 development environment on Debian 13 
# This is for developmen/staging purposes only. DO NOT use in production.
# Best use with Online Linux Container.
# Author: Mohammed AlShannaq
# Copyright (c) 2025 Extendy LTD
# License: MIT
# -----------------------------
# Verified 2025-11-27 with the following conditions:
# runs on a fresh Debian 13 install
# must run as root
# must confirm development environment unless --devenv=yes is provided
# must running online to let certbot work properly , so the domain name (or subdomain) must be already pointed to the server ip
# with not installing symfony by default <-- Need some fix to apply


# --- Configuration ---
LOG_FILE="/var/log/symfony-webserver.log"
SYMFONY_VERSION="7.4"
PHP_VERSION="8.4"

# --- Logging Function ---
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# --- Initial Setup and Checks ---

# Create log file if it doesn't exist
if [ ! -f "$LOG_FILE" ]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
fi

log "--- Starting Symfony ${SYMFONY_VERSION} Development Environment Setup ---"

# 1. Root Check
if [[ $EUID -ne 0 ]]; then
   log "ERROR: This script must be run as root."
   echo "ERROR: This script must be run as root."
   exit 1
fi
log "Root check passed."

# 2. OS Check (Debian 13)
OS_RELEASE=$(grep ^VERSION_ID /etc/os-release | cut -d'=' -f2 | tr -d '"')
if [ "$OS_RELEASE" != "13" ]; then
    log "ERROR: This script is designed for Debian 13. Detected version: Debian $OS_RELEASE."
    echo "ERROR: This script is designed for Debian 13. Detected version: Debian $OS_RELEASE."
    exit 1
fi
log "OS check passed. Detected Debian $OS_RELEASE."

# 3. Development Environment Confirmation
DEV_ENV_CONFIRMED=false
for arg in "$@"; do
    if [[ "$arg" == "--devenv=yes" ]]; then
        DEV_ENV_CONFIRMED=true
        log "Development environment confirmation skipped via --devenv=yes parameter."
        break
    fi
done

if [ "$DEV_ENV_CONFIRMED" = false ]; then
    echo -e "\n\033[1;33m!!! WARNING: DEVELOPMENT/STAGING ENVIRONMENT !!!\033[0m"
    echo "This script is intended for setting up a development or staging environment."
    read -r -p "Do you confirm you are in a development environment? (yes/no): " DEV_CONFIRM
    log "User confirmation for development environment: $DEV_CONFIRM"
    if [[ "$DEV_CONFIRM" != "yes" ]]; then
        log "User declined development environment confirmation. Exiting."
        echo "Exiting script."
        exit 1
    fi
fi

# --- User Input ---

echo -e "\n--- Gathering Configuration ---"
read -r -p "Enter the domain name to host (e.g., symfony.example.com): " DOMAIN
log "User entered domain: $DOMAIN"

read -r -p "Enter the public PHP files folder (e.g., symfony/public): " PUBLIC_FOLDER
# Ensure PUBLIC_FOLDER is not empty and doesn't start with /
if [[ -z "$PUBLIC_FOLDER" ]]; then
    PUBLIC_FOLDER="symfony/public"
    echo "Using default public folder: $PUBLIC_FOLDER"
fi
PUBLIC_FOLDER_PATH="/var/www/$PUBLIC_FOLDER"
log "Public folder path: $PUBLIC_FOLDER_PATH"

read -r -p "Enter your email for Certbot/Let's Encrypt: " CERTBOT_EMAIL
log "User entered Certbot email: $CERTBOT_EMAIL"

read -r -p "Do you want to install Symfony ${SYMFONY_VERSION} after setup? (yes/no): " INSTALL_SYMFONY
log "User chose to install Symfony: $INSTALL_SYMFONY"

# --- System Update and Package Installation ---

log "Updating system and installing base packages..."
echo -e "\n--- System Update and Package Installation ---"
apt update && apt upgrade -y | tee -a "$LOG_FILE"

log "Installing required packages..."
apt install -y \
    php php-fpm php-cli php-common \
    php-xml php-mbstring php-curl php-zip php-intl \
    php-opcache php-readline php-sqlite3 php-mysql php-redis \
    unzip curl git nano wget mariadb-server | tee -a "$LOG_FILE"

log "Enabling MariaDB service..."
systemctl enable mariadb | tee -a "$LOG_FILE"
systemctl start mariadb | tee -a "$LOG_FILE"

# 4. PHP Version Check
log "Checking PHP version..."
echo -e "\n--- PHP Version Check ---"
PHP_OUTPUT=$(php -v 2>&1)
echo "$PHP_OUTPUT" | tee -a "$LOG_FILE"
if [[ "$PHP_OUTPUT" != *"PHP ${PHP_VERSION}"* ]]; then
    log "WARNING: PHP version check. Expected ${PHP_VERSION}, but found a different version. Proceeding, but manual check may be required."
    echo "WARNING: PHP version check. Expected ${PHP_VERSION}, but found a different version. Proceeding, but manual check may be required."
fi

# --- Composer Installation ---

log "Installing Composer..."
echo -e "\n--- Composer Installation ---"
cd /root/ | tee -a "$LOG_FILE"
curl -sS https://getcomposer.org/installer -o composer-setup.php | tee -a "$LOG_FILE"
php composer-setup.php --install-dir=/usr/local/bin --filename=composer | tee -a "$LOG_FILE"
rm composer-setup.php | tee -a "$LOG_FILE"
log "Composer installed."

# --- Symfony CLI Installation ---

log "Installing Symfony CLI..."
echo -e "\n--- Symfony CLI Installation ---"
curl -1sLf 'https://dl.cloudsmith.io/public/symfony/stable/setup.deb.sh' | sudo -E bash | tee -a "$LOG_FILE"
sudo apt install symfony-cli -y | tee -a "$LOG_FILE"
log "Symfony CLI installed."

# --- Certbot Installation ---

log "Installing Certbot..."
echo -e "\n--- Certbot Installation ---"
apt install -y certbot python3-certbot-nginx | tee -a "$LOG_FILE"
CERTBOT_VERSION=$(certbot --version 2>&1)
echo "Certbot version: $CERTBOT_VERSION" | tee -a "$LOG_FILE"
log "Certbot installed. Version: $CERTBOT_VERSION"

# --- Nginx Installation and Configuration ---

log "Checking for Apache and installing Nginx..."
echo -e "\n--- Nginx Setup ---"

# Check for Apache listening on port 80
if ss -tulpn | grep -q ":80.*apache2"; then
    log "Apache detected on port 80. Removing Apache..."
    apt remove --purge apache2 apache2-* -y | tee -a "$LOG_FILE"
    apt autoremove -y | tee -a "$LOG_FILE"
    log "Apache removed."
fi

log "Installing Nginx..."
apt install -y nginx | tee -a "$LOG_FILE"
systemctl enable nginx | tee -a "$LOG_FILE"
systemctl start nginx | tee -a "$LOG_FILE"
log "Nginx installed and started."

# --- PHP-FPM Activation ---

log "Activating PHP-FPM ${PHP_VERSION}..."
echo -e "\n--- PHP-FPM Activation ---"
# Note: The package name is usually php-fpm or phpX.Y-fpm. Assuming php-fpm for generic Debian setup.
# If the user's system uses a versioned service name, this will need adjustment.
# For a clean Debian 13 install, 'php-fpm' should be the service name for the default PHP version.
# The user's request explicitly mentions 'php8.4-fpm', which implies a versioned package.
# We will use the generic 'php-fpm' service name for status check, and assume the correct version is active.

# Find the correct PHP-FPM socket
PHP_FPM_SOCKET=$(ls /run/php/ | grep -E 'php.*-fpm.sock' | head -n 1)
if [ -z "$PHP_FPM_SOCKET" ]; then
    log "ERROR: Could not find a PHP-FPM socket in /run/php/. Defaulting to php-fpm.sock."
    PHP_FPM_SOCKET="php-fpm.sock"
else
    log "Found PHP-FPM socket: $PHP_FPM_SOCKET"
fi

# Attempt to enable/start the generic php-fpm service
systemctl enable php-fpm | tee -a "$LOG_FILE"
systemctl start php-fpm | tee -a "$LOG_FILE"

log "Checking PHP-FPM status..."
PHP_FPM_STATUS=$(systemctl status php-fpm 2>&1)
echo "$PHP_FPM_STATUS" | tee -a "$LOG_FILE"
log "PHP-FPM status check complete."

# --- Nginx Virtual Host Creation ---

log "Creating Nginx Virtual Host for $DOMAIN..."
echo -e "\n--- Nginx Virtual Host Creation ---"

NGINX_CONF_PATH="/etc/nginx/sites-available/$DOMAIN"
SYMFONY_ROOT_DIR=$(dirname "$PUBLIC_FOLDER_PATH")

# Create the Nginx configuration file
cat << EOF > "$NGINX_CONF_PATH"
# Nginx config for Symfony (HTTP only, no SSL yet)
server {
    listen 80;
    server_name $DOMAIN;

    # Symfony public directory
    root $PUBLIC_FOLDER_PATH;
    index index.php;

    # Access and error logs
    access_log /var/log/nginx/${DOMAIN}_access.log;
    error_log  /var/log/nginx/${DOMAIN}_error.log;

    # Try to serve static files, then fall back to index.php
    location / {
        try_files \$uri /index.php\$is_args\$args;
    }

    # PHP-FPM handling
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/$PHP_FPM_SOCKET;
    }

    # Deny access to hidden and sensitive files
    location ~ /\.(git|env|ht) {
        deny all;
    }
}
EOF
log "Nginx config written to $NGINX_CONF_PATH"

# Activate the site and create the root directory
log "Activating site and creating root directory $SYMFONY_ROOT_DIR..."
ln -s "$NGINX_CONF_PATH" /etc/nginx/sites-enabled/ | tee -a "$LOG_FILE"
mkdir -p "$PUBLIC_FOLDER_PATH" | tee -a "$LOG_FILE"
echo "<?php echo 'Hello from Symfony container on $DOMAIN';" > "$PUBLIC_FOLDER_PATH/index.php" | tee -a "$LOG_FILE"
chown -R www-data:www-data "$SYMFONY_ROOT_DIR" | tee -a "$LOG_FILE"

# Test and reload Nginx
log "Testing Nginx configuration and reloading..."
nginx -t | tee -a "$LOG_FILE"
systemctl reload nginx | tee -a "$LOG_FILE"
log "Nginx reloaded."

# --- Certbot SSL Installation ---

log "Running Certbot for SSL certificate..."
echo -e "\n--- Certbot SSL Installation ---"
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$CERTBOT_EMAIL" --redirect | tee -a "$LOG_FILE"

log "Testing Nginx configuration after Certbot and reloading..."
nginx -t | tee -a "$LOG_FILE"
systemctl reload nginx | tee -a "$LOG_FILE"
log "Nginx reloaded after Certbot."

# --- Optional Symfony Project Installation ---

if [[ "$INSTALL_SYMFONY" == "yes" ]]; then
    log "User requested Symfony ${SYMFONY_VERSION} project installation."
    echo -e "\n--- Symfony Project Installation ---"

    # Check Symfony requirements
    log "Checking Symfony requirements..."
    symfony check:requirements | tee -a "$LOG_FILE"

    # Create the Symfony project
    log "Creating Symfony project in $SYMFONY_ROOT_DIR..."
    echo -e "\n\033[1;31m!!! CRITICAL WARNING !!!\033[0m"
    echo -e "\033[1;31mThis is a development setup. NEVER use this setup for production environments.\033[0m"
    log "WARNING: Creating Symfony project in development mode. Not for production."

    cd "$SYMFONY_ROOT_DIR" | tee -a "$LOG_FILE"
    # Clean up the temporary index.php and public folder
    rm -f "$PUBLIC_FOLDER_PATH/index.php" | tee -a "$LOG_FILE"
    rm -dfr "$PUBLIC_FOLDER_PATH" | tee -a "$LOG_FILE"

    # Git configuration to avoid errors in the script environment
    git config --global --add safe.directory "$SYMFONY_ROOT_DIR" | tee -a "$LOG_FILE"
    git config --global user.email "user@example.com" | tee -a "$LOG_FILE"
    git config --global user.name "Your Name" | tee -a "$LOG_FILE"
    export COMPOSER_ALLOW_SUPERUSER=1 | tee -a "$LOG_FILE"

    # Install Symfony
    symfony new $SYMFONY_ROOT_DIR --webapp --version="$SYMFONY_VERSION" | tee -a "$LOG_FILE"
    log "Symfony ${SYMFONY_VERSION} project created."
else
    log "User skipped Symfony project installation."
fi

# --- Finalization ---

log "--- Symfony Development Environment Setup Complete ---"
echo -e "\n\033[1;32m*** Installation Complete ***\033[0m"
echo "The setup script has finished."
echo "Domain: https://$DOMAIN"
echo "Root Directory: $SYMFONY_ROOT_DIR"
echo "Log File: $LOG_FILE"
echo "Please check the log file for details and any warnings."
