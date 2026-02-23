import boto3
import os
import logging

# Set up logging for better visibility in CloudWatch
logger = logging.getLogger()
logger.setLevel(logging.INFO)

def lambda_handler(event, context):
    """
    Triggers an Auto Scaling Group scale-up based on an external event.
    """
    
    # 1. Configuration via Environment Variables
    # Use os.environ to keep resource names out of the source code
    asg_name = os.environ.get('ASG_NAME', 'my-scaling-group')
    
    # 2. Retrieve identity from the event payload
    # Defaults to 'System' if no user is provided
    trigger_user = event.get('user', 'System')
    logger.info(f"Scale-up request initiated by: {trigger_user}")

    client = boto3.client('autoscaling')
    
    try:
        # 3. Check current state of the ASG
        response = client.describe_auto_scaling_groups(AutoScalingGroupNames=[asg_name])
        
        if not response['AutoScalingGroups']:
            logger.error(f"ASG '{asg_name}' not found.")
            return {"statusCode": 404, "body": "Resource not found"}

        asg = response['AutoScalingGroups'][0]
        current_capacity = asg['DesiredCapacity']
        
        # 4. Logic Gate: Only scale up if currently at 0
        if current_capacity > 0:
            logger.info(f"Resource '{asg_name}' is already active. No action taken.")
            return {
                "statusCode": 200, 
                "body": f"Resource already active (Capacity: {current_capacity})"
            }

        # 5. Execute Scale-up
        logger.info(f"Updating DesiredCapacity to 1 for ASG: {asg_name}")
        client.update_auto_scaling_group(
            AutoScalingGroupName=asg_name,
            DesiredCapacity=1
        )
        
        return {
            "statusCode": 200, 
            "body": f"Resource successfully started by {trigger_user}"
        }

    except Exception as e:
        logger.error(f"Error updating ASG: {str(e)}")
        return {"statusCode": 500, "body": "Internal Server Error"}
