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

# 9. Shared-machine marker (0.3): the survey says so, by the marker file only. Both cases
#    point the marker path into the sandbox, so the host's own marker never decides a result.
seed shared "$T"
survey_with_marker() {  # survey_with_marker <marker-path> <log>
  (cd "$SUB" && env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_PID \
      -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_ENTRYPOINT=cli \
      CLAUDE_CONFIG_DIR="$CFG" SYMMENO_CONFIG_DIR="$KEYS" SYMMENO_SHARED_MARKER="$1" \
      sh "$CONNECT" --survey) > "$OUT/$2" 2>&1
}
survey_with_marker "$SANDBOX/no-such-marker" shared-no.log
check "survey: shared no without the marker" "$(has shared-no.log '^shared no$')"
: > "$SANDBOX/shared-machine"
survey_with_marker "$SANDBOX/shared-machine" shared-yes.log
check "survey: shared yes with the marker" "$(has shared-yes.log '^shared yes$')"

# 9a. A user-wide entry at the configured Core address counts as Symmeno whatever its name and even when the
#     host does not contain "symmeno-core" (a trial Core): the survey reports it and folder mode refuses.
seed corehost "$T" old "$(sh "$ROOT/scripts/set-core-url.sh")"
connect "$SUB" corehost-survey.log --survey
check "survey: user_sc names a user-wide entry at the configured Core address" "$(has corehost-survey.log '^user_sc old$')"
cp "$CFG/.claude.json" "$OUT/corehost.before"
connect "$SUB" corehost-folder.log --folder . "$KEY"
check "folder mode refuses while that user-wide entry exists" "$([ $rc -eq 1 ] && echo yes || echo no)"
check "folder mode names it in the refusal" "$(has corehost-folder.log 'Symmeno connection for every folder (`old`')"
check "folder mode changed nothing" "$(cmp -s "$CFG/.claude.json" "$OUT/corehost.before" && echo yes || echo no)"
connect "$SUB" corehost-replace.log --folder . --replace-user old "$KEY"
check "--replace-user removes it by the configured Core address" "$([ $rc -eq 0 ] && [ "$(user_servers)" = - ] && echo yes || echo no)"

# 9c. --open-link (0.3.5, Vera's conditions): one URL shape, print-only when nobody is at the screen,
#     once per run, open as argv. A stub xdg-open on PATH records every open; most cases must record none.
CORE=$(sh "$ROOT/scripts/set-core-url.sh"); CORE_ORIGIN=${CORE%/mcp}; CORE_HOSTPORT=${CORE_ORIGIN#*://}
ENC_CORE=$(python3 -I -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=''))" "$CORE")
GOOD="$CORE_ORIGIN/authorize?response_type=code&client_id=c1&code_challenge=x&code_challenge_method=S256&redirect_uri=http%3A%2F%2Flocalhost%3A5%2Fcallback&state=s&scope=mcp&resource=$ENC_CORE"
STUBBIN="$SANDBOX/stubbin"; mkdir -p "$STUBBIN"; printf '#!/bin/sh\nprintf %%s "$1" >> "%s/opened.txt"\n' "$SANDBOX" > "$STUBBIN/xdg-open"; chmod +x "$STUBBIN/xdg-open"
# openlink <log> <env assignments...> -- -u SSH_* and a sandbox marker path, so neither the VM's own SSH
# session nor the host's real /etc/symmeno/shared-machine ever decides a result
openlink() { log=$1; shift; (cd "$SUB" && env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_PID \
    -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u SSH_CONNECTION -u SSH_TTY -u SSH_CLIENT -u WAYLAND_DISPLAY \
    CLAUDE_CODE_ENTRYPOINT=cli PATH="$STUBBIN:$PATH" CLAUDE_CONFIG_DIR="$CFG" SYMMENO_CONFIG_DIR="$KEYS" \
    SYMMENO_SHARED_MARKER="$SANDBOX/no-such-marker" "$@") > "$OUT/$log" 2>&1; rc=$?; }
