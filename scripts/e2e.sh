#!/usr/bin/env bash
set -euo pipefail

# End-to-end verifier for this demo:
# - POST a survey to API Gateway
# - Poll DynamoDB until the sentiment result appears (or timeout)
#
# Usage:
#   ./scripts/e2e.sh
#   AWS_PROFILE=dev ./scripts/e2e.sh
#
# Requirements:
# - curl
# - aws CLI configured (e.g. AWS_PROFILE, env credentials, instance role)

REGION="${REGION:-ap-southeast-2}"
ENDPOINT="${ENDPOINT:-$(terraform output -raw survey_endpoint 2>/dev/null || true)}"
TABLE="${TABLE:-$(terraform output -raw dynamodb_table_name 2>/dev/null || true)}"

if [[ -z "${ENDPOINT}" || -z "${TABLE}" ]]; then
  echo "ENDPOINT or TABLE is empty."
  echo "Either run from a deployed terraform workspace or set:"
  echo "  ENDPOINT=... TABLE=... REGION=..."
  exit 1
fi

SURVEY_ID="survey-e2e-$(date +%s)"
PAYLOAD="$(cat <<JSON
{
  "id": "${SURVEY_ID}",
  "customerId": "customer-e2e",
  "surveyText": "I love this product! It works perfectly & the customer service is excellent."
}
JSON
)"

echo "--- posting survey (id=${SURVEY_ID})"
curl -sS -X POST "${ENDPOINT}" -H "Content-Type: application/json" -d "${PAYLOAD}" | cat
echo

KEY_JSON="$(cat <<JSON
{"id":{"S":"${SURVEY_ID}"}}
JSON
)"

echo "--- polling DynamoDB table ${TABLE} in ${REGION} (timeout ~60s)"
for i in $(seq 1 12); do
  OUT="$(aws dynamodb get-item --region "${REGION}" --consistent-read --table-name "${TABLE}" --key "${KEY_JSON}" || true)"
  if echo "${OUT}" | grep -q '"Item"'; then
    echo "FOUND:"
    echo "${OUT}"
    exit 0
  fi
  echo "not yet (${i}/12)"
  sleep 5
done

echo "NOT FOUND after ~60s (id=${SURVEY_ID})"
exit 2


