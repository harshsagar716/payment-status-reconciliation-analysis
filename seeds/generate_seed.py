"""Load labeled UAT fixtures into the local payments database.

Re-running truncates the six payment tables, then inserts seeds/scenarios.json.
The replayed event is inserted twice. The second insert uses ON CONFLICT DO NOTHING.
"""

import json
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SEED_PATH = Path(__file__).resolve().parent / "scenarios.json"
AS_OF_COLUMNS = {
    "orders": ["order_id", "created_at", "order_amount_paise", "currency"],
    "payment_attempts": [
        "attempt_id",
        "order_id",
        "method",
        "amount_paise",
        "status",
        "created_at",
        "status_updated_at",
    ],
    "payment_events": ["event_id", "attempt_id", "status", "occurred_at", "received_at"],
    "settlement_batches": ["batch_id", "due_at", "settled_at", "actual_net_paise", "currency"],
    "refunds": [
        "refund_id",
        "attempt_id",
        "amount_paise",
        "status",
        "processed_at",
        "settlement_batch_id",
    ],
    "settlement_items": [
        "line_id",
        "batch_id",
        "attempt_id",
        "refund_id",
        "line_type",
        "signed_amount_paise",
    ],
}


def lit(value):
    if value is None:
        return "NULL"
    if isinstance(value, int) and not isinstance(value, bool):
        return str(value)
    if isinstance(value, str):
        return "'" + value.replace("'", "''") + "'"
    raise TypeError(f"unsupported value {value!r}")


def insert_sql(table, rows, conflict_clause=""):
    columns = AS_OF_COLUMNS[table]
    statements = []
    column_sql = ", ".join(columns)
    for row in rows:
        values = ", ".join(lit(row[column]) for column in columns)
        statements.append(
            f"INSERT INTO {table} ({column_sql}) VALUES ({values}){conflict_clause};"
        )
    return "\n".join(statements)


def validate(data):
    orders = {row["order_id"]: row for row in data["orders"]}
    events_by_attempt = defaultdict(list)
    for event in data["events"]:
        events_by_attempt[event["attempt_id"]].append(event)

    for attempt in data["attempts"]:
        order = orders[attempt["order_id"]]
        if attempt["amount_paise"] != order["order_amount_paise"]:
            raise SystemExit(f"{attempt['attempt_id']} amount does not match its order")
        events = events_by_attempt.get(attempt["attempt_id"])
        if not events:
            raise SystemExit(f"{attempt['attempt_id']} has no event")
        latest = max(events, key=lambda event: event["occurred_at"])
        if attempt["status"] != latest["status"]:
            raise SystemExit(f"{attempt['attempt_id']} status is not the latest event")
        if attempt["status_updated_at"] != latest["occurred_at"]:
            raise SystemExit(f"{attempt['attempt_id']} status_updated_at is not the latest event")

    event_ids = {event["event_id"] for event in data["events"]}
    for event_id in data["replay_event_ids"]:
        if event_id not in event_ids:
            raise SystemExit(f"replay id {event_id} is not an event")

    fee = sum(
        row["signed_amount_paise"]
        for row in data["lines"]
        if row["batch_id"] == "uat_fee_tax_net_batch"
    )
    fee_actual = next(
        row["actual_net_paise"]
        for row in data["batches"]
        if row["batch_id"] == "uat_fee_tax_net_batch"
    )
    if fee != 87640 or fee_actual - fee != -640:
        raise SystemExit(f"fee fixture drifted: net {fee}, variance {fee_actual - fee}")

    partial = sum(
        row["signed_amount_paise"]
        for row in data["lines"]
        if row["batch_id"] == "uat_partial_settlement_batch"
    )
    partial_actual = next(
        row["actual_net_paise"]
        for row in data["batches"]
        if row["batch_id"] == "uat_partial_settlement_batch"
    )
    if partial != partial_actual:
        raise SystemExit("partial settlement fixture variance is not zero")


def build_sql(data):
    replay_ids = set(data["replay_event_ids"])
    replay_rows = [row for row in data["events"] if row["event_id"] in replay_ids]
    parts = [
        "BEGIN;",
        "TRUNCATE settlement_items, refunds, payment_events, payment_attempts, settlement_batches, orders;",
        insert_sql("orders", data["orders"]),
        insert_sql("payment_attempts", data["attempts"]),
        insert_sql("payment_events", data["events"]),
        insert_sql("payment_events", replay_rows, " ON CONFLICT (event_id) DO NOTHING"),
        insert_sql("settlement_batches", data["batches"]),
        insert_sql("refunds", data["refunds"]),
        insert_sql("settlement_items", data["lines"]),
        "COMMIT;",
        """
SELECT 'orders' AS entity, count(*) FROM orders
UNION ALL SELECT 'payment_attempts', count(*) FROM payment_attempts
UNION ALL SELECT 'payment_events', count(*) FROM payment_events
UNION ALL SELECT 'refunds', count(*) FROM refunds
UNION ALL SELECT 'settlement_batches', count(*) FROM settlement_batches
UNION ALL SELECT 'settlement_items', count(*) FROM settlement_items
ORDER BY 1;
""".strip(),
    ]
    return "\n".join(parts) + "\n"


def main():
    data = json.loads(SEED_PATH.read_text(encoding="utf-8"))
    validate(data)
    completed = subprocess.run(
        [
            "docker",
            "compose",
            "exec",
            "-T",
            "db",
            "psql",
            "-U",
            "payments",
            "-d",
            "payments",
            "-v",
            "ON_ERROR_STOP=1",
        ],
        input=build_sql(data),
        text=True,
        cwd=ROOT,
        check=False,
    )
    sys.exit(completed.returncode)


if __name__ == "__main__":
    main()
