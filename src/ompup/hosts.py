from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
import json
import math
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import time
from typing import Iterable

CONFIG_PATH = Path(os.environ.get("OMPUP_CONFIG", Path.home() / ".config/ompup/hosts.json")).expanduser()

REMOTE_PROBE = r'''
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys

remote_dir, session, launch = sys.argv[1:4]
home = Path.home()
disk = shutil.disk_usage(home)
mem_total = 0
mem_available = 0
if Path("/proc/meminfo").is_file():
    values = {}
    for line in Path("/proc/meminfo").read_text().splitlines():
        key, value = line.split(":", 1)
        values[key] = int(value.split()[0]) * 1024
    mem_total = values.get("MemTotal", 0)
    mem_available = values.get("MemAvailable", values.get("MemFree", 0))
else:
    try:
        mem_total = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True))
        pages = {}
        page_size = 4096
        for line in subprocess.check_output(["vm_stat"], text=True).splitlines():
            if "page size of" in line:
                page_size = int(line.split("page size of", 1)[1].split("bytes", 1)[0])
            elif ":" in line:
                key, value = line.split(":", 1)
                pages[key] = int(value.strip().rstrip("."))
        mem_available = page_size * sum(pages.get(key, 0) for key in (
            "Pages free", "Pages inactive", "Pages speculative", "Pages purgeable"
        ))
    except (OSError, subprocess.SubprocessError, ValueError):
        pass

def command_ok(command):
    return shutil.which(command) is not None

shell = os.environ.get("SHELL", "/bin/sh")
try:
    omp_check = subprocess.run(
        [shell, "-lc", f"{launch} --version"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=8,
    ).returncode == 0
except (OSError, subprocess.SubprocessError):
    omp_check = False

project = home / remote_dir
session_check = subprocess.run(
    ["tmux", "has-session", "-t", f"={session}"],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
).returncode == 0 if command_ok("tmux") else False

print(json.dumps({
    "hostname": platform.node(),
    "system": platform.system().lower(),
    "arch": platform.machine().lower(),
    "cpu_count": os.cpu_count() or 1,
    "load1": os.getloadavg()[0],
    "memory_total": mem_total,
    "memory_available": mem_available,
    "disk_total": disk.total,
    "disk_free": disk.free,
    "project_exists": project.is_dir(),
    "session_exists": session_check,
    "tools_ok": all(command_ok(command) for command in ("bash", "git", "rsync", "tmux", "python3")) and omp_check,
}))
'''


class HostSelectionError(RuntimeError):
    pass


@dataclass(frozen=True)
class HostConfig:
    name: str
    ssh: str
    roles: tuple[str, ...] = ("general",)
    reserve_gb: float = 10.0
    priority: float = 0.0
    launch: str = "omp"


@dataclass(frozen=True)
class HostProbe:
    host: HostConfig
    reachable: bool
    latency_ms: float
    hostname: str = ""
    system: str = ""
    arch: str = ""
    cpu_count: int = 1
    load1: float = math.inf
    memory_total: int = 0
    memory_available: int = 0
    disk_total: int = 0
    disk_free: int = 0
    project_exists: bool = False
    session_exists: bool = False
    tools_ok: bool = False
    error: str = ""

    @property
    def free_gb(self) -> float:
        return self.disk_free / (1024**3)

    @property
    def load_per_cpu(self) -> float:
        return self.load1 / max(self.cpu_count, 1)


@dataclass(frozen=True)
class HostChoice:
    host: HostConfig
    probe: HostProbe
    reason: str
    score: float


def _validate_host(raw: dict) -> HostConfig:
    name = str(raw.get("name", "")).strip()
    ssh = str(raw.get("ssh", "")).strip()
    if not name or not ssh or any(char.isspace() for char in name):
        raise HostSelectionError("each configured host needs a whitespace-free name and SSH destination")
    roles = tuple(str(role).lower() for role in raw.get("roles", ["general"]))
    return HostConfig(
        name=name,
        ssh=ssh,
        roles=roles or ("general",),
        reserve_gb=float(raw.get("reserve_gb", 10)),
        priority=float(raw.get("priority", 0)),
        launch=str(raw.get("launch", "omp")),
    )


def load_hosts(fallback_host: str = "") -> list[HostConfig]:
    if CONFIG_PATH.is_file():
        try:
            payload = json.loads(CONFIG_PATH.read_text())
            hosts = [_validate_host(item) for item in payload.get("hosts", [])]
        except (OSError, ValueError, TypeError) as error:
            raise HostSelectionError(f"invalid host configuration {CONFIG_PATH}: {error}") from error
        if not hosts:
            raise HostSelectionError(f"no hosts configured in {CONFIG_PATH}")
        if fallback_host and fallback_host != "auto" and not any(
            fallback_host in {host.name, host.ssh} for host in hosts
        ):
            hosts.append(HostConfig(name=fallback_host, ssh=fallback_host))
    elif fallback_host and fallback_host != "auto":
        hosts = [HostConfig(name=fallback_host, ssh=fallback_host)]
    else:
        raise HostSelectionError(
            f"create {CONFIG_PATH} or set OMPUP_HOST to an SSH destination"
        )
    names = [host.name for host in hosts]
    if len(names) != len(set(names)):
        raise HostSelectionError(f"host names must be unique in {CONFIG_PATH}")
    return hosts


