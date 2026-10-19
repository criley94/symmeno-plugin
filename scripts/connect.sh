#!/bin/sh
# Connect Claude Code to Symmeno Core.
#
# Usage: connect.sh [--folder <crew-folder>] <key-file>
#
# Registers one MCP server named `sc` pointing at Symmeno Core, with a headers
# helper that reads the team key from <key-file> each time Claude Code connects.
# Then allows the `sc` tools in ~/.claude/settings.json so memory calls do not
# prompt. Safe to run again: a second run changes nothing.
#
# Scope:
#   (no --folder)  every folder on this computer (Claude Code user scope). Only
#                  for a computer that will only ever run one crew.
#   --folder DIR   only Claude Code started in DIR (local scope). REQUIRED on a
#                  computer shared by several crews, so a crew's key never
#                  reaches another crew's sessions.
#
# The key is never read, printed, or stored by this script. The Claude Code
# config holds only two paths: the helper's and the key file's.
set -eu

CORE_URL="https://deckhouse-489723-symmeno-core-mcp-svc-clfxlhbjsa-uc.a.run.app/mcp"
# The same Core service under its other Cloud Run address.
CORE_URL_ALT="https://deckhouse-489723-symmeno-core-mcp-svc-1019921786449.us-central1.run.app/mcp"
SERVER=sc
ALLOW='mcp__sc__*'

HERE=$(cd "$(dirname "$0")" && pwd)
HELPER_DIR="${SYMMENO_CONFIG_DIR:-$HOME/.config/symmeno-core}"
HELPER="$HELPER_DIR/sc-headers"
CLAUDE_JSON="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

say() { printf '%s\n' "$*"; }
die() { printf 'connect.sh: %s\n' "$*" >&2; exit 1; }
usage="usage: connect.sh [--folder <crew-folder>] <key-file>  (for example ~/.config/symmeno-core/nautilus-team-key)"

