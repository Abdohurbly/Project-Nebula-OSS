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

# Function to detect the port Node.js is listening on
detect_node_port() {
    node_port=$(lsof -iTCP -sTCP:LISTEN -n -P | grep node | awk '{print $9}' | sed 's/.*://')

    if [ -n "$node_port" ]; then
        echo "Node.js is running on port $node_port"
        return 0
    else
        echo "Node.js port not detected."
        return 1
    fi
}

# Function to find fastcgi-php.conf or create it if missing
ensure_fastcgi_conf() {
    if [ "$1" == "runcloud" ]; then
        # Check for RunCloud's fastcgi-php.conf path
        if [ -f /etc/nginx-rc/snippets/fastcgi-php.conf ]; then
            echo "Using existing /etc/nginx-rc/snippets/fastcgi-php.conf for RunCloud"
        else
            echo "Creating /etc/nginx-rc/snippets/fastcgi-php.conf for RunCloud"
            mkdir -p /etc/nginx-rc/snippets
            cat <<EOL >/etc/nginx-rc/snippets/fastcgi-php.conf
# PHP-FPM settings for RunCloud
fastcgi_split_path_info ^(.+\.php)(/.+)$;
fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
fastcgi_param PATH_INFO \$fastcgi_path_info;
fastcgi_index index.php;
include fastcgi_params;
EOL
        fi
    else
        # Standard Nginx path
        if [ -f /etc/nginx/snippets/fastcgi-php.conf ]; then
            echo "Using existing /etc/nginx/snippets/fastcgi-php.conf for standard Nginx"
        else
            echo "Creating /etc/nginx/snippets/fastcgi-php.conf for standard Nginx"
            mkdir -p /etc/nginx/snippets
            cat <<EOL >/etc/nginx/snippets/fastcgi-php.conf
# PHP-FPM settings for standard Nginx
fastcgi_split_path_info ^(.+\.php)(/.+)$;
fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
fastcgi_param PATH_INFO \$fastcgi_path_info;
fastcgi_index index.php;
include fastcgi_params;
EOL
        fi
    fi
}

# Function to search for valid server_name dynamically in all files
find_server_name() {
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
                        # Valid server_name found, return it
                        echo "$server_name"
                        return 0
                    fi
                done
            fi
        done
    done

    return 1
}

# Function to find existing SSL certificates dynamically
find_ssl_certificates() {
    local server_name="$1"
    # Search for the certificate and key in typical RunCloud and standard Nginx paths
    ssl_cert=$(grep -r "ssl_certificate " /etc/nginx-rc/conf.d/ /etc/nginx/sites-enabled/ 2>/dev/null | grep "$server_name" | sed 's/.*ssl_certificate\s\+//g' | head -n 1)
    ssl_key=$(grep -r "ssl_certificate_key " /etc/nginx-rc/conf.d/ /etc/nginx/sites-enabled/ 2>/dev/null | grep "$server_name" | sed 's/.*ssl_certificate_key\s\+//g' | head -n 1)

    if [ -z "$ssl_cert" ] || [ -z "$ssl_key" ]; then
        echo "Error: Could not find SSL certificates for server_name: $server_name"
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
    snippet_path="/etc/nginx-rc/snippets/fastcgi-php.conf"
    setup_type="runcloud"
else
    echo "Detected standard Nginx configuration."
    config_path="/etc/nginx/sites-available"
    enabled_path="/etc/nginx/sites-enabled"
    snippet_path="/etc/nginx/snippets/fastcgi-php.conf"
    setup_type="standard"
fi

# Ensure that fastcgi-php.conf exists or create it based on the setup type
ensure_fastcgi_conf "$setup_type"

# Attempt to find a valid server_name
valid_server_name=$(find_server_name "$enabled_path")

# Check if a valid server_name was found
if [ -z "$valid_server_name" ]; then
    echo "Error: Could not find a valid server_name in any configuration file."
    exit 1
fi

# Find SSL certificates dynamically for the found server_name
find_ssl_certificates "$valid_server_name"

# Detect if PHP or Node.js is running
if detect_php; then
    echo "Generating Nginx configuration for PHP application..."

    if [ "$setup_type" == "runcloud" ]; then
        # Determine the PHP-FPM socket for RunCloud
        php_fpm_socket="/var/run/php/php${php_version}rc-fpm.sock"
    else
        # Determine the PHP-FPM socket for standard Nginx
        php_fpm_socket="/var/run/php/php${php_version}-fpm.sock"
    fi

    # Create a new configuration for Netdata and PHP using the valid server_name
    cat <<EOL >$config_path/netdata.conf
server {
    listen 443 ssl;
    server_name $valid_server_name;

    ssl_certificate $ssl_cert
    ssl_certificate_key $ssl_key

    location /netdata/ {
        # Restrict access to staging.thenebu.com
        valid_referers none blocked staging.thenebu.com https://staging.thenebu.com;

        if (\$invalid_referer) {
            return 403;  # Forbidden if the referer is invalid
        }

        proxy_pass http://localhost:19999/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 600;
        proxy_connect_timeout 600;

        proxy_redirect off;
        proxy_set_header X-Forwarded-Host \$server_name;
        proxy_set_header X-Forwarded-Server \$server_name;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include $snippet_path;  # Correct snippet path based on setup
        fastcgi_pass unix:${php_fpm_socket};  # Adjust PHP version dynamically
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL

elif detect_node && detect_node_port; then
    echo "Generating Nginx configuration for Node.js application..."

    # Create a new configuration for Netdata and Node.js using the valid server_name
    cat <<EOL >$config_path/netdata.conf
server {
    listen 443 ssl;
    server_name $valid_server_name;

    ssl_certificate $ssl_cert
    ssl_certificate_key $ssl_key

    location /netdata/ {
        # Restrict access to staging.thenebu.com
        valid_referers none blocked staging.thenebu.com https://staging.thenebu.com;

        if (\$invalid_referer) {
            return 403;  # Forbidden if the referer is invalid
        }

        proxy_pass http://localhost:19999/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 600;
        proxy_connect_timeout 600;

        proxy_redirect off;
        proxy_set_header X-Forwarded-Host \$server_name;
        proxy_set_header X-Forwarded-Server \$server_name;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        proxy_pass http://localhost:$node_port;  
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOL

else
    echo "No PHP or Node.js application detected. Exiting..."
    exit 1
fi

# Enable the new Netdata site
if [[ "$setup_type" == "runcloud" ]]; then
    if [ ! -f /etc/nginx-rc/conf.d/netdata.conf ]; then
        ln -s $config_path/netdata.conf /etc/nginx-rc/conf.d/netdata.conf
        echo "Netdata configuration created and enabled in RunCloud path at /netdata."
    else
        echo "Netdata configuration already exists in RunCloud path."
    fi
else
    if [ ! -f /etc/nginx/sites-enabled/netdata.conf ]; then
        ln -s $config_path/netdata.conf /etc/nginx/sites-enabled/netdata.conf
        echo "Netdata configuration created in standard Nginx path."
    else
        echo "Netdata configuration already exists in standard Nginx path."
    fi
fi

# Test Nginx configuration for errors
nginx -t

# Restart Nginx if the test passes
if [ $? -eq 0 ]; then
    systemctl restart nginx
    echo "Netdata configuration created and enabled with proxy settings."
else
    echo "Nginx configuration test failed."
fi
