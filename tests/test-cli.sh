#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd -P)
OMPUP="$ROOT_DIR/bin/ompup"
FIXTURES="$ROOT_DIR/tests/fixtures"
ORIGINAL_PATH=$PATH
TMP=
PROJECT=
REMOTE=
STATE=
LOG=
OUT=
RC=0

cleanup() { [ -z "${TMP:-}" ] || rm -rf "$TMP"; }
trap cleanup EXIT
fail() { printf 'not ok - %s\n' "$*" >&2; printf '%s\n' "$OUT" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "expected [$2], got [$1]"; }
assert_file() { [ -f "$1" ] || fail "missing file $1"; }
assert_no_file() { [ ! -e "$1" ] || fail "unexpected path $1"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "output missing: $2" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "output unexpectedly contains: $2" ;; *) ;; esac; }

new_fixture() {
  cleanup
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/ompup-cli.XXXXXX")
  PROJECT="$TMP/local/project"
  REMOTE="$TMP/remote"
  STATE="$TMP/state"
  LOG="$TMP/ssh.log"
  mkdir -p "$PROJECT" "$REMOTE"
  : > "$LOG"
  export PATH="$FIXTURES:$ORIGINAL_PATH"
  export OMPUP_HOST=fixture OMPUP_REMOTE_ROOT=Projects
  export OMPUP_FAKE_REMOTE_HOME="$REMOTE" XDG_STATE_HOME="$STATE" OMPUP_FAKE_SSH_LOG="$LOG"
  unset OMPUP_EXCLUDES OMPUP_CMD OMPUP_FAKE_SSH_FAIL OMPUP_FAKE_SSH_FAIL_MATCH
  unset OMPUP_FAKE_SSH_FAIL_AFTER_MATCH OMPUP_FAKE_SSH_MUTATE_BEFORE_MATCH OMPUP_FAKE_SSH_MUTATE_PATH
  unset OMPUP_FAKE_MV_FAIL_AFTER_BACKUP OMPUP_FAKE_MV_MUTATE_BEFORE_BACKUP OMPUP_FAKE_CP_FAIL_AFTER_BACKUP
  unset OMPUP_FAKE_SSH_CREATE_DEST_BEFORE_MATCH OMPUP_FAKE_SSH_GIT_COMMIT_BEFORE_MATCH
  unset OMPUP_FAKE_SSH_GIT_COMMIT_STAMP OMPUP_FAKE_SSH_GIT_PROJECT
  unset OMPUP_FAKE_SSH_SYMLINK_ATTACK_BEFORE_MATCH OMPUP_FAKE_SSH_SYMLINK_ATTACK_KIND
  unset OMPUP_FAKE_SSH_SYMLINK_ATTACK_TARGET
  unset OMPUP_FAKE_MKDIR_RULES_ATTACK OMPUP_FAKE_MKDIR_RULES_TARGET
  unset OMPUP_FAKE_CP_REPLACE_CONTAINER OMPUP_FAKE_CP_REPLACE_STAMP OMPUP_FAKE_CP_REPLACE_TARGET OMPUP_FAKE_CP_REPLACE_KIND
}
run_ompup() {
  set +e
  OUT=$(cd "$PROJECT" && /bin/bash "$OMPUP" "$@" 2>&1)
  RC=$?
  set -e
}
run_ompup_from() {
  local cwd=$1; shift
  set +e
  OUT=$(cd "$cwd" && /bin/bash "$OMPUP" "$@" 2>&1)
  RC=$?
  set -e
}
remote_project() {
  local d
  for d in "$REMOTE/Projects"/*--*; do [ -d "$d" ] && { printf '%s' "$d"; return; }; done
  return 1
}
state_file() { find "$STATE/ompup/targets" -type f -name state -print -quit; }
marker_file() { find "$REMOTE/Projects/.ompup-v2" -type f -name marker -print -quit; }
transaction_journal() { find "$STATE/ompup/targets" -type f -name journal -print -quit; }
replace_field() {
  local file=$1 wanted=$2 replacement=$3 tmp
  tmp="$file.tmp"
  : > "$tmp"
  while IFS=$'\t' read -r key value rest || [ -n "$key" ]; do
    if [ "$key" = "$wanted" ]; then printf '%s\t%s\n' "$key" "$replacement" >> "$tmp"
    else printf '%s\t%s%s\n' "$key" "$value" "${rest:+$'\t'$rest}" >> "$tmp"; fi
  done < "$file"
  mv "$tmp" "$file"
}
snapshot() {
  local root=$1
  if [ ! -e "$root" ]; then printf '(absent)\n'; return; fi
  find "$root" -type f -print | LC_ALL=C sort | while IFS= read -r f; do printf '%s ' "${f#$root/}"; cksum "$f"; done
}
init_non_git() { printf 'one\n' > "$PROJECT/file.txt"; run_ompup sync; [ "$RC" -eq 0 ] || fail "initial non-Git sync"; }

init_git() {
  local bare="$TMP/ori'gin.git"
  rm -rf "$PROJECT"
  git init --bare "$bare" >/dev/null
  git clone "$bare" "$PROJECT" >/dev/null 2>&1
  git -C "$PROJECT" config user.name Fixture
  git -C "$PROJECT" config user.email fixture@example.invalid
  printf 'one\n' > "$PROJECT/file.txt"
  printf '*.log\n' > "$PROJECT/.gitignore"
  printf 'attrs\n' > "$PROJECT/.gitattributes"
  printf 'template\n' > "$PROJECT/.env.example"
  git -C "$PROJECT" add .
  git -C "$PROJECT" commit -m initial >/dev/null
  git -C "$PROJECT" push origin HEAD >/dev/null
  run_ompup sync
  [ "$RC" -eq 0 ] || fail "initial Git sync"
}

case_help_version() {
  new_fixture
  : > "$LOG"
  set +e
  OUT=$(env -i PATH=/usr/bin:/bin HOME="$TMP/nohome" /bin/bash "$OMPUP" --help 2>&1); RC=$?
  set -e
  assert_eq "$RC" 0; assert_contains "$OUT" 'Usage: ompup'
  set +e
  OUT=$(env -i PATH=/usr/bin:/bin HOME="$TMP/nohome" /bin/bash "$OMPUP" --version 2>&1); RC=$?
  set -e
  assert_eq "$RC" 0; assert_eq "$OUT" 'ompup 0.2.0'; assert_eq "$(cat "$LOG")" ''
}

case_initial_non_git() {
  new_fixture; init_non_git
  local rd id1 id2
  rd=$(remote_project); assert_eq "$(cat "$rd/file.txt")" one
  assert_file "$(marker_file)"; assert_file "$(state_file)"
  run_ompup status; assert_contains "$OUT" 'committed-owner: remote'; assert_contains "$OUT" 'effective-owner: remote'
  id1=$(printf '%s\n' "$OUT" | sed -n 's/^identity: //p')
  printf 'content change\n' > "$PROJECT/file.txt"
  run_ompup status; id2=$(printf '%s\n' "$OUT" | sed -n 's/^identity: //p')
  assert_eq "$id1" "$id2"
}

case_initial_git_and_git_boundary() {
  new_fixture; init_git
  local rd oid before after local_git_before local_git_after
  rd=$(remote_project)
  oid=$(git -C "$PROJECT" rev-parse HEAD)
  assert_eq "$(git -C "$rd" rev-parse HEAD)" "$oid"
  assert_eq "$(git -C "$rd" remote get-url origin)" "$(git -C "$PROJECT" remote get-url origin)"
  before=$(cksum "$rd/.git/index")
  mkdir -p "$rd/nested/.git" "$PROJECT/nested/.git"
  printf 'remote metadata\n' > "$rd/nested/.git/sentinel"
  printf 'local metadata\n' > "$PROJECT/nested/.git/sentinel"
  run_ompup pull; assert_eq "$RC" 0
  printf 'managed\n' > "$PROJECT/nested/value.txt"
  run_ompup sync; assert_eq "$RC" 0
  after=$(cksum "$rd/.git/index")
  assert_eq "$before" "$after"
  assert_eq "$(cat "$rd/nested/.git/sentinel")" 'remote metadata'
  assert_eq "$(cat "$rd/nested/value.txt")" managed
  assert_file "$rd/.gitignore"; assert_file "$rd/.gitattributes"; assert_file "$rd/.env.example"
  local_git_before=$(cksum "$PROJECT/.git/index")
  printf 'pulled\n' > "$rd/nested/value.txt"
  run_ompup pull; assert_eq "$RC" 0
  local_git_after=$(cksum "$PROJECT/.git/index")
  assert_eq "$local_git_before" "$local_git_after"
  assert_eq "$(cat "$PROJECT/nested/.git/sentinel")" 'local metadata'
  assert_eq "$(cat "$PROJECT/nested/value.txt")" pulled
}

case_round_trip_and_status() {
  new_fixture; init_non_git
  local rd; rd=$(remote_project)
  printf 'remote two\n' > "$rd/file.txt"; printf 'new\n' > "$rd/new.txt"
  run_ompup pull; assert_eq "$RC" 0; assert_eq "$(cat "$PROJECT/file.txt")" 'remote two'; assert_file "$PROJECT/new.txt"
  run_ompup status; assert_contains "$OUT" 'committed-owner: local'; assert_contains "$OUT" 'effective-owner: local'
  rm "$PROJECT/new.txt"; printf 'local three\n' > "$PROJECT/file.txt"
  run_ompup sync; assert_eq "$RC" 0; assert_eq "$(cat "$rd/file.txt")" 'local three'; assert_no_file "$rd/new.txt"
  run_ompup status; assert_contains "$OUT" 'epoch: 3'
}

case_divergent_git() {
  new_fixture; init_git
  local rd; rd=$(remote_project)
  git -C "$rd" config user.name Fixture; git -C "$rd" config user.email fixture@example.invalid
  printf 'remote commit\n' > "$rd/file.txt"; git -C "$rd" add file.txt; git -C "$rd" commit -m diverge >/dev/null
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'divergent remote HEAD should block'; assert_contains "$OUT" 'remote Git tuple diverged'
}

case_dirty_git_boundaries() {
  new_fixture; init_git
  printf 'staged\n' > "$PROJECT/staged.txt"; git -C "$PROJECT" add staged.txt
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'staged local index should block'; assert_contains "$OUT" 'local Git index has staged changes'
  git -C "$PROJECT" reset -q HEAD -- staged.txt; rm "$PROJECT/staged.txt"
  local rd; rd=$(remote_project); printf 'staged remote\n' > "$rd/staged.txt"; git -C "$rd" add staged.txt
  run_ompup pull; [ "$RC" -ne 0 ] || fail 'staged remote index should block'; assert_contains "$OUT" 'remote Git index has staged changes'
}

case_both_side_conflict() {
  new_fixture; init_non_git
  local rd; rd=$(remote_project)
  printf 'local\n' > "$PROJECT/local.txt"; printf 'remote\n' > "$rd/remote.txt"
  run_ompup status; assert_eq "$RC" 0; assert_contains "$OUT" 'effective-owner: unknown-conflict'; assert_contains "$OUT" 'both sides changed'; assert_contains "$OUT" 'local.txt'; assert_contains "$OUT" 'remote.txt'
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'both-side sync should block'
  run_ompup pull; [ "$RC" -ne 0 ] || fail 'both-side pull should block'
}

case_identity_isolation() {
  new_fixture
  local p1="$TMP/a/same" p2="$TMP/b/same" a1 a2
  mkdir -p "$p1" "$p2"; printf a > "$p1/f"; printf b > "$p2/f"
  PROJECT=$p1; run_ompup status; a1=$(printf '%s\n' "$OUT" | sed -n 's/^address: //p')
  PROJECT=$p2; run_ompup status; a2=$(printf '%s\n' "$OUT" | sed -n 's/^address: //p')
  [ "$a1" != "$a2" ] || fail 'same basename projects collided'
  PROJECT=$p1; run_ompup sync; assert_eq "$RC" 0
  PROJECT=$p2; run_ompup sync; assert_eq "$RC" 0
  [ "$(find "$REMOTE/Projects" -maxdepth 1 -type d -name 'same--*' | wc -l | tr -d ' ')" -eq 2 ] || fail 'remote addresses not isolated'
}

case_marker_and_collision() {
  new_fixture
  printf x > "$PROJECT/f"; run_ompup status; local address
  address=$(printf '%s\n' "$OUT" | sed -n 's/^address: //p'); mkdir -p "$REMOTE/Projects/$address"
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'unmarked destination should block'; assert_contains "$OUT" 'already exists'
  new_fixture; init_non_git
  printf 'schema\t2\nidentity_hash\twrong\n' > "$(marker_file)"
  run_ompup status; assert_eq "$RC" 0; assert_contains "$OUT" 'effective-owner: unknown-conflict'; assert_contains "$OUT" 'remote marker invalid'
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'malformed marker should block'; assert_contains "$OUT" 'marker'
  printf 'schema\t2\n' >> "$(state_file)"
  run_ompup status; [ "$RC" -ne 0 ] || fail 'duplicate state field should block'; assert_contains "$OUT" 'duplicate state field'
}

case_dependency_and_transport_failures() {
  new_fixture; printf x > "$PROJECT/f"
  export OMPUP_FAKE_SSH_FAIL=1
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'ssh failure should block'; assert_contains "$OUT" 'remote mutation lock'
  unset OMPUP_FAKE_SSH_FAIL
  set +e
  OUT=$(env -i PATH=/bin HOME="$TMP" OMPUP_HOST=fixture /bin/bash "$OMPUP" sync 2>&1); RC=$?
  set -e
  [ "$RC" -ne 0 ] || fail 'missing dependency should block'; assert_contains "$OUT" 'required local command not found'
}

case_recovery_and_rollback() {
  new_fixture; printf one > "$PROJECT/file.txt"
  export OMPUP_FAKE_SSH_FAIL_MATCH='.ompup-candidate-'
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'pre-journal candidate failure should fail'
  assert_no_file "$(state_file 2>/dev/null || true)"; [ -z "$(marker_file 2>/dev/null || true)" ] || fail 'pre-journal failure published marker'
  unset OMPUP_FAKE_SSH_FAIL_MATCH

  new_fixture; printf one > "$PROJECT/file.txt"
  export OMPUP_FAKE_SSH_FAIL_MATCH='cp -Rp'
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'post-journal initial promotion failure should fail'
  [ -z "$(marker_file 2>/dev/null || true)" ] || fail 'failed initial rename published marker'
  [ -n "$(find "$STATE" -type f -name journal -print -quit)" ] || fail 'durable initial journal missing'
  unset OMPUP_FAKE_SSH_FAIL_MATCH
  run_ompup sync; assert_eq "$RC" 0; assert_contains "$OUT" 'recovered uncommitted transaction'

  new_fixture; init_non_git
  local rd; rd=$(remote_project); run_ompup pull; assert_eq "$RC" 0
  printf 'pre\n' > "$PROJECT/file.txt"
  export OMPUP_FAKE_SSH_FAIL_MATCH='ompup_backup_copy'
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'injected backup copy failure should fail'; assert_eq "$(cat "$rd/file.txt")" one
  unset OMPUP_FAKE_SSH_FAIL_MATCH
  run_ompup sync; assert_eq "$RC" 0; assert_contains "$OUT" 'recovered uncommitted transaction'; assert_eq "$(cat "$rd/file.txt")" pre
  [ -z "$(find "$STATE" "$REMOTE" -type f -name journal -print)" ] || fail 'journals not cleaned'
}

case_locking() {
  new_fixture; init_non_git
  local rd locks lock; rd=$(remote_project); printf local > "$PROJECT/new"
  locks="$STATE/ompup/locks"; lock="$locks/held.lock"; mkdir "$lock"; printf '%s\n' "$$" > "$lock/pid"; printf other > "$lock/token"
  # Use the real generated lock name rather than an unrelated directory.
  rmdir "$lock" 2>/dev/null || rm -rf "$lock"
  lock=$(find "$locks" -maxdepth 1 -type d -name '*.lock' -print -quit)
  [ -z "$lock" ] || fail 'successful sync leaked local lock'
  address=${rd##*--}; address=${rd##*/}; target=$(find "$STATE/ompup/targets" -mindepth 1 -maxdepth 1 -type d -print -quit); target=${target##*/}
  lock="$locks/$target--$address.lock"; mkdir "$lock"; printf '%s\n' "$$" > "$lock/pid"; printf other > "$lock/token"
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'live local lock should block'; assert_contains "$OUT" 'local mutation lock is held'
  rm -rf "$lock"
  mkdir "$lock"; printf '99999999\n' > "$lock/pid"; printf stale > "$lock/token"
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'stale local lock should fail closed'
  assert_contains "$OUT" 'stale locks require explicit inspection'; assert_eq "$(cat "$lock/token")" stale
  rm -rf "$lock"
  mkdir -p "$REMOTE/Projects/.ompup-v2/locks/$address.lock"; printf other > "$REMOTE/Projects/.ompup-v2/locks/$address.lock/token"
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'remote lock should block'; assert_contains "$OUT" 'remote mutation lock'
}

