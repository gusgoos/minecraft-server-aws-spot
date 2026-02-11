#!/bin/bash
# REMOVED set -e to allow for custom retry logic

# 1. Configuration (REDACTED SAFE VALUES)
VOLUME_ID="vol-xxxxxxxxxxxxxxxxx"
ZONE_ID="ZXXXXXXXXXXXXXXX"
DOMAIN="example.com"
MOUNT_POINT="/minecraft"
JAR_NAME="fabric-server-launch.jar"
JAVA_HEAP="5G"

# Helper function for retries
retry() {
    local n=1
    local max=10
    local delay=5
    while true; do
        "$@" && break || {
            if [[ $n -lt $max ]]; then
                ((n++))
                echo "Command failed. Attempt $n/$max. Retrying in ${delay}s..."
                sleep $delay
            else
                echo "The command has failed after $n attempts."
                return 1
            fi
        }
    done
}

# 2. IMDSv2 Token and Public IP
echo "Retrieving Metadata..."
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

AWS_DEFAULT_REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)

export AWS_DEFAULT_REGION

# Get Public IP with retries
PUBLIC_IP=""
for i in {1..15}; do
    PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
      http://169.254.169.254/latest/meta-data/public-ipv4)
    [[ -n "$PUBLIC_IP" ]] && break
    sleep 2
done

# 3. Volume Attachment
echo "Attaching Volume..."
ATTACH_STATE=$(aws ec2 describe-volumes \
  --volume-ids "$VOLUME_ID" \
  --query 'Volumes[0].Attachments[0].State' \
  --output text)

if [ "$ATTACH_STATE" != "None" ] && [ "$ATTACH_STATE" != "null" ]; then
    aws ec2 detach-volume --volume-id "$VOLUME_ID" --force || true
    aws ec2 wait volume-available --volume-ids "$VOLUME_ID"
fi

retry aws ec2 attach-volume \
  --volume-id "$VOLUME_ID" \
  --instance-id "$INSTANCE_ID" \
  --device /dev/sdf

aws ec2 wait volume-in-use --volume-ids "$VOLUME_ID"

# 4. Identify Device (by Serial)
SEARCH_ID=$(echo "$VOLUME_ID" | tr -d '-')
DEVICE=""
for i in {1..20}; do
    DEVICE=$(lsblk -dpno NAME,SERIAL | grep "$SEARCH_ID" | awk '{print $1}')
    [[ -n "$DEVICE" ]] && break
    sleep 2
done

# 5. Safety Mount (NO FORMATTING)
mkdir -p "$MOUNT_POINT"
if ! mountpoint -q "$MOUNT_POINT"; then
    retry mount "$DEVICE" "$MOUNT_POINT"
fi

# 6. Route 53 Update
cat <<EOF > /tmp/route53.json
{
  "Comment": "Minecraft IP Update",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "$DOMAIN",
      "Type": "A",
      "TTL": 60,
      "ResourceRecords": [{"Value": "$PUBLIC_IP"}]
    }
  }]
}
EOF

echo "Updating Route 53 with IP: $PUBLIC_IP"

retry aws route53 change-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --change-batch file:///tmp/route53.json

# 7. Launch Server
cd "$MOUNT_POINT"
echo "Starting Minecraft server..."

if [ -f "$JAR_NAME" ]; then
    screen -dmS mc_server \
        java -Xms$JAVA_HEAP -Xmx$JAVA_HEAP \
        -XX:+UseG1GC \
        -XX:+ParallelRefProcEnabled \
        -XX:MaxGCPauseMillis=200 \
        -XX:+UnlockExperimentalVMOptions \
        -XX:+DisableExplicitGC \
        -XX:+AlwaysPreTouch \
        -XX:G1NewSizePercent=30 \
        -XX:G1MaxNewSizePercent=40 \
        -XX:G1HeapRegionSize=8M \
        -XX:G1ReservePercent=20 \
        -XX:G1HeapWastePercent=5 \
        -XX:G1MixedGCCountTarget=4 \
        -XX:InitiatingHeapOccupancyPercent=15 \
        -XX:G1MixedGCLiveThresholdPercent=90 \
        -XX:G1RSetUpdatingPauseTimePercent=5 \
        -XX:SurvivorRatio=32 \
        -XX:+PerfDisableSharedMem \
        -XX:MaxTenuringThreshold=1 \
        -Dusing.aikars.flags=https://mcflags.emc.gs \
        -Daikars.new.flags=true \
        -jar "$JAR_NAME" nogui
else
    echo "CRITICAL: $JAR_NAME not found in $MOUNT_POINT!"
fi

# 8. Cron Jobs (AMI baked-in scripts)

cat <<'EOF' > /etc/cron.d/minecraft-idle-shutdown
*/5 * * * * root /usr/local/bin/minecraft-idle-shutdown.sh
EOF
chmod 644 /etc/cron.d/minecraft-idle-shutdown

cat <<'EOF' > /etc/cron.d/minecraft-s3-backup
0 * * * * root /usr/local/bin/minecraft-s3-backup.sh
EOF
chmod 644 /etc/cron.d/minecraft-s3-backup

cat <<'EOF' > /etc/cron.d/minecraft-spot-reclaim-monitor
@reboot root /usr/local/bin/minecraft-spot-reclaim-monitor.sh
EOF
chmod 644 /etc/cron.d/minecraft-spot-reclaim-monitor
