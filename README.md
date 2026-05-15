# Run LLM on Kubernetes (AWS EKS)

Production-ready deployment of Large Language Models on Amazon EKS with OpenAI-compatible API and LoadBalancer access.

## Overview

Deploy the **Gemma 4 E2B** reasoning model on AWS EKS with:
- ✅ Fully automated infrastructure via Terraform
- ✅ OpenAI-compatible REST API
- ✅ Internet-accessible via AWS Network Load Balancer
- ✅ Persistent storage for model caching
- ✅ Auto-scaling and high availability ready

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                      AWS Cloud                          │
│  ┌──────────────────────────────────────────────────┐   │
│  │              VPC (10.0.0.0/16)                   │   │
│  │  ┌──────────────────────────────────────────┐    │   │
│  │  │         EKS Cluster (llm-eks)            │    │   │
│  │  │                                          │    │   │
│  │  │  ┌────────────┐    ┌────────────┐       │    │   │
│  │  │  │ Node Group │    │ Node Group │       │    │   │
│  │  │  │ t3.xlarge  │    │ t3.xlarge  │       │    │   │
│  │  │  │ 4 vCPU     │    │ 4 vCPU     │       │    │   │
│  │  │  │ 16GB RAM   │    │ 16GB RAM   │       │    │   │
│  │  │  └────────────┘    └────────────┘       │    │   │
│  │  │         │                  │             │    │   │
│  │  │  ┌──────────────────────────────┐       │    │   │
│  │  │  │   LLMKube Operator           │       │    │   │
│  │  │  │   (manages LLM lifecycle)    │       │    │   │
│  │  │  └──────────────────────────────┘       │    │   │
│  │  │         │                                │    │   │
│  │  │  ┌──────────────────────────────┐       │    │   │
│  │  │  │  Gemma 4 E2B (4.6GB)         │       │    │   │
│  │  │  │  - Reasoning Model           │       │    │   │
│  │  │  │  - OpenAI API Compatible     │       │    │   │
│  │  │  │  - Port 8080                 │       │    │   │
│  │  │  └──────────────────────────────┘       │    │   │
│  │  │         │                                │    │   │
│  │  │  ┌──────────────────────────────┐       │    │   │
│  │  │  │  EBS Volume (100GB)          │       │    │   │
│  │  │  │  (model cache)               │       │    │   │
│  │  │  └──────────────────────────────┘       │    │   │
│  │  └──────────────────────────────────────────┘    │   │
│  │                      │                            │   │
│  │  ┌──────────────────────────────────────────┐    │   │
│  │  │  AWS Network Load Balancer (Internet)    │    │   │
│  │  │  - Internet-facing                       │    │   │
│  │  │  - IP target mode                        │    │   │
│  │  └──────────────────────────────────────────┘    │   │
│  └───────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
                         │
                         │ HTTP :8080
                         ▼
                   Public Internet
              (OpenAI-compatible API)
```

## Features

- ✅ **Infrastructure as Code**: Complete Terraform automation
- ✅ **Production VPC**: Multi-AZ, public/private subnets, NAT gateway
- ✅ **Persistent Storage**: EBS CSI driver with automatic provisioning
- ✅ **Load Balancing**: AWS NLB with health checks
- ✅ **Security**: Security groups, IAM roles, IRSA
- ✅ **Scalability**: Horizontal pod autoscaling ready
- ✅ **Monitoring**: CloudWatch integration, pod metrics
- ✅ **GPU Ready**: Optional GPU support for 10-20x faster inference

## Prerequisites

- AWS Account with appropriate permissions
- AWS CLI configured: `aws configure`
- Terraform >= 1.3
- kubectl installed
- Helm 3.x (for LLMKube installation)

## Quick Start

### 1. Deploy Infrastructure

```bash
cd terraform
terraform init
terraform apply
```

⏱️ **Takes 15-20 minutes**

### 2. Configure kubectl

```bash
aws eks update-kubeconfig --region us-west-2 --name llm-eks
kubectl get nodes  # Verify cluster access
```

### 3. Install LLMKube Operator

```bash
cd ../k8s-manifests

# Add Helm repo
helm repo add llmkube https://llmkube.dev/charts
helm repo update

# Install operator
helm install llmkube llmkube/llmkube \
  --namespace llmkube-system \
  --create-namespace \
  --version 0.7.5