case_dry_run_zero_mutation() {
  new_fixture; printf one > "$PROJECT/file"
  local beforep beforer befores afterp afterr afters
  beforep=$(snapshot "$PROJECT"); beforer=$(snapshot "$REMOTE"); befores=$(snapshot "$STATE")
  run_ompup sync --dry-run; assert_eq "$RC" 0; assert_contains "$OUT" 'dry-run: no managed mutations'
  afterp=$(snapshot "$PROJECT"); afterr=$(snapshot "$REMOTE"); afters=$(snapshot "$STATE")
  assert_eq "$beforep" "$afterp"; assert_eq "$beforer" "$afterr"; assert_eq "$befores" "$afters"
  init_non_git
  run_ompup pull; assert_eq "$RC" 0
  printf changed > "$PROJECT/file"
  beforep=$(snapshot "$PROJECT"); beforer=$(snapshot "$REMOTE"); befores=$(snapshot "$STATE")
  run_ompup sync --dry-run; assert_eq "$RC" 0
  afterp=$(snapshot "$PROJECT"); afterr=$(snapshot "$REMOTE"); afters=$(snapshot "$STATE")
  assert_eq "$beforep" "$afterp"; assert_eq "$beforer" "$afterr"; assert_eq "$befores" "$afters"
}

case_exclusions_and_acknowledgement() {
  new_fixture
  local bare="$TMP/origin.git" rd
  rm -rf "$PROJECT"; git init --bare "$bare" >/dev/null; git clone "$bare" "$PROJECT" >/dev/null 2>&1
  git -C "$PROJECT" config user.name Fixture; git -C "$PROJECT" config user.email fixture@example.invalid
  printf secret > "$PROJECT/.env"; printf example > "$PROJECT/.env.example"; printf sample > "$PROJECT/.env.sample"
  printf ignored > "$PROJECT/generated.bin"; printf 'generated.bin\n' > "$PROJECT/.ompupignore"
  git -C "$PROJECT" add .; git -C "$PROJECT" commit -m files >/dev/null; git -C "$PROJECT" push origin HEAD >/dev/null
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'tracked omissions require acknowledgement'; assert_contains "$OUT" '.env'; assert_contains "$OUT" 'generated.bin'
  run_ompup sync --acknowledge-excluded; assert_eq "$RC" 0; rd=$(remote_project)
  assert_no_file "$rd/.env"; assert_no_file "$rd/generated.bin"; assert_eq "$(cat "$rd/.env.example")" example; assert_eq "$(cat "$rd/.env.sample")" sample
  printf 'other.bin\n' >> "$PROJECT/.ompupignore"; printf x > "$PROJECT/other.bin"; git -C "$PROJECT" add .; git -C "$PROJECT" commit -m policy >/dev/null; git -C "$PROJECT" push >/dev/null
  git -C "$rd" pull --ff-only >/dev/null
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'changed policy requires new acknowledgement'; assert_contains "$OUT" 'other.bin'
}

