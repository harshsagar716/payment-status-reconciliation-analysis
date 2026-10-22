-- Pass/fail for each labeled scenario. Snapshots are taken from the stored rows.
-- Late pending is checked twice: 25 hours after the pending event, then at the success event.

SET TIME ZONE 'UTC';

CREATE FUNCTION pg_temp.attempt_status(p_attempt_id text, p_as_of timestamptz)
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT status
    FROM payment_events
    WHERE attempt_id = p_attempt_id
      AND received_at <= p_as_of
    ORDER BY occurred_at DESC
    LIMIT 1;
$$;

CREATE FUNCTION pg_temp.pending_over_threshold(p_attempt_id text, p_as_of timestamptz)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT status = 'pending'
       AND (p_as_of - occurred_at) > interval '24 hours'
    FROM payment_events
    WHERE attempt_id = p_attempt_id
      AND received_at <= p_as_of
    ORDER BY occurred_at DESC
    LIMIT 1;
$$;

CREATE TEMP TABLE uat_check (
    scenario_id text NOT NULL,
    check_name text NOT NULL,
    ok boolean
);

INSERT INTO uat_check (scenario_id, check_name, ok)
SELECT 'failed_then_success', 'two_attempts',
       (SELECT count(*) = 2
        FROM payment_attempts
        WHERE order_id = 'uat_failed_then_success_order');

INSERT INTO uat_check (scenario_id, check_name, ok)
SELECT 'failed_then_success', 'failure_remains',
       (SELECT pg_temp.attempt_status(
                   'uat_failed_then_success_attempt_fail',
                   timestamptz '2026-12-31 00:00:00+00'
               ) = 'failed'
           AND pg_temp.attempt_status(
                   'uat_failed_then_success_attempt_ok',
                   timestamptz '2026-12-31 00:00:00+00'
               ) = 'success');

INSERT INTO uat_check (scenario_id, check_name, ok)
SELECT 'failed_then_success', 'one_paid_order',
       (SELECT count(DISTINCT order_id) = 1
        FROM payment_attempts
        WHERE order_id = 'uat_failed_then_success_order'
          AND pg_temp.attempt_status(attempt_id, timestamptz '2026-12-31 00:00:00+00') = 'success');

INSERT INTO uat_check (scenario_id, check_name, ok)
SELECT 'late_pending', 'flag_before_resolution',
       (SELECT pg_temp.pending_over_threshold(
                   'uat_late_pending_attempt',
                   pending.occurred_at + interval '25 hours'
               )
           AND (pending.occurred_at + interval '25 hours') < success.received_at
        FROM payment_events pending
        JOIN payment_events success
          ON success.event_id = 'uat_late_pending_event_success'
        WHERE pending.event_id = 'uat_late_pending_event_pending');

INSERT INTO uat_check (scenario_id, check_name, ok)
SELECT 'late_pending', 'resolved_after_success',
       (SELECT pg_temp.attempt_status('uat_late_pending_attempt', success.received_at) = 'success'
           AND COALESCE(
                   pg_temp.pending_over_threshold('uat_late_pending_attempt', success.received_at),
                   false
               ) = false
        FROM payment_events success
        WHERE success.event_id = 'uat_late_pending_event_success');

INSERT INTO uat_check (scenario_id, check_name, ok)
SELECT 'late_pending', 'both_events_kept',
       (SELECT count(*) = 2
        FROM payment_events
        WHERE attempt_id = 'uat_late_pending_attempt');

INSERT INTO uat_check (scenario_id, check_name, ok)
SELECT 'replayed_event', 'one_event_row',
       (SELECT count(*) = 1
        FROM payment_events
        WHERE event_id = 'uat_replayed_event_event');

INSERT INTO uat_check (scenario_id, check_name, ok)
SELECT 'replayed_event', 'amount_not_doubled',
       (SELECT count(*) = 1 AND sum(amount_paise) = 100000
        FROM payment_attempts
        WHERE order_id = 'uat_replayed_event_order');

INSERT INTO uat_check (scenario_id, check_name, ok)
SELECT 'double_success', 'two_success_attempts',
       (SELECT count(*) = 2
        FROM payment_attempts
        WHERE order_id = 'uat_double_success_order'
          AND pg_temp.attempt_status(attempt_id, timestamptz '2026-12-31 00:00:00+00') = 'success');

