#!/bin/sh
# Render the asterisk configuration: @PUBLIC_IP@, @DB_HOST@, @DB_PORT@ and
# @DB_PASSWORD@ in /etc/asterisk-templates are replaced by the environment.
set -e

: "${PUBLIC_IP:?PUBLIC_IP is not set}"
: "${DB_PASSWORD:?DB_PASSWORD is not set}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"

# escape for the replacement part of sed (delimiter |)
esc() { printf '%s' "$1" | sed 's/[\\|&]/\\&/g'; }

mkdir -p /etc/asterisk
for f in /etc/asterisk-templates/*.conf; do
    sed -e "s|@PUBLIC_IP@|$(esc "$PUBLIC_IP")|g" \
        -e "s|@DB_HOST@|$(esc "$DB_HOST")|g" \
        -e "s|@DB_PORT@|$(esc "$DB_PORT")|g" \
        -e "s|@DB_PASSWORD@|$(esc "$DB_PASSWORD")|g" \
        "$f" > "/etc/asterisk/$(basename "$f")"
done
chown -R root:asterisk /etc/asterisk
chmod 750 /etc/asterisk
chmod 640 /etc/asterisk/*.conf

exec "$@"
