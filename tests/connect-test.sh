#!/bin/sh
# Sandbox tests for scripts/connect.sh and scripts/trust.py.
#
# Everything happens under one scratch folder: CLAUDE_CONFIG_DIR and
# SYMMENO_CONFIG_DIR point into it, so the real ~/.claude.json,
# ~/.claude/settings.json and ~/.config/symmeno-core are never read or written.
# The key file is a made-up string, and the tests end by proving it never
# reached any config or any output. Needs python3, git and the claude command.
#
# Usage: sh tests/connect-test.sh [scratch-dir]   (exit 0 when every check passes)
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
CONNECT="$ROOT/scripts/connect.sh"
SANDBOX=${1:-$(mktemp -d)}
SANDBOX=$(cd "$SANDBOX" && pwd -P)
CORE_HOST="deckhouse-489723-symmeno-core-mcp-svc-clfxlhbjsa-uc.a.run.app"
KEY_TEXT="not-a-real-key-made-up-for-connect-test"
KEYS="$SANDBOX/keys"
OUT="$SANDBOX/out"
mkdir -p "$KEYS" "$OUT"
printf '%s\n' "$KEY_TEXT" > "$KEYS/nautilus-team-key"
KEY="$KEYS/nautilus-team-key"

pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { if [ "$2" = yes ]; then ok "$1"; else bad "$1"; fi; }

# A config dir with one trusted folder T and, optionally, a user-scope entry.
# seed <name> <trusted-folder> [<user-entry-name> <user-entry-url>]
seed() {
  CFG="$SANDBOX/$1/cfg"; mkdir -p "$CFG"
  python3 -I - "$CFG/.claude.json" "$2" "${3:-}" "${4:-}" <<'PY'
import json, sys
path, trusted, name, url = sys.argv[1:5]
config = {"projects": {trusted: {"hasTrustDialogAccepted": True}}}
if name:
    config["mcpServers"] = {name: {"type": "http", "url": url}}
with open(path, "w") as f:
    json.dump(config, f, indent=2)
PY
}

# connect <dir> <log> args...   runs connect.sh in <dir> against $CFG; exit code in $rc.
# $APP is the CLAUDE_CODE_ENTRYPOINT the script sees: cli (default), claude-desktop, or none (unset).
connect() {
  d=$1; log="$OUT/$2"; shift 2
  if [ "${APP:-cli}" = none ]; then entry="-u CLAUDE_CODE_ENTRYPOINT"; else entry="CLAUDE_CODE_ENTRYPOINT=${APP:-cli}"; fi
  (cd "$d" && env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_PID \
      -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_DESKTOP_APP_VERSION $entry \
      CLAUDE_CONFIG_DIR="$CFG" SYMMENO_CONFIG_DIR="$KEYS" sh "$CONNECT" "$@") >"$log" 2>&1
  rc=$?
}

# trust_of <folder>  -> true | false | absent ; servers_of <folder> -> names ; user_servers -> names
trust_of() {
  python3 -I - "$CFG/.claude.json" "$1" <<'PY'
import json, sys
p = (json.load(open(sys.argv[1])).get("projects") or {}).get(sys.argv[2])
print("absent" if p is None or "hasTrustDialogAccepted" not in p else str(bool(p["hasTrustDialogAccepted"])).lower())
PY
}
servers_of() {
  python3 -I - "$CFG/.claude.json" "$1" <<'PY'
import json, sys
p = (json.load(open(sys.argv[1])).get("projects") or {}).get(sys.argv[2]) or {}
print(" ".join(sorted((p.get("mcpServers") or {}).keys())) or "-")
PY
}
user_servers() {
  python3 -I - "$CFG/.claude.json" <<'PY'
import json, sys
print(" ".join(sorted((json.load(open(sys.argv[1])).get("mcpServers") or {}).keys())) or "-")
PY
}
has() { grep -q -- "$2" "$OUT/$1" && echo yes || echo no; }

# ---- the folders: T is trusted; T/repo is a git clone with a planted hook; T/sub is plain
T="$SANDBOX/T"; REPO="$T/repo"; SUB="$T/sub"
mkdir -p "$REPO/sub" "$REPO/.claude" "$SUB"
git -C "$REPO" init -q
printf '%s\n' '{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "echo PLANTED"}]}]}}' > "$REPO/.claude/settings.json"

# 1. Vera's case: a git repo inside a trusted folder ends UNMARKED.
seed vera "$T"
connect "$REPO" vera.log --folder . "$KEY"
check "repo in trusted folder: connect.sh exits 0" "$([ $rc -eq 0 ] && echo yes || echo no)"
check "repo in trusted folder: sc registered under the repo" "$([ "$(servers_of "$REPO")" = sc ] && echo yes || echo no)"
check "repo in trusted folder: repo is NOT marked trusted" "$([ "$(trust_of "$REPO")" != true ] && echo yes || echo no)"
check "repo in trusted folder: prints the not-trusted note" "$(has vera.log '^Note: Claude Code runs the key helper only in a trusted folder')"
check "repo in trusted folder: never prints 'Marked'" "$([ "$(has vera.log 'Marked ')" = no ] && echo yes || echo no)"

