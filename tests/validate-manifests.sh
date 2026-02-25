#!/usr/bin/env bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo -e "${YELLOW}Validating Kubernetes manifests...${NC}"

# Check if kubeconform is installed
if ! command -v kubeconform &> /dev/null; then
  echo -e "${RED}kubeconform not found. Install with: brew install kubeconform${NC}"
  exit 1
fi

ERRORS=0

# Validate standard K8s manifests
echo -e "\n${YELLOW}[1/3] Validating base manifests...${NC}"
find "$PROJECT_ROOT/k8s/base" -name '*.yaml' | while read -r file; do
  echo -n "  $file ... "
  if kubeconform -strict -ignore-missing-schemas \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    "$file" 2>&1; then
    echo -e "${GREEN}OK${NC}"
  else
    echo -e "${RED}FAIL${NC}"
    ERRORS=$((ERRORS + 1))
  fi
done

echo -e "\n${YELLOW}[2/3] Validating networking manifests...${NC}"
find "$PROJECT_ROOT/k8s/networking" -name '*.yaml' | while read -r file; do
  echo -n "  $file ... "
  if kubeconform -strict -ignore-missing-schemas \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    "$file" 2>&1; then
    echo -e "${GREEN}OK${NC}"
  else
    echo -e "${RED}FAIL${NC}"
    ERRORS=$((ERRORS + 1))
  fi
done

echo -e "\n${YELLOW}[3/3] Validating namespace and rollout manifests...${NC}"
for file in "$PROJECT_ROOT/k8s/namespaces.yaml"; do
  echo -n "  $file ... "
  if kubeconform -strict -ignore-missing-schemas "$file" 2>&1; then
    echo -e "${GREEN}OK${NC}"
  else
    echo -e "${RED}FAIL${NC}"
    ERRORS=$((ERRORS + 1))
  fi
done

echo ""
if [ "$ERRORS" -gt 0 ]; then
  echo -e "${RED}Validation failed with $ERRORS error(s)${NC}"
  exit 1
fi
echo -e "${GREEN}All manifests validated successfully!${NC}"
