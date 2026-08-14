# ompup

Jump from any local project directory into a synced [Oh My Pi](https://github.com/can1357/oh-my-pi) session on your remote box.

The first command bootstraps a remote Git checkout, transfers your uncommitted working state, attaches a project-named tmux session, and launches `omp`. Later commands reattach a live session without mutating its checkout. Close your laptop; the session keeps running.

```
cd ~/Projects/whatever
ompup
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

- Git transports commits and refs. ompup never rsyncs one live `.git` directory over another.
- A temporary Git index captures tracked files plus untracked, non-ignored files. Dependency directories, build output, ignored files, and sensitive paths stay out of the snapshot.
- Every successful transfer records the exact Git HEAD and snapshot tree. A later transfer proceeds only when the destination still matches that baseline. Conflicting edits, different commits, and repository-name collisions fail visibly.
- The first transfer scans reachable history and every transfer scans its working snapshot with `gitleaks`.
- An existing tmux session is reattached without synchronizing files beneath the running process. Use `ompup sync` explicitly when you want a later local change transferred.

## Requirements

- Local: Python 3.9 or newer, `ssh`, `rsync`, `git`, and `gitleaks`
- Remote: Bash, `tmux`, `rsync`, `git`, and `omp` on `PATH`
- An SSH host or alias that reaches your box (an entry in `~/.ssh/config` works well)

## Install

### CLI

```bash
git clone https://github.com/wolfiesch/ompup.git
ln -s "$PWD/ompup/bin/ompup" ~/.local/bin/ompup   # or anywhere on PATH
export OMPUP_HOST=my-devbox                        # add to your shell rc
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
| `ompup` | Bootstrap or sync when no session exists, then attach tmux and launch omp; a live session is attached without changing files |
| `ompup sync` | Safely transfer local uncommitted state, no attach |
| `ompup pull` | Safely transfer remote uncommitted state to an unchanged local baseline |
| `ompup status` | Compare local and remote Git, synchronization, and tmux state |
| `ompup shell` | Bootstrap or sync when needed, then attach a plain shell |

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `OMPUP_HOST` | required | SSH host or alias for the remote box |
| `OMPUP_REMOTE_ROOT` | `Projects` | Directory under the remote `$HOME` that holds project checkouts |
| `OMPUP_CMD` | `omp` | Command launched inside the tmux session |
| `OMPUP_EXCLUDES` | unsupported | Use `.gitignore` or `.git/info/exclude` so the synchronization snapshot remains verifiable |

## Notes

- Run ompup inside a Git repository. The repository directory name also becomes the tmux session name.
- Quitting omp drops to a shell inside the session instead of killing it.
- Committed changes move through normal Git push, fetch, or pull operations. ompup handles only uncommitted working state after bootstrap.
- `ompup pull` may delete local paths to reproduce the remote snapshot, but only when the local checkout exactly matches the recorded baseline.

## License

MIT
