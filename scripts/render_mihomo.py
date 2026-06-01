#!/usr/bin/env python3
"""Render the mihomo server config from node.json + clients.json + corp routes/domains.

Output is JSON. mihomo accepts JSON in `.yaml` config files because JSON is a strict
subset of YAML 1.2 and mihomo's parser (go-yaml v3) handles both.
"""
from __future__ import annotations
import argparse, ipaddress, json, socket
from string import Template


RU_GEOSITES = [
    "2gis", "category-bank-ru", "category-betting-ru", "category-ecommerce-ru",
    "category-entertainment-ru", "category-gov-ru", "category-media-ru",
    "category-medicine-ru", "category-retail-ru", "category-travel-ru",
    "kinopoisk", "mailru", "mailru-group", "myoffice-ru", "ok",
    "category-ru", "sber", "vk", "yandex",
]

RU_DOMAINS = [
    "alfabank.ru", "avito.ru", "beeline.ru", "cdek.ru", "detmir.ru",
    "dns-shop.ru", "eldorado.ru", "gazprombank.ru", "gosuslugi.ru", "hh.ru",
    "ivi.ru", "lamoda.ru", "megafon.ru", "mts.ru", "more.tv", "mvideo.ru",
    "okko.tv", "ozon.ru", "pochta.ru", "qiwi.com", "raiffeisen.ru",
    "rostelecom.ru", "rutube.ru", "samokat.ru", "superjob.ru", "tbank.ru",
    "tele2.ru", "tinkoff.ru", "vtb.ru", "wildberries.ru",
]


def load_routes(path):
    """Parse corporate route list. Accepts three line forms:
        route <ipv4> <netmask>      (OpenVPN-style)
        route <ipv4|ipv6>/<prefix>  (CIDR; v4 or v6)
        <ipv4|ipv6>/<prefix>        (bare CIDR; v4 or v6)
    Comments (#) and blank lines ignored. Unknown forms raise loudly so the
    operator notices typos instead of getting silent drops.
    """
    cidrs = []
    if not path:
        return cidrs
    with open(path) as fh:
        for lineno, raw in enumerate(fh, 1):
            s = raw.strip()
            if not s or s.startswith("#"):
                continue
            if s.startswith("route "):
                parts = s.split()
                if len(parts) == 3:
                    _, addr, mask = parts
                    if "/" in addr or ":" in addr:
                        raise SystemExit(
                            f"{path}:{lineno}: 'route <addr> <mask>' form is "
                            f"IPv4-only; use 'route <cidr>' or a bare CIDR for "
                            f"IPv6"
                        )
                    net = ipaddress.IPv4Network(f"{addr}/{mask}", strict=False)
                elif len(parts) == 2:
                    net = ipaddress.ip_network(parts[1], strict=False)
                else:
                    raise SystemExit(
                        f"{path}:{lineno}: unrecognized route form: {s!r}"
                    )
            elif "/" in s:
                net = ipaddress.ip_network(s, strict=False)
            else:
                raise SystemExit(
                    f"{path}:{lineno}: expected 'route ...' or a CIDR, got {s!r}"
                )
            cidrs.append(str(net))
    return cidrs


def load_domains(path):
    domains = []
    if not path:
        return domains
    with open(path) as fh:
        for line in fh:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            domains.append(s)
    return domains


def resolve_to_cidrs(host):
    """Resolve a host (literal IP or DNS name) to a set of /32 or /128 CIDRs.
    Raises RuntimeError on DNS failure — gaps in the loop-guard would let SS
    outbound traffic re-enter the proxy.
    """
    out = set()
    if not host:
        return out
    try:
        ipaddress.ip_address(host)
        out.add(f"{host}/32" if ":" not in host else f"{host}/128")
        return out
    except ValueError:
        pass
    try:
        for info in socket.getaddrinfo(host, None):
            ip = info[4][0]
            try:
                addr = ipaddress.ip_address(ip)
                out.add(f"{ip}/128" if addr.version == 6 else f"{ip}/32")
            except ValueError:
                continue
    except OSError as exc:
        raise RuntimeError(
            f"failed to resolve host {host!r} for loop-guard: {exc}. "
            f"Run with DNS available, or use an IP literal."
        ) from exc
    return out


def build_loop_guard(node):
    guard = set()
    for ep in node["outline"]:
        guard |= resolve_to_cidrs(ep.get("address"))
    guard |= resolve_to_cidrs(node.get("host"))
    if not guard:
        # No real addresses to guard. Emit a single /32 inside the reserved
        # 240.0.0.0/4 block (RFC 1112 "future use" — never routable) so the
        # rules array stays non-empty and the loop-guard ordering invariant
        # in build_rules() still holds.
        guard.add("240.0.0.0/32")
    return sorted(guard)


