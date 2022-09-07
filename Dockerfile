FROM alpine:latest
MAINTAINER mailsvb <mailsvb@gmail.com>

RUN apk update && apk upgrade && \
    apk add --no-cache bison git openssl-dev flex make gcc g++ musl-dev libunistring-dev lksctp-tools-dev linux-headers cargo && \
    git -C /tmp clone --depth 1 --branch 5.6.1 https://github.com/kamailio/kamailio && \
    cargo build --release --manifest-path=/tmp/ruxc/Cargo.toml && \
    cp /tmp/ruxc/include/ruxc.h /tmp/ruxc/target/release/libruxc.a /tmp/kamailio/src/modules/ruxc/ && \
    make -C /tmp/kamailio PREFIX="/usr" include_modules="tls websocket sctp ruxc" cfg && \
    make -C /tmp/kamailio -i -s all &&\
    make -C /tmp/kamailio -i -s install && \
    apk del --no-cache git make gcc g++ cargo
