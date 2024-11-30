#!/bin/bash

# Check if Nginx is installed
if ! command -v nginx &>/dev/null; then
    echo "Nginx is not installed. Aborting."
    exit 0
fi

# Function to detect if PHP-FPM is running (used for Laravel/PHP apps)
detect_php() {
    if command -v php >/dev/null; then
        php_version=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
        echo "Detected PHP version: $php_version"
        return 0
    elif pgrep -x "php-fpm" >/dev/null; then
        php_version=$(pgrep -a php-fpm | grep -Po 'php-fpm[\d.]+' | grep -o '[\d.]*' | head -n1)
        echo "Detected PHP-FPM version: $php_version"
        return 0
    else
        echo "PHP not detected."
        return 1
    fi
}

# Function to detect if Node.js is running and find the port
detect_node() {
    if pgrep -f "node" >/dev/null; then
        echo "Node.js application detected."
        return 0
    else
        echo "Node.js application not detected."
        return 1
    fi
}

# Function to search for valid server_name dynamically in all files
find_server_name_and_file() {
    local base_dir="$1"

    # Find all subdirectories and all files, including those without .conf extension
    for dir in $(find "$base_dir" -type d); do
        for conf_file in "$dir"/*; do # Handle all files, not just .conf
            if [ -f "$conf_file" ]; then
                # Extract the server_name line
                grep -Po '(?<=server_name\s)[^;]+' "$conf_file" 2>/dev/null | while read -r server_name; do
                    # Skip if server_name contains "example"
                    if [[ "$server_name" == *"example"* ]]; then
                        echo "Skipping server_name: $server_name in $conf_file because it contains 'example'"
                    else
                        # Valid server_name found, return the server_name and the file it's in
                        echo "$server_name $conf_file"
                        return 0
                    fi
                done
            fi
        done
    done

    return 1
}

# Function to find SSL certificates dynamically
find_ssl_certificates() {
    local conf_file="$1"
    ssl_cert=$(grep "ssl_certificate " "$conf_file" | sed 's/.*ssl_certificate\s\+//g' | tr -d ';' | head -n 1)
    ssl_key=$(grep "ssl_certificate_key " "$conf_file" | sed 's/.*ssl_certificate_key\s\+//g' | tr -d ';' | head -n 1)

    if [ -z "$ssl_cert" ] || [ -z "$ssl_key" ]; then
        echo "Error: Could not find SSL certificates in $conf_file."
        exit 1
    fi

    echo "Found SSL Certificate: $ssl_cert"
    echo "Found SSL Key: $ssl_key"
}

# Check if this is a RunCloud-managed server
if [ -d "/etc/nginx-rc/" ]; then
    echo "Detected RunCloud configuration."
    config_path="/etc/nginx-rc/conf.d"
    enabled_path="$config_path"
else
    echo "Detected standard Nginx configuration."
    config_path="/etc/nginx/sites-available"
    enabled_path="/etc/nginx/sites-enabled"
fi

# Find the valid server_name and the configuration file it belongs to
read valid_server_name config_file < <(find_server_name_and_file "$enabled_path")

# Check if a valid server_name was found
if [ -z "$valid_server_name" ] || [ -z "$config_file" ]; then
    echo "Error: Could not find a valid server_name in any configuration file."
    exit 1
fi

echo "Found valid server_name: $valid_server_name"
echo "Configuration file: $config_file"

# Find SSL certificates dynamically for the found server_name
find_ssl_certificates "$config_file"

# Detect if PHP or Node.js is running
if detect_php; then
    echo "Detected a PHP application (Laravel or similar)."
    php_fpm_socket="/var/run/php/php${php_version}-fpm.sock"

    # Prepare grafana configuration block
    grafana_config=$(
        cat <<EOL

    # grafana configuration
    location ~ /loki/ {
        proxy_pass http://localhost:3100/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # Disable buffering for real-time dashboard
        proxy_buffering off;
        proxy_redirect off;

        # Strip the /grafana/ prefix before passing to grafana
        rewrite ^/grafana/(.*) /\$1 break;

        # Increase timeouts for long-running requests
        proxy_read_timeout 600;
        proxy_connect_timeout 600;
    }
EOL
    )

elif detect_node && detect_node_port; then
    echo "Detected a Node.js application."

    # Prepare grafana configuration block
    grafana_config=$(
        cat <<EOL

    # grafana configuration
    location ~ /loki/ {
        proxy_pass http://localhost:3100/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # Disable buffering for real-time dashboard
        proxy_buffering off;
        proxy_redirect off;

        # Strip the /grafana/ prefix before passing to grafana
        rewrite ^/grafana/(.*) /\$1 break;

        # Increase timeouts for long-running requests
        proxy_read_timeout 600;
        proxy_connect_timeout 600;
    }
EOL
    )

else
    echo "No PHP or Node.js application detected. Exiting..."
    exit 1
fi

# Insert grafana block inside the last 'server' block before its closing '}'
# Look for 'server_name $valid_server_name' in the config file and append before the last '}'
awk -v grafana_block="$grafana_config" '
    /server_name.*'"$valid_server_name"'/ { in_server_block=1 }
    in_server_block && /}/ { in_server_block=0; print; print grafana_block; next }
    { print }
' "$config_file" >/tmp/updated_nginx_config && mv /tmp/updated_nginx_config "$config_file"

# Test Nginx configuration for errors
nginx -t

# Restart Nginx if the test passes
if [ $? -eq 0 ]; then
    systemctl restart nginx
    echo "grafana configuration appended inside the server block with proxy settings."
else
    echo "Nginx configuration test failed. Please check your Nginx configuration."
fi
