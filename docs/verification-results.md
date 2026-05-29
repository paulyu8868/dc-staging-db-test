# 검증 결과

검증 환경: AWS Sandbox (ap-northeast-2), 2026-05-28 ~ 2026-05-29

---

## Phase A — 복제 동작 검증

### 준비 데이터

| 테이블 | 컬럼 | 행수 |
|--------|------|------|
| `raw_daily_sales` | id, sale_date, product, amount, region, created_at | 10 |
| `v_daily_sales` (View) | id, sale_date, product, amount, region | 10 |

### Lambda 수동 실행 결과

| 검증일자 | View | 원본 행수 | Staging 행수 | 일치 | 소요(초) | 비고 |
|----------|------|-----------|--------------|------|----------|------|
| 2026-05-28 | v_daily_sales | 10 | 10 | ✅ Y | 1 | atomic_swap existed=False (최초) |

### CloudWatch 로그 발췌 (수동 실행)

```
[INFO] DB 연결: anua-dc-test-source-db.xxx.rds.amazonaws.com/finance_source
[INFO] DB 연결: anua-dc-test-staging-db.xxx.rds.amazonaws.com/analytics_staging
[INFO] create_table: daily_sales__tmp (5 columns)
[INFO] bulk_insert: daily_sales__tmp — 10행 적재
[INFO] atomic_swap: daily_sales 완료 (existed=False)
[INFO] {'view': 'v_daily_sales', 'rows': 10, 'status': 'ok'}
Duration: 1514 ms
```

---

## Phase A — 멱등성 검증

원본 데이터 수정 후 다음 자동 배치에서 Staging 반영 여부 확인.

| 변경 내용 | 원본 행수 | Staging 행수 | 일치 | 비고 |
|-----------|-----------|--------------|------|------|
| id=1 amount 수정, id=2 region 수정, 신규 2행 추가 | 12 | 12 | ✅ Y | 다음 5분 배치에서 자동 반영 |

---

## EventBridge 스케줄 검증

EventBridge `rate(5 minutes)` ENABLED 후 자동 실행 모니터링.

| 실행시각 (KST) | 트리거 | 복제 행수 | 결과 | 비고 |
|----------------|--------|-----------|------|------|
| 19:23:46 | 수동 | 10 | ✅ 성공 | Phase A 초기 검증 |
| 19:28:59 | **자동 (EventBridge)** | 10 | ✅ 성공 | ENABLED 40초 후 첫 트리거 |
| 19:33:59 | **자동 (EventBridge)** | 10 | ✅ 성공 | +5분 정확 |
| 19:38:59 | **자동 (EventBridge)** | 10 | ✅ 성공 | +5분 정확 |
| 19:43:59 | **자동 (EventBridge)** | 10 | ✅ 성공 | +5분 정확 |
| 19:47:46 | — | — | — | 소스 데이터 수정 (10→12행) |
| 19:48:59 | **자동 (EventBridge)** | **12** | ✅ 성공 | 변경분 즉시 반영, 멱등성 통과 |

**요약:**
- 총 자동 실행: 5회
- 에러: 0건
- 평균 실행 시간: ~650ms (warm) / ~1,500ms (cold start)
- 5분 간격 정확도: ±1초 이내

---

## 발견 및 수정 사항

배포 과정에서 발견한 버그 및 수정 내역:

| # | 파일 | 증상 | 원인 | 수정 |
|---|------|------|------|------|
| 1 | `rds-source/staging.tf` | AWS API 400 오류 | description 한글/em-dash(`—`) → non-printable 문자로 거부 | ASCII로 교체 |
| 2 | `lambda.tf` | Lambda 생성 실패 | `reserved_concurrent_executions=1` → Sandbox 계정 최소 미예약 concurrency(10) 미달 | 설정 제거 |
| 3 | `lambda/db.py` | `KeyError: 'host'` | `manage_master_user_password` 방식 시크릿에 `host` 키 없음 | env var fallback 추가 |
| 4 | `lambda/db.py` | TLS 연결 거부 (error 3159) | `ssl={}` (빈 dict)가 Python falsy → pymysql이 SSL 미활성화 | `ssl.SSLContext` 직접 생성 |

---

## 시나리오 A — DBeaver 실시간 관찰

`rate(1 minute)` 주입 + `rate(5 minutes)` 복제 동시 실행 시 Staging 행 증가 패턴:

| 시간 | 원본 행수 | Staging 행수 | 비고 |
|------|-----------|--------------|------|
| T+0 | 12 | 12 | 시작 기준 |
| T+5 | ~17 | ~17 | 첫 복제 배치 |
| T+10 | ~22 | ~22 | 두 번째 복제 배치 |

> DBeaver에서 `SELECT COUNT(*) FROM daily_sales` 또는  
> `SELECT * FROM daily_sales ORDER BY id DESC LIMIT 10` 으로 실시간 관찰 가능.
