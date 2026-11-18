"""sc plugin hook: restate the Symmeno agent's reply tag on each of the person's turns.

Claude Code runs this through reply-tag.sh on UserPromptSubmit, and on SessionStart after a compaction or a resume
(hooks.json). In a Symmeno session it adds one line to the agent's context:

    Start every reply to the person with your tag, as its very first characters: [Theo / Coach]

A Symmeno session is one whose transcript holds a successful result of mcp__sc__bootstrap or
mcp__plugin_sc_sc__bootstrap (a sign-in or a resume) that carries a `tag` field. The tag is the `tag` of the most
recent such result in the main conversation, exactly as Symmeno Core sent it: this never builds a tag from a name
and a role. A helper's own sign-in (a subagent's lines) never changes it. Anywhere else, and on any error, this prints
nothing and exits 0.

Speed and survival: a small state file per Claude session (no secret: the tag, how far into the transcript it has
read, and the ids of bootstrap calls still waiting for their result) means each run reads only what the transcript
gained since the last one, and the tag stays known after a compaction, a resume, or a transcript that no longer holds
the bootstrap. Without the state file it reads the transcript again from the start. A read looks only at lines that
name the bootstrap tool or carry a pending call id, and stops at a time budget, carrying on next turn.

The state lives in the plugin's data folder (CLAUDE_PLUGIN_DATA) or, without one,
<Claude config folder>/plugins/data/sc-symmeno, under reply-tag/. Standard library only; python3 3.9 or newer.
"""
import json
import os
import re
import sys
import time

TOOLS = ("mcp__sc__bootstrap", "mcp__plugin_sc_sc__bootstrap")
# A tool name as a JSON value ends in a quote; inside a JSON string (a prompt that names the tool) it would be \".
MARKERS = tuple((name + '"').encode() for name in TOOLS)
TAG_LINE = "Start every reply to the person with your tag, as its very first characters: {tag}"
# Core's tag: [<name> / <short role>], one line, no brackets inside.
TAG_RE = re.compile(r"\[[^\[\]\x00-\x1f\x7f]{1,80} / [^\[\]\x00-\x1f\x7f]{1,80}\]\Z")
SESSION_RE = re.compile(r"[A-Za-z0-9_-]{1,128}\Z")
STATE_VERSION = 1
BUDGET_SECONDS = 0.6
CHUNK_BYTES = 8 << 20
MAX_PENDING = 32
PRUNE_AFTER_SECONDS = 14 * 86400
PRUNE_EVERY_SECONDS = 86400


def state_dir():
    base = os.environ.get("CLAUDE_PLUGIN_DATA") or ""
    if not os.path.isabs(base):
        config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
        base = os.path.join(os.path.expanduser(config), "plugins", "data", "sc-symmeno")
    return os.path.join(base, "reply-tag")


def fresh_state(session):
    return {"v": STATE_VERSION, "session": session, "transcript": None, "ino": None, "offset": 0, "pending": [],
            "tag": None}


def load_state(path, session):
    try:
        with open(path, encoding="utf-8") as f:
            st = json.load(f)
    except (OSError, ValueError):
        return fresh_state(session)
    ok = (isinstance(st, dict) and st.get("v") == STATE_VERSION and st.get("session") == session
          and isinstance(st.get("offset"), int) and st["offset"] >= 0
          and isinstance(st.get("pending"), list) and all(isinstance(p, str) for p in st["pending"])
          and (st.get("tag") is None or (isinstance(st["tag"], str) and TAG_RE.match(st["tag"])))
          and (st.get("transcript") is None or isinstance(st["transcript"], str))
          and (st.get("ino") is None or isinstance(st["ino"], int)))
    return st if ok else fresh_state(session)


