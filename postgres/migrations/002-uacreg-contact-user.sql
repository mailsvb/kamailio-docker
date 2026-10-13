-- Contact user of trunk registrations = account username (1und1 rejects others with 403)
-- docker compose exec -T postgres psql -U kamailio kamailio < postgres/migrations/002-uacreg-contact-user.sql

BEGIN;

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
    ''::VARCHAR(255) AS contact_addr,
    ''::VARCHAR(128) AS socket
FROM trunk
WHERE register AND enabled;

COMMIT;