case_quoted_paths_and_command() {
  new_fixture
  rm -rf "$PROJECT"; PROJECT="$TMP/local/quo'ted project"; mkdir -p "$PROJECT/-leading dir"
  printf space > "$PROJECT/file with spaces"; printf quote > "$PROJECT/quo'te"; printf glob > "$PROJECT/'*?[x]'"; printf dash > "$PROJECT/-leading dir/-file"
  init_non_git
  local rd; rd=$(remote_project)
  assert_eq "$(cat "$rd/file with spaces")" space; assert_eq "$(cat "$rd/quo'te")" quote; assert_eq "$(cat "$rd/'*?[x]'")" glob
  export OMPUP_CMD='printf "it'"'"'s quoted"; exec "$SHELL"'
  run_ompup attach; assert_eq "$RC" 0
  assert_contains "$(cat "$LOG")" "it'"
  assert_no_file "$REMOTE/injected"
  export OMPUP_CMD=$'bad\ncommand'
  run_ompup attach; [ "$RC" -ne 0 ] || fail 'control character in OMPUP_CMD should fail'; assert_contains "$OUT" 'OMPUP_CMD contains'
  unset OMPUP_CMD
  badname=$'bad\nname'
  printf bad > "$PROJECT/$badname"
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'newline pathname should fail'; assert_contains "$OUT" 'unsupported control-byte pathname'
  rm "$PROJECT/$badname"
  mkfifo "$PROJECT/pipe"
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'special file should fail closed'; assert_contains "$OUT" 'unsupported special file'
}

