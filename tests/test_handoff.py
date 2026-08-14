from __future__ import annotations

import importlib.machinery
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
LOADER = importlib.machinery.SourceFileLoader("ompup_cli", str(ROOT / "bin" / "ompup"))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
assert SPEC is not None
CLI = importlib.util.module_from_spec(SPEC)
sys.modules[LOADER.name] = CLI
LOADER.exec_module(CLI)


class HandoffContractTests(unittest.TestCase):
    def test_handoff_parser_captures_session_identity(self) -> None:
        argv = [
            "ompup",
            "handoff",
            "--host",
            "compute",
            "--session-file",
            "/tmp/session.jsonl",
            "--session-id",
            "session-123",
            "--prepare-only",
        ]
        with patch.object(sys, "argv", argv):
            args = CLI.parse_args()

        self.assertEqual(args.command, "handoff")
        self.assertEqual(args.host, "compute")
        self.assertEqual(args.session_file, "/tmp/session.jsonl")
        self.assertEqual(args.session_id, "session-123")
        self.assertTrue(args.prepare_only)

    def test_cleanup_never_kills_a_session_not_started_by_handoff(self) -> None:
        with patch.object(CLI, "ssh_script") as ssh_script:
            CLI.cleanup_handoff("project", ".local/state/ompup/handoffs/project/id", kill_session=False)

        ssh_script.assert_called_once_with(
            CLI.CLEANUP_HANDOFF_SCRIPT,
            "project",
            ".local/state/ompup/handoffs/project/id",
            "0",
            check=False,
        )

    def test_cleanup_marks_owned_remote_session_for_termination(self) -> None:
        with patch.object(CLI, "ssh_script") as ssh_script:
            CLI.cleanup_handoff("project", ".local/state/ompup/handoffs/project/id", kill_session=True)

        self.assertEqual(ssh_script.call_args.args[3], "1")

    def test_session_checksum_changes_with_content(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            session = Path(directory) / "session.jsonl"
            session.write_text("first\n")
            first = CLI.file_sha256(session)
            session.write_text("second\n")
            second = CLI.file_sha256(session)

        self.assertNotEqual(first, second)


if __name__ == "__main__":
    unittest.main()
