"""Folder trust for connect.sh.

Claude Code runs a local-scope MCP headers helper only in a folder whose own
entry in ~/.claude.json has hasTrustDialogAccepted. A folder that inherits trust
from a trusted folder above it never gets the trust question, so it has no mark
of its own. connect.sh mirrors that inherited trust onto the folder, but never
across a git repository boundary: a repository inside a trusted folder (a fresh
clone with its own hooks) has to be trusted on its own, exactly as Claude Code's
own inheritance stops at the repository root.

Inside a git repository Claude Code keeps a folder's settings (local MCP servers,
trust) under the repository's root, so <folder> below is always that key: the
repository root, or the folder itself outside any repository.

Usage:
  trust.py root <folder>                  prints the folder's Claude Code project key
  trust.py state <claude.json> <folder>   prints: own | inherited <folder above> | none
  trust.py mark <claude.json> <folder>    marks the folder trusted if its state is inherited

Runs on Python 3.9 (Apple's default): keep the annotations behind the future
import and use nothing newer than 3.9.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys


def git_root(folder: str) -> str | None:
    """The root of the git repository holding folder, or None outside any repository.

    Asks git when it is installed. Any .git entry on the way up counts as a
    boundary too, so a repository git cannot read still keeps trust out.
    """
    if shutil.which("git"):
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        run = subprocess.run(["git", "-C", folder, "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, env=env)
        if run.returncode == 0 and run.stdout.strip():
            return os.path.realpath(run.stdout.strip())
    path = folder
    while True:
        if os.path.exists(os.path.join(path, ".git")):
            return path
        parent = os.path.dirname(path)
        if parent == path:
            return None
        path = parent


def root(folder: str) -> str:
    """Claude Code's project key for folder: its repository root, or itself."""
    return git_root(folder) or folder


def trusted(projects: dict, folder: str) -> bool:
    return bool((projects.get(folder) or {}).get("hasTrustDialogAccepted"))


def state(projects: dict, folder: str) -> tuple[str, str]:
    if trusted(projects, folder):
        return "own", folder
    # Trust from above a repository root never reaches inside it.
    boundary = git_root(folder)
    path = folder
    while path != boundary:
        parent = os.path.dirname(path)
        if parent == path:
            break
        path = parent
        if trusted(projects, path):
            return "inherited", path
    return "none", ""


def load(config_path: str) -> dict:
    try:
        with open(config_path) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def main() -> None:
    if sys.argv[1] == "root":
        print(root(sys.argv[2]))
        return
    action, config_path, folder = sys.argv[1:4]
    kind, above = state(load(config_path).get("projects") or {}, folder)
    if action == "state":
        print(kind if kind != "inherited" else f"inherited {above}")
        return
    if kind == "own":
        return
    if kind == "none":
        why = " A git repository is trusted on its own, never through the folder above it." \
            if git_root(folder) == folder else ""
        print(f"Note: Claude Code runs the key helper only in a trusted folder. Start Claude Code once in {folder} "
              f"and accept the trust question.{why}")
        return
    # Re-read right before writing, so a concurrent Claude Code save is not lost.
    config = load(config_path)
    config.setdefault("projects", {}).setdefault(folder, {})["hasTrustDialogAccepted"] = True
    tmp = f"{config_path}.tmp.{os.getpid()}"
    with open(tmp, "w") as f:
        json.dump(config, f, indent=2)
    os.chmod(tmp, os.stat(config_path).st_mode & 0o777)
    os.replace(tmp, config_path)
    print(f"Marked {folder} as trusted in Claude Code, like {above} above it.")


if __name__ == "__main__":
    main()
