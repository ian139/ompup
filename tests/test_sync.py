from __future__ import annotations

from contextlib import contextmanager
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import subprocess
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
LOADER = importlib.machinery.SourceFileLoader("ompup_sync_cli", str(ROOT / "bin" / "ompup"))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
assert SPEC is not None
CLI = importlib.util.module_from_spec(SPEC)
sys.modules[LOADER.name] = CLI
LOADER.exec_module(CLI)


class GitTransportIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.home = Path(self.temporary.name) / "home"
        self.home.mkdir()
        self.local = Path(self.temporary.name) / "local"
        self.remote_dir = "Projects/project"
        self.remote = self.home / self.remote_dir
        self.state_key = "0123456789abcdef-project"
        self.identity = "a" * 64
        CLI.REMOTE = "test-host"
        CLI.SSH_CONTROL_PATH = ""
        self._init_repository(self.local)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _init_repository(self, path: Path) -> None:
        CLI.run(["git", "init", "-q", "-b", "main", str(path)])
        (path / "tracked.txt").write_text("initial\n")
        self._commit(path, "initial")

    def _commit(self, path: Path, message: str) -> str:
        CLI.run(["git", "-C", str(path), "add", "-A"])
        CLI.run(
            [
                "git",
                "-C",
                str(path),
                "-c",
                "core.hooksPath=/dev/null",
                "-c",
                "user.name=Test",
                "-c",
                "user.email=test@example.com",
                "commit",
                "-qm",
                message,
            ]
        )
        return CLI.git(path, "rev-parse", "HEAD")

    def _ssh_script(self, script: str, *args: str, check: bool = True, capture: bool = False):
        env = os.environ.copy()
        env["HOME"] = str(self.home)
        return subprocess.run(
            ["bash", "-s", "--", *args],
            cwd=self.home,
            env=env,
            input=script,
            text=True,
            check=check,
            capture_output=capture,
        )

    def _ssh_command(self, command: str, *, check: bool = True, capture: bool = False):
        env = os.environ.copy()
        env["HOME"] = str(self.home)
        return subprocess.run(
            ["bash", "-c", command],
            cwd=self.home,
            env=env,
            text=True,
            check=check,
            capture_output=capture,
        )

    @contextmanager
    def _local_transport(self):
        with (
            patch.object(CLI, "ssh_script", side_effect=self._ssh_script),
            patch.object(CLI, "ssh_command", side_effect=self._ssh_command),
            patch.object(CLI, "remote_repository", return_value=str(self.remote)),
            patch.object(CLI, "scan_history"),
            patch.object(CLI, "scan_snapshot_tree"),
        ):
            yield

    def _assert_no_transport_refs(self, repository: Path) -> None:
        refs = CLI.git(repository, "for-each-ref", "--format=%(refname)", "refs/ompup")
        self.assertEqual(refs, "")

    def test_bootstrap_transfers_a_repository_with_no_commits(self) -> None:
        fresh = Path(self.temporary.name) / "fresh"
        CLI.run(["git", "init", "-q", "-b", "main", str(fresh)])
        (fresh / "notes.txt").write_text("uncommitted\n")

        with self._local_transport():
            CLI.sync_up(fresh, "project", self.state_key, self.remote_dir, self.identity, "")

        self.assertEqual((self.remote / "notes.txt").read_text(), "uncommitted\n")
        with self._local_transport():
            self.assertEqual(CLI.remote_state(self.remote_dir), CLI.local_state(fresh))
        self._assert_no_transport_refs(fresh)

    def test_ssh_transport_uses_private_process_scoped_socket(self) -> None:
        with patch.object(CLI.Path, "home", return_value=self.home):
            CLI.configure_ssh_transport("compute-box")

        control_dir = self.home / ".cache" / "ompup" / "ssh"
        self.assertEqual(stat.S_IMODE(control_dir.stat().st_mode), 0o700)
        self.assertIn(str(os.getpid()), CLI.SSH_CONTROL_PATH)
        self.assertIn("ControlMaster=auto", CLI.ssh_transport_args())
        self.assertIn("ControlPersist=60", CLI.ssh_transport_args())
        self.assertIn(CLI.SSH_CONTROL_PATH, CLI.git_transport_env()["GIT_SSH_COMMAND"])

    def test_bootstrap_and_incremental_push_preserve_dirty_snapshot(self) -> None:
        (self.local / "tracked.txt").write_text("dirty initial\n")
        (self.local / "untracked.txt").write_text("untracked initial\n")

        with self._local_transport():
            CLI.sync_up(
                self.local,
                "project",
                self.state_key,
                self.remote_dir,
                self.identity,
                "",
            )

            self.assertEqual((self.remote / "tracked.txt").read_text(), "dirty initial\n")
            self.assertEqual((self.remote / "untracked.txt").read_text(), "untracked initial\n")
            self.assertEqual(CLI.local_state(self.remote), CLI.local_state(self.local))

            self._commit(self.local, "commit snapshot")
            (self.local / "tracked.txt").write_text("second dirty state\n")
            (self.local / "new.txt").write_text("new state\n")
            CLI.sync_up(
                self.local,
                "project",
                self.state_key,
                self.remote_dir,
                self.identity,
                "",
            )

        self.assertEqual((self.remote / "tracked.txt").read_text(), "second dirty state\n")
        self.assertEqual((self.remote / "new.txt").read_text(), "new state\n")
        self.assertEqual(CLI.local_state(self.remote), CLI.local_state(self.local))
        self._assert_no_transport_refs(self.local)
        self._assert_no_transport_refs(self.remote)

    def test_pull_fetches_remote_commit_and_dirty_snapshot(self) -> None:
        with self._local_transport():
            CLI.sync_up(
                self.local,
                "project",
                self.state_key,
                self.remote_dir,
                self.identity,
                "",
            )
            (self.remote / "tracked.txt").write_text("remote commit\n")
            self._commit(self.remote, "remote commit")
            (self.remote / "tracked.txt").write_text("remote dirty\n")
            (self.remote / "remote-only.txt").write_text("remote only\n")

            CLI.sync_down(
                self.local,
                "project",
                self.state_key,
                self.remote_dir,
                self.identity,
            )

        self.assertEqual((self.local / "tracked.txt").read_text(), "remote dirty\n")
        self.assertEqual((self.local / "remote-only.txt").read_text(), "remote only\n")
        self.assertEqual(CLI.local_state(self.local), CLI.local_state(self.remote))
        self._assert_no_transport_refs(self.local)
        self._assert_no_transport_refs(self.remote)

    def test_concurrent_local_and_remote_changes_still_refuse_sync(self) -> None:
        with self._local_transport():
            CLI.sync_up(
                self.local,
                "project",
                self.state_key,
                self.remote_dir,
                self.identity,
                "",
            )
            (self.local / "tracked.txt").write_text("local change\n")
            (self.remote / "tracked.txt").write_text("remote change\n")

            with self.assertRaises(SystemExit):
                CLI.sync_up(
                    self.local,
                    "project",
                    self.state_key,
                    self.remote_dir,
                    self.identity,
                    "",
                )

        self.assertEqual((self.local / "tracked.txt").read_text(), "local change\n")
        self.assertEqual((self.remote / "tracked.txt").read_text(), "remote change\n")


if __name__ == "__main__":
    unittest.main()
