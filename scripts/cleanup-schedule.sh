#!/usr/bin/env bash
# cleanup-schedule.sh — 테스트 후 EventBridge 룰 비활성화
# 검증 완료 후 반드시 실행할 것 (rate(5 min) 룰 방치 금지)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"

RULE_NAME=$(terraform -chdir="$TF_DIR" output -raw eventbridge_rule_name)
REGION=$(terraform -chdir="$TF_DIR" output -raw aws_region)

echo "=== EventBridge 룰 비활성화 ==="
echo "  Rule : $RULE_NAME"
echo "  Region: $REGION"
echo ""

CURRENT_STATE=$(aws events describe-rule \
  --name "$RULE_NAME" \
  --region "$REGION" \
  --query 'State' \
  --output text)

echo "현재 상태: $CURRENT_STATE"

if [ "$CURRENT_STATE" = "DISABLED" ]; then
  echo "이미 DISABLED 상태입니다."
else
  aws events disable-rule --name "$RULE_NAME" --region "$REGION"
  NEW_STATE=$(aws events describe-rule \
    --name "$RULE_NAME" \
    --region "$REGION" \
    --query 'State' \
    --output text)
  echo "변경 후 상태: $NEW_STATE"
fi

echo ""
echo "다음 단계 — 전체 리소스 삭제:"
echo "  cd terraform && terraform destroy"
echo ""
echo "※ VPC Endpoint(Secrets Manager)는 시간당 과금 → 즉시 destroy 권장"
