FROM alpine:3.4
MAINTAINER Matthieu Buffet <mtth.bfft@gmail.com>

RUN apk add --no-cache \
    openssl \
    openvpn \
    bash \
    git

EXPOSE 9090

HEALTHCHECK --timeout=2s --interval=2m \
    CMD echo status | nc localhost 8000 || exit 1

VOLUME ["/etc/openvpn/","/var/log/openvpn/"]

CMD /usr/bin/openvpn-run.sh
COPY openvpn-run.sh /usr/bin/