def save_state(sdir, path, st):
    os.makedirs(sdir, mode=0o700, exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(st, f, separators=(",", ":"))
    os.replace(tmp, path)
    prune(sdir)


def prune(sdir):
    """At most once a day, remove state files of sessions untouched for two weeks."""
    mark = os.path.join(sdir, ".pruned")
    now = time.time()
    try:
        if now - os.stat(mark).st_mtime < PRUNE_EVERY_SECONDS:
            return
    except OSError:
        pass
    with open(mark, "w"):
        pass
    for name in os.listdir(sdir):
        p = os.path.join(sdir, name)
        if name.endswith((".json", ".tmp")):
            try:
                if now - os.stat(p).st_mtime > PRUNE_AFTER_SECONDS:
                    os.remove(p)
            except OSError:
                pass


def tag_in(content):
    """The `tag` of a bootstrap result's content (Core's JSON in a text part), or None."""
    if isinstance(content, str):
        texts = [content]
    elif isinstance(content, list):
        texts = [part.get("text") for part in content if isinstance(part, dict) and part.get("type") == "text"]
    else:
        return None
    for text in texts:
        if not isinstance(text, str):
            continue
        try:
            result = json.loads(text)
        except ValueError:
            continue
        tag = result.get("tag") if isinstance(result, dict) else None
        if isinstance(tag, str) and TAG_RE.match(tag):
            return tag
    return None


def read_line(raw, st):
    """One transcript line: register a bootstrap call, or take the tag from its result."""
    try:
        entry = json.loads(raw)
    except ValueError:
        return
    if not isinstance(entry, dict) or entry.get("isSidechain") is True:
        return  # a helper's own lines (older Claude Code kept them in the lead's file)
    kind, message = entry.get("type"), entry.get("message")
    if kind not in ("assistant", "user") or not isinstance(message, dict):
        return  # request snapshots, attachments, progress and summaries are not the conversation's own calls
    content = message.get("content")
    if not isinstance(content, list):
        return
    for block in content:
        if not isinstance(block, dict):
            continue
        if kind == "assistant" and block.get("type") == "tool_use" and block.get("name") in TOOLS:
            call = block.get("id")
            if isinstance(call, str) and call and call not in st["pending"]:
                st["pending"] = (st["pending"] + [call])[-MAX_PENDING:]
        elif kind == "user" and block.get("type") == "tool_result" and block.get("tool_use_id") in st["pending"]:
            st["pending"] = [p for p in st["pending"] if p != block["tool_use_id"]]
            if block.get("is_error") is not True:
                tag = tag_in(block.get("content"))
                if tag:
                    st["tag"] = tag


def read_chunk(data, st, deadline):
    """Read the complete lines in data (it ends with a newline); return how many bytes were read."""
    needles = {m: data.find(m) for m in MARKERS}
    for call in st["pending"]:
        needles[call.encode()] = data.find(call.encode())
    while True:
        hits = [at for at in needles.values() if at != -1]
        if not hits:
            return len(data)
        at = min(hits)
        start = data.rfind(b"\n", 0, at) + 1
        end = data.find(b"\n", at)
        if time.monotonic() > deadline:
            return start
        read_line(data[start:end], st)
        for needle, pos in list(needles.items()):
            if needle not in MARKERS and needle.decode() not in st["pending"]:
                del needles[needle]  # its result is in
            elif pos != -1 and pos < end:
                needles[needle] = data.find(needle, end)
        for call in st["pending"]:
            if call.encode() not in needles:
                needles[call.encode()] = data.find(call.encode(), end)


def scan(transcript, st, deadline):
    info = os.stat(transcript)
    if st["transcript"] != transcript or st["ino"] != info.st_ino or info.st_size < st["offset"]:
        # Another or a rewritten file: read it from the start. A tag already found stays until a newer one.
        st.update(transcript=transcript, ino=info.st_ino, offset=0, pending=[])
    if info.st_size == st["offset"]:
        return
    with open(transcript, "rb") as f:
        f.seek(st["offset"])
        carry = b""
        while time.monotonic() <= deadline:
            buf = f.read(CHUNK_BYTES)
            if not buf:
                return
            data = carry + buf
            cut = data.rfind(b"\n") + 1  # a last line still being written waits for the next run
            done = read_chunk(data[:cut], st, deadline) if cut else 0
            st["offset"] += done
            if done < cut:
                return  # out of time
            carry = data[cut:]


def main():
    hook = json.loads(sys.stdin.read())
    if not isinstance(hook, dict):
        return
    event = hook.get("hook_event_name")
    if event == "SessionStart":
        if hook.get("source") not in ("compact", "resume"):
            return
    elif event != "UserPromptSubmit":
        return
    session, transcript = hook.get("session_id"), hook.get("transcript_path")
    if not isinstance(session, str) or not SESSION_RE.match(session):
        return
    deadline = time.monotonic() + BUDGET_SECONDS
    sdir = state_dir()
    path = os.path.join(sdir, session + ".json")
    st = load_state(path, session)
    before = json.dumps(st, sort_keys=True)
    if isinstance(transcript, str) and transcript:
        try:
            scan(os.path.expanduser(transcript), st, deadline)
        except Exception:
            st = json.loads(before)  # an unreadable transcript changes nothing
    if json.dumps(st, sort_keys=True) != before:
        try:
            save_state(sdir, path, st)
        except Exception:
            pass  # no state this time: the next run reads again
    if st["tag"]:
        out = {"hookSpecificOutput": {"hookEventName": event, "additionalContext": TAG_LINE.format(tag=st["tag"])}}
        sys.stdout.write(json.dumps(out) + "\n")


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        pass  # never a word to the person, never a failed hook
    sys.exit(0)
