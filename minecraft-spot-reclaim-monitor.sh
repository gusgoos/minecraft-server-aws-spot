#!/bin/bash
# /usr/local/bin/minecraft-spot-reclaim-monitor.sh
set -euo pipefail

# ---------------- Configuration (REDACTED) ----------------
RCON_PASSWORD="REPLACE_WITH_RCON_PASSWORD"
RCON_PORT=25575
# ----------------------------------------------------------

echo "Spot Interruption Monitor Started..."

while true; do
  # Get IMDSv2 Token
  TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
  
  # Check for the instance-action (Reclaim)
  # 404 means everything is fine. 200 means termination is coming.
  HTTP_CODE=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" \
    -s -o /dev/null -w "%{http_code}" \
    http://169.254.169.254/latest/meta-data/spot/instance-action)

  if [ "$HTTP_CODE" -eq 200 ]; then
    echo "SPOT RECLAIM DETECTED! Starting emergency shutdown..."
    
    # 1. Warn Players
    mcrcon -H 127.0.0.1 -P "$RCON_PORT" -p "$RCON_PASSWORD" \
      "say [EMERGENCY] AWS is reclaiming this instance! Saving and shutting down in 15 seconds."
    sleep 15
    
    # 2. Force Save
    mcrcon -H 127.0.0.1 -P "$RCON_PORT" -p "$RCON_PASSWORD" "save-off"
    mcrcon -H 127.0.0.1 -P "$RCON_PORT" -p "$RCON_PASSWORD" "save-all flush"
    
    # 3. Trigger S3 backup script
    /usr/local/bin/minecraft-s3-backup.sh
    
    # 4. Final shutdown
    mcrcon -H 127.0.0.1 -P "$RCON_PORT" -p "$RCON_PASSWORD" "stop"
    shutdown -h now
    exit 0
  fi

  sleep 5
done