# Configure for EBS volumes
kubectl apply -f llmkube-post-install.yaml
kubectl wait --for=condition=complete job/llmkube-configure -n llmkube-system --timeout=60s
```

### 4. Deploy LLM

```bash
kubectl apply -f model.yaml
kubectl apply -f inference.yaml
kubectl apply -f service-loadbalancer-patch.yaml
```

⏱️ **Takes 5-10 minutes** (downloading 4.6GB model + LoadBalancer configuration)

### 5. Get API Endpoint

```bash
kubectl get svc gemma-e2b-service -w
# Wait for EXTERNAL-IP to appear

export LB_URL=$(kubectl get svc gemma-e2b-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "API: http://${LB_URL}:8080"
```

### 6. Test Your LLM

```bash
curl -X POST http://${LB_URL}:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma-e2b",
    "messages": [{"role": "user", "content": "What is Kubernetes?"}],
    "max_tokens": 500
  }' | jq -r '.choices[0].message.content'
```

## Project Structure

```
RunLLMsOnK8s/
├── terraform/              # Infrastructure as Code
│   ├── main.tf            # EKS cluster, node groups, addons
│   ├── vpc.tf             # VPC and networking
│   ├── providers.tf       # AWS/Kubernetes/Helm providers
│   ├── variables.tf       # Configurable parameters
│   ├── outputs.tf         # Cluster information
│   └── README.md          # Infrastructure guide
│
├── k8s-manifests/         # Kubernetes resources
│   ├── model.yaml         # Gemma 4 E2B model definition
│   ├── inference.yaml     # Inference service (LoadBalancer)
│   ├── llmkube-post-install.yaml  # Operator configuration
│   └── README.md          # Deployment guide
│
└── README.md              # This file
```

## What Gets Deployed

### Terraform Creates

| Resource | Description |
|----------|-------------|
| VPC | 10.0.0.0/16 with 3 AZs |
| Subnets | 3 public + 3 private |
| EKS Cluster | Kubernetes 1.31 |
| Node Group | 2x t3.xlarge (4 vCPU, 16GB) |
| EBS CSI Driver | For persistent volumes |
| Load Balancer Controller | Manages AWS NLBs |
| Security Groups | Allow port 8080 traffic |

### Kubernetes Deploys

| Resource | Description |
|----------|-------------|
| LLMKube Operator | Manages model lifecycle |
| Model | Gemma 4 E2B (4.6GB GGUF) |
| InferenceService | OpenAI-compatible API |
| PVC | 100GB EBS volume (model cache) |
| LoadBalancer | Internet-facing AWS NLB |

## Configuration

### Change Region

```hcl
# terraform/terraform.tfvars
aws_region = "us-east-1"
```

### Use Larger Instances

```hcl
# terraform/terraform.tfvars
instance_types = ["t3.2xlarge"]  # 8 vCPU, 32GB RAM
desired_size   = 3
```

### Scale Replicas

```yaml
# k8s-manifests/inference.yaml
spec:
  replicas: 3  # Run 3 inference pods
```

### Use Different Model

Edit `k8s-manifests/model.yaml` to use any GGUF model from Hugging Face:

```yaml
spec:
  source: https://huggingface.co/<org>/<model>/resolve/main/<file>.gguf
```

## Important: Gemma 4 E2B Model Notes

**This is a reasoning model** - it "thinks" before answering, using tokens for internal reasoning.

### Token Requirements

| Question Type | Minimum Tokens |
|---------------|----------------|
| Simple (1 sentence) | 500 |
| Detailed | 800+ |
| Complex reasoning | 1000+ |

### ❌ Wrong (Empty Response)

```bash
# Too few tokens - only gets thinking, no answer!
curl -X POST http://${LB_URL}:8080/v1/chat/completions \
  -d '{"messages": [{"role": "user", "content": "Hello"}], "max_tokens": 100}'
```

### ✅ Correct

```bash
# Enough tokens for full response
curl -X POST http://${LB_URL}:8080/v1/chat/completions \
  -d '{"messages": [{"role": "user", "content": "Hello"}], "max_tokens": 500}'
