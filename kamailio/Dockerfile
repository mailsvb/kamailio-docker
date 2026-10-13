FROM alpine:latest
LABEL maintainer="mailsvb <mailsvb@gmail.com>"

ARG KAMAILIO_VERSION=6.1.4
RUN apk update && apk upgrade && \
    apk add --no-cache bison git openssl-dev flex make gcc g++ musl-dev libunistring-dev lksctp-tools-dev linux-headers libpq-dev cargo && \
    git -C /tmp clone --depth 1 https://github.com/miconda/ruxc && \
    git -C /tmp clone --depth 1 --branch $KAMAILIO_VERSION https://github.com/kamailio/kamailio && \
    cargo build --release --manifest-path=/tmp/ruxc/Cargo.toml && \
    cp /tmp/ruxc/include/ruxc.h /tmp/ruxc/target/release/libruxc.a /tmp/kamailio/src/modules/ruxc/ && \
    make -C /tmp/kamailio PREFIX="/usr" include_modules="tls websocket sctp ruxc db_postgres" cfg && \
    make -C /tmp/kamailio -j$(nproc) all && \
    make -C /tmp/kamailio install && \
    apk del --no-cache git make gcc g++ cargo libpq-dev && \
    apk add --no-cache libgcc libpq && \
    rm -rf /tmp/kamailio /tmp/ruxc /root/.cargo && \
    test -f /usr/lib64/kamailio/modules/db_postgres.so && \
    test -f /usr/lib64/kamailio/modules/rtpengine.so && \
    kamailio -v

# configuration (kamailio.cfg, TLS certificate), separate layer: changes do not rebuild kamailio
COPY config/ /usr/etc/kamailio/

CMD ["/usr/sbin/kamailio", "-DD"]
