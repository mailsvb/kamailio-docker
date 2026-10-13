-- LAN trunks: use the LAN address of kamailio (Contact, Record-Route, SDP, registration)
-- docker compose exec -T postgres psql -U kamailio kamailio -v lan_contact=192.168.21.12:5060 < postgres/migrations/004-lan-trunk.sql

BEGIN;

ALTER TABLE settings ADD COLUMN IF NOT EXISTS lan_contact VARCHAR(255) NOT NULL DEFAULT '';
UPDATE settings SET lan_contact = :'lan_contact';

ALTER TABLE trunk ADD COLUMN IF NOT EXISTS lan BOOLEAN NOT NULL DEFAULT false;

CREATE OR REPLACE VIEW uacreg AS
SELECT
    id,
    -- l_uuid is the user part of the Contact, providers expect the account number there
    auth_username::VARCHAR(64) AS l_uuid,
    auth_username::VARCHAR(64) AS l_username,
    domain::VARCHAR(64) AS l_domain,
    auth_username::VARCHAR(64) AS r_username,
    domain::VARCHAR(64) AS r_domain,
    coalesce(realm, '')::VARCHAR(64) AS realm,
    auth_username::VARCHAR(64) AS auth_username,
    auth_password::VARCHAR(64) AS auth_password,
    ''::VARCHAR(128) AS auth_ha1,
    coalesce(proxy, 'sip:' || domain)::VARCHAR(255) AS auth_proxy,
    expires,
    0 AS flags,
    0 AS reg_delay,
    -- '' = reg_contact_addr (EXTERNAL_IP), LAN trunks register with the LAN address
    (CASE WHEN lan THEN (SELECT lan_contact FROM settings) ELSE '' END)::VARCHAR(255) AS contact_addr,
    ''::VARCHAR(128) AS socket
FROM trunk
WHERE register AND enabled;

COMMIT;
