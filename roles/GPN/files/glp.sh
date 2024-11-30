#!/bin/bash

# Default paths (configurable at the start)
LOKI_INSTALL_DIR="/opt/loki"
PROMTAIL_INSTALL_DIR="/usr/local/bin"
PROMTAIL_DATA_DIR="/var/lib/promtail"
LOKI_CONFIG_FILE="$LOKI_INSTALL_DIR/loki-local-config.yaml"
PROMTAIL_CONFIG_FILE="/etc/promtail-local-config.yaml"
LOG_DIRECTORY="/var/log" # Directory to scan for logs

# Improved error handling function
handle_error() {
  local exit_code=$?
  local line_no=$1
  if [ $exit_code -ne 0 ]; then
    echo "Error occurred in script at line: $line_no"
    echo "Exit code: $exit_code"
    exit $exit_code
  fi
}
trap 'handle_error ${LINENO}' ERR

# Retry download function
download_with_retries() {
  local url=$1
  local output=$2
  local retries=5
  local delay=5

  for ((i = 1; i <= retries; i++)); do
    wget -qO "$output" "$url" && return 0
    echo "Download failed: Attempt $i/$retries. Retrying in $delay seconds..."
    sleep "$delay"
  done
  echo "Download failed after $retries attempts."
  return 1
}

# Function to enable MySQL slow query logging if it's not enabled
enable_mysql_slow_query_log() {
  if command -v mysql &>/dev/null; then
    # MySQL config file path (adjust based on your setup)
    local mysql_conf="/etc/mysql/mysql.conf.d/mysqld.cnf"

    if [ -f "$mysql_conf" ]; then
      if ! grep -q "^slow_query_log = 1" "$mysql_conf"; then
        echo "Enabling MySQL slow query logging..."
        echo -e "\n[mysqld]\nslow_query_log = 1\nslow_query_log_file = /var/log/mysql/slow.log\nlong_query_time = 1" | sudo tee -a "$mysql_conf" >/dev/null
        
        sudo chown mysql:mysql /var/log/mysql/slow.log
        sudo chmod 664 /var/log/mysql/slow.log
        
        echo "MySQL slow query logging has been enabled."
        sudo systemctl restart mysql

      else
        sudo chown mysql:mysql /var/log/mysql/slow.log
        sudo chmod 664 /var/log/mysql/slow.log
        sudo systemctl restart mysql
        echo "MySQL slow query logging is already enabled."
      fi
    else
      echo "MySQL configuration file not found at $mysql_conf."
    fi
  else
    echo "MySQL is not installed on this system."
  fi
}

# Check if a specific job exists in Promtail configuration
job_exists_in_promtail() {
  local job_name=$1
  grep -q "job_name: ${job_name}" "$PROMTAIL_CONFIG_FILE"
}

# Update system packages
echo "Updating system packages..."
sudo apt-get update -y
sudo apt-get install unzip curl lsof -y

# Install Loki
echo "Installing Loki..."
LOKI_VERSION=$(curl -s "https://api.github.com/repos/grafana/loki/releases/latest" | grep -Po '"tag_name": "v\K[0-9.]+')
LOKI_URL="https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/loki-linux-amd64.zip"

# Create installation directory
sudo mkdir -p "$LOKI_INSTALL_DIR"

# Download Loki with retry logic
download_with_retries "$LOKI_URL" "$LOKI_INSTALL_DIR/loki.gz"

# Install Loki
sudo gzip -df "$LOKI_INSTALL_DIR/loki.gz"
sudo chmod +x "$LOKI_INSTALL_DIR/loki"
[[ ! -L /usr/local/bin/loki ]] && sudo ln -s "$LOKI_INSTALL_DIR/loki" /usr/local/bin/loki

# Install Promtail
echo "Installing Promtail..."
PROMTAIL_VERSION=$(curl -s "https://api.github.com/repos/grafana/loki/releases/latest" | grep -Po '"tag_name": "v\K[0-9.]+')
PROMTAIL_URL="https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/promtail-linux-amd64.zip"

TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"
download_with_retries "$PROMTAIL_URL" "promtail-linux-amd64.zip"

# Install Promtail
sudo unzip promtail-linux-amd64.zip
sudo mv promtail-linux-amd64 "$PROMTAIL_INSTALL_DIR/promtail"
sudo chmod a+x "$PROMTAIL_INSTALL_DIR/promtail"
cd - >/dev/null
rm -rf "$TEMP_DIR"

# Create a Promtail user if it doesn't exist
if ! id -u promtail &>/dev/null; then
  sudo useradd -r -s /bin/false promtail
fi

# Create systemd service for Loki
sudo bash -c "cat > /etc/systemd/system/loki.service <<EOL
[Unit]
Description=Loki log aggregation system
After=network.target

