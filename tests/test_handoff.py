from __future__ import annotations

from contextlib import redirect_stderr
import io
import importlib.machinery
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace


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
    def test_environment_parser_targets_multiple_hosts(self) -> None:
        argv = [
            "ompup",
            "env",
            "sync",
            "--host",
            "compute",
            "--host",
            "storage",
        ]
        with patch.object(sys, "argv", argv):
            args = CLI.parse_args()

        self.assertEqual(args.command, "env")
        self.assertEqual(args.env_command, "sync")
        self.assertEqual(args.host, ["compute", "storage"])

    def test_auth_migrate_parser_preserves_dry_run(self) -> None:
        with patch.object(sys, "argv", ["ompup", "auth", "migrate", "--dry-run"]):
            args = CLI.parse_args()

        self.assertEqual(args.command, "auth")
        self.assertEqual(args.auth_command, "migrate")
        self.assertTrue(args.dry_run)

    def test_preserve_mode_refuses_environment_sync(self) -> None:
        args = SimpleNamespace(env_command="sync", host=[], all=False)
        host = SimpleNamespace(name="compute")
        with (
            patch.object(CLI, "load_hosts", return_value=[host]),
            patch.object(
                CLI,
                "load_environment_config",
                return_value=SimpleNamespace(mode="preserve"),
            ),
            self.assertRaisesRegex(RuntimeError, "preserve mode"),
        ):
            CLI.run_environment_command(args)
    def test_environment_gate_rejects_unversioned_remote_session(self) -> None:
        choice = SimpleNamespace(
            host=SimpleNamespace(name="compute"),
            probe=SimpleNamespace(session_exists=True),
        )
        status = SimpleNamespace(fingerprint="a" * 64)
        with (
            patch.object(
                CLI,
                "load_environment_config",
                return_value=SimpleNamespace(mode="mirror"),
            ),
            patch.object(CLI, "ensure_environment", return_value=status),
            patch.object(CLI, "session_environment", return_value=""),
            self.assertRaises(SystemExit),
        ):
            CLI.verify_selected_environment(choice, "project")
    def test_preserve_mode_accepts_an_existing_unmanaged_session(self) -> None:
        choice = SimpleNamespace(
            host=SimpleNamespace(name="compute"),
            probe=SimpleNamespace(session_exists=True),
        )
        status = SimpleNamespace(fingerprint="", omp_version="omp/current")
        with (
            patch.object(
                CLI,
                "load_environment_config",
                return_value=SimpleNamespace(mode="preserve"),
            ),
            patch.object(CLI, "ensure_environment", return_value=status),
            patch.object(CLI, "session_environment") as session_environment,
        ):
            actual = CLI.verify_selected_environment(choice, "project")
        self.assertIs(actual, status)
        session_environment.assert_not_called()


    def test_attach_records_environment_fingerprint_in_tmux(self) -> None:
        with patch.object(CLI.os, "execvp") as execvp:
            CLI.REMOTE = "compute-box"
            CLI.attach("project", "Projects/project", "omp", "b" * 64)

        remote_command = execvp.call_args.args[1][-1]
        self.assertIn("@ompup-environment", remote_command)
        self.assertIn("b" * 64, remote_command)
    def test_attach_preserve_mode_does_not_require_environment_metadata(self) -> None:
        with patch.object(CLI.os, "execvp") as execvp:
            CLI.REMOTE = "compute-box"
            CLI.attach("Project", "Projects/Project", "omp", "")
        remote_command = execvp.call_args.args[1][-1]
        self.assertNotIn("@ompup-environment", remote_command)

    def test_detached_head_has_actionable_error(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            CLI.run(["git", "init", "-q", str(root)])
            (root / "file.txt").write_text("content\n")
            CLI.run(["git", "-C", str(root), "add", "file.txt"])
            CLI.run(
                [
                    "git",
                    "-C",
                    str(root),
                    "-c",
                    "core.hooksPath=/dev/null",
                    "-c",
                    "user.name=Test",
                    "-c",
                    "user.email=test@example.com",
                    "commit",
                    "-qm",
                    "initial",
                ]
            )
            head = CLI.git(root, "rev-parse", "HEAD")
            CLI.run(["git", "-C", str(root), "checkout", "-q", "--detach", head])
            stderr = io.StringIO()
            with redirect_stderr(stderr), self.assertRaises(SystemExit):
                CLI.current_branch(root)
            self.assertIn("check out a local branch", stderr.getvalue())
    def test_credential_query_is_not_copied_as_remote_origin(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            CLI.run(["git", "init", "-q", str(root)])
            CLI.run(
                [
                    "git",
                    "-C",
                    str(root),
                    "remote",
                    "add",
                    "origin",
                    "https://example.com/repo.git?access_token=private",
                ]
            )
            _identity, remote_origin = CLI.project_identity(root)
        self.assertEqual(remote_origin, "")

    def test_project_sync_does_not_require_local_rsync(self) -> None:
        args = SimpleNamespace(command="sync")
        with patch.object(
            CLI.shutil,
            "which",
            side_effect=lambda command: None if command == "rsync" else f"/usr/bin/{command}",
        ):
            CLI.validate_local_requirements(args)

    def test_handoff_requires_remote_rsync(self) -> None:
        CLI.REMOTE = "compute-box"
        missing = SimpleNamespace(returncode=1)
        with (
            patch.object(CLI, "ssh_script", return_value=missing),
            self.assertRaisesRegex(SystemExit, "1"),
        ):
            CLI.require_remote_command("rsync")






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
