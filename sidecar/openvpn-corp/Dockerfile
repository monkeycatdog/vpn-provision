# openvpn-corp sidecar: dials the corporate OpenVPN gateway and exposes a
# loopback-only SOCKS5 proxy (dante) whose egress is the OpenVPN tun device.
# mihomo routes corp-destined traffic to this proxy; only this container ever
# holds the corporate tunnel, so the VPS host and other containers cannot reach
# corp resources directly.
FROM alpine:3.21

# openvpn  - the actual VPN client (handles BF-CBC / no-tls-crypt natively)
# dante-server - SOCKS5 proxy (sockd)
# openssl  - provides the legacy provider needed for Blowfish (BF-CBC)
# iproute2 - `ip` for tun-readiness checks
# bash/curl - entrypoint + health probing
RUN apk add --no-cache openvpn dante-server openssl iproute2 bash curl

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 1080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
