# EKS Cluster Terraform Configuration

Production-ready AWS EKS cluster for running LLM inference workloads.

## What Gets Created

- **VPC** with public/private subnets across 3 availability zones
- **EKS Cluster** (Kubernetes 1.31)
- **Managed Node Group** with t3.xlarge instances (2 nodes)
- **AWS EBS CSI Driver** for persistent volumes
- **AWS Load Balancer Controller** for managing LoadBalancers
- **Security groups** configured for LLM service access
- **Default StorageClass** (gp2) configured

## Prerequisites

1. **AWS CLI** configured with credentials
   ```bash
   aws configure
   ```

2. **Terraform** >= 1.3
   ```bash
   terraform version
   ```

3. **kubectl** for Kubernetes access
   ```bash
   kubectl version --client
   ```

4. **Required AWS Permissions**:
   - VPC, Subnets, Internet/NAT Gateways
   - EKS Clusters, Node Groups
   - IAM Roles and Policies
   - Security Groups, EC2 Instances

## Configuration

### Default Values

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `us-west-2` | AWS region |
| `cluster_name` | `llm-eks` | EKS cluster name |
| `cluster_version` | `1.31` | Kubernetes version |
| `instance_types` | `["t3.xlarge"]` | Node instance types |
| `desired_size` | `2` | Desired node count |
| `min_size` | `1` | Minimum node count |
| `max_size` | `3` | Maximum node count |

### Customize Values

Create `terraform.tfvars`:

```hcl
aws_region     = "us-east-1"
cluster_name   = "my-llm-cluster"
instance_types = ["t3.2xlarge"]
desired_size   = 3
```

## Deployment

### 1. Initialize

```bash
cd terraform
terraform init
```

### 2. Review Plan

```bash
terraform plan
```

### 3. Deploy

```bash
terraform apply
```

Type `yes` when prompted. **Deployment takes 15-20 minutes.**

### 4. Configure kubectl

```bash
aws eks update-kubeconfig --region us-west-2 --name llm-eks
```

Or use the output command:
```bash
terraform output -raw configure_kubectl | bash
```

### 5. Verify Cluster

```bash
# Check nodes
kubectl get nodes

# Verify EBS CSI driver
kubectl get pods -n kube-system | grep ebs-csi

# Verify Load Balancer Controller
kubectl get pods -n kube-system | grep aws-load-balancer

# Check default StorageClass
kubectl get storageclass
```

Expected output:
```
NAME            PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
gp2 (default)   kubernetes.io/aws-ebs   Delete          WaitForFirstConsumer
```

## What's Configured Automatically

### ✅ EBS CSI Driver

Enables persistent volumes using Amazon EBS:
- Automatically installed as EKS addon
- IAM role with required permissions
- Service account configured

### ✅ AWS Load Balancer Controller

Manages AWS Load Balancers for Kubernetes services:
- Helm chart auto-installed
- IAM role for service account (IRSA)
- Creates internet-facing NLBs for LoadBalancer services

### ✅ Default StorageClass

Sets `gp2` as default for PersistentVolumeClaims:
- No need to specify storageClassName in manifests
- Uses GP2 SSD volumes
- WaitForFirstConsumer binding mode

### ✅ Security Groups

Pre-configured for LLM inference on port 8080:
- Ingress rule allowing VPC traffic to port 8080
- Applied to cluster security group
- Enables LoadBalancer → Pod communication

## Deployed Components

### Network Load Balancer Controller

- **Purpose**: Manages AWS NLBs for Kubernetes LoadBalancer services
- **Namespace**: `kube-system`
- **Service Account**: `aws-load-balancer-controller`
- **Features**:
  - Automatic NLB creation/deletion
  - Target group management
  - Health check configuration
  - IP mode support (required for EKS)

### EBS CSI Driver

- **Purpose**: Provisions EBS volumes for PVCs
- **Namespace**: `kube-system`
- **Components**:
  - Controller (2 replicas)
  - Node agents (DaemonSet)
- **Storage Classes**: gp2 (default), gp3, io1, io2, sc1, st1

## Cost Estimate

