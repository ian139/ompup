from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from ompup import hosts as hosts_module  # noqa: E402
from ompup.hosts import (  # noqa: E402
    HostConfig,
    HostProbe,
    HostSelectionError,
    choose_host,
    load_hosts,
    pin_host,
    probe_hosts,
    remote_project_dir,
    resolve_project,
)


def probe(
    host: HostConfig,
    *,
    free_gb: float,
    load: float,
    session: bool = False,
    checkout: bool = False,
) -> HostProbe:
    gib = 1024**3
    return HostProbe(
        host=host,
        reachable=True,
        latency_ms=20,
        system="darwin" if "macos" in host.roles else "linux",
        arch="arm64" if "macos" in host.roles else "x86_64",
        cpu_count=8,
        load1=load,
        memory_total=16 * gib,
        memory_available=8 * gib,
        disk_total=1000 * gib,
        disk_free=int(free_gb * gib),
        project_exists=checkout,
        session_exists=session,
        tools_ok=True,
    )


class ProjectResolutionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name).resolve()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_initializes_missing_repository_for_explicit_directory(self) -> None:
        project = self.base / "fresh-project"
        project.mkdir()
        (project / "notes.txt").write_text("hello\n")

        root = resolve_project(str(project), init_missing=True)

        self.assertEqual(root, project)
        self.assertTrue((project / ".git").is_dir())

    def test_initializes_missing_repository_for_current_directory(self) -> None:
        project = self.base / "cwd-project"
        project.mkdir()
        original = Path.cwd()
        os.chdir(project)
        try:
            root = resolve_project(init_missing=True)
        finally:
            os.chdir(original)

        self.assertEqual(root, project)
        self.assertTrue((project / ".git").is_dir())

    def test_refuses_to_initialize_protected_directories(self) -> None:
        fake_home = self.base / "home"
        (fake_home / "Downloads").mkdir(parents=True)
        with mock.patch.object(hosts_module.Path, "home", return_value=fake_home):
            for target in (fake_home, fake_home / "Downloads"):
                with self.assertRaisesRegex(HostSelectionError, "refusing to initialize"):
                    resolve_project(str(target), init_missing=True)
                self.assertFalse((target / ".git").exists())

    def test_non_repository_without_init_reports_actionable_error(self) -> None:
        plain = self.base / "plain"
        plain.mkdir()
        projects_root = self.base / "projects"
        candidate = projects_root / "candidate"
        candidate.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(candidate)], check=True)
        original = Path.cwd()
        os.chdir(plain)
        try:
            with (
                mock.patch.dict(os.environ, {"OMPUP_PROJECTS_ROOT": str(projects_root)}),
                mock.patch.object(hosts_module, "sys_stdin_is_tty", return_value=False),
                self.assertRaisesRegex(HostSelectionError, "not inside a Git repository"),
            ):
                resolve_project()
        finally:
            os.chdir(original)


class HostSelectionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        (self.root / "file.txt").write_text("test\n")
        self.hostinger = HostConfig(
            "hostinger", "hostinger-ssh", ("general", "linux", "services"), reserve_gb=40
        )
        self.contabo = HostConfig(
            "contabo", "contabo-ssh", ("general", "linux", "storage"), reserve_gb=100, priority=10
        )
        self.m1 = HostConfig("m1", "m1-ssh", ("general", "macos"), reserve_gb=25)
        self.hosts = [self.hostinger, self.contabo, self.m1]

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_capacity_score_prefers_storage_headroom_for_general_work(self) -> None:
        probes = [
            probe(self.hostinger, free_gb=45, load=4),
            probe(self.contabo, free_gb=600, load=1),
            probe(self.m1, free_gb=35, load=1),
        ]
        choice = choose_host(self.hosts, probes, self.root, "general")
        self.assertEqual(choice.host.name, "contabo")

    def test_profile_is_a_hard_capability_constraint(self) -> None:
        probes = [
            probe(self.hostinger, free_gb=200, load=0),
            probe(self.contabo, free_gb=600, load=0),
            probe(self.m1, free_gb=35, load=7),
        ]
        choice = choose_host(self.hosts, probes, self.root, "macos")
        self.assertEqual(choice.host.name, "m1")

    def test_live_session_beats_capacity_score(self) -> None:
        probes = [
            probe(self.hostinger, free_gb=45, load=4, session=True),
            probe(self.contabo, free_gb=600, load=1),
            probe(self.m1, free_gb=35, load=1),
        ]
        choice = choose_host(self.hosts, probes, self.root, "general")
        self.assertEqual(choice.host.name, "hostinger")
        self.assertEqual(choice.reason, "existing tmux session")

    def test_existing_checkout_is_sticky(self) -> None:
        probes = [
            probe(self.hostinger, free_gb=45, load=4),
            probe(self.contabo, free_gb=600, load=1),
            probe(self.m1, free_gb=35, load=1, checkout=True),
        ]
        choice = choose_host(self.hosts, probes, self.root, "general")
        self.assertEqual(choice.host.name, "m1")
        self.assertEqual(choice.reason, "existing remote checkout")

    def test_project_pin_beats_live_capacity(self) -> None:
        pin_host(self.root, "hostinger")
        probes = [
            probe(self.hostinger, free_gb=45, load=4),
            probe(self.contabo, free_gb=600, load=1),
            probe(self.m1, free_gb=35, load=1),
        ]
        choice = choose_host(self.hosts, probes, self.root, "general")
        self.assertEqual(choice.host.name, "hostinger")
        self.assertEqual(choice.reason, "project pin")

    def test_explicit_new_placement_respects_disk_reserve(self) -> None:
        probes = [probe(self.hostinger, free_gb=40.5, load=0)]
        with self.assertRaisesRegex(HostSelectionError, "including reserve"):
            choose_host(self.hosts, probes, self.root, "general", explicit="hostinger")

    def test_multiple_live_sessions_require_an_explicit_pin(self) -> None:
        probes = [
            probe(self.hostinger, free_gb=45, load=4, session=True),
            probe(self.contabo, free_gb=600, load=1, session=True),
            probe(self.m1, free_gb=35, load=1),
        ]
        with self.assertRaisesRegex(HostSelectionError, "multiple hosts"):
            choose_host(self.hosts, probes, self.root, "general")

    def test_host_roles_must_be_an_array(self) -> None:
        config = self.root / "hosts.json"
        config.write_text(json.dumps({"hosts": [{"name": "box", "ssh": "box", "roles": "linux"}]}))
        with (
            mock.patch.object(hosts_module, "CONFIG_PATH", config),
            self.assertRaisesRegex(HostSelectionError, "roles must be"),
        ):
            load_hosts()

    def test_unknown_host_fields_are_rejected(self) -> None:
        config = self.root / "hosts.json"
        config.write_text(json.dumps({"hosts": [{"name": "box", "ssh": "box", "reserveGB": 10}]}))
        with (
            mock.patch.object(hosts_module, "CONFIG_PATH", config),
            self.assertRaisesRegex(HostSelectionError, "reserveGB"),
        ):
            load_hosts()

    def test_host_specific_remote_root_is_used(self) -> None:
        host = HostConfig("box", "box", remote_root="srv/projects")
        self.assertEqual(remote_project_dir(host, "Project", "Projects"), "srv/projects/Project")
    def test_probe_hosts_uses_each_hosts_remote_root(self) -> None:
        hosts = [
            HostConfig("default", "default"),
            HostConfig("custom", "custom", remote_root="srv/projects"),
        ]

        def fake_probe(host: HostConfig, remote_dir: str, _session: str) -> HostProbe:
            return HostProbe(host, True, 1, remote_dir=remote_dir)

        with mock.patch.object(hosts_module, "probe_host", side_effect=fake_probe):
            probes = probe_hosts(hosts, "Project", "Project", "Projects")
        self.assertEqual(
            [probe.remote_dir for probe in probes],
            ["Projects/Project", "srv/projects/Project"],
        )

if __name__ == "__main__":
    unittest.main()
