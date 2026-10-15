#!/usr/bin/env bash
# Print the Artifactory URL. Fargate gives the task a NEW public IP every time
# it starts, so the address cannot be a Terraform output -- it is looked up.
set -euo pipefail
CL="${ECS_CLUSTER:-platform-lab}"
T=$(aws ecs list-tasks --cluster "$CL" --service-name artifactory --query 'taskArns[0]' --output text)
[[ "$T" == "None" || -z "$T" ]] && { echo "no running task yet" >&2; exit 1; }
ENI=$(aws ecs describe-tasks --cluster "$CL" --tasks "$T" \
  --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text)
IP=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI" \
  --query 'NetworkInterfaces[0].Association.PublicIp' --output text)
STATUS=$(aws ecs describe-tasks --cluster "$CL" --tasks "$T" --query 'tasks[0].lastStatus' --output text)
echo "http://$IP:8082   (task $STATUS; first login admin/password, forced change)"
