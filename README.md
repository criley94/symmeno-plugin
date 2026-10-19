# Symmeno plugin for Claude Code (`sc`)

Version 0.1.0.

Start your Symmeno crew from Claude Code, in your crew's folder:

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

When the install asks where to install, pick **Install for you (user scope)**. The plugin holds no key, so it is
safe in every folder; the connection in step 2 decides which folders reach a crew.

## 2. Connect Symmeno Core

Until sign-in arrives, one connection reaches one crew, so it lives where that crew works. In a terminal, run the
connect script that came with the plugin.

**A computer that runs more than one crew uses `--folder`.** That is the team VM, and any laptop with folders for
several crews. Run it once per crew folder, each with that crew's key file. The crew's key then reaches only
Claude Code started in that crew's folder, never another crew's:

```
sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/marketplaces/symmeno/scripts/connect.sh" --folder ~/nautilus ~/.config/symmeno-core/nautilus-team-key
```

`/sc:start` then works in Claude Code started in that exact folder, not in its subfolders.

**A computer that will only ever run one crew** can connect every folder at once by leaving out `--folder`:

```
sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/marketplaces/symmeno/scripts/connect.sh" ~/.config/symmeno-core/nautilus-team-key
```

If the script's path does not exist on your computer, type `/sc:help` in Claude Code: until Symmeno is connected,
it prints the exact command with the plugin's own path.

The script registers one Claude Code MCP server named `sc` (for that folder, or for your user), installs a small
helper at `~/.config/symmeno-core/sc-headers` that reads the key file each time Claude Code connects, and allows
the `sc` tools so memory calls do not ask each time. It never prints the key. Running it again changes nothing.

**If it says there is already a Symmeno connection** (for example one named `symmeno`, or one for every folder
while you asked for one folder), it changes nothing and prints two lines: one removes the old entry, the other
re-runs the script. Run them both. Anything you set up to allow `mcp__symmeno__*` tools by name no longer applies;
the tools are now `mcp__sc__*`. A crew folder that already has its own `sc` for the right crew needs nothing.

## 3. Open the crew folder and check

1. Quit Claude Code, then start it in the crew folder (any folder, if you connected without `--folder`).
2. If Claude Code asks whether you trust this folder, say yes. Claude Code reads the key only in a trusted folder,
   so the connection fails until you do.
3. Type `/mcp`. `sc` shows connected.
4. Type `/sc:start <crew>`, for example `/sc:start nautilus`. The crew's lead starts.

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
