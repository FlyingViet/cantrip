"""The cantrip script sends the app's own commands to the app and everything else to an agent as a question."""
import importlib.machinery
import importlib.util
import os
import re
import sys
import unittest

sys.dont_write_bytecode = True  # the script has no .py name; keep Scripts/ free of caches

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def load_script():
    path = os.path.join(ROOT, "Scripts", "cantrip")
    loader = importlib.machinery.SourceFileLoader("cantrip_script", path)
    spec = importlib.util.spec_from_loader("cantrip_script", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class CLIRoutingTests(unittest.TestCase):
    cli = load_script()

    def routed(self, *args):
        return self.cli.is_host_command(list(args))

    def test_every_app_command_is_routed(self):
        source = open(os.path.join(ROOT, "Sources", "Cantrip", "CantripCLI.swift")).read()
        commands = set(re.findall(r'"([a-z-]+)"', re.search(r"static let commands: Set<String> = \[([^\]]+)\]", source).group(1)))
        self.assertTrue(commands)
        for command in sorted(commands):
            self.assertTrue(self.routed(command), f"`cantrip {command}` must reach the app, not an agent")

    def test_every_dispatched_command_is_listed(self):
        """A command `CantripCLI.run` handles but `commands` leaves out never runs: the app binary
        opens its window instead (how `schedule` shipped unreachable)."""
        source = open(os.path.join(ROOT, "Sources", "Cantrip", "CantripCLI.swift")).read()
        listed = set(re.findall(r'"([a-z-]+)"', re.search(r"static let commands: Set<String> = \[([^\]]+)\]", source).group(1)))
        dispatch = source[source.index("static func run("):source.index("default: print(usage)")]
        handled = {name for line in re.findall(r"^\s*case (\"[^:]+):", dispatch, re.M) for name in re.findall(r'"([a-z-]+)"', line)}
        self.assertTrue(handled)
        self.assertEqual(handled - listed, set(), "handled by CantripCLI.run but not in CantripCLI.commands")

    def test_documented_commands_reach_the_app(self):
        for args in [["privacy", "report"], ["privacy", "report", "--days", "14"], ["privacy", "test", "hello"],
                     ["muse", "feeds"], ["muse", "log", "5"], ["handoffs", "--days", "7"], ["handoffs"],
                     ["sim", "acquire", "--device", "iPhone"], ["sim", "release"], ["api", "key", "new"], ["api", "--json"],
                     ["weather", "Portland, OR"], ["build-queue", "run"], ["seed-worktree", "/tmp/x"],
                     ["tab", "list"], ["mcp", "list"], ["status"], ["doctor"],
                     ["schedule", "list"], ["schedule", "add", "--at", "22:35", "--title", "Check", "--", "x"],
                     ["schedule", "cancel", "step:1"], ["schedule"]]:
            self.assertTrue(self.routed(*args), args)

    def test_questions_stay_questions(self):
        for args in [["privacy", "settings", "for", "my", "tabs?"], ["muse", "about", "this"],
                     ["sim", "racing", "games?"], ["api", "design", "review"], ["handoffs", "from", "today?"],
                     ["tab", "completion", "in", "zsh?"], ["schedule", "a", "meeting", "for", "me"], ["why", "is", "the", "sky", "blue"], ["summarize", "privacy", "test"]]:
            self.assertFalse(self.routed(*args), args)
        self.assertFalse(self.routed())


if __name__ == "__main__":
    unittest.main()
