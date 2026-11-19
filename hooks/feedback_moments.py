"""sc plugin hook: the feedback moments (sc 0.5.0, change 2026-11-18-feedback-ask-reflect).

Claude Code runs this through feedback-moments.sh (hooks/feedback-moments.json, named in .claude-plugin/plugin.json)
on UserPromptSubmit, SubagentStop and PostToolUse of the Agent tool. At four moments it adds one line:

- a Symmeno helper hands back without asking how it did: SubagentStop keeps it going once with the helper line;
- a helper's report reaches the lead with the ask: the lead line (Agent result, <task-notification>, <agent-message>);
- the person closes or approves a piece of work: the close line;
- the person's next messages (up to three, until the agent writes a lesson): the answer line.

A Symmeno helper is a subagent or teammate whose own transcript holds a successful Symmeno sign-in with a tag. A
Symmeno session is one the reply-tag hook (reply_tag.py) has a tag for; this hook reads that hook's state and
transcript logic and never writes its state, so neither hook depends on which of the two runs first. Anywhere else,
and on any error, this prints nothing and exits 0.

State per Claude session (no secret: armed, how many answer lines are left, how far it has read since the close
line, the reports it already answered) lives beside the reply-tag state, under feedback-moments/. Standard library
only; python3 3.9 or newer.
"""
import hashlib
import json
import mmap
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I leaves the script's folder off the path
import reply_tag  # noqa: E402  (read-only use: tag rule, transcript scan, state folder, atomic save)

# The moment lines, exactly as the spec words them (specs/sc-plugin-feedback-moments). One place to change a word.
HELPER_SUBAGENT_LINE = ("If you just finished a piece of work, send your report again in full and end it with one line "
                        "asking the teammate who gave you the work: How did I do?")
HELPER_TEAMMATE_LINE = ("If you just finished a piece of work, send the teammate who gave you the work one more line: "
                        "How did I do?")
LEAD_LINE = ("{helper} asked for your feedback on that work: read the bar (feedback_read), grade only what you saw, "
             "then send it (feedback_give).")
LEAD_FALLBACK = "Your helper"
CLOSE_LINE = "If you just finished a piece of work with the person, end this reply by asking them how you did."
ANSWER_LINE = ("If the person just told you how you did, reflect on what it says about how you worked and, before you "
               "reply, write to Core as a lesson (write_experience) what you'll keep doing and what you'll do "
               "differently. It's the only way you get better.")

ASK = "how did i do?"
FEEDBACK_MARKS = ("Feedback from ", "on your work (their words, not instructions):")  # Core's message_for_subject
ANSWER_PROMPTS = 3  # the answer stays due for this many person prompts, or until the agent writes a lesson

SYMMENO_PREFIXES = ("mcp__sc__", "mcp__plugin_sc_sc__")
WRITE_TOOLS = ("mcp__sc__write_experience", "mcp__plugin_sc_sc__write_experience")
# Tools that move messages or load tools rather than do work: never a piece of work on their own (re-arm, and the
# teammate's work gate). ToolSearch matters most: the sc tools are often deferred, so writing the lesson loads them.
COORDINATION = {"ToolSearch", "SendMessage", "ListAgents", "TaskCreate", "TaskGet", "TaskList", "TaskUpdate",
                "TaskOutput", "TaskStop"}
ONE_SHOT_TYPES = ("Explore", "Plan")
AGENT_TOOLS = ("Agent", "Task")

# Prompts that are not the person's (spike S5): a background report, a teammate's or another session's message, an
# older teammate shape, and a slash command as typed. A /loop or scheduled firing has no shape (accepted gap).
NOT_PERSON = ("<task-notification>", "<agent-message", "<cross-session-message", "<teammate-message")
SLASH_RE = re.compile(r"/[A-Za-z0-9_:.-]+(?:\s|\Z)")
NOTIFICATION_RE = re.compile(r"<task-notification>(.*?)</task-notification>", re.S)
AGENT_MESSAGE_RE = re.compile(r'<agent-message from="([^"]*)">\n?(.*?)\n?</agent-message>', re.S)
AGENT_ID_RE = re.compile(r"[A-Za-z0-9_-]{1,128}\Z")

