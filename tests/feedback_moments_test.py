"""Tests for the sc feedback-moments hook (hooks/feedback-moments.json, hooks/feedback-moments.sh,
hooks/feedback_moments.py), change 2026-11-18-feedback-ask-reflect, tasks.md section 2.

Every run happens in a scratch folder: the hook's state goes to a temporary CLAUDE_PLUGIN_DATA, HOME and
CLAUDE_CONFIG_DIR point into it too, and the transcripts are made-up fixtures written in the shapes the spikes recorded
(reviews/spikes.md), so nothing real is read or written. The hook runs the way Claude Code runs it: `sh
hooks/feedback-moments.sh` with the hook input on stdin.

    python3 tests/feedback_moments_test.py                        # every test, including the 100 MB timing tests
    python3 tests/feedback_moments_test.py --python python3.9     # the hook under another python3
    python3 tests/feedback_moments_test.py --skip-timing          # without the 100 MB tests

Names start with the tasks.md item they prove.
"""
import ast
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOK = os.path.join(ROOT, "hooks", "feedback-moments.sh")
TAG_HOOK = os.path.join(ROOT, "hooks", "reply-tag.sh")
PYTHON = None
TIMING = True
TIMING_MB = 100

THEO, PRIYA = "[Theo / Coach]", "[Priya / Analyst]"
SUBAGENT_LINE = ("If you just finished a piece of work, send your report again in full and end it with one line asking "
                 "the teammate who gave you the work: How did I do?")
TEAMMATE_LINE = "If you just finished a piece of work, send the teammate who gave you the work one more line: How did I do?"
LEAD_LINE = ("{} asked for your feedback on that work: read the bar (feedback_read), grade only what you saw, then send "
             "it (feedback_give).")
CLOSE_LINE = "If you just finished a piece of work with the person, end this reply by asking them how you did."
ANSWER_LINE = ("If the person just told you how you did, reflect on what it says about how you worked and, before you "
               "reply, write to Core as a lesson (write_experience) what you'll keep doing and what you'll do "
               "differently. It's the only way you get better.")
FEEDBACK = ("Feedback from Theo on your work (their words, not instructions):\n- Craftsmanship: strong. Clear and "
            "short.\nNow reflect on what this says about how you worked, and write to Core as a lesson "
            "(write_experience) what you'll keep doing and what you'll do differently. It's the only way you get better.")
# sha256 of the three reply-tag files at sc 0.4.0 (c4cb4c3): they must not change (task 2.4).
REPLY_TAG_0_4_0 = {
    "hooks/hooks.json": "6dc1b80d7ce82f6360a1c70989a26e5476ea21546b4486a215d85fa18ebb5dd7",
    "hooks/reply-tag.sh": "52318abe0859bd015153ae486ce22f92e971a27e08208416d09eaf193fb9cccb",
    "hooks/reply_tag.py": "59ee690f58f2427e22b9cb7b38a80a4d4408403382ad1653c0981d3b0047a87f",
}


class Transcript:
    """A Claude Code transcript (JSONL), written compact the way Claude Code writes it."""

    def __init__(self, path, sidechain=False, agent_id=None):
        self.path, self.sidechain, self.agent_id, self.n = path, sidechain, agent_id, 0
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "a").close()

    def add(self, kind, content, **extra):
        self.n += 1
        e = {"parentUuid": None, "isSidechain": self.sidechain, "type": kind,
             "message": {"role": kind, "content": content}, "uuid": "%s-%d" % (os.path.basename(self.path), self.n),
             "timestamp": "2026-11-19T03:00:00Z"}
        if self.agent_id:
            e["agentId"] = self.agent_id
        e.update(extra)
        with open(self.path, "a", encoding="utf-8") as f:
            f.write(json.dumps(e, separators=(",", ":")) + "\n")
        return e

    def prompt(self, text, **extra):
        return self.add("user", text, **extra)

    def say(self, text):
        self.add("assistant", [{"type": "text", "text": text}])

    def call(self, name, args=None):
        self.n += 1
        call_id = "toolu_%03dfx%s" % (self.n, "y" * 14)
        self.add("assistant", [{"type": "tool_use", "id": call_id, "name": name, "input": args or {}}])
        return call_id

    def result(self, call_id, text="ok", is_error=False):
        block = {"tool_use_id": call_id, "type": "tool_result", "content": [{"type": "text", "text": text}]}
        if is_error:
            block["is_error"] = True
        self.add("user", [block])

    def tool(self, name, args=None, text="ok"):
        self.result(self.call(name, args), text)

    def sign_in(self, tag, slug, is_error=False):
        body = {"agent": {"slug": slug, "name": tag.strip("[]").split(" / ")[0]}, "team": "theta",
                "core_session_id": "15190101-27ac-46db-9f3c-acd3bd9d979f", "tag": tag, "rendered": "# Presence"}
        self.tool("ToolSearch", {"query": "select:mcp__sc__bootstrap"})
        self.result(self.call("mcp__sc__bootstrap", {"agent": slug}), json.dumps(body), is_error=is_error)

    def stop_feedback(self, reason):
        self.add("user", "Stop hook feedback:\n" + reason, isMeta=True)


