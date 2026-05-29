# ==============================================================
# security-groups.tf — Source RDS / Staging RDS / Lambda SG
#
# [순환 의존 방지 설계]
# Lambda SG ↔ Source/Target RDS SG 간 상호 참조가 발생하므로,
# aws_security_group 리소스에는 inline 규칙을 두지 않는다.
# 모든 규칙은 aws_security_group_rule로 분리 선언.
# → Terraform은 SG 리소스 간 dep 없이 rule 리소스로만 dep 해소.
# ==============================================================

# ── 1. SG 리소스 (규칙 없음) ──────────────────────────────────

resource "aws_security_group" "source_rds" {
  name        = "${local.pfx}-sg-source-rds"
  description = "Source RDS SG - Private. Allow inbound from Lambda only."
  vpc_id      = aws_vpc.main.id

  # inline 규칙을 rule 리소스로 분리했으므로
  # 기본 egress ALL 자동 생성 방지 (아래 egress rule에서 명시)
  lifecycle {
    # SG 교체 없이 이름 변경이 발생하지 않도록 보호
    create_before_destroy = true
  }

  tags = {
    Name    = "${local.pfx}-sg-source-rds"
    Project = local.pfx
  }
}

resource "aws_security_group" "target_rds" {
  name        = "${local.pfx}-sg-target-rds"
  description = "Staging RDS SG - Public. Allow Lambda + DC KOR6 IPs inbound."
  vpc_id      = aws_vpc.main.id

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name    = "${local.pfx}-sg-target-rds"
    Project = local.pfx
  }
}

resource "aws_security_group" "lambda" {
  name        = "${local.pfx}-sg-lambda"
  description = "Lambda SG - Outbound to both RDS and Secrets Manager VPC Endpoint."
  vpc_id      = aws_vpc.main.id

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name    = "${local.pfx}-sg-lambda"
    Project = local.pfx
  }
}

# ── 2. Source RDS 규칙 ────────────────────────────────────────

# Lambda → Source RDS (복제 배치용 읽기)
resource "aws_security_group_rule" "source_rds_from_lambda" {
  type                     = "ingress"
  description              = "MySQL inbound from Lambda replication batch"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  security_group_id        = aws_security_group.source_rds.id
  source_security_group_id = aws_security_group.lambda.id
}

# 내 IP → Source RDS (테스트 데이터 준비 시 DML 접근, 선택)
# my_ip_cidr 기본값(0.0.0.0/32)을 실제 IP로 교체하면 자동 생성
resource "aws_security_group_rule" "source_rds_from_my_ip" {
  count = var.my_ip_cidr != "0.0.0.0/32" ? 1 : 0

  type              = "ingress"
  description       = "MySQL inbound from local dev PC - optional for test data setup"
  from_port         = 3306
  to_port           = 3306
  protocol          = "tcp"
  security_group_id = aws_security_group.source_rds.id
  cidr_blocks       = [var.my_ip_cidr]
}

# Source RDS egress: RDS는 인바운드만 필요하지만 Terraform 기본 egress ALL 유지
resource "aws_security_group_rule" "source_rds_egress_all" {
  type              = "egress"
  description       = "Default outbound for RDS response traffic"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.source_rds.id
  cidr_blocks       = ["0.0.0.0/0"]
}

# ── 3. Staging (Target) RDS 규칙 ─────────────────────────────

# Lambda → Staging RDS (복제 배치용 쓰기)
resource "aws_security_group_rule" "target_rds_from_lambda" {
  type                     = "ingress"
  description              = "MySQL inbound from Lambda - RENAME swap write"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  security_group_id        = aws_security_group.target_rds.id
  source_security_group_id = aws_security_group.lambda.id
}

# DC KOR6 → Staging RDS (Salesforce DC 읽기용)
# IP 1개당 rule 1개. for_each로 관리 (추가/삭제 시 diff 최소화)
resource "aws_security_group_rule" "target_rds_from_dc_kor6" {
  for_each = toset(var.dc_kor6_outbound_ips)

  type              = "ingress"
  description       = "Salesforce DC KOR6 outbound IP - read access"
  from_port         = 3306
  to_port           = 3306
  protocol          = "tcp"
  security_group_id = aws_security_group.target_rds.id
  cidr_blocks       = [each.value]
}

# 내 IP → Staging RDS (검증용, 선택)
resource "aws_security_group_rule" "target_rds_from_my_ip" {
  count = var.my_ip_cidr != "0.0.0.0/32" ? 1 : 0

  type              = "ingress"
  description       = "MySQL inbound from local dev PC - optional for verification"
  from_port         = 3306
  to_port           = 3306
  protocol          = "tcp"
  security_group_id = aws_security_group.target_rds.id
  cidr_blocks       = [var.my_ip_cidr]
}

resource "aws_security_group_rule" "target_rds_egress_all" {
  type              = "egress"
  description       = "Default outbound for RDS response traffic"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.target_rds.id
  cidr_blocks       = ["0.0.0.0/0"]
}

# ── 4. Lambda 규칙 ────────────────────────────────────────────

# Lambda → Source RDS (MySQL outbound)
resource "aws_security_group_rule" "lambda_to_source_rds" {
  type                     = "egress"
  description              = "MySQL outbound to source DB"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  security_group_id        = aws_security_group.lambda.id
  source_security_group_id = aws_security_group.source_rds.id
}

# Lambda → Staging RDS (MySQL outbound)
resource "aws_security_group_rule" "lambda_to_target_rds" {
  type                     = "egress"
  description              = "MySQL outbound to staging DB - RENAME swap write"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  security_group_id        = aws_security_group.lambda.id
  source_security_group_id = aws_security_group.target_rds.id
}

# Lambda → Secrets Manager VPC Endpoint (HTTPS, VPC 내부)
# SSM(Parameter Store) Endpoint는 테스트 단계에서 생략.
# Lambda 환경변수로 REPLICATION_CONFIG를 직접 주입.
resource "aws_security_group_rule" "lambda_to_secretsmanager_vpce" {
  type              = "egress"
  description       = "HTTPS outbound to Secrets Manager VPC Endpoint"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.lambda.id
  # VPC Endpoint는 VPC CIDR 내부 주소로 응답 → VPC CIDR로 허용
  cidr_blocks = [var.vpc_cidr]
}
