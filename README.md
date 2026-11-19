# Symmeno plugin for Claude Code (`sc`)

Version 0.5.0.

Start your Symmeno crew from Claude Code:

- `/sc:start <crew>` starts the crew's lead.
- `/sc:start <crew> <teammate>` starts that teammate.
- Add a project after either: `/sc:start nautilus lena portside`.
- `/sc:help` shows these forms, your crews, their teammates and recent projects.

## Before you start

- Claude Code is installed, and `python3` (3.9 or newer; the Mac default is fine) is on your PATH.
- You have been given a Symmeno account (your Google address is on a crew), or your crew's key file is on this
  computer (see "Shared computers" below).

## 1. Install the plugin

In Claude Code, type:

```
/plugin marketplace add https://symmeno.com/plugin/marketplace.json
/plugin install sc@symmeno
```

When the install asks where to install, pick **Install for you (user scope)**. The plugin holds no key and no
password; it carries one connection to Symmeno Core, so it is safe in every folder. Then type `/reload-plugins`.

## 2. Sign in once, then start from any folder

In any folder, type `/sc:start <crew>`, for example `/sc:start nautilus`.

The first time on this computer it shows a sign-in link. Open it, sign in with your Google account, and come back:
the crew's lead starts in the same conversation. From then on, `/sc:start <crew>` works in any folder with no
sign-in and no question. Your sign-in stays where Claude Code keeps it (the keychain on a Mac); the plugin never
sees it.

That first run also allows the Symmeno tools (`mcp__plugin_sc_sc__*`) in your own Claude Code settings, for every
folder on this computer, so your crew can read and write its memory without asking you each time. That is right for
a computer that is yours alone; on a shared computer, use crew keys instead (below).

`/sc:start` only starts crews you are a member of. One Claude session starts one crew; for another crew, open a new
session.

If the link does not open, or you are working over SSH, type `/mcp`, choose `sc`, pick Authenticate, then
`/sc:start <crew>` again.

## Bringing in teammates

Ask the lead. It brings teammates in by itself, signed in through the same connection, on the same project. You
usually start only the lead.

## Every reply starts with the teammate's tag

Once `/sc:start` has started a teammate, each of its replies to you begins with its tag, for example
`[Theo / Coach]`, so you always know who is talking. Symmeno Core sends the tag with the start; the plugin never
makes one up.

To keep that true in a long session, the plugin has one small hook. On each message you send in a session that
started a Symmeno teammate, and again after a compaction or a resume, it adds one line to the teammate's context:
`Start every reply to the person with your tag, as its very first characters: [Theo / Coach]`. You do not see the
line. In any other session the hook does nothing and says nothing, and it stays silent on any error or when
`python3` is missing. It reads only what the session's transcript gained since its last run, so it stays fast in a
long session. It keeps a small note per session (the tag and how far it has read; never a key or a password) in the
plugin's data folder, `~/.claude/plugins/data/sc-symmeno/reply-tag/`, and removes notes older than two weeks.

## Asking how it went, and learning from the answer

Your crew gets better only from what it writes down. From 0.5.0 the plugin adds one line to an agent's context at
four moments, so a piece of work ends with a question, a grade and a lesson. You do not see these lines.

| When | Who gets the line | The line |
|---|---|---|
| A Symmeno teammate hands work back without asking how it did | that teammate | `If you just finished a piece of work, send your report again in full and end it with one line asking the teammate who gave you the work: How did I do?` (a helper the lead started) or `If you just finished a piece of work, send the teammate who gave you the work one more line: How did I do?` (an agent-team teammate) |
| That report reaches the lead, asking "How did I do?" | the lead | `Priya asked for your feedback on that work: read the bar (feedback_read), grade only what you saw, then send it (feedback_give).` |
| You close or approve a piece of work ("thanks", "looks good", "ship it", "that's all for today") | the agent you are talking to | `If you just finished a piece of work with the person, end this reply by asking them how you did.` |
| Your next messages after it asked (up to three, until it writes its lesson) | the same agent | `If the person just told you how you did, reflect on what it says about how you worked and, before you reply, write to Core as a lesson (write_experience) what you'll keep doing and what you'll do differently. It's the only way you get better.` |

After the lead grades a helper, Symmeno Core's reply tells it to pass the grade on, and the helper writes its lesson
when the grade arrives. The plugin adds nothing there.

Once per piece of work:
- A helper the lead started is reminded once per job it was given. A teammate is reminded only after it did real
  work (a tool call outside Symmeno, other than sending a message, listing agents, loading tools, or to-do and task
  bookkeeping) and has not asked since. A
  helper that is receiving its grade is never reminded.
- The lead gets its line once per report that asks. It gets none for a report from a helper that was just
  receiving its grade.
- The close line comes once. It comes again only after the agent has written its lesson (or the three messages
  have passed) and has done more work. A string of "thanks", "perfect", "good night" asks once. "Hey!" or "Good
  morning" on its own never counts. Neither does "ok" inside a longer message ("ok, now read the next file").

Only your own messages count. Not: a helper's report, a teammate's message, another session's message, or a slash
command. A `/loop` or scheduled prompt looks like one of yours and can count. That gap is known: the lines only say
what to do *if* the moment is real.

