FROM alpine:latest

RUN apk update && apk upgrade
RUN apk add --no-cache bison git openssl-dev flex make gcc g++ musl-dev libunistring-dev lksctp-tools-dev linux-headers

RUN git -C /tmp/ clone --depth 1 https://github.com/kamailio/kamailio

RUN make -C /tmp/kamailio PREFIX="/usr" include_modules="tls websocket sctp" cfg
RUN make -C /tmp/kamailio -i -s all
RUN make -C /tmp/kamailio -i -s install

RUN apk del --no-cache git make gcc g++
