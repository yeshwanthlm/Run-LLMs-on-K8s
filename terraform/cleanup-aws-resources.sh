#!/bin/bash
# Emergency Cleanup Script for Orphaned AWS Resources
#
# ⚠️ THIS SCRIPT IS FOR EMERGENCY USE ONLY
#
# For fresh deployments, cleanup is AUTOMATIC via Terraform lifecycle hooks.
# Just run: terraform destroy
#
# Only use this script if:
# - You have orphaned resources from a previous failed cleanup
# - terraform destroy is failing with VPC/subnet dependency errors
# - You need to manually clean up an existing broken deployment
#
# Normal cleanup process:
# 1. kubectl delete -f ../k8s-manifests/inference.yaml
# 2. terraform destroy  (automatic cleanup runs!)

set -e

REGION="${AWS_REGION:-us-west-2}"
CLUSTER_NAME="${CLUSTER_NAME:-llm-eks}"

echo "========================================="
echo "AWS Kubernetes Resource Cleanup"
echo "========================================="
echo "Region: $REGION"
echo "Cluster: $CLUSTER_NAME"
echo ""

# Get VPC ID
VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || echo "")

if [ -z "$VPC_ID" ]; then
  echo "⚠️  Cluster not found or already deleted. Searching for orphaned resources..."
  # Try to find VPC by tag
  VPC_ID=$(aws ec2 describe-vpcs --region $REGION --filters "Name=tag:Name,Values=${CLUSTER_NAME}-vpc" --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "")
fi

if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
  echo "✓ No VPC found, nothing to clean up"
  exit 0
fi

echo "VPC ID: $VPC_ID"
echo ""

# Function to check if command succeeded
check_aws() {
  if [ $? -eq 0 ]; then
    echo "  ✓ Success"
  else
    echo "  ⚠️  Warning: command failed (continuing...)"
  fi
}

# 1. Delete all LoadBalancers in the VPC
echo "1. Cleaning up LoadBalancers..."
LB_ARNS=$(aws elbv2 describe-load-balancers --region $REGION \
  --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text 2>/dev/null || echo "")

if [ -n "$LB_ARNS" ]; then
  for ARN in $LB_ARNS; do
    LB_NAME=$(echo $ARN | rev | cut -d'/' -f1-2 | rev)
    echo "  Deleting LoadBalancer: $LB_NAME"
    aws elbv2 delete-load-balancer --load-balancer-arn $ARN --region $REGION 2>/dev/null || true
    check_aws
  done
  echo "  Waiting 30s for LoadBalancers to delete..."
  sleep 30
else
  echo "  ✓ No LoadBalancers found"
fi

# 2. Delete all Target Groups in the VPC
echo ""
echo "2. Cleaning up Target Groups..."
TG_ARNS=$(aws elbv2 describe-target-groups --region $REGION \
  --query "TargetGroups[?VpcId=='$VPC_ID'].TargetGroupArn" --output text 2>/dev/null || echo "")

if [ -n "$TG_ARNS" ]; then
  for ARN in $TG_ARNS; do
    TG_NAME=$(echo $ARN | rev | cut -d'/' -f1 | rev)
    echo "  Deleting Target Group: $TG_NAME"
    aws elbv2 delete-target-group --target-group-arn $ARN --region $REGION 2>/dev/null || true
    check_aws
  done
else
  echo "  ✓ No Target Groups found"
fi

# 3. Wait for ENIs to be released
echo ""
echo "3. Waiting for network interfaces to detach..."
sleep 45

# 4. Delete LoadBalancer Security Groups (created by AWS LB Controller)
echo ""
echo "4. Cleaning up LoadBalancer Security Groups..."
LB_SGS=$(aws ec2 describe-security-groups --region $REGION \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=k8s-*" \
  --query "SecurityGroups[].GroupId" --output text 2>/dev/null || echo "")

if [ -n "$LB_SGS" ]; then
  for SG_ID in $LB_SGS; do
    SG_NAME=$(aws ec2 describe-security-groups --group-ids $SG_ID --region $REGION --query 'SecurityGroups[0].GroupName' --output text 2>/dev/null)
    echo "  Deleting Security Group: $SG_NAME ($SG_ID)"
    aws ec2 delete-security-group --group-id $SG_ID --region $REGION 2>/dev/null || true
    check_aws
  done
else
  echo "  ✓ No LoadBalancer Security Groups found"
fi

# 5. Delete orphaned Network Interfaces
echo ""
echo "5. Cleaning up orphaned Network Interfaces..."
ENIS=$(aws ec2 describe-network-interfaces --region $REGION \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
  --query "NetworkInterfaces[].NetworkInterfaceId" --output text 2>/dev/null || echo "")

if [ -n "$ENIS" ]; then
  for ENI_ID in $ENIS; do
    echo "  Deleting ENI: $ENI_ID"
    aws ec2 delete-network-interface --network-interface-id $ENI_ID --region $REGION 2>/dev/null || true
    check_aws
  done
else
  echo "  ✓ No orphaned Network Interfaces found"
fi

# 6. Final check
echo ""
echo "6. Final verification..."
sleep 10

REMAINING_LBS=$(aws elbv2 describe-load-balancers --region $REGION \
  --query "LoadBalancers[?VpcId=='$VPC_ID'] | length(@)" --output text 2>/dev/null || echo "0")

REMAINING_ENIS=$(aws ec2 describe-network-interfaces --region $REGION \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
  --query "NetworkInterfaces | length(@)" --output text 2>/dev/null || echo "0")

echo ""
echo "========================================="
echo "Cleanup Summary"
echo "========================================="
echo "LoadBalancers remaining: $REMAINING_LBS"
echo "Orphaned ENIs remaining: $REMAINING_ENIS"
echo ""

if [ "$REMAINING_LBS" -eq 0 ] && [ "$REMAINING_ENIS" -eq 0 ]; then
  echo "✓ All resources cleaned up successfully!"
  echo ""
  echo "You can now safely run: terraform destroy"
  exit 0
else
  echo "⚠️  Some resources may still be deleting. Wait 30 seconds and run this script again."
  exit 1
fi
