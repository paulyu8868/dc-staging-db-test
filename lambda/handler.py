"""
복제 Lambda 핸들러 — config-driven, Full replace / RENAME swap 방식.

설계 원칙 (§4.1 Step Functions 전환 대비):
  - replicate_one_view()는 View 단위 독립 함수로 분리
  - 현재: handler()가 config 루프 순회
  - 전환 시: replicate_one_view()가 단일 Lambda가 되고, 루프는 SFN Map 상태로 대체
"""

import json
import logging
import os
from datetime import datetime, timezone

import db

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def load_config() -> list[dict]:
    """환경변수 REPLICATION_CONFIG에서 복제 대상 View 목록 로드 (SSM 미사용)"""
    raw = os.environ.get("REPLICATION_CONFIG", "[]")
    return json.loads(raw)


def replicate_one_view(
    source_conn,
    target_conn,
    item: dict,
) -> dict:
    """
    View 하나를 Full replace + RENAME swap 방식으로 복제.

    Step Functions 전환 시 이 함수가 그대로 단일 Lambda 핸들러가 됨.
    핵심 로직은 이 함수 밖으로 이동하지 않는다.
    """
    view = item["source_view"]
    table = item["target_table"]
    tmp = f"{table}__tmp"

    # 1. 원본 View 전체 읽기
    rows, columns = db.fetch_all(source_conn, f"SELECT * FROM `{view}`")

    # 2. Staging에 임시 테이블 생성 + 데이터 일괄 적재
    db.create_table(target_conn, tmp, columns)
    db.bulk_insert(target_conn, tmp, columns, rows)

    # 3. 원자적 RENAME swap — DC가 읽는 도중 빈 테이블 노출 없음
    db.atomic_swap(target_conn, table, tmp)

    return {"view": view, "rows": len(rows), "status": "ok"}


def handler(event, context) -> dict:
    config = load_config()
    if not config:
        logger.warning("REPLICATION_CONFIG 비어있음 — 복제할 View가 없습니다")
        return {"results": []}

    source_arn = os.environ["SOURCE_SECRET_ARN"]
    target_arn = os.environ["TARGET_SECRET_ARN"]
    source_db_name = os.environ.get("SOURCE_DB_NAME", "")
    staging_db_name = os.environ.get("STAGING_DB_NAME", "")
    source_host = os.environ.get("SOURCE_DB_HOST", "")
    target_host = os.environ.get("TARGET_DB_HOST", "")

    src = db.connect(source_arn, source_db_name, source_host)
    tgt = db.connect(target_arn, staging_db_name, target_host)

    results = []
    for item in config:
        now = datetime.now(timezone.utc).isoformat()
        try:
            r = replicate_one_view(src, tgt, item)
        except Exception as exc:
            r = {
                "view": item.get("source_view", "unknown"),
                "status": "error",
                "error": str(exc),
            }
            logger.error("[%s] 복제 실패: %s", now, r)
        else:
            logger.info("[%s] %s", now, r)
        results.append(r)

    db.close(src)
    db.close(tgt)

    return {"results": results}
