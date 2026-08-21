#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ompup-pack.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fail() { printf 'not ok - pack: %s\n' "$*" >&2; exit 1; }

for command in npm node tar; do command -v "$command" >/dev/null 2>&1 || fail "required command unavailable: $command"; done

(
  cd "$ROOT_DIR" || exit 1
  npm pack --dry-run --ignore-scripts >/dev/null
  npm pack --silent --ignore-scripts --pack-destination "$TMP" >/dev/null
)
archive=$(printf '%s\n' "$TMP"/*.tgz)
[ -f "$archive" ] || fail 'npm pack did not create exactly one archive'
[ "$(printf '%s\n' "$TMP"/*.tgz | wc -l | tr -d ' ')" = 1 ] || fail 'npm pack created multiple archives'
mkdir "$TMP/unpacked"
tar -xzf "$archive" -C "$TMP/unpacked"
package="$TMP/unpacked/package"
[ -d "$package" ] || fail 'archive has no package root'

actual="$TMP/actual-files"
expected="$TMP/expected-files"
(
  cd "$package" || exit 1
  find . -type f -print | sed 's#^./##' | LC_ALL=C sort
) > "$actual"
cat > "$expected" <<'EOF'
CHANGELOG.md
LICENSE
README.md
bin/ompup
extension/index.ts
package.json
EOF
if ! cmp -s "$expected" "$actual"; then
  printf '%s\n' 'expected package files:' >&2
  cat "$expected" >&2
  printf '%s\n' 'actual package files:' >&2
  cat "$actual" >&2
  fail 'package contents differ'
fi

node -e '
  const pkg = require(process.argv[1]);
  if (pkg.name !== "ompup" || pkg.version !== "0.2.0") process.exit(1);
  if (pkg.bin?.ompup !== "./bin/ompup") process.exit(1);
  if (pkg.omp?.extensions?.length !== 1 || pkg.omp.extensions[0] !== "./extension/index.ts") process.exit(1);
' "$package/package.json" || fail 'packed metadata is incorrect'
[ -x "$package/bin/ompup" ] || fail 'packed CLI is not executable'
[ -f "$package/extension/index.ts" ] || fail 'packed extension is missing'

unexpected=$(find "$package" \( -path '*/tests/*' -o -path '*/fixtures/*' -o -name '.env' -o -name '*.pem' -o -name '*.key' -o -name 'bun.lock' -o -name 'tsconfig.json' \) -print -quit)
[ -z "$unexpected" ] || fail "package contains excluded path: $unexpected"
printf '%s\n' 'ok - package contents and metadata'
