"""
DB 연결/쿼리 헬퍼 — Secrets Manager + pymysql 래퍼.

Step Functions 전환 시 이 모듈은 그대로 재사용됨.
"""

import json
import logging
import os
import ssl as ssl_module

import boto3
import pymysql
import pymysql.cursors

logger = logging.getLogger(__name__)


def _get_secret(secret_arn: str) -> dict:
    client = boto3.client(
        "secretsmanager",
        region_name=os.environ.get("AWS_REGION", "ap-northeast-2"),
    )
    resp = client.get_secret_value(SecretId=secret_arn)
    return json.loads(resp["SecretString"])


def connect(secret_arn: str, db_name: str = "", host_override: str = "") -> pymysql.connections.Connection:
    """Secrets Manager ARN에서 자격증명을 읽어 MySQL 연결 반환.

    manage_master_user_password 방식의 secret JSON 형식:
      {"username": "...", "password": "..."}
    host는 secret에 없으므로 host_override(env var)로 주입.
    """
    creds = _get_secret(secret_arn)
    host = host_override or creds.get("host", "")
    if not host:
        raise ValueError(f"DB host를 확인할 수 없음 — secret: {secret_arn}")
    ssl_ctx = ssl_module.create_default_context()
    ssl_ctx.check_hostname = False
    ssl_ctx.verify_mode = ssl_module.CERT_NONE
    conn = pymysql.connect(
        host=host,
        user=creds["username"],
        password=creds["password"],
        database=db_name or creds.get("dbname", ""),
        port=int(creds.get("port", 3306)),
        cursorclass=pymysql.cursors.DictCursor,
        connect_timeout=10,
        ssl=ssl_ctx,
    )
    logger.info("DB 연결: %s/%s", host, db_name)
    return conn


def fetch_all(conn: pymysql.connections.Connection, query: str) -> tuple:
    """쿼리 결과 전체 반환 → (rows: list[dict], columns: list[str])"""
    with conn.cursor() as cur:
        cur.execute(query)
        rows = cur.fetchall()
        columns = [d[0] for d in cur.description] if cur.description else []
    return rows, columns


def create_table(
    conn: pymysql.connections.Connection,
    table_name: str,
    columns: list[str],
) -> None:
    """임시 테이블 동적 생성.

    컬럼을 TEXT로 정의 → View 스키마 변경(컬럼 추가/순서 변경)을 Full replace가 자동 흡수.
    """
    if not columns:
        raise ValueError(f"create_table: {table_name} — 컬럼 없음")
    col_defs = ", ".join(f"`{c}` TEXT" for c in columns)
    with conn.cursor() as cur:
        cur.execute(f"DROP TABLE IF EXISTS `{table_name}`")
        cur.execute(
            f"CREATE TABLE `{table_name}` ({col_defs}) "
            "ENGINE=InnoDB DEFAULT CHARSET=utf8mb4"
        )
    conn.commit()
    logger.info("create_table: %s (%d columns)", table_name, len(columns))


def bulk_insert(
    conn: pymysql.connections.Connection,
    table_name: str,
    columns: list[str],
    rows: list[dict],
) -> None:
    """행 일괄 INSERT (executemany)"""
    if not rows:
        logger.info("bulk_insert: %s — 적재할 행 없음 (빈 View)", table_name)
        return
    placeholders = ", ".join(["%s"] * len(columns))
    col_names = ", ".join(f"`{c}`" for c in columns)
    sql = f"INSERT INTO `{table_name}` ({col_names}) VALUES ({placeholders})"
    vals = [tuple(row.get(c) for c in columns) for row in rows]
    with conn.cursor() as cur:
        cur.executemany(sql, vals)
    conn.commit()
    logger.info("bulk_insert: %s — %d행 적재", table_name, len(rows))


def atomic_swap(
    conn: pymysql.connections.Connection,
    table: str,
    tmp: str,
) -> None:
    """RENAME TABLE swap — MySQL 원자적 연산으로 다운타임 0 교체.

    첫 실행: RENAME tmp → table
    이후   : RENAME table → __old, tmp → table; DROP __old
    """
    old = f"{table}__old"
    with conn.cursor() as cur:
        cur.execute(
            "SELECT COUNT(*) AS cnt FROM information_schema.tables "
            "WHERE table_schema = DATABASE() AND table_name = %s",
            (table,),
        )
        row = cur.fetchone()
        exists = bool(row and row["cnt"] > 0)

        if exists:
            cur.execute(
                f"RENAME TABLE `{table}` TO `{old}`, `{tmp}` TO `{table}`"
            )
            cur.execute(f"DROP TABLE IF EXISTS `{old}`")
        else:
            cur.execute(f"RENAME TABLE `{tmp}` TO `{table}`")
    conn.commit()
    logger.info("atomic_swap: %s 완료 (existed=%s)", table, exists)


def close(conn: pymysql.connections.Connection) -> None:
    try:
        conn.close()
    except Exception:
        pass