# The wide net (spec table). Phrases are matched after the same normalising as the prompt.
ANYWHERE = (
    "thanks", "thank you", "thank u", "thx", "ty", "tysm", "cheers", "appreciate it", "appreciated", "looks good",
    "looks great", "lgtm", "ship it", "perfect", "that's it", "thats it", "that's all", "that is all", "that'll do",
    "that works", "works for me", "sounds good", "good night", "goodnight", "nite", "nice work", "nice job",
    "good job", "great job", "great work", "good work", "well done", "nailed it", "love it", "love this", "awesome",
    "excellent", "amazing", "beautiful", "brilliant", "fantastic", "wonderful", "approved", "good to go", "all good",
    "that's everything", "done for today", "done for the day", "done for tonight", "we're done", "all done",
    "signing off", "talk tomorrow", "see you tomorrow",
)
WHOLE_ONLY = ("ok", "okay", "k", "cool", "great", "nice", "good", "done", "bye", "night", "gn")
GREETINGS = ("hey", "hi", "hello", "yo", "morning", "good morning", "good afternoon", "good evening", "hey there",
             "hi there")

# Both sign-in tool names (reply_tag.TOOLS) end with this, as a JSON value: one search finds either.
SIGN_IN_MARK = b'sc__bootstrap"'
assert all(m.endswith(SIGN_IN_MARK) for m in reply_tag.MARKERS)

STATE_VERSION = 1
BUDGET_SECONDS = 0.6
MAX_LEAD_KEYS = 64
MAX_TRANSCRIPT_BYTES = 1 << 30


def norm(text):
    """Lowercase, curly apostrophes straight, punctuation as spaces, runs of spaces folded."""
    text = text.lower().replace("’", "'").replace("‘", "'").replace("ʼ", "'")
    return " ".join(re.sub(r"[^\w]|_", " ", text).split())


ANYWHERE_N = tuple(" %s " % norm(p) for p in ANYWHERE)
WHOLE_N = frozenset(norm(w) for w in WHOLE_ONLY)
GREETINGS_N = frozenset(norm(g) for g in GREETINGS)


def is_close(prompt):
    """The wide net: a close or approval, and never a greeting alone."""
    text = norm(prompt)
    if not text or text in GREETINGS_N:
        return False
    if text in WHOLE_N:
        return True
    padded = " %s " % text
    return any(p in padded for p in ANYWHERE_N)


def is_person(prompt):
    p = prompt.lstrip()
    return not p.startswith(NOT_PERSON) and not SLASH_RE.match(p)


def has_ask(text):
    return isinstance(text, str) and ASK in " ".join(text.lower().split())


def is_feedback(text):
    return isinstance(text, str) and all(m in text for m in FEEDBACK_MARKS)


def is_symmeno_tool(name):
    return isinstance(name, str) and name.startswith(SYMMENO_PREFIXES)


def is_work(name):
    return isinstance(name, str) and not is_symmeno_tool(name) and name not in COORDINATION


def name_of(tag):
    return tag[1:].split(" / ", 1)[0] if tag else None


def texts_of(content):
    if isinstance(content, str):
        return [content]
    if isinstance(content, list):
        return [b.get("text") for b in content if isinstance(b, dict) and b.get("type") == "text"
                and isinstance(b.get("text"), str)]
    return []


def lines_with(buf, needle, start=0, end=None, reverse=False):
    """(line start, line bytes) for each complete line of buf[start:end] that holds needle."""
    end = len(buf) if end is None else end
    if reverse:
        at = buf.rfind(needle, start, end)
        while at != -1:
            s = buf.rfind(b"\n", start, at) + 1
            e = buf.find(b"\n", at, end)
            if e != -1:
                yield s, buf[s:e]
            at = buf.rfind(needle, start, s) if s > start else -1
        return
    at = buf.find(needle, start, end)
    while at != -1:
        s = buf.rfind(b"\n", start, at) + 1
        e = buf.find(b"\n", at, end)
        if e == -1:
            return  # a last line still being written
        yield s, buf[s:e]
        at = buf.find(needle, e, end)


