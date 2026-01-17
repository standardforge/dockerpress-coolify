#!/bin/bash
set -e

# remove default index.html if exists
rm -f /var/www/html/index.html

function finish() {
  echo "Shutting down gracefully..."
  /usr/local/lsws/bin/lswsctrl stop
  pkill tail 2>/dev/null || true
  exit 0
}

function update_wp_config() {
  echo "Updating wp-config.php ..."
  wp config set WP_SITEURL "$SERVICE_URL_DOCKERPRESS" --add --type=constant --allow-root
  wp config set WP_HOME "$SERVICE_URL_DOCKERPRESS" --add --type=constant --allow-root
  wp config set DB_NAME "$WORDPRESS_DB_NAME" --add --type=constant --allow-root
  wp config set DB_USER "$WORDPRESS_DB_USER" --add --type=constant --allow-root
  wp config set DB_PASSWORD "$WORDPRESS_DB_PASSWORD" --add --type=constant --allow-root

  # Option 1: Just hostname in DB_HOST, use DB_PORT separately (RECOMMENDED)
  wp config set DB_HOST "$WORDPRESS_DB_HOST" --add --type=constant --allow-root
  wp config set DB_PORT "$WORDPRESS_DB_PORT" --raw --add --type=constant --allow-root

  wp config set DB_PREFIX "$WORDPRESS_DB_PREFIX" --add --type=constant --allow-root
  wp config set WP_DEBUG "$WP_DEBUG" --raw --add --type=constant --allow-root
  wp config set WP_MEMORY_LIMIT 512M --add --type=constant --allow-root
  wp config set WP_MAX_MEMORY_LIMIT 512M --add --type=constant --allow-root
  wp config set DISABLE_WP_CRON "$DISABLE_WP_CRON" --raw --add --type=constant --allow-root
}

function generate_litespeed_password() {
  if [ -n "${ADMIN_PASSWORD}" ]; then
    ENCRYPT_PASSWORD="$(/usr/local/lsws/admin/fcgi-bin/admin_php -q '/usr/local/lsws/admin/misc/htpasswd.php' "${ADMIN_PASSWORD}")"
    echo "admin:${ENCRYPT_PASSWORD}" >'/usr/local/lsws/admin/conf/htpasswd'
    echo "OLS WebAdmin user/password is admin/${ADMIN_PASSWORD}" >'/usr/local/lsws/adminpasswd'
  fi
}

function setup_mysql_client() {
  if [ -f /root/.my.cnf.sample ]; then
    echo "Updating my.cnf ..."
    mv /root/.my.cnf.sample /root/.my.cnf
    sed -i -e "s/MYUSER/$WORDPRESS_DB_USER/g" /root/.my.cnf
    sed -i -e "s/MYPASSWORD/$WORDPRESS_DB_PASSWORD/g" /root/.my.cnf
    sed -i -e "s/MYHOST/$WORDPRESS_DB_HOST/g" /root/.my.cnf
    sed -i -e "s/MYDATABASE/$WORDPRESS_DB_NAME/g" /root/.my.cnf
    sed -i -e "s/MYPORT/$WORDPRESS_DB_PORT/g" /root/.my.cnf
  fi
}

function install_wp_cli() {
  echo "Setting up wp-cli..."
  rm -rf /var/www/.wp-cli/
  mkdir -p "$WP_CLI_CACHE_DIR"
  chown -R www-data:www-data "$WP_CLI_CACHE_DIR"
  rm -rf "$WP_CLI_PACKAGES_DIR"
  mkdir -p "$WP_CLI_PACKAGES_DIR"
  chown -R www-data:www-data "$WP_CLI_PACKAGES_DIR"
  
  if [ ! -f /var/www/wp-cli.phar ]; then
    curl -o /var/www/wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x /var/www/wp-cli.phar
  fi
  
  if [ ! -f /var/www/wp-completion.bash ]; then
    curl -o /var/www/wp-completion.bash https://raw.githubusercontent.com/wp-cli/wp-cli/master/utils/wp-completion.bash
  fi
  source /var/www/wp-completion.bash
}

function setup_mysql_optimize() {
  echo "Setting up MySQL Optimize..."
  sed -i -e "s/WORDPRESS_DB_HOST/$WORDPRESS_DB_HOST/g" /usr/local/bin/mysql-optimize
  sed -i -e "s/WORDPRESS_DB_USER/$WORDPRESS_DB_USER/g" /usr/local/bin/mysql-optimize
  sed -i -e "s/WORDPRESS_DB_PASSWORD/$WORDPRESS_DB_PASSWORD/g" /usr/local/bin/mysql-optimize
  sed -i -e "s/WORDPRESS_DB_NAME/$WORDPRESS_DB_NAME/g" /usr/local/bin/mysql-optimize
  sed -i -e "s/WORDPRESS_DB_PORT/$WORDPRESS_DB_PORT/g" /usr/local/bin/mysql-optimize
}