**~$150-200 USD/month** (us-west-2 region):

| Resource | Monthly Cost |
|----------|--------------|
| EKS Cluster | $73 |
| 2x t3.xlarge (4 vCPU, 16GB) | $120 |
| NAT Gateway | $33 |
| EBS Volumes | $10-20 |
| Data Transfer | Variable |

### Cost Optimization

**Use Spot Instances:**
```hcl
# In terraform.tfvars
capacity_type = "SPOT"
```
Savings: ~70%

**Scale Down When Idle:**
```bash
# Via Terraform
terraform apply -var="desired_size=0"

# Or via kubectl
kubectl scale deployment --all --replicas=0
```

**Use Smaller Instances:**
```hcl
instance_types = ["t3.medium"]  # For testing only
```

## Outputs

After successful deployment:

```bash
# Cluster name
terraform output cluster_name

# API endpoint
terraform output cluster_endpoint

# kubectl configuration command
terraform output configure_kubectl

# All outputs
terraform output
```

## Next Steps

After the cluster is deployed:

1. **Install LLMKube operator** - See `../k8s-manifests/README.md`
2. **Deploy LLM model** - Apply model.yaml
3. **Create inference service** - Apply inference.yaml
4. **Test API** - Use LoadBalancer URL

```bash
cd ../k8s-manifests
# Follow the README there
```

## Troubleshooting

### Cluster Creation Fails

**Availability Zone Issues:**
```
Error: Cannot create cluster ... unsupported availability zone
```

**Fix**: The VPC configuration filters out Wavelength/Local zones. If error persists, check `vpc.tf` availability zone filter.

**Name Too Long Error:**
```
Error: expected length of name_prefix to be in the range (1 - 38)
```

**Fix**: Already resolved - cluster name is `llm-eks` (short enough).

### Cannot Connect to Cluster

```bash
# Update kubeconfig
aws eks update-kubeconfig --region us-west-2 --name llm-eks

# Verify AWS credentials
aws sts get-caller-identity

# Check cluster status
aws eks describe-cluster --name llm-eks --region us-west-2
```

### Nodes Not Joining

```bash
# Check node group status
aws eks describe-nodegroup --cluster-name llm-eks \
  --nodegroup-name llm-nodes --region us-west-2

# View node group events in AWS Console
```

### EBS CSI Driver Not Working

```bash
# Check addon status
aws eks describe-addon --cluster-name llm-eks \
  --addon-name aws-ebs-csi-driver --region us-west-2

# Check pod logs
kubectl logs -n kube-system -l app=ebs-csi-controller
```

### Load Balancer Controller Issues

```bash
# Check controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Verify IRSA role
kubectl describe sa aws-load-balancer-controller -n kube-system
```

## Cleanup

### Standard Cleanup (Fresh Deployments)

For normal use, cleanup is **fully automatic**:

```bash
# 1. Delete Kubernetes resources
cd ../k8s-manifests
kubectl delete -f inference.yaml
kubectl delete -f model.yaml

# Wait for services to be deleted
kubectl get svc -w
# Press Ctrl+C once gemma-e2b-service is gone

# 2. Destroy infrastructure (automatic cleanup runs!)
cd ../terraform
terraform destroy
```

**That's it!** Terraform automatically cleans up all Kubernetes-created AWS resources during destroy:
- ✅ LoadBalancers
- ✅ Target Groups  
- ✅ Orphaned Network Interfaces
- ✅ Security Groups created by AWS LB Controller

The `cleanup.tf` file runs automatically during `terraform destroy` - no manual script needed.

### What Gets Deleted

- EKS cluster and node groups
- VPC, subnets, NAT gateway, Internet gateway
- IAM roles and policies
- Security groups
- EBS CSI Driver
- AWS Load Balancer Controller
- EBS volumes (if not in use)
- **Kubernetes-created LoadBalancers and ENIs (automatic)**

### Emergency Cleanup (Only If Needed)

**⚠️ Only use this if you already have orphaned resources from a previous failed cleanup:**

```bash
# Run emergency cleanup script
cd terraform
./cleanup-aws-resources.sh

# Then destroy
terraform destroy
```

