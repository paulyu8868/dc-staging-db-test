# ==============================================================
# network.tf — VPC / Subnet / IGW / NAT 대신 VPC Endpoint /
#              Route Table
# VPC Endpoint(Interface) for Secrets Manager: NAT Gateway보다
# 저렴 (시간당 $0.01 vs $0.059). Lambda가 VPC 내에서 Secrets
# Manager에 접근하기 위해 필수.
# ==============================================================

locals {
  # 이름 prefix 편의 단축
  pfx = var.project_name
}

# ── VPC ───────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name    = "${local.pfx}-vpc"
    Project = local.pfx
  }
}

# ── Public Subnets (Staging DB용, 2 AZ) ──────────────────────
resource "aws_subnet" "public" {
  count             = length(var.public_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  # Staging DB가 Public Accessibility: YES이므로 Public Subnet
  map_public_ip_on_launch = false # EC2는 없음. RDS에는 무관.

  tags = {
    Name    = "${local.pfx}-public-${var.availability_zones[count.index]}"
    Project = local.pfx
    Tier    = "public"
  }
}

# ── Private Subnets (원본 DB + Lambda용, 2 AZ) ────────────────
resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name    = "${local.pfx}-private-${var.availability_zones[count.index]}"
    Project = local.pfx
    Tier    = "private"
  }
}

# ── Internet Gateway (Public Subnet → 인터넷) ─────────────────
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name    = "${local.pfx}-igw"
    Project = local.pfx
  }
}

# ── Public Route Table ────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name    = "${local.pfx}-rt-public"
    Project = local.pfx
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── Private Route Table ───────────────────────────────────────
# NAT Gateway 없이 VPC Endpoint만 사용 → 인터넷 기본 경로 없음
# Lambda → Secrets Manager: VPC Endpoint(아래)로 해결
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name    = "${local.pfx}-rt-private"
    Project = local.pfx
  }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ── Security Group: VPC Endpoint용 ───────────────────────────
# Lambda-SG(TCP 443 outbound)가 이 SG로 들어오는 것을 허용
resource "aws_security_group" "vpc_endpoint" {
  name        = "${local.pfx}-sg-vpce"
  description = "VPC Endpoint SG - Allow HTTPS from Lambda via private subnet CIDRs"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from Lambda for Secrets Manager VPC Endpoint"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.private_subnet_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${local.pfx}-sg-vpce"
    Project = local.pfx
  }
}

# ── VPC Endpoint — Secrets Manager (Interface) ───────────────
# NAT Gateway 대신 사용. Lambda가 VPC 내부에서 Secrets Manager에
# 접근하기 위한 Private DNS 지원 Interface Endpoint.
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoint.id]
  private_dns_enabled = true # SDK가 별도 설정 없이 endpoint를 자동 사용

  tags = {
    Name    = "${local.pfx}-vpce-secretsmanager"
    Project = local.pfx
  }
}
