# Automatic cleanup of Kubernetes-created AWS resources
# This runs automatically during terraform destroy - NO manual script needed

resource "null_resource" "cleanup_kubernetes_resources" {
  triggers = {
    cluster_name = var.cluster_name
    region       = var.aws_region
    vpc_id       = module.vpc.vpc_id
    always_run   = timestamp()
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -e

      echo "=============================================="
      echo "Automatic Cleanup of Kubernetes AWS Resources"
      echo "=============================================="
      echo "Cluster: ${self.triggers.cluster_name}"
      echo "Region: ${self.triggers.region}"
      echo "VPC: ${self.triggers.vpc_id}"
      echo ""

      # Step 1: Delete LoadBalancers
      echo "1. Removing LoadBalancers..."
      LB_ARNS=$(aws elbv2 describe-load-balancers \
        --region ${self.triggers.region} \
        --query "LoadBalancers[?VpcId=='${self.triggers.vpc_id}'].LoadBalancerArn" \
        --output text 2>/dev/null || echo "")

      if [ -n "$LB_ARNS" ]; then
        for ARN in $LB_ARNS; do
          echo "  - Deleting: $(echo $ARN | rev | cut -d/ -f1-2 | rev)"
          aws elbv2 delete-load-balancer --load-balancer-arn $ARN --region ${self.triggers.region} 2>/dev/null || true
        done
        echo "  - Waiting 30s for LoadBalancer deletion..."
        sleep 30
      else
        echo "  - No LoadBalancers found"
      fi

      # Step 2: Delete Target Groups
      echo ""
      echo "2. Removing Target Groups..."
      TG_ARNS=$(aws elbv2 describe-target-groups \
        --region ${self.triggers.region} \
        --query "TargetGroups[?VpcId=='${self.triggers.vpc_id}'].TargetGroupArn" \
        --output text 2>/dev/null || echo "")

      if [ -n "$TG_ARNS" ]; then
        for ARN in $TG_ARNS; do
          echo "  - Deleting: $(echo $ARN | rev | cut -d/ -f1 | rev)"
          aws elbv2 delete-target-group --target-group-arn $ARN --region ${self.triggers.region} 2>/dev/null || true
        done
      else
        echo "  - No Target Groups found"
      fi

      # Step 3: Wait for ENIs to detach
      echo ""
      echo "3. Waiting 45s for network interfaces to detach..."
      sleep 45

      # Step 4: Delete LoadBalancer Security Groups
      echo ""
      echo "4. Removing LoadBalancer Security Groups..."
      LB_SGS=$(aws ec2 describe-security-groups \
        --region ${self.triggers.region} \
        --filters "Name=vpc-id,Values=${self.triggers.vpc_id}" "Name=group-name,Values=k8s-*" \
        --query "SecurityGroups[].GroupId" \
        --output text 2>/dev/null || echo "")

      if [ -n "$LB_SGS" ]; then
        for SG_ID in $LB_SGS; do
          echo "  - Deleting: $SG_ID"
          aws ec2 delete-security-group --group-id $SG_ID --region ${self.triggers.region} 2>/dev/null || true
        done
      else
        echo "  - No LoadBalancer Security Groups found"
      fi

      # Step 5: Delete orphaned ENIs
      echo ""
      echo "5. Removing orphaned Network Interfaces..."
      sleep 15

      ENIS=$(aws ec2 describe-network-interfaces \
        --region ${self.triggers.region} \
        --filters "Name=vpc-id,Values=${self.triggers.vpc_id}" "Name=status,Values=available" \
        --query "NetworkInterfaces[].NetworkInterfaceId" \
        --output text 2>/dev/null || echo "")

      if [ -n "$ENIS" ]; then
        for ENI_ID in $ENIS; do
          echo "  - Deleting: $ENI_ID"
          aws ec2 delete-network-interface --network-interface-id $ENI_ID --region ${self.triggers.region} 2>/dev/null || true
        done
      else
        echo "  - No orphaned ENIs found"
      fi

      echo ""
      echo "=============================================="
      echo "Cleanup Complete - Terraform destroy can proceed"
      echo "=============================================="
    EOT
  }

  depends_on = [
    module.eks,
    helm_release.aws_load_balancer_controller,
    module.vpc
  ]
}
