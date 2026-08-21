#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd -P)
OMPUP="$ROOT_DIR/bin/ompup"
TMP=
SSHD_PID=
REMOTE_ROOT=
REAL_HOME=
OUT=

fail() {
  printf 'not ok - localhost ssh: %s\n' "$*" >&2
  [ -z "${OUT:-}" ] || printf '%s\n' "$OUT" >&2
  if [ -n "${TMP:-}" ] && [ -f "$TMP/sshd.log" ]; then
    printf '%s\n' '--- sshd log ---' >&2
    cat "$TMP/sshd.log" >&2
  fi
  exit 1
}

cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "${SSHD_PID:-}" ]; then
    kill "$SSHD_PID" 2>/dev/null || true
    wait "$SSHD_PID" 2>/dev/null || true
  fi
  if [ -n "${REMOTE_ROOT:-}" ] && [ -n "${REAL_HOME:-}" ]; then
    case "$REMOTE_ROOT" in
      .ompup-localhost-test-*) rm -rf -- "${REAL_HOME:?}/${REMOTE_ROOT:?}" ;;
      *) printf 'refusing unsafe remote cleanup path: %s\n' "$REMOTE_ROOT" >&2; rc=1 ;;
    esac
  fi
  [ -z "${TMP:-}" ] || rm -rf -- "$TMP"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

SSHD=$(command -v sshd 2>/dev/null || true)
if [ -z "$SSHD" ] && [ -x /usr/sbin/sshd ]; then SSHD=/usr/sbin/sshd; fi
if [ -z "$SSHD" ]; then
  if [ "${OMPUP_ALLOW_SSHD_SKIP:-0}" = 1 ] && [ -z "${CI:-}" ]; then
    printf '%s\n' 'ok - localhost ssh (explicit local skip: sshd unavailable)'
    exit 0
  fi
  fail 'sshd is unavailable (set OMPUP_ALLOW_SSHD_SKIP=1 only for an explicit local skip)'
fi
for command in ssh ssh-keygen rsync git python3; do
  command -v "$command" >/dev/null 2>&1 || fail "required command unavailable: $command"
done
REAL_SSH=$(command -v ssh)
REAL_HOME=$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')
REAL_HOME=$(cd "$REAL_HOME" && pwd -P)
CURRENT_USER=$(id -un)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ompup-localhost-ssh.XXXXXX")
REMOTE_ROOT=".ompup-localhost-test-${TMP##*/}-$$"
case "$REMOTE_ROOT" in *[!A-Za-z0-9._-]*) fail 'generated remote root is not a safe path segment' ;; esac
[ ! -e "$REAL_HOME/$REMOTE_ROOT" ] || fail 'generated remote root already exists'

mkdir -p "$TMP/keys" "$TMP/client-home/.ssh" "$TMP/local/project" "$TMP/local-state" "$TMP/bin"
chmod 700 "$TMP/keys" "$TMP/client-home/.ssh"
ssh-keygen -q -t ed25519 -N '' -f "$TMP/keys/host" >/dev/null
ssh-keygen -q -t ed25519 -N '' -f "$TMP/keys/client" >/dev/null
cp "$TMP/keys/client.pub" "$TMP/authorized_keys"
chmod 600 "$TMP/authorized_keys"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')

cat > "$TMP/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
AddressFamily inet
HostKey $TMP/keys/host
PidFile $TMP/sshd.pid
AuthorizedKeysFile $TMP/authorized_keys
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM no
PermitRootLogin no
StrictModes no
AllowUsers $CURRENT_USER
PrintMotd no
LogLevel VERBOSE
Subsystem sftp internal-sftp
EOF

read -r HOST_KEY_TYPE HOST_KEY_DATA _ < "$TMP/keys/host.pub"
printf 'ompup-localhost-fixture-host %s %s\n' "$HOST_KEY_TYPE" "$HOST_KEY_DATA" > "$TMP/known_hosts"
cat > "$TMP/client_config" <<EOF
Host ompup-localhost-fixture
  HostName 127.0.0.1
  Port $PORT
  User $CURRENT_USER
  IdentityFile $TMP/keys/client
  IdentitiesOnly yes
  UserKnownHostsFile $TMP/known_hosts
  StrictHostKeyChecking yes
  HostKeyAlias ompup-localhost-fixture-host
  BatchMode yes
  PasswordAuthentication no
  KbdInteractiveAuthentication no
  LogLevel ERROR
EOF

