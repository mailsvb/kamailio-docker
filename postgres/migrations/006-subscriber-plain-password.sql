-- Simplified subscriber table: plain text password, no domain/ha1/ha1b
-- (kamailio.cfg: auth_db calculate_ha1 1, password_column "password").
-- The hashed passwords cannot be converted: set the password of every user afterwards.
-- docker compose exec -T postgres psql -U kamailio kamailio < postgres/migrations/006-subscriber-plain-password.sql

BEGIN;

ALTER TABLE subscriber DROP CONSTRAINT IF EXISTS subscriber_account_idx;
DROP INDEX IF EXISTS subscriber_username_idx;
ALTER TABLE subscriber DROP COLUMN IF EXISTS domain;
ALTER TABLE subscriber DROP COLUMN IF EXISTS ha1;
ALTER TABLE subscriber DROP COLUMN IF EXISTS ha1b;
ALTER TABLE subscriber ADD CONSTRAINT subscriber_username_key UNIQUE (username);
ALTER TABLE subscriber ALTER COLUMN username DROP DEFAULT;

CREATE OR REPLACE FUNCTION kam_add_user(p_username VARCHAR, p_number VARCHAR, p_password VARCHAR)
RETURNS INTEGER LANGUAGE sql AS $$
    INSERT INTO subscriber (username, number, password)
    VALUES (p_username, p_number, p_password)
    ON CONFLICT (username) DO UPDATE
        SET number = EXCLUDED.number, password = EXCLUDED.password
    RETURNING id;
$$;

COMMIT;
