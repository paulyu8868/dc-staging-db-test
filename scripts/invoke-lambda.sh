#!/usr/bin/env bash
# invoke-lambda.sh — 복제 Lambda 수동 실행 (Phase A 검증용)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"

LAMBDA_NAME=$(terraform -chdir="$TF_DIR" output -raw lambda_function_name)
REGION=$(terraform -chdir="$TF_DIR" output -raw aws_region)
RESPONSE_FILE="/tmp/lambda_response_$(date +%Y%m%d_%H%M%S).json"

echo "=== Lambda 수동 실행 ==="
echo "  함수: $LAMBDA_NAME"
echo "  리전: $REGION"
echo ""

echo "[CloudWatch 로그 (마지막 실행)]"
aws lambda invoke \
  --function-name "$LAMBDA_NAME" \
  --region "$REGION" \
  --log-type Tail \
  --query 'LogResult' \
  --output text \
  "$RESPONSE_FILE" | base64 -d

echo ""
echo "[응답 JSON]"
python3 -m json.tool "$RESPONSE_FILE" 2>/dev/null || cat "$RESPONSE_FILE"

echo ""
echo "복제 결과를 확인하려면:"
echo "  bash scripts/verify-replication.sh"