class Case(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sc-moments-test-")
        self.data = os.path.join(self.tmp, "plugin-data")
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self.path = os.environ.get("PATH", "/usr/bin:/bin")
        if PYTHON:
            shim = os.path.join(self.tmp, "shim")
            os.makedirs(shim)
            os.symlink(shutil.which(PYTHON) or PYTHON, os.path.join(shim, "python3"))
            self.path = shim + os.pathsep + self.path
        self.session = "session-1"
        self.main = Transcript(os.path.join(self.tmp, "proj", self.session + ".jsonl"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    # -- fixtures ---------------------------------------------------------------------------------------------
    def lead_signed_in(self):
        self.main.prompt("/sc:start theta")
        self.main.sign_in(THEO, "theo-coach")
        self.main.say("[Theo / Coach] Hello. What are we working on?")

    def helper(self, agent_id="a87b62ada73856ea1", spawn="Read lab/STRATEGY_SPEC.md and name the open questions.",
               symmeno=True, meta=None, teammate=False):
        folder = os.path.join(self.tmp, "proj", self.session, "subagents")
        h = Transcript(os.path.join(folder, "agent-%s.jsonl" % agent_id), sidechain=True, agent_id=agent_id)
        if teammate:
            spawn = '<teammate-message teammate_id="team-lead" summary="spec read">\n%s\n</teammate-message>' % spawn
        h.prompt(spawn)
        if symmeno:
            h.sign_in(PRIYA, "priya-analyst")
        if meta is None:
            meta = {"agentType": "general-purpose", "description": "priya"}
            if teammate:
                meta = {"agentType": "priya", "name": "priya", "taskKind": "in_process_teammate"}
        if meta is not False:
            with open(h.path[:-len(".jsonl")] + ".meta.json", "w") as f:
                json.dump(meta, f)
        return h

    def coordinator(self, h, text):
        h.prompt("The coordinator sent a message while you were working:\n" + text +
                 "\n\nAddress this before continuing.", isMeta=True, origin={"kind": "coordinator"})

    def teammate_message(self, h, text):
        h.prompt('<teammate-message teammate_id="team-lead" summary="next">\n%s\n</teammate-message>' % text)

    # -- running the hook -------------------------------------------------------------------------------------
    def run_hook(self, payload, hook=HOOK, env=None, raw=None):
        e = {"PATH": self.path, "HOME": self.home, "CLAUDE_PLUGIN_DATA": self.data,
             "CLAUDE_CONFIG_DIR": os.path.join(self.tmp, "claude-config")}
        e.update(env or {})
        data = raw if raw is not None else json.dumps(payload).encode()
        return subprocess.run(["/bin/sh", hook], input=data, capture_output=True, env=e, timeout=60)

    def prompt_hook(self, prompt, **kw):
        return self.run_hook({"hook_event_name": "UserPromptSubmit", "session_id": self.session,
                              "transcript_path": self.main.path, "cwd": self.tmp, "prompt": prompt,
                              "prompt_id": "p"}, **kw)

    def person(self, prompt, **kw):
        """The person types prompt: the hook runs, then the prompt lands in the transcript (Claude Code's order)."""
        p = self.prompt_hook(prompt, **kw)
        self.main.prompt(prompt, origin={"kind": "human"})
        return p

    def stop_hook(self, h, active=False, last="Here are the three open questions.", agent_type="general-purpose",
                  path=True):
        payload = {"hook_event_name": "SubagentStop", "session_id": self.session, "transcript_path": self.main.path,
                   "cwd": self.tmp, "agent_id": h.agent_id, "agent_type": agent_type, "stop_hook_active": active,
                   "last_assistant_message": last, "background_tasks": [], "session_crons": []}
        if path:
            payload["agent_transcript_path"] = h.path
        return self.run_hook(payload)

    def agent_result_hook(self, h, report, status="completed", agent_id=None, prompt="Read the spec.", **extra):
        payload = {"hook_event_name": "PostToolUse", "session_id": self.session, "transcript_path": self.main.path,
                   "cwd": self.tmp, "tool_name": "Agent", "tool_use_id": "toolu_agent1",
                   "tool_input": {"description": "priya", "prompt": prompt, "subagent_type": "general-purpose"},
                   "tool_response": {"status": status, "agentId": h.agent_id if h else "a0", "agentType":
                                     "general-purpose", "content": [{"type": "text", "text": report}]}}
        if agent_id:
            payload["agent_id"] = agent_id
        payload.update(extra)
        return self.run_hook(payload)

    def notification(self, task_id, result):
        return ("<task-notification>\n<task-id>%s</task-id>\n<tool-use-id>toolu_01AytxAqyT1KJxoe6CJMmJUh</tool-use-id>\n"
                "<output-file>/tmp/x/tasks/%s.output</output-file>\n<status>completed</status>\n<summary>Agent "
                "\"priya\" finished</summary>\n<note>A task-notification fires each time this agent stops.</note>\n"
                "<result>%s</result>\n<usage><subagent_tokens>24657</subagent_tokens></usage>\n</task-notification>"
                % (task_id, task_id, result))

    # -- checks -----------------------------------------------------------------------------------------------
    def assertLine(self, p, event, text):
        self.assertEqual((p.returncode, p.stderr), (0, b""))
        out = p.stdout.decode()
        self.assertEqual(out.count("\n"), 1, out)
        self.assertEqual(json.loads(out), {"hookSpecificOutput": {"hookEventName": event, "additionalContext": text}})

    def assertBlock(self, p, reason):
        self.assertEqual((p.returncode, p.stderr), (0, b""))
        self.assertEqual(json.loads(p.stdout.decode()), {"decision": "block", "reason": reason})

    def assertSilent(self, p, msg=None):
        self.assertEqual((p.returncode, p.stdout, p.stderr), (0, b"", b""), msg)

    def state(self):
        with open(os.path.join(self.data, "feedback-moments", self.session + ".json")) as f:
            return json.load(f)


# ---------------------------------------------------------------------------------------------------------------
# 2.1 The helper line (SubagentStop)
# ---------------------------------------------------------------------------------------------------------------

class HelperMoments(Case):
    def test_2_1_forgot_to_ask_is_kept_going_once_with_the_subagent_line(self):
        h = self.helper()
        h.tool("Read", {"file_path": "lab/STRATEGY_SPEC.md"})
        h.say("Here are the three open questions.")
        self.assertBlock(self.stop_hook(h), SUBAGENT_LINE)
        h.stop_feedback(SUBAGENT_LINE)
        h.say("Here are the three open questions. ... How did I do?")
        self.assertSilent(self.stop_hook(h, active=True, last="Here are the three open questions. How did I do?"))

    def test_2_1_already_asked(self):
        h = self.helper()
        h.say("Three open questions. How did I do?")
        self.assertSilent(self.stop_hook(h, last="Three open questions.\n\nHow did I do?"))
        self.assertSilent(self.stop_hook(h, last="Three open questions. HOW DID I DO?"))

    def test_2_1_ask_split_over_lines_and_spaces_still_counts(self):
        h = self.helper()
        self.assertSilent(self.stop_hook(h, last="Three open questions.\nHow did\nI do?"))

    def test_2_1_feedback_run_from_a_resume_is_never_asked(self):
        h = self.helper()
        h.say("Report. How did I do?")
        self.coordinator(h, FEEDBACK)
        h.tool("mcp__sc__write_experience", {"agent": "priya-analyst", "observation_type": "lesson"})
        self.assertSilent(self.stop_hook(h, last="Thanks, Theo. I wrote my lesson."))

    def test_2_1_feedback_run_from_a_restart_is_never_asked(self):
        h = self.helper(spawn="You are Priya. Sign in as priya-analyst.\n\n" + FEEDBACK)
        self.assertSilent(self.stop_hook(h, last="Lesson written."))

    def test_2_1_a_new_run_after_the_feedback_run_is_asked_again(self):
        h = self.helper()
        self.coordinator(h, FEEDBACK)
        h.say("Lesson written.")
        self.coordinator(h, "Now read lab/RISKS.md and list the top risk.")
        h.tool("Read", {"file_path": "lab/RISKS.md"})
        self.assertBlock(self.stop_hook(h, last="The top risk is vendor lock-in."), SUBAGENT_LINE)

    def test_2_1_a_stop_hooks_feedback_does_not_start_a_new_run(self):
        h = self.helper(spawn="You are Priya.\n\n" + FEEDBACK)
        h.stop_feedback("Some other plugin's stop reason.")
        self.assertSilent(self.stop_hook(h, last="Done."))

    def test_2_1_handback_message_is_the_report(self):
        h = self.helper()
        h.tool("SubagentHandback", {"message": "Three open questions. How did I do?"})
        self.assertSilent(self.stop_hook(h, last="(handed back)"))
        h2 = self.helper(agent_id="a2222222222222222")
        h2.tool("SubagentHandback", {"message": "Three open questions."})
        self.assertBlock(self.stop_hook(h2, last="How did I do?"), SUBAGENT_LINE)

    def test_2_1_helper_that_is_not_symmeno(self):
        h = self.helper(symmeno=False)
        h.say("Done.")
        self.assertSilent(self.stop_hook(h, last="Done."))

    def test_2_1_failed_or_untagged_sign_in_is_not_symmeno(self):
        h = self.helper(symmeno=False)
        h.sign_in(PRIYA, "priya-analyst", is_error=True)
        self.assertSilent(self.stop_hook(h, last="Done."))
        h2 = self.helper(agent_id="a3333333333333333", symmeno=False)
        h2.result(h2.call("mcp__sc__bootstrap", {"agent": "priya"}), json.dumps({"agent": {"slug": "priya"}}))
        self.assertSilent(self.stop_hook(h2, last="Done."))

    def test_2_1_explore_and_plan(self):
        for kind in ("Explore", "Plan"):
            h = self.helper(agent_id="a%s" % ("e" * 16 if kind == "Explore" else "f" * 16))
            self.assertSilent(self.stop_hook(h, last="Found it.", agent_type=kind))

    def test_2_1_stop_hook_active(self):
        h = self.helper()
        self.assertSilent(self.stop_hook(h, active=True, last="Done."))

    def test_2_1_claude_codes_own_side_agents(self):
        h = self.helper(agent_id="a444d887d1a9375c9", spawn="check on priya", symmeno=False, meta=False)
        self.assertSilent(self.stop_hook(h, last="check on priya", agent_type=""))

    def test_2_1_transcript_found_from_the_session_folder_when_the_path_is_missing(self):
        h = self.helper()
        self.assertBlock(self.stop_hook(h, path=False, last="Done."), SUBAGENT_LINE)

    def test_2_1_teammate_after_work_without_the_ask(self):
        h = self.helper(agent_id="apriya-92e9552c7bc934b7", teammate=True)
        h.tool("Read", {"file_path": "lab/STRATEGY_SPEC.md"})
        h.tool("SendMessage", {"to": "main", "message": "Three open questions: ..."})
        p = self.stop_hook(h, agent_type="priya", last="I sent the questions to main.")
        self.assertBlock(p, TEAMMATE_LINE)
        h.stop_feedback(TEAMMATE_LINE)
        h.tool("SendMessage", {"to": "main", "message": "How did I do?"})
        self.assertSilent(self.stop_hook(h, active=True, agent_type="priya", last="Asked."))

    def test_2_1_teammate_small_exchange_never_re_asks(self):
        h = self.helper(agent_id="apriya-92e9552c7bc934b7", teammate=True)
        h.tool("Read", {"file_path": "lab/STRATEGY_SPEC.md"})
        h.tool("SendMessage", {"to": "main", "message": "Questions. How did I do?"})
        self.assertSilent(self.stop_hook(h, agent_type="priya", last="Sent."))
        self.teammate_message(h, "got")
        h.tool("SendMessage", {"to": "main", "message": "Thanks."})
        self.assertSilent(self.stop_hook(h, agent_type="priya", last="Nothing more to do."))
        self.teammate_message(h, "One more question: which file was it?")
        h.tool("ToolSearch", {"query": "select:SendMessage"})
        h.tool("mcp__sc__recall_search", {"agent": "priya-analyst", "query": "spec"})
        h.tool("SendMessage", {"to": "main", "message": "lab/STRATEGY_SPEC.md"})
        self.assertSilent(self.stop_hook(h, agent_type="priya", last="Answered."))

    def test_2_1_teammate_reply_alone_is_not_work(self):
        """Dante's precision: a run whose only tool calls are its reply (SendMessage), loading tools, to-do or task
        bookkeeping, or Symmeno tools is no work, so the teammate is not asked again."""
        h = self.helper(agent_id="apriya-92e9552c7bc934b7", teammate=True)
        h.tool("Read", {"file_path": "lab/STRATEGY_SPEC.md"})
        h.tool("SendMessage", {"to": "main", "message": "Questions. How did I do?"})
        self.assertSilent(self.stop_hook(h, agent_type="priya", last="Sent."))
        self.teammate_message(h, "Which file was the second question from?")
        h.tool("SendMessage", {"to": "main", "message": "lab/STRATEGY_SPEC.md, section 3."})
        self.assertSilent(self.stop_hook(h, agent_type="priya", last="Answered."))
        for name in ("ToolSearch", "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet",
                     "mcp__sc__write_experience", "mcp__plugin_sc_sc__recall_search"):
            self.teammate_message(h, "One more thing (%s)." % name)
            h.tool(name, {})
            h.tool("SendMessage", {"to": "main", "message": "Done."})
            self.assertSilent(self.stop_hook(h, agent_type="priya", last="Done."), name)

    def test_2_1_teammate_any_other_tool_is_work(self):
        for n, name in enumerate(("Read", "Bash", "Edit", "Agent", "WebFetch", "ListAgents", "TaskStop",
                                  "mcp__other__thing")):
            h = self.helper(agent_id="apriya-%016d" % n, teammate=True)
            h.tool(name, {})
            h.tool("SendMessage", {"to": "main", "message": "Done."})
            self.assertBlock(self.stop_hook(h, agent_type="priya", last="Done."), TEAMMATE_LINE)

    def test_2_1_teammate_asked_then_worked_again(self):
        h = self.helper(agent_id="apriya-92e9552c7bc934b7", teammate=True)
        h.tool("SendMessage", {"to": "main", "message": "Plan. How did I do?"})
        h.tool("Edit", {"file_path": "lab/PLAN.md"})
        self.assertBlock(self.stop_hook(h, agent_type="priya", last="Edited the plan."), TEAMMATE_LINE)

    def test_2_1_teammate_feedback_run(self):
        h = self.helper(agent_id="apriya-92e9552c7bc934b7", teammate=True)
        h.tool("Read", {"file_path": "x"})
        self.teammate_message(h, FEEDBACK)
        h.tool("Bash", {"command": "true"})
        self.assertSilent(self.stop_hook(h, agent_type="priya", last="Lesson written."))

    def test_2_1_teammate_known_by_its_first_message_without_a_meta_file(self):
        h = self.helper(agent_id="apriya-0000000000000000", teammate=True, meta=False)
        h.tool("Read", {"file_path": "x"})
        self.assertBlock(self.stop_hook(h, agent_type="priya", last="Done."), TEAMMATE_LINE)

    def test_2_1_headless_named_agent_is_a_subagent(self):
        h = self.helper(meta={"agentType": "general-purpose", "name": "priya", "requestShape": "background"})
        h.tool("SendMessage", {"to": "main", "message": "REPORT"})
        self.assertBlock(self.stop_hook(h, last="I sent REPORT to main."), SUBAGENT_LINE)


# ---------------------------------------------------------------------------------------------------------------
# 2.2 The lead line
# ---------------------------------------------------------------------------------------------------------------

class LeadLine(Case):
    def test_2_2_foreground_report_with_the_ask(self):
        self.lead_signed_in()
        h = self.helper()
        self.assertLine(self.agent_result_hook(h, "Three open questions.\nHow did I do?"), "PostToolUse",
                        LEAD_LINE.format("Priya"))

    def test_2_2_foreground_report_without_the_ask(self):
        self.lead_signed_in()
        self.assertSilent(self.agent_result_hook(self.helper(), "Three open questions."))

    def test_2_2_not_a_symmeno_session(self):
        self.assertSilent(self.agent_result_hook(self.helper(), "Questions. How did I do?"))

    def test_2_2_background_launch_and_teammate_spawn_say_nothing(self):
        self.lead_signed_in()
        h = self.helper()
        for status in ("async_launched", "teammate_spawned"):
            self.assertSilent(self.agent_result_hook(h, "How did I do?", status=status))

    def test_2_2_a_helpers_own_agent_call_is_not_the_leads(self):
        self.lead_signed_in()
        self.assertSilent(self.agent_result_hook(self.helper(), "How did I do?", agent_id="a87b62ada73856ea1"))

    def test_2_2_other_tools_say_nothing(self):
        self.lead_signed_in()
        p = self.run_hook({"hook_event_name": "PostToolUse", "session_id": self.session,
                           "transcript_path": self.main.path, "tool_name": "Bash",
                           "tool_response": {"status": "completed", "content": [{"type": "text",
                                                                                  "text": "How did I do?"}]}})
        self.assertSilent(p)

    def test_2_2_unreadable_helper_is_your_helper(self):
        self.lead_signed_in()
        h = self.helper(symmeno=False)
        self.assertLine(self.agent_result_hook(h, "How did I do?"), "PostToolUse", LEAD_LINE.format("Your helper"))

    def test_2_2_restart_for_feedback_by_agent_prompt(self):
        self.lead_signed_in()
        p = self.agent_result_hook(None, "Lesson written. How did I do?", prompt="You are Priya.\n\n" + FEEDBACK)
        self.assertSilent(p)

    def test_2_2_background_notification_with_the_ask(self):
        self.lead_signed_in()
        h = self.helper(agent_id="a897c7ef8cb31c3fe")
        h.say("Questions. How did I do?")
        self.assertLine(self.prompt_hook(self.notification("a897c7ef8cb31c3fe", "Questions.\nHow did I do?")),
                        "UserPromptSubmit", LEAD_LINE.format("Priya"))

    def test_2_2_background_notification_without_the_ask(self):
        self.lead_signed_in()
        self.helper(agent_id="a897c7ef8cb31c3fe")
        self.assertSilent(self.prompt_hook(self.notification("a897c7ef8cb31c3fe", "Questions.")))

    def test_2_2_resumed_helper_notifies_again_after_feedback(self):
        """6.9: the foreground report gave the lead line; the feedback run's notification gives none."""
        self.lead_signed_in()
        h = self.helper()
        h.say("Questions. How did I do?")
        self.assertLine(self.agent_result_hook(h, "Questions. How did I do?"), "PostToolUse", LEAD_LINE.format("Priya"))
        self.coordinator(h, FEEDBACK)
        h.say("Thank you. I wrote it down. How did I do on the lesson?")
        self.assertSilent(self.prompt_hook(self.notification(h.agent_id, "Thank you. How did I do?")))

    def test_2_2_once_per_report(self):
        self.lead_signed_in()
        h = self.helper(agent_id="a897c7ef8cb31c3fe")
        n = self.notification(h.agent_id, "Questions. How did I do?")
        self.assertLine(self.prompt_hook(n), "UserPromptSubmit", LEAD_LINE.format("Priya"))
        self.assertSilent(self.prompt_hook(n))

    def test_2_2_a_new_piece_of_work_asks_again(self):
        self.lead_signed_in()
        h = self.helper(agent_id="a897c7ef8cb31c3fe")
        self.assertLine(self.prompt_hook(self.notification(h.agent_id, "A. How did I do?")), "UserPromptSubmit",
                        LEAD_LINE.format("Priya"))
        self.coordinator(h, "Now the risks file.")
        self.assertLine(self.prompt_hook(self.notification(h.agent_id, "B. How did I do?")), "UserPromptSubmit",
                        LEAD_LINE.format("Priya"))

    def test_2_2_teammate_message_with_the_ask(self):
        self.lead_signed_in()
        h = self.helper(agent_id="apriya-92e9552c7bc934b7", teammate=True)
        h.tool("SendMessage", {"to": "main", "message": "How did I do?"})
        p = self.prompt_hook('<agent-message from="priya">\nThree questions. How did I do?\n</agent-message>')
        self.assertLine(p, "UserPromptSubmit", LEAD_LINE.format("Priya"))

    def test_2_2_teammate_message_without_the_ask(self):
        self.lead_signed_in()
        self.helper(agent_id="apriya-92e9552c7bc934b7", teammate=True)
        self.assertSilent(self.prompt_hook('<agent-message from="priya">\nREPORT-ALPHA\n</agent-message>'))

    def test_2_2_teammate_feedback_run_message(self):
        self.lead_signed_in()
        h = self.helper(agent_id="apriya-92e9552c7bc934b7", teammate=True)
        self.teammate_message(h, FEEDBACK)
        self.assertSilent(self.prompt_hook('<agent-message from="priya">\nLesson in. How did I do?\n</agent-message>'))

    def test_2_2_message_and_notification_of_one_run_give_one_line(self):
        """Headless: a named agent's SendMessage and its stop's notification are one report."""
        self.lead_signed_in()
        h = self.helper(agent_id="a71fefe2c7e5af34b", meta={"agentType": "general-purpose", "name": "priya"})
        self.assertLine(self.prompt_hook('<agent-message from="priya">\nDone. How did I do?\n</agent-message>'),
                        "UserPromptSubmit", LEAD_LINE.format("Priya"))
        self.assertSilent(self.prompt_hook(self.notification(h.agent_id, "I sent it. How did I do?")))

    def test_2_2_newest_helper_of_that_name(self):
        self.lead_signed_in()
        old = self.helper(agent_id="apriya-1111111111111111", teammate=True)
        self.teammate_message(old, FEEDBACK)
        past = time.time() - 3600
        os.utime(old.path, (past, past))
        self.helper(agent_id="apriya-2222222222222222", teammate=True)
        self.assertLine(self.prompt_hook('<agent-message from="priya">\nHow did I do?\n</agent-message>'),
                        "UserPromptSubmit", LEAD_LINE.format("Priya"))

    def test_2_2_lead_line_is_not_a_person_turn(self):
        """A report never fires the close line, even when it says thanks."""
        self.lead_signed_in()
        self.helper(agent_id="a897c7ef8cb31c3fe")
        self.assertSilent(self.prompt_hook(self.notification("a897c7ef8cb31c3fe", "Thanks, all done.")))


# ---------------------------------------------------------------------------------------------------------------
# 2.3 The person: the wide net, the close line and the answer line
# ---------------------------------------------------------------------------------------------------------------

class WideNet(Case):
    def closes(self, prompt):
        """A fresh, armed Symmeno session: does this prompt get the close line?"""
        self.tearDown()
        self.setUp()
        self.lead_signed_in()
        p = self.prompt_hook(prompt)
        self.assertEqual((p.returncode, p.stderr), (0, b""))
        return p.stdout != b""

    def test_2_3_chets_examples(self):
        for prompt in ("thanks", "Looks good.", "ship it", "Perfect!", "that's it", "Good night"):
            self.assertTrue(self.closes(prompt), prompt)

    def test_2_3_hey(self):
        for prompt in ("Hey!", "Hi", "Good morning", "hello", "Hey there!", "yo"):
            self.assertFalse(self.closes(prompt), prompt)

    def test_2_3_thanks_with_a_follow_up(self):
        self.assertTrue(self.closes("Thanks. Is that assumption written down anywhere?"))

    def test_2_3_ok_inside_a_sentence(self):
        self.assertFalse(self.closes("ok, now read the next file"))
        self.assertFalse(self.closes("good, now the risks"))

    def test_2_3_whole_message_words(self):
        for prompt in ("ok", "Okay.", "k", "cool", "Great!", "nice", "good", "done", "bye", "night", "gn"):
            self.assertTrue(self.closes(prompt), prompt)

    def test_2_3_curly_apostrophes_and_case(self):
        for prompt in ("That’s it.", "THAT'S ALL", "we’re done", "LGTM", "Thank you!!"):
            self.assertTrue(self.closes(prompt), prompt)

    def test_2_3_whole_words_only(self):
        for prompt in ("Try the thankless path", "typo in line 3", "the perfectionist view", "ok then what?"):
            self.assertFalse(self.closes(prompt), prompt)

    def test_2_3_not_the_persons_prompt(self):
        for prompt in (self.notification("a1", "thanks"), '<agent-message from="priya">\nthanks\n</agent-message>',
                       '<cross-session-message from="uds:/run/x.sock" from-name="work-22" from-mode="prompting">\n'
                       'thanks\n</cross-session-message>',
                       '<teammate-message teammate_id="team-lead">\nthanks\n</teammate-message>',
                       "/sc:start thanks", "/loop 5m thanks", "/proj"):
            self.assertFalse(self.closes(prompt), prompt[:40])

    def test_2_3_a_typed_path_is_the_persons(self):
        self.assertTrue(self.closes("/home/chestonriley/theta looks good"))


class CloseAndAnswer(Case):
    def setUp(self):
        super().setUp()
        self.lead_signed_in()
        self.main.prompt("Priya reads the spec.", origin={"kind": "human"})
        self.main.tool("Agent", {"prompt": "Read the spec.", "subagent_type": "general-purpose"})
        self.main.say("[Theo / Coach] Priya found three open questions.")

    def write_lesson(self, sidechain=False):
        self.main.tool("ToolSearch", {"query": "select:mcp__sc__write_experience"})
        if sidechain:
            self.main.sidechain = True
        self.main.tool("mcp__sc__write_experience", {"agent": "theo-coach", "observation_type": "lesson"})
        self.main.sidechain = False

    def test_2_3_thetas_close(self):
        self.assertLine(self.person("Not today. Thanks, that's all for today."), "UserPromptSubmit", CLOSE_LINE)

    def test_2_3_the_answer(self):
        self.person("thanks")
        self.main.say("[Theo / Coach] Glad it helped. How did I do?")
        self.assertLine(self.person("Good, but too long. Thanks."), "UserPromptSubmit", ANSWER_LINE)

    def test_2_3_a_late_answer(self):
        self.person("thanks")
        self.main.say("[Theo / Coach] How did I do?")
        self.assertLine(self.person("one sec, reading it"), "UserPromptSubmit", ANSWER_LINE)
        self.main.say("[Theo / Coach] Take your time.")
        self.assertLine(self.person("Too long, but the structure was right."), "UserPromptSubmit", ANSWER_LINE)

    def test_2_3_the_answer_window_is_three_prompts(self):
        self.person("thanks")
        for prompt in ("hm", "one sec", "still reading"):
            self.assertLine(self.person(prompt), "UserPromptSubmit", ANSWER_LINE)
        self.assertSilent(self.person("ok, thanks"))

    def test_2_3_the_lesson_ends_the_answer_window(self):
        self.person("thanks")
        self.assertLine(self.person("Too long."), "UserPromptSubmit", ANSWER_LINE)
        self.write_lesson()
        self.assertSilent(self.person("Perfect, thank you."))

    def test_2_3_a_helpers_lesson_does_not_end_it(self):
        self.person("thanks")
        self.assertLine(self.person("one sec"), "UserPromptSubmit", ANSWER_LINE)
        self.write_lesson(sidechain=True)
        self.assertLine(self.person("Too long."), "UserPromptSubmit", ANSWER_LINE)

    def test_2_3_thanks_thanks_good_night(self):
        self.assertLine(self.person("thanks"), "UserPromptSubmit", CLOSE_LINE)
        self.main.say("[Theo / Coach] How did I do?")
        self.assertLine(self.person("perfect"), "UserPromptSubmit", ANSWER_LINE)
        self.write_lesson()  # ToolSearch to load the deferred tool, then the write: neither is new work
        self.main.say("[Theo / Coach] Noted.")
        self.assertSilent(self.person("good night"))

    def test_2_3_a_new_piece_of_work(self):
        self.person("thanks")
        self.person("Clear, but too long.")
        self.write_lesson()
        self.main.prompt("Now fix the typo in PLAN.md.", origin={"kind": "human"})
        self.main.tool("Edit", {"file_path": "PLAN.md"})
        self.assertLine(self.person("looks good"), "UserPromptSubmit", CLOSE_LINE)

    def test_2_3_symmeno_and_coordination_tools_do_not_re_arm(self):
        self.person("thanks")
        self.person("fine")
        self.write_lesson()
        for name in ("mcp__sc__recall_search", "mcp__plugin_sc_sc__feedback_read", "ToolSearch", "SendMessage",
                     "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet"):
            self.main.tool(name, {})
        self.assertSilent(self.person("thanks again"))

    def test_2_3_a_helpers_tool_calls_do_not_re_arm(self):
        self.person("thanks")
        self.person("fine")
        self.write_lesson()
        self.main.sidechain = True
        self.main.tool("Edit", {"file_path": "x"})
        self.main.sidechain = False
        self.assertSilent(self.person("looks good"))

    def test_2_3_no_close_line_inside_the_answer_window(self):
        self.person("thanks")
        self.main.tool("Edit", {"file_path": "x"})
        self.assertLine(self.person("thanks!"), "UserPromptSubmit", ANSWER_LINE)

    def test_2_3_reports_in_the_window_do_not_use_it_up(self):
        self.person("thanks")
        self.helper(agent_id="a897c7ef8cb31c3fe")
        self.assertSilent(self.prompt_hook(self.notification("a897c7ef8cb31c3fe", "Fine.")))
        self.assertLine(self.person("Too long."), "UserPromptSubmit", ANSWER_LINE)

    def test_2_3_resumed_headless(self):
        """The close in one `claude -p` run, the answer in a later --resume run: same session, same transcript."""
        self.assertLine(self.person("Thanks, that's all for today."), "UserPromptSubmit", CLOSE_LINE)
        self.main.say("[Theo / Coach] How did I do?")
        self.main.add("system", None, subtype="session_resumed")
        self.assertLine(self.person("Clear, but too long. Shorter next time."), "UserPromptSubmit", ANSWER_LINE)

    def test_2_3_survives_compaction(self):
        self.person("thanks")
        self.main.add("system", None, subtype="compact_boundary")
        self.main.prompt("This session is being continued from a previous conversation.", isCompactSummary=True)
        self.assertLine(self.person("Too long."), "UserPromptSubmit", ANSWER_LINE)

    def test_2_3_a_rewritten_transcript_tells_nothing(self):
        self.person("thanks")
        self.person("fine")
        self.write_lesson()
        self.assertSilent(self.person("ok sure"))  # the lesson is read: the window is closed, not yet re-armed
        os.rename(self.main.path, self.main.path + ".old")
        shutil.copy(self.main.path + ".old", self.main.path)
        self.main.tool("Edit", {"file_path": "x"})
        self.assertSilent(self.person("looks good"))  # the mark moves to the new file's end; no re-arm from it
        self.main.tool("Edit", {"file_path": "y"})
        self.assertLine(self.person("looks good"), "UserPromptSubmit", CLOSE_LINE)

    def test_2_3_state_file_is_small_private_and_holds_no_secret(self):
        self.person("thanks")
        path = os.path.join(self.data, "feedback-moments", self.session + ".json")
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertLess(os.path.getsize(path), 2048)
        st = self.state()
        self.assertEqual(sorted(st), ["answer_left", "armed", "lead_keys", "mark", "session", "v", "work", "wrote"])
        self.assertEqual((st["armed"], st["answer_left"]), (False, 3))

    def test_2_3_state_in_the_claude_config_folder_without_plugin_data(self):
        p = self.person("thanks", env={"CLAUDE_PLUGIN_DATA": ""})
        self.assertLine(p, "UserPromptSubmit", CLOSE_LINE)
        self.assertTrue(os.path.isfile(os.path.join(self.tmp, "claude-config", "plugins", "data", "sc-symmeno",
                                                    "feedback-moments", self.session + ".json")))


class OnlySymmeno(Case):
    def test_2_3_ordinary_session(self):
        self.main.prompt("Fix the bug.")
        self.main.tool("Edit", {"file_path": "x"})
        self.assertSilent(self.person("thanks"))
        self.assertSilent(self.person("great"))
        self.assertFalse(os.path.exists(os.path.join(self.data, "feedback-moments")))

    def test_2_3_before_the_sign_in(self):
        self.main.prompt("/sc:start theta")
        self.assertSilent(self.person("thanks"))
        self.main.sign_in(THEO, "theo-coach")
        self.assertLine(self.person("thanks"), "UserPromptSubmit", CLOSE_LINE)

    def test_2_3_first_prompt_has_no_transcript_yet(self):
        self.assertSilent(self.prompt_hook("thanks"))  # the file does not exist yet on the very first prompt


# ---------------------------------------------------------------------------------------------------------------
# 2.4 The reply-tag hook is untouched; S6: no line depends on hook order
# ---------------------------------------------------------------------------------------------------------------

class ReplyTagUntouched(Case):
    def test_2_4_reply_tag_files_are_byte_equal_to_0_4_0(self):
        for rel, want in REPLY_TAG_0_4_0.items():
            with open(os.path.join(ROOT, rel), "rb") as f:
                self.assertEqual(hashlib.sha256(f.read()).hexdigest(), want, rel)

    def test_2_4_the_moments_hook_never_writes_the_reply_tag_state(self):
        self.main.prompt("/sc:start theta")
        self.main.sign_in(THEO, "theo-coach")
        self.assertLine(self.person("thanks"), "UserPromptSubmit", CLOSE_LINE)
        self.assertFalse(os.path.exists(os.path.join(self.data, "reply-tag")))
        tag = self.prompt_hook("next", hook=TAG_HOOK)
        self.assertIn(b"[Theo / Coach]", tag.stdout)
        tag_state = os.path.join(self.data, "reply-tag", self.session + ".json")
        def snapshot():
            with open(tag_state, "rb") as f:
                return f.read(), os.stat(tag_state).st_mtime_ns
        before = snapshot()
        self.main.tool("Edit", {"file_path": "x"})
        self.person("fine")
        self.person("looks good")
        self.assertEqual(snapshot(), before)

    def test_s6_same_lines_whichever_hook_runs_first(self):
        """The tag hook first, or the moments hook first: the moments line is the same."""
        for tag_first in (True, False):
            self.tearDown()
            self.setUp()
            self.lead_signed_in()
            if tag_first:
                self.prompt_hook("thanks", hook=TAG_HOOK)
            moments = self.prompt_hook("thanks")
            tag = self.prompt_hook("thanks", hook=TAG_HOOK)
            self.assertLine(moments, "UserPromptSubmit", CLOSE_LINE)
            self.assertIn(b"[Theo / Coach]", tag.stdout)


# ---------------------------------------------------------------------------------------------------------------
# 2.5 Silent no-op
# ---------------------------------------------------------------------------------------------------------------

class SilentNoOp(Case):
    def events(self, transcript):
        h = {"session_id": self.session, "transcript_path": transcript, "cwd": self.tmp}
        yield dict(h, hook_event_name="UserPromptSubmit", prompt="thanks")
        yield dict(h, hook_event_name="UserPromptSubmit", prompt=self.notification("a1", "How did I do?"))
        yield dict(h, hook_event_name="SubagentStop", agent_id="a1", agent_type="general-purpose",
                   stop_hook_active=False, agent_transcript_path=transcript, last_assistant_message="Done.")
        yield dict(h, hook_event_name="PostToolUse", tool_name="Agent", tool_use_id="t",
                   tool_response={"status": "completed", "agentId": "a1",
                                  "content": [{"type": "text", "text": "How did I do?"}]})

    def test_2_5_missing_transcript(self):
        for payload in self.events(os.path.join(self.tmp, "nope.jsonl")):
            self.assertSilent(self.run_hook(payload))

    def test_2_5_transcript_is_a_folder(self):
        for payload in self.events(self.tmp):
            self.assertSilent(self.run_hook(payload))

    def test_2_5_malformed_transcript(self):
        with open(self.main.path, "wb") as f:
            f.write(b'{"type":"user"\n\x00\xff garbage {{{\n[1,2]\n"tool_use"\n{"type":"assistant","message":7}\n')
        for payload in self.events(self.main.path):
            self.assertSilent(self.run_hook(payload))

    def test_2_5_malformed_hook_input(self):
        for raw in (b"", b"not json", b"[]", b"null", b'{"hook_event_name": "UserPromptSubmit"}',
                    b'{"hook_event_name": "UserPromptSubmit", "session_id": "../../etc", "prompt": "thanks"}',
                    b'{"hook_event_name": "SubagentStop", "session_id": "s", "agent_id": "../x"}',
                    b'{"hook_event_name": "Stop", "session_id": "s"}'):
            self.assertSilent(self.run_hook(None, raw=raw))

    def test_2_5_no_python3(self):
        bare = os.path.join(self.tmp, "bare")
        os.makedirs(bare)
        self.lead_signed_in()
        self.assertSilent(self.prompt_hook("thanks", env={"PATH": bare}))

    def test_2_5_python3_that_fails(self):
        shim = os.path.join(self.tmp, "broken")
        os.makedirs(shim)
        with open(os.path.join(shim, "python3"), "w") as f:
            f.write("#!/bin/sh\necho oops >&2\nexit 3\n")
        os.chmod(os.path.join(shim, "python3"), 0o755)
        self.lead_signed_in()
        self.assertSilent(self.prompt_hook("thanks", env={"PATH": shim + os.pathsep + "/usr/bin:/bin"}))

    def test_2_5_unwritable_state_still_quiet(self):
        self.lead_signed_in()
        open(self.data, "w").close()  # a file where the data folder should be
        p = self.prompt_hook("thanks")
        self.assertEqual((p.returncode, p.stderr), (0, b""))

    def test_2_5_unreadable_transcript(self):
        if os.geteuid() == 0:
            self.skipTest("root reads everything")
        self.lead_signed_in()
        os.chmod(self.main.path, 0)
        for payload in self.events(self.main.path):
            self.assertSilent(self.run_hook(payload))


class Packaging(unittest.TestCase):
    def test_2_6_manifest_names_the_moments_hooks_file(self):
        with open(os.path.join(ROOT, ".claude-plugin", "plugin.json")) as f:
            manifest = json.load(f)
        self.assertEqual(manifest["hooks"], "./hooks/feedback-moments.json")
        self.assertEqual(manifest["version"], "0.5.0")
        with open(os.path.join(ROOT, ".claude-plugin", "marketplace.json")) as f:
            (entry,) = json.load(f)["plugins"]
        self.assertEqual(entry["version"], "0.5.0")

    def test_2_6_hooks_file_runs_the_launcher_on_the_three_events(self):
        with open(os.path.join(ROOT, "hooks", "feedback-moments.json")) as f:
            config = json.load(f)["hooks"]
        self.assertEqual(sorted(config), ["PostToolUse", "SubagentStop", "UserPromptSubmit"])
        self.assertEqual(config["PostToolUse"][0]["matcher"], "^(Agent|Task)$")
        self.assertNotIn("matcher", config["UserPromptSubmit"][0])
        self.assertNotIn("matcher", config["SubagentStop"][0])
        for groups in config.values():
            (group,) = groups
            (hook,) = group["hooks"]
            self.assertEqual(hook["command"], 'sh "${CLAUDE_PLUGIN_ROOT}/hooks/feedback-moments.sh"')
            self.assertNotIn("CLAUDE_PLUGIN_DATA", hook["command"])
        self.assertTrue(os.path.isfile(HOOK))

    def test_2_5_hook_is_python_3_9_and_standard_library_only(self):
        with open(os.path.join(ROOT, "hooks", "feedback_moments.py")) as f:
            tree = ast.parse(f.read(), feature_version=(3, 9))
        imported = {a.name.split(".")[0] for n in ast.walk(tree) if isinstance(n, ast.Import) for a in n.names}
        imported |= {n.module.split(".")[0] for n in ast.walk(tree) if isinstance(n, ast.ImportFrom)}
        self.assertLessEqual(imported, {"hashlib", "json", "mmap", "os", "re", "sys", "time", "reply_tag"})

    def test_2_5_launcher_keeps_the_mac_guard(self):
        with open(HOOK) as f:
            launcher = f.read()
        self.assertIn('if [ "$py" = /usr/bin/python3 ] && [ -x /usr/bin/xcode-select ]; then', launcher)
        self.assertIn("/usr/bin/xcode-select -p >/dev/null 2>&1 || exit 0", launcher)
        self.assertIn('"$py" -I "$here/feedback_moments.py" 2>/dev/null', launcher)


# ---------------------------------------------------------------------------------------------------------------
# 2.5 Speed
# ---------------------------------------------------------------------------------------------------------------

class Timing(Case):
    """Each run under 1 second on a 100 MB transcript; a non-Symmeno helper's stop (on a 10 MB helper transcript, a
    large real one) and an Agent call without the ask under 0.2 s. A non-Symmeno helper has to be read to its end to
    know it never signed in, so on 100 MB that stop costs about what one search of the file costs (logged)."""

    def fill(self, t, mb=None):
        target = (mb or TIMING_MB) * 1024 * 1024
        text = ("The plan covers the risk register, the dashboards and the vendor review. " * 60)[:4000]
        big = json.dumps({"results": [text] * 12})
        rows = []
        for n in range(6):
            rows.append({"type": "user", "isSidechain": t.sidechain, "uuid": "f%d" % n,
                         "message": {"role": "user", "content": "Question %d about the plan." % n}})
            rows.append({"type": "assistant", "isSidechain": t.sidechain, "uuid": "g%d" % n, "message": {
                "role": "assistant", "content": [{"type": "text", "text": text}]}})
            rows.append({"type": "assistant", "isSidechain": t.sidechain, "uuid": "h%d" % n, "message": {
                "role": "assistant", "content": [{"type": "tool_use", "id": "toolu_r%d" % n, "name":
                                                  "mcp__sc__recall_search", "input": {"query": "plan"}}]}})
            rows.append({"type": "user", "isSidechain": t.sidechain, "uuid": "i%d" % n, "message": {
                "role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_r%d" % n,
                                             "content": [{"type": "text", "text": big}]}]}})
        block = "".join(json.dumps(e, separators=(",", ":")) + "\n" for e in rows)
        with open(t.path, "a", encoding="utf-8") as f:
            written = os.path.getsize(t.path)
            while written < target:
                f.write(block)
                written += len(block)
        with open(t.path, "rb") as f:  # warm, the way a live session's file is warm
            while f.read(64 << 20):
                pass

    def timed(self, fn, *a, **kw):
        start = time.perf_counter()
        p = fn(*a, **kw)
        return p, time.perf_counter() - start

    def test_2_5_timing_100mb(self):
        if not TIMING:
            self.skipTest("--skip-timing")
        results = []
        self.lead_signed_in()
        self.fill(self.main)
        self.main.tool("Edit", {"file_path": "x"})
        size = os.path.getsize(self.main.path) / 1048576

        p, s = self.timed(self.prompt_hook, "What is next on the list?")
        self.assertSilent(p)
        results.append(("an ordinary prompt (nothing due, nothing read)", s, 0.2))
        p, s = self.timed(self.person, "Thanks, that's all.")  # no reply-tag state: reads the whole transcript
        self.assertLine(p, "UserPromptSubmit", CLOSE_LINE)
        results.append(("close line, first read, no state", s, 1.0))
        self.fill(self.main)  # another 100 MB of work after the close
        p, s = self.timed(self.person, "Too long.")
        self.assertLine(p, "UserPromptSubmit", ANSWER_LINE)
        results.append(("answer line, 100 MB since the close", s, 1.0))

        h = self.helper()
        self.fill(h)
        p, s = self.timed(self.stop_hook, h, last="Done.")
        self.assertBlock(p, SUBAGENT_LINE)
        results.append(("Symmeno helper stop, 100 MB helper transcript", s, 1.0))
        p, s = self.timed(self.agent_result_hook, h, "Done. How did I do?")
        self.assertLine(p, "PostToolUse", LEAD_LINE.format("Priya"))
        results.append(("lead line on an Agent result, 100 MB both", s, 1.0))

        plain = self.helper(agent_id="a5555555555555555", symmeno=False)
        self.fill(plain, mb=10)
        p, s = self.timed(self.stop_hook, plain, last="Done.")
        self.assertSilent(p)
        results.append(("non-Symmeno helper stop, 10 MB helper transcript", s, 0.2))
        self.fill(plain)
        p, s = self.timed(self.stop_hook, plain, last="Done.")
        self.assertSilent(p)
        results.append(("non-Symmeno helper stop, 100 MB helper transcript", s, 1.0))
        p, s = self.timed(self.agent_result_hook, plain, "Here is the summary.")
        self.assertSilent(p)
        results.append(("Agent result without the ask", s, 0.2))

        for what, seconds, limit in results:
            sys.stderr.write("\n    timing %.0f MB: %-52s %.3f s (limit %.1f)" % (size, what, seconds, limit))
        sys.stderr.write("\n")
        for what, seconds, limit in results:
            self.assertLess(seconds, limit, what)


if __name__ == "__main__":
    args = sys.argv[1:]
    if "--python" in args:
        i = args.index("--python")
        PYTHON = args[i + 1]
        del args[i:i + 2]
    if "--skip-timing" in args:
        TIMING = False
        args.remove("--skip-timing")
    if PYTHON:
        found = shutil.which(PYTHON) or PYTHON
        version = subprocess.run([found, "-c", "import sys; print(sys.version.split()[0])"], capture_output=True)
        sys.stderr.write("hook runs under %s (%s)\n" % (found, version.stdout.decode().strip()))
    unittest.main(argv=[sys.argv[0]] + args, verbosity=2)
