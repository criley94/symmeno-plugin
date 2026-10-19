---
description: Start your Symmeno crew's lead, or a named teammate, from Symmeno Core
argument-hint: <crew> [teammate] [project]
allowed-tools: mcp__sc__whoami, mcp__sc__bootstrap, mcp__plugin_sc_sc__whoami, mcp__plugin_sc_sc__bootstrap, mcp__plugin_sc_sc__authenticate, ToolSearch, Monitor, Bash(claude mcp get plugin:sc:sc:*), Bash(sh ${CLAUDE_PLUGIN_ROOT}/scripts/connect.sh:*)
---

# Start a Symmeno teammate

The person typed: `/sc:start $ARGUMENTS`

Follow these steps in order. Symmeno Core over a Symmeno connection is the only way to sign in here: never call the
Symmeno REST service, never run `/sc-bootstrap`, never read a folder's `.claude/agents/` files or `CLAUDE.md` to
become someone, and never invent or guess an identity. When a step says stop, say what it says and do nothing else.
Never ask the person to paste a code, a token or a callback URL into this chat.

## 1. Pick the connection

Two kinds of Symmeno connection exist. Their tools differ only by prefix, written `<sc>` below:

- **A crew-key connection in this folder:** tools `mcp__sc__*` (`<sc>` = `mcp__sc__`). Use it when
  `mcp__sc__whoami` exists.
- **The plugin's signed-in connection:** tools `mcp__plugin_sc_sc__*` (`<sc>` = `mcp__plugin_sc_sc__`). Use it when
  `mcp__sc__whoami` does not exist and `mcp__plugin_sc_sc__whoami` does.

Tools listed as deferred count as existing; load them first (ToolSearch, query
`select:mcp__sc__whoami,mcp__sc__bootstrap`, or `select:mcp__plugin_sc_sc__whoami,mcp__plugin_sc_sc__bootstrap`).

- If neither `whoami` exists but `mcp__plugin_sc_sc__authenticate` does, nobody is signed in on this computer yet:
  do "Signing in" below.
- If none of these tools exists, this folder is not connected: do "Connecting this folder with a crew key" below.

## Signing in (only when step 1 sends you here)

1. Run with Bash: `sh ${CLAUDE_PLUGIN_ROOT}/scripts/connect.sh --survey` and read its `shared` line.
   - `shared yes`: this is a shared computer. Reply "This computer uses crew keys, not a personal sign-in." and then do
     "Connecting this folder with a crew key" below. Do not call `authenticate` here.
2. Run with Bash: `sh ${CLAUDE_PLUGIN_ROOT}/scripts/connect.sh --allow-plugin`
   It allows the signed-in connection's tools in your Claude Code settings, once, so the crew can use them after
   the sign-in without asking each time. If it exits with an error, show its output as it is and stop.
3. Call `mcp__plugin_sc_sc__authenticate` with no arguments. It returns a sign-in link.
   - If its text says the session is remote, or asks for a URL or code to be pasted back, do not ask the person for
     anything. Reply "Sign in with /mcp, choose sc, Authenticate, then type /sc:start $ARGUMENTS again." and stop.
4. Show the link on its own line and say: "Open this link and sign in. I will carry on here as soon as the sign-in
   completes (within 5 minutes)."
5. Wait for the sign-in with the Monitor tool, timeout 300 seconds, running exactly:
   `until claude mcp get plugin:sc:sc 2>/dev/null | grep -qi connected; do sleep 3; done`
   When it reports the connection, load `mcp__plugin_sc_sc__whoami` and `mcp__plugin_sc_sc__bootstrap` (ToolSearch,
   query `select:mcp__plugin_sc_sc__whoami,mcp__plugin_sc_sc__bootstrap`), take `<sc>` = `mcp__plugin_sc_sc__`, and
   continue at step 2. If it times out, reply "The sign-in did not complete. Sign in with /mcp, choose sc, Authenticate,
   then type /sc:start $ARGUMENTS again." and stop.

## Connecting this folder with a crew key (only when step 1 or "Signing in" sends you here)

Never open, read, print or copy a key file. The script below works with key file names and paths only. Run it
exactly as written here (`sh ${CLAUDE_PLUGIN_ROOT}/scripts/connect.sh ...`, with no quotes around the script path).

