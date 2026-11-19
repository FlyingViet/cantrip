#!/usr/bin/env python3
"""Scripts/cantrip-mcp-relay.c against Scripts/cantrip-mcp: the native relay must speak the same
protocol. Compiles it, then runs both against a fake Cantrip socket. `make test-mcp-relay`."""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FAILURES = []


def check(condition, message):
    if not condition:
        FAILURES.append(message)
        print("FAIL:", message)


class FakeHost:
    """A unix socket that records each connection's lines and answers every request after the hello."""

    def __init__(self, path):
        self.path = path
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(path)
        self.server.listen(4)
        self.received = []
        threading.Thread(target=self.serve, daemon=True).start()

    def close(self):
        self.server.close()
        os.unlink(self.path)

    def serve(self):
        while True:
            try:
                connection, _ = self.server.accept()
            except OSError:
                return
            threading.Thread(target=self.handle, args=(connection,), daemon=True).start()

    def handle(self, connection):
        data = b""
        while True:
            chunk = connection.recv(65536)
            if not chunk:
                break
            data += chunk
            while b"\n" in data:
                line, data = data.split(b"\n", 1)
                self.received.append(line)
                if line.startswith(b'{"server"'):
                    continue
                message = json.loads(line)
                if message.get("method") == "bye":
                    connection.sendall(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": "bye"}).encode() + b"\n")
                    connection.close()
                    return
                if "id" in message:
                    reply = {"jsonrpc": "2.0", "id": message["id"], "result": {"echo": message.get("params")}}
                    connection.sendall(json.dumps(reply).encode() + b"\n")
        if data:
            self.received.append(b"UNTERMINATED:" + data)
        connection.close()


def main():
    work = tempfile.mkdtemp(prefix="relay-test-")
    try:
        binary = os.path.join(work, "bin", "cantrip-mcp-relay")
        os.makedirs(os.path.dirname(binary))
        subprocess.run(["clang", "-O2", "-Wall", "-Werror", "-o", binary,
                        os.path.join(ROOT, "Scripts", "cantrip-mcp-relay.c")], check=True)
        script = os.path.join(work, "bin", "cantrip-mcp")
        shutil.copy2(os.path.join(ROOT, "Scripts", "cantrip-mcp"), script)
        sock = os.path.join(work, "s.sock")
        env = dict(os.environ, CANTRIP_MCP_SOCKET=sock)
        env.pop("CANTRIP_TAB_ID", None)

        # Both relays send the same hello, then pass requests and replies through unchanged.
        requests = b"".join(json.dumps({"jsonrpc": "2.0", "id": n, "method": "tools/call",
                                        "params": {"n": n, "text": "x" * 70000 if n == 2 else "\u00e9"}}).encode() + b"\n"
                            for n in (1, 2, 3))
        # The last line has no newline: both relays end it with one.
        requests += json.dumps({"jsonrpc": "2.0", "id": 4, "method": "ping"}).encode()
        results = {}
        for name, relay in (("script", script), ("native", binary)):
            host = FakeHost(sock)
            done = subprocess.run([relay, "kiwi", "--backend", "Copilot", "--tab", "T-1"], input=requests,
                                  capture_output=True, env=env, timeout=20)
            host.close()
            replies = [json.loads(line) for line in done.stdout.splitlines() if line.strip()]
            results[name] = host.received
            check(done.returncode == 0, f"{name}: exits 0 (got {done.returncode}, {done.stderr[:200]!r})")
            check([r["id"] for r in replies] == [1, 2, 3, 4], f"{name}: every reply comes back in order: {[r.get('id') for r in replies]}")
            check(len(replies) > 1 and len(replies[1]["result"]["echo"]["text"]) == 70000, f"{name}: a 70 KB reply passes whole")
        check(results["native"] == results["script"], "the native relay sends exactly the script's lines: "
              f"{results['native'][:1]!r} vs {results['script'][:1]!r}")
        check(results["native"][:1] == [b'{"server": "kiwi", "backend": "Copilot", "tab": "T-1"}'], "hello line")

        # The tab comes from CANTRIP_TAB_ID when --tab isn't given; quotes are escaped.
        host = FakeHost(sock)
        subprocess.run([binary, 'od"d', "--backend", "Claude"], input=b"", capture_output=True,
                       env=dict(env, CANTRIP_TAB_ID="TAB-2"), timeout=20)
        host.close()
        check(host.received[:1] == [b'{"server": "od\\"d", "backend": "Claude", "tab": "TAB-2"}'],
              f"hello from the environment: {host.received[:1]!r}")

        # The host closing the connection ends the relay at once, with stdin still open.
        host = FakeHost(sock)
        relay = subprocess.Popen([binary, "kiwi"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
        relay.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 9, "method": "bye"}).encode() + b"\n")
        relay.stdin.flush()
        try:
            out = relay.stdout.read()
            relay.wait(timeout=5)
            check(b'"bye"' in out, "the host's last reply arrives before it closes")
        except subprocess.TimeoutExpired:
            relay.kill()
            check(False, "the relay exits when the host closes")
        host.close()

        # Without Cantrip, the native relay runs the script beside it, which answers with an error.
        done = subprocess.run([binary, "kiwi"], input=json.dumps({"jsonrpc": "2.0", "id": 7, "method": "tools/list"}).encode() + b"\n",
                              capture_output=True, env=env, timeout=20)
        reply = json.loads(done.stdout.splitlines()[0]) if done.stdout.strip() else {}
        check(reply.get("id") == 7 and "isn't running" in reply.get("error", {}).get("message", ""),
              f"no Cantrip: a visible error for the request ({done.stdout[:200]!r})")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print("mcp relay:", "FAILED" if FAILURES else "all passed")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
