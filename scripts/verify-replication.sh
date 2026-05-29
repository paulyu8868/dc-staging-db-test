#!/usr/bin/env bash
# verify-replication.sh — Lambda 실행 결과 + Staging DB 행수 검증

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"

echo "=== 복제 검증 ==="

STAGING_HOST=$(terraform -chdir="$TF_DIR" output -raw staging_db_address)
STAGING_DB="analytics_staging"
STAGING_USER="admin"

# Secrets Manager에서 Staging DB 비밀번호 조회
SECRET_ARN=$(terraform -chdir="$TF_DIR" output -raw target_secret_arn)
STAGING_PASS=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ARN" \
  --query 'SecretString' \
  --output text | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

echo "  Staging DB: $STAGING_HOST"
echo ""

# Lambda 최신 실행 결과를 CloudWatch Logs에서 조회
LAMBDA_NAME=$(terraform -chdir="$TF_DIR" output -raw lambda_function_name)
REGION=$(terraform -chdir="$TF_DIR" output -raw aws_region)

echo "[1/2] Lambda 최신 실행 결과 (CloudWatch Logs)"
LOG_GROUP="/aws/lambda/$LAMBDA_NAME"
LATEST_STREAM=$(aws logs describe-log-streams \
  --log-group-name "$LOG_GROUP" \
  --region "$REGION" \
  --order-by LastEventTime \
  --descending \
  --max-items 1 \
  --query 'logStreams[0].logStreamName' \
  --output text 2>/dev/null || echo "")

if [ -n "$LATEST_STREAM" ] && [ "$LATEST_STREAM" != "None" ]; then
  aws logs get-log-events \
    --log-group-name "$LOG_GROUP" \
    --log-stream-name "$LATEST_STREAM" \
    --region "$REGION" \
    --limit 20 \
    --query 'events[*].message' \
    --output text 2>/dev/null | grep -E "(복제|status|rows)" || true
fi

echo ""
echo "[2/2] Staging DB 행수 확인"

# config에 정의된 모든 target_table 행수 조회
CONFIG_FILE="$SCRIPT_DIR/../config/replication-config.json"
TABLES=$(python3 -c "
import json, sys
cfg = json.load(open('$CONFIG_FILE'))
for item in cfg:
    print(item['source_view'], item['target_table'])
")

DATE=$(date +%Y-%m-%d)
ALL_PASSED=true

echo ""
printf "%-15s %-20s %-12s\n" "View" "Staging 테이블" "행수"
echo "-------------------------------------------------------"

while IFS=' ' read -r view table; do
  COUNT=$(mysql -h "$STAGING_HOST" -P 3306 \
    -u "$STAGING_USER" --password="$STAGING_PASS" \
    --ssl-mode=REQUIRED -s -N \
    -e "SELECT COUNT(*) FROM \`$STAGING_DB\`.\`$table\`;" 2>/dev/null || echo "ERROR")

  printf "%-15s %-20s %-12s\n" "$view" "$table" "$COUNT"

  if [ "$COUNT" = "ERROR" ]; then
    ALL_PASSED=false
  fi
done <<< "$TABLES"

echo ""
if $ALL_PASSED; then
  echo "검증 결과 기록 형식 (phase-a-replication-results.md):"
  while IFS=' ' read -r view table; do
    COUNT=$(mysql -h "$STAGING_HOST" -P 3306 \
      -u "$STAGING_USER" --password="$STAGING_PASS" \
      --ssl-mode=REQUIRED -s -N \
      -e "SELECT COUNT(*) FROM \`$STAGING_DB\`.\`$table\`;" 2>/dev/null)
    echo "| $DATE | Phase A | $view | - | $COUNT | - | - | - |"
  done <<< "$TABLES"
else
  echo "검증 실패 — Staging 테이블 접근 오류. SG/TLS/Lambda 실행 여부 확인."
  exit 1
fi