def build_proxies(node):
    names = [ep["name"] for ep in node["outline"]]
    if len(set(names)) != len(names):
        dups = sorted({n for n in names if names.count(n) > 1})
        raise ValueError(f"duplicate outline endpoint names: {dups}")
    proxies = []
    for ep in node["outline"]:
        proxies.append({
            "name":     f"ss-{ep['name']}",
            "type":     "ss",
            "server":   ep["address"],
            "port":     ep["port"],
            "cipher":   ep["method"],
            "password": ep["password"],
            "udp":      True,
        })
    proxies.append({"name": "direct-out", "type": "direct"})
    # Corporate egress is provided by the openvpn-corp sidecar container, which
    # dials the corp gateway (BF-CBC / no tls-crypt — handled by a real openvpn
    # binary) and exposes a loopback SOCKS5 proxy. mihomo never speaks OpenVPN;
    # it routes corp-destined traffic to this SOCKS5 outbound. See
    # sidecar/openvpn-corp/. The sidecar publishes 127.0.0.1:<port> on the host
    # and mihomo runs with network_mode: host, so the address is loopback.
    corp = node.get("corp_socks", {})
    proxies.append({
        "name":   "ovpn-corp",
        "type":   "socks5",
        "server": corp.get("host", "127.0.0.1"),
        "port":   corp.get("port", 1080),
        # dante is TCP-only (CONNECT). UDP-associate is intentionally not used.
        "udp":    False,
    })
    return proxies


# corporate_domains.txt uses Xray routing syntax; translate each entry to the
# equivalent mihomo rule type. A bare entry (no prefix) is treated as a suffix
# match for backward compatibility.
def domain_rule(entry, target):
    prefix_map = {
        "domain":  "DOMAIN-SUFFIX",
        "full":    "DOMAIN",
        "keyword": "DOMAIN-KEYWORD",
        "regexp":  "DOMAIN-REGEX",
    }
    if ":" in entry:
        kind, _, value = entry.partition(":")
        rule = prefix_map.get(kind)
        if rule:
            return f"{rule},{value},{target}"
    return f"DOMAIN-SUFFIX,{entry},{target}"


def build_rules(loop_guard, routes, corp_domains):
    rules = []
    for cidr in loop_guard:
        rules.append(f"IP-CIDR,{cidr},direct-out,no-resolve")
    for d in corp_domains:
        rules.append(domain_rule(d, "ovpn-corp"))
    for cidr in routes:
        rules.append(f"IP-CIDR,{cidr},ovpn-corp,no-resolve")
    for site in RU_GEOSITES:
        rules.append(f"GEOSITE,{site},direct-out")
    for d in RU_DOMAINS:
        rules.append(f"DOMAIN-SUFFIX,{d},direct-out")
    rules.append("GEOIP,RU,direct-out,no-resolve")
    rules.append("MATCH,GLOBAL")
    return rules


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--template", required=True)
    parser.add_argument("--node",     required=True)
    parser.add_argument("--clients",  required=True)
    parser.add_argument("--routes",   default="")
    parser.add_argument("--corp-domains", default="")
    parser.add_argument("--output",   required=True)
    args = parser.parse_args()

    with open(args.node) as fh:
        node = json.load(fh)
    with open(args.clients) as fh:
        clients = json.load(fh)
    routes  = load_routes(args.routes)
    corp_domains = load_domains(args.corp_domains)
    loop_guard = build_loop_guard(node)

    emails = [c["email"] for c in clients]
    if len(set(emails)) != len(emails):
        dups = sorted({e for e in emails if emails.count(e) > 1})
        raise ValueError(f"duplicate client emails: {dups}")
    hy2_users = {c["email"]: c["password"] for c in clients}
    proxies   = build_proxies(node)
    global_proxies = [proxy["name"] for proxy in proxies if proxy["name"].startswith("ss-")] + ["direct-out"]
    rules     = build_rules(loop_guard, routes, corp_domains)

    with open(args.template) as fh:
        tmpl = Template(fh.read())
    rendered = tmpl.substitute(
        LISTEN_PORT=node["listen_port"],
        HY2_USERS=json.dumps(hy2_users),
        PROXIES=json.dumps(proxies),
        GLOBAL_PROXIES=json.dumps(global_proxies),
        RULES=json.dumps(rules),
    )

    # Round-trip through json to canonicalize (catches malformed substitution early).
    obj = json.loads(rendered)
    with open(args.output, "w") as fh:
        json.dump(obj, fh, indent=2, sort_keys=False, ensure_ascii=False)
        fh.write("\n")


if __name__ == "__main__":
    main()