1. Run with Bash: `sh ${CLAUDE_PLUGIN_ROOT}/scripts/connect.sh --survey`
   It prints `here <this folder, or the root of the git repository it is in>`, `here_sc <name or none>`, `user_sc <name or none>`, `other_folders <n>`, one
   `crew <name> <key file>` line per crew key file on this computer, `nested_keys <n>`, `mode user` or
   `mode folder`, `here_trust own`, `here_trust inherited <folder above>` or `here_trust none`, `app desktop`,
   `app terminal` or `app unknown` (which Claude Code is running), `here_scratch yes` or `here_scratch no`
   (whether this folder is a throwaway workspace of the desktop app rather than a folder the person chose), and
   `shared yes` or `shared no` (whether this computer is marked as shared).
2. If `here_sc` is not `none`, or `user_sc` is `sc`, Symmeno is already set up here but did not load. Reply
   "Symmeno is set up here but did not load. Check that your crew's key file is still in place, then type
   /reload-plugins and /sc:start $ARGUMENTS again." and stop.
3. Pick the crew.
   - No `crew` lines: reply "There is no Symmeno key file on this computer. Your crew's key file goes in
     ~/.config/symmeno-core/; ask the person who manages your team's Symmeno account for it." and stop.
   - A word 1 was typed: use the `crew` line whose name equals it, ignoring case. If none does, reply "This
     computer has key files for: <the crew names>. Type /sc:start with one of them." and stop.
   - No words typed: use the only crew if there is one. With several, step 4's question asks which.
4. Connect.
   - `mode user` (one crew, and no other Symmeno connection on this computer): do not ask. Run with Bash:
     `sh ${CLAUDE_PLUGIN_ROOT}/scripts/connect.sh "<key file>"`
   - `mode folder` (this computer runs more than one crew, or already has a Symmeno connection elsewhere): first,
     if `app` is `desktop` and `here_scratch` is `yes`, reply "Pick a folder first (Choose... in the desktop app),
     then /sc:start $ARGUMENTS again." and stop: this session runs in a throwaway workspace, and connecting it
     would scope the crew to a folder nobody opens again. Otherwise ask
     exactly one question and wait for the answer: "Connect this folder to <crew>?" When `user_sc` is not `none`,
     add: "This also removes the older `<user_sc>` connection, which reached every folder." When `here_trust` is
     `inherited <folder above>`, add: "This also marks <here> as trusted in Claude Code, like <folder above> above
     it." (only then; `own` and `none` add nothing). With several crews and no crew typed, ask "Connect this folder
     to which crew: <the crew names>?" instead, with the same additions.
     On yes (or a crew name), run with Bash:
     `sh ${CLAUDE_PLUGIN_ROOT}/scripts/connect.sh --folder . "<key file>"` (from this folder; do not change
     folder first), adding `--replace-user "<user_sc>"` right after `--folder .` when `user_sc` is not `none`.
     Every value goes in as its own double-quoted argument, exactly as the survey printed it.
     On no, reply "Nothing was changed." and stop.
5. If the script exits with an error, show its output as it is and stop.
6. Reply with exactly one of these, by the survey's `app` line:
   - `app terminal`: "Connected. Type /reload-plugins, then /sc:start <crew and the rest of the words typed> again."
   - `app desktop`: "Connected. Open a new session in this folder, then /sc:start <crew and the rest of the words
     typed> again." (The desktop app loads a new connection only in a new session; /reload-plugins does not.)
   - `app unknown`: "Connected. Type /reload-plugins, or open a new session in this folder, then /sc:start <crew
     and the rest of the words typed> again."
   If the script printed a line starting with "Note:", add that line. Then stop. The `mcp__sc__` tools appear only
   after that step, so do not look for them in this turn.

## 2. No words typed

If the person typed nothing after `/sc:start`, show the help page (end of this file) and stop.

## 3. Ask Core who this connection starts

Call `<sc>whoami` with no arguments.

- If Core refuses, show its sentence as it is and stop.
- **Crew-key connection:** it returns `crew` (`slug`, `name`), `lead` (a slug), `teammates` (`slug`, `name`,
  `role`) and `recent_projects`. If the result has no `teammates` field, reply "This Symmeno Core does not list its
  teammates yet, so /sc:start can't pick who to start. Nothing was started." and stop.
