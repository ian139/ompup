# ompup

`ompup` hands one project tree between a local machine and a persistent [Oh My Pi](https://github.com/can1357/oh-my-pi) session over SSH. It is an explicit two-copy handoff, not continuous sync or a merge tool.

```bash
export OMPUP_HOST=my-devbox       # an SSH alias is recommended
cd ~/src/my-project
ompup                            # sync, then attach only after a safe handoff
```

The remote tmux session survives disconnects. If the remote already owns the tree, use `ompup attach`; the default command deliberately refuses to overwrite or resync it.

## Ownership model

A committed ledger records exactly one owner. Every mutation compares both copies with the last committed baseline and fails closed when reality disagrees.

| State | Meaning | Allowed next handoff |
|---|---|---|
| uninitialized | No trusted local ledger exists and the addressed remote path is absent | `sync` |
| local-owned | Only the local copy may change | `sync` hands ownership to remote |
| remote-owned | Only the remote copy may change | `pull` hands ownership to local; `attach` transfers nothing |
| unknown-conflict | Both sides changed, the non-owner changed, identity/marker/Git validation failed, or a lock/transaction is unresolved | inspect `status`, reconcile the reported paths or recovery artifact, then retry; there is no force mode |

| Command | Data transfer and ownership effect |
|---|---|
| `ompup` | From uninitialized/local-owned: `sync`, then attach OMP. From remote-owned: refuse and require `attach`. |
| `ompup sync` | Require uninitialized/local-owned; publish local to remote as a whole-tree swap; commit remote-owned. |
| `ompup pull` | Require remote-owned; publish remote to local as a whole-tree swap; commit local-owned. |
| `ompup attach` | Require an initialized, effectively remote-owned, unlocked tree; attach/create its tmux session and run `OMPUP_CMD`. No sync. |
| `ompup shell` | From uninitialized/local-owned: sync, then attach a plain remote shell. It refuses when remote already owns the tree. |
| `ompup status` | Read-only identity, local/remote Git tuples, committed/effective owner, epoch, changed paths, blocker, and tmux state. Connectivity failures are reported as blockers. |

`sync` uses deletion inside a candidate to make the managed remote tree match local. `pull` also stages an exact managed candidate before swapping it into place. Neither command merges content.

## Identity, layout, and state

The address is `<readable-slug>--<12-hex-hash>` and the tmux session is `ompup-<slug>-<12-hex-hash>` (the session slug is capped at 32 characters). Hashes are stable protocol identifiers, not security claims.

- **Git identity:** SHA-1 of a domain separator and the exact, single `remote.origin.url`. The local ledger additionally binds the physical local root.
- **Non-Git identity:** SHA-1 of a domain separator and the absolute physical path from `pwd -P`; content changes never change identity.
- **Target identity:** SHA-1 of the exact `OMPUP_HOST` and `OMPUP_REMOTE_ROOT`.

Local state is stored under `${XDG_STATE_HOME:-$HOME/.local/state}/ompup`:

```text
targets/<target-hash>/<address>/state
targets/<target-hash>/<address>/baselines/<epoch>/{tree,rules}
targets/<target-hash>/<address>/transactions/<token>/{journal,before,after,rules}
locks/<target-hash>--<address>.lock/
```

Remote data is relative to the SSH account's real home:

```text
~/<remote-root>/<address>/
~/<remote-root>/.ompup-v2/<address>/marker
~/<remote-root>/.ompup-v2/<address>/txn/<token>/journal
~/<remote-root>/.ompup-v2/locks/<address>.lock/
~/<remote-root>/.ompup-{candidate,backup,failed}-<address>-<token>
```

The marker is validated before an existing destination is trusted. It records schema `2`, the full identity hash and kind, address, and creating version. A pre-existing unmarked directory is never adopted. In particular, the v0.1 path `~/Projects/<basename>` is left untouched; v0.2 neither migrates nor adopts it.

## Git boundary

`.git` is an immutable transfer boundary: every file or directory named `.git`, including nested ones and worktree `.git` files, is excluded in both directions. Initial Git sync makes the remote candidate with `git clone --no-checkout --origin origin` from the exact origin, then establishes the exact local branch/detached/unborn mode and HEAD before copying managed working-tree data. Later swaps copy each side's own `.git` internally; rsync never transports it.

Both sides must retain the same exact origin, HEAD mode, branch, and commit. Ompup rejects staged index changes, unmerged entries, sparse checkouts, Gitlinks/submodules, and merge/cherry-pick/revert/rebase operations. The initial commit must be fetchable by the remote origin (an unborn branch is supported by real sync, but cannot be proven by initial `--dry-run`). Normal unstaged and untracked working-tree files are handoff data unless excluded.

The Git index and staging state are never synchronized. Commit graph changes are not merged or fetched for you; advance both repositories deliberately before handing off. `.gitignore`, `.gitattributes`, and `.gitmodules` are ordinary managed files, although a Gitlink in the index makes the project unsupported.

**Credential warning:** the exact origin URL is embedded, shell-quoted, in the remote clone command. Do not use an origin URL containing a password, token, or other embedded credential. Prefer an SSH origin whose key is already available on the remote.

## Crash-safe publication and recovery

Mutations acquire both local and remote locks. They materialize and validate a complete candidate, durably publish a journal, rename the live directory to a same-filesystem backup, rename the candidate live, validate again, create the new baseline, and write ownership state last. Backups and journals make the rename gap recoverable.

The next mutating command recovers one valid interrupted transaction to its validated pre-tree, or finalizes cleanup when state was already committed. If a live tree, backup, journal, marker, symlink, or epoch does not match the bound transaction, ompup preserves the evidence and blocks instead of guessing or deleting a third version. `status` reports pending remote locks/transactions. A stale local lock is never auto-broken: inspect its PID/token and related journals, then remove only the verified stale lock before retrying. Signals run best-effort candidate and owned-lock cleanup; after machine loss, use the same command to invoke journal recovery.

## Exclusions and trust boundary

The filter is a convenience denylist, **not a secret scanner**. Review `ompup sync --dry-run` before first use. Ompup lists tracked files omitted by the active policy and requires `--acknowledge-excluded`; the acknowledgement is bound to the filter and omitted-path digest, so a policy change may require acknowledgement again.

Rules are applied in this order:

```text
exclude .git
include .ompupignore
include .env.example
include .env.sample
exclude .env
exclude .env.*
exclude *.pem
exclude *.key
exclude *.p12
exclude *.pfx
exclude .ssh/
exclude .aws/
exclude .gnupg/
exclude .netrc
exclude .npmrc
exclude .pypirc
exclude .git-credentials
exclude .docker/config.json
exclude .kube/
exclude .config/gh/hosts.yml
exclude node_modules/
exclude .venv/
exclude venv/
exclude __pycache__/
exclude .pytest_cache/
exclude .mypy_cache/
exclude target/
exclude dist/
exclude build/
exclude .next/
exclude .turbo/
exclude .cache/
exclude .DS_Store
```

`.env.example` and `.env.sample` are intentional templates and remain included. Put additional LF-separated rsync exclude patterns in the project-root `.ompupignore`. `OMPUP_EXCLUDES` adds colon-separated patterns. The remote `.ompupignore` controls a pull, while the local file controls a sync. CR/TAB policy text is rejected. Anyone who can write the project or these rules can influence what is copied; inspect the effective policy and do not treat it as a confidentiality boundary.

## Options and configuration

`--dry-run` applies only to `sync` and `pull`. It prints identity, destination, policy, changes, and the planned ownership transition without managed writes; it still contacts the remote and may run read-only Git checks. `--acknowledge-excluded` also applies only to those commands.

| Variable | Default | Purpose |
|---|---|---|
| `OMPUP_HOST` | required | One safe SSH alias or `user@host` token. Use `~/.ssh/config` aliases for ports, proxy jumps, identities, and other SSH settings. |
| `OMPUP_REMOTE_ROOT` | `Projects` | Safe relative path below remote `$HOME`; absolute paths, `.`/`..`, empty segments, and shell characters are rejected. |
| `OMPUP_CMD` | `omp` | Remote Bash text launched inside the tmux session. CR/LF/TAB are rejected; the trusted value is intentionally evaluated by remote `bash -lc`. |
| `OMPUP_EXCLUDES` | empty | Extra colon-separated rsync excludes. |
| `XDG_STATE_HOME` | `$HOME/.local/state` | Local state base. |
| `OMPUP_STATUS_TIMEOUT_MS` | `30000` | Positive integer timeout used by the OMP extension for `status`. |
| `OMPUP_OPERATION_TIMEOUT_MS` | `120000` | Positive integer timeout used by the OMP extension for `sync`/`pull`. |

`help`/`--help` and `version`/`--version` do not require configuration or dependencies.

## Requirements

- OMP **>= 17.3.4** and Bun **>= 1.3.14** for the extension.
- Local: Bash 3.2 or newer, SSH client, rsync, and Git.
- Remote: SSH service plus Bash, rsync, Git (for Git projects), tmux (for attach/status), and `omp` or the configured command.
- Tested targets: macOS with system openrsync/rsync 2.6.9 compatibility and current Linux.
- The remote account must be able to create directories and atomic same-filesystem renames below its home. Initial Git sync also requires remote access to the exact origin and local access to the same commit.

## Install, upgrade, and rollback

Install the pinned CLI from npm, then set a host alias:

```bash
npm install --global ompup@0.2.0
export OMPUP_HOST=my-devbox
ompup --version
```

To use the slash command from a source/package directory, link its manifest with OMP and keep that directory installed:

```bash
omp plugin link /absolute/path/to/ompup
```

The manifest loads `extension/index.ts`, which invokes the bundled `bin/ompup` when present and otherwise falls back explicitly to `ompup` on `PATH`. `/ompup [sync|pull|status]` is a **user slash command**, not an LLM tool. Mutating verbs require an interactive UI; the extension reports progress, enforces the timeout variables above, preserves full failure/truncated output in a private temporary artifact, and never attaches the current terminal. Use the standalone CLI for `attach` and `shell`.

Upgrade by installing a new exact version; rollback by reinstalling the previous exact version. Do not mix binaries and extension files from different releases:

```bash
npm install --global ompup@<exact-version>
# relink the matching unpacked package/source directory if the extension is linked
```

Before changing versions, finish or recover any reported transaction and bring ownership back to the side where you will continue working. v0.2 does not import v0.1 state or paths.

## License

MIT