case_attach_and_default_safety() {
  new_fixture; init_non_git
  : > "$LOG"
  run_ompup; [ "$RC" -ne 0 ] || fail 'default should not skip remote-owned sync'; assert_contains "$OUT" 'run ompup attach'
  assert_not_contains "$(cat "$LOG")" 'tmux new-session'
  run_ompup attach; assert_eq "$RC" 0; assert_contains "$(cat "$LOG")" 'tmux new-session'
  local rd; rd=$(remote_project); printf remote > "$rd/remote-edit"
  : > "$LOG"; run_ompup; [ "$RC" -ne 0 ] || fail 'default must not attach after ownership conflict'; assert_not_contains "$(cat "$LOG")" 'tmux new-session'
  new_fixture; printf one > "$PROJECT/file.txt"; run_ompup
  assert_eq "$RC" 0; assert_contains "$(cat "$LOG")" 'tmux new-session'
}

case_explicit_ownership_boundaries() {
  new_fixture; init_non_git
  local rd before
  rd=$(remote_project); before=$(snapshot "$rd")
  printf 'unauthorized local\n' > "$PROJECT/file.txt"
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'remote-owned local edit must not sync'
  assert_contains "$OUT" 'non-owning local side changed'; assert_eq "$(snapshot "$rd")" "$before"

  new_fixture; init_non_git
  rd=$(remote_project); printf 'authorized remote\n' > "$rd/file.txt"
  run_ompup pull; assert_eq "$RC" 0
  before=$(snapshot "$PROJECT"); printf 'unauthorized remote\n' > "$rd/file.txt"
  run_ompup pull; [ "$RC" -ne 0 ] || fail 'local-owned remote edit must not pull'
  assert_contains "$OUT" 'non-owning remote side changed'; assert_eq "$(snapshot "$PROJECT")" "$before"
}

