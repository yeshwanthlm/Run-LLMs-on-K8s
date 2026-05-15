# Kubernetes Manifests for LLM Inference

Deploy Gemma 4 E2B LLM on your EKS cluster with OpenAI-compatible API.

## Files Overview

| File | Purpose |
|------|---------|
| `model.yaml` | Defines the Gemma 4 E2B model (4.6GB GGUF) |
| `inference.yaml` | InferenceService with LoadBalancer, includes `fsGroup: 100` for volume permissions |
| `service-loadbalancer-patch.yaml` | Auto-patch Job to configure LoadBalancer as internet-facing with IP target mode |
| `llmkube-post-install.yaml` | Configures LLMKube controller with proper security context |

**All configuration is automated** - no manual patching required!

## Prerequisites

- EKS cluster deployed via Terraform (see `../terraform/README.md`)
- kubectl configured: `aws eks update-kubeconfig --region us-west-2 --name llm-eks`
- Helm 3.x installed

## Quick Start

```bash
# 1. Install LLMKube operator
helm repo add llmkube https://defilantech.github.io/LLMKube
helm repo update
helm search repo llmkube --versions

CHART_VERSION="0.7.5"
helm install llmkube llmkube/llmkube \
  --namespace llmkube-system \
  --version ${CHART_VERSION} \
  --create-namespace

# 2. Configure operator for EBS volumes
kubectl apply -f llmkube-post-install.yaml
kubectl wait --for=condition=complete job/llmkube-configure -n llmkube-system --timeout=60s

# 3. Deploy model, inference service, and LoadBalancer patch
kubectl apply -f model.yaml
kubectl apply -f inference.yaml
kubectl apply -f service-loadbalancer-patch.yaml

# 4. Wait for deployment (5-10 min for model download + LoadBalancer setup)
kubectl get pods -w

# 5. Get LoadBalancer URL
export LB_URL=$(kubectl get svc gemma-e2b-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "API: http://${LB_URL}:8080"
```

---

## Detailed Deployment Guide

### Step 1: Install LLMKube Operator

```bash
helm repo add llmkube https://defilantech.github.io/LLMKube
helm repo update
helm search repo llmkube --versions

CHART_VERSION="0.7.5"
helm install llmkube llmkube/llmkube \
  --namespace llmkube-system \
  --version ${CHART_VERSION} \
  --create-namespace
```

Verify installation:
```bash
kubectl get pods -n llmkube-system
kubectl get crd | grep llmkube
```

Expected CRDs:
```
inferenceservices.inference.llmkube.dev
models.inference.llmkube.dev
```

### Step 2: Configure for EBS Volumes

Apply the post-install configuration to set proper volume permissions:

```bash
kubectl apply -f llmkube-post-install.yaml
```

Wait for configuration job to complete:
```bash
kubectl wait --for=condition=complete job/llmkube-configure -n llmkube-system --timeout=60s
```

Verify controller restarted:
```bash
kubectl get pods -n llmkube-system
```

### Step 3: Deploy the Model

```bash
kubectl apply -f model.yaml
```

Check model status:
```bash
kubectl get models
kubectl describe model gemma-e2b
```

### Step 4: Deploy the Inference Service

```bash
kubectl apply -f inference.yaml
```

This automatically configures:
- **Pod security context**: Sets `fsGroup: 100` for EBS volume permissions
- **Resource requests**: 1 CPU, 2Gi memory (optimized for t3.xlarge)
- **Service**: Creates LoadBalancer on port 8080

Check inference service:
```bash
kubectl get inferenceservices
kubectl get svc gemma-e2b-service
```

Verify security context is applied:
```bash
kubectl get deployment gemma-e2b-service -o yaml | grep fsGroup
# Should show: fsGroup: 100
```

### Step 5: Apply LoadBalancer Configuration

The inference service creates an internal LoadBalancer by default. Apply the automatic patch to configure it as internet-facing with IP target mode:

```bash
kubectl apply -f service-loadbalancer-patch.yaml
```

This creates a Job that automatically:
- Waits for the service to be created
- Patches it with internet-facing annotation
- Configures IP target mode (avoids security group conflicts)
- Auto-cleans up after 5 minutes

Check the patch job:
```bash
kubectl logs job/patch-service-loadbalancer
```