function create_wordpress_database() {
  echo "Waiting for database to be ready..."
  MAX_TRIES=30
  COUNT=0
  
  until mysql --no-defaults -h "$WORDPRESS_DB_HOST" --port "$WORDPRESS_DB_PORT" -u "$WORDPRESS_DB_USER" -p"$WORDPRESS_DB_PASSWORD" -e "SELECT 1" >/dev/null 2>&1; do
    COUNT=$((COUNT+1))
    if [ $COUNT -ge $MAX_TRIES ]; then
      echo "ERROR: Database connection timeout after $MAX_TRIES attempts"
      exit 1
    fi
    echo "Database not ready, waiting... (attempt $COUNT/$MAX_TRIES)"
    sleep 3
  done
  
  echo "Database is ready!"
  
  if [ -n "$MYSQL_ROOT_PASSWORD" ]; then
    echo "Creating database using root user..."
    mysql --no-defaults -h "$WORDPRESS_DB_HOST" --port "$WORDPRESS_DB_PORT" -u root -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS \`$WORDPRESS_DB_NAME\`;"
  else
    echo "Creating database using $WORDPRESS_DB_USER user..."
    mysql --no-defaults -h "$WORDPRESS_DB_HOST" --port "$WORDPRESS_DB_PORT" -u "$WORDPRESS_DB_USER" -p"$WORDPRESS_DB_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS \`$WORDPRESS_DB_NAME\`;"
  fi
}

function install_wordpress() {
  chown -R www-data:www-data /var/www/html

  if [ ! -e /var/www/html/wp-config.php ]; then

    echo "WordPress not found, downloading latest version ..."
    wp core download --path=/var/www/html --allow-root

    echo "Creating wp-config.file ..."
    cp /var/www/wp-config-sample.php /var/www/html/wp-config.php
    chown www-data:www-data /var/www/html/wp-config.php
    update_wp_config

    echo "Shuffling wp-config.php salts ..."
    wp config shuffle-salts --allow-root

    # if Wordpress is installed
    if ! wp core is-installed --allow-root; then
      echo "Installing WordPress for $SERVICE_URL_DOCKERPRESS ..."
      if [ "${WP_MULTISITE:-false}" = "true" ]; then
        echo "define('WP_ALLOW_MULTISITE', true);" >> /var/www/html/wp-config.php
        wp core multisite-install --url="$SERVICE_URL_DOCKERPRESS" --title="WordPress" --admin_user="$ADMIN_USER" --admin_password="$ADMIN_PASS" --admin_email="$ADMIN_EMAIL" --subdomains="${WP_SUBDOMAINS:-false}" --skip-email --path=/var/www/html --allow-root
      else
        wp core install --url="$SERVICE_URL_DOCKERPRESS" \
          --title="WordPress" \
          --admin_user="$ADMIN_USER" \
          --admin_password="$ADMIN_PASS" \
          --admin_email="$ADMIN_EMAIL" \
          --skip-email \
          --path=/var/www/html \
          --allow-root
      fi

      echo "Updating plugins..."
      wp plugin update --all --path=/var/www/html --allow-root || true

      echo "Remove Dolly..."
      wp plugin delete hello --path=/var/www/html --allow-root || true

      echo "Removing old default themes..."
      active_theme=$(wp theme list --status=active --field=name --path=/var/www/html --allow-root)
      wp theme delete $(wp theme list --field=name --path=/var/www/html --allow-root | grep -v "^${active_theme}$") --path=/var/www/html --allow-root || true

      echo "Updating active theme..."
      wp theme update "$active_theme" --path=/var/www/html --allow-root || true

      echo "WordPress install complete!"

      if [ -f /var/www/.htaccess ]; then
        cp /var/www/.htaccess /var/www/html/.htaccess
        chown www-data:www-data /var/www/html/.htaccess
      fi
      
      wp rewrite structure '/%postname%/' --allow-root

    else
      echo 'WordPress is already installed.'
    fi
  else
    echo 'wp-config.php file already exists.'
    update_wp_config
  fi
}

function install_dockerpress_plugins() {
  # First verify WordPress can connect to database
  if ! wp db check --allow-root 2>/dev/null; then
    echo "WARNING: Cannot connect to database. Skipping plugin installation."
    echo "Plugins can be installed later from WordPress admin."
    return 0
  fi

  echo "Installing action-scheduler ..."
  wp plugin install action-scheduler --force --activate --path=/var/www/html --allow-root || echo "Warning: action-scheduler installation failed"

  echo "Installing litespeed-cache ..."
  wp plugin install litespeed-cache --force --activate --path=/var/www/html --allow-root || echo "Warning: litespeed-cache installation failed"

  echo "Installing regenerate-thumbnails ..."
  wp plugin install regenerate-thumbnails --force --activate --path=/var/www/html --allow-root || echo "Warning: regenerate-thumbnails installation failed"
}

# Trap signals
trap finish SIGTERM SIGINT

cd /var/www/html

echo "=== Starting DockerPress Setup ==="

# Generate litespeed Admin Password
generate_litespeed_password

# Setting Up MySQL Client Defaults
setup_mysql_client

# Setup wp-cli
install_wp_cli

# Setting up cron service
service cron start || service cron reload

# Setting up MySQL Optimize
setup_mysql_optimize

# Start memcache service (before WordPress needs it)
service memcached start

# Creating WordPress Database - WITH BETTER ERROR HANDLING
echo "Waiting for database connection..."
if ! create_wordpress_database; then
    echo "ERROR: Could not connect to database!"
    echo "DB_HOST: $WORDPRESS_DB_HOST"
    echo "DB_PORT: $WORDPRESS_DB_PORT"
    echo "DB_NAME: $WORDPRESS_DB_NAME"
    echo "DB_USER: $WORDPRESS_DB_USER"
    echo "Starting OpenLiteSpeed anyway so container doesn't crash..."
    
    # Start OpenLiteSpeed even without DB
    /usr/local/lsws/bin/lswsctrl start
    sleep 2
    sysvbanner dockerpress
    cat '/usr/local/lsws/adminpasswd' 2>/dev/null || echo "Admin password not set"
    
    echo "Container is running but WordPress needs database connection."
    echo "Check your database settings and restart the container."
    tail -f /var/log/litespeed/error.log /var/log/litespeed/access.log &
    wait
    exit 0
fi

# Check if this is first run or update
FIRST_RUN=false
if [ ! -e /var/www/html/wp-config.php ]; then
    FIRST_RUN=true
    echo "First run detected - will perform full WordPress installation"
else
    echo "Existing installation detected - updating configuration only"
fi

# Run WordPress installer
echo "Installing/Updating WordPress..."
if ! install_wordpress; then
    echo "ERROR: WordPress installation failed!"
    cat /var/www/html/wp-config.php || echo "No wp-config.php found"
fi

# Only install plugins on first run or if explicitly requested
if [ "$FIRST_RUN" = true ] || [ "${FORCE_PLUGIN_INSTALL:-false}" = "true" ]; then
    echo "Installing default plugins..."
    install_dockerpress_plugins
else
    echo "Skipping plugin installation (not first run)"
fi

# Update file permissions
echo "Setting permissions..."
chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html
chmod 644 /var/www/html/wp-config.php

# Verify WordPress
wp core verify-checksums --allow-root || echo "Warning: Checksum verification failed"

# Test database connection one more time
if wp db check --allow-root; then
    echo "✓ Database connection verified"
else
    echo "✗ WARNING: Database connection test failed"
fi

# Ensure proper permissions on LiteSpeed directories
echo "Setting LiteSpeed permissions..."
chown -R lsadm:lsadm /usr/local/lsws/conf /tmp/lshttpd /var/log/litespeed
chmod -R 755 /tmp/lshttpd
chmod -R 755 /var/log/litespeed

# Welcome banner
sysvbanner dockerpress

# Display credentials
cat '/usr/local/lsws/adminpasswd' 2>/dev/null || echo "Admin password not set"

echo "=== Starting OpenLiteSpeed ==="

# Start OpenLiteSpeed
/usr/local/lsws/bin/lswsctrl start

# Wait for it to actually start
sleep 5

# Verify it's running
if ! pgrep -x "litespeed" > /dev/null; then
    echo "ERROR: OpenLiteSpeed failed to start!"
    echo "=== Error Log ==="
    cat /var/log/litespeed/error.log 2>/dev/null || echo "No error log found"
    exit 1
fi

echo "OpenLiteSpeed started successfully on port 80"
echo "Listening on: *:80"
echo "Document root: /var/www/html"

# Test that WordPress responds (internal test)
echo "Testing WordPress..."
sleep 2
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/)
if [ "$RESPONSE" = "200" ] || [ "$RESPONSE" = "301" ] || [ "$RESPONSE" = "302" ]; then
    echo "✓ WordPress is responding (HTTP $RESPONSE)"
else
    echo "✗ WordPress returned HTTP $RESPONSE"
    if [ "$RESPONSE" = "500" ]; then
        echo "This usually means database connection issues."
        echo "Check your database credentials and ensure the database is running."
    fi
fi

# Tail logs (keeps container running)
echo "Container ready - tailing logs..."
tail -f /var/log/litespeed/error.log /var/log/litespeed/access.log &

# Wait for signals
wait