# 2. A subfolder of that repo: keyed by the repo root, still unmarked.
seed reposub "$T"
connect "$REPO/sub" reposub.log --folder . "$KEY"
check "repo subfolder: sc registered under the repo root" "$([ "$(servers_of "$REPO")" = sc ] && echo yes || echo no)"
check "repo subfolder: no entry under the subfolder itself" "$([ "$(servers_of "$REPO/sub")" = - ] && echo yes || echo no)"
check "repo subfolder: repo root is NOT marked trusted" "$([ "$(trust_of "$REPO")" != true ] && echo yes || echo no)"

# 3. A plain subfolder of a trusted folder is marked, and says so.
seed plain "$T"
connect "$SUB" plain.log --folder . "$KEY"
check "plain subfolder: exits 0" "$([ $rc -eq 0 ] && echo yes || echo no)"
check "plain subfolder: marked trusted" "$([ "$(trust_of "$SUB")" = true ] && echo yes || echo no)"
check "plain subfolder: prints 'Marked <sub> ... like <T> above it'" "$(has plain.log "^Marked $SUB as trusted in Claude Code, like $T above it")"
check "plain subfolder: T itself untouched" "$([ "$(trust_of "$T")" = true ] && echo yes || echo no)"

# 3b. Running it again changes nothing and says so.
cp "$CFG/.claude.json" "$OUT/plain.before"
connect "$SUB" plain2.log --folder . "$KEY"
check "second run: exits 0" "$([ $rc -eq 0 ] && echo yes || echo no)"
check "second run: says already connected" "$(has plain2.log 'already connected')"
check "second run: config unchanged" "$(cmp -s "$CFG/.claude.json" "$OUT/plain.before" && echo yes || echo no)"

# 4. --folder that is not the current folder is refused, nothing written.
seed notcwd "$T"
cp "$CFG/.claude.json" "$OUT/notcwd.before"
connect "$T" notcwd.log --folder "$SUB" "$KEY"
check "--folder != cwd: exits 1" "$([ $rc -eq 1 ] && echo yes || echo no)"
check "--folder != cwd: says to run from inside the folder" "$(has notcwd.log 'run this from inside the folder you connect')"
check "--folder != cwd: config unchanged" "$(cmp -s "$CFG/.claude.json" "$OUT/notcwd.before" && echo yes || echo no)"
check "--folder != cwd: nothing written to the helper folder" "$([ -z "$(find "$KEYS" -newer "$OUT/notcwd.before")" ] && echo yes || echo no)"

# 5. --survey reports here (the project key) and here_trust, and changes nothing.
seed survey "$T"
cp "$CFG/.claude.json" "$OUT/survey.before"
connect "$REPO" survey-repo.log --survey
check "survey in repo: here is the repo" "$(has survey-repo.log "^here $REPO\$")"
check "survey in repo: here_trust none" "$(has survey-repo.log '^here_trust none$')"
connect "$REPO/sub" survey-reposub.log --survey
check "survey in repo subfolder: here is the repo root" "$(has survey-reposub.log "^here $REPO\$")"
connect "$SUB" survey-sub.log --survey
check "survey in plain subfolder: here_trust inherited T" "$(has survey-sub.log "^here_trust inherited $T\$")"
connect "$T" survey-t.log --survey
check "survey in T: here_trust own" "$(has survey-t.log '^here_trust own$')"
check "survey: mode user (one key file, no Symmeno connection anywhere)" "$(has survey-t.log '^mode user$')"
check "survey: config unchanged" "$(cmp -s "$CFG/.claude.json" "$OUT/survey.before" && echo yes || echo no)"

# 6. --replace-user: a user entry named sc that points elsewhere is NOT Symmeno; refused.
seed foreign "$T" sc "https://example.invalid/mcp"
connect "$SUB" foreign.log --folder . --replace-user sc "$KEY"
check "--replace-user on a foreign 'sc': exits 1" "$([ $rc -eq 1 ] && echo yes || echo no)"
check "--replace-user on a foreign 'sc': says not a Symmeno connection" "$(has foreign.log 'is not a Symmeno connection')"
check "--replace-user on a foreign 'sc': user entry still there" "$([ "$(user_servers)" = sc ] && echo yes || echo no)"
check "--replace-user on a foreign 'sc': nothing registered for the folder" "$([ "$(servers_of "$SUB")" = - ] && echo yes || echo no)"

