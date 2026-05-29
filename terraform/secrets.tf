# ==============================================================
# secrets.tf — RDS 자격증명 관리 전략 문서화
#
# [채택 방식] manage_master_user_password = true
#
# RDS가 master password를 직접 생성하고 Secrets Manager에 저장.
# Terraform 코드에도, state에도 평문 비밀번호가 존재하지 않음.
#
# AWS 자동 생성 시크릿 JSON 형식:
#   {
#     "username":              "admin",
#     "password":              "<AWS 자동 생성>",
#     "engine":                "mysql",
#     "host":                  "xxx.rds.amazonaws.com",
#     "port":                  3306,
#     "dbInstanceIdentifier":  "anua-dc-test-source-db"
#   }
#
# Lambda 환경변수:
#   SOURCE_SECRET_ARN = aws_db_instance.source_rds.master_user_secret[0].secret_arn
#   TARGET_SECRET_ARN = aws_db_instance.staging_rds.master_user_secret[0].secret_arn
#
# NOTE: AWS auto-managed secret에는 dbname이 포함되지 않으므로
#       Lambda 환경변수 SOURCE_DB_NAME / STAGING_DB_NAME 으로 별도 주입.
# ==============================================================
