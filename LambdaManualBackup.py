import boto3
import base64
import os

# Initialize clients
ec2 = boto3.client('ec2')
asg = boto3.client('autoscaling')

def lambda_handler(event, context):
    # --- 1. Load Configuration from Environment Variables ---
    # These should be set in the Lambda 'Configuration' tab in AWS Console
    ASG_NAME = os.environ.get('ASG_NAME', 'MinecraftServer-ASG')
    VOLUME_ID = os.environ.get('VOLUME_ID')
    S3_BUCKET = os.environ.get('S3_BUCKET')
    AMI_ID = os.environ.get('AMI_ID')
    INSTANCE_TYPE = os.environ.get('INSTANCE_TYPE', 't4g.small')
    IAM_ROLE = os.environ.get('IAM_ROLE_NAME')
    SECURITY_GROUP = os.environ.get('SECURITY_GROUP_ID')
    AZ = os.environ.get('AVAILABILITY_ZONE')

    # --- 2. Safety Check: Is the main server off? ---
    response = asg.describe_auto_scaling_groups(AutoScalingGroupNames=[ASG_NAME])
    if not response['AutoScalingGroups']:
        return {"status": "error", "message": f"ASG {ASG_NAME} not found."}
        
    desired_capacity = response['AutoScalingGroups'][0]['DesiredCapacity']
    
    if desired_capacity > 0:
        return {
            "status": "error", 
            "message": "Server ASG is active. Shutdown the server before running backup worker."
        }

    # --- 3. UserData Script (Injected with Variables) ---
    # We use an f-string to pass the Python variables into the Bash script
    user_data_script = f"""#!/bin/bash
VOLUME_ID="{VOLUME_ID}"
MOUNT_POINT="/minecraft"
S3_BUCKET="{S3_BUCKET}"

# Get Instance Metadata (IMDSv2)
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
export AWS_DEFAULT_REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)

# Ensure volume is available
ATTACH_STATE=$(aws ec2 describe-volumes --volume-ids "$VOLUME_ID" --query 'Volumes[0].Attachments[0].State' --output text)
if [ "$ATTACH_STATE" != "None" ] && [ "$ATTACH_STATE" != "null" ]; then
    aws ec2 detach-volume --volume-id "$VOLUME_ID" --force
    aws ec2 wait volume-available --volume-ids "$VOLUME_ID"
fi

# Attach EBS Volume
aws ec2 attach-volume --volume-id "$VOLUME_ID" --instance-id "$INSTANCE_ID" --device /dev/sdf
aws ec2 wait volume-in-use --volume-ids "$VOLUME_ID"

# Detect NVMe Device (Wait up to 40s)
DEVICE=""
for i in {{1..20}}; do
    ROOT_SOURCE=$(findmnt -n -o SOURCE /)
    ROOT_PARENT=$(lsblk -no PKNAME "$ROOT_SOURCE" 2>/dev/null)
    ROOT_DISK="/dev/${{ROOT_PARENT:-$(basename "$ROOT_SOURCE")}}"

    for dev in /dev/nvme*n1; do
        [[ "$dev" == "$ROOT_DISK" ]] && continue
        DEVICE="$dev"
        break
    done
    [[ -b "$DEVICE" ]] && break
    sleep 2
done

if [[ -z "$DEVICE" ]]; then
    echo "ERROR: EBS device not found"
    exit 1
fi

# Mount and Sync
mkdir -p "$MOUNT_POINT"
mount "$DEVICE" "$MOUNT_POINT"
TIMESTAMP=$(date +%Y-%m-%d-%H-%M-%S)
aws s3 sync "$MOUNT_POINT" "$S3_BUCKET/manual-backup-$TIMESTAMP"

# Cleanup
umount "$MOUNT_POINT"
aws ec2 detach-volume --volume-id "$VOLUME_ID"
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"
"""

    # --- 4. Launch the Worker ---
    instance = ec2.run_instances(
        ImageId=AMI_ID,
        InstanceType=INSTANCE_TYPE,
        MaxCount=1,
        MinCount=1,
        UserData=user_data_script,
        InstanceInitiatedShutdownBehavior='terminate',
        IamInstanceProfile={{'Name': IAM_ROLE}},
        SecurityGroupIds=[SECURITY_GROUP],
        Placement={{'AvailabilityZone': AZ}}
    )

    return {{
        "status": "success",
        "instance_id": instance['Instances'][0]['InstanceId']
    }}
