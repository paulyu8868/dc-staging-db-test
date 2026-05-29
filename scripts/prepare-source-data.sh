#!/usr/bin/env bash
# prepare-source-data.sh — 원본 DB에 모의 재무 데이터 + View 생성
# 실행 위치: 프로젝트 루트 또는 scripts/ 디렉토리

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"

echo "=== 원본 DB 데이터 준비 ==="

echo "[1/3] Terraform output에서 접속 정보 조회..."
SOURCE_HOST=$(terraform -chdir="$TF_DIR" output -raw source_db_address)
SOURCE_DB=$(terraform -chdir="$TF_DIR" output -raw source_db_name 2>/dev/null || echo "finance_source")
SOURCE_USER="admin"

echo "  Host : $SOURCE_HOST"
echo "  DB   : $SOURCE_DB"
echo ""
echo "[2/3] Secrets Manager에서 비밀번호 조회..."
SECRET_ARN=$(terraform -chdir="$TF_DIR" output -raw source_secret_arn)
SOURCE_PASS=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ARN" \
  --query 'SecretString' \
  --output text | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

echo "[3/3] 테이블/View 생성 및 모의 데이터 적재..."

mysql -h "$SOURCE_HOST" -P 3306 -u "$SOURCE_USER" --password="$SOURCE_PASS" "$SOURCE_DB" << 'SQL'

-- 모의 일별 매출 원본 테이블
CREATE TABLE IF NOT EXISTS raw_daily_sales (
  id         INT AUTO_INCREMENT PRIMARY KEY,
  sale_date  DATE           NOT NULL,
  product    VARCHAR(50)    NOT NULL,
  amount     DECIMAL(12, 2) NOT NULL,
  region     VARCHAR(20)    NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Staging으로 복제될 분석용 View (민감 컬럼 제외 가능)
CREATE OR REPLACE VIEW v_daily_sales AS
SELECT id, sale_date, product, amount, region
FROM raw_daily_sales;

-- 기존 데이터 초기화 (멱등 실행용)
TRUNCATE TABLE raw_daily_sales;

-- 모의 재무 데이터 10건
INSERT INTO raw_daily_sales (sale_date, product, amount, region) VALUES
  ('2026-05-01', 'Product A', 1500000.00, 'Seoul'),
  ('2026-05-01', 'Product B',  800000.00, 'Busan'),
  ('2026-05-02', 'Product A', 2100000.00, 'Seoul'),
  ('2026-05-02', 'Product C',  350000.00, 'Incheon'),
  ('2026-05-03', 'Product B', 1200000.00, 'Seoul'),
  ('2026-05-03', 'Product A',  980000.00, 'Daegu'),
  ('2026-05-04', 'Product C', 2750000.00, 'Seoul'),
  ('2026-05-04', 'Product B',  620000.00, 'Busan'),
  ('2026-05-05', 'Product A', 1890000.00, 'Seoul'),
  ('2026-05-05', 'Product C',  430000.00, 'Incheon');

SELECT '데이터 준비 완료' AS status;
SELECT COUNT(*) AS v_daily_sales_row_count FROM v_daily_sales;
SQL

echo ""
echo "완료. Lambda를 실행해 복제를 테스트하세요:"
echo "  bash scripts/invoke-lambda.sh"
