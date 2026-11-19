#!/bin/sh
# Opt-in live check of the feedback-moments hook in real Claude Code (tests/feedback_moments_test.py is the full,
# offline suite).
#
# Loads this checkout with --plugin-dir (nothing is installed, no setting changes) and a stand-in `sc` server
# (tests/fake_sc_crew_server.py: `bootstrap` with a tag per test agent, and `write_experience`; it reaches nothing).
# Four headless turns on a cheap model, a few cents in all:
#   1. Theo signs in and hands Priya (a signed-in foreground helper) a one-line job; she answers without asking, the
#      helper line keeps her going once, her report to Theo ends with the ask, and Theo gets the lead line;
#   2. the same session resumed: "Thanks, that's all for today." gets the tag line and the close line;
#   3. resumed again: the person's answer gets the answer line (and the stand-in logs whether a lesson was written);
#   4. a fresh session that never signs in: "thanks" and a helper, no hook context and no hook error.
# Each session leaves its transcript in Claude Code's projects folder, as any session does.
#
# Usage: sh tests/feedback-moments-live.sh [scratch-dir] [model]    (exit 0 when every check passes; default haiku)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
W=${1:-$(mktemp -d)}
W=$(cd "$W" && pwd -P)
MODEL=${2:-haiku}
mkdir -p "$W/signed-in" "$W/plain"
LOG="$W/sc-calls.jsonl"
printf '{"mcpServers": {"sc": {"type": "stdio", "command": "python3", "args": ["-I", "%s/tests/fake_sc_crew_server.py"], "env": {"SC_FAKE_LOG": "%s"}}}}\n' \
  "$ROOT" "$LOG" > "$W/mcp.json"
TOOLS="Agent ToolSearch mcp__sc__bootstrap mcp__sc__write_experience"

pass=0; fail=0
check() { if [ "$2" = yes ]; then pass=$((pass + 1)); printf 'ok   %s\n' "$1"; else fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; fi; }
note() { printf '     %s\n' "$1"; }

cc() {
  d=$1; out=$2; prompt=$3; shift 3
  (cd "$d" && env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_PID \
      -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_ENTRYPOINT \
      -u CLAUDE_CODE_SESSION_ATTENDED \
      claude -p "$prompt" --model "$MODEL" --setting-sources project,local --plugin-dir "$ROOT" --output-format json \
      "$@") > "$W/$out.json" 2> "$W/$out.err" < /dev/null
}
field() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]) or "")' "$W/$1.json" "$2" 2>/dev/null; }
transcript() { ls "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/*/"$1".jsonl 2>/dev/null | head -1; }
# ctx <transcript> <event> <text>: how many hook_additional_context entries for that event hold exactly that line
ctx() {
  python3 -I - "$1" "$2" "$3" <<'PY'
import json, sys
path, event, text = sys.argv[1:4]
n = 0
for line in open(path, encoding="utf-8"):
    a = json.loads(line).get("attachment") or {}
    if a.get("type") == "hook_additional_context" and a.get("hookEvent") == event and text in (a.get("content") or []):
        n += 1
print(n)
PY
}
noise() { grep -c '"type":"hook_\(additional_context\|error\|non_blocking_error\)"' "$1"; }

SUB="If you just finished a piece of work, send your report again in full and end it with one line asking the teammate who gave you the work: How did I do?"
LEAD="Priya asked for your feedback on that work: read the bar (feedback_read), grade only what you saw, then send it (feedback_give)."
CLOSE="If you just finished a piece of work with the person, end this reply by asking them how you did."
ANSWER="If the person just told you how you did, reflect on what it says about how you worked and, before you reply, write to Core as a lesson (write_experience) what you'll keep doing and what you'll do differently. It's the only way you get better."
TAGLINE="Start every reply to the person with your tag, as its very first characters: [Theo / Coach]"

cc "$W/signed-in" turn1 'Call the mcp__sc__bootstrap tool with agent "theo-coach". Then use the Agent tool once with run_in_background set to false, subagent_type "general-purpose", description "priya", and this prompt: "Call the mcp__sc__bootstrap tool with agent priya-analyst. Then reply with exactly one line: REPORT: the sky is blue." When it returns, reply with only the word done.' \
  --allowedTools $TOOLS --strict-mcp-config --mcp-config "$W/mcp.json"
SID=$(field turn1 session_id)
check "turn 1 ran (session ${SID:-none})" "$([ -n "$SID" ] && echo yes || echo no)"
T=$(transcript "$SID")
H=$(ls "$(dirname "$T")/$SID/subagents/"agent-*.jsonl 2>/dev/null | head -1)
check "turn 1: the helper was kept going once with the helper line" "$([ -n "$H" ] && [ "$(grep -c 'Stop hook feedback:\\n'"$SUB" "$H")" = 1 ] && echo yes || echo no)"
FG=$( [ -n "$T" ] && ctx "$T" PostToolUse "$LEAD" || echo 0); BG=$( [ -n "$T" ] && ctx "$T" UserPromptSubmit "$LEAD" || echo 0)
check "turn 1: Theo got the lead line once" "$([ $((FG + BG)) = 1 ] && echo yes || echo no)"
note "lead line on the Agent result (foreground): $FG; on the <task-notification> (background): $BG"

cc "$W/signed-in" turn2 "Thanks, that's all for today." --resume "$SID" --allowedTools $TOOLS --strict-mcp-config --mcp-config "$W/mcp.json"
check "turn 2 resumed the same session" "$([ -n "$SID" ] && [ "$(field turn2 session_id)" = "$SID" ] && echo yes || echo no)"
check "turn 2: the tag line and the close line" "$([ "$(ctx "$T" UserPromptSubmit "$TAGLINE")" -ge 1 ] && [ "$(ctx "$T" UserPromptSubmit "$CLOSE")" = 1 ] && echo yes || echo no)"
note "turn 2 reply: $(field turn2 result)"

cc "$W/signed-in" turn3 'Clear, but too long. Shorter next time.' --resume "$SID" --allowedTools $TOOLS --strict-mcp-config --mcp-config "$W/mcp.json"
check "turn 3: the answer line, and the close line still once" "$([ "$(ctx "$T" UserPromptSubmit "$ANSWER")" = 1 ] && [ "$(ctx "$T" UserPromptSubmit "$CLOSE")" = 1 ] && echo yes || echo no)"
note "turn 3 reply: $(field turn3 result)"
note "lesson written by theo-coach: $(grep -c '"tool": "write_experience".*"agent": "theo-coach"' "$LOG" 2>/dev/null || echo 0) (model behavior, recorded, not checked)"

cc "$W/plain" plain 'thanks. Then use the Agent tool once, in the foreground, subagent_type "general-purpose", prompt "Reply with the word hi." Then reply with only the word done.' \
  --allowedTools Agent --strict-mcp-config
P=$(transcript "$(field plain session_id)")
check "plain session: no hook context and no hook error" "$([ -n "$P" ] && [ "$(noise "$P")" = 0 ] && echo yes || echo no)"

printf '\ntranscripts: %s\n             %s\n' "${T:-?}" "${P:-?}"
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