def entry(raw):
    try:
        e = json.loads(raw)
    except ValueError:
        return None
    return e if isinstance(e, dict) else None


def open_map(path):
    """The transcript mapped read-only, or None (missing, empty, too big, not a file)."""
    f = open(path, "rb")
    try:
        size = os.fstat(f.fileno()).st_size
        if size == 0 or size > MAX_TRANSCRIPT_BYTES:
            return None
        return mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    finally:
        f.close()


# ---------------------------------------------------------------------------------------------------------------
# A helper's own transcript
# ---------------------------------------------------------------------------------------------------------------

def helper_tag(buf, deadline):
    """The tag of the newest successful Symmeno sign-in in a helper's transcript (its lines are sidechain), or None."""
    calls = []
    for at, raw in lines_with(buf, SIGN_IN_MARK):  # one pass finds both tool names
        e = entry(raw)
        if not e or e.get("type") != "assistant" or not isinstance(e.get("message"), dict):
            continue
        for b in e["message"].get("content") or []:
            if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") in reply_tag.TOOLS \
                    and isinstance(b.get("id"), str) and b["id"]:
                calls.append((at, b["id"]))
        if time.monotonic() > deadline:
            return None
    for at, call in reversed(calls):
        for _, raw in lines_with(buf, call.encode(), at):
            e = entry(raw)
            if not e or e.get("type") != "user" or not isinstance(e.get("message"), dict):
                continue
            for b in e["message"].get("content") or []:
                if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("tool_use_id") == call \
                        and b.get("is_error") is not True:
                    tag = reply_tag.tag_in(b.get("content"))
                    if tag:
                        return tag
    return None


def run_start(buf, deadline):
    """(line start, entry) of the message that started the helper's current run: its newest prompt-like user line
    (the spawn prompt, a coordinator's or lead's message), not a tool result and not a stop hook's feedback."""
    for at, raw in lines_with(buf, b'"type":"user"', reverse=True):
        if time.monotonic() > deadline:
            return None
        e = entry(raw)
        if not e or e.get("type") != "user" or not isinstance(e.get("message"), dict):
            continue
        content = e["message"].get("content")
        if isinstance(content, list) and any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
            continue
        text = "\n".join(texts_of(content))
        if not text or text.startswith("Stop hook feedback:") or e.get("isCompactSummary") is True:
            continue
        return at, e
    return None


def tool_calls(buf, start):
    """(name, input) of each tool call after start, in order."""
    out = []
    for _, raw in lines_with(buf, b'"type":"tool_use"', start):
        e = entry(raw)
        if not e or e.get("type") != "assistant" or not isinstance(e.get("message"), dict):
            continue
        for b in e["message"].get("content") or []:
            if isinstance(b, dict) and b.get("type") == "tool_use":
                out.append((b.get("name"), b.get("input") if isinstance(b.get("input"), dict) else {}))
    return out


def helper(path, deadline, need_tag_only=False):
    """What the hooks need from a helper's transcript, or None when it is not a Symmeno helper (or unreadable)."""
    try:
        buf = open_map(path)
    except OSError:
        return None
    if buf is None:
        return None
    try:
        tag = helper_tag(buf, deadline)
        if not tag:
            return None
        info = {"tag": tag, "run_id": None, "run_text": None, "calls": []}
        start = run_start(buf, deadline)
        if start:
            at, e = start
            info["run_id"] = e.get("uuid") if isinstance(e.get("uuid"), str) else "@%d" % at
            info["run_text"] = "\n".join(texts_of(e["message"].get("content")))
            if not need_tag_only:
                info["calls"] = tool_calls(buf, at)
        return info
    finally:
        buf.close()


def is_teammate(agent_path, run_text):
    try:
        with open(agent_path[:-len(".jsonl")] + ".meta.json", encoding="utf-8") as f:
            meta = json.load(f)
        if isinstance(meta, dict) and "taskKind" in meta:
            return meta.get("taskKind") == "in_process_teammate"
    except (OSError, ValueError):
        pass
    return isinstance(run_text, str) and run_text.lstrip().startswith("<teammate-message")