The script is provided for emergency situations, but **shouldn't be needed** for fresh deployments.

### If Terraform Destroy Fails

This should **rarely happen** with automatic cleanup, but if it does:

**Error: "Network vpc-xxx has some mapped public address(es)"**

The automatic cleanup should prevent this, but if it occurs:

```bash
# Run emergency script
./cleanup-aws-resources.sh

# Retry destroy
terraform destroy
```

**Error: "Subnet has dependencies and cannot be deleted"**

```bash
# Check what's still attached
VPC_ID=$(terraform output -raw vpc_id)
aws ec2 describe-network-interfaces --region us-west-2 \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available"

# Use emergency script
./cleanup-aws-resources.sh
terraform destroy
```

### How Automatic Cleanup Works

When you run `terraform destroy`, the following happens automatically:

1. **Pre-destroy hook runs** (from `cleanup.tf`)
2. Scans VPC for LoadBalancers → Deletes them
3. Removes Target Groups
4. Waits for Network Interfaces to detach
5. Deletes LoadBalancer Security Groups
6. Removes orphaned ENIs
7. **Then** Terraform destroys VPC and other infrastructure

This ensures clean deletion every time without manual intervention.

### Best Practices

✅ **DO**: Delete Kubernetes resources before `terraform destroy`
✅ **DO**: Wait for services to be deleted (`kubectl get svc -w`)
✅ **DO**: Just run `terraform destroy` - cleanup is automatic
❌ **DON'T**: Use the cleanup script unless you have existing orphaned resources
❌ **DON'T**: Skip deleting Kubernetes resources first

## Advanced Configuration

### Use GPU Instances

Edit `variables.tf`:
```hcl
variable "instance_types" {
  default = ["g4dn.xlarge"]
}
```

After deployment, install NVIDIA device plugin:
```bash
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.0/nvidia-device-plugin.yml
```

### Enable Cluster Autoscaler

Add to `main.tf`:
```hcl
eks_managed_node_groups = {
  llm_nodes = {
    # ... existing config ...
    
    scaling_config = {
      desired_size = 2
      max_size     = 10
      min_size     = 1
    }
    
    tags = {
      "k8s.io/cluster-autoscaler/enabled" = "true"
      "k8s.io/cluster-autoscaler/llm-eks" = "owned"
    }
  }
}
```

Then install cluster autoscaler via Helm.

### Use Different Region

```hcl
# terraform.tfvars
aws_region = "eu-west-1"
```

Update kubectl config after deployment:
```bash
aws eks update-kubeconfig --region eu-west-1 --name llm-eks
```

## Upgrades

### Upgrade Kubernetes Version

1. Update `variables.tf`:
   ```hcl
   variable "cluster_version" {
     default = "1.32"
   }
   ```

2. Apply:
   ```bash
   terraform apply
   ```

3. Upgrade nodes (done automatically by EKS managed node groups)

### Upgrade EKS Addons

```bash
# Check available versions
aws eks describe-addon-versions --addon-name aws-ebs-csi-driver

# Update in Terraform or via CLI
aws eks update-addon --cluster-name llm-eks \
  --addon-name aws-ebs-csi-driver \
  --addon-version v1.x.x-eksbuild.x
```

## Security Best Practices

✅ **Implemented in this configuration:**
- Private subnets for worker nodes
- Public endpoint with restricted access
- IRSA for fine-grained IAM permissions
- Security groups limit traffic
- Cluster creator has admin access

🔒 **Additional recommendations:**
- Enable envelope encryption for secrets
- Use private cluster endpoint (requires VPN/bastion)
- Enable EKS audit logging to CloudWatch
- Implement network policies
- Use Pod Security Standards

## Support

- **Terraform AWS EKS Module**: https://github.com/terraform-aws-modules/terraform-aws-eks
- **AWS EKS Best Practices**: https://aws.github.io/aws-eks-best-practices/
- **EBS CSI Driver**: https://github.com/kubernetes-sigs/aws-ebs-csi-driver
- **Load Balancer Controller**: https://kubernetes-sigs.github.io/aws-load-balancer-controller/
