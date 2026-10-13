-- Media server (service media, asterisk): voicemail PIN per user, voicemail number
-- and ring time in settings, realtime views read by asterisk
-- docker compose exec -T postgres psql -U kamailio kamailio < postgres/migrations/009-media.sql

BEGIN;

ALTER TABLE subscriber ADD COLUMN IF NOT EXISTS vm_pin VARCHAR(16) NOT NULL DEFAULT '0000' CHECK (vm_pin ~ '^[0-9]+$');
ALTER TABLE settings ADD COLUMN IF NOT EXISTS voicemail_number VARCHAR(32) NOT NULL DEFAULT '*86';
ALTER TABLE settings ADD COLUMN IF NOT EXISTS voicemail_timeout INTEGER NOT NULL DEFAULT 20 CHECK (voicemail_timeout > 0);

-- voicemail boxes (app_voicemail realtime), PIN = subscriber.vm_pin
CREATE OR REPLACE VIEW vm_mailbox AS
SELECT
    id AS uniqueid,
    'default'::VARCHAR(80) AS context,
    username::VARCHAR(80) AS mailbox,
    vm_pin::VARCHAR(80) AS password,
    number::VARCHAR(80) AS fullname
FROM subscriber;

-- PIN changed in the voicemail menu
CREATE OR REPLACE FUNCTION vm_mailbox_update() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE subscriber SET vm_pin = NEW.password WHERE id = OLD.uniqueid;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS vm_mailbox_update ON vm_mailbox;
CREATE TRIGGER vm_mailbox_update INSTEAD OF UPDATE ON vm_mailbox
    FOR EACH ROW EXECUTE FUNCTION vm_mailbox_update();

-- PJSIP endpoint and AoR per user (sorcery realtime), only used for MWI:
-- asterisk sends unsolicited NOTIFY message-summary to sip:<user>@127.0.0.1:5060
-- (kamailio), kamailio forwards it to the registered devices of the user
CREATE OR REPLACE VIEW ps_endpoints AS
SELECT
    username::VARCHAR(40) AS id,
    'transport-kamailio'::VARCHAR(40) AS transport,
    username::VARCHAR(2048) AS aors,
    'from-kamailio'::VARCHAR(40) AS context,
    'all'::VARCHAR(200) AS disallow,
    'alaw,ulaw'::VARCHAR(200) AS allow,
    (username || '@default')::VARCHAR(40) AS mailboxes
FROM subscriber;

CREATE OR REPLACE VIEW ps_aors AS
SELECT
    username::VARCHAR(40) AS id,
    ('sip:' || username || '@127.0.0.1:5060')::VARCHAR(255) AS contact,
    1 AS max_contacts,
    (username || '@default')::VARCHAR(80) AS mailboxes
FROM subscriber;

COMMIT;
