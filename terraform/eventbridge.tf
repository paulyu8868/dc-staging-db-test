# ==============================================================
# eventbridge.tf — 복제 Lambda 주기 실행 스케줄
# ==============================================================

resource "aws_cloudwatch_event_rule" "replication_schedule" {
  name        = "${local.pfx}-replication-schedule"
  description = "복제 Lambda 주기 실행 — 테스트: rate(5 minutes) / 운영: cron(0 17 * * ? *)"

  schedule_expression = var.schedule_expression

  # 기본 DISABLED — 의도치 않은 반복 실행 방지
  # 테스트 시 terraform.tfvars에서 ENABLED로 변경
  state = var.eventbridge_rule_state

  tags = { Name = "${local.pfx}-replication-schedule" }
}

resource "aws_cloudwatch_event_target" "replication_lambda" {
  rule      = aws_cloudwatch_event_rule.replication_schedule.name
  target_id = "${local.pfx}-replication-lambda"
  arn       = aws_lambda_function.replication.arn
}

# EventBridge → Lambda 호출 허용 (source_arn으로 이 룰에서만 허용)
resource "aws_lambda_permission" "eventbridge_invoke" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.replication.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.replication_schedule.arn
}

# ── modify-data 스케줄 (시나리오 A: 1분 간격 INSERT) ──────────

resource "aws_cloudwatch_event_rule" "modify_data_schedule" {
  name                = "${local.pfx}-modify-data-schedule"
  description         = "modify-data Lambda 1분 간격 실행 — 시나리오 A 테스트용"
  schedule_expression = "rate(1 minute)"
  state               = var.modify_data_rule_state

  tags = { Name = "${local.pfx}-modify-data-schedule" }
}

resource "aws_cloudwatch_event_target" "modify_data_lambda" {
  rule      = aws_cloudwatch_event_rule.modify_data_schedule.name
  target_id = "${local.pfx}-modify-data-lambda"
  arn       = aws_lambda_function.modify_data.arn
}

resource "aws_lambda_permission" "eventbridge_invoke_modify_data" {
  statement_id  = "AllowEventBridgeInvokeModifyData"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.modify_data.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.modify_data_schedule.arn
}
