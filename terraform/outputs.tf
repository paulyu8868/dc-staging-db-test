# ==============================================================
# outputs.tf — 검증/운영에 필요한 엔드포인트, 명령어, 안내
# ==============================================================

output "aws_region" {
  description = "배포 리전"
  value       = var.aws_region
}

# ── DB Endpoints ─────────────────────────────────────────────

output "source_db_endpoint" {
  description = "원본 DB 엔드포인트 host:port (VPC 내부 전용 — 외부 접근 불가)"
  value       = aws_db_instance.source_rds.endpoint
}

output "source_db_address" {
  description = "원본 DB 호스트명 (포트 제외)"
  value       = aws_db_instance.source_rds.address
}

output "staging_db_endpoint" {
  description = "Staging DB 엔드포인트 host:port (Public — DC 연결 대상)"
  value       = aws_db_instance.staging_rds.endpoint
}

output "staging_db_address" {
  description = "Staging DB 호스트명 (포트 제외)"
  value       = aws_db_instance.staging_rds.address
}

# ── Secrets Manager ──────────────────────────────────────────

output "source_secret_arn" {
  description = "원본 DB Secrets Manager ARN"
  value       = aws_db_instance.source_rds.master_user_secret[0].secret_arn
}

output "target_secret_arn" {
  description = "Staging DB Secrets Manager ARN"
  value       = aws_db_instance.staging_rds.master_user_secret[0].secret_arn
}

# ── Lambda ───────────────────────────────────────────────────

output "lambda_function_name" {
  description = "복제 Lambda 함수 이름"
  value       = aws_lambda_function.replication.function_name
}

output "lambda_invoke_command" {
  description = "Phase A 수동 실행 명령어 (로그 포함)"
  value       = <<-EOT
    aws lambda invoke \
      --function-name ${aws_lambda_function.replication.function_name} \
      --region ${var.aws_region} \
      --log-type Tail \
      --query 'LogResult' \
      --output text \
      /tmp/response.json | base64 -d && echo "" && cat /tmp/response.json
  EOT
}

# ── EventBridge ──────────────────────────────────────────────

output "eventbridge_rule_name" {
  description = "EventBridge 스케줄 룰 이름 (cleanup-schedule.sh용)"
  value       = aws_cloudwatch_event_rule.replication_schedule.name
}

# ── DB 연결 명령어 (my_ip_cidr SG 규칙 필요) ─────────────────

output "staging_db_mysql_connect" {
  description = "Staging DB MySQL 연결 명령어 (my_ip_cidr 설정 필요, TLS 강제)"
  value       = "mysql -h ${aws_db_instance.staging_rds.address} -P 3306 -u ${var.staging_db_username} -p --ssl-mode=REQUIRED ${var.staging_db_name}"
}

# ── 정리 안내 ─────────────────────────────────────────────────

output "destroy_guide" {
  description = "테스트 완료 후 리소스 정리 절차"
  value       = <<-EOT
    [정리 절차]
    1. EventBridge 룰 비활성화:
       bash scripts/cleanup-schedule.sh
    2. 전체 리소스 삭제:
       cd terraform && terraform destroy
    ※ VPC Endpoint(Secrets Manager)는 시간당 과금 → 즉시 destroy 권장
    ※ NAT Gateway 미사용, RDS 자동 백업 비활성화 → 추가 잔여 비용 없음
  EOT
}
