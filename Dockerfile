FROM alpine:3.4
MAINTAINER Matthieu Buffet <mtth.bfft@gmail.com>

RUN apk add --no-cache \
    openssl \
    openvpn \
    bash \
    git

EXPOSE 9090

VOLUME ["/etc/openvpn/"]
ADD openvpn-run.sh /usr/bin/
CMD /usr/bin/openvpn-run.sh

