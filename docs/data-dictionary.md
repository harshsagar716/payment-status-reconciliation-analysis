# Data dictionary

Source: `Harsh_Sagar_Payments_Project_PRD.pdf` �6 (columns) and �7 (metrics).  
Rules that are choices, not PRD fields, live in `docs/assumptions.md`.

Synthetic INR only. Every amount is an integer number of paise. Every timestamp is `timestamptz` (UTC). Business dates use `Asia/Kolkata`.

## How a snapshot is read

Every metric and exception takes an explicit `as_of` timestamp.

An event is visible when `received_at <= as_of`. The attempt's status at that snapshot is the visible event with the latest `occurred_at`. `payment_attempts.status` stores the latest status for convenience. Metrics do not read that column. They read events, so an earlier snapshot still shows pending after a later success has been stored.

An attempt is in the creation-date cohort when `created_at` is inside `[cohort_start, cohort_end)` and `created_at <= as_of`. With no cohort bounds, the cohort is every attempt with `created_at <= as_of`.

Pending age is `as_of` minus the `occurred_at` of the event that set the as-of status to `pending`. The demo threshold is the parameter `pending_review_after` (value `24 hours`).

## Status values

Used on `payment_attempts`, `payment_events`, and `refunds`.

| Status | Meaning |
| --- | --- |
| `pending` | Recorded, not yet successful or failed. Stays pending past the review threshold. |
| `success` | Attempt: captured payment. Refund: refund that reduces the refundable balance. |
| `failed` | Closed without capture, or refund that did not succeed. |

## Settlement line types

`signed_amount_paise` already carries the sign. Expected net is the sum of the signed lines. Queries do not subtract refunds, fees, or tax a second time.

| `line_type` | Parent | Sign |
| --- | --- | --- |
| `capture` | `attempt_id` set, `refund_id` null | Positive |
| `refund` | `refund_id` set, `attempt_id` null | Negative |
| `fee` | both parents null | Negative |
| `fee_tax` | both parents null | Negative |

A refund line is loaded only for a refund whose status is `success`.

## orders

Grain: one order.

| Column | Type | Null | Rule |
| --- | --- | --- | --- |
| `order_id` | `text` | no | Primary key. |
| `created_at` | `timestamptz` | no | When the order was created. |
| `order_amount_paise` | `bigint` | no | `>= 0`. Order total in paise. |
| `currency` | `text` | no | `INR`. |

## payment_attempts

Grain: one attempt. A retry is a new `attempt_id`.

| Column | Type | Null | Rule |
| --- | --- | --- | --- |
| `attempt_id` | `text` | no | Primary key. |
| `order_id` | `text` | no | Foreign key to `orders.order_id`. |
| `method` | `text` | no | `upi`, `card`, or `netbanking`. |
| `amount_paise` | `bigint` | no | `>= 0`. Equals the parent order amount in this prototype. |
| `status` | `text` | no | `pending`, `success`, or `failed`. Latest status only. |
| `created_at` | `timestamptz` | no | Attempt creation. Cohort date comes from this column. |
| `status_updated_at` | `timestamptz` | no | `occurred_at` of the latest event for this attempt. |

Two successful attempts for one order are allowed. They are an exception, not a constraint violation.

## payment_events

Grain: one event. Insert-only. A repeated `event_id` does not add a row, and does not change counts or amounts.

| Column | Type | Null | Rule |
| --- | --- | --- | --- |
| `event_id` | `text` | no | Primary key. Unique. |
| `attempt_id` | `text` | no | Foreign key to `payment_attempts.attempt_id`. |
| `status` | `text` | no | `pending`, `success`, or `failed`. |
| `occurred_at` | `timestamptz` | no | When the provider says the status happened. |
| `received_at` | `timestamptz` | no | When this prototype received the event. `received_at >= occurred_at`. |

## refunds

Grain: one refund. Independent of attempt status. Only `success` reduces the refundable balance.

| Column | Type | Null | Rule |
| --- | --- | --- | --- |
| `refund_id` | `text` | no | Primary key. |
| `attempt_id` | `text` | no | Foreign key to `payment_attempts.attempt_id`. The attempt is a captured payment. |
| `amount_paise` | `bigint` | no | `>= 0`. |
| `status` | `text` | no | `pending`, `success`, or `failed`. |
| `processed_at` | `timestamptz` | yes | Required when status is `success` or `failed`. Null while `pending`. |
| `settlement_batch_id` | `text` | yes | Foreign key to `settlement_batches.batch_id`. Set when the successful refund is assigned to a batch. A refund may use a later batch than the capture. |

Refundable balance for an attempt = `amount_paise` minus the sum of `success` refunds visible at `as_of` (`processed_at <= as_of`). Pending and failed refunds stay out of that sum. The balance may go below zero in a seeded violation. The exception query reports it. The load does not clamp it.

