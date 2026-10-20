#!/bin/sh
# Connect Claude Code to Symmeno Core.
#
# Usage: connect.sh [--folder <crew-folder> [--replace-user <name>]] <key-file>
#        connect.sh --survey
#        connect.sh --allow-plugin
#        connect.sh --open-link <sign-in url>
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

CORE_URL="https://core-trial-698809613891.us-central1.run.app/mcp"
# The same Core service under its other Cloud Run address.
CORE_URL_ALT="https://core-trial-698809613891.us-central1.run.app/mcp"
SERVER=sc
ALLOW='mcp__sc__*'
# The plugin's own signed-in connection registers as plugin:sc:sc, so its tools
# carry this prefix. --allow-plugin allows them once, before the sign-in.
PLUGIN_ALLOW='mcp__plugin_sc_sc__*'
# A shared computer (the agent VM) never signs a person in: /sc:start sees
# `shared yes` in --survey and uses crew keys instead. Root creates the file.
SHARED_MARKER="${SYMMENO_SHARED_MARKER:-/etc/symmeno/shared-machine}"

HERE=$(cd "$(dirname "$0")" && pwd)
HELPER_DIR="${SYMMENO_CONFIG_DIR:-$HOME/.config/symmeno-core}"
HELPER="$HELPER_DIR/sc-headers"
CLAUDE_JSON="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

say() { printf '%s\n' "$*"; }
die() { printf 'connect.sh: %s\n' "$*" >&2; exit 1; }
usage="usage: connect.sh [--folder <crew-folder> [--replace-user <name>]] <key-file>  (for example ~/.config/symmeno-core/nautilus-team-key), connect.sh --survey, connect.sh --allow-plugin, or connect.sh --open-link <sign-in url>"

command -v python3 >/dev/null 2>&1 || die "python3 is needed to read Claude Code's config safely."

# Which Claude Code is running the script. The desktop app sets
# CLAUDE_CODE_ENTRYPOINT (the claude binary itself checks these values); the
# terminal sets "cli". It decides the last line: the desktop app loads a new
# connection only in a new session, the terminal with /reload-plugins.
case "${CLAUDE_CODE_ENTRYPOINT:-}" in
  claude-desktop|claude-desktop-3p|local-agent) APP=desktop ;;
  "") APP=${CLAUDE_CODE_DESKTOP_APP_VERSION:+desktop}; APP=${APP:-unknown} ;;
  *) APP=terminal ;;
esac

# A desktop session started without "Choose..." runs in a throwaway workspace.
# Connecting that path would scope the crew to a folder nobody will see again.
is_scratch() {
  python3 -I - "$1" <<'PY'
import os, sys
path = sys.argv[1]
parts = path.split(os.sep)
scratch = (any(p.lower().startswith("scratch") for p in parts)
           or "/Library/Application Support/Claude/" in path + "/"
           or path.startswith(("/var/folders/", "/private/var/folders/", "/private/tmp/")))
print("yes" if scratch else "no")
PY
}

# allow_tools <rule> <what>: allow one tool rule in Claude Code's settings, once,
# keeping every other setting. Says what it did; a settings file it cannot
# read safely is left alone with the line to add.
allow_tools() {
  python3 -I - "$SETTINGS" "$1" "$2" <<'PY'
import json, os, sys
path, rule, what = sys.argv[1:4]
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
    print(f"The {what} are already allowed in {path}.")
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
print(f"Allowed the {what} in {path}.")
PY
}