def subagents_dir(transcript, session):
    return os.path.join(os.path.dirname(transcript), session, "subagents")


def agent_path_for(transcript, session, agent_id):
    if not isinstance(agent_id, str) or not AGENT_ID_RE.match(agent_id):
        return None
    return os.path.join(subagents_dir(transcript, session), "agent-%s.jsonl" % agent_id)


def agent_path_by_name(transcript, session, name):
    """The newest helper transcript whose meta names it `name` (a teammate's or a named agent's)."""
    folder = subagents_dir(transcript, session)
    best = None
    try:
        names = os.listdir(folder)
    except OSError:
        return None
    for fn in names:
        if not fn.endswith(".meta.json"):
            continue
        p = os.path.join(folder, fn)
        try:
            with open(p, encoding="utf-8") as f:
                meta = json.load(f)
            mtime = os.stat(p[:-len(".meta.json")] + ".jsonl").st_mtime
        except (OSError, ValueError):
            continue
        if isinstance(meta, dict) and meta.get("name") == name and (best is None or mtime > best[0]):
            best = (mtime, p[:-len(".meta.json")] + ".jsonl")
    return best[1] if best else None


# ---------------------------------------------------------------------------------------------------------------
# SubagentStop: the helper line
# ---------------------------------------------------------------------------------------------------------------

def on_subagent_stop(hook, deadline):
    if hook.get("stop_hook_active") is True or hook.get("agent_type") in ONE_SHOT_TYPES:
        return None
    path = hook.get("agent_transcript_path")
    if not isinstance(path, str) or not path:
        t, s = hook.get("transcript_path"), hook.get("session_id")
        path = agent_path_for(t, s, hook.get("agent_id")) if isinstance(t, str) and isinstance(s, str) else None
    if not path:
        return None
    path = os.path.expanduser(path)
    info = helper(path, deadline)
    if not info or info["run_text"] is None or is_feedback(info["run_text"]):
        return None
    calls = info["calls"]
    if is_teammate(path, info["run_text"]):
        # Ruling S4: a teammate is asked only after real work, and only if it hasn't asked since its last work.
        last_work = max((i for i, (name, _) in enumerate(calls) if is_work(name)), default=-1)
        if last_work == -1:
            return None
        if any(name == "SendMessage" and has_ask(args.get("message")) for name, args in calls[last_work + 1:]):
            return None
        return {"decision": "block", "reason": HELPER_TEAMMATE_LINE}
    handback = [args.get("message") for name, args in calls if name == "SubagentHandback"]
    report = handback[-1] if handback else hook.get("last_assistant_message")
    if has_ask(report):
        return None
    return {"decision": "block", "reason": HELPER_SUBAGENT_LINE}


# ---------------------------------------------------------------------------------------------------------------
# The lead's tag, and the moments state
# ---------------------------------------------------------------------------------------------------------------

def lead_tag(session, transcript, deadline):
    """The main conversation's tag, the way reply_tag.py finds it: its state plus whatever the transcript gained since
    (so it does not matter which hook ran first this turn). The reply-tag state is never written here."""
    path = os.path.join(reply_tag.state_dir(), session + ".json")
    st = reply_tag.load_state(path, session)
    if isinstance(transcript, str) and transcript:
        try:
            reply_tag.scan(os.path.expanduser(transcript), st, deadline)
        except Exception:
            pass
    return st.get("tag")


def moments_dir():
    return os.path.join(os.path.dirname(reply_tag.state_dir()), "feedback-moments")


def fresh_state(session):
    return {"v": STATE_VERSION, "session": session, "armed": True, "answer_left": 0, "mark": None, "work": False,
            "wrote": False, "lead_keys": []}


