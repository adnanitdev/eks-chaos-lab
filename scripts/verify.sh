#!/usr/bin/env bash
# scripts/verify.sh
# Checks that the full stack is healthy and ready for chaos testing
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; FAILURES=$((FAILURES+1)); }
warn() { echo -e "  ${YELLOW}~${NC} $*"; }
FAILURES=0

echo -e "\n${CYAN}━━━ EKS Chaos Lab — Health Check ━━━${NC}\n"

# ── Nodes ─────────────────────────────────────────────────────────────────────
echo "Nodes:"
while IFS= read -r line; do
  name=$(echo "$line" | awk '{print $1}')
  status=$(echo "$line" | awk '{print $2}')
  if [ "$status" = "Ready" ]; then ok "$name ($status)"
  else fail "$name ($status)"; fi
done < <(kubectl get nodes --no-headers)

# ── Ecommerce Apps ────────────────────────────────────────────────────────────
echo -e "\nEcommerce apps (namespace: ecommerce):"
EXPECTED_APPS=("frontend" "api-gateway" "user-service" "order-service" "payment-service" "notification-service")
for app in "${EXPECTED_APPS[@]}"; do
  READY=$(kubectl get deployment "$app" -n ecommerce \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  DESIRED=$(kubectl get deployment "$app" -n ecommerce \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
  if [ "${READY:-0}" -ge 1 ]; then
    ok "$app ($READY/$DESIRED ready)"
  else
    fail "$app ($READY/$DESIRED ready)"
  fi
done

# ── Databases ─────────────────────────────────────────────────────────────────
echo -e "\nDatabases:"
for db in "redis-cache" "postgres-user"; do
  READY=$(kubectl get statefulset "$db" -n ecommerce \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [ "${READY:-0}" -ge 1 ]; then ok "$db (ready)"
  else fail "$db (not ready)"; fi
done

# ── Chaos Tools ───────────────────────────────────────────────────────────────
echo -e "\nChaos tools:"
# LitmusChaos
LITMUS_POD=$(kubectl get pods -n litmus --no-headers 2>/dev/null | grep -c Running || echo 0)
if [ "$LITMUS_POD" -gt 0 ]; then ok "LitmusChaos ($LITMUS_POD pods running)"
else warn "LitmusChaos not installed (run: helm install litmus ...)"; fi

# Chaos Mesh
CM_POD=$(kubectl get pods -n chaos-mesh --no-headers 2>/dev/null | grep -c Running || echo 0)
if [ "$CM_POD" -gt 0 ]; then ok "Chaos Mesh ($CM_POD pods running)"
else warn "Chaos Mesh not installed (run: helm install chaos-mesh ...)"; fi

# ── Monitoring ────────────────────────────────────────────────────────────────
echo -e "\nMonitoring:"
PROM_POD=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus \
  --no-headers 2>/dev/null | grep -c Running || echo 0)
if [ "$PROM_POD" -gt 0 ]; then ok "Prometheus ($PROM_POD pods running)"
else warn "Prometheus not found in monitoring namespace"; fi

GRAFANA_POD=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana \
  --no-headers 2>/dev/null | grep -c Running || echo 0)
if [ "$GRAFANA_POD" -gt 0 ]; then ok "Grafana ($GRAFANA_POD pods running)"
else warn "Grafana not found"; fi

# ── RBAC ─────────────────────────────────────────────────────────────────────
echo -e "\nChaos RBAC:"
if kubectl get serviceaccount litmus-admin -n ecommerce &>/dev/null; then
  ok "litmus-admin ServiceAccount exists in ecommerce"
else
  fail "litmus-admin ServiceAccount missing — run: kubectl apply -f kubernetes/chaos-tools/litmus-rbac.yaml"
fi

# ── Ingress / Access ──────────────────────────────────────────────────────────
echo -e "\nIngress:"
INGRESS_HOST=$(kubectl get ingress ecommerce-ingress -n ecommerce \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
if [ -n "$INGRESS_HOST" ]; then
  ok "ALB provisioned: http://$INGRESS_HOST"
else
  warn "ALB not provisioned yet (may take 2-3 minutes after deploy)"
fi

# ── HPAs ─────────────────────────────────────────────────────────────────────
echo -e "\nHPAs:"
kubectl get hpa -n ecommerce --no-headers 2>/dev/null | while read -r line; do
  name=$(echo "$line" | awk '{print $1}')
  ok "HPA: $name"
done
# Check user-service has no HPA (expected weak spot)
if ! kubectl get hpa -n ecommerce 2>/dev/null | grep -q "user-service"; then
  warn "user-service has no HPA (this is intentional — chaos engineer will flag it)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo -e "${GREEN}━━━ All checks passed. Ready for chaos! ━━━${NC}"
  echo -e "\nRun: ${CYAN}./scripts/run-chaos.sh${NC}"
else
  echo -e "${RED}━━━ $FAILURES check(s) failed. Fix above issues before running chaos. ━━━${NC}"
  exit 1
fi
