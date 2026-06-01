import json, pathlib, subprocess, pytest

FIXTURES = pathlib.Path(__file__).parent / "fixtures"
RENDER   = pathlib.Path(__file__).parent.parent / "render_mihomo.py"

def render(tmp_path, corp_socks=None):
    node_path = FIXTURES / "node.mihomo.json"
    if corp_socks is not None:
        node = json.loads(node_path.read_text())
        node["corp_socks"] = corp_socks
        node_path = tmp_path / "node.json"
        node_path.write_text(json.dumps(node))
    out = tmp_path / "rendered.yaml"
    subprocess.run(
        ["python3", str(RENDER),
         "--template", "config/mihomo_config.template.yaml",
         "--node",     str(node_path),
         "--clients",  str(FIXTURES / "clients.mihomo.json"),
         "--routes",   str(FIXTURES / "ips.txt"),
         "--corp-domains", str(FIXTURES / "corporate_domains.txt"),
         "--output",   str(out)],
        check=True,
        cwd=pathlib.Path(__file__).parent.parent.parent,
    )
    return json.loads(out.read_text())

def test_hysteria2_listener_has_all_users(tmp_path):
    cfg = render(tmp_path)
    listener = next(l for l in cfg["listeners"] if l["type"] == "hysteria2")
    assert listener["port"] == 443
    assert listener["users"] == {
        "laptop": "firstSecret123",
        "phone":  "secondSecret456",
    }

def test_two_outline_proxies_emitted(tmp_path):
    cfg = render(tmp_path)
    ss_proxies = [p for p in cfg["proxies"] if p["type"] == "ss"]
    assert sorted(p["name"] for p in ss_proxies) == ["ss-freedom-eu1", "ss-freedom-eu2"]
    assert {p["server"] for p in ss_proxies} == {"95.164.22.5", "95.164.22.6"}

def test_fallback_group_includes_all_outlines_and_direct(tmp_path):
    cfg = render(tmp_path)
    grp = next(g for g in cfg["proxy-groups"] if g["name"] == "GLOBAL")
    assert grp["type"] == "fallback"
    assert grp["proxies"] == ["ss-freedom-eu1", "ss-freedom-eu2", "direct-out"]
    assert grp["url"].startswith("http")
    assert grp["interval"] >= 30

def test_corp_proxy_is_socks5_to_sidecar(tmp_path):
    # Corp egress is the openvpn-corp sidecar's loopback SOCKS5 proxy; mihomo
    # never speaks OpenVPN itself.
    cfg = render(tmp_path)
    ovpn = next(p for p in cfg["proxies"] if p["name"] == "ovpn-corp")
    assert ovpn["type"] == "socks5"
    assert ovpn["server"] == "127.0.0.1"
    assert ovpn["port"] == 1080
    assert ovpn["udp"] is False
    # No corp credentials leak into the mihomo config.
    assert "openvpn" not in {p["type"] for p in cfg["proxies"]}

def test_corp_socks_honours_node_override(tmp_path):
    cfg = render(tmp_path, corp_socks={"host": "10.9.9.9", "port": 1081})
    ovpn = next(p for p in cfg["proxies"] if p["name"] == "ovpn-corp")
    assert ovpn["server"] == "10.9.9.9"
    assert ovpn["port"] == 1081

def test_routing_corp_ip_goes_to_openvpn(tmp_path):
    cfg = render(tmp_path)
    rules = cfg["rules"]
    assert any(r == "IP-CIDR,10.20.0.0/16,ovpn-corp,no-resolve" for r in rules)
    assert any(r == "IP-CIDR,172.16.5.0/24,ovpn-corp,no-resolve" for r in rules)

def test_routing_corp_domain_goes_to_openvpn(tmp_path):
    cfg = render(tmp_path)
    rules = cfg["rules"]
    assert "DOMAIN-SUFFIX,corp.example.com,ovpn-corp" in rules
    assert "DOMAIN-SUFFIX,jira.corp.example.com,ovpn-corp" in rules

def test_routing_ru_geoip_goes_direct(tmp_path):
    cfg = render(tmp_path)
    rules = cfg["rules"]
    assert "GEOIP,RU,direct-out,no-resolve" in rules

def test_routing_default_goes_to_global_fallback(tmp_path):
    cfg = render(tmp_path)
    rules = cfg["rules"]
    assert rules[-1] == "MATCH,GLOBAL"

def test_ru_geosites_complete(tmp_path):
    cfg = render(tmp_path)
    rules = set(cfg["rules"])
    for site in [
        "2gis", "category-bank-ru", "category-betting-ru",
        "category-ecommerce-ru", "category-entertainment-ru",
        "category-gov-ru", "category-media-ru", "category-medicine-ru",
        "category-retail-ru", "category-travel-ru", "kinopoisk",
        "mailru", "mailru-group", "myoffice-ru", "ok", "category-ru",
        "sber", "vk", "yandex",
    ]:
        assert f"GEOSITE,{site},direct-out" in rules, f"missing {site}"

