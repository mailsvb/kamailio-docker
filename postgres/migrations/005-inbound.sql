-- Incoming calls: trunk source networks, inbound group and ring timeout
-- docker compose exec -T postgres psql -U kamailio kamailio < postgres/migrations/005-inbound.sql

BEGIN;

ALTER TABLE trunk ADD COLUMN IF NOT EXISTS inbound_src CIDR[] NOT NULL DEFAULT '{}';
ALTER TABLE trunk ADD COLUMN IF NOT EXISTS inbound_group_id INTEGER REFERENCES sip_group(id) ON DELETE SET NULL;
ALTER TABLE trunk ADD COLUMN IF NOT EXISTS ring_timeout INTEGER NOT NULL DEFAULT 60;

CREATE OR REPLACE FUNCTION kam_trunk_inbound(p_trunk VARCHAR, p_group VARCHAR, p_src CIDR[])
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO sip_group (name) VALUES (p_group) ON CONFLICT (name) DO NOTHING;
    UPDATE trunk
    SET inbound_group_id = (SELECT id FROM sip_group WHERE name = p_group),
        inbound_src = p_src
    WHERE name = p_trunk;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown trunk %', p_trunk;
    END IF;
END;
$$;

COMMIT;