case_rename_gap_recovery() {
  new_fixture; init_non_git
  local rd backup
  rd=$(remote_project); run_ompup pull; assert_eq "$RC" 0
  printf 'local handoff\n' > "$PROJECT/file.txt"
  export OMPUP_FAKE_SSH_FAIL_AFTER_MATCH='ompup_backup_copy'
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'sync backup-copy gap injection should fail'
  assert_eq "$(cat "$rd/file.txt")" one
  backup=$(find "$REMOTE/Projects" -maxdepth 1 -type d -name '.ompup-backup-*' -print -quit)
  [ -n "$backup" ] || fail 'sync backup-copy artifact missing'
  unset OMPUP_FAKE_SSH_FAIL_AFTER_MATCH
  run_ompup sync; assert_eq "$RC" 0; assert_contains "$OUT" 'recovered uncommitted transaction'
  rd=$(remote_project); assert_eq "$(cat "$rd/file.txt")" 'local handoff'

  new_fixture; init_non_git
  rd=$(remote_project); printf 'remote handoff\n' > "$rd/file.txt"
  export OMPUP_FAKE_CP_FAIL_AFTER_BACKUP=1
  run_ompup pull; [ "$RC" -ne 0 ] || fail 'pull backup-copy gap injection should fail'
  backup=$(find "$TMP/local" -maxdepth 1 -type d -name '.ompup-backup-*' -print -quit)
  [ -n "$backup" ] || fail 'pull backup-copy artifact missing'
  unset OMPUP_FAKE_CP_FAIL_AFTER_BACKUP
  run_ompup_from "$backup/tree" pull; assert_eq "$RC" 0
  assert_contains "$OUT" 'recovered uncommitted transaction'; assert_eq "$(cat "$PROJECT/file.txt")" 'remote handoff'

  new_fixture; init_git
  rd=$(remote_project); printf 'git remote handoff\n' > "$rd/file.txt"
  export OMPUP_FAKE_CP_FAIL_AFTER_BACKUP=1
  run_ompup pull; [ "$RC" -ne 0 ] || fail 'Git pull backup-copy gap injection should fail'
  backup=$(find "$TMP/local" -maxdepth 1 -type d -name '.ompup-backup-*' -print -quit)
  [ -n "$backup" ] || fail 'Git pull backup-copy artifact missing'
  unset OMPUP_FAKE_CP_FAIL_AFTER_BACKUP
  run_ompup_from "$backup/tree" pull; assert_eq "$RC" 0
  assert_contains "$OUT" 'recovered uncommitted transaction'; assert_eq "$(cat "$PROJECT/file.txt")" 'git remote handoff'
}

case_promotion_window_conflicts() {
  new_fixture; init_non_git
  local rd before_epoch backup
  rd=$(remote_project); run_ompup pull; assert_eq "$RC" 0
  before_epoch=$(sed -n 's/^epoch	//p' "$(state_file)")
  printf 'desired local\n' > "$PROJECT/file.txt"
  export OMPUP_FAKE_SSH_MUTATE_BEFORE_MATCH='/txn/'
  export OMPUP_FAKE_SSH_MUTATE_PATH="$rd/file.txt"
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'remote promotion-window write must block'
  assert_contains "$OUT" 'changed during backup copy'
  backup=$(find "$REMOTE/Projects" -type f -path '*/.ompup-backup-*/tree/file.txt' -print -quit)
  assert_eq "$(cat "$backup")" concurrent
  assert_eq "$(sed -n 's/^epoch	//p' "$(state_file)")" "$before_epoch"

  new_fixture; init_non_git
  rd=$(remote_project); printf 'desired remote\n' > "$rd/file.txt"
  before_epoch=$(sed -n 's/^epoch	//p' "$(state_file)")
  export OMPUP_FAKE_MV_MUTATE_BEFORE_BACKUP="$PROJECT/file.txt"
  run_ompup pull; [ "$RC" -ne 0 ] || fail 'local promotion-window write must block'
  assert_contains "$OUT" 'changed during backup copy'
  backup=$(find "$TMP/local" -type f -path '*/.ompup-backup-*/tree/file.txt' -print -quit)
  assert_eq "$(cat "$backup")" concurrent
  assert_eq "$(sed -n 's/^epoch	//p' "$(state_file)")" "$before_epoch"
}

case_remote_policy_and_secret_defaults() {
  new_fixture; init_non_git
  local rd
  rd=$(remote_project)
  printf '*.tmp\ncache/\n' > "$rd/.ompupignore"
  printf hidden > "$rd/one.tmp"; mkdir "$rd/cache"; printf hidden > "$rd/cache/value"; printf visible > "$rd/kept.txt"
  run_ompup pull; assert_eq "$RC" 0
  assert_no_file "$PROJECT/one.tmp"; assert_no_file "$PROJECT/cache"; assert_eq "$(cat "$PROJECT/kept.txt")" visible
  run_ompup status; assert_eq "$RC" 0; assert_contains "$OUT" 'effective-owner: local'

  new_fixture; init_non_git
  rd=$(remote_project); printf 'bad\trule\n' > "$rd/.ompupignore"; printf remote > "$rd/file.txt"
  run_ompup pull; [ "$RC" -ne 0 ] || fail 'TAB in remote policy must block'
  assert_contains "$OUT" 'unsupported control byte'; assert_eq "$(cat "$PROJECT/file.txt")" one

  new_fixture
  mkdir -p "$PROJECT/.docker" "$PROJECT/.kube" "$PROJECT/.config/gh" "$PROJECT/nested/.docker" "$PROJECT/nested/.kube"
  printf secret > "$PROJECT/.git-credentials"; printf secret > "$PROJECT/.docker/config.json"
  printf secret > "$PROJECT/.kube/config"; printf secret > "$PROJECT/.config/gh/hosts.yml"
  printf secret > "$PROJECT/nested/.docker/config.json"; printf secret > "$PROJECT/nested/.kube/config"
  printf example > "$PROJECT/.env.example"; printf sample > "$PROJECT/.env.sample"
  init_non_git; rd=$(remote_project)
  assert_no_file "$rd/.git-credentials"; assert_no_file "$rd/.docker/config.json"; assert_no_file "$rd/.kube"
  assert_no_file "$rd/.config/gh/hosts.yml"; assert_no_file "$rd/nested/.docker/config.json"; assert_no_file "$rd/nested/.kube"
  assert_eq "$(cat "$rd/.env.example")" example; assert_eq "$(cat "$rd/.env.sample")" sample
}