FOLDER=
if [ "${1:-}" = "--folder" ]; then
  [ $# -ge 2 ] || die "$usage"
  [ -d "$2" ] || die "no folder at $2"
  FOLDER=$(cd "$2" && pwd -P)
  shift 2
fi
[ $# -eq 1 ] || die "$usage"
command -v claude >/dev/null 2>&1 || die "Claude Code (the claude command) is not on PATH."
command -v python3 >/dev/null 2>&1 || die "python3 is needed to read Claude Code's config safely."

case "$1" in
  /*) KEY_FILE="$1" ;;
  *) KEY_FILE="$(pwd)/$1" ;;
esac
[ -f "$KEY_FILE" ] || die "no key file at $KEY_FILE"
[ -s "$KEY_FILE" ] || die "the key file is empty: $KEY_FILE"

if [ -n "$FOLDER" ]; then
  SCOPE=local
  WHERE="Claude Code started in $FOLDER"
  RERUN="sh \"$HERE/connect.sh\" --folder \"$FOLDER\" \"$KEY_FILE\""
else
  SCOPE=user
  WHERE="every folder on this computer"
  RERUN="sh \"$HERE/connect.sh\" \"$KEY_FILE\""
fi

# The helper command stored in the config: two paths, never the key.
HELPER_CMD=$(python3 -I - "$HELPER" "$KEY_FILE" <<'PY'
import shlex, sys
print(shlex.quote(sys.argv[1]) + " " + shlex.quote(sys.argv[2]))
PY
)

# 1. Look for an existing Symmeno connection (reads the config; prints names,
#    scopes and addresses only, never headers). In folder mode a user-scope
#    Symmeno entry is refused too: it would reach every folder.
existing=$(python3 -I - "$CLAUDE_JSON" "$SERVER" "$CORE_URL" "$CORE_URL_ALT" "$HELPER_CMD" "$FOLDER" <<'PY'
import json, sys
from urllib.parse import urlparse
path, server, url, url_alt, helper_cmd, folder = sys.argv[1:7]
try:
    with open(path) as f:
        config = json.load(f)
except FileNotFoundError:
    config = {}
except (OSError, ValueError):
    print("unreadable")
    sys.exit(0)

def symmeno(cfg):
    return "symmeno-core" in (urlparse(str(cfg.get("url") or "")).hostname or "")

user = config.get("mcpServers") or {}
here = ((config.get("projects") or {}).get(folder) or {}) if folder else {}
if folder:
    for name, cfg in user.items():
        if name == server or symmeno(cfg):
            print("userwide\t" + name)
            sys.exit(0)
servers = (here.get("mcpServers") or {}) if folder else user
mine = servers.get(server)
if mine is not None:
    if mine.get("url") in (url, url_alt) and mine.get("headersHelper") == helper_cmd:
        print("same\t" + ("trusted" if not folder or here.get("hasTrustDialogAccepted") else "untrusted"))
    elif mine.get("url") in (url, url_alt):
        # Never print the stored helper or headers: they could hold a key.
        print("elsewhere\tthe same Core, with a different key file or key helper")
    else:
        print("elsewhere\t" + str(mine.get("url") or mine.get("command") or "?"))
    sys.exit(0)
for name, cfg in servers.items():
    if symmeno(cfg):
        print("other\t" + name)
        sys.exit(0)
print("none\t" + ("trusted" if not folder or here.get("hasTrustDialogAccepted") else "untrusted"))
PY
)
status=${existing%%"$(printf '\t')"*}
detail=${existing#*"$(printf '\t')"}

remove_line() {
  if [ "$1" = user ]; then
    say "  claude mcp remove --scope user $2"
  else
    say "  (cd \"$FOLDER\" && claude mcp remove --scope local $2)"
  fi
}

multi_crew_hint() {
  if [ -z "$FOLDER" ]; then
    say "If this computer runs more than one crew, connect each crew's folder instead: add --folder <crew-folder>."
  fi
}

case "$status" in
  unreadable)
    die "could not read $CLAUDE_JSON as JSON. Nothing was changed." ;;
  userwide)
    say "This computer has a Symmeno connection for every folder (\`$detail\`, user scope)."
    say "On a computer shared by several crews, each crew's connection belongs in its own folder."
    say "Nothing was changed. To move it, run these two lines:"
    remove_line user "$detail"
    say "  $RERUN"
    exit 1 ;;
  elsewhere)
    say "An MCP server named \`$SERVER\` already exists for $WHERE and is set up differently: $detail"
    say "Nothing was changed. To replace it, run these two lines:"
    remove_line "$SCOPE" "$SERVER"
    say "  $RERUN"
    multi_crew_hint
    exit 1 ;;
  other)
    say "There is already a Symmeno connection named \`$detail\` for $WHERE."
    say "Symmeno's start text uses tools named mcp__sc__*, so the connection must be named \`sc\`."
    say "Nothing was changed. To rename it, run these two lines:"
    remove_line "$SCOPE" "$detail"
    say "  $RERUN"
    multi_crew_hint
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

# 3. Register `sc` (user scope, or local scope in the crew folder).
if [ "$status" = same ]; then
  say "Symmeno is already connected as \`$SERVER\` for $WHERE ($CORE_URL)."
else
  config=$(python3 -I - "$CORE_URL" "$HELPER_CMD" <<'PY'
import json, sys
url, helper_cmd = sys.argv[1:3]
print(json.dumps({"type": "http", "url": url, "headersHelper": helper_cmd}))
PY
)
  if [ -n "$FOLDER" ]; then
    (cd "$FOLDER" && claude mcp add-json --scope local "$SERVER" "$config" >/dev/null)
  else
    claude mcp add-json --scope user "$SERVER" "$config" >/dev/null
  fi
  say "Connected Symmeno as \`$SERVER\` for $WHERE ($CORE_URL)."
fi
if [ "$detail" = untrusted ]; then
  say "Note: Claude Code runs the key helper only in a trusted folder. Start Claude Code once in $FOLDER and accept the trust question."
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

if [ -n "$FOLDER" ]; then
  say "Done. Start Claude Code in $FOLDER (restart it if it is open there), type /mcp and check that sc shows connected, then type /sc:start <crew>."
else
  say "Done. Restart Claude Code, type /mcp and check that sc shows connected, then type /sc:start <crew>."
fi
