# Salesforce DC ← Staging DB 복제 패턴 검증 스펙

## 배경 및 목적

Salesforce Data Cloud(DC)를 실제 운영 DB에 직접 연결하는 대신,  
분석용 View만 복제된 Staging DB에 연결하여 **원본 격리 + DC 연동**을 동시에 달성하는 패턴을 검증.

### 핵심 요구사항

1. 원본 재무 DB는 외부 노출 없이 Private 유지
2. DC는 Staging DB에서만 읽음 (TLS 강제, IP 허용 목록 제한)
3. 복제 중 DC 읽기가 빈 테이블에 노출되지 않을 것 (atomic swap)
4. 코드/State에 평문 비밀번호 없음

---

## 아키텍처 결정사항 (ADR)

### ADR-01: 복제 방식 — Full Replace + RENAME Swap

**결정:** 증분 복제 대신 Full replace 채택  
**이유:**
- View 스키마 변경(컬럼 추가/삭제)을 자동 흡수
- 10만 건 이하 규모에서 성능 충분
- RENAME TABLE은 MySQL 원자적 연산 → 다운타임 0

**트레이드오프:** 데이터 볼륨 증가 시 Step Functions + 증분 복제로 전환 고려

### ADR-02: 비밀번호 관리 — manage_master_user_password

**결정:** AWS RDS 자동 관리 (`manage_master_user_password = true`)  
**이유:**
- Terraform code, state, CI 로그 어디에도 평문 비밀번호 없음
- 자동 교체(rotation) 지원
- Lambda는 Secrets Manager에서 실행 시마다 동적 조회

**주의:** 자동 생성 시크릿에는 `host` 키가 없음 → Lambda 환경변수(`SOURCE_DB_HOST`, `TARGET_DB_HOST`)로 별도 주입

### ADR-03: Secrets Manager 접근 — VPC Endpoint (Interface)

**결정:** NAT Gateway 대신 VPC Interface Endpoint 사용  
**이유:**
- Lambda가 VPC 내부에서 Secrets Manager 접근 시 인터넷 경유 불필요
- 비용: $0.01/h (NAT Gateway $0.059/h 대비 83% 절감)
- Private DNS 활성화 → SDK 코드 변경 없이 자동 라우팅

### ADR-04: Lambda SSL — ssl.SSLContext 명시 생성

**결정:** `ssl={}` 대신 `ssl.create_default_context()` 사용  
**이유:**
- pymysql 1.1.1에서 `ssl={}` (빈 dict)는 Python falsy → SSL 미활성화
- Staging DB의 `require_secure_transport=ON`에 의해 연결 거부 (MySQL error 3159)
- `ssl.SSLContext`를 직접 생성해 `check_hostname=False, verify_mode=CERT_NONE` 설정

---

## 리소스 목록

| 리소스 | 식별자 | 설명 |
|--------|--------|------|
| VPC | `anua-dc-test-vpc` | 10.0.0.0/16 |
| Private Subnet × 2 | `anua-dc-test-private-*` | Lambda + 원본 DB |
| Public Subnet × 2 | `anua-dc-test-public-*` | Staging DB |
| Internet Gateway | `anua-dc-test-igw` | Public 서브넷 출구 |
| VPC Endpoint | `anua-dc-test-vpce-secretsmanager` | Interface, Private DNS |
| Security Group × 4 | lambda, source-rds, target-rds, vpce | 최소 권한 |
| RDS (원본) | `anua-dc-test-source-db` | MySQL 8.0, Private, db.t3.micro |
| RDS (Staging) | `anua-dc-test-staging-db` | MySQL 8.0, Public, TLS 강제 |
| Lambda (복제) | `anua-dc-test-replication` | Python 3.12, 300s timeout |
| Lambda (주입) | `anua-dc-test-modify-data` | Python 3.12, 시나리오 A용 |
| IAM Role | `anua-dc-test-lambda-role` | VPC Execution + Secrets Manager 읽기 |
| EventBridge Rule (복제) | `anua-dc-test-replication-schedule` | rate(5 minutes) |
| EventBridge Rule (주입) | `anua-dc-test-modify-data-schedule` | rate(1 minute), 시나리오 A용 |
| CloudWatch Log Group × 2 | `/aws/lambda/anua-dc-test-*` | 7일 보존 |

---

## 검증 단계

### Phase A: DC 없이 복제 동작 검증

1. 원본 DB에 모의 재무 데이터 + `v_daily_sales` View 생성
2. Lambda 수동 실행 → Staging `daily_sales` 복제 확인
3. EventBridge 자동 실행 (rate 5min) 확인
4. 멱등성: 원본 변경 후 다음 배치에서 반영 확인

### Phase B: DC 연동 검증

1. Staging DB endpoint로 Salesforce DC 커넥터 생성
2. Test Connection 성공 확인
3. Data Stream → DLO 적재 확인

### 시나리오 A: DBeaver 실시간 관찰

1. modify-data Lambda: rate(1 minute)로 원본에 1행 INSERT
2. replication Lambda: rate(5 minutes)로 Staging 복제
3. DBeaver에서 5분마다 ~5행 증가 관찰

---

## 비용 추정 (Sandbox)

| 리소스 | 단가 | 비고 |
|--------|------|------|
| RDS db.t3.micro × 2 | $0.040/h | 약 $0.96/일 |
| VPC Endpoint (Interface) | $0.01/h | |
| Lambda | 거의 무료 | 100만 호출 무료 |
| EventBridge | 무료 | |

> **총합 약 $1.2/일** — 검증 종료 즉시 `terraform destroy` 권장

---

## 향후 전환 고려사항

| 항목 | 현재 (Sandbox) | 운영 전환 시 |
|------|---------------|-------------|
| 복제 방식 | Lambda 단일 함수 루프 | Step Functions Map 상태로 병렬화 |
| 스케줄 | rate(5 minutes) | cron(0 17 * * ? *) — KST 02:00 |
| Config 저장 | Lambda 환경변수 embed | SSM Parameter Store |
| SSL 검증 | CERT_NONE (sandbox) | RDS CA 인증서 검증 |
| Lambda Reserved Concurrency | 없음 | 1 (중복 실행 방지) |
