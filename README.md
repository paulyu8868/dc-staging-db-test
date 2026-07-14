# Salesforce DC ← Staging DB 복제 패턴 검증

원본 DB를 Private 서브넷에 격리하고, 분석용 View를 Public Staging DB로 주기 배치 복제하여  
**Salesforce Data Cloud(DC)가 Staging에서 읽는 아키텍처 패턴**을 AWS Sandbox에서 end-to-end 검증하는 프로젝트.

> 상세 설계 근거: [docs/dc-staging-db-test-spec.md](docs/dc-staging-db-test-spec.md)  
> 아키텍처 다이어그램: [docs/architecture.md](docs/architecture.md)  
> 검증 결과: [docs/verification-results.md](docs/verification-results.md)

---

## 아키텍처 개요

```
[원본 DB]                  [복제 Lambda]              [Staging DB]
finance_source (Private) → v_daily_sales SELECT   → analytics_staging (Public)
RDS MySQL 8.0              Full replace                RDS MySQL 8.0
privately_accessible=false RENAME atomic swap          publicly_accessible=true
                           EventBridge rate(5min)      require_secure_transport=ON
                                                            ↑
                                                   [Salesforce DC CAN]
                                                   12개 /32 IP SG 허용
```

- **원본 DB**: Private Subnet, 인터넷 직접 노출 없음
- **Staging DB**: Public Subnet, TLS 강제, DC IP 12개만 SG 허용
- **Lambda**: Private Subnet 배치, VPC Endpoint로 Secrets Manager 접근
- **비밀번호**: `manage_master_user_password=true` — Terraform/State에 평문 없음

---

## 검증 결과 요약

| 단계 | 항목 | 결과 |
|------|------|------|
| Phase A | v_daily_sales → daily_sales 10행 복제 | ✅ 일치 (1초) |
| Phase A | 멱등성 — 원본 12행 변경 후 다음 배치 반영 | ✅ 12행 정확 반영 |
| 스케줄 | EventBridge rate(5min) 자동 실행 4회 연속 | ✅ 정확히 5분 간격 |
| 스케줄 | 에러율 | ✅ 0건 |
| 스케줄 | atomic_swap (RENAME TABLE) | ✅ 다운타임 0 |

> 상세 수치 및 CloudWatch 로그 발췌: [docs/verification-results.md](docs/verification-results.md)

---

## 사전 준비

### 1. AWS CLI + 프로파일 설정

```bash
aws configure --profile sandbox-anua-test
# region: ap-northeast-2
```

### 2. 도구 설치 확인

```bash
terraform version   # >= 1.5
python3 --version   # >= 3.10
```

### 3. Lambda 의존성 설치

```bash
pip install -r lambda/requirements.txt -t lambda/
pip install -r lambda/requirements.txt -t lambda-modify-data/
```

> pymysql은 `.gitignore` 처리됨 — `apply` 전에 반드시 위 명령 실행 필요.

### 4. terraform.tfvars 생성

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# 내 IP 입력: curl ifconfig.me
```

---

## 배포

```bash
cd terraform