# --survey: facts only, no change.
if [ "${1:-}" = "--survey" ]; then
  [ $# -eq 1 ] || die "$usage"
  SURVEY_HERE=$(python3 -I "$HERE/trust.py" root "$(pwd -P)")
  python3 -I - "$CLAUDE_JSON" "$SERVER" "$HELPER_DIR" "$SURVEY_HERE" "$CORE_URL" "$CORE_URL_ALT" <<'PY'
import glob, json, os, sys
from urllib.parse import urlparse
path, server, key_dir, here, url, url_alt = sys.argv[1:7]
core_hosts = {urlparse(u).hostname for u in (url, url_alt)}
try:
    with open(path) as f:
        config = json.load(f)
except FileNotFoundError:
    config = {}
except (OSError, ValueError):
    print("error could not read Claude Code's config as JSON")
    sys.exit(0)

def symmeno(name, cfg):
    host = urlparse(str(cfg.get("url") or "")).hostname or ""
    return name == server or host in core_hosts or "symmeno-core" in host

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
  printf 'here_trust %s\n' "$(python3 -I "$HERE/trust.py" state "$CLAUDE_JSON" "$SURVEY_HERE")"
  printf 'app %s\n' "$APP"
  printf 'here_scratch %s\n' "$(is_scratch "$SURVEY_HERE")"
  if [ -e "$SHARED_MARKER" ]; then printf 'shared yes\n'; else printf 'shared no\n'; fi
  exit 0
fi

# --allow-plugin: before the plugin's sign-in, allow its tools once. Nothing
# else is read or written.
if [ "${1:-}" = "--allow-plugin" ]; then
  [ $# -eq 1 ] || die "$usage"
  allow_tools "$PLUGIN_ALLOW" "plugin tools ($PLUGIN_ALLOW)"
  exit 0
fi

# --open-link: open the sign-in page in the person's browser. Only a page on
# the configured Core's own origin and /authorize path is ever opened; anything
# else is refused and nothing runs. Without a browser (a headless or SSH
# session) it says so and exits 0, and /sc:start shows the link instead.
if [ "${1:-}" = "--open-link" ]; then
  [ $# -eq 2 ] || die "$usage"
  # The script is the boundary (Vera): every check is here, in code. First the
  # one URL shape that is ever opened; then whether anyone is at this screen;
  # then at most one open per run; then the open itself, as an argv list.
  mkdir -p "$HELPER_DIR" && chmod 700 "$HELPER_DIR"
  python3 -I - "$2" "$CORE_URL" "$HELPER_DIR/open-link.last" "$SHARED_MARKER" <<'PY'
import os, subprocess, sys, time
from urllib.parse import parse_qs, urlparse

raw, core_url, stamp, marker = sys.argv[1:5]
core = urlparse(core_url)

def refuse(why):
    print(f"refused: {why}. Nothing was opened.")
    sys.exit(1)

# 1. One URL shape only.
if len(raw) > 4096:
    refuse("the link is too long")
if any(ord(c) < 33 or ord(c) == 127 for c in raw):
    refuse("the link holds whitespace or a control character")
link = urlparse(raw)
try:
    # .port raises ValueError on a malformed port (for example a backslash in it): refuse, never trace.
    link_port = link.port
except ValueError:
    refuse("the link could not be parsed")
local_test_core = core.scheme == "http" and core.hostname in ("localhost", "127.0.0.1")
if link.scheme != "https" and not (local_test_core and link.scheme == "http"):
    refuse("not an https link")
if link.username is not None or link.password is not None:
    refuse("the link carries a user name")
if link.hostname != core.hostname:
    refuse(f"not on this Symmeno Core ({core.hostname})")
if link_port not in (None, 443) and not (local_test_core and link_port == core.port):
    refuse("not on this Symmeno Core's port")
if link.path != "/authorize":
    refuse("not the sign-in page")
q = parse_qs(link.query, keep_blank_values=True)
def one(name):
    v = q.get(name, [])
    return v[0] if len(v) == 1 and v[0] else None
if one("response_type") != "code":
    refuse("not a sign-in request (response_type)")
if one("code_challenge_method") != "S256":
    refuse("not a PKCE S256 request")
for name in ("client_id", "code_challenge", "state"):
    if one(name) is None:
        refuse(f"the link has no single {name}")
if one("resource") != core_url:
    refuse("the link is not for this Symmeno Core (resource)")
back = urlparse(one("redirect_uri") or "")
try:
    back_port = back.port
except ValueError:
    refuse("the link could not be parsed (redirect_uri)")
if (back.scheme != "http" or back.hostname not in ("localhost", "127.0.0.1") or back_port is None
        or back.path != "/callback" or back.query or back.username is not None):
    refuse("the sign-in would not come back to this computer (redirect_uri)")

# 2. Print-only when nobody is at this screen. Never guess: unsure means print only.
print_only = None
if any(os.environ.get(v) for v in ("SSH_CONNECTION", "SSH_TTY", "SSH_CLIENT")):
    print_only = "this is an SSH session"
elif os.path.exists(marker):
    print_only = "this is a shared computer"
elif (os.environ.get("CLAUDE_CODE_ENTRYPOINT") or "").startswith(("sdk", "bench")):
    print_only = "this session has no screen"
elif sys.platform != "darwin" and not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
    print_only = "this session has no display"
if print_only:
    print(f"No browser can be opened from this session ({print_only}); open the sign-in link yourself.")
    sys.exit(0)

# 3. At most once per run: a second open within 120 seconds prints only.
try:
    if time.time() - os.stat(stamp).st_mtime < 120:
        print("The sign-in page was opened a moment ago; open the sign-in link yourself if it is not showing.")
        sys.exit(0)
except FileNotFoundError:
    pass
fd = os.open(stamp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.close(fd)
os.utime(stamp, None)

# 4. Open, as an argv list, never through a shell. The URL is not echoed.
opener = ["open", raw] if sys.platform == "darwin" else ["xdg-open", raw]
try:
    done = subprocess.run(opener, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    ok = done.returncode == 0
except (OSError, subprocess.SubprocessError):
    ok = False
print("Opened the sign-in page in your browser." if ok
      else "No browser could be opened from this session; open the sign-in link yourself.")
PY
  exit $?
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
  if [ "$APP" = desktop ] && [ "$(is_scratch "$FOLDER")" = yes ]; then
    die "Pick a folder first (Choose... in the desktop app), then /sc:start again. This session runs in a throwaway workspace, not a folder you chose: $FOLDER. Nothing was changed."
  fi
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

core_hosts = {urlparse(u).hostname for u in (url, url_alt)}

def symmeno(cfg):
    host = urlparse(str(cfg.get("url") or "")).hostname or ""
    return host in core_hosts or "symmeno-core" in host

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
  kind=$(python3 -I - "$CLAUDE_JSON" "$SERVER" "$REPLACE_USER" "$CORE_URL" "$CORE_URL_ALT" <<'PY'
import json, sys
from urllib.parse import urlparse
path, server, name, url, url_alt = sys.argv[1:6]
core_hosts = {urlparse(u).hostname for u in (url, url_alt)}
try:
    with open(path) as f:
        cfg = (json.load(f).get("mcpServers") or {}).get(name)
except (OSError, ValueError):
    cfg = None
host = urlparse(str((cfg or {}).get("url") or "")).hostname or ""
if cfg is None:
    print("absent")
elif host in core_hosts or "symmeno-core" in host:
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
allow_tools "$ALLOW" "sc tools"

# A running terminal Claude Code picks up the new connection with
# /reload-plugins; the desktop app only in a new session.
if [ -n "$FOLDER" ]; then AT="in $FOLDER"; else AT="in Claude Code"; fi
case "$APP" in
  desktop)  say "Done. Open a new session $AT, then /sc:start <crew>. (The desktop app loads a new connection only in a new session.)" ;;
  terminal) say "Done. In Claude Code${FOLDER:+ running in $FOLDER}, type /reload-plugins (or start Claude Code again), then /sc:start <crew>." ;;
  *)        say "Done. In Claude Code${FOLDER:+ running in $FOLDER}, type /reload-plugins, or open a new session, then /sc:start <crew>." ;;
esac
exit 0