def test_ru_explicit_domains_complete(tmp_path):
    cfg = render(tmp_path)
    rules = set(cfg["rules"])
    for d in [
        "alfabank.ru", "avito.ru", "beeline.ru", "cdek.ru", "detmir.ru",
        "dns-shop.ru", "eldorado.ru", "gazprombank.ru", "gosuslugi.ru",
        "hh.ru", "ivi.ru", "lamoda.ru", "megafon.ru", "mts.ru", "more.tv",
        "mvideo.ru", "okko.tv", "ozon.ru", "pochta.ru", "qiwi.com",
        "raiffeisen.ru", "rostelecom.ru", "rutube.ru", "samokat.ru",
        "superjob.ru", "tbank.ru", "tele2.ru", "tinkoff.ru", "vtb.ru",
        "wildberries.ru",
    ]:
        assert f"DOMAIN-SUFFIX,{d},direct-out" in rules, f"missing {d}"

def test_loop_guard_first_and_covers_outline_endpoints(tmp_path):
    cfg = render(tmp_path)
    rules = cfg["rules"]
    assert "IP-CIDR,95.164.22.5/32,direct-out,no-resolve" in rules
    assert "IP-CIDR,95.164.22.6/32,direct-out,no-resolve" in rules
    assert "IP-CIDR,203.0.113.10/32,direct-out,no-resolve" in rules
    # Order spec: loop-guard → corp-domain → corp-ip → RU-geosite →
    # RU-domain → RU-geoip → MATCH. Locate the first index of each rule kind
    # by exact-shape predicate so corp-domain vs corp-ip can be told apart
    # (both contain the substring "ovpn-corp").
    first_guard       = next(i for i, r in enumerate(rules) if "95.164.22.5/32" in r)
    first_corp_dom    = next(i for i, r in enumerate(rules) if r.startswith("DOMAIN-SUFFIX,") and r.endswith(",ovpn-corp"))
    first_corp_ip     = next(i for i, r in enumerate(rules) if r.startswith("IP-CIDR,")       and r.endswith(",ovpn-corp,no-resolve"))
    first_ru_geosite  = next(i for i, r in enumerate(rules) if r.startswith("GEOSITE,")       and r.endswith(",direct-out"))
    first_ru_domain   = next(i for i, r in enumerate(rules) if r.startswith("DOMAIN-SUFFIX,") and r.endswith(",direct-out"))
    first_ru_geoip    = next(i for i, r in enumerate(rules) if r == "GEOIP,RU,direct-out,no-resolve")
    first_match       = next(i for i, r in enumerate(rules) if r == "MATCH,GLOBAL")
    assert first_guard < first_corp_dom < first_corp_ip < first_ru_geosite < first_ru_domain < first_ru_geoip < first_match

def test_dns_fake_ip_enabled(tmp_path):
    cfg = render(tmp_path)
    dns = cfg["dns"]
    assert dns["enable"] is True
    assert dns["enhanced-mode"] == "fake-ip"
    assert dns["fake-ip-range"].startswith("198.18.")

def test_duplicate_outline_names_rejected(tmp_path):
    """Two outline endpoints with the same name → renderer must error."""
    bad_node = tmp_path / "bad-node.json"
    bad_node.write_text(json.dumps({
        "host": "203.0.113.10",
        "ssh_user": "ubuntu", "ssh_port": 22, "install_dir": "/opt/x",
        "listen_port": 443,
        "hysteria2": {"cert_pem":"x","key_pem":"y","cert_fingerprint_sha256":"AA"},
        "outline": [
            {"name":"dup","address":"95.164.22.5","port":18066,
             "method":"chacha20-ietf-poly1305","password":"a"},
            {"name":"dup","address":"95.164.22.6","port":18066,
             "method":"chacha20-ietf-poly1305","password":"b"},
        ],
        "openvpn_corp": {"server":"x","port":1194,"proto":"udp","ca_pem":"x"},
    }))
    out = tmp_path / "out.yaml"
    result = subprocess.run(
        ["python3", str(RENDER),
         "--template", "config/mihomo_config.template.yaml",
         "--node",     str(bad_node),
         "--clients",  str(FIXTURES / "clients.mihomo.json"),
         "--routes",   str(FIXTURES / "ips.txt"),
         "--corp-domains", str(FIXTURES / "corporate_domains.txt"),
         "--output",   str(out)],
        capture_output=True, text=True,
        cwd=pathlib.Path(__file__).parent.parent.parent,
    )
    assert result.returncode != 0
    assert "duplicate outline endpoint names" in result.stderr

def test_duplicate_client_emails_rejected(tmp_path):
    """Two clients with the same email → renderer must error."""
    bad_clients = tmp_path / "bad-clients.json"
    bad_clients.write_text(json.dumps([
        {"email":"laptop","password":"a"},
        {"email":"laptop","password":"b"},
    ]))
    out = tmp_path / "out.yaml"
    result = subprocess.run(
        ["python3", str(RENDER),
         "--template", "config/mihomo_config.template.yaml",
         "--node",     str(FIXTURES / "node.mihomo.json"),
         "--clients",  str(bad_clients),
         "--routes",   str(FIXTURES / "ips.txt"),
         "--corp-domains", str(FIXTURES / "corporate_domains.txt"),
         "--output",   str(out)],
        capture_output=True, text=True,
        cwd=pathlib.Path(__file__).parent.parent.parent,
    )
    assert result.returncode != 0
    assert "duplicate client emails" in result.stderr
