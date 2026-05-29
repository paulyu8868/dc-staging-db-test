# ==============================================================
# lambda-modify-data.tf — 원본 DB에 1행 INSERT (시나리오 A용)
# ==============================================================

data "archive_file" "modify_data_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda-modify-data"
  output_path = "${path.module}/../modify-data-lambda.zip"
}

resource "aws_cloudwatch_log_group" "modify_data" {
  name              = "/aws/lambda/${local.pfx}-modify-data"
  retention_in_days = 7

  tags = { Name = "${local.pfx}-modify-data-logs" }
}

resource "aws_lambda_function" "modify_data" {
  filename         = data.archive_file.modify_data_zip.output_path
  function_name    = "${local.pfx}-modify-data"
  role             = aws_iam_role.lambda.arn
  handler          = "modify_handler.handler"
  runtime          = "python3.12"
  source_code_hash = data.archive_file.modify_data_zip.output_base64sha256

  timeout     = 60
  memory_size = 256

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      SOURCE_SECRET_ARN = aws_db_instance.source_rds.master_user_secret[0].secret_arn
      SOURCE_DB_HOST    = aws_db_instance.source_rds.address
      SOURCE_DB_NAME    = var.source_db_name
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_vpc_execution,
    aws_iam_role_policy.lambda_secrets,
    aws_cloudwatch_log_group.modify_data,
  ]

  tags = { Name = "${local.pfx}-modify-data" }
}