opened() { [ -e "$SANDBOX/opened.txt" ] && cat "$SANDBOX/opened.txt" || printf ''; }
seed openlink "$T"
# positive: a display, a good link: opened exactly once, with exactly the given URL, stamp mode 600
openlink ol-good.log env DISPLAY=:9 sh "$CONNECT" --open-link "$GOOD"
check "--open-link good: exits 0 and says opened" "$([ $rc -eq 0 ] && grep -q 'Opened the sign-in page' "$OUT/ol-good.log" && echo yes || echo no)"
check "--open-link good: opened exactly the given URL, once" "$([ "$(opened)" = "$GOOD" ] && echo yes || echo no)"
check "--open-link good: the once-per-run stamp is mode 600" "$([ "$(stat -c %a "$KEYS/open-link.last" 2>/dev/null || stat -f %Lp "$KEYS/open-link.last")" = 600 ] && echo yes || echo no)"
# a second call within 120 seconds prints only
openlink ol-again.log env DISPLAY=:9 sh "$CONNECT" --open-link "$GOOD"
check "--open-link twice in one run: second call prints only" "$([ $rc -eq 0 ] && grep -q 'opened a moment ago' "$OUT/ol-again.log" && [ "$(opened)" = "$GOOD" ] && echo yes || echo no)"
rm -f "$SANDBOX/opened.txt" "$KEYS/open-link.last"
# print-only: nobody at this screen (each with a display and the stub ready, so an open would show)
openlink ol-ssh.log env DISPLAY=:9 SSH_CONNECTION="1.2.3.4 5 6.7.8.9 22" sh "$CONNECT" --open-link "$GOOD"
check "--open-link over SSH: prints only, opens nothing" "$([ $rc -eq 0 ] && grep -q 'SSH session' "$OUT/ol-ssh.log" && [ -z "$(opened)" ] && echo yes || echo no)"
: > "$SANDBOX/shared-machine"
openlink ol-shared.log env DISPLAY=:9 SYMMENO_SHARED_MARKER="$SANDBOX/shared-machine" sh "$CONNECT" --open-link "$GOOD"
check "--open-link on a shared computer: prints only, opens nothing" "$([ $rc -eq 0 ] && grep -q 'shared computer' "$OUT/ol-shared.log" && [ -z "$(opened)" ] && echo yes || echo no)"
openlink ol-sdk.log env DISPLAY=:9 CLAUDE_CODE_ENTRYPOINT=sdk-py sh "$CONNECT" --open-link "$GOOD"
check "--open-link from an SDK session: prints only, opens nothing" "$([ $rc -eq 0 ] && grep -q 'no screen' "$OUT/ol-sdk.log" && [ -z "$(opened)" ] && echo yes || echo no)"
openlink ol-nodisplay.log env -u DISPLAY sh "$CONNECT" --open-link "$GOOD"
check "--open-link without a display: prints only, opens nothing" "$([ $rc -eq 0 ] && grep -q 'no display' "$OUT/ol-nodisplay.log" && [ -z "$(opened)" ] && echo yes || echo no)"
# refusals: exit 1, "Nothing was opened", nothing recorded (all with a display and the stub ready)
refuse_case() {  # refuse_case <label> <url>
  openlink ol-bad.log env DISPLAY=:9 sh "$CONNECT" --open-link "$2"
  check "--open-link refuses $1" "$([ $rc -eq 1 ] && grep -q 'Nothing was opened' "$OUT/ol-bad.log" && [ -z "$(opened)" ] && echo yes || echo no)"
}
refuse_case "another host" "https://evil.example/authorize?response_type=code&client_id=c1&code_challenge=x&code_challenge_method=S256&redirect_uri=http%3A%2F%2Flocalhost%3A5%2Fcallback&state=s&resource=$ENC_CORE"
refuse_case "a look-alike host" "${CORE_ORIGIN}.evil.example/authorize?response_type=code&client_id=c1&code_challenge=x&code_challenge_method=S256&redirect_uri=http%3A%2F%2Flocalhost%3A5%2Fcallback&state=s&resource=$ENC_CORE"
refuse_case "http instead of https" "$(printf '%s' "$GOOD" | sed 's#^https://#http://#')"
refuse_case "userinfo in the host" "https://core@${CORE_HOSTPORT}/authorize?response_type=code&client_id=c1&code_challenge=x&code_challenge_method=S256&redirect_uri=http%3A%2F%2Flocalhost%3A5%2Fcallback&state=s&resource=$ENC_CORE"
refuse_case "another path" "$CORE_ORIGIN/anything?response_type=code&client_id=c1&code_challenge=x&code_challenge_method=S256&redirect_uri=http%3A%2F%2Flocalhost%3A5%2Fcallback&state=s&resource=$ENC_CORE"
refuse_case "a missing resource" "$CORE_ORIGIN/authorize?response_type=code&client_id=c1&code_challenge=x&code_challenge_method=S256&redirect_uri=http%3A%2F%2Flocalhost%3A5%2Fcallback&state=s"
refuse_case "a wrong resource" "$CORE_ORIGIN/authorize?response_type=code&client_id=c1&code_challenge=x&code_challenge_method=S256&redirect_uri=http%3A%2F%2Flocalhost%3A5%2Fcallback&state=s&resource=https%3A%2F%2Fevil.example%2Fmcp"
refuse_case "response_type=token" "$(printf '%s' "$GOOD" | sed 's/response_type=code/response_type=token/')"
refuse_case "plain PKCE" "$(printf '%s' "$GOOD" | sed 's/code_challenge_method=S256/code_challenge_method=plain/')"
refuse_case "a missing state" "$(printf '%s' "$GOOD" | sed 's/&state=s//')"
refuse_case "a hosted redirect_uri" "$(printf '%s' "$GOOD" | sed 's#redirect_uri=[^&]*#redirect_uri=https%3A%2F%2Fclaude.ai%2Fapi%2Fmcp%2Fauth_callback#')"
refuse_case "a non-loopback redirect_uri" "$(printf '%s' "$GOOD" | sed 's#redirect_uri=[^&]*#redirect_uri=http%3A%2F%2Fevil.example%3A5%2Fcallback#')"
refuse_case "a 5,000-character URL" "$GOOD&pad=$(python3 -I -c "print('a' * 5000)")"
refuse_case "a space in the URL" "$GOOD &x=1"
check "--open-link refuses a missing or extra argument" "$(connect "$SUB" ol-args.log --open-link; [ $rc -eq 1 ] && echo yes || echo no)"
rm -f "$SANDBOX/shared-machine"

