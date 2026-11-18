"""A stand-in `sc` MCP server (stdio) for tests/reply-tag-live.sh: one tool, `bootstrap`, that answers like Symmeno
Core's sign-in with a made-up agent and its `tag`. It reaches nothing and holds no key. Standard library only.

    python3 -I tests/fake_sc_server.py [tag]      (default tag: [Theo / Coach])
"""
import json
import sys

TAG = sys.argv[1] if len(sys.argv) > 1 else "[Theo / Coach]"
NAME = TAG.strip("[]").split(" / ")[0]


def answer(msg_id, result=None, error=None):
    out = {"jsonrpc": "2.0", "id": msg_id}
    out.update({"error": error} if error else {"result": result})
    sys.stdout.write(json.dumps(out) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        method, msg_id = msg.get("method"), msg.get("id")
        if msg_id is None:
            continue  # a notification
        if method == "initialize":
            version = (msg.get("params") or {}).get("protocolVersion") or "2025-06-18"
            answer(msg_id, {"protocolVersion": version, "capabilities": {"tools": {}},
                            "serverInfo": {"name": "sc-stand-in", "version": "0"}})
        elif method == "tools/list":
            answer(msg_id, {"tools": [{
                "name": "bootstrap",
                "description": "Sign in as a teammate (test stand-in).",
                "inputSchema": {"type": "object", "properties": {"agent": {"type": "string"}}, "required": ["agent"]},
            }]})
        elif method == "tools/call":
            agent = ((msg.get("params") or {}).get("arguments") or {}).get("agent", "theo-coach")
            body = {"agent": {"slug": agent, "name": NAME, "role": "Coach"}, "team": "theta",
                    "core_session_id": "00000000-0000-0000-0000-000000000000", "tag": TAG,
                    "rendered": "# Presence\n\nYou are %s. This is a test stand-in; reply briefly." % NAME}
            answer(msg_id, {"content": [{"type": "text", "text": json.dumps(body)}]})
        elif method == "ping":
            answer(msg_id, {})
        else:
            answer(msg_id, error={"code": -32601, "message": "not here"})


if __name__ == "__main__":
    main()