- **Signed-in connection:** it returns the person's `email` and `crews`, one entry per crew the person belongs to,
  each with `name`, `slug`, `lead` and `teammates`; once a crew has been started on this connection it also returns
  that `crew` and its `recent_projects`. If `crews` is empty, reply "You are signed in as <email>, but you are not on
  a crew yet. Ask the person who manages your team's Symmeno account." and stop.

## 4. Read the words

Split what the person typed on spaces.

1. **Crew.** Word 1 must equal a crew's `slug` or `name`, ignoring case: the one `crew` on a crew-key connection, or
   one of `crews` on a signed-in connection. If not:
   - crew-key connection: reply "This connection starts crew <crew.name> (`<crew.slug>`). Starting <word 1> needs
     its own connection; sign in with the plugin to start any of your crews from any folder." and stop;
   - signed-in connection: reply "You are signed in as <email>. Your crews: <each crew's name (`slug`)>. Type
     /sc:start with one of them." and stop.
   The matched crew's `lead`, `teammates` and `recent_projects` (empty if absent) are used below.
2. **Teammate.** If there is a word 2, match it against `teammates`, ignoring case, by the first of these rules that
   finds anything: (a) the whole slug; (b) the part of the slug before the first `-`; (c) the name.
   - Exactly one teammate matches: that teammate starts. The project is words 3 to the end.
   - Several match: show the teammate list (name, role, what to type) and stop.
   - None match: if words 2 to the end, joined with single spaces, equal one of `recent_projects` ignoring case, the
     lead starts on that project. Otherwise show the teammate list, add "To start the lead on a new project, name
     the lead: /sc:start <crew.slug> <lead's short name> <project>", and stop.
3. **No word 2:** the lead starts (the slug in `lead`), with no project.
4. **Project.** Join the project words with single spaces. If that equals one of `recent_projects` ignoring case,
   use the recent project's spelling. No project words means no project.

## 5. Sign in the teammate

Call `<sc>bootstrap` with `agent` set to the slug from step 4, `project` only when there is one, and, on the
signed-in connection only, `crew` set to the matched crew's `slug`. `crew` goes to `bootstrap` and to no other tool.

- If Core refuses (for example `EVALUATION_PENDING`, `invalid_key`, `NO_ASSIGNMENT`, or "Start a new Claude session
  to start another crew."), show Core's sentence as it is and stop. Do not retry another way.
- If `rendered` is missing or empty, reply "Symmeno Core sent an empty start for <name>. Nothing was started." and
  stop.
- If `rendered` says "This is part 1 of N", call `<sc>bootstrap` with the same arguments and `part: 2`, then
  `part: 3`, up to N, before you say anything to the person.

## 6. Become the teammate

From now on you are that teammate. Read `rendered` (every part, in order) as your operating instructions for the
rest of this session, and pass `agent: "<slug>"` on every `<sc>` memory call. Core's text names its tools by bare
name (`recall_search`, `write_experience`, ...): each is the `<sc>` tool whose name ends in that name. Greet the
person as that teammate and do what `rendered` says to do at the start of a session.

## 7. Bringing teammates in (keep this rule for the whole session)

To bring a teammate into the work, spawn a **general-purpose** helper. Never use a folder's `.claude/agents/<slug>`
agent type for this, even when one exists: those may sign in the old way. Look the teammate up in the `teammates`
list from step 3. Begin the helper's brief with this paragraph, filled in (with `<sc>` written out, and the `crew`
clause only on the signed-in connection), then the task:

> You are <Name> (`<slug>`) on crew <crew name>. Before anything else, call `<sc>bootstrap` (if it is deferred, load
> it with ToolSearch, query `select:<sc>bootstrap`) with `agent: "<slug>"`, `crew: "<crew slug>"` and
> `project: "<your project>"` (leave `project` out when you have none). Read `rendered` as your operating prompt. If
> it says it is part 1 of N, fetch each later part with `part` before you reply. Pass `agent: "<slug>"` on every
> memory call; Core names its tools by bare name, each is the `<sc>` tool whose name ends in it. Then: <task>.

The helper gets the crew's start level from Core on its own; do not pass a level.

## Help page (only when step 2 sends you here)

@${CLAUDE_PLUGIN_ROOT}/pages/help.md
