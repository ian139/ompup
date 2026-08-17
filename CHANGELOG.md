# Changelog

## 0.2.0

Breaking release: v0.2 replaces the unsafe in-place basename mirror with an explicit, fail-closed handoff protocol. Existing v0.1 remote directories such as `~/Projects/<basename>` and any v0.1 state are not adopted, migrated, or modified.

### Changed

- Added committed local-owned/remote-owned state, baseline comparison, and unknown-conflict blocking when both sides or a non-owner change.
- Replaced in-place publication with locked candidate/backup/journal directory swaps, validation, rollback, interruption recovery, and state-last ownership commits.
- Added collision-resistant addresses from exact Git-origin or physical non-Git-path identity, target binding, private local state, and validated remote markers.
- Initial Git handoff now clones the exact origin and establishes the exact branch/detached/unborn HEAD. Origin/HEAD divergence, staged or unmerged index state, sparse checkout, Gitlinks/submodules, and active Git operations fail closed.
- Made every `.git` directory or file, including nested metadata, an immutable transfer boundary. Git indexes and staging state are never synchronized.
- Added exact inspectable default excludes, `.ompupignore`, `OMPUP_EXCLUDES`, preserved `.env.example`/`.env.sample` templates, and acknowledgement for tracked excluded paths. The denylist is explicitly not a secret scanner.
- `ompup` and `ompup shell` sync only from local ownership; when remote already owns the tree, use the new transfer-free `ompup attach`. `status` reports identities, Git tuples, owners, epochs, changed paths, blockers, locks/transactions, and tmux state.
- `sync` and `pull` now support zero-managed-write `--dry-run` and `--acknowledge-excluded`.
- Hardened host/root/command/path/state/marker/journal validation and remote shell quoting. SSH aliases remain supported.
- Reworked the OMP integration as the `/ompup sync|pull|status` user command, not an LLM tool. Added completions, no-UI mutation refusal, deterministic bundled-CLI resolution, progress, operation/status timeouts, process-group termination, distinct exit/signal/timeout/spawn errors, bounded output, and private full-output artifacts.
- Set supported floors to OMP 17.3.4 and Bun 1.3.14; retained Bash 3.2 and macOS openrsync/rsync 2.6.9 compatibility.

### Operational notes

- There is no continuous synchronization, content merge, Git fetch, staging synchronization, destination adoption, or force overwrite.
- Initial Git clone passes the exact origin URL to a remote shell command. Use credential-free URLs and remote SSH credentials; never embed a token or password in the origin.
- Review exclusions with `--dry-run`, resolve or recover transactions before upgrading or rolling back, and reconcile every `unknown-conflict` explicitly.
