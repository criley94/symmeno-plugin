# Symmeno plugin for Claude Code (`sc`)

Version 0.1.0.

Start your Symmeno crew from any folder:

- `/sc:start <crew>` starts the crew's lead.
- `/sc:start <crew> <teammate>` starts that teammate.
- Add a project after either: `/sc:start nautilus lena portside`.
- `/sc:help` shows these forms, your crew, its teammates and its recent projects.

The plugin carries the two commands. The connection to Symmeno Core is a separate, one-time step (step 2), so the
team key stays in a file on your computer and never in the plugin.

## Before you start

- Claude Code is installed, and `python3` is on your PATH (the connect script uses it to read Claude Code's config).
- git on this computer can clone `criley94/symmeno-plugin`. The repo is private: today this plugin is for Team
  Nautilus only.
- Your team key file is on this computer, readable only by you. For Nautilus it is
  `~/.config/symmeno-core/nautilus-team-key`. Do not open it or paste it anywhere.

## 1. Install the plugin

In Claude Code, type:

```
/plugin marketplace add criley94/symmeno-plugin
/plugin install sc@symmeno
```

## 2. Connect Symmeno Core

In a terminal, run the connect script that came with the plugin, giving it your key file:

```
sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/marketplaces/symmeno/scripts/connect.sh" ~/.config/symmeno-core/nautilus-team-key
```

If that path does not exist on your computer, type `/sc:help` in Claude Code: until Symmeno is connected, it
prints the exact command with the plugin's own path.

The script registers one Claude Code MCP server named `sc` for your user, installs a small helper at
`~/.config/symmeno-core/sc-headers` that reads the key file each time Claude Code connects, and allows the `sc`
tools so memory calls do not ask each time. It never prints the key. Running it again changes nothing.

**If it says this computer already has a Symmeno connection** (for example one named `symmeno`), it changes
nothing and prints two lines: one removes the old entry, the other re-runs the script. Run them both. Anything you
set up to allow `mcp__symmeno__*` tools by name no longer applies; the tools are now `mcp__sc__*`.

## 3. Restart and check

1. Quit Claude Code and start it again.
2. Type `/mcp`. `sc` shows connected.
3. Type `/sc:start <crew>`, for example `/sc:start nautilus`. The crew's lead starts.

## Bringing in teammates

Ask the lead. It brings teammates in by itself, signed in through the same connection, on the same project. You
usually start only the lead.

## Updating

When a new version is out, type:

```
/plugin marketplace update symmeno
/plugin update sc@symmeno
```

Then restart Claude Code. The connection from step 2 does not need to be redone.

## For invitees (not yet)

This repo is private, so it installs only where git can already clone it. A plugin customers can install needs a
public repo or another route. That is Chet's call before any invitee.