You should see:
```
✓ Service found
✓ Service patched successfully
✓ LoadBalancer will be recreated as internet-facing with IP targets
```

**Note:** The LoadBalancer will be recreated, which takes 2-3 minutes.

### Step 7: Monitor Deployment

**Watch pod creation** (takes 5-10 minutes for model download):
```bash
kubectl get pods -l app=gemma-e2b-service -w
```

**Watch model download progress:**
```bash
# Pod will be in Init:0/1 status
kubectl logs -f -l app=gemma-e2b-service -c model-downloader
```

You'll see the 4.6GB model downloading from Hugging Face.

**Once running, check main container:**
```bash
kubectl logs -f -l app=gemma-e2b-service
```

### Step 8: Get LoadBalancer URL

```bash
# Wait for EXTERNAL-IP (takes 2-3 minutes)
kubectl get svc gemma-e2b-service -w
```

Once available:
```bash
export LB_URL=$(kubectl get svc gemma-e2b-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "API Endpoint: http://${LB_URL}:8080"
```

### Step 9: Verify Target Health

Wait for AWS NLB health checks to pass (~30-60 seconds):

```bash
# Check if targets are healthy
TG_ARN=$(aws elbv2 describe-target-groups --region us-west-2 \
  --query 'TargetGroups[?contains(TargetGroupName, `k8s-default-gemmae2b`)].TargetGroupArn' \
  --output text)

aws elbv2 describe-target-health --target-group-arn $TG_ARN --region us-west-2 \
  --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text
```

Wait until it shows `healthy`.

---

## Testing Your LLM API

### ⚠️ Important: Token Requirements

**Gemma 4 E2B** is a reasoning model that "thinks" before answering. It uses many tokens for internal reasoning, so you need higher token limits than normal models.

| Use Case | Minimum Tokens |
|----------|----------------|
| Simple questions | 500 |
| Detailed responses | 800+ |
| Complex reasoning | 1000+ |

### Quick Test

```bash
curl -X POST http://${LB_URL}:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma-e2b",
    "messages": [{"role": "user", "content": "What is Kubernetes in one sentence?"}],
    "max_tokens": 500
  }' | jq -r '.choices[0].message.content'
```

Expected output (example):
```
Kubernetes is an open-source container orchestration platform that automates the deployment, scaling, and management of containerized applications.
```

### More Examples

**Simple question:**
```bash
curl -X POST http://${LB_URL}:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "gemma-e2b", "messages": [{"role": "user", "content": "Explain Docker briefly"}], "max_tokens": 600}' \
  | jq -r '.choices[0].message.content'
```

**See reasoning + answer:**
```bash
curl -X POST http://${LB_URL}:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "gemma-e2b", "messages": [{"role": "user", "content": "What are containers?"}], "max_tokens": 800}' \
  | jq '.choices[0].message'
```

**Get full response with stats:**
```bash
curl -X POST http://${LB_URL}:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "gemma-e2b", "messages": [{"role": "user", "content": "Hello!"}], "max_tokens": 500}' \
  | jq '.'
```

### Python Example

```python
from openai import OpenAI

lb_url = "http://your-lb-url:8080"

client = OpenAI(
    base_url=f"{lb_url}/v1",
    api_key="not-needed"
)

response = client.chat.completions.create(
    model="gemma-e2b",
    messages=[
        {"role": "user", "content": "Explain Kubernetes"}
    ],
    max_tokens=600  # Use 500+ for E2B model
)

print(response.choices[0].message.content)
```

---

## Monitoring & Operations

### View Logs

```bash
# Inference service logs
kubectl logs -f -l app=gemma-e2b-service

# Operator logs
kubectl logs -n llmkube-system -l control-plane=controller-manager --tail=50
```

### Resource Usage

```bash
kubectl top pods
kubectl describe pod -l app=gemma-e2b-service
```

### LoadBalancer Status

```bash
# Service details
kubectl describe svc gemma-e2b-service

# Target health
TG_ARN=$(aws elbv2 describe-target-groups --region us-west-2 \
  --query 'TargetGroups[?contains(TargetGroupName, `k8s-default-gemmae2b`)].TargetGroupArn' \
  --output text)
aws elbv2 describe-target-health --target-group-arn $TG_ARN --region us-west-2
```

---

## Scaling

### Manual Scaling

