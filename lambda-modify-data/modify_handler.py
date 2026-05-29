import json
import os
import random
import ssl as ssl_module
from datetime import date, timedelta

import boto3
import pymysql


def handler(event, context):
    secret_arn = os.environ["SOURCE_SECRET_ARN"]
    host = os.environ["SOURCE_DB_HOST"]
    db_name = os.environ.get("SOURCE_DB_NAME", "finance_source")

    sm = boto3.client("secretsmanager", region_name="ap-northeast-2")
    creds = json.loads(sm.get_secret_value(SecretId=secret_arn)["SecretString"])

    ssl_ctx = ssl_module.create_default_context()
    ssl_ctx.check_hostname = False
    ssl_ctx.verify_mode = ssl_module.CERT_NONE

    conn = pymysql.connect(
        host=host, user=creds["username"], password=creds["password"],
        database=db_name, connect_timeout=10, ssl=ssl_ctx,
    )
    cur = conn.cursor()

    regions = ["KR", "JP", "US", "SG", "AU"]
    products = ["Product A", "Product B", "Product C", "Product D", "Product E"]
    region = random.choice(regions)
    product = random.choice(products)
    amount = round(random.uniform(1000, 9999), 2)
    sale_date = date.today() - timedelta(days=random.randint(0, 30))

    cur.execute(
        "INSERT INTO raw_daily_sales (sale_date, product, amount, region) VALUES (%s, %s, %s, %s)",
        (sale_date, product, amount, region),
    )
    conn.commit()

    cur.execute("SELECT COUNT(*) FROM raw_daily_sales")
    total = cur.fetchone()[0]
    cur.close()
    conn.close()

    return {
        "status": "ok",
        "inserted": {"sale_date": str(sale_date), "product": product, "amount": amount, "region": region},
        "total_rows": total,
    }