```

## Cost Estimation

### Monthly Costs (us-west-2)

| Component | Cost |
|-----------|------|
| EKS Cluster | $73 |
| 2x t3.xlarge | $120 |
| NAT Gateway | $33 |
| Load Balancer | $20 |
| EBS Storage (100GB) | $10 |
| **Total** | **~$256/month** |

### Cost Optimization

**1. Use Spot Instances** (70% savings):
```hcl
capacity_type = "SPOT"
```

**2. Stop when not in use**:
```bash
kubectl scale deployment gemma-e2b-service --replicas=0
```

**3. Destroy when done**:
```bash
terraform destroy
```

## Performance

### Current (t3.xlarge - 4 vCPU)

- Prompt: 15-20 tokens/sec
- Generation: 4-5 tokens/sec
- Response: 20-60 seconds

### With GPU (g4dn.xlarge)

- Prompt: 200+ tokens/sec (10-15x faster)
- Generation: 50+ tokens/sec (10x faster)
- Response: 2-10 seconds

## Monitoring

```bash
# Pod logs
kubectl logs -f -l app=gemma-e2b-service

# Resource usage
kubectl top pods

# Service status
kubectl get svc,pods,inferenceservices,models
```

## Troubleshooting

### Common Issues

**Pod stuck downloading**:
- Wait 5-10 min for 4.6GB model download
- Check: `kubectl logs -f -l app=gemma-e2b-service -c model-downloader`

**LoadBalancer timeout**:
- Wait 2-3 min for NLB provisioning
- Verify targets healthy: See k8s-manifests/README.md

**Empty API responses**:
- Use 500+ tokens for Gemma 4 E2B model
- Model uses tokens for reasoning first

**PVC pending**:
- Verify EBS CSI driver: `kubectl get pods -n kube-system | grep ebs-csi`

See detailed troubleshooting in:
- `terraform/README.md` - Infrastructure issues
- `k8s-manifests/README.md` - Application issues

## Cleanup

**Simple 2-step process** - automatic cleanup included!

```bash
# 1. Delete Kubernetes resources
cd k8s-manifests
kubectl delete -f service-loadbalancer-patch.yaml
kubectl delete -f inference.yaml
kubectl delete -f model.yaml
kubectl get svc -w  # Wait until services are gone (Ctrl+C when done)

# 2. Destroy infrastructure (cleanup runs automatically!)
cd ../terraform
terraform destroy
```

**That's it!** Terraform automatically cleans up all Kubernetes-created AWS resources during destroy:
- ✅ LoadBalancers
- ✅ Target Groups
- ✅ Network Interfaces
- ✅ Security Groups

No manual cleanup script needed for fresh deployments!

### Emergency Cleanup (Rarely Needed)

**Only if you have orphaned resources** from a previous failed cleanup:

```bash
cd terraform
./cleanup-aws-resources.sh  # Emergency cleanup
terraform destroy
```

For fresh deployments, this script isn't needed - cleanup is automatic.

See [`terraform/README.md#cleanup`](terraform/README.md#cleanup) for detailed information.

## Documentation

- **Infrastructure**: [`terraform/README.md`](terraform/README.md)
- **Application**: [`k8s-manifests/README.md`](k8s-manifests/README.md)
- **LLMKube**: https://github.com/defilantech/LLMKube
- **Gemma Model**: https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF

## API Examples

### cURL

```bash
curl -X POST http://${LB_URL}:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma-e2b",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "Explain Docker"}
    ],
    "max_tokens": 600
  }' | jq -r '.choices[0].message.content'
```

### Python

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://your-lb-url:8080/v1",
    api_key="not-needed"
)

response = client.chat.completions.create(
    model="gemma-e2b",
    messages=[
        {"role": "user", "content": "What is Kubernetes?"}
    ],
    max_tokens=600
)

print(response.choices[0].message.content)
```

### Node.js

```javascript
const OpenAI = require('openai');

const client = new OpenAI({
  baseURL: 'http://your-lb-url:8080/v1',
  apiKey: 'not-needed'
});

async function chat() {
  const response = await client.chat.completions.create({
    model: 'gemma-e2b',
    messages: [{role: 'user', content: 'Explain containers'}],
    max_tokens: 600
  });
  
  console.log(response.choices[0].message.content);
}

chat();
```

## Acknowledgments

- Built with [LLMKube](https://github.com/defilantech/LLMKube)
- Uses [Terraform AWS EKS Module](https://github.com/terraform-aws-modules/terraform-aws-eks)

## License

This project is provided as-is for educational and demonstration purposes.

---

**Ready to deploy your own LLM on Kubernetes?**

```bash
git clone <your-repo>
cd RunLLMsOnK8s
terraform -chdir=terraform init
terraform -chdir=terraform apply
```

🚀 Happy inferencing!
