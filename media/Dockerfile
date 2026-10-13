FROM alpine:latest
LABEL maintainer="mailsvb <mailsvb@gmail.com>"

# Media server (asterisk): announcements and voicemail, only kamailio talks to it
# official prompts (core + extra) in A-law and G.722 instead of Alpine's 8 kHz GSM set
ARG SOUNDS_URL=https://downloads.asterisk.org/pub/telephony/sounds/releases
ARG CORE_SOUNDS=1.6.1
ARG EXTRA_SOUNDS=1.5.2
RUN apk add --no-cache asterisk asterisk-pgsql && \
    asterisk -V && \
    mkdir -p /usr/share/asterisk/sounds/en && \
    for f in core-sounds-en-alaw-$CORE_SOUNDS core-sounds-en-g722-$CORE_SOUNDS \
             extra-sounds-en-alaw-$EXTRA_SOUNDS extra-sounds-en-g722-$EXTRA_SOUNDS; do \
        wget -qO- "$SOUNDS_URL/asterisk-$f.tar.gz" | tar -xz -C /usr/share/asterisk/sounds/en || exit 1; \
    done && \
    test -f /usr/share/asterisk/sounds/en/vm-password.alaw && \
    test -f /usr/share/asterisk/sounds/en/vm-password.g722 && \
    mkdir -p /var/spool/asterisk/voicemail && \
    chown -R asterisk:asterisk /var/spool/asterisk /var/lib/asterisk /var/log/asterisk /var/run/asterisk

# configuration templates, rendered to /etc/asterisk on every start (entrypoint.sh)
COPY config/ /etc/asterisk-templates/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["asterisk", "-f", "-U", "asterisk", "-G", "asterisk"]
