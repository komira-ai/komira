#!/usr/bin/env bash
# umbrella_cache.sh -- building komira inside a repository that mounts it as a
# git submodule reuses a standalone checkout's remote cache entries.
#
# usage: checks/umbrella_cache.sh        (from the repo root; BUCK2 overrides the binary)
#
# The check snapshots the working tree into a scratch git repository, then:
#   1. clones it (the standalone checkout) and builds the examples and their
#      run checks there, with a fresh daemon;
#   2. creates an umbrella repository whose root cell is `umbrella`, mounts the
#      snapshot at ./komira with `git submodule add`, configures it with
#      tools/umbrella_buckconfig.sh plus an execution platform of its own, and
#      builds the same targets with a fresh daemon.
# It passes only if every umbrella command is a remote cache hit
# ("Commands: N (cached: N, remote: 0, local: 0)", N > 0) and the two builds
# ran the same actions with the same action digests (`buck2 log what-ran`).
#
# Needs `.buckconfig.local` (remote-execution settings) in the repo root; it is
# copied into both scratch checkouts. Scratch goes under $TMPDIR.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [ -z "${BUCK2:-}" ]; then
    if command -v buck2 > /dev/null; then BUCK2=buck2; else BUCK2="$ROOT/tools/buck2"; fi
fi
case "$BUCK2" in /*) ;; */*) BUCK2="$PWD/$BUCK2" ;; esac
W=$(mktemp -d "${TMPDIR:-/tmp}/komira_umbrella.XXXXXX")
GIT=(git -c user.name=komira-checks -c user.email=checks@example.invalid -c init.defaultBranch=main)

die() { echo "FAIL  umbrella cache: $1"; echo "logs: $W"; exit 1; }

stop_daemons() {
    local d
    for d in "$W/standalone" "$W/umbrella"; do
        [ -d "$d" ] && (cd "$d" && "$BUCK2" kill > /dev/null 2>&1)
    done
}
trap stop_daemons EXIT

[ -f "$ROOT/.buckconfig.local" ] || die "no .buckconfig.local in $ROOT (remote-execution settings)"

# Snapshot the working tree (tracked and untracked, minus ignored files).
mkdir "$W/src"
(cd "$ROOT" && git ls-files -co --exclude-standard -z) |
    while IFS= read -r -d '' f; do [ -e "$ROOT/$f" ] && printf '%s\0' "$f"; done |
    (cd "$ROOT" && tar --null -T - -cf -) | tar -xf - -C "$W/src" || die "cannot snapshot the working tree"
("${GIT[@]}" -C "$W/src" init -q && "${GIT[@]}" -C "$W/src" add -A &&
    "${GIT[@]}" -C "$W/src" commit -qm snapshot) || die "cannot commit the snapshot"

# Standalone checkout.
"${GIT[@]}" clone -q "$W/src" "$W/standalone" || die "cannot clone the snapshot"
cp "$ROOT/.buckconfig.local" "$W/standalone/"

# Umbrella repository with komira as a submodule.
mkdir "$W/umbrella"
("${GIT[@]}" -C "$W/umbrella" init -q &&
    "${GIT[@]}" -C "$W/umbrella" -c protocol.file.allow=always submodule add -q "$W/src" komira) ||
    die "cannot add the submodule"
"$W/umbrella/komira/tools/umbrella_buckconfig.sh" komira > "$W/umbrella/.buckconfig" ||
    die "tools/umbrella_buckconfig.sh failed"
printf '\n[cells]\n  umbrella = .\n\n[build]\n  execution_platforms = umbrella//platforms:remote\n\n[project]\n  ignore = buck-out, .git\n' \
    >> "$W/umbrella/.buckconfig"
cp "$ROOT/.buckconfig.local" "$W/umbrella/"
mkdir "$W/umbrella/platforms"
cat > "$W/umbrella/platforms/BUCK" << 'EOF'
load("@komira//platforms:defs.bzl", "re_properties", "remote_execution_platforms")

remote_execution_platforms(
    name = "remote",
    names = ["linux-x86_64"],
    constraints = ["komira//platforms:linux-x86_64"],
    properties = [re_properties("linux_x86_64_properties")],
    visibility = ["PUBLIC"],
)
EOF

TARGETS=(
    komira//examples:hello komira//examples:hellopkg komira//examples:hello_pkg_user
    komira//examples/libgate_ok:libgate_ok komira//examples:test_hellopkg
)
RUN_CHECKS=("komira//examples:hello[run_check]" "komira//examples:hello_pkg_user[run_check]")

build() { # checkout, invocation number, targets...
    local d=$1 i=$2; shift 2
    (cd "$W/$d" && "$BUCK2" build "$@") > "$W/$d.build$i.log" 2>&1 ||
        die "$d: build failed (see $W/$d.build$i.log)"
    (cd "$W/$d" && "$BUCK2" log what-ran --format json) > "$W/$d.what_ran$i.json" 2>&1 ||
        die "$d: cannot read what-ran"
    grep '"digest"' "$W/$d.what_ran$i.json" |
        sed -E 's/.*"identity":"([^"]*)".*"executor":"([^"]*)".*"digest":"([^"]*)".*/\1\t\3\t\2/' \
        >> "$W/$d.actions"
}

for d in standalone umbrella; do
    : > "$W/$d.actions"
    build "$d" 1 "${TARGETS[@]}"
    build "$d" 2 "${RUN_CHECKS[@]}"
    (cd "$W/$d" && "$BUCK2" kill > /dev/null 2>&1)
done

for i in 1 2; do
    line=$(grep -o 'Commands: .*' "$W/umbrella.build$i.log" | tail -n 1)
    [[ "$line" =~ ^Commands:\ ([0-9]+)\ \(cached:\ ([0-9]+),\ remote:\ 0,\ local:\ 0\)$ ]] &&
        [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ] && [ "${BASH_REMATCH[1]}" != 0 ] ||
        die "umbrella build $i was not all remote cache hits: '${line:-no Commands line}'"
    echo "      umbrella build $i: $line"
done

cut -f1,2 "$W/standalone.actions" | LC_ALL=C sort > "$W/standalone.digests"
cut -f1,2 "$W/umbrella.actions" | LC_ALL=C sort > "$W/umbrella.digests"
n=$(wc -l < "$W/umbrella.digests" | tr -d ' ')
[ "$n" != 0 ] || die "what-ran recorded no action digests"
if ! cmp -s "$W/standalone.digests" "$W/umbrella.digests"; then
    diff "$W/standalone.digests" "$W/umbrella.digests" | head -n 8
    die "action digests differ between the standalone checkout and the umbrella"
fi
stop_daemons
echo "PASS  umbrella cache: $n actions, identical digests, every umbrella command a cache hit"
rm -rf "$W/src" "$W/standalone" "$W/umbrella"