def load_state(path, session):
    try:
        with open(path, encoding="utf-8") as f:
            st = json.load(f)
    except (OSError, ValueError):
        return fresh_state(session)
    mark = st.get("mark") if isinstance(st, dict) else None
    ok = (isinstance(st, dict) and st.get("v") == STATE_VERSION and st.get("session") == session
          and isinstance(st.get("armed"), bool) and isinstance(st.get("work"), bool)
          and isinstance(st.get("wrote"), bool)
          and isinstance(st.get("answer_left"), int) and 0 <= st["answer_left"] <= ANSWER_PROMPTS
          and isinstance(st.get("lead_keys"), list) and all(isinstance(k, str) for k in st["lead_keys"])
          and (mark is None or (isinstance(mark, dict) and isinstance(mark.get("transcript"), str)
                                and isinstance(mark.get("ino"), int) and isinstance(mark.get("offset"), int)
                                and mark["offset"] >= 0)))
    return st if ok else fresh_state(session)


def save_state(session, st):
    sdir = moments_dir()
    reply_tag.save_state(sdir, os.path.join(sdir, session + ".json"), st)


def mark_here(transcript):
    """Where the transcript ends now (complete lines only): later tool calls come after the close line."""
    with open(transcript, "rb") as f:
        size = os.fstat(f.fileno()).st_size
        f.seek(max(0, size - 65536))
        tail = f.read()
        ino = os.fstat(f.fileno()).st_ino
    nl = tail.rfind(b"\n")
    return {"transcript": transcript, "ino": ino, "offset": size - len(tail) + (nl + 1 if nl != -1 else 0)}


def catch_up(st, transcript, deadline):
    """Read the main conversation's tool calls since the mark: any work re-arms later, a write_experience ends the
    answer window. A rewritten or other file tells nothing: the mark moves to its end."""
    mark = st.get("mark")
    if not mark:
        return
    try:
        info = os.stat(transcript)
    except OSError:
        return
    if mark["transcript"] != transcript or mark["ino"] != info.st_ino or info.st_size < mark["offset"]:
        st["mark"] = mark_here(transcript)
        return
    if info.st_size == mark["offset"]:
        return
    buf = open_map(transcript)
    if buf is None:
        return
    try:
        cut = buf.rfind(b"\n", mark["offset"]) + 1
        if cut <= mark["offset"]:
            return
        for s, raw in lines_with(buf, b'"type":"tool_use"', mark["offset"], cut):
            if time.monotonic() > deadline or (st["work"] and (st["wrote"] or not st["answer_left"])):
                mark["offset"] = s  # read from here next time (the flags already say what is needed)
                return
            e = entry(raw)
            if not e or e.get("isSidechain") is True or e.get("type") != "assistant" \
                    or not isinstance(e.get("message"), dict):
                continue
            for b in e["message"].get("content") or []:
                if isinstance(b, dict) and b.get("type") == "tool_use":
                    if b.get("name") in WRITE_TOOLS:
                        st["wrote"] = True
                    elif is_work(b.get("name")):
                        st["work"] = True
        mark["offset"] = cut
    finally:
        buf.close()


# ---------------------------------------------------------------------------------------------------------------
# The lead line
# ---------------------------------------------------------------------------------------------------------------

def lead_line_for(report, source_key, path, fallback_run_text, st, deadline):
    """The lead line for one report with the ask, or None (no ask, a feedback run, already answered)."""
    if not has_ask(report):
        return None
    info = helper(path, deadline, need_tag_only=True) if path else None
    run_text = info["run_text"] if info and info["run_text"] is not None else fallback_run_text
    if is_feedback(run_text):
        return None
    key = "%s:%s" % (os.path.basename(path or ""), info["run_id"]) if info and info["run_id"] else \
        "%s:%s" % (source_key, hashlib.sha256(report.encode("utf-8", "replace")).hexdigest()[:16])
    if key in st["lead_keys"]:
        return None
    st["lead_keys"] = (st["lead_keys"] + [key])[-MAX_LEAD_KEYS:]
    return LEAD_LINE.format(helper=name_of(info["tag"]) if info else LEAD_FALLBACK)


def reports_in(prompt):
    """(report, kind, who) for each background report (kind task, who = its task id) or teammate message (kind msg,
    who = the sender's name) in a prompt."""
    out = []
    p = prompt.lstrip()
    if p.startswith("<task-notification>"):
        for body in NOTIFICATION_RE.findall(p):
            task = re.search(r"<task-id>([^<]*)</task-id>", body)
            result = re.search(r"<result>(.*?)</result>", body, re.S)
            if task and result:
                out.append((result.group(1), "task", task.group(1).strip()))
    elif p.startswith("<agent-message"):
        for name, body in AGENT_MESSAGE_RE.findall(p):
            out.append((body, "msg", name))
    return out


