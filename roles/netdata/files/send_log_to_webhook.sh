# /usr/libexec/netdata/plugins.d/send_log_to_webhook.sh
#!/bin/bash

WEBHOOK_URL="https://api.thenebu.com/api/webhook/netdata"
LOG_FILE=$1
JOB=$2

# Extract the last 10 lines of the log file (adjust as needed)
LOG_CONTENT=$(tail -n 10 "$LOG_FILE")

# Send log content to webhook
curl -X POST -H "Content-Type: application/json" -d "{\"job\":\"$JOB\", \"log_content\": \"$LOG_CONTENT\"}" "$WEBHOOK_URL"
