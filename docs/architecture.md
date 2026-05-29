# 아키텍처 다이어그램

## 전체 구성

```mermaid
graph TB
    subgraph VPC["AWS VPC (10.0.0.0/16)"]
        subgraph Private["Private Subnet (10.0.10/11.0/24)"]
            SRC[(원본 DB\nfinance_source\nRDS MySQL 8.0\nprivately_accessible=false)]
            LMB[복제 Lambda\nanua-dc-test-replication\nPython 3.12]
            LMB2[주입 Lambda\nanua-dc-test-modify-data\n시나리오 A용]
            VPCE[VPC Endpoint\nSecrets Manager\nInterface Type]
        end
        subgraph Public["Public Subnet (10.0.1/2.0/24)"]
            STG[(Staging DB\nanalytics_staging\nRDS MySQL 8.0\npublicly_accessible=true\nrequire_secure_transport=ON)]
        end
    end

    SM[AWS Secrets Manager\nDB 비밀번호 자동 관리]
    EB1[EventBridge\nrate 5 minutes\n복제 스케줄]
    EB2[EventBridge\nrate 1 minute\n시나리오 A]
    DC[Salesforce DC\nCAN 리전\n12개 /32 IP]
    DEV[개발자 로컬\nmy_ip_cidr SG 허용]

    EB1 -->|트리거| LMB
    EB2 -->|트리거| LMB2
    LMB2 -->|INSERT 1행| SRC
    LMB -->|SELECT v_daily_sales| SRC
    LMB -->|RENAME swap| STG
    LMB -->|GetSecretValue| VPCE
    VPCE --> SM
    SM -.->|비밀번호 주입| SRC
    SM -.->|비밀번호 주입| STG
    DC -->|JDBC TLS 3306| STG
    DEV -->|MySQL 3306| STG
```

## 보안 그룹 구성

```mermaid
graph LR
    subgraph SG["Security Groups"]
        SG_L[sg-lambda\noutbound: source-rds 3306\noutbound: staging-rds 3306\noutbound: vpce 443]
        SG_SRC[sg-source-rds\ninbound: lambda-sg 3306\ninbound: my_ip 3306]
        SG_STG[sg-target-rds\ninbound: lambda-sg 3306\ninbound: my_ip 3306\ninbound: DC 12 IPs 3306]
        SG_VPE[sg-vpce\ninbound: private-subnet 443]
    end
```

## 복제 흐름 (Full Replace + RENAME Swap)

```mermaid
sequenceDiagram
    participant EB as EventBridge
    participant L as Lambda
    participant SRC as 원본 DB
    participant STG as Staging DB

    EB->>L: rate(5 minutes) 트리거
    L->>SRC: SELECT * FROM v_daily_sales
    SRC-->>L: rows (전체 행)
    L->>STG: CREATE TABLE daily_sales__tmp
    L->>STG: INSERT INTO daily_sales__tmp (bulk)
    L->>STG: RENAME TABLE daily_sales→__old, __tmp→daily_sales
    L->>STG: DROP TABLE daily_sales__old
    Note over STG: DC가 읽는 도중 빈 테이블 노출 없음
```

## 데이터 흐름

```
[원본 테이블]                [View]               [Staging 테이블]
raw_daily_sales    →    v_daily_sales    →    daily_sales
(민감 컬럼 포함)       (컬럼 선택/마스킹)    (DC가 읽는 복제본)
```
