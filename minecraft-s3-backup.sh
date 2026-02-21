#!/bin/bash
# /usr/local/bin/minecraft-s3-backup.sh
set -euo pipefail

# ---------------- Configuration ----------------
S3_BUCKET="s3://bubucket"
MINECRAFT_PATH="/minecraft"
RCON_PASSWORD="password123"
RCON_PORT=25575
# ------------------------------------------------

# 1. Tell Minecraft to stop writing to disk temporarily
mcrcon -H 127.0.0.1 -P "$RCON_PORT" -p "$RCON_PASSWORD" "save-off"
mcrcon -H 127.0.0.1 -P "$RCON_PORT" -p "$RCON_PASSWORD" "save-all flush"

# 2. Sync to S3
if [ "$(ls -A $MINECRAFT_PATH)" ]; then
   aws s3 sync "$MINECRAFT_PATH" "$S3_BUCKET/hourly-backup/" --delete
fi
# 3. Turn saving back on
mcrcon -H 127.0.0.1 -P "$RCON_PORT" -p "$RCON_PASSWORD" "save-on"

echo "Backup to S3 completed at $(date)"
