"""A small stdio MCP server for mcp-on-demand tests.

FAKE_STARTS: file that gets one line per start (with the pid).
FAKE_TOOLS: comma-separated tool names to advertise.
"""
import json
import os
import sys

with open(os.environ["FAKE_STARTS"], "a") as handle:
    handle.write("%d\n" % os.getpid())


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def tools():
    return [{"name": name, "description": "Tool " + name + " ✦", "inputSchema": {"type": "object"}}
            for name in os.environ.get("FAKE_TOOLS", "echo").split(",")]


for line in sys.stdin:
    message = json.loads(line)
    method, request_id = message.get("method"), message.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": request_id, "result": {
            "protocolVersion": message["params"]["protocolVersion"],
            "capabilities": {"tools": {"listChanged": False}, "prompts": {}},
            "serverInfo": {"name": "fake", "version": "1"}, "instructions": "Fake server."}})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": request_id, "result": {"tools": tools()}})
    elif method == "prompts/list":
        send({"jsonrpc": "2.0", "id": request_id, "result": {"prompts": [{"name": "hello"}]}})
    elif method == "tools/call":
        name = message["params"]["name"]
        if name == "crash":
            sys.exit(3)
        if name == "ask":
            send({"jsonrpc": "2.0", "id": "srv-1", "method": "roots/list"})
            answer = json.loads(sys.stdin.readline())
            text = "roots=%d" % len(answer["result"]["roots"])
        else:
            text = "echo:" + json.dumps(message["params"].get("arguments", {}), ensure_ascii=False)
        send({"jsonrpc": "2.0", "method": "notifications/message", "params": {"level": "info", "data": "called"}})
        send({"jsonrpc": "2.0", "id": request_id, "result": {"content": [{"type": "text", "text": text}]}})
    elif request_id is not None and method:
        send({"jsonrpc": "2.0", "id": request_id, "result": {}})
