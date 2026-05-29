# ==============================================================
# lambda.tf — 복제 Lambda + IAM Role + VPC 설정
# ==============================================================

# ── IAM: Lambda 실행 역할 ──────────────────────────────────────

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${local.pfx}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json

  tags = { Name = "${local.pfx}-lambda-role" }
}

# VPC 접근 실행 역할 (ENI 생성/삭제 권한 + 기본 CloudWatch Logs)
# VPC Lambda는 이 관리형 정책 없으면 ENI 생성 실패로 배포 오류 발생
resource "aws_iam_role_policy_attachment" "lambda_vpc_execution" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Secrets Manager 읽기 — 두 시크릿 ARN으로만 최소 권한 부여
data "aws_iam_policy_document" "lambda_secrets" {
  statement {
    sid    = "SecretsManagerRead"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      aws_db_instance.source_rds.master_user_secret[0].secret_arn,
      aws_db_instance.staging_rds.master_user_secret[0].secret_arn,
    ]
  }
}

resource "aws_iam_role_policy" "lambda_secrets" {
  name   = "${local.pfx}-lambda-secrets-policy"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_secrets.json
}

# ── Lambda 코드 패키징 ────────────────────────────────────────
# [사전 조건] pymysql을 lambda/ 디렉토리에 설치 후 apply
#   pip install -r lambda/requirements.txt -t lambda/
# 설치 없이 apply하면 런타임에서 pymysql import 오류 발생

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"
  output_path = "${path.module}/../lambda.zip"
  excludes    = ["requirements.txt"]
}

# ── Lambda 함수 ──────────────────────────────────────────────

resource "aws_lambda_function" "replication" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "${local.pfx}-replication"
  role             = aws_iam_role.lambda.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  timeout     = var.lambda_timeout
  memory_size = var.lambda_memory_mb

  # Private Subnet 배치 → 원본 DB(Private) + Staging DB(Public) 모두 VPC 라우팅으로 접근
  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      SOURCE_SECRET_ARN  = aws_db_instance.source_rds.master_user_secret[0].secret_arn
      TARGET_SECRET_ARN  = aws_db_instance.staging_rds.master_user_secret[0].secret_arn
      SOURCE_DB_NAME     = var.source_db_name
      STAGING_DB_NAME    = var.staging_db_name
      SOURCE_DB_HOST     = aws_db_instance.source_rds.address
      TARGET_DB_HOST     = aws_db_instance.staging_rds.address
      # config/replication-config.json 내용을 환경변수로 embed (SSM 미사용)
      REPLICATION_CONFIG = file("${path.module}/../config/replication-config.json")
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_vpc_execution,
    aws_iam_role_policy.lambda_secrets,
    aws_cloudwatch_log_group.lambda,
  ]

  tags = { Name = "${local.pfx}-replication" }
}

# CloudWatch Log Group — retention 명시 관리 (기본값은 무제한)
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.pfx}-replication"
  retention_in_days = 7

  tags = { Name = "${local.pfx}-lambda-logs" }
}
