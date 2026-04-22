#!/usr/bin/env bash
# scripts/deploy.sh
# Full end-to-end: provision EKS, deploy apps, generate traffic, verify Prometheus
# Usage: ./scripts/deploy.sh [--skip-terraform] [--skip-traffic] [--destroy]
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
SKIP_TRAFFIC=false
DESTROY=false
PROM_PORT=9090
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

for arg in "$@"; do
  case $arg in
    --skip-terraform) SKIP_TERRAFORM=true ;;
    --skip-traffic)   SKIP_TRAFFIC=true ;;
    --destroy)        DESTROY=true ;;
  esac
done

# ── Prerequisites check ───────────────────────────────────────────────────────
step "Checking prerequisites"
for tool in terraform aws kubectl helm curl; do
  if command -v "$tool" &>/dev/null; then
    success "$tool found"
  else
    error "$tool not found. Please install it first."
  fi
done

aws sts get-caller-identity --region "$REGION" &>/dev/null || \
  error "AWS credentials not configured. Run: aws configure"
success "AWS credentials OK (account: $(aws sts get-caller-identity --query Account --output text))"

# ── Destroy mode ──────────────────────────────────────────────────────────────
if [ "$DESTROY" = true ]; then
  step "Destroying infrastructure"
  warn "This will DELETE your EKS cluster and all apps!"
  read -r -p "Type 'yes' to confirm: " confirm
  [ "$confirm" = "yes" ] || { info "Aborted."; exit 0; }

  info "Stopping load generators..."
  kubectl delete pod load-gen load-gen-2 load-gen-3 -n ecommerce --ignore-not-found=true || true

  info "Removing Kubernetes namespaces..."
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
  terraform init -upgrade
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

kubectl apply -f "$ROOT_DIR/kubernetes/apps/ingress.yaml"
kubectl apply -f "$ROOT_DIR/kubernetes/chaos-tools/litmus-rbac.yaml"
kubectl apply -f "$ROOT_DIR/kubernetes/monitoring/service-monitor.yaml" || \
  warn "ServiceMonitor apply failed — Prometheus CRDs may not be ready yet."

# ── Wait for deployments ──────────────────────────────────────────────────────
step "Waiting for all deployments to be ready"
for deploy in frontend api-gateway user-service order-service payment-service notification-service; do
  info "Waiting for $deploy..."
  kubectl rollout status deployment/"$deploy" -n ecommerce --timeout=180s && \
    success "$deploy is ready" || warn "$deploy is not ready yet"
done

# ── Patch apps to httpbin (emits real HTTP metrics) ───────────────────────────
step "Patching services to emit real HTTP metrics"
# http-echo emits nothing useful to Prometheus
# httpbin exposes real HTTP endpoints with measurable latency, status codes, delays

