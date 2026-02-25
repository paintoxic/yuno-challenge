#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
BASE_URL="${BASE_URL:-http://localhost:8080}"
PASS=0
FAIL=0

run_test() {
  local name="$1"
  local expected_code="$2"
  local method="$3"
  local url="$4"
  local body="${5:-}"

  echo -n "  $name ... "

  if [ -n "$body" ]; then
    HTTP_CODE=$(curl -s -o /tmp/test_response.json -w "%{http_code}" \
      -X "$method" -H "Content-Type: application/json" \
      -d "$body" "$url")
  else
    HTTP_CODE=$(curl -s -o /tmp/test_response.json -w "%{http_code}" \
      -X "$method" "$url")
  fi

  if [ "$HTTP_CODE" = "$expected_code" ]; then
    echo -e "${GREEN}PASS${NC} (HTTP $HTTP_CODE)"
    PASS=$((PASS + 1))
  else
    echo -e "${RED}FAIL${NC} (expected $expected_code, got $HTTP_CODE)"
    cat /tmp/test_response.json 2>/dev/null || true
    echo ""
    FAIL=$((FAIL + 1))
  fi
}

echo -e "${YELLOW}PayStream Auth Service — Integration Tests${NC}"
echo -e "${YELLOW}Base URL: $BASE_URL${NC}\n"

# Health endpoint
echo -e "${YELLOW}[1/4] Health Check${NC}"
run_test "GET /health returns 200" "200" "GET" "$BASE_URL/health"

# Authorization endpoint - valid requests
echo -e "\n${YELLOW}[2/4] Authorization — Valid Requests${NC}"
run_test "Visa transaction (Maria Garcia, $2,450.00 USD)" "200" "POST" "$BASE_URL/v1/authorize" \
  '{"card_number":"4532-8921-0045-1234","amount":2450.00,"currency":"USD","merchant":"Amazon Web Services","processor":"visa"}'

run_test "Mastercard transaction (Carlos Lopez, €189.99 EUR)" "200" "POST" "$BASE_URL/v1/authorize" \
  '{"card_number":"5412-7534-0098-7721","amount":189.99,"currency":"EUR","merchant":"El Corte Inglés","processor":"mastercard"}'

run_test "AMEX transaction (Ana Martínez, $15,000.00 USD)" "200" "POST" "$BASE_URL/v1/authorize" \
  '{"card_number":"3782-822463-10005","amount":15000.00,"currency":"USD","merchant":"Salesforce Inc","processor":"amex"}'

# Authorization endpoint - invalid requests
echo -e "\n${YELLOW}[3/4] Authorization — Error Cases${NC}"
run_test "GET /v1/authorize returns 405" "405" "GET" "$BASE_URL/v1/authorize"
run_test "Invalid JSON body returns 400" "400" "POST" "$BASE_URL/v1/authorize" "not-json"

# Metrics endpoint
echo -e "\n${YELLOW}[4/4] Observability${NC}"
run_test "GET /metrics returns 200" "200" "GET" "$BASE_URL/metrics"

# Verify metrics content
echo -n "  Metrics contain auth_requests_total ... "
if grep -q "auth_requests_total" /tmp/test_response.json 2>/dev/null; then
  echo -e "${GREEN}PASS${NC}"
  PASS=$((PASS + 1))
else
  echo -e "${RED}FAIL${NC}"
  FAIL=$((FAIL + 1))
fi

# Fault injection test
echo -e "\n${YELLOW}[Bonus] Fault Injection${NC}"
run_test "Enable fault injection" "200" "POST" "$BASE_URL/admin/fault-inject" \
  '{"enabled":true,"latency_ms":5000,"success_rate":0.3}'
run_test "Disable fault injection" "200" "POST" "$BASE_URL/admin/fault-inject" \
  '{"enabled":false,"latency_ms":0,"success_rate":1.0}'

# Summary
echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
TOTAL=$((PASS + FAIL))
echo -e "Total: $TOTAL | ${GREEN}Pass: $PASS${NC} | ${RED}Fail: $FAIL${NC}"
if [ "$FAIL" -gt 0 ]; then
  echo -e "${RED}Some tests failed!${NC}"
  exit 1
fi
echo -e "${GREEN}All tests passed!${NC}"
