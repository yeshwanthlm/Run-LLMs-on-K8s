# Quick Start Guide

Deploy an LLM on AWS EKS in under 30 minutes.

## Prerequisites

- AWS CLI configured (`aws configure`)
- Terraform >= 1.3
- kubectl installed
- Helm installed

## Deploy (20-25 minutes)

### 1. Create Infrastructure (15-20 min)

```bash
cd terraform
terraform init
terraform apply  # Type 'yes' when prompted
```

☕ Take a break - this creates the entire EKS cluster.

### 2. Configure kubectl

```bash
aws eks update-kubeconfig --region us-west-2 --name llm-eks
kubectl get nodes  # Verify 2 nodes are Ready
```

### 3. Install LLMKube Operator (2 min)

```bash
cd ../k8s-manifests

helm repo add llmkube https://llmkube.dev/charts
helm repo update

helm install llmkube llmkube/llmkube \
  --namespace llmkube-system \
  --create-namespace \
  --version 0.7.5

kubectl apply -f llmkube-post-install.yaml
kubectl wait --for=condition=complete job/llmkube-configure -n llmkube-system --timeout=60s
```

### 4. Deploy LLM (5-10 min)

```bash
kubectl apply -f model.yaml
kubectl apply -f inference.yaml
kubectl apply -f service-loadbalancer-patch.yaml

# Watch deployment (model downloads 4.6GB)
kubectl get pods -w
```

Wait for pod to show `Running` (Ctrl+C to exit watch).

**Note**: The service patch job automatically configures the LoadBalancer as internet-facing with IP target mode.

### 5. Get API URL

```bash
export LB_URL=$(kubectl get svc gemma-e2b-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "API: http://${LB_URL}:8080"
```

### 6. Test It!

```bash
curl -X POST http://${LB_URL}:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma-e2b",
    "messages": [{"role": "user", "content": "What is Kubernetes?"}],
    "max_tokens": 500
  }' | jq -r '.choices[0].message.content'
```

You should see the AI's response!

## Use Your LLM

### Python

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://your-lb-url:8080/v1",
    api_key="not-needed"
)

response = client.chat.completions.create(
    model="gemma-e2b",
    messages=[{"role": "user", "content": "Hello!"}],
    max_tokens=500
)

print(response.choices[0].message.content)
```

### cURL

```bash
curl -X POST http://${LB_URL}:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "gemma-e2b", "messages": [{"role": "user", "content": "Your question here"}], "max_tokens": 500}'
```

## Important Notes

### Token Limits

Gemma 4 E2B is a **reasoning model** - it thinks before answering.

- ❌ **100-300 tokens**: Only shows thinking, no answer
- ✅ **500+ tokens**: Gets full response
- ✅ **800+ tokens**: For detailed answers

**Always use at least 500 tokens!**

### Performance

On t3.xlarge (4 vCPU):
- Response time: 20-60 seconds
- Generation: ~4-5 tokens/sec

For faster responses, use larger instances or GPU.

## Cleanup (3-5 minutes)

When you're done:

```bash
# 1. Delete Kubernetes resources
cd k8s-manifests
kubectl delete -f service-loadbalancer-patch.yaml
kubectl delete -f inference.yaml
kubectl delete -f model.yaml
kubectl get svc -w  # Wait for services to disappear

# 2. Destroy infrastructure (automatic cleanup!)
cd ../terraform
terraform destroy  # Type 'yes' when prompted
```

**No manual cleanup needed** - Terraform automatically removes all LoadBalancers and orphaned resources!

## Cost

~$150-200/month if left running.

**Save money**:
- Scale to zero: `kubectl scale deployment gemma-e2b-service --replicas=0`
- Destroy when done: `terraform destroy`

## Troubleshooting

### Pod stuck downloading
- Wait 5-10 min for 4.6GB model download
- Check: `kubectl logs -f -l app=gemma-e2b-service -c model-downloader`

### Empty API responses
- Use 500+ tokens (not 100!)
- Reasoning model needs tokens for thinking

### LoadBalancer timeout
- Wait 2-3 min for NLB provisioning
- Verify: `kubectl get svc gemma-e2b-service`

## Next Steps

- See [`README.md`](README.md) for full documentation
- Check [`terraform/README.md`](terraform/README.md) for infrastructure details
- Read [`k8s-manifests/README.md`](k8s-manifests/README.md) for deployment options

---

**Questions?** All fixes are documented in [`FIXES-APPLIED.md`](FIXES-APPLIED.md)
