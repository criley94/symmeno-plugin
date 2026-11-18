#!/bin/sh
# Opt-in live check of the reply-tag hook in real Claude Code (tests/reply_tag_test.py is the full, offline suite).
#
# Loads this checkout with --plugin-dir (nothing is installed, no setting changes) and a stand-in `sc` server
# (tests/fake_sc_server.py: one `bootstrap` tool that answers with a tag; it reaches nothing). Three headless turns
# on a cheap model, a few cents in all:
#   1. a turn that calls bootstrap: the hook adds nothing yet (the tag arrives during the turn);
#   2. the same session resumed: the SessionStart and UserPromptSubmit hooks each add the tag line;
#   3. a fresh session that never signs in: no hook context and no hook error.
# Each session leaves its transcript in Claude Code's projects folder, as any session does; the plugin's data
# folder gets a sc-inline/reply-tag/ state file per session. The script prints both places at the end.
#
# Usage: sh tests/reply-tag-live.sh [scratch-dir] [model]    (exit 0 when every check passes; model default haiku)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
W=${1:-$(mktemp -d)}
W=$(cd "$W" && pwd -P)
MODEL=${2:-haiku}
TAG="[Theo / Coach]"
mkdir -p "$W/signed-in" "$W/plain"
printf '{"mcpServers": {"sc": {"type": "stdio", "command": "python3", "args": ["-I", "%s/tests/fake_sc_server.py"]}}}\n' \
  "$ROOT" > "$W/mcp.json"

pass=0; fail=0
check() { if [ "$2" = yes ]; then pass=$((pass + 1)); printf 'ok   %s\n' "$1"; else fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; fi; }

# cc <dir> <out> <prompt> [claude args...]: one headless turn, with this session's own Claude Code variables
# cleared. The prompt goes right after -p: --allowedTools and --mcp-config take several values and would swallow it.
cc() {
  d=$1; out=$2; prompt=$3; shift 3
  (cd "$d" && env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_PID \
      -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_ENTRYPOINT \
      claude -p "$prompt" --model "$MODEL" --setting-sources project,local --plugin-dir "$ROOT" --output-format json \
      "$@") > "$W/$out.json" 2> "$W/$out.err"
}
field() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]) or "")' "$W/$1.json" "$2" 2>/dev/null; }
transcript() { ls "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/*/"$1".jsonl 2>/dev/null | head -1; }
# hook_lines <transcript> <event>: how many hook_additional_context entries for that event carry exactly the tag line
hook_lines() {
  python3 -I - "$1" "$2" "$TAG" <<'PY'
import json, sys
path, event, tag = sys.argv[1:4]
want = ["Start every reply to the person with your tag, as its very first characters: " + tag]
n = 0
for line in open(path, encoding="utf-8"):
    a = json.loads(line).get("attachment") or {}
    if a.get("type") == "hook_additional_context" and a.get("hookEvent") == event and a.get("content") == want:
        n += 1
print(n)
PY
}
hook_noise() { grep -c '"type":"hook_\(additional_context\|error\|non_blocking_error\|blocking_error\)"' "$1"; }

cc "$W/signed-in" turn1 'Call the mcp__sc__bootstrap tool with agent "theo-coach". Then reply with only the word done.' \
  --allowedTools mcp__sc__bootstrap --strict-mcp-config --mcp-config "$W/mcp.json"
SID=$(field turn1 session_id)
check "turn 1 ran (session ${SID:-none})" "$([ -n "$SID" ] && echo yes || echo no)"
T=$(transcript "$SID")
check "turn 1: the bootstrap result carries the tag" "$(grep -q 'tag\\": \\"\[Theo / Coach\]' "$T" 2>/dev/null && echo yes || echo no)"
check "turn 1: no hook context yet (the tag came during the turn)" "$([ -n "$T" ] && [ "$(hook_noise "$T")" = 0 ] && echo yes || echo no)"

cc "$W/signed-in" turn2 'What is the capital of France? One short sentence.' \
  --allowedTools mcp__sc__bootstrap --strict-mcp-config --mcp-config "$W/mcp.json" --resume "$SID"
check "turn 2 resumed the same session" "$([ -n "$SID" ] && [ "$(field turn2 session_id)" = "$SID" ] && echo yes || echo no)"
check "turn 2: SessionStart (resume) added the tag line once" "$([ "$(hook_lines "$T" SessionStart)" = 1 ] && echo yes || echo no)"
check "turn 2: UserPromptSubmit added the tag line once" "$([ "$(hook_lines "$T" UserPromptSubmit)" = 1 ] && echo yes || echo no)"
R2=$(field turn2 result)
printf '     turn 2 reply: %s\n' "$R2"
check "turn 2: the reply starts with the tag" "$(case $R2 in "$TAG"*) echo yes ;; *) echo no ;; esac)"

cc "$W/plain" plain 'Say hi in two words.' --strict-mcp-config
P=$(transcript "$(field plain session_id)")
check "plain session: no hook context and no hook error" "$([ -n "$P" ] && [ "$(hook_noise "$P")" = 0 ] && echo yes || echo no)"

printf '\ntranscripts: %s\n             %s\n' "${T:-?}" "${P:-?}"
printf 'hook state:  %s/plugins/data/sc-inline/reply-tag/\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
