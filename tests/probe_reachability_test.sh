#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Test tools/environments/probe-reachability.sh with stub curl and ldd
# executables, so no network is used. The stub curl reproduces what curl 8.5
# was measured to do (2026-11-04) against servers that ignore a byte range:
# with --max-filesize it stops and exits 63, still reporting the status code.
# Checks: a non-GNU ldd does not stop the probe; --get passes the size cap
# and reports a capped transfer as range-ignored; outcomes are classified;
# --json is valid; an unknown argument exits 2. Needs jq.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
probe="$repo_root/tools/environments/probe-reachability.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$work/bin"
cat > "$work/hosts.txt" <<'EOF'
# comment line
https://range-ignoring.test/big.bin
https://honours-range.test/file
https://refusing.test/api
https://bad-cert.test/
EOF

# Stub curl: the URL is the last argument; -w '%{http_code}' output goes to
# stdout, as with the real curl.
cat > "$work/bin/curl" <<'SH'
#!/bin/sh
args="$*"
for url in "$@"; do :; done
case "$args" in *" -r 0-0 "*) mode=get ;; *" -I "*) mode=head ;; *) echo "stub curl: no method in: $args" >&2; exit 97 ;; esac
if [ "$mode" = get ]; then
    case "$args" in *"--max-filesize 65536"*) ;; *) echo "stub curl: GET without size cap" >&2; exit 97 ;; esac
fi
case "$url" in
    https://range-ignoring.test/*) printf 200; [ "$mode" = get ] && exit 63; exit 0 ;;
    https://honours-range.test/*)  [ "$mode" = get ] && printf 206 || printf 200; exit 0 ;;
    https://refusing.test/*)       printf 403; exit 0 ;;
    https://bad-cert.test/*)       printf 000; exit 60 ;;
esac
printf 000; exit 6
SH
# A FreeBSD-style ldd: exists, rejects --version.
printf '#!/bin/sh\necho "ldd: illegal option -- -" >&2\nexit 1\n' > "$work/bin/ldd"
chmod +x "$work/bin/curl" "$work/bin/ldd"

run() { PATH="$work/bin:$PATH" HOSTS_FILE="$work/hosts.txt" bash "$probe" "$@"; }
row() { grep -Eq "^$1 +$2 +$3\$" <<<"$4" || fail "expected '$1 $2 $3' in: $4"; }

head_out="$(run)" || fail "HEAD probe exited non-zero with a non-GNU ldd"
grep -q 'glibc' <<<"$head_out" && fail "non-GNU ldd reported as glibc"
row 200 reachable 'https://range-ignoring\.test/big\.bin' "$head_out"
row 403 refused 'https://refusing\.test/api' "$head_out"
row 000 tls-failed 'https://bad-cert\.test/' "$head_out"

get_out="$(run --get)" || fail "GET probe exited non-zero"
row 200 range-ignored 'https://range-ignoring\.test/big\.bin' "$get_out"
row 206 reachable 'https://honours-range\.test/file' "$get_out"

json="$(run --json --get)" || fail "JSON probe exited non-zero"
jq -e '.method == "get" and (.hosts | length) == 4 and
       ([.hosts[].outcome] | sort) == ["range-ignored","reachable","refused","tls-failed"]' \
    <<<"$json" >/dev/null || fail "JSON output wrong: $json"

rc=0; run --bogus >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "unknown argument exited $rc, expected 2"

echo 'PASS: probe tolerates non-GNU ldd, caps range-ignoring GETs, classifies outcomes'
