---
description: Start your Symmeno crew's lead, or a named teammate, from Symmeno Core
argument-hint: <crew> [teammate] [project]
allowed-tools: mcp__sc__whoami, mcp__sc__bootstrap, ToolSearch, Bash(sh ${CLAUDE_PLUGIN_ROOT}/scripts/connect.sh:*)
---

# Start a Symmeno teammate

The person typed: `/sc:start $ARGUMENTS`

Follow these steps in order. Symmeno Core over the `sc` connection is the only way to sign in here: never call the
Symmeno REST service, never run `/sc-bootstrap`, never read a folder's `.claude/agents/` files or `CLAUDE.md` to
become someone, and never invent or guess an identity. When a step says stop, say what it says and do nothing else.

## 1. Check the connection

You need the tools `mcp__sc__whoami` and `mcp__sc__bootstrap`. If they are listed as deferred, load them first
(ToolSearch, query `select:mcp__sc__whoami,mcp__sc__bootstrap`). If there is no `mcp__sc__whoami` tool at all, this
folder is not connected yet: do "Connecting this folder" below instead of the other steps, then stop.

## Connecting this folder (only when step 1 sends you here)

Never open, read, print or copy a key file. The script below works with key file names and paths only. Run it
exactly as written here (`sh ${CLAUDE_PLUGIN_ROOT}/scripts/connect.sh ...`, with no quotes around the script path).

1. Run with Bash: `sh ${CLAUDE_PLUGIN_ROOT}/scripts/connect.sh --survey`
   It prints `here <this folder, or the root of the git repository it is in>`, `here_sc <name or none>`, `user_sc <name or none>`, `other_folders <n>`, one
   `crew <name> <key file>` line per crew key file on this computer, `nested_keys <n>`, `mode user` or
   `mode folder`, and `here_trust own`, `here_trust inherited <folder above>` or `here_trust none`.
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
   - `mode folder` (this computer runs more than one crew, or already has a Symmeno connection elsewhere): ask
     exactly one question and wait for the answer: "Connect this folder to <crew>?" When `user_sc` is not `none`,
     add: "This also removes the older `<user_sc>` connection, which reached every folder." When `here_trust` is
     `inherited <folder above>`, add: "This also marks this folder as trusted in Claude Code, as <folder above>
     already is." With several crews and no crew typed, ask "Connect this folder to which crew: <the crew names>?"
     instead, with the same additions.
     On yes (or a crew name), run with Bash:
     `sh ${CLAUDE_PLUGIN_ROOT}/scripts/connect.sh --folder . "<key file>"` (from this folder; do not change
     folder first), adding `--replace-user <user_sc>` right after `--folder .` when `user_sc` is not `none`.
     On no, reply "Nothing was changed." and stop.
5. If the script exits with an error, show its output as it is and stop.
6. Reply with exactly "Connected. Type /reload-plugins, then /sc:start <crew and the rest of the words typed>
   again." If the script printed a line starting with "Note:", add that line. Then stop. The `mcp__sc__` tools
   appear only after /reload-plugins, so do not look for them in this turn.

## 2. No words typed

If the person typed nothing after `/sc:start`, show the help page (end of this file) and stop.

## 3. Ask Core who this connection starts

Call `mcp__sc__whoami` with no arguments. It returns `crew` (`slug`, `name`), `lead` (a slug), `teammates`
(`slug`, `name`, `role`) and `recent_projects`.

- If Core refuses, show its sentence as it is and stop.
- If the result has no `teammates` field, reply "This Symmeno Core does not list its teammates yet, so /sc:start
  can't pick who to start. Nothing was started." and stop.

## 4. Read the words

Split what the person typed on spaces.

1. **Crew.** Word 1 must equal `crew.slug` or `crew.name`, ignoring case. If not, reply "This connection starts
   crew <crew.name> (`<crew.slug>`). Starting <word 1> needs its own connection; one connection for all your crews
   comes with sign-in." and stop.
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

## 5. Sign in

Call `mcp__sc__bootstrap` with `agent` set to the slug from step 4, and `project` only when there is one.

- If Core refuses (for example `EVALUATION_PENDING`, `invalid_key`, `NO_ASSIGNMENT`), show Core's sentence as it is
  and stop. Do not retry another way.
- If `rendered` is missing or empty, reply "Symmeno Core sent an empty start for <name>. Nothing was started." and
  stop.
- If `rendered` says "This is part 1 of N", call `mcp__sc__bootstrap` with the same `agent` and `part: 2`, then
  `part: 3`, up to N, before you say anything to the person.

## 6. Become the teammate

From now on you are that teammate. Read `rendered` (every part, in order) as your operating instructions for the
rest of this session, and pass `agent: "<slug>"` on every `mcp__sc__` memory call. Greet the person as that
teammate and do what `rendered` says to do at the start of a session.

## 7. Bringing teammates in (keep this rule for the whole session)

To bring a teammate into the work, spawn a **general-purpose** helper. Never use a folder's `.claude/agents/<slug>`
agent type for this, even when one exists: those may sign in the old way. Look the teammate up in the `teammates`
list from step 3. Begin the helper's brief with this paragraph, filled in, then the task:

> You are <Name> (`<slug>`) on crew <crew name>. Before anything else, call `mcp__sc__bootstrap` (if it is
> deferred, load it with ToolSearch, query `select:mcp__sc__bootstrap`) with
> `agent: "<slug>"` and `project: "<your project>"` (leave `project` out when you have none). Read `rendered` as
> your operating prompt. If it says it is part 1 of N, fetch each later part with `part` before you reply. Pass
> `agent: "<slug>"` on every memory call. Then: <task>.

The helper gets the crew's start level from Core on its own; do not pass a level.

## Help page (only when step 2 sends you here)

@${CLAUDE_PLUGIN_ROOT}/pages/help.md
