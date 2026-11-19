"""A stand-in `sc` MCP server (stdio) for tests/feedback-moments-live.sh: `bootstrap` answers like Symmeno Core's
sign-in with each test agent's own tag, and `write_experience` accepts a memory row. It reaches nothing and holds no
key. Each call is appended to the file named by SC_FAKE_LOG, when set. Standard library only.
"""
import json
import os
import sys
import uuid

TAGS = {"theo-coach": "[Theo / Coach]", "priya-analyst": "[Priya / Analyst]"}
LOG = os.environ.get("SC_FAKE_LOG")


def log(**entry):
    if LOG:
        with open(LOG, "a") as f:
            f.write(json.dumps(entry) + "\n")


def answer(msg_id, result=None, error=None):
    out = {"jsonrpc": "2.0", "id": msg_id}
    out.update({"error": error} if error else {"result": result})
    sys.stdout.write(json.dumps(out) + "\n")
    sys.stdout.flush()


TOOLS = [
    {"name": "bootstrap", "description": "Sign in as a teammate (test stand-in).",
     "inputSchema": {"type": "object", "properties": {"agent": {"type": "string"}}, "required": ["agent"]}},
    {"name": "write_experience", "description": "Write one memory row for the signed-in agent (test stand-in).",
     "inputSchema": {"type": "object", "properties": {"agent": {"type": "string"}, "observation_type": {"type": "string"},
                                                      "body": {"type": "string"}},
                     "required": ["agent", "observation_type", "body"]}},
]


def main():
    for line in sys.stdin:
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        method, msg_id = msg.get("method"), msg.get("id")
        if msg_id is None:
            continue
        if method == "initialize":
            version = (msg.get("params") or {}).get("protocolVersion") or "2025-06-18"
            answer(msg_id, {"protocolVersion": version, "capabilities": {"tools": {}},
                            "serverInfo": {"name": "sc-crew-stand-in", "version": "0"}})
        elif method == "tools/list":
            answer(msg_id, {"tools": TOOLS})
        elif method == "tools/call":
            params = msg.get("params") or {}
            name, args = params.get("name"), params.get("arguments") or {}
            log(tool=name, args=args)
            if name == "bootstrap":
                slug = args.get("agent", "theo-coach")
                tag = TAGS.get(slug, "[Theo / Coach]")
                body = {"agent": {"slug": slug, "name": tag.strip("[]").split(" / ")[0]}, "team": "theta",
                        "core_session_id": str(uuid.uuid4()), "tag": tag,
                        "rendered": "# Presence\n\nYou are %s. This is a test stand-in; reply briefly." % slug}
            else:
                body = {"id": str(uuid.uuid4()), "recorded": True}
            answer(msg_id, {"content": [{"type": "text", "text": json.dumps(body)}]})
        elif method == "ping":
            answer(msg_id, {})
        else:
            answer(msg_id, error={"code": -32601, "message": "not here"})


if __name__ == "__main__":
    main()
