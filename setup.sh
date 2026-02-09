#!/usr/bin/env bash
set -e

### ========= CONFIG =========
HOSTNAME_NAME="new-hostname"
NEW_USER="deploy"
DOMAIN_NAME="yourdomain.com"
EMAIL="youremail@example.com"
WEB_ROOT="/var/www/app"
NGINX_SITE_NAME="app"
PHP_VERSION="8.2"
### ==========================

echo "🚀 Starting FULL production VPS setup..."

# ================= STEP 1 =================
echo "🔄 System update..."
apt update -y && apt upgrade -y

apt install -y \
  software-properties-common \
  curl unzip zip git ca-certificates \
  lsb-release gnupg

# ================= STEP 2 =================
echo "🏷️ Hostname..."
hostnamectl set-hostname "$HOSTNAME_NAME"

# ================= STEP 3 =================
echo "📦 snapd & snapcraft..."
apt install snapd -y
snap install snapcraft --classic

# ================= STEP 4 =================
echo "👤 Create sudo user..."
if ! id "$NEW_USER" &>/dev/null; then
  adduser "$NEW_USER"
  usermod -aG sudo "$NEW_USER"
fi

# ================= STEP 5 =================
echo "🐟 Fish shell..."
apt install fish -y
usermod --shell "$(which fish)" "$NEW_USER"

# ================= STEP 6 =================
echo "🔑 GitLab SSH key (server)..."
sudo -u "$NEW_USER" mkdir -p "/home/$NEW_USER/.ssh"
sudo -u "$NEW_USER" ssh-keygen -t ed25519 -f "/home/$NEW_USER/.ssh/id_ed25519" -N ""
echo "➡️ GitLab public key:"
cat "/home/$NEW_USER/.ssh/id_ed25519.pub"

# ================= STEP 7 =================
echo "🔥 Firewall (UFW)..."
apt install ufw -y
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80
ufw allow 443
ufw --force enable

# ================= STEP 8 =================
echo "🛡️ Fail2Ban..."
apt install fail2ban -y
systemctl enable fail2ban
systemctl start fail2ban

# ================= STEP 9 =================
echo "🐘 PHP install..."
add-apt-repository ppa:ondrej/php -y
apt update -y

apt install -y \
  php$PHP_VERSION \
  php$PHP_VERSION-fpm \
  php$PHP_VERSION-cli \
  php$PHP_VERSION-mbstring \
  php$PHP_VERSION-xml \
  php$PHP_VERSION-bcmath \
  php$PHP_VERSION-curl \
  php$PHP_VERSION-zip \
  php$PHP_VERSION-mysql \
  php$PHP_VERSION-sqlite3 \
  php$PHP_VERSION-gd \
  php$PHP_VERSION-opcache

systemctl enable php$PHP_VERSION-fpm
systemctl start php$PHP_VERSION-fpm

# ===== PHP TUNING =====
PHP_INI="/etc/php/$PHP_VERSION/fpm/php.ini"

sed -i "s/^memory_limit = .*/memory_limit = 256M/" $PHP_INI
sed -i "s/^upload_max_filesize = .*/upload_max_filesize = 50M/" $PHP_INI
sed -i "s/^post_max_size = .*/post_max_size = 50M/" $PHP_INI
sed -i "s/^max_execution_time = .*/max_execution_time = 60/" $PHP_INI
sed -i "s/^;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/" $PHP_INI

systemctl restart php$PHP_VERSION-fpm

# ================= STEP 10 =================
echo "🌐 Nginx..."
apt install nginx -y
systemctl enable nginx
systemctl start nginx

mkdir -p "$WEB_ROOT"

cat > /etc/nginx/sites-available/$NGINX_SITE_NAME <<EOF
server {
    listen 80;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;

    root $WEB_ROOT/public;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php$PHP_VERSION-fpm.sock;
    }

    location ~ /\. {
        deny all;
    }
}
EOF

cp -a /etc/nginx/sites-available/default ~/default.nginx.backup || true
unlink /etc/nginx/sites-enabled/default 2>/dev/null || true

ln -sf /etc/nginx/sites-available/$NGINX_SITE_NAME /etc/nginx/sites-enabled/$NGINX_SITE_NAME

nginx -t
systemctl restart nginx

chown -R www-data:www-data "$WEB_ROOT"
chmod -R 755 "$WEB_ROOT"

# ================= STEP 11 =================
echo "⚙️ Supervisor (Laravel queues)..."
apt install supervisor -y

cat > /etc/supervisor/conf.d/laravel-worker.conf <<EOF
[program:laravel-worker]
process_name=%(program_name)s_%(process_num)02d
command=php $WEB_ROOT/artisan queue:work --sleep=3 --tries=3 --timeout=90
autostart=true
autorestart=true
user=www-data
numprocs=2
redirect_stderr=true
stdout_logfile=/var/log/laravel-worker.log
EOF

supervisorctl reread
supervisorctl update
supervisorctl start laravel-worker:*

# ================= STEP 12 =================
echo "🧾 Log rotation..."
cat > /etc/logrotate.d/laravel <<EOF
/var/log/laravel*.log /var/log/nginx/*.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    sharedscripts
    postrotate
        systemctl reload nginx > /dev/null 2>&1 || true
    endscript
}
EOF

# ================= STEP 13 =================
echo "🔒 SSL..."
snap install --classic certbot
ln -s /snap/bin/certbot /usr/bin/certbot || true

certbot --nginx -d "$DOMAIN_NAME" -d "www.$DOMAIN_NAME" \
  -m "$EMAIL" --agree-tos --non-interactive

certbot renew --dry-run

echo "✅ FULL PRODUCTION VPS READY"
