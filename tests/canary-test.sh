#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NAMESPACE="${NAMESPACE:-paystream}"
ROLLOUT_NAME="auth-service"

echo -e "${YELLOW}PayStream Auth Service — Canary Deployment Test${NC}\n"

# Check prerequisites
echo -e "${BLUE}[0/5] Checking prerequisites...${NC}"
for cmd in kubectl; do
  if ! command -v "$cmd" &> /dev/null; then
    echo -e "${RED}$cmd not found${NC}"
    exit 1
  fi
done

# Check if argo rollouts plugin is available
if ! kubectl argo rollouts version &> /dev/null 2>&1; then
  echo -e "${RED}kubectl-argo-rollouts plugin not found${NC}"
  exit 1
fi
echo -e "${GREEN}Prerequisites OK${NC}\n"

# Step 1: Verify current rollout status
echo -e "${BLUE}[1/5] Checking current rollout status...${NC}"
kubectl argo rollouts get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" || {
  echo -e "${RED}Rollout $ROLLOUT_NAME not found in namespace $NAMESPACE${NC}"
  exit 1
}

# Step 2: Verify services exist
echo -e "\n${BLUE}[2/5] Verifying services...${NC}"
for svc in auth-service auth-service-stable auth-service-canary; do
  echo -n "  $svc ... "
  if kubectl get svc "$svc" -n "$NAMESPACE" &> /dev/null; then
    echo -e "${GREEN}OK${NC}"
  else
    echo -e "${RED}NOT FOUND${NC}"
    exit 1
  fi
done

# Step 3: Verify VirtualService traffic weights
echo -e "\n${BLUE}[3/5] Checking VirtualService traffic weights...${NC}"
VS_OUTPUT=$(kubectl get virtualservice auth-service-vs -n "$NAMESPACE" -o yaml 2>/dev/null || echo "not found")
if echo "$VS_OUTPUT" | grep -q "weight:"; then
  echo -e "${GREEN}VirtualService has traffic weights configured${NC}"
  echo "$VS_OUTPUT" | grep -A2 "weight:"
else
  echo -e "${YELLOW}VirtualService not found or no weights configured${NC}"
fi

# Step 4: Verify AnalysisTemplates exist
echo -e "\n${BLUE}[4/5] Checking AnalysisTemplates...${NC}"
for tmpl in auth-service-health auth-service-success-rate; do
  echo -n "  $tmpl ... "
  if kubectl get analysistemplate "$tmpl" -n "$NAMESPACE" &> /dev/null; then
    echo -e "${GREEN}OK${NC}"
  else
    echo -e "${YELLOW}NOT FOUND (will be created on first rollout)${NC}"
  fi
done

# Step 5: Verify Prometheus is reachable (for analysis)
echo -e "\n${BLUE}[5/5] Checking Prometheus connectivity...${NC}"
PROM_SVC=$(kubectl get svc prometheus -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
if [ -n "$PROM_SVC" ]; then
  echo -e "${GREEN}Prometheus service found at $PROM_SVC:9090${NC}"
else
  echo -e "${YELLOW}Prometheus service not found (metrics-based analysis may fail)${NC}"
fi

echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Canary infrastructure validation complete!${NC}"
echo -e "\nTo trigger a canary deployment:"
echo -e "  kubectl argo rollouts set image $ROLLOUT_NAME \\"
echo -e "    auth-service=paintoxic/paystream-auth-service:<new-tag> \\"
echo -e "    -n $NAMESPACE"
echo -e "\nTo monitor progress:"
echo -e "  kubectl argo rollouts get rollout $ROLLOUT_NAME -n $NAMESPACE --watch"
echo -e "\nTo promote canary to stable:"
echo -e "  kubectl argo rollouts promote $ROLLOUT_NAME -n $NAMESPACE"
echo -e "\nTo abort and rollback:"
echo -e "  kubectl argo rollouts abort $ROLLOUT_NAME -n $NAMESPACE"
