# Outline multi-URI + ssconf support (main/Xray branch)

## Problem

`scripts/provision_remote.sh` on `main` accepts one `--outline-uri`, requires
`scheme == "ss"`, and fails on the `ssconf://` dynamic-access-key URIs
currently in `.env` (`TRISTATE_OUTLINE_URI`, comma-separated, two entries).
The `mihomo` branch already solved this for its own render path
(`scripts/render_mihomo.py`, repeatable `--outline-uri` / `--outline-uris-csv`,
named endpoints). `main` and `mihomo` are separate implementations sharing
the same CLI concept — this spec ports that concept to `main`'s Xray path,
adding `ssconf://` resolution that `mihomo` doesn't have yet either.

## CLI

- `--outline-uri <uri>` — repeatable, appends to an array.
- `--outline-uris` / `--outline-uris-csv '<a>,<b>'` — comma-split, appends to
  the same array.
- `justfile` (both `provision` and any other recipe passing
  `TRISTATE_OUTLINE_URI`) switches from single `--outline-uri "$X"` to
  `--outline-uris-csv "$X"`.
- At least one URI required (existing validation, extended to check array
  non-empty instead of a single string).

## URI resolution

Single function `parse_outline_uri <uri> <default_name>` (python, inline —
no new deps) replaces the two duplicated inline parse blocks currently at
`provision_remote.sh:204` (dry-run validation) and `:279` (real render).

- `scheme == "ss"`: unchanged — base64-decode userinfo as `METHOD:PASSWORD`.
- `scheme == "ssconf"`: rewrite to `https://` and fetch via
  `urllib.request.urlopen(..., timeout=10)`; `json.loads` the body; expect
  `{"server", "server_port", "password", "method", ["prefix"]}`. Fetch
  failure raises with the offending URL in the message — no retry.
- Both paths return `{"name", "address", "port", "method", "password",
  ["prefix"]}`. `name` = URI fragment (`#foo`, unquoted) if present, else
  `default_name` (`endpoint-<index>`).
- After resolving all URIs, reject duplicate `name`s (mirrors mihomo
  branch's check).

## node.json

`"outline"` changes from a single object to a list of resolved entries, one
per URI, in input order. Matches the shape already present in
`state/51.250.90.29/node.json` (written under the mihomo branch).

## Xray template rendering

`config/xray_config.template.json`'s `ss-freedom` outbound
(`settings.servers`) is already an array containing one placeholder object.
Replace the four scalar placeholders (`$OUTLINE_ADDRESS/PORT/METHOD/PASSWORD`)
with one `$OUTLINE_SERVERS` placeholder substituted as
`json.dumps([{"address", "port", "method", "password"} for each entry])`
(`name`/`prefix` dropped — not part of Xray's shadowsocks server schema).
Xray's shadowsocks outbound natively distributes across multiple `servers`
entries in one outbound; no routing/balancer changes needed.

## Dry-run validation

Same loop, over all resolved URIs, printing `scheme=... host=... port=...
method=...` per entry (as today, just N times instead of once).

## Out of scope

- No load-balancing strategy selection (random default is fine — YAGNI).
- No retry/backoff on ssconf fetch.
- No changes to `mihomo` branch itself (already has multi-URI; this spec
  only adds what main is missing).