for svc in user-service order-service payment-service notification-service; do
  info "Patching $svc → httpbin..."
  kubectl set image deployment/$svc $svc=kennethreitz/httpbin:latest -n ecommerce
  kubectl patch deployment $svc -n ecommerce --type='json' -p='[
    {"op":"replace","path":"/spec/template/spec/containers/0/args","value":[]},
    {"op":"replace","path":"/spec/template/spec/containers/0/ports/0/containerPort","value":80},
    {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/port","value":80},
    {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/port","value":80}
  ]'
done

info "Waiting for patched rollouts..."
for svc in user-service order-service payment-service notification-service; do
  kubectl rollout status deployment/$svc -n ecommerce --timeout=120s && \
    success "$svc patched and ready" || warn "$svc rollout pending"
done

# ── Start load generators ─────────────────────────────────────────────────────
if [ "$SKIP_TRAFFIC" = false ]; then
  step "Starting traffic generators"

  kubectl delete pod load-gen load-gen-2 load-gen-3 -n ecommerce --ignore-not-found=true
  sleep 2

  info "Starting load-gen: steady traffic to api-gateway + frontend..."
  kubectl run load-gen --image=busybox:1.36 --restart=Never -n ecommerce -- \
    /bin/sh -c "
      while true; do
        wget -q -O/dev/null http://api-gateway/get 2>/dev/null
        wget -q -O/dev/null http://api-gateway/status/200 2>/dev/null
        wget -q -O/dev/null http://frontend/health 2>/dev/null
        sleep 0.2
      done
    "

  info "Starting load-gen-2: traffic across all backend services..."
  kubectl run load-gen-2 --image=busybox:1.36 --restart=Never -n ecommerce -- \
    /bin/sh -c "
      while true; do
        wget -q -O/dev/null http://user-service/get 2>/dev/null
        wget -q -O/dev/null http://order-service/get 2>/dev/null
        wget -q -O/dev/null http://payment-service/get 2>/dev/null
        wget -q -O/dev/null http://notification-service/get 2>/dev/null
        sleep 0.3
      done
    "

  info "Starting load-gen-3: mixed traffic including slow endpoints (adds latency signal)..."
  kubectl run load-gen-3 --image=busybox:1.36 --restart=Never -n ecommerce -- \
    /bin/sh -c "
      while true; do
        wget -q -O/dev/null http://api-gateway/delay/1 2>/dev/null
        wget -q -O/dev/null http://payment-service/get 2>/dev/null
        wget -q -O/dev/null http://user-service/get 2>/dev/null
        sleep 0.5
      done
    "

  success "3 load generators running"

  info "Waiting 90s for Prometheus to collect initial metrics baseline..."
  for i in $(seq 1 9); do
    sleep 10
    echo -ne "  ${CYAN}[${i}0s / 90s]${NC}\r"
  done
  echo ""
  success "Baseline metric collection complete"
else
  info "Skipping traffic generation (--skip-traffic flag set)"
fi

# ── Verify Prometheus metrics ─────────────────────────────────────────────────
step "Verifying Prometheus metric collection"

info "Starting Prometheus port-forward on port $PROM_PORT..."
pkill -f "port-forward.*$PROM_PORT" 2>/dev/null || true
sleep 1
kubectl port-forward svc/prometheus-operated "$PROM_PORT:9090" -n monitoring &>/dev/null &
PF_PID=$!
sleep 5

PROM_URL="http://localhost:$PROM_PORT"
PROM_OK=false

if curl -sf "$PROM_URL/-/healthy" &>/dev/null; then
  success "Prometheus is healthy"
  PROM_OK=true
else
  warn "Prometheus not responding — skipping metric checks"
  kill $PF_PID 2>/dev/null || true
fi

if [ "$PROM_OK" = true ]; then

  # Query helper — returns series count
  prom_count() {
    curl -sf "$PROM_URL/api/v1/query" --data-urlencode "query=$1" 2>/dev/null | \
      python3 -c "
import sys,json
d=json.load(sys.stdin)
print(len(d.get('data',{}).get('result',[])))
" 2>/dev/null || echo "0"
  }

  # Query helper — returns scalar value
  prom_val() {
    curl -sf "$PROM_URL/api/v1/query" --data-urlencode "query=$1" 2>/dev/null | \
      python3 -c "
import sys,json
d=json.load(sys.stdin)
r=d.get('data',{}).get('result',[])
print(round(float(r[0]['value'][1]),2) if r else 'no data')
" 2>/dev/null || echo "no data"
  }

  echo ""
  echo -e "  ${BLUE}Metric check${NC}                                    ${BLUE}Result${NC}"
  echo    "  ─────────────────────────────────────────────────────────"

  # Core kube-state-metrics
  N=$(prom_count 'kube_pod_info{namespace="ecommerce"}')
  [ "$N" -gt 0 ] 2>/dev/null && \
    success "kube_pod_info                              $N pods tracked" || \
    warn    "kube_pod_info                              no data"

  N=$(prom_count 'kube_pod_container_status_restarts_total{namespace="ecommerce"}')
  [ "$N" -gt 0 ] 2>/dev/null && \
    success "pod_restart_counter                        $N series" || \
    warn    "pod_restart_counter                        no data"

  N=$(prom_count 'kube_deployment_status_replicas_available{namespace="ecommerce"}')
  [ "$N" -gt 0 ] 2>/dev/null && \
    success "deployment_replicas_available              $N deployments" || \
    warn    "deployment_replicas_available              no data"

  # cAdvisor metrics (CPU + memory)
  N=$(prom_count 'container_cpu_usage_seconds_total{namespace="ecommerce",container!=""}')
  [ "$N" -gt 0 ] 2>/dev/null && \
    success "container_cpu_usage                        $N series" || \
    warn    "container_cpu_usage                        no data (cAdvisor may need more time)"

  N=$(prom_count 'container_memory_working_set_bytes{namespace="ecommerce",container!=""}')
  [ "$N" -gt 0 ] 2>/dev/null && \
    success "container_memory_working_set               $N series" || \
    warn    "container_memory_working_set               no data"

  # Network traffic (confirms load generators are actually sending)
  if [ "$SKIP_TRAFFIC" = false ]; then
    RATE=$(prom_val 'sum(rate(container_network_transmit_bytes_total{namespace="ecommerce"}[2m]))')
    if [ "$RATE" != "no data" ] && [ "$RATE" != "0" ] 2>/dev/null; then
      success "network_transmit_rate                      ${RATE} bytes/s ✓ traffic flowing"
    else
      warn    "network_transmit_rate                      no data (load gen may still warming up)"
    fi
  fi

  # Per-service replica status from Prometheus
  echo ""
  echo -e "  ${BLUE}Service replicas (via Prometheus):${NC}"
  for svc in frontend api-gateway user-service order-service payment-service notification-service; do
    AVAIL=$(prom_val "kube_deployment_status_replicas_available{namespace=\"ecommerce\",deployment=\"$svc\"}")
    DESIRED=$(prom_val "kube_deployment_spec_replicas{namespace=\"ecommerce\",deployment=\"$svc\"}")
    if [ "$AVAIL" = "no data" ]; then
      warn "  $svc → not in Prometheus yet"
    else
      if [ "$AVAIL" = "$DESIRED" ] 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} $svc → ${AVAIL}/${DESIRED} replicas"
      else
        echo -e "  ${YELLOW}~${NC} $svc → ${AVAIL}/${DESIRED} replicas (degraded)"
      fi
    fi
  done

  # Scrape target health
  echo ""
  TARGET_SUMMARY=$(curl -sf "$PROM_URL/api/v1/targets" 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
active=d.get('data',{}).get('activeTargets',[])
up=[t for t in active if t.get('health')=='up']
down=[t for t in active if t.get('health')!='up']
print(f'{len(up)} up, {len(down)} down out of {len(active)} total targets')
" 2>/dev/null || echo "unknown")
  info "Prometheus scrape targets: $TARGET_SUMMARY"

  kill $PF_PID 2>/dev/null || true
fi

# ── HTTP smoke test ───────────────────────────────────────────────────────────
step "HTTP smoke test — calling each service directly"

# Use a temporary curl pod for clean HTTP tests
kubectl delete pod curl-test -n ecommerce --ignore-not-found=true &>/dev/null || true
kubectl run curl-test --image=curlimages/curl:latest --restart=Never -n ecommerce \
  -- sleep 120 &>/dev/null || true
sleep 8

for entry in "api-gateway:80:/get" "user-service:80:/get" "order-service:80:/get" \
             "payment-service:80:/get" "notification-service:80:/get" "frontend:80:/health"; do
  SVC=$(echo "$entry" | cut -d: -f1)
  PORT=$(echo "$entry" | cut -d: -f2)
  PATH_=$(echo "$entry" | cut -d: -f3)
  CODE=$(kubectl exec curl-test -n ecommerce -- \
    curl -s -o /dev/null -w "%{http_code}" "http://${SVC}:${PORT}${PATH_}" 2>/dev/null || echo "000")
  if [[ "$CODE" =~ ^[23] ]]; then
    success "$SVC${PATH_} → HTTP $CODE"
  else
    warn "$SVC${PATH_} → HTTP $CODE"
  fi
done

kubectl delete pod curl-test -n ecommerce --ignore-not-found=true &>/dev/null || true

# ── Summary ───────────────────────────────────────────────────────────────────
step "All done"

echo ""
kubectl get pods -n ecommerce -o wide
echo ""

INGRESS_HOST=$(kubectl get ingress ecommerce-ingress -n ecommerce \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending...")
GRAFANA_LB=$(kubectl get svc prometheus-grafana -n monitoring \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending...")

echo -e "${GREEN}━━━ URLs ━━━${NC}"
echo -e "  App:        http://${INGRESS_HOST}"
echo -e "  Grafana:    http://${GRAFANA_LB}  (admin / chaos-lab-admin)"
echo -e "  Prometheus: kubectl port-forward svc/prometheus-operated 9090:9090 -n monitoring"
echo -e "  Chaos Mesh: kubectl port-forward svc/chaos-dashboard 2333:2333 -n chaos-mesh"
echo ""
echo -e "${GREEN}━━━ Load generators ━━━${NC}"
kubectl get pod load-gen load-gen-2 load-gen-3 -n ecommerce --no-headers 2>/dev/null || true
echo ""
echo -e "${GREEN}━━━ Next step ━━━${NC}"
echo -e "  cd ../ai-chaos-engineer"
echo -e "  python main.py run --provider openai"
echo ""
success "Stack ready. Prometheus recording. Chaos can begin."