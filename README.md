# payment-status-reconciliation-analysis

Independent portfolio project exploring payment outcomes, refunds, and settlement reconciliation using SQL and business analysis.

Synthetic INR data only. Amounts are integer paise. The product rules are in the PRD; the files below are the locked dictionary, the open choices, and the Postgres tables.

## Layout

| Path | What it is |
| --- | --- |
| `Harsh_Sagar_Payments_Project_PRD.pdf` | Product requirements. |
| `docs/data-dictionary.md` | Columns, metrics, and exception rules. |
| `docs/assumptions.md` | Demo constants and the labeled cases later SQL must hit. |
| `schema/001_tables.sql` | Tables, checks, and the insert-only rule on `payment_events`. |
| `docker-compose.yml` | Local Postgres 16 for that schema. |

## Local database

```bash
docker compose up -d
```

Login is `payments` / `payments` on `localhost:5432`, database `payments`. The schema file is mounted at `/schema` inside the container and is not applied automatically.
