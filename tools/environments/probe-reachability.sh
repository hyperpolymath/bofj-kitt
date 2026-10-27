#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# probe-reachability.sh — measure which toolchain hosts this environment can
# reach (experiment X1 in docs/proposals/environment-of-environments.adoc).
#
# Sends one HEAD request per host and prints the HTTP status the environment
# saw. It downloads nothing and executes nothing it fetched. The result is a
# fact about THIS environment instance on THIS date; copy it into the
# matching `measured` block of environments.kyaml rather than assuming it
# holds elsewhere.
#
# Usage:
#   tools/environments/probe-reachability.sh            # text table
#   tools/environments/probe-reachability.sh --json     # one JSON object
#   HOSTS_FILE=my-hosts.txt tools/environments/probe-reachability.sh
#
# Exit code is 0 whenever the probe ran; reachability is reported, not
# judged. Exit 2 when curl is missing or the hosts file cannot be read.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTS_FILE="${HOSTS_FILE:-$HERE/hosts.txt}"
TIMEOUT="${PROBE_TIMEOUT:-15}"
MODE="text"
if [ "${1:-}" = "--json" ]; then
    MODE="json"
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "probe-reachability: curl is not on PATH" >&2
    exit 2
fi
if [ ! -r "$HOSTS_FILE" ]; then
    echo "probe-reachability: cannot read hosts file $HOSTS_FILE" >&2
    exit 2
fi

# classify <http-code> <curl-exit> — one word per outcome.
classify() {
    local code="$1" rc="$2"
    if [ "$rc" -eq 60 ]; then
        echo "tls-failed"
    elif [ "$rc" -ne 0 ] || [ "$code" = "000" ]; then
        echo "unreachable"
    elif [ "$code" = "401" ]; then
        echo "auth-required"
    elif [ "$code" = "403" ]; then
        echo "refused"
    elif [ "${code:0:1}" = "2" ] || [ "${code:0:1}" = "3" ]; then
        echo "reachable"
    else
        echo "http-$code"
    fi
}

date_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
platform="$(uname -s)/$(uname -m)"
if command -v ldd >/dev/null 2>&1; then
    # awk reads all of ldd's output, so no SIGPIPE under pipefail.
    platform="$platform glibc $(ldd --version 2>/dev/null | awk 'NR==1{print $NF}')"
fi

if [ "$MODE" = "text" ]; then
    printf 'probe-reachability %s (%s)\n' "$date_utc" "$platform"
    printf '%-6s %-14s %s\n' "HTTP" "OUTCOME" "URL"
fi

rows=()
# `|| [ -n "$line" ]` keeps a final line that has no trailing newline.
while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    rc=0
    # -L follows redirects so a release asset is measured at its final
    # host, not at the 302 GitHub answers with; the code is the last one.
    code="$(curl -sS -I -L -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$line" 2>/dev/null)" || rc=$?
    outcome="$(classify "$code" "$rc")"
    if [ "$MODE" = "text" ]; then
        printf '%-6s %-14s %s\n' "$code" "$outcome" "$line"
    else
        rows+=("$(printf '{"url":"%s","http":"%s","outcome":"%s"}' "$line" "$code" "$outcome")")
    fi
done < "$HOSTS_FILE"

if [ "$MODE" = "json" ]; then
    joined=""
    for r in "${rows[@]}"; do
        if [ -z "$joined" ]; then joined="$r"; else joined="$joined,$r"; fi
    done
    printf '{"probe":"reachability","date":"%s","platform":"%s","hosts":[%s]}\n' \
        "$date_utc" "$platform" "$joined"
fi
