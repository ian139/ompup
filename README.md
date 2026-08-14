# ompup

Jump from any local project into a persistent [Oh My Pi](https://github.com/can1357/oh-my-pi) session on the best available remote machine.

ompup probes configured hosts, honors project and workload affinity, pins the first placement, aligns the shared OMP environment, transfers Git commits and uncommitted state safely, attaches a project-named tmux session, and launches `omp`. The `/ompup handoff` extension command also moves the current live conversation into remote tmux and replaces its cmux surface in place.

```bash
ompup                       # current Git project
ompup UFC-pokedex           # named project from any directory
ompup --pick                # interactive project picker
ompup --cmux                # open or reuse a cmux workspace
/ompup handoff              # from inside local omp running in cmux
ompup env status --all      # verify OMP config, skills, agents, extensions, and plugins
ompup env sync --all        # align every reachable machine
ompup auth status           # verify the shared credential broker
```

## How it works

```text
local Git history ──verified bundle/snapshot──> ~/Projects/<name>
local session JSONL + artifacts ──────────────> ~/.local/state/ompup/handoffs/...
                                                         │
                                                   tmux + omp --resume
                                                         │
                                                   cmux SSH surface
```

- Git history moves through verified Git bundles. Fast-forward commits transfer automatically in either direction; divergent history fails visibly.
- A temporary Git index captures tracked files plus untracked, non-ignored files. Dependency directories, build output, ignored files, and sensitive paths stay out of the snapshot.
- Every successful transfer records the exact Git HEAD and snapshot tree. A later transfer proceeds only when the destination still matches that baseline. Conflicting edits and repository-name collisions fail visibly.
- The first transfer scans reachable history and every transfer scans its working snapshot with `gitleaks`.
- An existing tmux session is reattached without synchronizing files beneath the running process. Use `ompup sync` explicitly when you want a later local change transferred.
- Host selection is sticky. Live capacity chooses the first placement; the project remains pinned until `ompup unpin`.
- A live handoff waits for OMP to become idle, syncs the project, copies the session and artifacts into a private remote state directory, verifies the checksum and remote export, and starts OMP in tmux. Only then does cmux replace the local surface.
- Before an OMP launch or live handoff, the selected machine must match the local environment fingerprint and OMP version. Each tmux session records the fingerprint it started with, so an older live process cannot be mistaken for a current environment.

## Requirements

- Local: Python 3.12 or newer, `ssh`, `rsync`, `git`, `gitleaks`, and `yq`; cmux is required for live session handoff
- Remote: Python 3, Bash, `tmux`, `rsync`, `git`, and `omp`
- An SSH host or alias that reaches your box (an entry in `~/.ssh/config` works well)

## Install

### CLI

```bash
git clone https://github.com/wolfiesch/ompup.git
ln -s "$PWD/ompup/bin/ompup" ~/.local/bin/ompup   # or anywhere on PATH
mkdir -p ~/.config/ompup
```

### Oh My Pi extension

The same repo is an omp plugin. It adds `/ompup sync`, `/ompup pull`, `/ompup status`, and `/ompup handoff`. Handoff resumes the exact persisted conversation on the selected host, replaces the calling cmux surface with SSH attached to remote tmux, and shuts down the local OMP process.

```bash
omp plugin link ./ompup      # from the clone
```

Or point omp at it directly:

```bash
omp --extension ./ompup/extension/index.ts
```

## Usage

| Command | Effect |
|---|---|
| `ompup [PROJECT]` | Select a host, bootstrap or sync when needed, then attach tmux and launch omp |
| `ompup --pick` | Interactively choose a project |
| `ompup sync [PROJECT]` | Safely transfer fast-forward commits and local uncommitted state, no attach |
| `ompup pull [PROJECT]` | Safely transfer fast-forward commits and remote uncommitted state to local |
| `ompup status [PROJECT]` | Show selected host, capacity banner, Git synchronization, and tmux state |
| `ompup doctor [PROJECT]` | Probe every host and explain the selection |
| `ompup hosts` | Show live reachability, tools, platform, load, memory, disk, and latency |
| `ompup pin HOST [PROJECT]` | Pin a project to a configured host |
| `ompup unpin [PROJECT]` | Return a project to automatic placement |
| `ompup shell [PROJECT]` | Bootstrap or sync when needed, then attach a plain shell |
| `ompup [PROJECT] --cmux` | Open or reuse a named cmux workspace for the remote session |
| `/ompup handoff` | Wait for idle, transfer and verify this session, start remote OMP, then replace the current cmux surface |
| `/ompup handoff --host HOST` | Hand the session to a specific configured host |
| `ompup env status --all` | Compare the local shared-environment fingerprint with every configured host |
| `ompup env sync --all` | Update OMP, transfer the safe declarative environment, provision broker tokens over SSH, and verify each reachable host |
| `ompup auth setup` | Copy the broker bearer token over SSH into a local mode-0600 file and configure the broker URL |
| `ompup auth status` | Verify authenticated broker access without printing the token |
| `ompup auth migrate [--dry-run]` | Move local stored credentials, including OAuth accounts, into the broker |

## Host configuration

Create `~/.config/ompup/hosts.json`:

```json
{
  "hosts": [
    {
      "name": "compute",
      "ssh": "compute-box",
      "roles": ["general", "linux", "auth"],
      "reserve_gb": 40,
      "priority": 0,
      "launch": "omp"
    },
    {
      "name": "storage",
      "ssh": "storage-box",
      "roles": ["general", "linux", "storage"],
      "reserve_gb": 100,
      "priority": 10,
      "launch": "omp"
    },
    {
      "name": "mac",
      "ssh": "mac-worker",
      "roles": ["general", "macos", "arm64"],
      "reserve_gb": 25,
      "priority": 0,
      "launch": "$HOME/.local/bin/omp"
    }
  ],
  "environment": {
    "auth_host": "compute",
    "auth_broker_url": "http://100.64.0.10:8765"
  }
}
```

Add machines by appending host objects. No source change is required.

Selection precedence:

1. Explicit `--host`
2. Project pin stored in local Git config
3. A unique live tmux session
4. A unique existing remote checkout
5. Capability and live-capacity score for new placement

The capacity score uses declared roles, minimum free-space reserves, free disk, normalized load, available memory, and optional priority. It is a placement heuristic, not a hardware benchmark. Common profiles are `general`, `linux`, `storage`, `macos`, and `services`; custom role names work without source changes. Swift and Xcode projects select `macos` automatically. Set a persistent override with `git config ompup.profile PROFILE`.

## Shared OMP environment

`ompup env sync` treats the local Mac as the declarative source and installs a content-addressed release on each reachable host. Existing remote files are moved into timestamped backups before replacement. The release and every transferred project snapshot are scanned with `gitleaks`.

| Shared and parity-gated | Intentionally machine-local |
|---|---|
| OMP version and safe `config.yml` settings | `agent.db`, session history, memories, caches, blobs, logs |
| Active skills, agents, commands, rules, hooks, and referenced OMP docs | `.env`, broker tokens, API credentials, and other secret files |
| Portable extensions and exact linked plugin sources | MCP definitions, custom model files, SSH configuration |
| Auth-broker URL and model-role settings | cmux, Pompup, IRC visualization, and local episodic-memory extensions |

Remote configuration removes local extension paths and disables speech, sonification, and computer control. Skills ignored by the local OMP configuration, large local runtime payloads, and known credential-bearing skill payloads remain local. Authentication uses the OMP auth broker instead of copying SQLite databases or refresh tokens. The bearer token is transferred only through SSH stdin and stored as `~/.omp/auth-broker.token` with mode `0600`.

Initial rollout:

```bash
ompup auth setup
ompup auth migrate --dry-run
ompup auth migrate
ompup env sync --all
ompup env status --all
```

The broker URL should be reachable only through a trusted network such as Tailscale or through TLS. `env sync` skips nothing silently: unreachable hosts and version, fingerprint, plugin, or checksum failures are reported.

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `OMPUP_CONFIG` | `~/.config/ompup/hosts.json` | Host inventory path |
| `OMPUP_HOST` | empty | Legacy single-host fallback; use `auto` with a host inventory |
| `OMPUP_PROJECTS_ROOT` | `~/Projects` | Directory searched by project names and the picker |
| `OMPUP_REMOTE_ROOT` | `Projects` | Directory under remote `$HOME` for checkouts |
| `OMPUP_CMD` | host `launch` value | One-invocation remote OMP command override |
| `OMPUP_EXCLUDES` | unsupported | Use `.gitignore` or `.git/info/exclude` |

## Notes

- Project names resolve from the current Git repository, an explicit path, or a case-insensitive directory under `OMPUP_PROJECTS_ROOT`.
- The repository directory name also becomes the tmux session name.
- In sessions created by `ompup up`, quitting omp drops to a remote shell instead of killing tmux.
- Fast-forward commits transfer automatically. Divergent history requires normal Git reconciliation.
- `ompup pull` may delete local paths to reproduce the remote snapshot, but only when the local checkout exactly matches the recorded baseline.
- A successful handoff keeps the local session file as a rollback copy. A failed transfer, checksum, remote load, launch, or cmux replacement leaves local OMP running and removes only remote state created by that attempt.
- Handoff refuses while asynchronous jobs are running because their local processes cannot migrate with the session transcript.
- Handoff refuses to overwrite an existing project tmux session. Attach that session or select another host.
- If cmux cannot respawn the calling surface, ompup opens a focused fallback workspace and closes the old surface when cmux can identify it.

## License

MIT
