-- Example provisioning (not loaded automatically)
-- docker compose exec -T postgres psql -U kamailio kamailio < postgres/examples/example-data.sql

-- trunk with registration + digest authentication
INSERT INTO trunk (name, domain, proxy, auth_username, auth_password, register, strip, prefix)
VALUES ('provider-reg', 'sip.provider-a.example', NULL, '4930111111', 'trunk-secret', true, 0, '');

-- trunk with digest authentication on INVITE only (no registration)
INSERT INTO trunk (name, domain, proxy, auth_username, auth_password, register)
VALUES ('provider-digest', 'sip.provider-b.example', 'sip:proxy.provider-b.example:5060;transport=udp', 'acct42', 'trunk-secret', false);

-- IP based trunk, provider trusts the public IP of kamailio
INSERT INTO trunk (name, domain, from_user, register, strip, prefix)
VALUES ('provider-ip', 'pstn.provider-c.example', '4930222222', false, 1, '+49');

-- users
SELECT kam_add_user('1001', '+4930111111', 'user-secret');
SELECT kam_add_user('1002', '+4930111112', 'user-secret');

-- dedicated trunk per user (used first for outgoing calls)
SELECT kam_user_trunk('1001', 'provider-reg');
SELECT kam_user_trunk('1002', 'provider-digest');

-- optional: group trunks, only used for users without a dedicated trunk
SELECT kam_user_to_group('1001', 'office');
SELECT kam_user_to_group('1002', 'office');
SELECT kam_trunk_to_group('provider-ip', 'office', 0);
