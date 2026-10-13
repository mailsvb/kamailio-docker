-- Per trunk switch for P-Asserted-Identity (1und1 rejects a PAI that differs from the account)
-- docker compose exec -T postgres psql -U kamailio kamailio < postgres/migrations/003-trunk-send-pai.sql

ALTER TABLE trunk ADD COLUMN IF NOT EXISTS send_pai BOOLEAN NOT NULL DEFAULT true;