case_malicious_state_and_journals() {
  new_fixture; init_non_git
  local state journal rd target victim backup
  state=$(state_file); victim="$TMP/victim"; mkdir "$victim"; printf safe > "$victim/value"
  replace_field "$state" baseline_epoch '../../../../victim'
  run_ompup status; [ "$RC" -ne 0 ] || fail 'traversal baseline epoch must block'
  assert_contains "$OUT" 'invalid state baseline epoch'; assert_eq "$(cat "$victim/value")" safe

  new_fixture; init_non_git; rd=$(remote_project); run_ompup pull; assert_eq "$RC" 0
  printf local > "$PROJECT/file.txt"; export OMPUP_FAKE_SSH_FAIL_AFTER_MATCH='ompup_backup_copy'
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'journal setup should interrupt'
  unset OMPUP_FAKE_SSH_FAIL_AFTER_MATCH
  journal=$(transaction_journal); replace_field "$journal" target_epoch 0003
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'noncanonical journal epoch must block'
  assert_contains "$OUT" 'invalid transaction target epoch'

  new_fixture; init_non_git; rd=$(remote_project); run_ompup pull; assert_eq "$RC" 0
  printf local > "$PROJECT/file.txt"; export OMPUP_FAKE_SSH_FAIL_AFTER_MATCH='ompup_backup_copy'
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'journal setup should interrupt'
  unset OMPUP_FAKE_SSH_FAIL_AFTER_MATCH
  journal=$(transaction_journal); printf 'unexpected\tfield\n' >> "$journal"
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'unknown journal field must block'
  assert_contains "$OUT" 'unknown transaction journal field'

  new_fixture; init_non_git; rd=$(remote_project); run_ompup pull; assert_eq "$RC" 0
  printf local > "$PROJECT/file.txt"; export OMPUP_FAKE_SSH_FAIL_AFTER_MATCH='ompup_backup_copy'
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'journal setup should interrupt'
  unset OMPUP_FAKE_SSH_FAIL_AFTER_MATCH
  journal=$(transaction_journal); target=$(sed -n 's/^target_epoch	//p' "$journal")
  victim="$TMP/symlink-victim"; mkdir "$victim"; printf safe > "$victim/value"
  ln -s "$victim" "${journal%/transactions/*}/baselines/$target"
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'symlink baseline deletion must block'
  assert_contains "$OUT" 'refusing symlink baseline generation deletion'; assert_eq "$(cat "$victim/value")" safe
}

case_cleanup_recovery_and_status_blockers() {
  new_fixture
  printf one > "$PROJECT/file.txt"
  export OMPUP_FAKE_SSH_FAIL_MATCH='rm -rf -- tree'
  run_ompup sync; assert_eq "$RC" 0; assert_contains "$OUT" 'committed journal retained'
  journal=$(transaction_journal); assert_file "$journal"
  unset OMPUP_FAKE_SSH_FAIL_MATCH
  run_ompup pull; assert_eq "$RC" 0; assert_contains "$OUT" 'finalized committed transaction'
  [ -z "$(transaction_journal 2>/dev/null || true)" ] || fail 'cleanup recovery left local journal'

  new_fixture; init_non_git
  export OMPUP_FAKE_SSH_FAIL=1
  run_ompup status; assert_eq "$RC" 0; assert_contains "$OUT" 'blocker: remote connectivity failed'
  assert_not_contains "$OUT" 'failed to compare remote tree'
  unset OMPUP_FAKE_SSH_FAIL
  rd=$(remote_project); rm -rf "$rd"
  run_ompup status; assert_eq "$RC" 0; assert_contains "$OUT" 'remote destination/marker mismatch: absent'
  assert_contains "$OUT" 'remote-changed: (not compared)'

  new_fixture; init_non_git
  printf 'schema\t2\nidentity_hash\twrong\n' > "$(marker_file)"
  run_ompup status; assert_eq "$RC" 0; assert_contains "$OUT" 'blocker: remote marker'
  assert_contains "$OUT" 'remote-changed: (not compared)'

  new_fixture; init_git
  rd=$(remote_project); rm -rf "$rd/.git"
  run_ompup status; assert_eq "$RC" 0; assert_contains "$OUT" 'BLOCK:remote Git metadata is missing'
  assert_contains "$OUT" 'remote-changed: (not compared)'
}

case_initial_sync_third_versions() {
  new_fixture
  printf 'source\n' > "$PROJECT/file.txt"
  export OMPUP_FAKE_SSH_FAIL_AFTER_MATCH='cp -Rp'
  run_ompup sync
  [ "$RC" -ne 0 ] || fail 'post-rename crash injection should fail'
  local rd journal
  rd=$(remote_project); journal=$(transaction_journal)
  assert_file "$rd/file.txt"; assert_file "$journal"
  printf 'remote edit\n' > "$rd/post-crash.txt"
  unset OMPUP_FAKE_SSH_FAIL_AFTER_MATCH
  run_ompup sync
  [ "$RC" -ne 0 ] || fail 'post-crash third version must block recovery'
  assert_contains "$OUT" 'third remote version'
  assert_eq "$(cat "$rd/post-crash.txt")" 'remote edit'
  assert_file "$journal"

  new_fixture
  printf 'source\n' > "$PROJECT/file.txt"
  export OMPUP_FAKE_SSH_CREATE_DEST_BEFORE_MATCH='cp -Rp'
  run_ompup sync
  [ "$RC" -ne 0 ] || fail 'concurrent initial destination must block promotion'
  rd=$(remote_project); assert_eq "$(cat "$rd/concurrent.txt")" concurrent
  unset OMPUP_FAKE_SSH_CREATE_DEST_BEFORE_MATCH
  run_ompup sync
  [ "$RC" -ne 0 ] || fail 'never-adopted concurrent destination must block recovery'
  assert_contains "$OUT" 'third remote version'
  assert_eq "$(cat "$rd/concurrent.txt")" concurrent
}

