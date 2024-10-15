#!/bin/bash

# Function to check if a command is installed
is_installed() {
    command -v "$1" >/dev/null 2>&1
}

# Install unzip if it's not installed
if ! is_installed "unzip"; then
    echo "unzip not found, installing unzip..."
    sudo apt update && sudo apt install -y unzip
else
    echo "unzip is already installed."
fi

# Install or update Netdata
install_netdata() {
    echo "Installing or updating Netdata..."
    bash <(curl -Ss https://my-netdata.io/kickstart.sh)
    echo "Netdata installation or update complete."
}

# Install or update Loki
install_loki() {
    echo "Installing or updating Loki..."
    LOKI_VERSION=$(curl -s https://api.github.com/repos/grafana/loki/releases/latest | grep 'tag_name' | cut -d '"' -f 4)
    wget https://github.com/grafana/loki/releases/download/$LOKI_VERSION/loki-linux-amd64.zip
    unzip loki-linux-amd64.zip
    sudo mv loki-linux-amd64 /usr/local/bin/loki
    sudo chmod +x /usr/local/bin/loki
    echo "Loki installed or updated to version $LOKI_VERSION."
}

# Install or update Promtail
install_promtail() {
    echo "Installing or updating Promtail..."
    PROMTAIL_VERSION=$(curl -s https://api.github.com/repos/grafana/loki/releases/latest | grep 'tag_name' | cut -d '"' -f 4)
    wget https://github.com/grafana/loki/releases/download/$PROMTAIL_VERSION/promtail-linux-amd64.zip
    unzip promtail-linux-amd64.zip
    sudo mv promtail-linux-amd64 /usr/local/bin/promtail
    sudo chmod +x /usr/local/bin/promtail
    echo "Promtail installed or updated to version $PROMTAIL_VERSION."
}

# Check and install updates
if ! is_installed "netdata"; then
    install_netdata
else
    echo "Netdata is already installed."
fi

if ! is_installed "loki"; then
    install_loki
else
    echo "Loki is already installed."
fi

if ! is_installed "promtail"; then
    install_promtail
else
    echo "Promtail is already installed."
fi

# Define log paths for Apache, Nginx, Laravel, and Node.js
APACHE_ERROR_LOG="/var/log/apache2/error.log"
APACHE_ACCESS_LOG="/var/log/apache2/access.log"
NGINX_ERROR_LOG="/var/log/nginx/error.log"
NGINX_ACCESS_LOG="/var/log/nginx/access.log"
LARAVEL_LOG="/path-to-your-laravel-app/storage/logs/laravel.log"
NODE_LOG="/path-to-your-node-app/logs/node-error.log"

# Configuration paths
NETDATA_WEB_LOG_CONFIG="/etc/netdata/go.d/web_log.conf"
LOKI_CONFIG="/etc/loki/local-config.yaml"
PROMTAIL_CONFIG="/etc/promtail/promtail.yaml"

# Create necessary directories for Netdata, Loki, and Promtail
echo "Creating necessary directories..."
sudo mkdir -p /etc/netdata/go.d
sudo mkdir -p /etc/loki/
sudo mkdir -p /etc/promtail/
sudo mkdir -p /loki/boltdb-shipper-active /loki/boltdb-shipper-cache /loki/chunks /loki/boltdb-shipper-compactor

# Create /var/lib/loki directory for Loki if it doesn't exist
echo "Creating /var/lib/loki directory..."
sudo mkdir -p /var/lib/loki
sudo chown -R loki:loki /var/lib/loki
sudo chmod 755 /var/lib/loki

# Create Netdata web_log config
echo "Configuring logs for Netdata..."
cat <<EOL | sudo tee $NETDATA_WEB_LOG_CONFIG >/dev/null
jobs:
  - name: apache_access
    path: $APACHE_ACCESS_LOG
    log_type: auto
  - name: apache_error
    path: $APACHE_ERROR_LOG
    log_type: auto
  - name: nginx_access
    path: $NGINX_ACCESS_LOG
    log_type: auto
  - name: nginx_error
    path: $NGINX_ERROR_LOG
    log_type: auto
  - name: laravel_error
    path: $LARAVEL_LOG
    log_type: auto
  - name: nodejs_error
    path: $NODE_LOG
    log_type: auto
EOL

echo "Netdata web_log.conf configured."

# Loki Configuration - overwrite existing config
echo "Configuring Loki for single-node deployment..."
cat <<EOL | sudo tee $LOKI_CONFIG >/dev/null
auth_enabled: false

server:
  http_listen_port: 3100

ingester:
  lifecycler:
    address: 127.0.0.1
    ring:
      kvstore:
        store: inmemory
      replication_factor: 1
    final_sleep: 0s
  chunk_idle_period: 5m
  chunk_retain_period: 30s

schema_config:
  configs:
    - from: 2020-05-15
      store: boltdb-shipper
      object_store: filesystem
      schema: v11
      index:
        prefix: index_
        period: 24h

storage_config:
  boltdb_shipper:
    active_index_directory: /loki/boltdb-shipper-active
    cache_location: /loki/boltdb-shipper-cache
    cache_ttl: 24h
  filesystem:
    directory: /loki/chunks

compactor:
  working_directory: /loki/boltdb-shipper-compactor

limits_config:
  reject_old_samples: true
  reject_old_samples_max_age: 168h
  allow_structured_metadata: false

EOL

echo "Loki configuration for single-node deployment complete."

# Promtail Configuration - overwrite existing config
echo "Configuring Promtail..."
cat <<EOL | sudo tee $PROMTAIL_CONFIG >/dev/null
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://localhost:3100/loki/api/v1/push

scrape_configs:
  - job_name: nginx_logs
    static_configs:
      - targets:
          - localhost
        labels:
          job: nginx
          __path__: /var/log/nginx/*.log

  - job_name: apache_logs
    static_configs:
      - targets:
          - localhost
        labels:
          job: apache
          __path__: /var/log/apache2/*.log

  - job_name: laravel_logs
    static_configs:
      - targets:
          - localhost
        labels:
          job: laravel
          __path__: $LARAVEL_LOG

  - job_name: nodejs_logs
    static_configs:
      - targets:
          - localhost
        labels:
          job: nodejs
          __path__: $NODE_LOG
EOL

echo "Promtail configuration complete."

# Ensure correct permissions on log files and Loki directories
echo "Setting permissions on log files and Loki directories..."
sudo chmod +r $APACHE_ERROR_LOG $APACHE_ACCESS_LOG $NGINX_ERROR_LOG $NGINX_ACCESS_LOG $LARAVEL_LOG $NODE_LOG 2>/dev/null
sudo chown -R loki:loki /loki /var/lib/loki

# Create Loki systemd service file
echo "Creating Loki systemd service file..."
cat <<EOL | sudo tee /etc/systemd/system/loki.service >/dev/null
[Unit]
Description=Loki Service
After=network.target

[Service]
ExecStart=/usr/local/bin/loki --config.file=/etc/loki/local-config.yaml --config.expand-env=true >> /var/log/loki.log 2>&1 &
Restart=always
User=loki
Group=loki
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOL

# Create Promtail systemd service file
echo "Creating Promtail systemd service file..."
cat <<EOL | sudo tee /etc/systemd/system/promtail.service >/dev/null
[Unit]
Description=Promtail Service
After=network.target

[Service]
ExecStart=/usr/local/bin/promtail --config.file=/etc/promtail/promtail.yaml
Restart=always
User=loki
Group=loki
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOL

# Create loki user and group if they don't exist
sudo groupadd -f loki
sudo useradd -g loki -s /sbin/nologin -M loki 2>/dev/null || true

# Reload systemd, enable and start Loki and Promtail services
sudo systemctl daemon-reload
sudo systemctl enable loki
sudo systemctl enable promtail

echo "Starting Loki and Promtail..."
sudo systemctl restart loki
sudo systemctl restart promtail

echo "Waiting for Loki and Promtail to initialize..."
sleep 10

# Check the status of Loki and Promtail services
echo "Checking Loki service status..."
sudo systemctl status loki

echo "Checking Promtail service status..."
sudo systemctl status promtail

# Verify that Loki is running
if pgrep -x "loki" >/dev/null; then
    echo "Loki is running."
else
    echo "Loki is not running. Starting it manually..."
    sudo /usr/local/bin/loki --config.file=/etc/loki/local-config.yaml &
    echo "Loki started manually. Please investigate why the service is not starting automatically."
fi

# Verify automatic start on boot
echo "Verifying automatic start on boot for Loki and Promtail..."

check_service_enabled() {
    if systemctl is-enabled $1 >/dev/null 2>&1; then
        echo "$1 is set to start automatically on boot."
    else
        echo "$1 is NOT set to start automatically on boot. Enabling now..."
        sudo systemctl enable $1
        echo "$1 has been enabled to start automatically on boot."
    fi
}

check_service_enabled loki
check_service_enabled promtail

echo "Setup complete. Loki and Promtail should now start automatically on boot."
echo "To verify after a reboot, you can run: 'sudo systemctl status loki' and 'sudo systemctl status promtail'"
