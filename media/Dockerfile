FROM alpine:latest
LABEL maintainer="mailsvb <mailsvb@gmail.com>"

# Media server (asterisk): announcements and voicemail, only kamailio talks to it
# official prompts (core + extra) instead of Alpine's 8 kHz GSM set, one file per
# codec so that asterisk plays them without transcoding: G.722, A-law, µ-law,
# G.729 (pass-through only, no G.729 codec in Alpine) and sln16 (16 kHz linear,
# the source for opus calls: encoded only, there are no official opus prompts)
ARG SOUNDS_URL=https://downloads.asterisk.org/pub/telephony/sounds/releases
ARG CORE_SOUNDS=1.6.1
ARG EXTRA_SOUNDS=1.5.2
ARG SOUND_FORMATS="sln16 g722 alaw ulaw g729"
# srtp: SDES and DTLS-SRTP, opus: open source opus codec
RUN apk add --no-cache asterisk asterisk-pgsql asterisk-srtp asterisk-opus && \
    asterisk -V && \
    mkdir -p /usr/share/asterisk/sounds/en && \
    for fmt in $SOUND_FORMATS; do \
        for f in core-sounds-en-$fmt-$CORE_SOUNDS extra-sounds-en-$fmt-$EXTRA_SOUNDS; do \
            wget -qO- "$SOUNDS_URL/asterisk-$f.tar.gz" | tar -xz -C /usr/share/asterisk/sounds/en || exit 1; \
        done; \
        test -f /usr/share/asterisk/sounds/en/vm-password.$fmt || exit 1; \
    done && \
    test -f /usr/lib/asterisk/modules/res_srtp.so && \
    test -f /usr/lib/asterisk/modules/codec_opus_open_source.so && \
    mkdir -p /var/spool/asterisk/voicemail && \
    chown -R asterisk:asterisk /var/spool/asterisk /var/lib/asterisk /var/log/asterisk /var/run/asterisk

# configuration templates, rendered to /etc/asterisk on every start (entrypoint.sh)
COPY config/ /etc/asterisk-templates/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["asterisk", "-f", "-U", "asterisk", "-G", "asterisk"]
