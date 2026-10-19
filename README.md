# Symmeno plugin for Claude Code (`sc`)

Version 0.2.0.

Start your Symmeno crew from Claude Code:

- `/sc:start <crew>` starts the crew's lead.
- `/sc:start <crew> <teammate>` starts that teammate.
- Add a project after either: `/sc:start nautilus lena portside`.
- `/sc:help` shows these forms, your crew, its teammates and its recent projects.

## Before you start

- Claude Code is installed, and `python3` is on your PATH.
- git on this computer can clone `criley94/symmeno-plugin`. The repo is private: today this plugin is for Team
  Nautilus only.
- Your crew's key file is on this computer, readable only by you, at `~/.config/symmeno-core/<crew>-team-key`
  (for Nautilus, `~/.config/symmeno-core/nautilus-team-key`). Do not open it or paste it anywhere. The plugin
  never holds a key; it only points Claude Code at that file.

## 1. Install the plugin

In Claude Code, type:

```
/plugin marketplace add criley94/symmeno-plugin
/plugin install sc@symmeno
```

When the install asks where to install, pick **Install for you (user scope)**. The plugin holds no key, so it is
safe in every folder. Then type `/reload-plugins`.

## 2. Start your crew

In any folder, type `/sc:start <crew>`, for example `/sc:start nautilus`.

The first time in a folder, it connects Symmeno for you instead of starting:

- **If this computer has one crew's key file and no other Symmeno connection**, it connects every folder at once,
  without asking.
- **If this computer runs more than one crew**, it asks one question, "Connect this folder to <crew>?", and connects
  only this folder. Until sign-in arrives, one connection reaches one crew, so a crew's key never reaches another
  crew's folders. If an older Symmeno connection covers every folder (for example one named `symmeno`), the
  question says it will be removed.

Then it tells you the one step to load the new connection: type `/reload-plugins`, then `/sc:start <crew>` again.
The crew's lead starts.

## Bringing in teammates

Ask the lead. It brings teammates in by itself, signed in through the same connection, on the same project. You
usually start only the lead.

## Connecting from a terminal (optional)

`/sc:start` runs the plugin's `scripts/connect.sh` for you. You can also run it yourself:

```
cd ~/nautilus
sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/marketplaces/symmeno/scripts/connect.sh" --folder . ~/.config/symmeno-core/nautilus-team-key
```

- `--folder .` connects the folder you are in, and only that one (the script refuses any other folder); leave it
  out to connect every folder (only on a computer that will only ever run one crew).
- It registers one Claude Code MCP server named `sc`, installs a small helper at
  `~/.config/symmeno-core/sc-headers` that reads the key file each time Claude Code connects, and allows the `sc`
  tools so memory calls do not ask each time. It never prints the key. Running it again changes nothing.
- Claude Code reads a folder's key only when that folder is trusted. If a folder above it is trusted, the script
  marks this folder trusted too, but never across a git repository: a repository inside a trusted folder has to be
  trusted on its own. Otherwise start Claude Code there once and accept the trust question.
- If it finds a Symmeno connection that is set up differently, it changes nothing and prints the two lines to fix
  it. Anything you set up to allow `mcp__symmeno__*` tools by name no longer applies; the tools are `mcp__sc__*`.
- `sh .../connect.sh --survey` shows the crews with key files and the Symmeno connections on this computer,
  without changing anything.

If a folder was connected before and `/sc:start` says Symmeno did not load, check that the crew's key file is still
in place: without it the connection fails with an error that looks like a Core or sign-in problem.

## Updating

When a new version is out, type:

```
/plugin marketplace update symmeno
/plugin update sc@symmeno
```

Then type `/reload-plugins`. Connections do not need to be redone.

## For invitees (not yet)

This repo is private, so it installs only where git can already clone it. A plugin customers can install needs a
public repo or another route. That is Chet's call before any invitee.