case_git_metadata_race() {
  new_fixture
  init_git
  local rd state before_epoch before_remote
  rd=$(remote_project)
  run_ompup pull; assert_eq "$RC" 0
  state=$(state_file); before_epoch=$(sed -n 's/^epoch	//p' "$state"); before_remote=$(snapshot "$rd")
  export OMPUP_FAKE_SSH_GIT_COMMIT_BEFORE_MATCH='/txn/'
  export OMPUP_FAKE_SSH_GIT_COMMIT_STAMP="$TMP/git-race-fired"
  export OMPUP_FAKE_SSH_GIT_PROJECT="$PROJECT"
  run_ompup sync
  [ "$RC" -ne 0 ] || fail 'metadata-only local HEAD race must block ownership commit'
  assert_contains "$OUT" 'local candidate Git tuple changed'
  assert_eq "$(sed -n 's/^epoch	//p' "$state")" "$before_epoch"
  unset OMPUP_FAKE_SSH_GIT_COMMIT_BEFORE_MATCH
  run_ompup sync
  [ "$RC" -ne 0 ] || fail 'Git divergence after rollback must remain blocked'
  assert_contains "$OUT" 'remote Git tuple diverged'
  assert_eq "$(snapshot "$rd")" "$before_remote"
}

case_exclusive_control_creation() {
  local sentinel before state transactions

  new_fixture
  sentinel="$TMP/local-component-sentinel"; mkdir "$sentinel"; printf safe > "$sentinel/value"
  mkdir -p "$STATE"; ln -s "$sentinel" "$STATE/ompup"; before=$(snapshot "$sentinel")
  printf source > "$PROJECT/file"
  run_ompup sync
  [ "$RC" -ne 0 ] || fail 'symlinked local state component must block'
  assert_eq "$(snapshot "$sentinel")" "$before"

  new_fixture
  init_non_git
  run_ompup pull; assert_eq "$RC" 0
  state=$(state_file); transactions="${state%/state}/transactions"
  sentinel="$TMP/local-journal-sentinel"; mkdir "$sentinel"; printf safe > "$sentinel/value"; before=$(snapshot "$sentinel")
  rmdir "$transactions"; ln -s "$sentinel" "$transactions"
  printf local > "$PROJECT/file"
  run_ompup sync
  [ "$RC" -ne 0 ] || fail 'symlinked local transaction directory must block'
  assert_eq "$(snapshot "$sentinel")" "$before"

  new_fixture
  sentinel="$TMP/remote-component-sentinel"; mkdir "$sentinel"; printf safe > "$sentinel/value"
  mkdir -p "$REMOTE/Projects"; ln -s "$sentinel" "$REMOTE/Projects/.ompup-v2"; before=$(snapshot "$sentinel")
  printf source > "$PROJECT/file"
  run_ompup sync
  [ "$RC" -ne 0 ] || fail 'symlinked remote control component must block'
  assert_eq "$(snapshot "$sentinel")" "$before"

  new_fixture
  sentinel="$TMP/journal-sentinel"; mkdir "$sentinel"; printf safe > "$sentinel/value"; before=$(snapshot "$sentinel")
  printf source > "$PROJECT/file"
  export OMPUP_FAKE_SSH_SYMLINK_ATTACK_BEFORE_MATCH='/txn/'
  export OMPUP_FAKE_SSH_SYMLINK_ATTACK_KIND=journal
  export OMPUP_FAKE_SSH_SYMLINK_ATTACK_TARGET="$sentinel"
  run_ompup sync
  [ "$RC" -ne 0 ] || fail 'precreated remote journal symlink must block'
  assert_eq "$(snapshot "$sentinel")" "$before"

  new_fixture
  sentinel="$TMP/marker-sentinel"; mkdir "$sentinel"; printf safe > "$sentinel/value"; before=$(snapshot "$sentinel")
  printf source > "$PROJECT/file"
  export OMPUP_FAKE_SSH_SYMLINK_ATTACK_BEFORE_MATCH='.marker'
  export OMPUP_FAKE_SSH_SYMLINK_ATTACK_KIND=marker
  export OMPUP_FAKE_SSH_SYMLINK_ATTACK_TARGET="$sentinel"
  run_ompup sync
  [ "$RC" -ne 0 ] || fail 'precreated remote marker temp symlink must block'
  assert_eq "$(snapshot "$sentinel")" "$before"

  new_fixture
  sentinel="$TMP/state-sentinel"; mkdir "$sentinel"; printf safe > "$sentinel/value"; before=$(snapshot "$sentinel")
  printf source > "$PROJECT/file"
  export OMPUP_FAKE_SSH_SYMLINK_ATTACK_BEFORE_MATCH='/marker'
  export OMPUP_FAKE_SSH_SYMLINK_ATTACK_KIND=state
  export OMPUP_FAKE_SSH_SYMLINK_ATTACK_TARGET="$sentinel"
  run_ompup sync
  [ "$RC" -ne 0 ] || fail 'precreated local state temp symlink must block'
  assert_eq "$(snapshot "$sentinel")" "$before"
}

case_rules_publication_races() {
  local sentinel before

  new_fixture
  sentinel="$TMP/transaction-rules-sentinel"; printf safe > "$sentinel"; before=$(cat "$sentinel")
  printf source > "$PROJECT/file"
  export OMPUP_FAKE_MKDIR_RULES_ATTACK=transaction OMPUP_FAKE_MKDIR_RULES_TARGET="$sentinel"
  run_ompup sync
  [ "$RC" -ne 0 ] || fail 'precreated transaction rules symlink must block'
  assert_eq "$(cat "$sentinel")" "$before"

  new_fixture
  sentinel="$TMP/baseline-rules-sentinel"; printf safe > "$sentinel"; before=$(cat "$sentinel")
  printf source > "$PROJECT/file"
  export OMPUP_FAKE_MKDIR_RULES_ATTACK=baseline OMPUP_FAKE_MKDIR_RULES_TARGET="$sentinel"
  run_ompup sync
  [ "$RC" -ne 0 ] || fail 'precreated baseline rules symlink must block'
  assert_eq "$(cat "$sentinel")" "$before"
}

