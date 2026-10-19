#!/bin/sh
# Connect Claude Code to Symmeno Core.
#
# Usage: connect.sh [--folder <crew-folder> [--replace-user <name>]] <key-file>
#        connect.sh --survey
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
#                  computer that runs more than one crew, so a crew's key never
#                  reaches another crew's sessions. Run it from inside DIR
#                  (DIR must be the current folder, so `--folder .` works). If DIR
#                  has no trust answer of its own but a folder above it is trusted
#                  in Claude Code, DIR is marked trusted too, never across a git
#                  repository boundary (see trust.py).
#   --replace-user NAME  with --folder: first remove the user-scope entry NAME
#                  if it points at Symmeno Core, since it would reach every folder.
#
# --survey prints what /sc:start needs to connect the current folder: the crews
# with a key file (names and paths only), the Symmeno connections already on this
# computer, and whether to connect one folder or every folder. It changes nothing.
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
usage="usage: connect.sh [--folder <crew-folder> [--replace-user <name>]] <key-file>  (for example ~/.config/symmeno-core/nautilus-team-key), or connect.sh --survey"

command -v python3 >/dev/null 2>&1 || die "python3 is needed to read Claude Code's config safely."

# --survey: facts only, no change.
if [ "${1:-}" = "--survey" ]; then
  [ $# -eq 1 ] || die "$usage"
  python3 -I - "$CLAUDE_JSON" "$SERVER" "$HELPER_DIR" "$(python3 -I "$HERE/trust.py" root "$(pwd -P)")" <<'PY'
import glob, json, os, sys
from urllib.parse import urlparse
path, server, key_dir, here = sys.argv[1:5]
try:
    with open(path) as f:
        config = json.load(f)
except FileNotFoundError:
    config = {}
except (OSError, ValueError):
    print("error could not read Claude Code's config as JSON")
    sys.exit(0)

def symmeno(name, cfg):
    return name == server or "symmeno-core" in (urlparse(str(cfg.get("url") or "")).hostname or "")

user_sc = next((n for n, c in (config.get("mcpServers") or {}).items() if symmeno(n, c)), "none")
here_sc, other_folders = "none", 0
for folder, proj in (config.get("projects") or {}).items():
    entries = [n for n, c in (proj.get("mcpServers") or {}).items() if symmeno(n, c)]
    if not entries:
        continue
    if folder == here:
        here_sc = entries[0]
    else:
        other_folders += 1
# Crews are named by their key files; the files themselves are never opened.
crews = sorted(glob.glob(os.path.join(key_dir, "*-team-key")))
nested = [p for p in glob.glob(os.path.join(key_dir, "**", "*-team-key"), recursive=True) if p not in crews]
print("here " + here)
print("here_sc " + here_sc)
print("user_sc " + user_sc)
print("other_folders %d" % other_folders)
for p in crews:
    print("crew %s %s" % (os.path.basename(p)[: -len("-team-key")], p))
print("nested_keys %d" % len(nested))
one_crew = len(crews) == 1 and not nested and user_sc == "none" and here_sc == "none" and other_folders == 0
print("mode " + ("user" if one_crew else "folder"))
PY
  printf 'here_trust %s\n' "$(python3 -I "$HERE/trust.py" state "$CLAUDE_JSON" "$(python3 -I "$HERE/trust.py" root "$(pwd -P)")")"
  exit 0
fi

FOLDER=
REPLACE_USER=
if [ "${1:-}" = "--folder" ]; then
  [ $# -ge 2 ] || die "$usage"
  [ -d "$2" ] || die "no folder at $2"
  FOLDER=$(cd "$2" && pwd -P)
  [ "$FOLDER" = "$(pwd -P)" ] || die "run this from inside the folder you connect: cd \"$FOLDER\" && sh \"$HERE/connect.sh\" --folder . <key-file>"
  shift 2
  if [ "${1:-}" = "--replace-user" ]; then
    [ $# -ge 2 ] || die "$usage"
    REPLACE_USER=$2
    shift 2
  fi
fi
[ $# -eq 1 ] || die "$usage"
command -v claude >/dev/null 2>&1 || die "Claude Code (the claude command) is not on PATH."

case "$1" in
  /*) KEY_FILE="$1" ;;
  *) KEY_FILE="$(pwd)/$1" ;;
esac
[ -f "$KEY_FILE" ] || die "no key file at $KEY_FILE"
[ -s "$KEY_FILE" ] || die "the key file is empty: $KEY_FILE"

if [ -n "$FOLDER" ]; then
  SCOPE=local
  # Inside a git repository Claude Code keeps local settings under its root.
  FOLDER=$(python3 -I "$HERE/trust.py" root "$FOLDER")
  WHERE="Claude Code started in $FOLDER"
  if [ -e "$FOLDER/.git" ]; then
    WHERE="Claude Code started anywhere in the git repository $FOLDER"
  fi
  RERUN="cd \"$(pwd -P)\" && sh \"$HERE/connect.sh\" --folder . \"$KEY_FILE\""
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
existing=$(python3 -I - "$CLAUDE_JSON" "$SERVER" "$CORE_URL" "$CORE_URL_ALT" "$HELPER_CMD" "$FOLDER" "$REPLACE_USER" <<'PY'
import json, sys
from urllib.parse import urlparse
path, server, url, url_alt, helper_cmd, folder, replace_user = sys.argv[1:8]
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
        if name != replace_user and (name == server or symmeno(cfg)):
            print("userwide\t" + name)
            sys.exit(0)
servers = (here.get("mcpServers") or {}) if folder else user
mine = servers.get(server)
if mine is not None:
    if mine.get("url") in (url, url_alt) and mine.get("headersHelper") == helper_cmd:
        print("same\t-")
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
print("none\t-")
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
    say "On a computer that runs more than one crew, each crew's connection belongs in its own folder."
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

# 2a. --replace-user: now that the checks passed, remove the named user-scope
#     entry, but only a Symmeno one.
if [ -n "$REPLACE_USER" ]; then
  kind=$(python3 -I - "$CLAUDE_JSON" "$SERVER" "$REPLACE_USER" <<'PY'
import json, sys
from urllib.parse import urlparse
path, server, name = sys.argv[1:4]
try:
    with open(path) as f:
        cfg = (json.load(f).get("mcpServers") or {}).get(name)
except (OSError, ValueError):
    cfg = None
if cfg is None:
    print("absent")
elif "symmeno-core" in (urlparse(str(cfg.get("url") or "")).hostname or ""):
    print("symmeno")
else:
    print("not-symmeno")
PY
)
  case "$kind" in
    symmeno)
      claude mcp remove --scope user "$REPLACE_USER" >/dev/null
      say "Removed the Symmeno connection \`$REPLACE_USER\` that reached every folder." ;;
    absent) ;;
    *) die "\`$REPLACE_USER\` is not a Symmeno connection, so it was left alone. Nothing was changed." ;;
  esac
fi

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

# 3b. Folder trust. Claude Code runs a local-scope key helper only in a folder
#     whose own entry is marked trusted; mirror trust inherited from a folder
#     above, but never across a git repository boundary (trust.py).
if [ -n "$FOLDER" ]; then
  python3 -I "$HERE/trust.py" mark "$CLAUDE_JSON" "$FOLDER"
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

# A running Claude Code picks up the new connection with /reload-plugins.
if [ -n "$FOLDER" ]; then
  say "Done. In Claude Code running in $FOLDER, type /reload-plugins (or start Claude Code there), then /sc:start <crew>."
else
  say "Done. In Claude Code, type /reload-plugins (or start Claude Code again), then /sc:start <crew>."
fi