# 9b. --allow-plugin (0.3): allows the signed-in connection's tools once, touches nothing else.
seed allowplugin "$T"
printf '%s\n' '{"theme": "dark", "permissions": {"allow": ["Bash(ls:*)"], "deny": ["Read(/etc/*)"]}}' > "$CFG/settings.json"
cp "$CFG/.claude.json" "$OUT/allowplugin.before"
connect "$SUB" allowplugin.log --allow-plugin
check "--allow-plugin: exits 0" "$([ $rc -eq 0 ] && echo yes || echo no)"
check "--allow-plugin: says it allowed the plugin tools" "$(has allowplugin.log 'Allowed the plugin')"
check "--allow-plugin: rule added, other settings kept" "$(python3 -I - "$CFG/settings.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
ok = (s.get("theme") == "dark" and s["permissions"]["deny"] == ["Read(/etc/*)"]
      and s["permissions"]["allow"] == ["Bash(ls:*)", "mcp__plugin_sc_sc__*"])
print("yes" if ok else "no")
PY
)"
check "--allow-plugin: .claude.json untouched" "$(cmp -s "$CFG/.claude.json" "$OUT/allowplugin.before" && echo yes || echo no)"
connect "$SUB" allowplugin2.log --allow-plugin
check "--allow-plugin twice: says already allowed" "$(has allowplugin2.log 'already allowed')"
check "--allow-plugin twice: rule not duplicated" "$([ "$(python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]))['permissions']['allow'].count('mcp__plugin_sc_sc__*'))" "$CFG/settings.json")" = 1 ] && echo yes || echo no)"
check "--allow-plugin: refuses extra arguments" "$(connect "$SUB" allowplugin3.log --allow-plugin extra; [ $rc -eq 1 ] && echo yes || echo no)"