# 7. --replace-user: a user entry on the Symmeno Core host, under any name, is removed.
seed symmeno "$T" symmeno "https://$CORE_HOST/mcp"
connect "$SUB" symmeno.log --folder . --replace-user symmeno "$KEY"
check "--replace-user on a Core-host entry: exits 0" "$([ $rc -eq 0 ] && echo yes || echo no)"
check "--replace-user on a Core-host entry: says removed" "$(has symmeno.log 'Removed the Symmeno connection `symmeno`')"
check "--replace-user on a Core-host entry: user entry gone" "$([ "$(user_servers)" = - ] && echo yes || echo no)"
check "--replace-user on a Core-host entry: sc registered for the folder" "$([ "$(servers_of "$SUB")" = sc ] && echo yes || echo no)"

# 8. The desktop app: a throwaway scratch workspace is refused in folder mode; the
#    last line says "new session" on desktop, "/reload-plugins" in the terminal, both when unknown.
SCRATCH="$SANDBOX/scratch-workspace-7f3a"; mkdir -p "$SCRATCH"
seed desktop-scratch "$T"
cp "$CFG/.claude.json" "$OUT/desktop-scratch.before"
APP=claude-desktop connect "$SCRATCH" desktop-survey.log --survey
check "desktop survey: app desktop" "$(has desktop-survey.log '^app desktop$')"
check "desktop survey: here_scratch yes for a scratch workspace" "$(has desktop-survey.log '^here_scratch yes$')"
APP=claude-desktop connect "$SCRATCH" desktop-scratch.log --folder . "$KEY"
check "desktop + scratch folder: exits 1" "$([ $rc -eq 1 ] && echo yes || echo no)"
check "desktop + scratch folder: says pick a folder first" "$(has desktop-scratch.log 'Pick a folder first (Choose... in the desktop app), then /sc:start again')"
check "desktop + scratch folder: config unchanged" "$(cmp -s "$CFG/.claude.json" "$OUT/desktop-scratch.before" && echo yes || echo no)"
APP=cli connect "$SCRATCH" terminal-survey.log --survey
check "terminal survey: app terminal" "$(has terminal-survey.log '^app terminal$')"
APP=cli connect "$SCRATCH" terminal-scratch.log --folder . "$KEY"
check "terminal + scratch-looking folder: allowed (the person chose it)" "$([ $rc -eq 0 ] && echo yes || echo no)"
check "terminal: last line says /reload-plugins" "$(has terminal-scratch.log '^Done\. .*type /reload-plugins')"
# A desktop session in a folder the person chose (mktemp on Linux gives /tmp/tmp.X, which is not scratch-shaped;
# on macOS mktemp lands in /var/folders, which is, so this case is only meaningful on Linux).
CHOSEN=$(mktemp -d)
seed desktop-chosen "$T"
APP=claude-desktop connect "$CHOSEN" desktop-chosen.log --folder . "$KEY"
check "desktop + chosen folder: exits 0" "$([ $rc -eq 0 ] && echo yes || echo no)"
check "desktop + chosen folder: sc registered" "$([ "$(servers_of "$CHOSEN")" = sc ] && echo yes || echo no)"
check "desktop: last line says open a new session in the folder" "$(has desktop-chosen.log "^Done\. Open a new session in $CHOSEN, then /sc:start")"
rm -rf "$CHOSEN"
seed desktop-user "$T"
APP=claude-desktop connect "$SCRATCH" desktop-user.log "$KEY"
check "desktop + user scope from a scratch workspace: allowed (no folder involved)" "$([ $rc -eq 0 ] && echo yes || echo no)"
check "desktop + user scope: sc at user scope" "$([ "$(user_servers)" = sc ] && echo yes || echo no)"
check "desktop + user scope: last line says open a new session" "$(has desktop-user.log '^Done\. Open a new session in Claude Code, then /sc:start')"
seed unknown-app "$T"
APP=none connect "$SCRATCH" unknown-survey.log --survey
check "no entrypoint: app unknown" "$(has unknown-survey.log '^app unknown$')"
APP=none connect "$SCRATCH" unknown-user.log "$KEY"
check "no entrypoint: last line says both /reload-plugins and a new session" "$(has unknown-user.log '^Done\. .*type /reload-plugins, or open a new session')"

# 9. The key never reaches a config, a settings file or any output.
leaks=$(grep -rl -- "$KEY_TEXT" "$SANDBOX" | grep -v "^$KEY\$" || true)
check "key text appears nowhere but the key file" "$([ -z "$leaks" ] && echo yes || echo no)"
[ -n "$leaks" ] && printf '  leaked into: %s\n' $leaks

printf '\n%d passed, %d failed  (sandbox: %s)\n' "$pass" "$fail" "$SANDBOX"
[ "$fail" -eq 0 ]
