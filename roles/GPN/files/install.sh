#!/bin/bash

# Variables
PROMETHEUS_VERSION="2.55.0"
NODE_EXPORTER_VERSION="1.8.2"
USER="prometheus"
PROMETHEUS_DIR="/etc/prometheus"
DATA_DIR="/var/lib/prometheus"
GRAFANA_USERNAME="admin"
GRAFANA_PASSWORD="admin"
GRAFANA_URL="http://localhost:3000"

# Update the system
sudo apt update -y
sudo apt upgrade -y

# Create a prometheus user and directories
sudo useradd --no-create-home --shell /bin/false $USER
sudo mkdir -p $PROMETHEUS_DIR $DATA_DIR
sudo chown $USER:$USER $DATA_DIR

# Download and install Prometheus
wget https://github.com/prometheus/prometheus/releases/download/v$PROMETHEUS_VERSION/prometheus-$PROMETHEUS_VERSION.linux-amd64.tar.gz
tar xvf prometheus-$PROMETHEUS_VERSION.linux-amd64.tar.gz
cd prometheus-$PROMETHEUS_VERSION.linux-amd64
sudo mv prometheus promtool /usr/local/bin/
sudo mv consoles console_libraries $PROMETHEUS_DIR
sudo mv prometheus.yml $PROMETHEUS_DIR/prometheus.yml
sudo chown -R $USER:$USER /usr/local/bin/prometheus /usr/local/bin/promtool $PROMETHEUS_DIR

# Configure Prometheus to scrape Node Exporter
cat <<EOF | sudo tee $PROMETHEUS_DIR/prometheus.yml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node_exporter'
    static_configs:
      - targets: ['localhost:9100']
EOF

# Create systemd service for Prometheus
cat <<EOF | sudo tee /etc/systemd/system/prometheus.service
[Unit]
Description=Prometheus Monitoring
Wants=network-online.target
After=network-online.target

[Service]
User=$USER
Group=$USER
Type=simple
ExecStart=/usr/local/bin/prometheus \\
    --config.file=$PROMETHEUS_DIR/prometheus.yml \\
    --storage.tsdb.path=$DATA_DIR

[Install]
WantedBy=multi-user.target
EOF

# Enable and start Prometheus
sudo systemctl daemon-reload
sudo systemctl enable prometheus
sudo systemctl start prometheus

# Download and install Node Exporter
cd ..
wget https://github.com/prometheus/node_exporter/releases/download/v$NODE_EXPORTER_VERSION/node_exporter-$NODE_EXPORTER_VERSION.linux-amd64.tar.gz
tar xvf node_exporter-$NODE_EXPORTER_VERSION.linux-amd64.tar.gz
sudo mv node_exporter-$NODE_EXPORTER_VERSION.linux-amd64/node_exporter /usr/local/bin/
sudo chown $USER:$USER /usr/local/bin/node_exporter

# Create systemd service for Node Exporter
cat <<EOF | sudo tee /etc/systemd/system/node_exporter.service
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=$USER
Group=$USER
Type=simple
ExecStart=/usr/local/bin/node_exporter

[Install]
WantedBy=multi-user.target
EOF

# Enable and start Node Exporter
sudo systemctl daemon-reload
sudo systemctl enable node_exporter
sudo systemctl start node_exporter

# Cleanup
rm -rf prometheus-$PROMETHEUS_VERSION.linux-amd64.tar.gz node_exporter-$NODE_EXPORTER_VERSION.linux-amd64.tar.gz prometheus-$PROMETHEUS_VERSION.linux-amd64 node_exporter-$NODE_EXPORTER_VERSION.linux-amd64

# Import Grafana Dashboard using basic auth
curl -X POST -H "Content-Type: application/json" -u "$GRAFANA_USERNAME:$GRAFANA_PASSWORD" \
    -d "{\"dashboard\": {\"id\": 1860}, \"overwrite\": true, \"inputs\": [], \"folderId\": 0}" \
    $GRAFANA_URL/api/dashboards/db

# Display status
echo "Prometheus and Node Exporter installation completed."
echo "Prometheus is running on port 9090"
echo "Node Exporter is running on port 9100"
echo "Grafana dashboard with ID 1860 has been imported."