[Service]
ExecStart=$LOKI_INSTALL_DIR/loki -config.file=$LOKI_CONFIG_FILE
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOL"

# Start and enable Loki service
sudo systemctl daemon-reload
sudo systemctl start loki
sudo systemctl enable loki

# Wait for Loki to be ready with timeout
echo "Waiting for Loki to be ready..."
TIMEOUT=60
start_time=$(date +%s)
while true; do
  if [[ $(curl -s http://localhost:3100/ready) == "ready" ]]; then
    echo "Loki is ready!"
    break
  fi

  current_time=$(date +%s)
  if ((current_time - start_time >= TIMEOUT)); then
    echo "Timeout waiting for Loki to be ready"
    exit 1
  fi

  echo "Loki is not ready yet. Retrying in 5 seconds..."
  sleep 5
done

# Configure Promtail with improved dynamic configuration
configure_promtail() {
  local config_file="$PROMTAIL_CONFIG_FILE"

  # Backup existing config if it exists
  if [ -f "$config_file" ]; then
    sudo cp "$config_file" "${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
  fi

  # Base configuration
  sudo bash -c "cat > $config_file <<EOL
server:
  http_listen_port: 9081
  grpc_listen_port: 0

positions:
  filename: $PROMTAIL_DATA_DIR/positions.yaml

clients:
  - url: http://localhost:3100/loki/api/v1/push

scrape_configs:
EOL"

  # Function to add log configuration for each file
  add_log_config() {
    local job_name=$1
    local log_path=$2

    echo "  - job_name: ${job_name}" | sudo tee -a "$config_file"
    echo "    static_configs:" | sudo tee -a "$config_file"
    echo "      - targets: ['localhost']" | sudo tee -a "$config_file"
    echo "        labels:" | sudo tee -a "$config_file"
    echo "          job: ${job_name}" | sudo tee -a "$config_file"
    echo "          __path__: ${log_path}" | sudo tee -a "$config_file"
  }

  # Detect log files in specified log directory with service-specific naming
  for log_file in "$LOG_DIRECTORY"/*.log "$LOG_DIRECTORY"/*/*.log; do
    if [ -f "$log_file" ]; then
      # Extract directory and file name for descriptive job name
      service_name=$(basename "$(dirname "$log_file")")
      log_filename=$(basename "$log_file" .log)
      job_name="${service_name}_${log_filename}_log"
      add_log_config "$job_name" "$log_file"
    fi
  done

  # Enable MySQL slow logging if MySQL is installed and configure it in Promtail
  enable_mysql_slow_query_log # Ensure MySQL slow logging is enabled
  mysql_error_log="/var/log/mysql/error.log"
  mysql_slow_log="/var/log/mysql/slow.log"

  # Add MySQL logs only if not already configured in Promtail
  if ! job_exists_in_promtail "mysql_error_log" && [ -f "$mysql_error_log" ]; then
    add_log_config "mysql_error_log" "$mysql_error_log"
  fi
  if ! job_exists_in_promtail "mysql_slow_log" && [ -f "$mysql_slow_log" ]; then
    add_log_config "mysql_slow_log" "$mysql_slow_log"
  fi
}

# Create systemd service for Promtail
sudo bash -c "cat > /etc/systemd/system/promtail.service <<EOL
[Unit]
Description=Promtail log shipping system
After=network.target

[Service]
ExecStart=$PROMTAIL_INSTALL_DIR/promtail -config.file=$PROMTAIL_CONFIG_FILE
Restart=always
User=promtail
Group=promtail
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOL"

# Configure Promtail directory and permissions
sudo mkdir -p "$PROMTAIL_DATA_DIR"
sudo chmod 755 "$PROMTAIL_DATA_DIR"
sudo chown promtail:promtail "$PROMTAIL_DATA_DIR"

# Call configure_promtail and start service
configure_promtail
sudo systemctl daemon-reload
sudo systemctl start promtail
sudo systemctl enable promtail

# Verify services are running
echo "Verifying services..."
for service in loki promtail; do
  if ! sudo systemctl is-active --quiet $service; then
    echo "Warning: $service is not running"
    sudo systemctl status $service --no-pager
  else
    echo "$service is running correctly"
  fi
done

echo "Installation and configuration complete!"
echo "Loki endpoint: http://localhost:3100"
echo "Promtail endpoint: http://localhost:9081"

# Log summary
echo -e "\nLog sources configured:"
grep -r "job_name:" "$PROMTAIL_CONFIG_FILE" | cut -d':' -f2-

# Final status check
echo -e "\nFinal status check:"
for service in loki promtail; do
  echo "=== $service status ==="
  sudo systemctl status $service --no-pager || true
done