INSERT INTO uat_check (scenario_id, check_name, ok)
SELECT 'double_success', 'one_paid_order',
       (SELECT count(DISTINCT order_id) = 1
        FROM payment_attempts
        WHERE order_id = 'uat_double_success_order'
          AND pg_temp.attempt_status(attempt_id, timestamptz '2026-12-31 00:00:00+00') = 'success');

INSERT INTO uat_check (scenario_id, check_name, ok)
SELECT 'partial_refunds', 'successful_refund_50000',
       (SELECT COALESCE(sum(amount_paise), 0) = 50000
        FROM refunds
        WHERE attempt_id = 'uat_partial_refunds_attempt'
          AND status = 'success'
          AND processed_at <= timestamptz '2026-12-31 00:00:00+00');

INSERT INTO uat_check (scenario_id, check_name, ok)
SELECT 'partial_refunds', 'remaining_balance_50000',
       (SELECT attempt.amount_paise - COALESCE(sum(refund.amount_paise), 0) = 50000
        FROM payment_attempts attempt
        LEFT JOIN refunds refund
          ON refund.attempt_id = attempt.attempt_id
         AND refund.status = 'success'
         AND refund.processed_at <= timestamptz '2026-12-31 00:00:00+00'
        WHERE attempt.attempt_id = 'uat_partial_refunds_attempt'
        GROUP BY attempt.amount_paise);

INSERT INTO uat_check (scenario_id, check_name, ok)
SELECT 'partial_refunds', 'pending_refund_excluded',
       (SELECT COALESCE(sum(amount_paise), 0) = 10000
        FROM refunds
        WHERE attempt_id = 'uat_partial_refunds_attempt'
          AND status = 'pending');

INSERT INTO uat_check (scenario_id, check_name, ok)
SELECT 'fee_tax_net', 'expected_net_87640',
       (SELECT COALESCE(sum(signed_amount_paise), 0) = 87640
        FROM settlement_items
        WHERE batch_id = 'uat_fee_tax_net_batch');

INSERT INTO uat_check (scenario_id, check_name, ok)
SELECT 'fee_tax_net', 'variance_minus_640',
       (SELECT batch.actual_net_paise - (
                   SELECT COALESCE(sum(item.signed_amount_paise), 0)
                   FROM settlement_items item
                   WHERE item.batch_id = batch.batch_id
               ) = -640
        FROM settlement_batches batch
        WHERE batch.batch_id = 'uat_fee_tax_net_batch');

INSERT INTO uat_check (scenario_id, check_name, ok)
SELECT 'fee_tax_net', 'mismatch_flag',
       (SELECT batch.actual_net_paise IS NOT NULL
           AND batch.actual_net_paise <> (
                   SELECT COALESCE(sum(item.signed_amount_paise), 0)
                   FROM settlement_items item
                   WHERE item.batch_id = batch.batch_id
               )
        FROM settlement_batches batch
        WHERE batch.batch_id = 'uat_fee_tax_net_batch');

INSERT INTO uat_check (scenario_id, check_name, ok)
SELECT 'fee_tax_net', 'partial_flag_absent',
       (SELECT batch.actual_net_paise IS NOT NULL
           AND NOT EXISTS (
                   SELECT 1
                   FROM refunds refund
                   WHERE refund.settlement_batch_id = batch.batch_id
                     AND refund.status = 'success'
                     AND NOT EXISTS (
                         SELECT 1
                         FROM settlement_items item
                         WHERE item.refund_id = refund.refund_id
                           AND item.line_type = 'refund'
                     )
               )
        FROM settlement_batches batch
        WHERE batch.batch_id = 'uat_fee_tax_net_batch');

INSERT INTO uat_check (scenario_id, check_name, ok)
SELECT 'not_yet_due', 'awaiting_not_overdue',
       (SELECT batch.actual_net_paise IS NULL
           AND batch.due_at > snap.as_of
           AND NOT (snap.as_of > batch.due_at AND batch.actual_net_paise IS NULL)
        FROM settlement_batches batch
        CROSS JOIN (
            SELECT max(event.received_at) AS as_of
            FROM payment_events event
            JOIN payment_attempts attempt ON attempt.attempt_id = event.attempt_id
            WHERE attempt.order_id = 'uat_not_yet_due_order'
        ) snap
        WHERE batch.batch_id = 'uat_not_yet_due_batch');

