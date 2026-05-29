# ==============================================================
# variables.tf — Salesforce DC Staging DB 복제 패턴 검증
# 모든 환경별 값은 이 파일에서 관리. 하드코딩 금지.
# ==============================================================

# ── 공통 ──────────────────────────────────────────────────────
variable "aws_region" {
  description = "배포 AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "리소스 이름 prefix"
  type        = string
  default     = "anua-dc-test"
}

# ── 네트워크 ──────────────────────────────────────────────────
variable "vpc_cidr" {
  description = "VPC CIDR 블록"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Public Subnet CIDR 목록 (Staging DB용, 2 AZ)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private Subnet CIDR 목록 (원본 DB + Lambda용, 2 AZ)"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "availability_zones" {
  description = "사용할 AZ 목록 (2개 필수 — RDS Subnet Group 요구사항)"
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}

# ── IP allowlist ──────────────────────────────────────────────
# Phase B 시작 전 Salesforce 공식 페이지에서 최신 IP 확인 필수
# https://help.salesforce.com/s/articleView?id=data.c360_a_data_cloud_ip_address_allowlist.htm
variable "dc_kor6_outbound_ips" {
  description = "Salesforce DC KOR6 Outbound IP 목록 (CIDR 형식, /32)"
  type        = list(string)
  # 실제 IP는 Phase B 시작 전 공식 페이지에서 확인 후 tfvars에 입력
  default = [
    "3.97.88.239/32",
    "3.98.246.168/32",
    "15.223.138.191/32",
    "3.99.254.231/32",
    "35.182.152.164/32",
    "52.60.48.144/32",
    "3.98.111.171/32",
    "3.97.239.71/32",
    "99.79.178.202/32",
    "3.98.79.254/32",
    "15.223.107.129/32",
    "52.60.81.101/32",
  ]
}

variable "my_ip_cidr" {
  description = "로컬 개발/검증용 내 IP (CIDR 형식, /32). terraform.tfvars에 입력."
  type        = string
  default     = "0.0.0.0/32" # terraform.tfvars에서 반드시 실제 IP로 교체
}

# ── RDS 공통 ──────────────────────────────────────────────────
variable "db_instance_class" {
  description = "RDS 인스턴스 타입 (원본/Staging 공통)"
  type        = string
  default     = "db.t3.micro"
}

variable "db_engine_version" {
  description = "MySQL 버전"
  type        = string
  default     = "8.0"
}

variable "db_allocated_storage" {
  description = "RDS 스토리지(GB)"
  type        = number
  default     = 20
}

# ── 원본 DB ───────────────────────────────────────────────────
variable "source_db_name" {
  description = "원본 DB 데이터베이스명"
  type        = string
  default     = "finance_source"
}

variable "source_db_username" {
  description = "원본 DB 마스터 사용자명"
  type        = string
  default     = "admin"
}

# ── Staging DB ────────────────────────────────────────────────
variable "staging_db_name" {
  description = "Staging DB 데이터베이스명"
  type        = string
  default     = "analytics_staging"
}

variable "staging_db_username" {
  description = "Staging DB 마스터 사용자명"
  type        = string
  default     = "admin"
}

# ── Lambda ────────────────────────────────────────────────────
variable "lambda_timeout" {
  description = "Lambda 최대 실행 시간(초). 1만건 기준 여유 있게 설정."
  type        = number
  default     = 300
}

variable "lambda_memory_mb" {
  description = "Lambda 메모리(MB)"
  type        = number
  default     = 256
}

# ── EventBridge 스케줄 ────────────────────────────────────────
variable "schedule_expression" {
  description = <<-EOT
    EventBridge 스케줄 표현식.
    테스트: "rate(5 minutes)"
    운영:   "cron(0 17 * * ? *)"  # UTC 17:00 = KST 02:00
  EOT
  type        = string
  default     = "rate(5 minutes)" # 테스트 기본값. 운영 전환 시 교체
}

variable "eventbridge_rule_state" {
  description = "복제 EventBridge 룰 활성화 여부 (rate 5 min). 검증 후 DISABLED로 변경 필수."
  type        = string
  default     = "DISABLED"
  validation {
    condition     = contains(["ENABLED", "DISABLED"], var.eventbridge_rule_state)
    error_message = "ENABLED 또는 DISABLED 만 허용"
  }
}

variable "modify_data_rule_state" {
  description = "modify-data EventBridge 룰 활성화 여부 (rate 1 min). 시나리오 A 테스트용."
  type        = string
  default     = "DISABLED"
  validation {
    condition     = contains(["ENABLED", "DISABLED"], var.modify_data_rule_state)
    error_message = "ENABLED 또는 DISABLED 만 허용"
  }
}

# ── SSM 복제 config 경로 ──────────────────────────────────────
# 테스트 단계: Lambda 환경변수(REPLICATION_CONFIG)로 직접 주입 → SSM/VPC Endpoint 미사용
# 운영 전환 시 SSM Parameter Store로 이관하고 SSM VPC Endpoint 추가 필요
variable "replication_config_ssm_path" {
  description = "SSM Parameter Store에 저장된 복제 대상 config JSON 경로 (운영 단계용)"
  type        = string
  default     = "/anua-test/replication-config"
}
