#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Test tools/environments/probe-reachability.sh against a local HTTP server:
# a non-GNU ldd must not stop the probe, a GET to a server that ignores the
# byte range must be capped and reported as range-ignored, and an unknown
# argument must exit 2. Needs python3 and curl; touches no outside host.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
probe="$repo_root/tools/environments/probe-reachability.sh"
work="$(mktemp -d)"
server_pid=""
cleanup() {
    if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
    rm -rf "$work"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# python's http.server ignores Range and sends Content-Length, which is the
# case the size cap must catch. 1 MiB is far above the probe's 64 KiB cap.
mkdir -p "$work/www" "$work/bin"
head -c 1048576 /dev/zero > "$work/www/big.bin"
printf 'small\n' > "$work/www/small.txt"
port="$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
(cd "$work/www" && exec python3 -I -m http.server "$port" --bind 127.0.0.1) >/dev/null 2>&1 &
server_pid=$!
for _ in $(seq 50); do
    curl -s -o /dev/null --noproxy '*' "http://127.0.0.1:$port/small.txt" && break
    sleep 0.1
done

printf '# comment\nhttp://127.0.0.1:%s/big.bin\nhttp://127.0.0.1:%s/small.txt\n' "$port" "$port" > "$work/hosts.txt"

# A FreeBSD-style ldd: exists, rejects --version.
printf '#!/bin/sh\necho "ldd: illegal option -- -" >&2\nexit 1\n' > "$work/bin/ldd"
chmod +x "$work/bin/ldd"

run() {
    env -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy NO_PROXY='*' \
        PATH="$work/bin:$PATH" HOSTS_FILE="$work/hosts.txt" PROBE_TIMEOUT=10 \
        bash "$probe" "$@"
}

head_out="$(run)" || fail "HEAD probe exited non-zero with a non-GNU ldd"
grep -q 'glibc' <<<"$head_out" && fail "non-GNU ldd reported as glibc"
grep -Eq '^200 +reachable +http://127\.0\.0\.1:[0-9]+/big\.bin$' <<<"$head_out" ||
    fail "HEAD of big.bin not reachable: $head_out"

get_out="$(run --get)" || fail "GET probe exited non-zero"
grep -Eq '^200 +range-ignored +http://127\.0\.0\.1:[0-9]+/big\.bin$' <<<"$get_out" ||
    fail "GET of a range-ignoring server not capped as range-ignored: $get_out"
grep -Eq '^200 +reachable +http://127\.0\.0\.1:[0-9]+/small\.txt$' <<<"$get_out" ||
    fail "small GET body not reachable: $get_out"

json="$(run --json --get)" || fail "JSON probe exited non-zero"
python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["method"]=="get"; assert {h["outcome"] for h in d["hosts"]}=={"range-ignored","reachable"}' "$json" ||
    fail "JSON output invalid: $json"

rc=0; run --bogus >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "unknown argument exited $rc, expected 2"

echo 'PASS: probe tolerates non-GNU ldd, caps range-ignoring GETs, rejects unknown arguments'
