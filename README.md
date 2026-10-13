# sip-server

[![build](https://github.com/mailsvb/kamailio-docker/actions/workflows/build.yml/badge.svg)](https://github.com/mailsvb/kamailio-docker/actions/workflows/build.yml)

SIP server based on Kamailio with PostgreSQL provisioning, rtpengine media relay, an echo test service and a web admin UI. All images are built from this repository with `docker compose`.

| Service / container | Image | Directory | Description |
|---|---|---|---|
| `kamailio` | `sip-server/kamailio` | `kamailio/` | Kamailio 6.1.4 built from source, configuration in `kamailio/config/` |
| `rtpengine` | `sip-server/rtpengine` | `rtpengine/` | rtpengine (sipwise) built from source, relays RTP of trunk calls |
| `postgres` | `sip-server/postgres` | `postgres/` | PostgreSQL 17 with the schema in `postgres/init/` |
| `admin` | `sip-server/admin` | `admin/` | web UI for the database and kamailio RPC |
| `echo` | `sip-server/echo` | `echo/` | sipp echo test, reached by dialling `*43` |

Persistent data lives in named docker volumes only: `sip-server_pgdata` (database) and `sip-server_kamailio-run` (RPC sockets shared by kamailio and admin). Configuration and SQL scripts are baked into the images, there are no bind mounts.

## Requirements
*  docker
*  docker compose v2

## Usage
###### build all images
`docker compose build`

Versions can be overridden with build args, e.g. `docker compose build --build-arg KAMAILIO_VERSION=6.1.4 kamailio` or `--build-arg RTPENGINE_VERSION=mr26.2.1.3 rtpengine`.

###### start
`docker compose up -d`

###### apply changes of `kamailio/config/` (or any other image)
`docker compose up -d --build kamailio`

###### stop / start
`docker compose stop` / `docker compose start`

###### remove all containers and images (`-v` also deletes the database volume)
`docker compose down --rmi all`

###### use published images instead of building
Set `IMAGE_PREFIX=ghcr.io/<owner>` (and optionally `IMAGE_TAG`) in `.env`, then `docker compose pull && docker compose up -d`.

## CI
* `build` (push to main, pull requests): builds all five images and runs a smoke test for each (kamailio config check, `rtpengine --version`, ...), validates `docker-compose.yml`.
* `publish` (manual, *Actions → publish → Run workflow*): builds all images and pushes them to the GitHub Container Registry as `ghcr.io/<repository owner>/<image>` with tags `latest`, `sha-<commit>` and, for kamailio and rtpengine, the version from the Dockerfile (e.g. `6.1.4`, `mr26.2.1.3`). Uses the built-in `GITHUB_TOKEN`, no secrets needed. New packages are private by default, change their visibility in the package settings.

## Environment variables
* `PUBLIC_IP=1.2.3.4` required, LAN address of the host for phones (SIP and SDP of internal legs, rtpengine interface `lan`)
* `EXTERNAL_IP` default=`PUBLIC_IP`, public address written into the SDP towards trunks (rtpengine interface `wan`). Set it when the host is behind NAT and forward UDP 49000-49999 (rtpengine) to the host.
* `DB_PASSWORD` required, password of the PostgreSQL user `kamailio` (keep it URL safe, it is part of `DBURL`)
* `SIP_REALM` default=kamailio, digest realm for user authentication. It is copied into table `settings` when the database is created.
* `ADMIN_LISTEN` default=0.0.0.0:8080, address of the admin web UI

Copy `.env.example` to `.env` next to `docker-compose.yml` and adjust it.

## Media relay (rtpengine)
Internal calls use direct media between the phones. Trunk calls are relayed by rtpengine (userspace forwarding, RTP ports 49000-49999), controlled by kamailio over the ng protocol on `127.0.0.1:22222`. It has two logical interfaces on `PUBLIC_IP`:
* `lan`: advertises `PUBLIC_IP`, used towards phones and LAN trunks
* `wan`: advertises `EXTERNAL_IP`, used towards trunks on the internet

Active calls: `docker compose exec kamailio kamcmd rtpengine.show all`

## Users, groups and trunks
Users and trunks live in a PostgreSQL database (service `postgres`). The schema in `postgres/init/` is loaded when the data volume is created for the first time. Updates for existing databases are in `postgres/migrations/`, apply them with e.g.

`docker compose exec -T postgres psql -U kamailio kamailio < postgres/migrations/008-device-type.sql`

* Only users in table `subscriber` can register or place calls (digest authentication, plain text `password`).
* Parallel registrations per user: `settings.max_contacts` (default 1), overridden per user by `subscriber.max_contacts` (NULL = global value). Read on every REGISTER, no reload needed.
  * `1`: the last registration wins, older devices of the user are removed and no longer receive calls
  * `N > 1`: up to N devices stay registered and all of them ring in parallel; a new device beyond N replaces the oldest registration
* Device type: a registration whose User-Agent contains `Desk_Phone_IP` is a `Unify` phone, all others are `Generic`. The type is kept per registered device and recorded in `subscriber.device_type` (type of the last registration).
  * Call messages sent to a Unify phone (INVITE, 180, 183, 200, re-INVITE, UPDATE, ACK, BYE, ...) get `X-Siemens-Call-Type: ST-secure` when the SDP carries secure media (SDES `a=crypto`, DTLS `a=fingerprint`, ZRTP `a=zrtp-hash`, MIKEY, `RTP/SAVP(F)`), otherwise `ST-insecure`. An existing `X-Siemens-Call-Type` header is left unchanged.
* Every user gets a dedicated trunk for outgoing calls (`subscriber.trunk_id`, set with `kam_user_trunk`).
* Optional fallback for users without a dedicated trunk: users belong to groups (`user_group`), trunks are assigned to groups (`group_trunk`, lowest `priority` wins).
* Dialled numbers are handled in this order:
  1. feature codes starting with `*` or `#`, never sent to a trunk:
     * `*43` echo test (service `echo`, sipp answering on 127.0.0.1:5090 and echoing RTP on `PUBLIC_IP`:48000)
     * all others are answered with 404
  2. internal numbers: the extension (`username`) or the `number` of a local user
  3. everything else leaves through the caller's trunk
* Media: internal calls use direct media between the phones, trunk calls are relayed by rtpengine
* Trunk calls:
  * From = trunk account (`from_user`, falls back to `auth_username`)
  * P-Asserted-Identity = number of the user
  * number normalization: strip `strip` leading digits, then prepend `prefix`
* Trunk types:
  * registration + digest: `register = true` with `auth_username` / `auth_password`
  * digest on INVITE only: `register = false` with `auth_username` / `auth_password`
  * IP based: no credentials, set `from_user` for the caller ID
* Trunk options: `send_pai` (send P-Asserted-Identity, default true), `lan` (trunk is on the LAN: kamailio uses its LAN address `PUBLIC_IP` instead of `EXTERNAL_IP` in Contact, Record-Route, SDP and registration)

Open a database shell:

`docker compose exec postgres psql -U kamailio kamailio`

```sql
-- user with SIP username, phone number and password
SELECT kam_add_user('1001', '+4930111111', 'secret');

-- trunk
INSERT INTO trunk (name, domain, proxy, auth_username, auth_password, register, strip, prefix)
VALUES ('provider', 'sip.provider.example', NULL, '4930111111', 'trunk-secret', true, 1, '+49');

-- dedicated trunk of the user
SELECT kam_user_trunk('1001', 'provider');

-- optional: allow 3 parallel registrations for this user (all devices ring)
UPDATE subscriber SET max_contacts = 3 WHERE username = '1001';

-- optional group fallback
SELECT kam_user_to_group('1001', 'office');
SELECT kam_trunk_to_group('provider', 'office', 0);
```

### Incoming calls
Incoming calls of a trunk ring all registered members of its inbound group in parallel.

* An INVITE without credentials is accepted as trunk call when its source address is in `trunk.inbound_src` (list of networks). Everything else must authenticate as a user.
* If several trunks match, the one whose `auth_username` equals the called user wins (registered trunks call `sip:<auth_username>@kamailio`).
* All members of `trunk.inbound_group_id` ring for `trunk.ring_timeout` seconds (default 60). Nobody answers or nobody registered: `480 Temporarily Unavailable` to the trunk.

```sql
-- ring group 'office' for calls from the trunk, accepted from 192.168.0.1 only
SELECT kam_trunk_inbound('provider', 'office', '{192.168.0.1/32}');
SELECT kam_user_to_group('1001', 'office');
SELECT kam_user_to_group('1002', 'office');
-- optional: ring time in seconds
UPDATE trunk SET ring_timeout = 30 WHERE name = 'provider';
```

For trunks on the internet use the provider networks as `inbound_src` (e.g. 1&1: `'{212.227.0.0/16,82.144.32.0/19}'`) and restrict the UDP 5060 port forwarding to them as well.

See `postgres/examples/example-data.sql` for all trunk types. After changing trunks with `register = true`, reload the registrations:

`docker compose exec kamailio kamcmd uac.reg_reload`

`docker compose exec kamailio kamcmd uac.reg_dump` shows their state.

## Admin web UI
Service `admin` (Go, `admin/`) serves a web UI on `http://<host>:8080` (`ADMIN_LISTEN`):
* spreadsheet-like editor for all tables of the database: edit cells in place, add/delete rows, booleans as checkbox, foreign keys as dropdown. Changes are highlighted and written in one transaction on **Save** (Ctrl+S), a failing constraint writes nothing.
* **Reload registrations** (`uac.reg_reload`), **Restart kamailio** and an RPC console (e.g. `uac.reg_dump`, `ul.dump`)

It talks to kamailio through the jsonrpcs socket in the shared volume `kamailio-run`. Restart terminates kamailio via RPC (`core.kill`), the restart policy of the container starts it again. Optionally mount `/var/run/docker.sock` into `admin` (see `docker-compose.yml`) to restart through the docker API and show the container state; this gives the admin container root access to the host.

**There is no authentication.** Only expose it in a trusted network, e.g. `ADMIN_LISTEN=192.168.21.12:8080` or `127.0.0.1:8080`.
