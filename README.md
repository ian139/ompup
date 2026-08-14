# ompup

Jump from any local project directory into a synced [Oh My Pi](https://github.com/can1357/oh-my-pi) session on your remote box.

One command syncs your working tree to the server, attaches a tmux session named after the project, and launches `omp` inside it. Close your laptop; the session keeps running.

```
cd ~/Projects/whatever
ompup
```

## How it works

```
local checkout ──rsync──> ~/Projects/<name> on your box
                              │
                        tmux new -A -s <name>
                              │
                             omp
```

- Git stays canonical. Commit and push from either side; rsync only carries uncommitted working state so you can jump mid-thought.
- Secrets never sync: `.env*`, `*.pem`, `*.key` are always excluded, along with `node_modules`, virtualenvs, and build output.
- Up-sync uses `--delete` for a faithful mirror, so a dirty-remote guard refuses to sync when the remote checkout has uncommitted changes. Commit there or run `ompup pull` first.
- The tmux session survives disconnects. Running `ompup` again reattaches instead of creating a duplicate.

## Requirements

- Local: `ssh`, `rsync`, `git`
- Remote: `tmux`, `rsync`, `git`, and `omp` on `PATH`
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
| `ompup` | Sync up, attach tmux, launch omp (reattach if the session exists) |
| `ompup sync` | Sync up only, no attach |
| `ompup pull` | Sync remote work back to the local checkout (never deletes local files) |
| `ompup status` | Remote git status and tmux session state |
| `ompup shell` | Sync up and attach a plain shell instead of omp |

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `OMPUP_HOST` | required | SSH host or alias for the remote box |
| `OMPUP_REMOTE_ROOT` | `Projects` | Directory under the remote `$HOME` that holds project checkouts |
| `OMPUP_CMD` | `omp` | Command launched inside the tmux session |
| `OMPUP_EXCLUDES` | empty | Extra colon-separated rsync exclude patterns |

## Notes

- The project name comes from the git toplevel directory (or the current directory outside a repo) and doubles as the tmux session name.
- Quitting omp drops to a shell inside the session instead of killing it.
- `ompup pull` intentionally skips `--delete`; review the result with `git status` before committing.

## License

MIT