case_container_path_races() {
  local sentinel before rd

  new_fixture
  sentinel="$TMP/remote-candidate-container-sentinel"; mkdir "$sentinel"; printf safe > "$sentinel/value"; before=$(snapshot "$sentinel")
  printf source > "$PROJECT/file"
  export OMPUP_FAKE_SSH_SYMLINK_ATTACK_BEFORE_MATCH='exec rsync'
  export OMPUP_FAKE_SSH_SYMLINK_ATTACK_KIND=candidate_container OMPUP_FAKE_SSH_SYMLINK_ATTACK_TARGET="$sentinel"
  run_ompup sync
  [ "$RC" -ne 0 ] || fail 'replaced remote candidate container must block'
  assert_eq "$(snapshot "$sentinel")" "$before"

  new_fixture; init_non_git; rd=$(remote_project); run_ompup pull; assert_eq "$RC" 0
  sentinel="$TMP/remote-candidate-tree-sentinel"; mkdir "$sentinel"; printf safe > "$sentinel/value"; before=$(snapshot "$sentinel")
  printf local > "$PROJECT/file"
  export OMPUP_FAKE_SSH_SYMLINK_ATTACK_BEFORE_MATCH='source=$HOME/'
  export OMPUP_FAKE_SSH_SYMLINK_ATTACK_KIND=candidate_tree OMPUP_FAKE_SSH_SYMLINK_ATTACK_TARGET="$sentinel"
  run_ompup sync
  [ "$RC" -ne 0 ] || fail 'precreated remote candidate tree symlink must block'
  assert_eq "$(snapshot "$sentinel")" "$before"

  new_fixture; init_non_git; rd=$(remote_project); run_ompup pull; assert_eq "$RC" 0
  sentinel="$TMP/remote-backup-tree-sentinel"; mkdir "$sentinel"; printf safe > "$sentinel/value"; before=$(snapshot "$sentinel")
  printf local > "$PROJECT/file"
  export OMPUP_FAKE_SSH_SYMLINK_ATTACK_BEFORE_MATCH=ompup_backup_copy
  export OMPUP_FAKE_SSH_SYMLINK_ATTACK_KIND=backup_tree OMPUP_FAKE_SSH_SYMLINK_ATTACK_TARGET="$sentinel"
  run_ompup sync
  [ "$RC" -ne 0 ] || fail 'precreated remote backup tree symlink must block'
  assert_eq "$(snapshot "$sentinel")" "$before"

  new_fixture; init_non_git; rd=$(remote_project); printf remote > "$rd/file.txt"
  sentinel="$TMP/local-candidate-container-sentinel"; mkdir "$sentinel"; printf safe > "$sentinel/value"; before=$(snapshot "$sentinel")
  export OMPUP_FAKE_CP_REPLACE_CONTAINER=1 OMPUP_FAKE_CP_REPLACE_STAMP="$TMP/candidate-replaced"
  export OMPUP_FAKE_CP_REPLACE_TARGET="$sentinel" OMPUP_FAKE_CP_REPLACE_KIND=candidate
  run_ompup pull
  [ "$RC" -ne 0 ] || fail 'replaced local candidate container must block'
  assert_eq "$(snapshot "$sentinel")" "$before"

  new_fixture; init_non_git; rd=$(remote_project); printf remote > "$rd/file.txt"
  sentinel="$TMP/local-backup-container-sentinel"; mkdir "$sentinel"; printf safe > "$sentinel/value"; before=$(snapshot "$sentinel")
  export OMPUP_FAKE_CP_REPLACE_CONTAINER=1 OMPUP_FAKE_CP_REPLACE_STAMP="$TMP/backup-replaced"
  export OMPUP_FAKE_CP_REPLACE_TARGET="$sentinel" OMPUP_FAKE_CP_REPLACE_KIND=backup
  run_ompup pull
  [ "$RC" -ne 0 ] || fail 'replaced local backup container must block'
  assert_eq "$(snapshot "$sentinel")" "$before"
}

case_control_pathnames() {
  local name rd

  new_fixture
  name=$'local-\001-control'; printf x > "$PROJECT/$name"
  run_ompup sync
  [ "$RC" -ne 0 ] || fail 'local C0 pathname must block'
  assert_contains "$OUT" 'unsupported control-byte pathname'
  assert_not_contains "$OUT" $'\001'

  new_fixture
  name=$'local-\177-delete'; printf x > "$PROJECT/$name"
  run_ompup sync
  [ "$RC" -ne 0 ] || fail 'local DEL pathname must block'
  assert_not_contains "$OUT" $'\177'

  new_fixture
  name=$'local-\033]0;owned\007-osc'; printf x > "$PROJECT/$name"
  run_ompup sync
  [ "$RC" -ne 0 ] || fail 'local OSC pathname must block'
  assert_not_contains "$OUT" $'\033'
  assert_not_contains "$OUT" $'\007'

  new_fixture; init_non_git; rd=$(remote_project)
  name=$'remote-\033]0;owned\007-osc'; printf x > "$rd/$name"
  run_ompup status
  assert_eq "$RC" 0
  assert_contains "$OUT" 'blocker: remote tree validation failed'
  assert_not_contains "$OUT" $'\033'
  assert_not_contains "$OUT" $'\007'

  rm "$rd/$name"
  name=$'remote-\177-delete'; printf x > "$rd/$name"
  run_ompup pull
  [ "$RC" -ne 0 ] || fail 'remote DEL pathname must block pull'
  assert_contains "$OUT" 'unsupported control-byte pathname'
  assert_not_contains "$OUT" $'\177'
}

all_cases=(
  help_version initial_non_git initial_git_and_git_boundary round_trip_and_status
  divergent_git dirty_git_boundaries both_side_conflict identity_isolation
  marker_and_collision dependency_and_transport_failures recovery_and_rollback
  locking dry_run_zero_mutation exclusions_and_acknowledgement
  quoted_paths_and_command attach_and_default_safety explicit_ownership_boundaries
  rename_gap_recovery promotion_window_conflicts remote_policy_and_secret_defaults
  malicious_state_and_journals cleanup_recovery_and_status_blockers
  initial_sync_third_versions git_metadata_race exclusive_control_creation
  rules_publication_races container_path_races control_pathnames
)

requested=${1:-all}
for name in "${all_cases[@]}"; do
  if [ "$requested" = all ] || [ "$requested" = "$name" ]; then
    "case_$name"
    printf 'ok - %s\n' "$name"
  fi
done
