-- Max. parallel registrations: global default in settings, per user override in subscriber
-- docker compose exec -T postgres psql -U kamailio kamailio < postgres/migrations/007-max-contacts.sql

BEGIN;

ALTER TABLE settings ADD COLUMN IF NOT EXISTS max_contacts INTEGER NOT NULL DEFAULT 1 CHECK (max_contacts >= 1);
ALTER TABLE subscriber ADD COLUMN IF NOT EXISTS max_contacts INTEGER CHECK (max_contacts >= 1);

COMMIT;