def on_post_tool_use(hook, deadline):
    if hook.get("tool_name") not in AGENT_TOOLS or hook.get("agent_id"):
        return None  # the lead line is for the main conversation's own helpers
    resp = hook.get("tool_response")
    if not isinstance(resp, dict) or resp.get("status") != "completed":
        return None  # a background launch reports later, by <task-notification>
    report = "\n".join(texts_of(resp.get("content")))
    if not has_ask(report):
        return None
    session, transcript = hook.get("session_id"), hook.get("transcript_path")
    if not lead_tag(session, transcript, deadline):
        return None
    st = load_state(os.path.join(moments_dir(), session + ".json"), session)
    tool_input = hook.get("tool_input") if isinstance(hook.get("tool_input"), dict) else {}
    path = agent_path_for(os.path.expanduser(transcript), session, resp.get("agentId")) if transcript else None
    line = lead_line_for(report, "agent:%s" % hook.get("tool_use_id"), path, tool_input.get("prompt"), st, deadline)
    if line:
        save_state(session, st)
        return context("PostToolUse", line)
    return None


# ---------------------------------------------------------------------------------------------------------------
# UserPromptSubmit: the lead line on a report, or the close and answer lines on the person's prompt
# ---------------------------------------------------------------------------------------------------------------

def on_prompt(hook, deadline):
    prompt, session, transcript = hook.get("prompt"), hook.get("session_id"), hook.get("transcript_path")
    if not isinstance(prompt, str) or not isinstance(transcript, str) or not transcript:
        return None
    transcript = os.path.expanduser(transcript)
    path = os.path.join(moments_dir(), session + ".json")
    if not is_person(prompt):
        reports = [r for r in reports_in(prompt) if has_ask(r[0])]
        if not reports or not lead_tag(session, transcript, deadline):
            return None
        st = load_state(path, session)
        lines = []
        for report, kind, who in reports:
            helper_path = agent_path_for(transcript, session, who) if kind == "task" else \
                agent_path_by_name(transcript, session, who)
            line = lead_line_for(report, "%s:%s" % (kind, who), helper_path, None, st, deadline)
            if line:
                lines.append(line)
        if not lines:
            return None
        save_state(session, st)
        return context("UserPromptSubmit", "\n".join(lines))
    st = load_state(path, session)
    close = is_close(prompt)
    if not st["answer_left"] and not close:
        return None  # nothing could fire on this prompt: no reads, no writes
    if not lead_tag(session, transcript, deadline):
        return None
    catch_up(st, transcript, deadline)
    if st["wrote"]:
        st["answer_left"] = 0
    if not st["armed"] and not st["answer_left"] and st["work"]:
        st["armed"] = True
    line = None
    if st["answer_left"]:
        st["answer_left"] -= 1
        line = ANSWER_LINE
    elif st["armed"] and close:
        st.update(armed=False, answer_left=ANSWER_PROMPTS, work=False, wrote=False, mark=mark_here(transcript))
        line = CLOSE_LINE
    save_state(session, st)
    return context("UserPromptSubmit", line) if line else None


def context(event, text):
    return {"hookSpecificOutput": {"hookEventName": event, "additionalContext": text}}


def main():
    hook = json.loads(sys.stdin.read())
    if not isinstance(hook, dict):
        return
    session = hook.get("session_id")
    if not isinstance(session, str) or not reply_tag.SESSION_RE.match(session):
        return
    deadline = time.monotonic() + BUDGET_SECONDS
    event = hook.get("hook_event_name")
    if event == "SubagentStop":
        out = on_subagent_stop(hook, deadline)
    elif event == "PostToolUse":
        out = on_post_tool_use(hook, deadline)
    elif event == "UserPromptSubmit":
        out = on_prompt(hook, deadline)
    else:
        return
    if out:
        sys.stdout.write(json.dumps(out) + "\n")


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        pass  # never a word to the person, never a failed hook
    sys.exit(0)