Edit `inference.yaml`:
```yaml
spec:
  replicas: 2  # Increase replicas
```

Apply:
```bash
kubectl apply -f inference.yaml
```

Or scale directly:
```bash
kubectl scale deployment gemma-e2b-service --replicas=2
```

### Auto-scaling

```bash
kubectl autoscale deployment gemma-e2b-service \
  --cpu-percent=70 \
  --min=1 \
  --max=3
```

---

## Performance

### Current Setup (t3.xlarge - 4 vCPUs)

- **Prompt processing**: 15-20 tokens/sec
- **Generation**: 4-5 tokens/sec  
- **Typical response time**: 20-60 seconds

### Improving Performance

**Option 1: Larger CPU instances**
- Update `terraform/variables.tf`: `instance_types = ["t3.2xlarge"]`
- Run `terraform apply`

**Option 2: Add GPU** (10-20x faster)
1. Update to GPU instances: `instance_types = ["g4dn.xlarge"]`
2. Install NVIDIA device plugin:
   ```bash
   kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.0/nvidia-device-plugin.yml
   ```
3. Update `model.yaml`:
   ```yaml
   hardware:
     accelerator: cuda
     gpu:
       enabled: true
       count: 1
   ```
4. Reapply: `kubectl apply -f model.yaml inference.yaml`

---

## Troubleshooting

### Pod Stuck in Init

**Check logs:**
```bash
kubectl logs -l app=gemma-e2b-service -c model-downloader
```

**Common causes:**
- Model still downloading (wait 5-10 min)
- Network issues downloading from Hugging Face
- Insufficient disk space

### LoadBalancer Timeout

**Verify patch job completed:**
```bash
kubectl logs job/patch-service-loadbalancer
```

Should show successful patching.

**Verify annotations were applied:**
```bash
kubectl get svc gemma-e2b-service -o yaml | grep annotations -A 5
```

Should show:
```yaml
service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
```

If annotations are missing, the patch job may have failed. Reapply:
```bash
kubectl delete -f service-loadbalancer-patch.yaml
kubectl apply -f service-loadbalancer-patch.yaml
```

**Check target health:**
```bash
TG_ARN=$(aws elbv2 describe-target-groups --region us-west-2 \
  --query 'TargetGroups[?contains(TargetGroupName, `k8s-default-gemmae2b`)].TargetGroupArn' \
  --output text)
aws elbv2 describe-target-health --target-group-arn $TG_ARN --region us-west-2
```

### Empty Responses

**Symptom:** `content` field is empty

**Cause:** Gemma 4 E2B uses tokens for reasoning first

**Solution:** Increase `max_tokens` to 500+:
```bash
curl -X POST http://${LB_URL}:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "gemma-e2b", "messages": [{"role": "user", "content": "Test"}], "max_tokens": 500}'
```

### Pod Has Unbound PVC

**Check PVC status:**
```bash
kubectl get pvc
kubectl describe pvc llmkube-model-cache
```

If stuck pending, EBS CSI driver may not be ready. Verify:
```bash
kubectl get pods -n kube-system | grep ebs-csi
```

Should see `ebs-csi-controller` and `ebs-csi-node` pods running.

---

## Cleanup

### Delete Inference Service

```bash
# Delete patch job and service
kubectl delete -f service-loadbalancer-patch.yaml
kubectl delete -f inference.yaml

# Wait for LoadBalancer to be removed (important!)
kubectl get svc -w
```

### Delete Model & Operator

```bash
kubectl delete -f model.yaml
kubectl delete job llmkube-configure -n llmkube-system
helm uninstall llmkube -n llmkube-system
```

### Delete PVC (Optional)

```bash
kubectl delete pvc llmkube-model-cache
```

**Note:** Keeping the PVC preserves the downloaded model for faster restarts.

---

## Cost Optimization

### Pause Service

Scale to zero (keeps model cached):
```bash
kubectl scale deployment gemma-e2b-service --replicas=0
```

### Resume Service

```bash
kubectl scale deployment gemma-e2b-service --replicas=1
```

---

## Resources

- **LLMKube**: https://github.com/defilantech/LLMKube
- **Gemma Model**: https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF
- **OpenAI API**: https://platform.openai.com/docs/api-reference/chat
- **Llama.cpp**: https://github.com/ggml-org/llama.cpp
