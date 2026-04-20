#!/usr/bin/env bash
# scripts/run-chaos.sh
# Runs the AI Chaos Engineer against the deployed ecommerce stack
# Usage: ./scripts/run-chaos.sh [--dry-run] [--provider anthropic|openai]
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
step()    { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

REGION="us-east-1"
CLUSTER_NAME="chaos-lab-dev"
DRY_RUN=false
PROVIDER="anthropic"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CHAOS_DIR="$ROOT_DIR/../ai-chaos-engineer"

for arg in "$@"; do
  case $arg in
    --dry-run)          DRY_RUN=true ;;
    --provider=*)       PROVIDER="${arg#*=}" ;;
  esac
done

# ── Verify cluster is accessible ─────────────────────────────────────────────
step "Verifying cluster access"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME" &>/dev/null
kubectl get nodes --no-headers | grep -q Ready || { echo "No ready nodes found"; exit 1; }
success "Cluster accessible"

# ── Check all apps are running ────────────────────────────────────────────────
step "Checking application health before chaos"
echo ""
kubectl get pods -n ecommerce -o wide
echo ""

NOT_READY=$(kubectl get pods -n ecommerce --no-headers | grep -v Running | grep -v Completed | wc -l | tr -d ' ')
if [ "$NOT_READY" -gt 0 ]; then
  warn "$NOT_READY pods are not in Running state. Chaos may produce misleading results."
  read -r -p "Continue anyway? (y/N): " confirm
  [ "$confirm" = "y" ] || exit 0
fi

# ── Port-forward Prometheus if not accessible ─────────────────────────────────
step "Checking Prometheus"
PROM_URL="${PROMETHEUS_URL:-http://localhost:9090}"

if ! curl -sf "$PROM_URL/-/healthy" &>/dev/null; then
  info "Prometheus not accessible at $PROM_URL — starting port-forward..."
  kubectl port-forward svc/prometheus-operated 9090:9090 -n monitoring &
  PF_PID=$!
  sleep 3
  export PROMETHEUS_URL="http://localhost:9090"
  info "Port-forward started (PID $PF_PID)"
  trap "kill $PF_PID 2>/dev/null || true" EXIT
fi
success "Prometheus OK at $PROM_URL"

# ── Update config.yaml namespace ─────────────────────────────────────────────
step "Configuring AI Chaos Engineer"
cd "$CHAOS_DIR"

# Patch config to target ecommerce namespace
if command -v python3 &>/dev/null; then
  python3 - <<'PYEOF'
import yaml, sys

with open("config.yaml") as f:
    cfg = yaml.safe_load(f)

cfg["kubernetes"]["namespace"] = "ecommerce"
cfg["kubernetes"]["context"] = ""
cfg["ai"]["provider"] = "anthropic"

with open("config.yaml", "w") as f:
    yaml.dump(cfg, f, default_flow_style=False)

print("config.yaml updated: namespace=ecommerce")
PYEOF
fi

# ── Run Chaos ─────────────────────────────────────────────────────────────────
step "Running AI Chaos Engineer"

CHAOS_CMD="python main.py run --provider $PROVIDER --skip-confirm"
if [ "$DRY_RUN" = true ]; then
  CHAOS_CMD="python main.py run --provider $PROVIDER --dry-run --skip-confirm"
  info "DRY RUN mode — no experiments will actually execute"
fi

info "Command: $CHAOS_CMD"
echo ""
eval "$CHAOS_CMD"

# ── Show results ──────────────────────────────────────────────────────────────
step "Post-chaos cluster state"
echo ""
kubectl get pods -n ecommerce -o wide
echo ""

LATEST_REPORT=$(ls -t reports/*.md 2>/dev/null | head -1 || echo "")
if [ -n "$LATEST_REPORT" ]; then
  success "Latest report: $LATEST_REPORT"
fi
