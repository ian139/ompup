from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from ompup.hosts import (  # noqa: E402
    HostConfig,
    HostProbe,
    HostSelectionError,
    choose_host,
    pin_host,
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


if __name__ == "__main__":
    unittest.main()