## settlement_batches

Grain: one settlement. `batch_id` is the settlement reference used for matching.

| Column | Type | Null | Rule |
| --- | --- | --- | --- |
| `batch_id` | `text` | no | Primary key. Settlement reference. |
| `due_at` | `timestamptz` | no | When the batch is due. |
| `settled_at` | `timestamptz` | yes | Null until an actual net is recorded. |
| `actual_net_paise` | `bigint` | yes | Recorded settlement. Null means missing. Never stored as zero to mean missing. |
| `currency` | `text` | no | `INR`. Matching requires the same currency on the batch and the order. |

`settled_at` and `actual_net_paise` are both null or both present.

## settlement_items

Grain: one batch line.

| Column | Type | Null | Rule |
| --- | --- | --- | --- |
| `line_id` | `text` | no | Primary key. |
| `batch_id` | `text` | no | Foreign key to `settlement_batches.batch_id`. |
| `attempt_id` | `text` | yes | Foreign key to `payment_attempts.attempt_id`. Set only for `capture`. |
| `refund_id` | `text` | yes | Foreign key to `refunds.refund_id`. Set only for `refund`. |
| `line_type` | `text` | no | `capture`, `refund`, `fee`, or `fee_tax`. |
| `signed_amount_paise` | `bigint` | no | Signed paise. See line types. Zero is not a valid line. |

## Metrics (�7)

Amounts below are paise. Rates are ratios, reported with the numerator and the denominator as well as the rate.

### Attempt success rate

Successful attempts divided by all initiated attempts in the creation-date cohort, as of `as_of`.

- Numerator: attempts in the cohort whose as-of status is `success`.
- Denominator: all attempts in the cohort, including `pending` and `failed`.
- Pending stays in the denominator.

### Order paid rate

- Numerator: distinct `order_id` in the cohort with at least one attempt whose as-of status is `success`.
- Denominator: distinct `order_id` in the cohort with at least one attempt.
- An order with two successful attempts counts once.

Reported separately from attempt success rate so retries do not inflate paid orders.

### Refund value

- Sum of `amount_paise` for refunds with status `success` and `processed_at <= as_of`, grouped by the `Asia/Kolkata` calendar date of `processed_at`.
- Pending refunds (`processed_at` null, or pending and not yet processed) are a separate sum, not folded into the successful total.
- Failed refunds are a separate count and sum. They do not reduce refund value.

### Expected net by settlement batch

For one `batch_id`: sum of `signed_amount_paise` on its lines.

That sum is captures, minus successful refund deductions, minus fees, minus fee tax, because those lines are already signed.

### Variance

`actual_net_paise - expected_net_paise`, compared exactly in paise.

When `actual_net_paise` is null, variance is null. It is not `0 - expected_net`.

### Overdue batches

A batch is overdue when `as_of > due_at` and `actual_net_paise` is null.

A batch with `due_at` still in the future and a null actual is awaiting settlement. It is not overdue.

## Exceptions (�8)

These are the queues the later SQL must return. Definitions use only the columns above.

| Exception | Rule at `as_of` |
| --- | --- |
| Pending over threshold | As-of status is `pending` and pending age is greater than `pending_review_after`. Status is not changed to `failed`. |
| Duplicate successful attempts | More than one attempt on the same `order_id` has as-of status `success`. |
| Refund over capture | Sum of visible successful refunds for one attempt is greater than that attempt's `amount_paise`. |
| Failed methods | Count of attempts with as-of status `failed`, by `method`. |
| Missing settlement | `as_of > due_at` and `actual_net_paise` is null. Same population as overdue. |
| Partial settlement | `actual_net_paise` is not null, and at least one `success` refund with this `settlement_batch_id` has no `refund` line. |
| Amount mismatch | `actual_net_paise` is not null and is not equal to expected net. |

A batch can carry a partial flag and a mismatch flag at the same time. Each flag stays visible.

## Coverage check

�6 columns: `order_id`, `created_at`, `order_amount_paise`, `currency`, `attempt_id`, `order_id`, `method`, `amount_paise`, `status`, `created_at`, `status_updated_at`, `event_id`, `attempt_id`, `status`, `occurred_at`, `received_at`, `refund_id`, `attempt_id`, `amount_paise`, `status`, `processed_at`, `settlement_batch_id`, `line_id`, `batch_id`, `attempt_id`, `refund_id`, `line_type`, `signed_amount_paise`, `batch_id`, `due_at`, `settled_at`, `actual_net_paise`, `currency`.

�7 metrics: attempt success rate, order paid rate, refund value, expected net, variance, overdue batches.
