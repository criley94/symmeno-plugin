#!/bin/sh
# set-core-url.sh <url>   -- point the plugin at another Symmeno Core (a trial build).
#
# The bundled connection (.mcp.json) and connect.sh's CORE_URL must stay
# byte-identical: Claude Code keeps one tool set only when a folder's crew-key
# `sc` and the plugin's server have exactly the same URL. This rewrites both, and
# tests/connect-test.sh checks they match. No argument prints the current URL.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
if [ $# -eq 0 ]; then
  sed -n 's/^CORE_URL="\(.*\)"$/\1/p' "$ROOT/scripts/connect.sh"
  exit 0
fi
[ $# -eq 1 ] || { echo "usage: set-core-url.sh [<url>]" >&2; exit 1; }
case "$1" in
  https://*/mcp) ;;
  http://localhost:*/mcp|http://127.0.0.1:*/mcp) ;;   # a local test Core only
  *) echo "set-core-url.sh: the URL must be https://<host>/mcp, got: $1" >&2; exit 1 ;;
esac
python3 -I - "$ROOT" "$1" <<'PY'
import json, re, sys
root, url = sys.argv[1:3]
p = f"{root}/scripts/connect.sh"
s = open(p).read()
s, n = re.subn(r'^CORE_URL=".*"$', f'CORE_URL="{url}"', s, count=1, flags=re.M)
assert n == 1, "CORE_URL line not found in connect.sh"
open(p, "w").write(s)
m = f"{root}/.mcp.json"
cfg = json.load(open(m))
cfg["mcpServers"]["sc"]["url"] = url
with open(m, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print(f"Core URL is now {url} in scripts/connect.sh and .mcp.json")
PY
