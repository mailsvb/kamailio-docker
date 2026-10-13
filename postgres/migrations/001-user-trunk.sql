-- Adds the dedicated trunk per user to an existing database.
-- New databases get this from postgres/init/01-kamailio-schema.sql.
-- docker compose exec -T postgres psql -U kamailio kamailio < postgres/migrations/001-user-trunk.sql

BEGIN;

ALTER TABLE subscriber ADD COLUMN IF NOT EXISTS trunk_id INTEGER REFERENCES trunk(id) ON DELETE SET NULL;

CREATE OR REPLACE FUNCTION kam_user_trunk(p_username VARCHAR, p_trunk VARCHAR)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    UPDATE subscriber
    SET trunk_id = (SELECT id FROM trunk WHERE name = p_trunk)
    WHERE username = p_username;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown user %', p_username;
    END IF;
    IF p_trunk IS NOT NULL AND NOT EXISTS (SELECT 1 FROM trunk WHERE name = p_trunk) THEN
        RAISE EXCEPTION 'unknown trunk %', p_trunk;
    END IF;
END;
$$;

COMMIT;