INSERT INTO uat_check (scenario_id, check_name, ok)
SELECT 'overdue_missing', 'overdue_flag',
       (SELECT (batch.due_at + interval '1 hour') > batch.due_at
           AND batch.actual_net_paise IS NULL
        FROM settlement_batches batch
        WHERE batch.batch_id = 'uat_overdue_missing_batch');

INSERT INTO uat_check (scenario_id, check_name, ok)
SELECT 'overdue_missing', 'variance_null',
       (SELECT (
                   SELECT item_sum.expected_net
                   FROM (
                       SELECT COALESCE(sum(signed_amount_paise), 0) AS expected_net
                       FROM settlement_items
                       WHERE batch_id = 'uat_overdue_missing_batch'
                   ) item_sum
               ) = 100000
           AND batch.actual_net_paise IS NULL
           AND (batch.actual_net_paise - (
                   SELECT COALESCE(sum(item.signed_amount_paise), 0)
                   FROM settlement_items item
                   WHERE item.batch_id = batch.batch_id
               )) IS NULL
        FROM settlement_batches batch
        WHERE batch.batch_id = 'uat_overdue_missing_batch');

INSERT INTO uat_check (scenario_id, check_name, ok)
SELECT 'partial_settlement', 'partial_flag',
       (SELECT batch.actual_net_paise IS NOT NULL
           AND EXISTS (
                   SELECT 1
                   FROM refunds refund
                   WHERE refund.settlement_batch_id = batch.batch_id
                     AND refund.status = 'success'
                     AND refund.processed_at <= batch.settled_at
                     AND NOT EXISTS (
                         SELECT 1
                         FROM settlement_items item
                         WHERE item.refund_id = refund.refund_id
                           AND item.line_type = 'refund'
                     )
               )
        FROM settlement_batches batch
        WHERE batch.batch_id = 'uat_partial_settlement_batch');

INSERT INTO uat_check (scenario_id, check_name, ok)
SELECT 'partial_settlement', 'variance_zero',
       (SELECT batch.actual_net_paise = 98000
           AND batch.actual_net_paise = (
                   SELECT COALESCE(sum(item.signed_amount_paise), 0)
                   FROM settlement_items item
                   WHERE item.batch_id = batch.batch_id
               )
        FROM settlement_batches batch
        WHERE batch.batch_id = 'uat_partial_settlement_batch');

INSERT INTO uat_check (scenario_id, check_name, ok)
SELECT 'refund_over_capture', 'successful_refund_110000',
       (SELECT COALESCE(sum(amount_paise), 0) = 110000
        FROM refunds
        WHERE attempt_id = 'uat_refund_over_capture_attempt'
          AND status = 'success'
          AND processed_at <= timestamptz '2026-12-31 00:00:00+00');

INSERT INTO uat_check (scenario_id, check_name, ok)
SELECT 'refund_over_capture', 'exceeds_capture',
       (SELECT COALESCE(sum(refund.amount_paise), 0) > attempt.amount_paise
        FROM payment_attempts attempt
        LEFT JOIN refunds refund
          ON refund.attempt_id = attempt.attempt_id
         AND refund.status = 'success'
         AND refund.processed_at <= timestamptz '2026-12-31 00:00:00+00'
        WHERE attempt.attempt_id = 'uat_refund_over_capture_attempt'
        GROUP BY attempt.amount_paise);

SELECT scenario_id,
       CASE WHEN bool_and(COALESCE(ok, false)) THEN 'pass' ELSE 'fail' END AS result
FROM uat_check
GROUP BY scenario_id
ORDER BY scenario_id;

DO $$
DECLARE
    msg text;
    expected text[] := ARRAY[
        'failed_then_success',
        'late_pending',
        'replayed_event',
        'double_success',
        'partial_refunds',
        'fee_tax_net',
        'not_yet_due',
        'overdue_missing',
        'partial_settlement',
        'refund_over_capture'
    ];
BEGIN
    SELECT string_agg(scenario_id || '.' || check_name, ', ' ORDER BY scenario_id, check_name)
    INTO msg
    FROM uat_check
    WHERE ok IS NOT TRUE;

    IF msg IS NOT NULL THEN
        RAISE EXCEPTION 'UAT failed: %', msg;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM unnest(expected) AS scenario_id
        WHERE scenario_id NOT IN (SELECT uat_check.scenario_id FROM uat_check)
    ) THEN
        RAISE EXCEPTION 'UAT missing a scenario id';
    END IF;
END $$;
