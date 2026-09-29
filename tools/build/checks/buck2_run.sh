#!/usr/bin/env bash
# buck2_run.sh -- `buck2 run` starts a built Mojo binary on this machine, and
# downloads only the binary and its runtime libraries to do it.
#
# usage: tools/build/checks/buck2_run.sh        (from the repo root; BUCK2 overrides the binary)
#
# The check snapshots the working tree into a scratch clone, so the client
# starts with an empty buck-out and a fresh daemon, then:
#   1. `buck2 run //tools/build/examples:hello` must exit 0 and print exactly the
#      greeting. (The binary runs on this machine, under a virtual-memory cap.
#      The build before it runs remotely.)
#   2. `buck2 log what-materialized` for that invocation: the bytes fetched
#      from the remote CAS must stay under MAX_DOWNLOAD_BYTES, and no fetched
#      path may be the compiler (a runtime that pulled the compiler closure in
#      would download hundreds of MB, or fail on a server's batch limit).
#   3. The runnable directory, copied to an unrelated directory, still starts:
#      its run path is relative to the binary, not to buck-out.
#
# The remote-execution settings come from `.buckconfig.local` in the repo root,
# copied into the scratch clone when present, or from the machine-wide
# buckconfig (as on the CI runner). Scratch goes under $TMPDIR (set it to a disk
# directory where /tmp is memory); the clone, its buck-out and the moved copy
# are deleted on exit, pass or fail, unless KEEP_SCRATCH=1. Logs are kept.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
if [ -z "${BUCK2:-}" ]; then
    BUCK2="$ROOT/buck2"
fi
case "$BUCK2" in /*) ;; */*) BUCK2="$PWD/$BUCK2" ;; esac
EXPECTED='hello from mojo'
MAX_DOWNLOAD_BYTES=${MAX_DOWNLOAD_BYTES:-67108864}
# buck-out on this machine after the run. The runtime lands on disk twice: the
# toolchain's runtime directory and the runnable directory's lib/ copy.
MAX_DISK_BYTES=${MAX_DISK_BYTES:-100663296}
MEM_CAP_KB=${MEM_CAP_KB:-8388608}
W=$(mktemp -d "${TMPDIR:-/tmp}/komira_run.XXXXXX")
GIT=(git -c user.name=komira-checks -c user.email=checks@example.invalid -c init.defaultBranch=main)

die() { echo "FAIL  buck2 run: $1"; echo "logs: $W"; exit 1; }
stop_daemon() { [ -d "$W/clone" ] && (cd "$W/clone" && "$BUCK2" kill > /dev/null 2>&1); }
cleanup() {
    stop_daemon
    [ "${KEEP_SCRATCH:-0}" = 1 ] || rm -rf "${W:?}/src" "${W:?}/clone" "${W:?}/moved"
}
trap cleanup EXIT


mkdir "$W/src"
(cd "$ROOT" && git ls-files -co --exclude-standard -z) |
    while IFS= read -r -d '' f; do [ -e "$ROOT/$f" ] && printf '%s\0' "$f"; done |
    (cd "$ROOT" && tar --null -T - -cf -) | tar -xf - -C "$W/src" || die "cannot snapshot the working tree"
("${GIT[@]}" -C "$W/src" init -q && "${GIT[@]}" -C "$W/src" add -A &&
    "${GIT[@]}" -C "$W/src" commit -qm snapshot) || die "cannot commit the snapshot"
"${GIT[@]}" clone -q "$W/src" "$W/clone" || die "cannot clone the snapshot"
[ ! -f "$ROOT/.buckconfig.local" ] || cp "$ROOT/.buckconfig.local" "$W/clone/"

# 1
rc=0
(cd "$W/clone" && ulimit -v "$MEM_CAP_KB" && "$BUCK2" run //tools/build/examples:hello) \
    > "$W/run.stdout" 2> "$W/run.log" || rc=$?
[ "$rc" = 0 ] || die "buck2 run exited $rc: $(grep -E 'Error' "$W/run.log" | tail -n 1 | cut -c1-240)"
printf '%s\n' "$EXPECTED" > "$W/expected"
cmp -s "$W/run.stdout" "$W/expected" ||
    die "stdout was '$(head -c 200 "$W/run.stdout")', expected '$EXPECTED'"

# 2
(cd "$W/clone" && "$BUCK2" log what-materialized) > "$W/materialized.tsv" 2> "$W/materialized.err" ||
    die "cannot read what-materialized"
# path, method, digest, file count, bytes. `cas` rows are remote downloads;
# `copy` rows are local copies of what was already fetched.
fetched=$(awk -F'\t' '$2 == "cas" { n += $5 } END { print n + 0 }' "$W/materialized.tsv")
files=$(awk -F'\t' '$2 == "cas" { n += $4 } END { print n + 0 }' "$W/materialized.tsv")
[ "$files" -gt 0 ] || die "what-materialized recorded no download; the check measured nothing"
[ "$fetched" -le "$MAX_DOWNLOAD_BYTES" ] ||
    die "downloaded $fetched bytes, over the $MAX_DOWNLOAD_BYTES budget (see $W/materialized.tsv)"
if awk -F'\t' '$2 == "cas" { print $1 }' "$W/materialized.tsv" | grep -E 'mojo_compiler|/compiler(/|$)' > "$W/compiler_paths"; then
    die "the compiler was downloaded: $(head -n 1 "$W/compiler_paths")"
fi

disk=$(du -sb "$W/clone/buck-out" 2> /dev/null | cut -f1)
[ -n "$disk" ] || die "cannot measure $W/clone/buck-out"
[ "$disk" -le "$MAX_DISK_BYTES" ] ||
    die "buck-out holds $disk bytes on disk, over the $MAX_DISK_BYTES budget"

# 3
runnable=$(awk -F'\t' '$2 == "copy" && $1 ~ /hello\.runnable$/ && $4 > 0 { print $1 }' "$W/materialized.tsv" | head -n 1)
[ -n "$runnable" ] && [ -x "$W/clone/$runnable/hello" ] || die "no runnable directory in what-materialized"
cp -R "$W/clone/$runnable" "$W/moved"
rc=0
(ulimit -v "$MEM_CAP_KB" && env -u LD_LIBRARY_PATH "$W/moved/hello") > "$W/moved.stdout" 2> "$W/moved.err" || rc=$?
[ "$rc" = 0 ] && cmp -s "$W/moved.stdout" "$W/expected" ||
    die "the runnable directory does not start after a move (rc=$rc): $(head -c 200 "$W/moved.err")"

echo "PASS  buck2 run: printed the greeting; downloaded $fetched bytes in $files files, no compiler; buck-out $disk bytes on disk; runs after a move"