def find_host(hosts: Iterable[HostConfig], value: str) -> HostConfig:
    matches = [host for host in hosts if value in {host.name, host.ssh}]
    if len(matches) != 1:
        choices = ", ".join(host.name for host in hosts)
        raise HostSelectionError(f"unknown host {value!r}; configured hosts: {choices}")
    return matches[0]


def probe_host(host: HostConfig, remote_dir: str, session: str, timeout: int = 10) -> HostProbe:
    command = "python3 - " + " ".join(
        shlex.quote(value) for value in (remote_dir, session, host.launch)
    )
    started = time.monotonic()
    try:
        result = subprocess.run(
            ["ssh", "-o", f"ConnectTimeout={timeout}", host.ssh, command],
            input=REMOTE_PROBE,
            text=True,
            capture_output=True,
            timeout=timeout + 5,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return HostProbe(host=host, reachable=False, latency_ms=(time.monotonic() - started) * 1000, error=str(error))
    latency = (time.monotonic() - started) * 1000
    if result.returncode != 0:
        message = result.stderr.strip().splitlines()[-1] if result.stderr.strip() else f"ssh exit {result.returncode}"
        return HostProbe(host=host, reachable=False, latency_ms=latency, error=message)
    try:
        data = json.loads(result.stdout)
        return HostProbe(host=host, reachable=True, latency_ms=latency, **data)
    except (TypeError, ValueError) as error:
        return HostProbe(host=host, reachable=False, latency_ms=latency, error=f"invalid probe output: {error}")


def probe_hosts(hosts: Iterable[HostConfig], remote_dir: str, session: str) -> list[HostProbe]:
    host_list = list(hosts)
    results: dict[str, HostProbe] = {}
    with ThreadPoolExecutor(max_workers=min(len(host_list), 8) or 1) as executor:
        futures = {executor.submit(probe_host, host, remote_dir, session): host for host in host_list}
        for future in as_completed(futures):
            probe = future.result()
            results[probe.host.name] = probe
    return [results[host.name] for host in host_list]


def project_profile(root: Path, requested: str = "auto") -> str:
    if requested != "auto":
        return requested
    configured = subprocess.run(
        ["git", "-C", str(root), "config", "--local", "--get", "ompup.profile"],
        text=True,
        capture_output=True,
    )
    if configured.returncode == 0 and configured.stdout.strip():
        return configured.stdout.strip().lower()
    mac_markers = [root / "Package.swift", *root.glob("*.xcodeproj"), *root.glob("*.xcworkspace")]
    if any(path.exists() for path in mac_markers):
        return "macos"
    return "general"


def project_bytes(root: Path) -> int:
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-co", "--exclude-standard", "-z"],
        capture_output=True,
        check=True,
    )
    total = 0
    for raw in result.stdout.split(b"\0"):
        if not raw:
            continue
        try:
            path = root / os.fsdecode(raw)
            if path.is_file() and not path.is_symlink():
                total += path.stat().st_size
        except OSError:
            continue
    return total


def pinned_host(root: Path) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), "config", "--local", "--get", "ompup.host"],
        text=True,
        capture_output=True,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def pin_host(root: Path, host: str) -> None:
    subprocess.run(["git", "-C", str(root), "config", "--local", "ompup.host", host], check=True)


def unpin_host(root: Path) -> None:
    subprocess.run(
        ["git", "-C", str(root), "config", "--local", "--unset-all", "ompup.host"],
        check=False,
    )


def _score(probe: HostProbe, profile: str, required_gb: float) -> float | None:
    host = probe.host
    if not probe.reachable or not probe.tools_ok:
        return None
    if probe.free_gb < host.reserve_gb + required_gb:
        return None
    if profile != "auto" and profile not in host.roles:
        return None
    role_bonus = 35.0 if profile in host.roles else 0.0
    free_ratio = probe.disk_free / max(probe.disk_total, 1)
    disk_headroom = min(max(probe.free_gb - host.reserve_gb, 0) / 100, 2)
    load_headroom = 1 - min(probe.load_per_cpu, 1)
    memory_headroom = probe.memory_available / max(probe.memory_total, 1)
    return host.priority + role_bonus + 25 * free_ratio + 15 * disk_headroom + 25 * load_headroom + 10 * memory_headroom


