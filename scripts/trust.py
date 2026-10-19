"""Folder trust for connect.sh.

Claude Code runs a local-scope MCP headers helper only in a folder whose own
entry in ~/.claude.json has hasTrustDialogAccepted. A folder that inherits trust
from a trusted folder above it never gets the trust question, so it has no mark
of its own. connect.sh mirrors that inherited trust onto the folder, but never
across a git repository boundary: a repository inside a trusted folder (a fresh
clone with its own hooks) has to be trusted on its own.

Inside a git repository Claude Code keeps a folder's settings (local MCP servers,
trust) under the repository's root, so <folder> below is always that key: the
repository root, or the folder itself outside any repository.

Usage:
  trust.py root <folder>                  prints the folder's Claude Code project key
  trust.py state <claude.json> <folder>   prints: own | inherited <folder above> | none
  trust.py mark <claude.json> <folder>    marks the folder trusted if its state is inherited
"""

import json
import os
import sys


def root(folder: str) -> str:
    path = folder
    while True:
        if os.path.exists(os.path.join(path, ".git")):
            return path
        parent = os.path.dirname(path)
        if parent == path:
            return folder
        path = parent


def state(projects: dict, folder: str) -> tuple[str, str]:
    if (projects.get(folder) or {}).get("hasTrustDialogAccepted"):
        return "own", folder
    path = folder
    while True:
        # A repository root is a boundary: trust above it does not reach inside.
        if os.path.exists(os.path.join(path, ".git")):
            return "none", ""
        parent = os.path.dirname(path)
        if parent == path:
            return "none", ""
        path = parent
        if (projects.get(path) or {}).get("hasTrustDialogAccepted"):
            return "inherited", path


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
        print(f"Note: Claude Code runs the key helper only in a trusted folder. Start Claude Code once in {folder} "
              "and accept the trust question.")
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
