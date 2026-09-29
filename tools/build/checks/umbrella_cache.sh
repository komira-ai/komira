#!/usr/bin/env bash
# umbrella_cache.sh -- building komira inside a repository that mounts it as a
# git submodule reuses a standalone checkout's remote cache entries.
#
# usage: tools/build/checks/umbrella_cache.sh        (from the repo root; BUCK2 overrides the binary)
#
# The check snapshots the working tree into a scratch git repository, then:
#   1. clones it (the standalone checkout) and builds the examples and their
#      run checks there, with a fresh daemon;
#   2. creates two umbrella repositories whose root cell is `umbrella`, mounts
#      the snapshot with `git submodule add` at ./komira in one and at
#      ./third_party/komira in the other, configures each with
#      tools/build/umbrella_buckconfig.sh plus an execution platform of its own, and
#      builds the same targets in each with a fresh daemon.
# It passes only if every umbrella command is a remote cache hit
# ("Commands: N (cached: N, remote: 0, local: 0)", N > 0) and the two builds
# ran the same actions with the same action digests (`buck2 log what-ran`).
#
# Needs `.buckconfig.local` (remote-execution settings) in the repo root; it is
# copied into every scratch checkout. Scratch goes under $TMPDIR (set it to a
# disk directory where /tmp is memory); the checkouts, and their buck-out, are
# deleted on exit, pass or fail, unless KEEP_SCRATCH=1. Logs are kept.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
if [ -z "${BUCK2:-}" ]; then
    if command -v buck2 > /dev/null; then BUCK2=buck2; else BUCK2="$ROOT/tools/buck2"; fi
fi
case "$BUCK2" in /*) ;; */*) BUCK2="$PWD/$BUCK2" ;; esac
W=$(mktemp -d "${TMPDIR:-/tmp}/komira_umbrella.XXXXXX")
GIT=(git -c user.name=komira-checks -c user.email=checks@example.invalid -c init.defaultBranch=main)

die() { echo "FAIL  umbrella cache: $1"; echo "logs: $W"; exit 1; }

CHECKOUTS=(standalone umbrella umbrella_deep)

stop_daemons() {
    local d
    for d in "${CHECKOUTS[@]}"; do
        [ -d "$W/$d" ] && (cd "$W/$d" && "$BUCK2" kill > /dev/null 2>&1)
    done
}
cleanup() {
    stop_daemons
    if [ "${KEEP_SCRATCH:-0}" != 1 ]; then
        local d
        for d in src "${CHECKOUTS[@]}"; do rm -rf "${W:?}/$d"; done
    fi
}
trap cleanup EXIT

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

# Umbrella repositories with komira as a submodule, at depth 1 and depth 2.
make_umbrella() { # checkout, mount path
    local d=$1 m=$2
    mkdir "$W/$d"
    ("${GIT[@]}" -C "$W/$d" init -q &&
        "${GIT[@]}" -C "$W/$d" -c protocol.file.allow=always submodule add -q "$W/src" "$m") ||
        die "$d: cannot add the submodule at $m"
    "$W/$d/$m/tools/build/umbrella_buckconfig.sh" "$m" > "$W/$d/.buckconfig" ||
        die "$d: tools/build/umbrella_buckconfig.sh $m failed"
    printf '\n[cells]\n  umbrella = .\n\n[build]\n  execution_platforms = umbrella//platforms:remote\n\n[project]\n  ignore = buck-out, .git\n' \
        >> "$W/$d/.buckconfig"
    cp "$ROOT/.buckconfig.local" "$W/$d/"
    mkdir "$W/$d/platforms"
    cat > "$W/$d/platforms/BUCK" << 'EOF'
load("@komira//tools/build/platforms:defs.bzl", "komira_execution_platforms", "re_properties")

komira_execution_platforms(
    name = "remote",
    light = re_properties("light_properties"),
    mojo_compile = re_properties("mojo_compile_properties"),
    visibility = ["PUBLIC"],
)
EOF
}
make_umbrella umbrella komira
make_umbrella umbrella_deep third_party/komira

TARGETS=(
    komira//tools/build/examples:hello komira//tools/build/examples:hellopkg komira//tools/build/examples:hello_pkg_user
    komira//tools/build/examples/libgate_ok:libgate_ok komira//tools/build/examples:test_hellopkg
)
RUN_CHECKS=("komira//tools/build/examples:hello[run_check]" "komira//tools/build/examples:hello_pkg_user[run_check]")

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

for d in "${CHECKOUTS[@]}"; do
    : > "$W/$d.actions"
    build "$d" 1 "${TARGETS[@]}"
    build "$d" 2 "${RUN_CHECKS[@]}"
    (cd "$W/$d" && "$BUCK2" kill > /dev/null 2>&1)
done

cut -f1,2 "$W/standalone.actions" | LC_ALL=C sort > "$W/standalone.digests"
n=$(wc -l < "$W/standalone.digests" | tr -d ' ')
[ "$n" != 0 ] || die "what-ran recorded no action digests"
for d in umbrella umbrella_deep; do
    for i in 1 2; do
        line=$(grep -o 'Commands: .*' "$W/$d.build$i.log" | tail -n 1)
        [[ "$line" =~ ^Commands:\ ([0-9]+)\ \(cached:\ ([0-9]+),\ remote:\ 0,\ local:\ 0\)$ ]] &&
            [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ] && [ "${BASH_REMATCH[1]}" != 0 ] ||
            die "$d build $i was not all remote cache hits: '${line:-no Commands line}'"
        echo "      $d build $i: $line"
    done
    cut -f1,2 "$W/$d.actions" | LC_ALL=C sort > "$W/$d.digests"
    if ! cmp -s "$W/standalone.digests" "$W/$d.digests"; then
        diff "$W/standalone.digests" "$W/$d.digests" | head -n 8
        die "action digests differ between the standalone checkout and $d"
    fi
done
echo "PASS  umbrella cache: $n actions, identical digests at mount depths 1 and 2, every umbrella command a cache hit"
