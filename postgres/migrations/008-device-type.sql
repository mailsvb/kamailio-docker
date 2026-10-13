-- Device type of the last registration (Generic / Unify), set by kamailio on REGISTER
-- docker compose exec -T postgres psql -U kamailio kamailio < postgres/migrations/008-device-type.sql

BEGIN;

ALTER TABLE subscriber ADD COLUMN IF NOT EXISTS device_type VARCHAR(16) NOT NULL DEFAULT 'Generic' CHECK (device_type IN ('Generic', 'Unify'));

COMMIT;
