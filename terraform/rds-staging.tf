# ==============================================================
# rds-staging.tf — Staging DB (Public, TLS 강제, DC 연결 대상)
# ==============================================================

resource "aws_db_subnet_group" "staging" {
  name        = "${local.pfx}-staging-subnet-grp"
  subnet_ids  = aws_subnet.public[*].id
  description = "Staging DB - Public Subnet 2 AZ"

  tags = { Name = "${local.pfx}-staging-subnet-grp" }
}

# TLS 전송 강제 파라미터 그룹
# require_secure_transport=ON → TLS 없이 연결 시 즉시 거부
resource "aws_db_parameter_group" "staging_tls" {
  name        = "${local.pfx}-staging-tls-pg"
  family      = "mysql8.0"
  description = "Staging DB: require_secure_transport=ON"

  parameter {
    name         = "require_secure_transport"
    value        = "1"
    apply_method = "immediate"
  }

  tags = { Name = "${local.pfx}-staging-tls-pg" }
}

resource "aws_db_instance" "staging_rds" {
  identifier        = "${local.pfx}-staging-db"
  engine            = "mysql"
  engine_version    = var.db_engine_version
  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage
  storage_type      = "gp2"

  db_name  = var.staging_db_name
  username = var.staging_db_username

  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.staging.name
  vpc_security_group_ids = [aws_security_group.target_rds.id]
  parameter_group_name   = aws_db_parameter_group.staging_tls.name

  # 검증 핵심: DC가 직접 연결해야 하므로 Public ON
  # 보안: SG에서 DC KOR6 6개 IP로만 제한 + TLS 강제
  publicly_accessible = true
  multi_az            = false

  skip_final_snapshot     = true
  deletion_protection     = false
  backup_retention_period = 0

  tags = { Name = "${local.pfx}-staging-db" }
}
