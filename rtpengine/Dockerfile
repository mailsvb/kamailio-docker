FROM alpine:latest AS build

ARG RTPENGINE_VERSION=mr26.2.1.3
RUN apk add --no-cache bash git make gcc musl-dev linux-headers pkgconf gperf perl pandoc-cli \
        glib-dev json-glib-dev libevent-dev openssl-dev pcre2-dev zlib-dev curl-dev \
        libpcap-dev hiredis-dev libwebsockets-dev xmlrpc-c-dev libjwt-dev ncurses-dev liburing-dev \
        iptables-dev libmnl-dev libnftnl-dev \
        ffmpeg-dev spandsp-dev opus-dev mariadb-connector-c-dev && \
    git -C /tmp clone --depth 1 --branch $RTPENGINE_VERSION https://github.com/sipwise/rtpengine
RUN RTPENGINE_VERSION=$RTPENGINE_VERSION make -C /tmp/rtpengine/daemon -j$(nproc) rtpengine && \
    install -Dm755 /tmp/rtpengine/daemon/rtpengine /out/usr/bin/rtpengine && \
    # shared libraries needed at runtime, installed as so: packages in the final stage
    scanelf --needed --nobanner --format '%n#p' /out/usr/bin/rtpengine | tr ',' '\n' | sed 's/^/so:/' | sort -u > /out/runtime-deps

FROM alpine:latest
LABEL maintainer="mailsvb <mailsvb@gmail.com>"

COPY --from=build /out/ /
RUN apk add --no-cache $(cat /runtime-deps) && \
    rm /runtime-deps && \
    addgroup -S rtpengine && adduser -S -D -H -G rtpengine rtpengine && \
    rtpengine --version

USER rtpengine
# userspace forwarding only (no kernel module), interfaces are set in docker-compose.yml
CMD ["rtpengine", "--foreground", "--log-stderr", "--table=-1", "--listen-ng=127.0.0.1:22222"]
