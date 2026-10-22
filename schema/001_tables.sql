-- Tables for the payments prototype. Column rules: docs/data-dictionary.md.
-- Attempt amount matching its order is enforced by the seed, not a trigger.

CREATE TABLE orders (
    order_id text PRIMARY KEY,
    created_at timestamptz NOT NULL,
    order_amount_paise bigint NOT NULL,
    currency text NOT NULL,
    CONSTRAINT orders_amount_non_negative CHECK (order_amount_paise >= 0),
    CONSTRAINT orders_currency_inr CHECK (currency = 'INR')
);

CREATE TABLE payment_attempts (
    attempt_id text PRIMARY KEY,
    order_id text NOT NULL REFERENCES orders (order_id),
    method text NOT NULL,
    amount_paise bigint NOT NULL,
    status text NOT NULL,
    created_at timestamptz NOT NULL,
    status_updated_at timestamptz NOT NULL,
    CONSTRAINT payment_attempts_method CHECK (method IN ('upi', 'card', 'netbanking')),
    CONSTRAINT payment_attempts_amount_non_negative CHECK (amount_paise >= 0),
    CONSTRAINT payment_attempts_status CHECK (status IN ('pending', 'success', 'failed'))
);

CREATE TABLE payment_events (
    event_id text PRIMARY KEY,
    attempt_id text NOT NULL REFERENCES payment_attempts (attempt_id),
    status text NOT NULL,
    occurred_at timestamptz NOT NULL,
    received_at timestamptz NOT NULL,
    CONSTRAINT payment_events_status CHECK (status IN ('pending', 'success', 'failed')),
    CONSTRAINT payment_events_received_after_occurred CHECK (received_at >= occurred_at)
);

CREATE FUNCTION reject_payment_event_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'payment_events is insert-only';
END;
$$;

CREATE TRIGGER payment_events_append_only
BEFORE UPDATE OR DELETE ON payment_events
FOR EACH ROW
EXECUTE FUNCTION reject_payment_event_mutation();

CREATE TABLE settlement_batches (
    batch_id text PRIMARY KEY,
    due_at timestamptz NOT NULL,
    settled_at timestamptz,
    actual_net_paise bigint,
    currency text NOT NULL,
    CONSTRAINT settlement_batches_currency_inr CHECK (currency = 'INR'),
    CONSTRAINT settlement_batches_actual_pair CHECK (
        (settled_at IS NULL AND actual_net_paise IS NULL)
        OR (settled_at IS NOT NULL AND actual_net_paise IS NOT NULL)
    )
);

CREATE TABLE refunds (
    refund_id text PRIMARY KEY,
    attempt_id text NOT NULL REFERENCES payment_attempts (attempt_id),
    amount_paise bigint NOT NULL,
    status text NOT NULL,
    processed_at timestamptz,
    settlement_batch_id text REFERENCES settlement_batches (batch_id),
    CONSTRAINT refunds_amount_non_negative CHECK (amount_paise >= 0),
    CONSTRAINT refunds_status CHECK (status IN ('pending', 'success', 'failed')),
    CONSTRAINT refunds_processed_at_matches_status CHECK (
        (status = 'pending' AND processed_at IS NULL)
        OR (status IN ('success', 'failed') AND processed_at IS NOT NULL)
    )
);

CREATE TABLE settlement_items (
    line_id text PRIMARY KEY,
    batch_id text NOT NULL REFERENCES settlement_batches (batch_id),
    attempt_id text REFERENCES payment_attempts (attempt_id),
    refund_id text REFERENCES refunds (refund_id),
    line_type text NOT NULL,
    signed_amount_paise bigint NOT NULL,
    CONSTRAINT settlement_items_shape CHECK (
        (
            line_type = 'capture'
            AND attempt_id IS NOT NULL
            AND refund_id IS NULL
            AND signed_amount_paise > 0
        )
        OR (
            line_type = 'refund'
            AND attempt_id IS NULL
            AND refund_id IS NOT NULL
            AND signed_amount_paise < 0
        )
        OR (
            line_type = 'fee'
            AND attempt_id IS NULL
            AND refund_id IS NULL
            AND signed_amount_paise < 0
        )
        OR (
            line_type = 'fee_tax'
            AND attempt_id IS NULL
            AND refund_id IS NULL
            AND signed_amount_paise < 0
        )
    )
);
