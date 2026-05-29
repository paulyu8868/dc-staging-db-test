# ==============================================================
# rds-source.tf — 원본 DB (Private, Public Access OFF)
# ==============================================================

resource "aws_db_subnet_group" "source" {
  name        = "${local.pfx}-source-subnet-grp"
  subnet_ids  = aws_subnet.private[*].id
  description = "Source DB - Private Subnet 2 AZ"

  tags = { Name = "${local.pfx}-source-subnet-grp" }
}

resource "aws_db_instance" "source_rds" {
  identifier        = "${local.pfx}-source-db"
  engine            = "mysql"
  engine_version    = var.db_engine_version
  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage
  storage_type      = "gp2"

  db_name  = var.source_db_name
  username = var.source_db_username

  # 비밀번호를 AWS Secrets Manager에서 자동 관리
  # → Terraform 코드/state에 평문 노출 없음
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.source.name
  vpc_security_group_ids = [aws_security_group.source_rds.id]

  # 원본 DB는 반드시 Private — 인터넷 직접 노출 금지
  publicly_accessible = false
  multi_az            = false

  # sandbox: 즉시 삭제 + 자동 백업 비활성화 (불필요 비용 방지)
  skip_final_snapshot     = true
  deletion_protection     = false
  backup_retention_period = 0

  tags = { Name = "${local.pfx}-source-db" }
}
