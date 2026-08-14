# ompup

Jump from any local project into a persistent [Oh My Pi](https://github.com/can1357/oh-my-pi) session on the best available remote machine.

ompup probes configured hosts, honors project and workload affinity, pins the first placement, transfers Git commits and uncommitted state safely, attaches a project-named tmux session, and launches `omp`. Later commands reattach a live session without mutating its checkout.

```bash
ompup                       # current Git project
ompup UFC-pokedex           # named project from any directory
ompup --pick                # interactive project picker
ompup --cmux                # open or reuse a cmux workspace
```

## How it works

```text
local Git history ──bundle, first run only──> ~/Projects/<name>
local working tree ──verified snapshot──────>        │
                                                     │
                                               tmux new -A
                                                     │
                                                    omp
```

- Git history moves through verified Git bundles. Fast-forward commits transfer automatically in either direction; divergent history fails visibly.
- A temporary Git index captures tracked files plus untracked, non-ignored files. Dependency directories, build output, ignored files, and sensitive paths stay out of the snapshot.
- Every successful transfer records the exact Git HEAD and snapshot tree. A later transfer proceeds only when the destination still matches that baseline. Conflicting edits and repository-name collisions fail visibly.
- The first transfer scans reachable history and every transfer scans its working snapshot with `gitleaks`.
- An existing tmux session is reattached without synchronizing files beneath the running process. Use `ompup sync` explicitly when you want a later local change transferred.
- Host selection is sticky. Live capacity chooses the first placement; the project remains pinned until `ompup unpin`.

## Requirements

- Local: Python 3.12 or newer, `ssh`, `rsync`, `git`, and `gitleaks`
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

The same repo is an omp plugin. It adds `/ompup sync`, `/ompup pull`, and `/ompup status` inside a session, so an agent or you can push the current project to the box without leaving omp. The interactive jump stays in the CLI, since a running TUI cannot hand its terminal to a remote tmux.

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

## Host configuration

Create `~/.config/ompup/hosts.json`:

```json
{
  "hosts": [
    {
      "name": "compute",
      "ssh": "compute-box",
      "roles": ["general", "linux"],
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
  ]
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
- Quitting omp drops to a shell inside the session instead of killing it.
- Fast-forward commits transfer automatically. Divergent history requires normal Git reconciliation.
- `ompup pull` may delete local paths to reproduce the remote snapshot, but only when the local checkout exactly matches the recorded baseline.

## License

MIT
