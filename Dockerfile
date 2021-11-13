FROM alpine:latest

RUN apk update && apk upgrade && \
    apk add --no-cache bison git openssl-dev flex make gcc g++ musl-dev libunistring-dev lksctp-tools-dev linux-headers && \
    git -C /tmp/ clone --depth 1 --branch 5.5.2 https://github.com/kamailio/kamailio && \
    make -C /tmp/kamailio PREFIX="/usr" include_modules="tls websocket sctp" cfg && \
    make -C /tmp/kamailio -i -s all &&\
    make -C /tmp/kamailio -i -s install && \
    apk del --no-cache git make gcc g++
