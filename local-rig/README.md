# Local smoke rig

Stand-alone mihomo container for exercising the protocol surface used by this
project (Hysteria2 inbound, `fallback` proxy-group, geo routing) on your laptop
before touching a VPS. Not a substitute for `just provision`.

## What's exercised

- Hysteria2 listener on UDP `:8443` (`users: {laptop: testpassword123}`).
- `fallback` proxy-group `GLOBAL` over `ss-dead` (`192.0.2.1` — RFC 5737
  TEST-NET-1, guaranteed unreachable) and `direct-out`. Confirms health-probe
  flips the active proxy to `direct-out` within one `interval`.
- REST API on `127.0.0.1:9090` for `/proxies/GLOBAL`, `/rules`, etc.

Corporate egress is a `socks5` outbound named `ovpn-corp` pointing at the
**openvpn-corp sidecar** (`sidecar/openvpn-corp/`). By default the sidecar is
disabled (compose `profiles: [corp]`), so `ovpn-corp` is declared but never
dialed — no corp creds needed to exercise the Hysteria2 + fallback surface.

To exercise the real corp tunnel, drop `corporate.conf` (the `.ovpn` with
inline `<ca>/<cert>/<key>`) and `corporate.auth` (two lines: user, pass) into
`local-rig/openvpn-corp/etc/`, then:

```bash
cd local-rig
docker compose --profile corp up -d --build
docker logs --tail 40 openvpn-corp-rig   # expect: "tun0 is up after Ns"
curl --socks5-hostname 127.0.0.1:1080 -s https://ifconfig.me   # exits via corp
```

The `local-rig/openvpn-corp/` dir is gitignored.

## First-time setup

The Hysteria2 listener references `cert/server.crt` + `server.key` that the rig
expects you to provide. Mint a throwaway self-signed cert:

```bash
mkdir -p local-rig/mihomo/cert
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -days 3650 -nodes \
  -subj "/CN=tristate.local" \
  -keyout local-rig/mihomo/cert/server.key \
  -out   local-rig/mihomo/cert/server.crt
```

The `cert/` dir is gitignored.

## Run

```bash
cd local-rig
docker compose up -d
docker logs --tail 30 mihomo-rig
```

Expected log line: `Hysteria2 server listening at 0.0.0.0:8443`.

## Verify

```bash
# Container is up and REST API answers
curl -s http://127.0.0.1:9090/version

# After one health interval (~30s), GLOBAL flips to direct-out
sleep 35
curl -s http://127.0.0.1:9090/proxies/GLOBAL | python3 -m json.tool

# HTTP traffic through the proxy gets out via direct-out
curl -x http://127.0.0.1:7890 -s https://api.ipify.org
```

## Tear down

```bash
docker compose down
```

## Reset

```bash
docker compose down
rm -rf local-rig/mihomo/cert local-rig/mihomo/*.db local-rig/mihomo/geo*.dat
```