terraform init
terraform plan    # 생성될 리소스 확인 (약 45개)
terraform apply   # RDS 생성 포함, 약 10분 소요
```

완료 후 주요 output:

```bash
terraform output staging_db_endpoint    # DC 연결 대상
terraform output lambda_function_name   # 복제 Lambda 이름
terraform output lambda_invoke_command  # 수동 실행 명령어
```

---

## Phase A — 복제 동작 검증

### 1. 원본 DB 데이터 준비

```bash
bash scripts/prepare-source-data.sh
```

> 원본 DB는 `publicly_accessible=false` (Private). 로컬 머신에서 직접 mysql 접속 불가.  
> 스크립트가 실패하면 VPC 내 Lambda를 통해 실행하거나 AWS RDS Query Editor 사용.

### 2. Lambda 수동 실행

```bash
bash scripts/invoke-lambda.sh
```

### 3. 복제 결과 확인

```bash
bash scripts/verify-replication.sh
```

### 4. EventBridge 스케줄 검증 (선택)

```hcl
# terraform/terraform.tfvars
eventbridge_rule_state = "ENABLED"
```

```bash
cd terraform && terraform apply
# 5분 후 CloudWatch Logs에서 자동 실행 확인
# 완료 후 반드시 DISABLED로 복원
```

---

## 시나리오 A — DBeaver 실시간 관찰

원본 DB에 1분마다 1행 INSERT, 5분마다 Staging으로 복제 → DBeaver에서 5분 단위 행 증가 관찰.

```hcl
# terraform/terraform.tfvars
eventbridge_rule_state = "ENABLED"   # 복제 (rate 5 minutes)
modify_data_rule_state = "ENABLED"   # INSERT (rate 1 minute)
```

```bash
cd terraform && terraform apply
# 5분마다 staging daily_sales 행수가 ~5씩 증가
```

종료 시:

```bash
bash scripts/cleanup-schedule.sh
cd terraform
# terraform.tfvars에서 두 룰 모두 DISABLED로 변경 후
terraform apply
```

---

## Phase B — DC 연동 검증

1. Staging DB endpoint 확인:

   ```bash
   terraform -chdir=terraform output staging_db_endpoint
   ```

2. Salesforce DC → AWS RDS MySQL 커넥터 생성
   - JDBC URL: `jdbc:mysql://<endpoint>:3306/analytics_staging`
   - SSL 필수 (`require_secure_transport=ON`)

3. DC Outbound IP를 `terraform.tfvars`에 추가 후 `terraform apply`
   - IP 목록: [Salesforce 공식 페이지](https://help.salesforce.com/s/articleView?id=data.c360_a_data_cloud_ip_address_allowlist.htm)

---

## 정리 (Cleanup)

**반드시 아래 순서로 정리하세요.**

```bash
# 1. EventBridge 룰 비활성화
bash scripts/cleanup-schedule.sh

# 2. 전체 리소스 삭제 (약 10~15분)
cd terraform && terraform destroy
```

주요 과금 리소스:

| 리소스 | 단가 |
|--------|------|
| RDS db.t3.micro × 2 | ~$0.040/h |
| VPC Endpoint (Secrets Manager) | $0.01/h |
| Lambda / EventBridge | 무료 수준 |

---

## 디렉터리 구조

```
dc-staging-db-test/
├── terraform/
│   ├── main.tf                  # provider 설정
│   ├── variables.tf             # 전체 변수 (IP, 스케줄 등)
│   ├── terraform.tfvars.example # 변수 예시 (tfvars는 .gitignore)
│   ├── network.tf               # VPC, Subnet, IGW, VPC Endpoint
│   ├── security-groups.tf       # SG 및 규칙 (순환 의존 방지)
│   ├── secrets.tf               # Secrets Manager 전략 문서
│   ├── rds-source.tf            # 원본 DB (Private)
│   ├── rds-staging.tf           # Staging DB (Public, TLS)
│   ├── lambda.tf                # 복제 Lambda + IAM
│   ├── lambda-modify-data.tf    # 데이터 주입 Lambda (시나리오 A)
│   ├── eventbridge.tf           # 두 EventBridge 스케줄 룰
│   └── outputs.tf               # endpoint, 명령어 안내
├── lambda/
│   ├── handler.py               # 복제 핸들러 (config-driven)
│   ├── db.py                    # DB 연결/쿼리 헬퍼
│   └── requirements.txt         # pymysql==1.1.1
├── lambda-modify-data/
│   └── modify_handler.py        # 원본 DB 1행 INSERT (시나리오 A)
├── config/
│   └── replication-config.json  # 복제 대상 View 목록
├── scripts/
│   ├── prepare-source-data.sh   # 원본 DB 모의 데이터 생성
│   ├── invoke-lambda.sh         # Lambda 수동 실행
│   ├── verify-replication.sh    # 복제 결과 검증
│   └── cleanup-schedule.sh      # EventBridge 룰 비활성화
└── docs/
    ├── dc-staging-db-test-spec.md   # 설계 스펙
    ├── architecture.md              # Mermaid 아키텍처 다이어그램
    └── verification-results.md     # Phase A/스케줄 검증 결과
```

---

## 참고 문서

- [Salesforce DC IP Allowlist](https://help.salesforce.com/s/articleView?id=data.c360_a_data_cloud_ip_address_allowlist.htm)
- [AWS RDS manage_master_user_password](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-secrets-manager.html)
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
