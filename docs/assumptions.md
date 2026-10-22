# Assumptions

Locked before schema and seed. Each item is a choice the PRD leaves open, or a demo constant the later files must use unchanged.

The dictionary in `docs/data-dictionary.md` is the field and metric contract. This file is the list of choices behind it.

## Demo constants

1. Currency is `INR` on every order and every batch. There is no multi-currency traffic.
2. Money is integer paise. The seed never writes a float. INR 3.60 is 360 paise.
3. Pending review threshold is the SQL parameter `pending_review_after = interval '24 hours'`. One value, passed into the query. No config file and no settings table.
4. Business dates for refund grouping and the dashboard use `Asia/Kolkata`. Storage stays `timestamptz` in UTC.
5. Payment methods are `upi`, `card`, and `netbanking`.
6. Status values are `pending`, `success`, and `failed` on attempts, events, and refunds. `success` on an attempt means captured.
7. `batch_id` is the settlement reference in §R4. No second reference column.
8. Each attempt amount equals its order amount. Partial capture is out of scope. Partial refunds are in scope.
9. Seeds contain no names, phone numbers, email addresses, or card numbers.

## Behaviour choices

10. Current status lives on `payment_attempts` and can change. History lives on `payment_events` and is insert-only. The seed uses `INSERT ... ON CONFLICT (event_id) DO NOTHING`.
11. As-of status comes from events with `received_at <= as_of`, taking the latest `occurred_at`. Metrics ignore `payment_attempts.status`.
12. A pending attempt past 24 hours is listed for review and remains `pending`.
13. Missing `actual_net_paise` stays null. It is never written or queried as zero. Variance is null when the actual is null. `settled_at` is null exactly when the actual is null.
14. Overdue means `as_of > due_at` and `actual_net_paise` is null. Due tomorrow is awaiting, not overdue.
15. Expected net equals `SUM(signed_amount_paise)` for the batch. Capture lines are positive. Refund, fee, and fee-tax lines are negative.
16. Fee and fee-tax lines have neither `attempt_id` nor `refund_id`. Capture lines have only `attempt_id`. Refund lines have only `refund_id`.
17. A successful payment is tied to a batch by its capture line. A successful refund may name a later batch in `refunds.settlement_batch_id`.
18. Duplicate successes are stored and then flagged. No unique constraint blocks the §9 case.
19. Refundable balance uses successful refunds only. The seed may insert a successful total above the capture. The exception query reports that row. Nothing in the load rewrites it.
20. Partial settlement means a non-null actual and at least one successful refund assigned to that `batch_id` with no refund line. This is queryable from §6 columns alone. The labeled fixture below is that case, with variance held at zero so partial and mismatch are separate signals. The amount-mismatch signal is the fee fixture.
21. Cohort bounds are optional query parameters. The demo dashboard uses every attempt with `created_at <= as_of`.
22. Identifier columns are `text`, assigned by the seed. No UUID extension and no sequences.

## Labeled results the later UAT must hit

These rows are the first seed. Bulk traffic is added only after these pass. Snapshots differ by scenario. The late-pending case has two.

| Id | What is stored | Snapshot | Result |
| --- | --- | --- | --- |
| `failed_then_success` | Two attempts, one `failed`, one `success`, one order | After both events | One paid order. The failure remains in the attempt denominator. |
| `late_pending` | One attempt, pending event, then a success event more than 24 hours later. Both event rows kept | `as_of` after 24 hours pending, before the success | Pending-over-threshold flag is present. |
| `late_pending` | Same rows | `as_of` after the success event | Pending flag is absent. As-of status is `success`. Both events remain. |
| `replayed_event` | Same `event_id` inserted twice | After the replay | One event row. Amounts and counts do not increase. |
| `double_success` | Two `success` attempts, one order | After both | Order paid count is 1. Duplicate-success exception is present. |
| `partial_refunds` | Capture 100000 paise. Successful refunds 30000 and 20000. One pending or failed refund also stored | After the successful refunds are processed | Successful refunded value 50000 paise. The other refund does not reduce the remaining 50000. |
| `fee_tax_net` | Capture 100000, refund line ?10000, fee ?2000, fee tax ?360. `actual_net_paise` 87000 | After `settled_at` | Expected net 87640. Variance ?640. Mismatch flag present. |
| `not_yet_due` | Batch `due_at` after the snapshot, `actual_net_paise` null | Before `due_at` | Awaiting. Overdue flag absent. |
| `overdue_missing` | Batch `due_at` before the snapshot, `actual_net_paise` null | After `due_at` | Overdue and missing-settlement flags present. Variance null. |
| `partial_settlement` | Capture and fee lines present, actual equal to that line sum, one successful refund assigned to the batch with no refund line | After settlement | Partial flag present. Variance 0. |
| `refund_over_capture` | Capture 100000. Successful refunds 60000 and 50000 | After both refunds | Exception present. Successful refund sum 110000. |

`fee_tax_net` arithmetic: `100000 - 10000 - 2000 - 360 = 87640`. Variance: `87000 - 87640 = -640`.

`partial_refunds` arithmetic: `30000 + 20000 = 50000` successful paise on a `100000` capture.

## Out of scope for every later file

Web app, live gateway, auth, webhooks, chargebacks, automated refund execution, customer personal data, and any config framework around the 24-hour parameter.
