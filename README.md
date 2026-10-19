# Symmeno plugin for Claude Code (`sc`)

Version 0.3.4.

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
/plugin marketplace add criley94/symmeno-plugin
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
same address, and Claude Code keeps the folder's one. The shared VM stays on the 0.2 line of this plugin.

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

## For invitees (not yet)

This repo is public so the Claude desktop app can install it, but a person still needs a Symmeno account on a crew.
Inviting people outside Team Nautilus is Chet's call.
