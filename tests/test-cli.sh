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
}
run_ompup() {
  set +e
  OUT=$(cd "$PROJECT" && /bin/bash "$OMPUP" "$@" 2>&1)
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
  export OMPUP_FAKE_SSH_FAIL_MATCH="mkdir '\\''Projects/.ompup-candidate"
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'pre-journal candidate failure should fail'
  assert_no_file "$(state_file 2>/dev/null || true)"; [ -z "$(marker_file 2>/dev/null || true)" ] || fail 'pre-journal failure published marker'
  unset OMPUP_FAKE_SSH_FAIL_MATCH

  new_fixture; printf one > "$PROJECT/file.txt"
  export OMPUP_FAKE_SSH_FAIL_MATCH="mv '\\''Projects/.ompup-candidate"
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'post-journal initial swap failure should fail'
  assert_file "$(marker_file)"; [ -n "$(find "$STATE" -type f -name journal -print -quit)" ] || fail 'durable initial journal missing'
  unset OMPUP_FAKE_SSH_FAIL_MATCH
  run_ompup sync; assert_eq "$RC" 0; assert_contains "$OUT" 'recovered uncommitted transaction'

  new_fixture; init_non_git
  local rd; rd=$(remote_project); printf 'pre\n' > "$PROJECT/file.txt"
  export OMPUP_FAKE_SSH_FAIL_MATCH='.ompup-backup-'
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'injected swap failure should fail'; assert_eq "$(cat "$rd/file.txt")" one
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
  init_non_git; printf changed > "$PROJECT/file"
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
  run_ompup sync; [ "$RC" -ne 0 ] || fail 'newline pathname should fail'; assert_contains "$OUT" 'unsupported CR/LF/TAB pathname'
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

all_cases=(
  help_version initial_non_git initial_git_and_git_boundary round_trip_and_status
  divergent_git dirty_git_boundaries both_side_conflict identity_isolation
  marker_and_collision dependency_and_transport_failures recovery_and_rollback
  locking dry_run_zero_mutation exclusions_and_acknowledgement
  quoted_paths_and_command attach_and_default_safety
)

requested=${1:-all}
for name in "${all_cases[@]}"; do
  if [ "$requested" = all ] || [ "$requested" = "$name" ]; then
    "case_$name"
    printf 'ok - %s\n' "$name"
  fi
done
