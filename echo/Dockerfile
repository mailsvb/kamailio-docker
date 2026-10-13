FROM alpine:latest
LABEL maintainer="mailsvb <mailsvb@gmail.com>"

# SIP echo test service: answers calls and echoes RTP back to the sender
RUN apk add --no-cache sipp && sipp -v | head -2
COPY echo.xml /etc/sipp/echo.xml
