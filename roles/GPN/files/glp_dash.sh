#!/bin/bash

# Variables
GRAFANA_URL="http://localhost:3000"
GRAFANA_USER="admin"
GRAFANA_PASS="admin"
LOKI_URL="http://localhost:3100"

# Add Loki as a data source using basic authentication
add_loki_datasource() {
    # Check if the Loki data source already exists
    local EXISTING_DS=$(curl -s -X GET "$GRAFANA_URL/api/datasources/name/Loki" \
        -H "Content-Type: application/json" \
        -u "$GRAFANA_USER:$GRAFANA_PASS")

    # If the data source exists, skip creation
    if [[ $EXISTING_DS == *'"id"'* ]]; then
        echo "Loki data source already exists."
    else
        # Create the Loki data source if not found
        local CREATE_DS=$(curl -s -X POST "$GRAFANA_URL/api/datasources" \
            -H "Content-Type: application/json" \
            -u "$GRAFANA_USER:$GRAFANA_PASS" \
            -d '{
            "name": "Loki",
            "type": "loki",
            "url": "'"$LOKI_URL"'",
            "access": "proxy",
            "basicAuth": false,
            "isDefault": true,
            "jsonData": {
                "maxLines": 1000
            }
        }')

        if [[ $CREATE_DS == *'"id"'* ]]; then
            echo "Loki data source created successfully."
        else
            echo "Failed to create Loki data source. Response: $CREATE_DS"
        fi
    fi
}

# Get the UID of the Loki data source
get_loki_uid() {
    LOKI_UID=$(curl -s -X GET "$GRAFANA_URL/api/datasources" \
        -H "Content-Type: application/json" \
        -u "$GRAFANA_USER:$GRAFANA_PASS" | jq -r '.[] | select(.name=="Loki") | .uid')
    echo "Retrieved Loki UID: $LOKI_UID"
}

# Create a dashboard with 4 panels in a 2x2 layout for raw logs using the dynamic UID
create_logs_dashboard() {
    curl -s -X POST "$GRAFANA_URL/api/dashboards/db" \
        -H "Content-Type: application/json" \
        -u $GRAFANA_USER:$GRAFANA_PASS \
        -d '{
        "dashboard": {
            "id": null,
            "title": "Logs Dashboard",
            "uid": "logs_dashboard",
            "timezone": "browser",
            "schemaVersion": 36,
            "version": 0,
            "refresh": "5s",
            "panels": [
                {
                    "id": 1,
                    "type": "logs",
                    "title": "Nginx Error Logs",
                    "datasource": {
                        "type": "loki",
                        "uid": "'"$LOKI_UID"'"
                    },
                    "gridPos": {
                        "h": 8,
                        "w": 12,
                        "x": 0,
                        "y": 0
                    },
                    "targets": [
                        {
                            "refId": "A",
                            "expr": "{job=\"nginx\"}",
                            "queryType": "range",
                            "datasource": {
                                "type": "loki",
                                "uid": "'"$LOKI_UID"'"
                            }
                        }
                    ],
                    "options": {
                        "showLabels": true,
                        "showTime": true,
                        "wrapLogMessage": true,
                        "prettifyLogMessage": true,
                        "enableLogDetails": true,
                        "dedupStrategy": "none",
                        "sortOrder": "Descending"
                    }
                },
                {
                    "id": 2,
                    "type": "logs",
                    "title": "Apache Error Logs",
                    "datasource": {
                        "type": "loki",
                        "uid": "'"$LOKI_UID"'"
                    },
                    "gridPos": {
                        "h": 8,
                        "w": 12,
                        "x": 12,
                        "y": 0
                    },
                    "targets": [
                        {
                            "refId": "A",
                            "expr": "{job=\"apache\"}",
                            "queryType": "range",
                            "datasource": {
                                "type": "loki",
                                "uid": "'"$LOKI_UID"'"
                            }
                        }
                    ],
                    "options": {
                        "showLabels": true,
                        "showTime": true,
                        "wrapLogMessage": true,
                        "prettifyLogMessage": true,
                        "enableLogDetails": true,
                        "dedupStrategy": "none",
                        "sortOrder": "Descending"
                    }
                },
                {
                    "id": 3,
                    "type": "logs",
                    "title": "MySQL Slow Queries",
                    "datasource": {
                        "type": "loki",
                        "uid": "'"$LOKI_UID"'"
                    },
                    "gridPos": {
                        "h": 8,
                        "w": 12,
                        "x": 0,
                        "y": 8
                    },
                    "targets": [
                        {
                            "refId": "A",
                            "expr": "{job=\"mysql_slow_queries\"}",
                            "queryType": "range",
                            "datasource": {
                                "type": "loki",
                                "uid": "'"$LOKI_UID"'"
                            }
                        }
                    ],
                    "options": {
                        "showLabels": true,
                        "showTime": true,
                        "wrapLogMessage": true,
                        "prettifyLogMessage": true,
                        "enableLogDetails": true,
                        "dedupStrategy": "none",
                        "sortOrder": "Descending"
                    }
                },
                {
                    "id": 4,
                    "type": "logs",
                    "title": "General System Logs",
                    "datasource": {
                        "type": "loki",
                        "uid": "'"$LOKI_UID"'"
                    },
                    "gridPos": {
                        "h": 8,
                        "w": 12,
                        "x": 12,
                        "y": 8
                    },
                    "targets": [
                        {
                            "refId": "A",
                            "expr": "{job=\"general_logs\"}",
                            "queryType": "range",
                            "datasource": {
                                "type": "loki",
                                "uid": "'"$LOKI_UID"'"
                            }
                        }
                    ],
                    "options": {
                        "showLabels": true,
                        "showTime": true,
                        "wrapLogMessage": true,
                        "prettifyLogMessage": true,
                        "enableLogDetails": true,
                        "dedupStrategy": "none",
                        "sortOrder": "Descending"
                    }
                }
            ],
            "time": {
                "from": "now-6h",
                "to": "now"
            },
            "timepicker": {
                "refresh_intervals": [
                    "5s",
                    "10s",
                    "30s",
                    "1m",
                    "5m",
                    "15m",
                    "30m",
                    "1h",
                    "2h",
                    "1d"
                ]
            }
        },
        "overwrite": true,
        "message": "Updated dashboard"
    }'
}

# Main execution
echo "Setting up Loki datasource..."
add_loki_datasource

echo "Retrieving Loki UID..."
get_loki_uid

echo "Creating dashboard..."
create_logs_dashboard
