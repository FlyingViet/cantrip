"""Tests for Scripts/mcp-on-demand, driven over stdio against fake_server.py."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
LAUNCHER = os.path.join(HERE, "..", "..", "Scripts", "mcp-on-demand")
PROTOCOL = "2025-06-18"


class Session:
    def __init__(self, test, tools="echo", server=None):
        env = dict(os.environ, FAKE_STARTS=test.starts, FAKE_TOOLS=tools)
        self.process = subprocess.Popen(
            [sys.executable, LAUNCHER, "--cache-dir", test.cache, "--",
             sys.executable, server or test.server],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env, encoding="utf-8", bufsize=1)
        self.next_id = 0
        self.notifications = []

    def send(self, message):
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def request(self, method, params=None, answer=None):
        self.next_id += 1
        request_id = self.next_id
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}})
        while True:
            line = self.process.stdout.readline()
            if not line:
                raise AssertionError("launcher closed stdout waiting for %s" % method)
            message = json.loads(line)
            if message.get("id") == request_id and "method" not in message:
                return message
            if "method" in message and "id" in message and answer:
                self.send({"jsonrpc": "2.0", "id": message["id"], "result": answer(message)})
            elif "method" in message:
                self.notifications.append(message)

    def handshake(self, protocol=PROTOCOL):
        reply = self.request("initialize", {"protocolVersion": protocol, "capabilities": {},
                                            "clientInfo": {"name": "test", "version": "1"}})
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return reply

    def close(self):
        self.process.stdin.close()
        self.process.wait(10)
        self.process.stdout.close()


class MCPOnDemandTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="mcp-on-demand-")
        self.cache = os.path.join(self.folder, "cache")
        self.starts = os.path.join(self.folder, "starts")
        self.server = os.path.join(self.folder, "fake_server.py")
        shutil.copy(os.path.join(HERE, "fake_server.py"), self.server)

    def tearDown(self):
        shutil.rmtree(self.folder, ignore_errors=True)

    def start_count(self):
        if not os.path.exists(self.starts):
            return 0
        with open(self.starts) as handle:
            return len(handle.read().split())

    def record_cache(self, tools="echo"):
        session = Session(self, tools)
        session.handshake()
        session.request("tools/list")
        session.request("prompts/list")
        session.close()

    def test_first_run_starts_the_server_and_records_a_cache(self):
        session = Session(self)
        init = session.handshake()
        self.assertEqual(init["result"]["serverInfo"]["name"], "fake")
        self.assertEqual(self.start_count(), 1)
        tools = session.request("tools/list")
        self.assertEqual([tool["name"] for tool in tools["result"]["tools"]], ["echo"])
        session.close()
        self.assertTrue(os.listdir(self.cache))

    def test_cached_catalog_does_not_start_the_server(self):
        self.record_cache()
        session = Session(self)
        init = session.handshake()
        self.assertEqual(init["result"]["instructions"], "Fake server.")
        self.assertTrue(init["result"]["capabilities"]["tools"]["listChanged"])
        tools = session.request("tools/list")
        self.assertEqual(tools["result"]["tools"][0]["description"], "Tool echo ✦")
        self.assertEqual(session.request("prompts/list")["result"]["prompts"][0]["name"], "hello")
        self.assertEqual(session.request("ping")["result"], {})
        self.assertEqual(session.request("logging/setLevel", {"level": "debug"})["result"], {})
        time.sleep(0.3)
        self.assertEqual(self.start_count(), 1, "only the recording run started the server")
        session.close()
        self.assertEqual(self.start_count(), 1)

    def test_first_tool_call_starts_the_server_and_passes_messages_through(self):
        self.record_cache()
        session = Session(self)
        session.handshake()
        session.request("tools/list")
        reply = session.request("tools/call", {"name": "echo", "arguments": {"text": "héllo"}})
        self.assertEqual(reply["result"]["content"][0]["text"], 'echo:{"text": "héllo"}')
        self.assertEqual(self.start_count(), 2)
        self.assertIn("notifications/message", [n["method"] for n in session.notifications])
        asked = session.request("tools/call", {"name": "ask"},
                                answer=lambda request: {"roots": [{"uri": "file:///tmp"}]})
        self.assertEqual(asked["result"]["content"][0]["text"], "roots=1")
        self.assertEqual(self.start_count(), 2, "the started server is reused")
        session.close()

    def test_changed_catalog_updates_the_cache_and_notifies_the_client(self):
        self.record_cache(tools="echo")
        session = Session(self, tools="echo,newer")
        session.handshake()
        stale = session.request("tools/list")
        self.assertEqual([tool["name"] for tool in stale["result"]["tools"]], ["echo"])
        session.request("tools/call", {"name": "echo", "arguments": {}})
        deadline = time.time() + 5
        while time.time() < deadline and not any(
                n["method"] == "notifications/tools/list_changed" for n in session.notifications):
            session.request("ping")
            time.sleep(0.05)
        self.assertIn("notifications/tools/list_changed", [n["method"] for n in session.notifications])
        fresh = session.request("tools/list")
        self.assertEqual([tool["name"] for tool in fresh["result"]["tools"]], ["echo", "newer"])
        session.close()
        session = Session(self, tools="echo,newer")
        session.handshake()
        cached = session.request("tools/list")
        self.assertEqual([tool["name"] for tool in cached["result"]["tools"]], ["echo", "newer"])
        session.close()

    def test_server_exit_fails_the_call_and_the_next_call_restarts_it(self):
        self.record_cache()
        session = Session(self)
        session.handshake()
        crashed = session.request("tools/call", {"name": "crash"})
        self.assertIn("exited", crashed["error"]["message"])
        reply = session.request("tools/call", {"name": "echo", "arguments": {}})
        self.assertEqual(reply["result"]["content"][0]["text"], "echo:{}")
        self.assertEqual(self.start_count(), 3)
        session.close()

    def test_closing_stdin_stops_the_server(self):
        self.record_cache()
        session = Session(self)
        session.handshake()
        session.request("tools/call", {"name": "echo", "arguments": {}})
        with open(self.starts) as handle:
            pid = int(handle.read().split()[-1])
        session.close()
        deadline = time.time() + 5
        while time.time() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)
        else:
            self.fail("the server outlived the launcher's stdin")

    def test_other_protocol_version_or_changed_server_skips_the_cache(self):
        self.record_cache()
        session = Session(self)
        session.handshake(protocol="2024-11-05")
        self.assertEqual(self.start_count(), 2)
        session.close()
        with open(self.server, "a") as handle:
            handle.write("\n# changed\n")
        session = Session(self)
        session.handshake()
        self.assertEqual(self.start_count(), 3)
        session.close()

    def test_server_discover_is_declined_without_starting_the_server(self):
        self.record_cache()
        session = Session(self)
        declined = session.request("server/discover", {})
        self.assertEqual(declined["error"]["code"], -32601)
        session.handshake()
        session.request("tools/list")
        self.assertEqual(self.start_count(), 1)
        session.close()

    def test_initialize_with_another_protocol_restarts_a_running_server(self):
        self.record_cache()
        session = Session(self)
        session.handshake()
        session.request("tools/call", {"name": "echo", "arguments": {}})
        self.assertEqual(self.start_count(), 2)
        again = session.request("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                               "clientInfo": {"name": "test", "version": "1"}})
        self.assertEqual(again["result"]["protocolVersion"], "2024-11-05")
        self.assertEqual(self.start_count(), 3)
        reply = session.request("tools/call", {"name": "echo", "arguments": {}})
        self.assertEqual(reply["result"]["content"][0]["text"], "echo:{}")
        session.close()

    def test_server_that_cannot_start_reports_an_error(self):
        session = Session(self, server=os.path.join(self.folder, "missing.py"))
        reply = session.request("initialize", {"protocolVersion": PROTOCOL, "capabilities": {},
                                               "clientInfo": {"name": "test", "version": "1"}})
        self.assertIn("error", reply)
        session.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
