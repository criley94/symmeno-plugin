#!/bin/sh
# Connect this computer's Claude Code to Symmeno Core.
#
# Usage: connect.sh <key-file>
#
# Registers one MCP server named `sc`, at user scope, pointing at Symmeno Core,
# with a headers helper that reads the team key from <key-file> each time Claude
# Code connects. Then allows the `sc` tools in ~/.claude/settings.json so memory
# calls do not prompt. Safe to run again: a second run changes nothing.
#
# The key is never read, printed, or stored by this script. The Claude Code
# config holds only two paths: the helper's and the key file's.
set -eu

CORE_URL="https://deckhouse-489723-symmeno-core-mcp-svc-clfxlhbjsa-uc.a.run.app/mcp"
SERVER=sc
ALLOW='mcp__sc__*'

HERE=$(cd "$(dirname "$0")" && pwd)
HELPER_DIR="${SYMMENO_CONFIG_DIR:-$HOME/.config/symmeno-core}"
HELPER="$HELPER_DIR/sc-headers"
CLAUDE_JSON="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

say() { printf '%s\n' "$*"; }
die() { printf 'connect.sh: %s\n' "$*" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: connect.sh <key-file>  (for example ~/.config/symmeno-core/nautilus-team-key)"
command -v claude >/dev/null 2>&1 || die "Claude Code (the claude command) is not on PATH."
command -v python3 >/dev/null 2>&1 || die "python3 is needed to read Claude Code's config safely."

case "$1" in
  /*) KEY_FILE="$1" ;;
  *) KEY_FILE="$(pwd)/$1" ;;
esac
[ -f "$KEY_FILE" ] || die "no key file at $KEY_FILE"
[ -s "$KEY_FILE" ] || die "the key file is empty: $KEY_FILE"

# 1. Look for an existing Symmeno connection at user scope (reads the config;
#    prints names and addresses only, never headers).
existing=$(python3 -I - "$CLAUDE_JSON" "$SERVER" "$CORE_URL" <<'PY'
import json, sys
from urllib.parse import urlparse
path, server, url = sys.argv[1:4]
try:
    with open(path) as f:
        servers = json.load(f).get("mcpServers") or {}
except FileNotFoundError:
    servers = {}
except (OSError, ValueError):
    print("unreadable")
    sys.exit(0)
mine = servers.get(server)
if mine is not None:
    print("same" if mine.get("url") == url else "elsewhere " + str(mine.get("url") or mine.get("command") or "?"))
    sys.exit(0)
for name, cfg in servers.items():
    host = urlparse(str(cfg.get("url") or "")).hostname or ""
    if "symmeno-core" in host:
        print("other " + name)
        sys.exit(0)
print("none")
PY
)

case "$existing" in
  unreadable)
    die "could not read $CLAUDE_JSON as JSON. Nothing was changed." ;;
  "elsewhere "*)
    say "An MCP server named \`$SERVER\` already exists and points somewhere else: ${existing#elsewhere }"
    say "Nothing was changed. To replace it, run these two lines:"
    say "  claude mcp remove --scope user $SERVER"
    say "  sh \"$HERE/connect.sh\" \"$KEY_FILE\""
    exit 1 ;;
  "other "*)
    name=${existing#other }
    say "This computer already has a Symmeno connection named \`$name\`."
    say "Symmeno's start text uses tools named mcp__sc__*, so the connection must be named \`sc\`."
    say "Nothing was changed. To rename it, run these two lines:"
    say "  claude mcp remove --scope user $name"
    say "  sh \"$HERE/connect.sh\" \"$KEY_FILE\""
    exit 1 ;;
esac

# 2. Install the headers helper at a stable path (the plugin's own folder
#    changes with every version).
mkdir -p "$HELPER_DIR"
chmod 700 "$HELPER_DIR"
if [ -f "$HELPER" ] && cmp -s "$HERE/sc-headers" "$HELPER"; then
  say "Headers helper already in place: $HELPER"
else
  cp "$HERE/sc-headers" "$HELPER.tmp.$$"
  chmod 700 "$HELPER.tmp.$$"
  mv "$HELPER.tmp.$$" "$HELPER"
  say "Installed the headers helper: $HELPER"
fi

# 3. Register `sc` at user scope.
if [ "$existing" = same ]; then
  say "Symmeno is already connected as \`$SERVER\` ($CORE_URL)."
else
  config=$(python3 -I - "$CORE_URL" "$HELPER" "$KEY_FILE" <<'PY'
import json, shlex, sys
url, helper, key_file = sys.argv[1:4]
print(json.dumps({"type": "http", "url": url,
                  "headersHelper": shlex.quote(helper) + " " + shlex.quote(key_file)}))
PY
)
  claude mcp add-json --scope user "$SERVER" "$config" >/dev/null
  say "Connected Symmeno as \`$SERVER\` at user scope ($CORE_URL)."
fi

# 4. Allow the sc tools, once, keeping every other setting.
python3 -I - "$SETTINGS" "$ALLOW" <<'PY'
import json, os, sys
path, rule = sys.argv[1:3]
try:
    with open(path) as f:
        settings = json.load(f)
except FileNotFoundError:
    settings = {}
except (OSError, ValueError):
    print(f"{path} is not valid JSON, so it was left alone. Add this to its permissions.allow list: \"{rule}\"")
    sys.exit(0)
if not isinstance(settings, dict):
    print(f"{path} is not a JSON object, so it was left alone. Add this to its permissions.allow list: \"{rule}\"")
    sys.exit(0)
perms = settings.setdefault("permissions", {})
allow = perms.setdefault("allow", []) if isinstance(perms, dict) else None
if not isinstance(allow, list):
    print(f"{path} has an unexpected permissions shape, so it was left alone. Add this to its permissions.allow list: \"{rule}\"")
    sys.exit(0)
if rule in allow:
    print(f"The sc tools are already allowed in {path}.")
    sys.exit(0)
allow.append(rule)
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
tmp = f"{path}.tmp.{os.getpid()}"
with open(tmp, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
if os.path.exists(path):
    os.chmod(tmp, os.stat(path).st_mode & 0o777)
os.replace(tmp, path)
print(f"Allowed the sc tools in {path}.")
PY

say "Done. Restart Claude Code, type /mcp and check that sc shows connected, then type /sc:start <crew>."