# 10. The bundled connection and connect.sh name the same Core, byte for byte; set-core-url.sh keeps it so.
MCP_URL=$(python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]))['mcpServers']['sc']['url'])" "$ROOT/.mcp.json")
SH_URL=$(sh "$ROOT/scripts/set-core-url.sh")
check ".mcp.json url == connect.sh CORE_URL" "$([ -n "$MCP_URL" ] && [ "$MCP_URL" = "$SH_URL" ] && echo yes || echo no)"
check ".mcp.json has exactly one server, named sc, type http, no headers and no secrets" "$(python3 -I - "$ROOT/.mcp.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
s = c.get("mcpServers") or {}
ok = list(s) == ["sc"] and s["sc"].get("type") == "http" and set(s["sc"]) == {"type", "url"}
print("yes" if ok else "no")
PY
)"
COPY="$SANDBOX/repo-copy"; mkdir -p "$COPY/scripts"; cp "$ROOT/.mcp.json" "$COPY/"; cp "$ROOT/scripts/connect.sh" "$ROOT/scripts/set-core-url.sh" "$COPY/scripts/"
sh "$COPY/scripts/set-core-url.sh" "https://trial.example.invalid/mcp" >/dev/null
check "set-core-url.sh rewrites connect.sh (on a copy)" "$([ "$(sh "$COPY/scripts/set-core-url.sh")" = "https://trial.example.invalid/mcp" ] && echo yes || echo no)"
check "set-core-url.sh rewrites .mcp.json to the same URL (on a copy)" "$([ "$(python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]))['mcpServers']['sc']['url'])" "$COPY/.mcp.json")" = "https://trial.example.invalid/mcp" ] && echo yes || echo no)"
check "set-core-url.sh sets CORE_URL_ALT to the same URL (on a copy)" "$([ "$(sed -n 's/^CORE_URL_ALT="\(.*\)"$/\1/p' "$COPY/scripts/connect.sh")" = "https://trial.example.invalid/mcp" ] && echo yes || echo no)"
check "set-core-url.sh refuses a URL that is not https://.../mcp" "$(sh "$COPY/scripts/set-core-url.sh" "http://evil.example/x" >/dev/null 2>&1 && echo no || echo yes)"
check "the real repo's URL is untouched" "$([ "$(sh "$ROOT/scripts/set-core-url.sh")" = "$SH_URL" ] && echo yes || echo no)"
# Release check: what main publishes points at production Core, never a trial or localhost URL left
# by set-core-url.sh. Other branches (a trial build) may point elsewhere, but only over https.
PROD_URL="https://deckhouse-489723-symmeno-core-mcp-svc-clfxlhbjsa-uc.a.run.app/mcp"
BRANCH=$(git -C "$ROOT" branch --show-current 2>/dev/null || echo "")
if [ "$BRANCH" = main ]; then
  check "release: main's .mcp.json URL is production Core" "$([ "$MCP_URL" = "$PROD_URL" ] && echo yes || echo no)"
else
  check "release: this branch's .mcp.json URL is https (branch: ${BRANCH:-none})" "$(case "$MCP_URL" in https://*/mcp) echo yes ;; *) echo no ;; esac)"
fi

# 11. The key never reaches a config, a settings file or any output.
leaks=$(grep -rl -- "$KEY_TEXT" "$SANDBOX" | grep -v "^$KEY\$" || true)
check "key text appears nowhere but the key file" "$([ -z "$leaks" ] && echo yes || echo no)"
[ -n "$leaks" ] && printf '  leaked into: %s\n' $leaks

printf '\n%d passed, %d failed  (sandbox: %s)\n' "$pass" "$fail" "$SANDBOX"
[ "$fail" -eq 0 ]
