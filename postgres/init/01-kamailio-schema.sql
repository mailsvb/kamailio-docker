-- Kamailio database schema (PostgreSQL)
-- Executed once by the postgres container on first start (empty data volume).
-- Standard tables are taken from kamailio 6.1.4 utils/kamctl/postgres/*-create.sql

-- realm used for digest authentication, must match SIP_REALM of kamailio
\getenv sip_realm SIP_REALM
-- LAN address of kamailio, used as registration contact for LAN trunks
\getenv public_ip PUBLIC_IP

-- ----- standard kamailio tables -----

CREATE TABLE version (
    id SERIAL PRIMARY KEY NOT NULL,
    table_name VARCHAR(32) NOT NULL,
    table_version INTEGER DEFAULT 0 NOT NULL,
    CONSTRAINT version_table_name_idx UNIQUE (table_name)
);

INSERT INTO version (table_name, table_version) values ('version','1');

CREATE TABLE subscriber (
    id SERIAL PRIMARY KEY NOT NULL,
    -- simplified: no domain (use_domain 0), plain text password (calculate_ha1 1)
    username VARCHAR(64) NOT NULL UNIQUE,
    password VARCHAR(64) DEFAULT '' NOT NULL,
    -- custom: phone number of the user (sent as P-Asserted-Identity on trunks)
    number VARCHAR(64) DEFAULT '' NOT NULL,
    -- custom: max. parallel registrations of the user, NULL = settings.max_contacts
    max_contacts INTEGER CHECK (max_contacts >= 1),
    -- custom: device type of the last registration, set by kamailio
    -- ('Unify' when the User-Agent contains Desk_Phone_IP)
    device_type VARCHAR(16) NOT NULL DEFAULT 'Generic' CHECK (device_type IN ('Generic', 'Unify'))
);

INSERT INTO version (table_name, table_version) values ('subscriber','7');

-- ----- custom tables: groups and trunks -----

CREATE TABLE settings (
    id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    realm VARCHAR(64) NOT NULL,
    -- contact address (host:port) for registrations at LAN trunks
    lan_contact VARCHAR(255) NOT NULL DEFAULT '',
    -- max. parallel registrations per user (1 = last registration wins),
    -- overridden by subscriber.max_contacts
    max_contacts INTEGER NOT NULL DEFAULT 1 CHECK (max_contacts >= 1)
);

INSERT INTO settings (realm, lan_contact) VALUES (
    coalesce(nullif(:'sip_realm', ''), 'kamailio'),
    CASE WHEN :'public_ip' = '' THEN '' ELSE :'public_ip' || ':5060' END);

CREATE TABLE sip_group (
    id SERIAL PRIMARY KEY NOT NULL,
    name VARCHAR(64) NOT NULL UNIQUE
);

CREATE TABLE user_group (
    subscriber_id INTEGER NOT NULL REFERENCES subscriber(id) ON DELETE CASCADE,
    group_id INTEGER NOT NULL REFERENCES sip_group(id) ON DELETE CASCADE,
    PRIMARY KEY (subscriber_id, group_id)
);

CREATE TABLE trunk (
    id SERIAL PRIMARY KEY NOT NULL,
    name VARCHAR(64) NOT NULL UNIQUE,
    -- SIP domain of the provider, used in Request-URI, From and PAI
    domain VARCHAR(64) NOT NULL,
    -- optional outbound proxy as SIP URI, e.g. 'sip:sip.provider.net:5060;transport=udp'
    proxy VARCHAR(255),
    -- digest credentials, NULL for IP based trunks
    auth_username VARCHAR(64),
    auth_password VARCHAR(64),
    -- NULL = answer challenges for any realm
    realm VARCHAR(64),
    -- user part of From, defaults to auth_username
    from_user VARCHAR(64),
    -- true = kamailio registers at the provider (via uac module)
    register BOOLEAN NOT NULL DEFAULT false,
    expires INTEGER NOT NULL DEFAULT 300,
    -- number normalization: strip N leading digits, then prepend prefix
    strip INTEGER NOT NULL DEFAULT 0,
    prefix VARCHAR(16) NOT NULL DEFAULT '',
    -- send P-Asserted-Identity with the number of the user
    send_pai BOOLEAN NOT NULL DEFAULT true,
    -- trunk is on the LAN: use the LAN address of kamailio instead of EXTERNAL_IP
    lan BOOLEAN NOT NULL DEFAULT false,
    -- incoming calls: accepted from these source networks, ring all members of
    -- inbound_group_id in parallel for ring_timeout seconds
    inbound_src CIDR[] NOT NULL DEFAULT '{}',
    inbound_group_id INTEGER REFERENCES sip_group(id) ON DELETE SET NULL,
    ring_timeout INTEGER NOT NULL DEFAULT 60,
    enabled BOOLEAN NOT NULL DEFAULT true,
    CHECK (NOT register OR (auth_username IS NOT NULL AND auth_password IS NOT NULL))
);

-- dedicated trunk of a user for outgoing calls (takes precedence over group trunks)
ALTER TABLE subscriber ADD COLUMN trunk_id INTEGER REFERENCES trunk(id) ON DELETE SET NULL;

CREATE TABLE group_trunk (
    group_id INTEGER NOT NULL REFERENCES sip_group(id) ON DELETE CASCADE,
    trunk_id INTEGER NOT NULL REFERENCES trunk(id) ON DELETE CASCADE,
    -- lowest priority wins when a user is in several groups
    priority INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (group_id, trunk_id)
);

-- uac module reads trunk registrations from this view (reload: kamcmd uac.reg_reload)
CREATE VIEW uacreg AS
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

INSERT INTO version (table_name, table_version) values ('uacreg','5');

-- ----- provisioning helpers -----

-- add or update a user: SELECT kam_add_user('1001', '+4930123456', 'secret');
CREATE FUNCTION kam_add_user(p_username VARCHAR, p_number VARCHAR, p_password VARCHAR)
RETURNS INTEGER LANGUAGE sql AS $$
    INSERT INTO subscriber (username, number, password)
    VALUES (p_username, p_number, p_password)
    ON CONFLICT (username) DO UPDATE
        SET number = EXCLUDED.number, password = EXCLUDED.password
    RETURNING id;
$$;

-- assign the dedicated trunk of a user: SELECT kam_user_trunk('1001', 'provider-a');
-- NULL as trunk removes the assignment
CREATE FUNCTION kam_user_trunk(p_username VARCHAR, p_trunk VARCHAR)
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

-- assign a user to a group (group is created if missing): SELECT kam_user_to_group('1001', 'office');
CREATE FUNCTION kam_user_to_group(p_username VARCHAR, p_group VARCHAR)
RETURNS VOID LANGUAGE sql AS $$
    INSERT INTO sip_group (name) VALUES (p_group) ON CONFLICT (name) DO NOTHING;
    INSERT INTO user_group (subscriber_id, group_id)
    SELECT s.id, g.id FROM subscriber s, sip_group g
    WHERE s.username = p_username AND g.name = p_group
    ON CONFLICT DO NOTHING;
$$;

-- assign a trunk to a group: SELECT kam_trunk_to_group('provider-a', 'office', 0);
CREATE FUNCTION kam_trunk_to_group(p_trunk VARCHAR, p_group VARCHAR, p_priority INTEGER DEFAULT 0)
RETURNS VOID LANGUAGE sql AS $$
    INSERT INTO sip_group (name) VALUES (p_group) ON CONFLICT (name) DO NOTHING;
    INSERT INTO group_trunk (group_id, trunk_id, priority)
    SELECT g.id, t.id, p_priority FROM sip_group g, trunk t
    WHERE g.name = p_group AND t.name = p_trunk
    ON CONFLICT (group_id, trunk_id) DO UPDATE SET priority = EXCLUDED.priority;
$$;

-- incoming calls of a trunk ring all members of a group (group is created if missing):
-- SELECT kam_trunk_inbound('provider-a', 'office', '{192.168.0.1/32}');
CREATE FUNCTION kam_trunk_inbound(p_trunk VARCHAR, p_group VARCHAR, p_src CIDR[])
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
