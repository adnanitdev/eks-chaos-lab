#!/usr/bin/env bash
# scripts/deploy.sh
# Full end-to-end: provision EKS with Terraform, then deploy all apps
# Usage: ./scripts/deploy.sh [--skip-terraform] [--destroy]
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; exit 1; }
step()    { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

# ── Config ────────────────────────────────────────────────────────────────────
REGION="us-east-1"
CLUSTER_NAME="chaos-lab-dev"
SKIP_TERRAFORM=false
DESTROY=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

for arg in "$@"; do
  case $arg in
    --skip-terraform) SKIP_TERRAFORM=true ;;
    --destroy)        DESTROY=true ;;
  esac
done

# ── Prerequisites check ───────────────────────────────────────────────────────
step "Checking prerequisites"
for tool in terraform aws kubectl helm; do
  if command -v "$tool" &>/dev/null; then
    success "$tool found: $(${tool} version 2>/dev/null | head -1 || echo 'ok')"
  else
    error "$tool not found. Please install it first."
  fi
done

# Check AWS credentials
aws sts get-caller-identity --region "$REGION" &>/dev/null || \
  error "AWS credentials not configured. Run: aws configure"
success "AWS credentials OK (account: $(aws sts get-caller-identity --query Account --output text))"

# ── Destroy mode ──────────────────────────────────────────────────────────────
if [ "$DESTROY" = true ]; then
  step "Destroying infrastructure"
  warn "This will DELETE your EKS cluster and all apps!"
  read -r -p "Type 'yes' to confirm: " confirm
  [ "$confirm" = "yes" ] || { info "Aborted."; exit 0; }

  info "Removing Kubernetes resources first..."
  kubectl delete namespace ecommerce --ignore-not-found=true || true
  kubectl delete namespace litmus --ignore-not-found=true || true
  kubectl delete namespace chaos-mesh --ignore-not-found=true || true
  kubectl delete namespace monitoring --ignore-not-found=true || true

  info "Running terraform destroy..."
  cd "$ROOT_DIR/terraform"
  terraform destroy -var-file="environments/dev/terraform.tfvars" -auto-approve
  success "Infrastructure destroyed"
  exit 0
fi

# ── Terraform ─────────────────────────────────────────────────────────────────
if [ "$SKIP_TERRAFORM" = false ]; then
  step "Provisioning EKS cluster with Terraform"
  cd "$ROOT_DIR/terraform"

  info "Running terraform init..."
  terraform init -upgrade

  info "Running terraform plan..."
  terraform plan -var-file="environments/dev/terraform.tfvars" -out=tfplan

  info "Applying infrastructure (this takes ~15 minutes)..."
  terraform apply tfplan

  success "EKS cluster provisioned"
else
  info "Skipping Terraform (--skip-terraform flag set)"
fi

# ── Configure kubectl ─────────────────────────────────────────────────────────
step "Configuring kubectl"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"
success "kubectl configured"

# Wait for nodes to be ready
info "Waiting for worker nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s
NODE_COUNT=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
success "$NODE_COUNT nodes ready"

# ── Deploy Applications ───────────────────────────────────────────────────────
step "Deploying ecommerce applications"

info "Creating namespace and shared resources..."
kubectl apply -f "$ROOT_DIR/kubernetes/apps/00-namespace.yaml"
sleep 3

info "Deploying databases (Redis + PostgreSQL)..."
kubectl apply -f "$ROOT_DIR/kubernetes/apps/databases.yaml"

info "Deploying microservices..."
kubectl apply -f "$ROOT_DIR/kubernetes/apps/frontend/deployment.yaml"
kubectl apply -f "$ROOT_DIR/kubernetes/apps/api-gateway/deployment.yaml"
kubectl apply -f "$ROOT_DIR/kubernetes/apps/user-service/deployment.yaml"
kubectl apply -f "$ROOT_DIR/kubernetes/apps/order-service/deployment.yaml"
kubectl apply -f "$ROOT_DIR/kubernetes/apps/payment-service/deployment.yaml"
kubectl apply -f "$ROOT_DIR/kubernetes/apps/notification-service/deployment.yaml"

info "Applying ingress..."
kubectl apply -f "$ROOT_DIR/kubernetes/apps/ingress.yaml"

info "Applying chaos tools RBAC..."
kubectl apply -f "$ROOT_DIR/kubernetes/chaos-tools/litmus-rbac.yaml"

info "Applying monitoring (ServiceMonitor + alerts)..."
kubectl apply -f "$ROOT_DIR/kubernetes/monitoring/service-monitor.yaml" || \
  warn "ServiceMonitor apply failed — Prometheus CRDs may not be ready yet. Re-run after monitoring stack is up."

# ── Wait for deployments ──────────────────────────────────────────────────────
step "Waiting for all deployments to be ready"
for deploy in frontend api-gateway user-service order-service payment-service notification-service; do
  info "Waiting for $deploy..."
  kubectl rollout status deployment/"$deploy" -n ecommerce --timeout=180s && \
    success "$deploy is ready" || warn "$deploy is not ready yet"
done

# ── Print summary ─────────────────────────────────────────────────────────────
step "Deployment Summary"

echo ""
echo "━━━ Pods ━━━"
kubectl get pods -n ecommerce -o wide

echo ""
echo "━━━ Services ━━━"
kubectl get svc -n ecommerce

echo ""
echo "━━━ Ingress ━━━"
kubectl get ingress -n ecommerce

echo ""
INGRESS_HOST=$(kubectl get ingress ecommerce-ingress -n ecommerce \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending...")
GRAFANA_LB=$(kubectl get svc prometheus-grafana -n monitoring \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending...")

echo -e "${GREEN}━━━ Access URLs ━━━${NC}"
echo -e "  App:     http://${INGRESS_HOST}"
echo -e "  Grafana: http://${GRAFANA_LB} (admin / chaos-lab-admin)"
echo ""
echo -e "${GREEN}━━━ Run AI Chaos Engineer ━━━${NC}"
echo -e "  cd ../ai-chaos-engineer"
echo -e "  python main.py plan --provider anthropic"
echo -e "  python main.py run"
echo ""
success "Done! Your chaos lab is ready."
