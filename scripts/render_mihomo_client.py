#!/usr/bin/env python3
"""Render a single-client mihomo config (JSON output, valid YAML 1.2)."""
import argparse, json, sys
from string import Template

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--template", required=True)
    p.add_argument("--node",     required=True)
    p.add_argument("--clients",  required=True)
    p.add_argument("--name",     required=True)
    p.add_argument("--output",   required=True)
    args = p.parse_args()

    with open(args.node) as fh:
        node = json.load(fh)
    with open(args.clients) as fh:
        clients = json.load(fh)
    try:
        c = next(c for c in clients if c["email"] == args.name)
    except StopIteration:
        print(f"client not found: {args.name}", file=sys.stderr)
        raise SystemExit(2)

    with open(args.template) as fh:
        rendered = Template(fh.read()).substitute(
            SERVER_HOST=json.dumps(node["host"]),
            SERVER_PORT=node["listen_port"],
            CLIENT_PASSWORD=json.dumps(c["password"]),
            CERT_FINGERPRINT=json.dumps(node["hysteria2"]["cert_fingerprint_sha256"]),
        )
    obj = json.loads(rendered)
    with open(args.output, "w") as fh:
        json.dump(obj, fh, indent=2, ensure_ascii=False)
        fh.write("\n")

if __name__ == "__main__":
    main()