The same promises as the tag hook. Outside a session that started a Symmeno teammate, for a helper that never signed
in to Symmeno, and on any error (or with no `python3`), these hooks do nothing and say nothing. They never change the
tag hook's files or its notes. They keep a small note per session (whether a close is armed, how many answer lines
are left, how far they have read since the close, and which reports they answered; never a key or a password) in
`~/.claude/plugins/data/sc-symmeno/feedback-moments/`, and remove notes older than two weeks. The hooks are in
`hooks/feedback-moments.json` (named by `.claude-plugin/plugin.json`), beside the tag hook's `hooks/hooks.json`.

## Shared computers (crew keys)

A computer that several crews share (the agent VM) never signs a person in: it stays on crew keys, one key file per
crew at `~/.config/symmeno-core/<crew>-team-key`, readable only by you. Do not open a key file or paste it anywhere.
The computer carries the marker file `/etc/symmeno/shared-machine` (created by whoever runs it), and `/sc:start`
then connects the folder with the crew's key instead of signing anyone in:

- **If this computer has one crew's key file and no other Symmeno connection**, it connects every folder at once,
  without asking.
- **If this computer runs more than one crew**, it asks one question, "Connect this folder to <crew>?", and connects
  only this folder, so a crew's key never reaches another crew's folders. If an older Symmeno connection covers
  every folder (for example one named `symmeno`), the question says it will be removed. If the folder is not yet
  trusted in Claude Code but the folder above it is, the question says it will mark this folder trusted too (never
  for a git repository: see below).

Then it tells you the one step to load the new connection: in the terminal, type `/reload-plugins`; in the Claude
desktop app, open a new session in the same folder. Then `/sc:start <crew>` again, and the crew's lead starts.

A folder connected with a crew key keeps using it, even with the plugin's own connection present: both point at the
same address, and Claude Code keeps the folder's one.

In the desktop app, pick the folder first (**Choose...**). A session started without one runs in a throwaway
workspace, and `/sc:start` refuses to connect that path: it would scope the crew to a folder you never open again.

### Connecting from a terminal (optional)

`/sc:start` runs the plugin's `scripts/connect.sh` for you on a shared computer. You can also run it yourself:

```
cd ~/nautilus
sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/marketplaces/symmeno/scripts/connect.sh" --folder . ~/.config/symmeno-core/nautilus-team-key
```

- `--folder .` connects the folder you are in, and only that one (the script refuses any other folder). Inside a
  git repository that means the whole repository, because Claude Code keeps a repository's local settings under
  its root. Leave `--folder` out to connect every folder (only on a computer that will only ever run one crew).
- It registers one Claude Code MCP server named `sc`, installs a small helper at
  `~/.config/symmeno-core/sc-headers` that reads the key file each time Claude Code connects, and allows the `sc`
  tools so memory calls do not ask each time. It never prints the key. Running it again changes nothing.
- Claude Code reads a folder's key only when that folder is trusted. If a folder above it is trusted, the script
  marks this folder trusted too, but never across a git repository: a repository inside a trusted folder has to be
  trusted on its own. Otherwise start Claude Code there once and accept the trust question.
- If it finds a Symmeno connection that is set up differently, it changes nothing and prints the two lines to fix
  it. Anything you set up to allow `mcp__symmeno__*` tools by name no longer applies; the tools are `mcp__sc__*`.
- `sh .../connect.sh --survey` shows the crews with key files, the Symmeno connections on this computer and whether
  it is marked shared, without changing anything.

If a folder was connected before and `/sc:start` says Symmeno did not load, check that the crew's key file is still
in place: without it the connection fails with an error that looks like a Core or sign-in problem.

## Updating

When a new version is out, type:

```
/plugin marketplace update symmeno
/plugin update sc@symmeno
```

Then type `/reload-plugins`. Sign-ins and crew-key connections do not need to be redone.

## For the people who run Symmeno

- The bundled connection (`.mcp.json`) and `scripts/connect.sh` must name the same Core address, byte for byte;
  `sh scripts/set-core-url.sh <url>` changes both (a trial build), and `tests/connect-test.sh` checks they match.
- `sh tests/connect-test.sh <scratch-dir>` runs the script checks in a sandbox that never touches the real
  `~/.claude.json`.
- `python3 tests/reply_tag_test.py` tests the reply-tag hook (`hooks/`) on made-up transcripts, in a scratch folder,
  including a 100 MB transcript that must take under a second. `--python python3.9` runs the hook under another
  Python; `--skip-timing` leaves out the 100 MB test.
- `sh tests/reply-tag-live.sh <scratch-dir>` is an opt-in check in real Claude Code: it loads this checkout with
  `--plugin-dir` and a stand-in `sc` server, runs three short headless turns on a cheap model (a few cents), and
  leaves their transcripts where Claude Code keeps every session's.
- `python3 tests/feedback_moments_test.py` tests the feedback-moments hooks on made-up transcripts in the shapes
  Claude Code writes, including 100 MB timing runs. `--python python3.9` and `--skip-timing` work the same way.
- `sh tests/feedback-moments-live.sh <scratch-dir>` is the opt-in live check for those hooks. It runs four headless
  turns on a cheap model against a stand-in `sc` server (`tests/fake_sc_crew_server.py`): a helper reminded to ask,
  the lead line, the close line, the answer line, and a plain session that gets nothing.

## For invitees (not yet)

This repo is public so the Claude desktop app can install it, but a person still needs a Symmeno account on a crew.
Inviting people outside Team Nautilus is Chet's call.
