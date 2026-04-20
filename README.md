# EKS Chaos Lab

Terraform + Kubernetes manifests for spinning up a production-like EKS cluster with a sample e-commerce microservices stack — purpose-built as a target for the **AI Chaos Engineer**.

---

## What Gets Deployed

### Infrastructure (Terraform)
| Resource | Detail |
|---|---|
| EKS Cluster | Kubernetes 1.29, us-east-1 |
| VPC | 3 AZs, public + private subnets, NAT gateways |
| Node Group | 2× t3.medium (auto-scales to 4) |
| EKS Add-ons | vpc-cni, coredns, kube-proxy, ebs-csi-driver |
| kube-prometheus-stack | Prometheus + Grafana (LoadBalancer) |
| LitmusChaos | Chaos execution engine (LoadBalancer) |
| Chaos Mesh | Network + stress chaos (LoadBalancer) |
| AWS LB Controller | Provisions ALBs for Ingress |
| Metrics Server | Pod CPU/memory metrics for HPA |

### Applications (Kubernetes — `ecommerce` namespace)
| Service | Replicas | HPA | Notes |
|---|---|---|---|
| `frontend` | 2 | ✓ (2-6) | nginx, topology spread |
| `api-gateway` | 2 | ✓ (2-8) | Entry point |
| `user-service` | 1 | ✗ | **Intentional weak spot** — single replica, no HPA |
| `order-service` | 2 | ✓ (2-6) | Depends on Redis + user/payment svc |
| `payment-service` | 2 | ✓ (2-6) | **No resource limits** — chaos will flag this |
| `notification-service` | 1 | ✗ | Low priority, tolerates disruption |
| `redis-cache` | 1 | — | StatefulSet, 1Gi PVC |
| `postgres-user` | 1 | — | StatefulSet, 5Gi PVC |

The weak spots are intentional — they give the AI chaos engineer real findings to report.

---

## Prerequisites

```bash
# Install these tools first
brew install terraform awscli kubectl helm   # macOS
# or use your Linux package manager

# Configure AWS credentials
aws configure
# IAM permissions needed: EKS full, EC2, VPC, IAM, ELB
```

**Estimated cost:** ~$4-6/day for 2× t3.medium + NAT gateways. Destroy when done.

---

## Deploy

```bash
git clone https://github.com/YOUR_USERNAME/eks-chaos-lab
cd eks-chaos-lab

# Make scripts executable
chmod +x scripts/*.sh

# Full deploy (Terraform + apps) — takes ~15 minutes
./scripts/deploy.sh

# If cluster already exists, skip Terraform
./scripts/deploy.sh --skip-terraform
```

### What the deploy script does
1. Checks prerequisites (terraform, aws, kubectl, helm)
2. Runs `terraform init + plan + apply` — provisions VPC, EKS, add-ons
3. Configures kubectl context
4. Deploys all Kubernetes manifests
5. Waits for all deployments to be ready
6. Prints access URLs

---

## Verify Everything Is Running

```bash
./scripts/verify.sh
```

Expected output:
```
━━━ EKS Chaos Lab — Health Check ━━━

Nodes:
  ✓ ip-10-0-x-x.ec2.internal (Ready)
  ✓ ip-10-0-x-x.ec2.internal (Ready)

Ecommerce apps (namespace: ecommerce):
  ✓ frontend (2/2 ready)
  ✓ api-gateway (2/2 ready)
  ✓ user-service (1/1 ready)
  ✓ order-service (2/2 ready)
  ✓ payment-service (2/2 ready)
  ✓ notification-service (1/1 ready)

━━━ All checks passed. Ready for chaos! ━━━
```

---

## Run AI Chaos Engineer

```bash
# From the ai-chaos-engineer directory
cd ../ai-chaos-engineer

# Step 1: Scan the cluster
python main.py scan

# Step 2: See the AI plan (no execution)
python main.py plan

# Step 3: Dry run (full flow, no actual chaos)
python main.py run --dry-run

# Step 4: The real thing
python main.py run
```

Or use the convenience wrapper:
```bash
cd eks-chaos-lab
./scripts/run-chaos.sh             # full run
./scripts/run-chaos.sh --dry-run   # plan only
./scripts/run-chaos.sh --provider=openai
```

---

## Access Dashboards

```bash
# Get Grafana URL
kubectl get svc prometheus-grafana -n monitoring
# Login: admin / chaos-lab-admin

# Get app URL
kubectl get ingress ecommerce-ingress -n ecommerce

# Get LitmusChaos portal
kubectl get svc -n litmus | grep frontend

# Port-forward Prometheus locally
kubectl port-forward svc/prometheus-operated 9090:9090 -n monitoring
```

---

## Intentional Weak Spots

The sample apps have three deliberate weaknesses for the AI to discover:

1. **`user-service`** — single replica + no HPA. A pod kill causes full service outage.
2. **`payment-service`** — no resource limits. CPU/memory stress can cascade to the node.
3. **`notification-service`** — single replica. Low blast radius but still a finding.

The AI chaos engineer should identify all three, propose targeted experiments, and generate fix recommendations for each.

---

## Destroy

```bash
./scripts/deploy.sh --destroy
```

This deletes all Kubernetes namespaces first (releasing PVCs/ELBs), then runs `terraform destroy`.

---

## Repo Structure

```
eks-chaos-lab/
├── terraform/
│   ├── main.tf               # EKS + Helm releases
│   ├── providers.tf          # AWS, k8s, helm providers
│   ├── variables.tf
│   ├── outputs.tf
│   ├── modules/
│   │   ├── vpc/main.tf       # VPC, subnets, NAT gateways
│   │   └── eks/main.tf       # EKS cluster, node group, IAM, OIDC
│   └── environments/dev/
│       └── terraform.tfvars  # us-east-1, t3.medium, 2 nodes
├── kubernetes/
│   ├── apps/
│   │   ├── 00-namespace.yaml
│   │   ├── databases.yaml    # Redis + PostgreSQL StatefulSets
│   │   ├── ingress.yaml      # ALB Ingress
│   │   ├── frontend/
│   │   ├── api-gateway/
│   │   ├── user-service/     # weak spot: single replica
│   │   ├── order-service/
│   │   ├── payment-service/  # weak spot: no resource limits
│   │   └── notification-service/
│   ├── monitoring/
│   │   └── service-monitor.yaml  # Prometheus scrape + alert rules
│   └── chaos-tools/
│       └── litmus-rbac.yaml  # RBAC for chaos experiments
└── scripts/
    ├── deploy.sh             # full deploy
    ├── verify.sh             # health check
    └── run-chaos.sh          # run AI chaos engineer
```