def choose_host(
    hosts: list[HostConfig],
    probes: list[HostProbe],
    root: Path,
    profile: str,
    explicit: str = "",
) -> HostChoice:
    size_gb = project_bytes(root) / (1024**3)
    required_gb = max(1.0, size_gb * 2)
    by_name = {probe.host.name: probe for probe in probes}
    pinned = pinned_host(root)
    requested = explicit or pinned
    if requested and requested != "auto":
        host = find_host(hosts, requested)
        probe = by_name[host.name]
        if not probe.reachable:
            raise HostSelectionError(f"pinned host {host.name} is unreachable: {probe.error}")
        if not probe.tools_ok:
            raise HostSelectionError(f"pinned host {host.name} is missing required tools or its OMP command")
        if not probe.project_exists and probe.free_gb < host.reserve_gb + required_gb:
            raise HostSelectionError(
                f"host {host.name} has {probe.free_gb:.0f} GB free; "
                f"new placement needs {host.reserve_gb + required_gb:.0f} GB including reserve"
            )
        return HostChoice(host, probe, "explicit host" if explicit else "project pin", math.inf)

    sessions = [probe for probe in probes if probe.reachable and probe.session_exists]
    if len(sessions) == 1:
        return HostChoice(sessions[0].host, sessions[0], "existing tmux session", math.inf)
    if len(sessions) > 1:
        names = ", ".join(probe.host.name for probe in sessions)
        raise HostSelectionError(f"project has live sessions on multiple hosts: {names}; pin one with `ompup pin HOST`")

    checkouts = [probe for probe in probes if probe.reachable and probe.project_exists]
    if len(checkouts) == 1:
        return HostChoice(checkouts[0].host, checkouts[0], "existing remote checkout", math.inf)
    if len(checkouts) > 1:
        names = ", ".join(probe.host.name for probe in checkouts)
        raise HostSelectionError(f"project exists on multiple hosts: {names}; pin one with `ompup pin HOST`")

    candidates: list[tuple[float, HostProbe]] = []
    for probe in probes:
        score = _score(probe, profile, required_gb)
        if score is not None:
            candidates.append((score, probe))
    if not candidates:
        details = "; ".join(
            f"{probe.host.name}: {probe.error or f'{probe.free_gb:.0f} GB free, tools_ok={probe.tools_ok}'}"
            for probe in probes
        )
        raise HostSelectionError(f"no eligible host for profile {profile}: {details}")
    score, probe = max(candidates, key=lambda item: (item[0], item[1].host.name))
    return HostChoice(probe.host, probe, f"capacity score for {profile} profile", score)


def project_candidates(projects_root: Path | None = None) -> list[Path]:
    base = projects_root or Path(os.environ.get("OMPUP_PROJECTS_ROOT", Path.home() / "Projects"))
    if not base.is_dir():
        return []
    return sorted(
        (path for path in base.iterdir() if path.is_dir() and (path / ".git").exists()),
        key=lambda path: path.name.lower(),
    )


def resolve_project(value: str = "", pick: bool = False) -> Path:
    if value:
        supplied = Path(value).expanduser()
        if supplied.exists():
            return _git_root(supplied)
        candidates = [path for path in project_candidates() if path.name.lower() == value.lower()]
        if len(candidates) == 1:
            return _git_root(candidates[0])
        raise HostSelectionError(f"project not found: {value}")

    cwd_root = _git_root(Path.cwd(), required=False)
    if cwd_root is not None and not pick:
        return cwd_root
    candidates = project_candidates()
    if not candidates:
        raise HostSelectionError("no Git projects found under the configured projects root")
    if not sys_stdin_is_tty():
        raise HostSelectionError("choose a project explicitly when no interactive terminal is available")
    names = "\n".join(path.name for path in candidates) + "\n"
    if shutil.which("fzf"):
        result = subprocess.run(
            ["fzf", "--prompt", "ompup project> ", "--height", "40%", "--reverse"],
            input=names,
            text=True,
            capture_output=True,
        )
        if result.returncode != 0 or not result.stdout.strip():
            raise HostSelectionError("project selection cancelled")
        return _git_root(next(path for path in candidates if path.name == result.stdout.strip()))
    for index, path in enumerate(candidates, 1):
        print(f"{index:>3}  {path.name}")
    choice = input("Project number: ").strip()
    if not choice.isdigit() or not 1 <= int(choice) <= len(candidates):
        raise HostSelectionError("invalid project selection")
    return _git_root(candidates[int(choice) - 1])


def _git_root(path: Path, required: bool = True) -> Path | None:
    result = subprocess.run(
        ["git", "-C", str(path), "rev-parse", "--show-toplevel"],
        text=True,
        capture_output=True,
    )
    if result.returncode == 0:
        return Path(result.stdout.strip()).resolve()
    if required:
        raise HostSelectionError(f"not inside a Git repository: {path}")
    return None


def sys_stdin_is_tty() -> bool:
    try:
        return os.isatty(0)
    except OSError:
        return False


def format_probe(probe: HostProbe) -> str:
    if not probe.reachable:
        return f"{probe.host.name:<12} unreachable  {probe.error}"
    memory = probe.memory_available / (1024**3)
    status = "ready" if probe.tools_ok else "missing tools"
    flags = []
    if probe.project_exists:
        flags.append("checkout")
    if probe.session_exists:
        flags.append("session")
    suffix = f"  {','.join(flags)}" if flags else ""
    return (
        f"{probe.host.name:<12} {status:<13} {probe.system}/{probe.arch:<10} "
        f"cpu={probe.cpu_count:<2} load={probe.load1:.2f} mem_free={memory:.1f}GB "
        f"disk_free={probe.free_gb:.0f}GB latency={probe.latency_ms:.0f}ms{suffix}"
    )
