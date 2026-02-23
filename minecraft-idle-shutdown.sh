#!/bin/bash
# /usr/local/bin/minecraft-idle-shutdown.sh
set -euo pipefail

# ---------------- Configuration ----------------
# It is recommended to set these in a separate environment file or 
# as variables in your CI/CD pipeline.
RCON_PASSWORD="${RCON_PASSWORD:-your_secure_password_here}"
RCON_PORT=${RCON_PORT:-25575}
ASG_NAME="${ASG_NAME:-your-asg-name-here}"

CHECK_INTERVAL_MIN=5
THRESHOLD=3   # 3 checks * 5 minutes = 15 minutes

STATE_DIR="/var/lib/minecraft-manager"
COUNTER_FILE="$STATE_DIR/idle_counter"
LOCK_FILE="$STATE_DIR/idle_counter.lock"

export PATH=/usr/local/bin:/usr/bin:/bin
# ------------------------------------------------

mkdir -p "$STATE_DIR"

# ---- lock to avoid race conditions (cron overlap) ----
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

# ---- get player count safely ----
# Connects to the local server via mcrcon
RAW_LIST="$(mcrcon -H 127.0.0.1 -P "$RCON_PORT" -p "$RCON_PASSWORD" "list" 2>/dev/null || true)"

# Extracts current player count (e.g., from "There are 2 of a max of 20 players online")
PLAYER_COUNT=$(echo "$RAW_LIST" | grep -oP '\d+(?=\s+of)' | head -n1 || echo 0)

# If parsing failed or result isn't a number, exit to prevent accidental shutdown
if ! [[ "$PLAYER_COUNT" =~ ^[0-9]+$ ]]; then
  exit 0
fi

# ---- update idle counter ----
VAL="$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)"

if [ "$PLAYER_COUNT" -eq 0 ]; then
  VAL=$((VAL + 1))
  echo "$VAL" > "$COUNTER_FILE"
else
  # Reset counter if players are online
  echo 0 > "$COUNTER_FILE"
  exit 0
fi

# ---- threshold reached ----
if [ "$VAL" -lt "$THRESHOLD" ]; then
  exit 0
fi

# ---- notify + safe world save ----
mcrcon -H 127.0.0.1 -P "$RCON_PORT" -p "$RCON_PASSWORD" \
  "say No players detected for $((THRESHOLD * CHECK_INTERVAL_MIN)) minutes. Server shutting down."

mcrcon -H 127.0.0.1 -P "$RCON_PORT" -p "$RCON_PASSWORD" "save-off"
mcrcon -H 127.0.0.1 -P "$RCON_PORT" -p "$RCON_PASSWORD" "save-all flush"
sleep 10
mcrcon -H 127.0.0.1 -P "$RCON_PORT" -p "$RCON_PASSWORD" "save-on"

# ---- AWS metadata (IMDSv2) ----
TOKEN="$(curl -s -X PUT http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')"

REGION="$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)"

# --- reset idle counter before shutdown ----
echo 0 > "$COUNTER_FILE"

# ---- scale ASG to zero ----
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name "$ASG_NAME" \
  --desired-capacity 0 \
  --region "$REGION" || true

# ---- shutdown instance ----
shutdown -h now
