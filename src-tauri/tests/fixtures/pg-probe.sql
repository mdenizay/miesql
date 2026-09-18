-- Seed for the PostgreSQL protocol spike. It exists to prove one thing: that the simple
-- query protocol renders every type as text and reports the row description even when a
-- query returns nothing. Load it into a scratch database, never a real one.
DROP TABLE IF EXISTS types_probe;

CREATE TABLE types_probe (
    id serial PRIMARY KEY,
    name text NOT NULL,
    amount numeric(12,4),
    ratio double precision,
    when_ts timestamptz,
    when_d date,
    flag boolean,
    ident uuid,
    doc jsonb,
    tags text[],
    raw bytea
);

INSERT INTO types_probe (name, amount, ratio, when_ts, when_d, flag, ident, doc, tags, raw)
VALUES ('ada', 1234.5600, 0.5, '2026-01-02 03:04:05+00', '2026-01-02', true,
        '12345678-9abc-def0-1234-56789abcdef0', '{"k":[1,2]}', ARRAY['a','b'], '\x00ff10');

-- A row of NULLs, so the tests can check NULL stays distinct from the empty string.
INSERT INTO types_probe (name) VALUES ('nulls');
