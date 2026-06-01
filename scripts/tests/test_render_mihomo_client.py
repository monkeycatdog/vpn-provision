import json, pathlib, subprocess

FIXTURES = pathlib.Path(__file__).parent / "fixtures"
RENDER   = pathlib.Path(__file__).parent.parent / "render_mihomo_client.py"

def test_client_yaml_has_hysteria2_with_creds(tmp_path):
    out = tmp_path / "client.yaml"
    subprocess.run(
        ["python3", str(RENDER),
         "--template", "config/mihomo_client.template.yaml",
         "--node",    str(FIXTURES / "node.mihomo.json"),
         "--clients", str(FIXTURES / "clients.mihomo.json"),
         "--name",    "laptop",
         "--output",  str(out)],
        check=True,
        cwd=pathlib.Path(__file__).parent.parent.parent,
    )
    cfg = json.loads(out.read_text())
    proxy = cfg["proxies"][0]
    assert proxy["type"] == "hysteria2"
    assert proxy["server"] == "203.0.113.10"
    assert proxy["port"] == 443
    assert proxy["password"] == "firstSecret123"
    assert proxy["fingerprint"] == "AA:BB:CC:DD"

def test_unknown_client_name_errors(tmp_path):
    out = tmp_path / "client.yaml"
    result = subprocess.run(
        ["python3", str(RENDER),
         "--template", "config/mihomo_client.template.yaml",
         "--node",    str(FIXTURES / "node.mihomo.json"),
         "--clients", str(FIXTURES / "clients.mihomo.json"),
         "--name",    "nonexistent",
         "--output",  str(out)],
        capture_output=True, text=True,
        cwd=pathlib.Path(__file__).parent.parent.parent,
    )
    assert result.returncode != 0
    assert "client not found" in result.stderr.lower()