cat > "$TMP/bin/ssh" <<'EOF'
#!/bin/sh
set -eu
exec "$OMPUP_TEST_REAL_SSH" -F "$OMPUP_TEST_SSH_CONFIG" "$@"
EOF
chmod 755 "$TMP/bin/ssh"

"$SSHD" -t -f "$TMP/sshd_config" || fail 'sshd rejected the disposable configuration'
"$SSHD" -D -e -f "$TMP/sshd_config" > "$TMP/sshd.log" 2>&1 &
SSHD_PID=$!
ready=0
attempt=0
while [ "$attempt" -lt 100 ]; do
  if "$REAL_SSH" -F "$TMP/client_config" ompup-localhost-fixture true >/dev/null 2>&1; then ready=1; break; fi
  kill -0 "$SSHD_PID" 2>/dev/null || break
  attempt=$((attempt + 1))
  sleep 0.1
done
[ "$ready" -eq 1 ] || fail 'disposable sshd did not accept the fixture key'

export HOME="$TMP/client-home"
export XDG_STATE_HOME="$TMP/local-state"
export OMPUP_HOST=ompup-localhost-fixture
export OMPUP_REMOTE_ROOT="$REMOTE_ROOT"
export OMPUP_TEST_REAL_SSH="$REAL_SSH"
export OMPUP_TEST_SSH_CONFIG="$TMP/client_config"
export PATH="$TMP/bin:$PATH"
unset OMPUP_EXCLUDES OMPUP_CMD

printf 'local one\n' > "$TMP/local/project/file.txt"
printf '#!/bin/sh\nprintf "mode-preserved\\n"\n' > "$TMP/local/project/run.sh"
chmod 755 "$TMP/local/project/run.sh"
OUT=$(cd "$TMP/local/project" && /bin/bash "$OMPUP" sync 2>&1) || fail 'initial non-Git sync failed'
case "$OUT" in *'owner=remote epoch=1'*) ;; *) fail 'sync did not report remote ownership' ;; esac

remote_project=
for candidate in "$REAL_HOME/$REMOTE_ROOT"/*--*; do
  [ -d "$candidate" ] || continue
  [ -z "$remote_project" ] || fail 'sync created more than one remote project'
  remote_project=$candidate
done
[ -n "$remote_project" ] || fail 'sync did not create an addressed remote project'
[ "$(cat "$remote_project/file.txt")" = 'local one' ] || fail 'remote bytes differ after sync'
[ -x "$remote_project/run.sh" ] || fail 'remote executable mode was not preserved'
[ ! -e "$remote_project/.git" ] || fail 'non-Git sync unexpectedly created .git'
address=${remote_project##*/}
marker="$REAL_HOME/$REMOTE_ROOT/.ompup-v2/$address/marker"
[ -f "$marker" ] || fail 'remote identity marker is missing'

OUT=$(cd "$TMP/local/project" && /bin/bash "$OMPUP" status 2>&1) || fail 'remote-owned status failed'
case "$OUT" in *'identity-kind: non-git'*'committed-owner: remote'*'effective-owner: remote'*'blocker: none'*) ;; *) fail 'remote-owned status is incomplete' ;; esac

"$REAL_SSH" -F "$TMP/client_config" ompup-localhost-fixture \
  "printf '%s\\n' 'remote two' > '$REMOTE_ROOT/$address/file.txt'; printf '%s\\n' 'remote only' > '$REMOTE_ROOT/$address/remote.txt'"
OUT=$(cd "$TMP/local/project" && /bin/bash "$OMPUP" pull 2>&1) || fail 'remote-to-local pull failed'
case "$OUT" in *'owner=local epoch=2'*) ;; *) fail 'pull did not report local ownership' ;; esac
[ "$(cat "$TMP/local/project/file.txt")" = 'remote two' ] || fail 'local bytes differ after pull'
[ "$(cat "$TMP/local/project/remote.txt")" = 'remote only' ] || fail 'pull omitted a remote-created file'
[ -x "$TMP/local/project/run.sh" ] || fail 'local executable mode was not preserved'

OUT=$(cd "$TMP/local/project" && /bin/bash "$OMPUP" status 2>&1) || fail 'local-owned status failed'
case "$OUT" in *'committed-owner: local'*'effective-owner: local'*'epoch: 2'*'blocker: none'*) ;; *) fail 'local-owned status is incomplete' ;; esac
printf '%s\n' 'ok - localhost ssh non-Git handoff'
