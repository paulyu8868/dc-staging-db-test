# ==============================================================
# main.tf — provider, required_providers
# ==============================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # 모든 리소스에 공통 태그 자동 적용
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = "sandbox"
      ManagedBy   = "terraform"
    }
  }
}
