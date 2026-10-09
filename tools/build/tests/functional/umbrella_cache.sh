#!/usr/bin/env bash
# umbrella_cache.sh -- a repository using komira as a cell, mounted as a git
# submodule or fetched as a git external cell, builds komira's targets with
# the same action digests as a standalone checkout, and so from its remote
# cache entries.
#
# usage: tools/build/tests/functional/umbrella_cache.sh        (from the repo root; BUCK2 overrides the binary)
#
# The check snapshots the working tree into a scratch git repository, then:
#   1. clones it (the standalone checkout) and builds the examples and their
#      run checks there, with a fresh daemon;
#   2. creates three consuming repositories, configured as
#      tools/build/consumer.buckconfig says (root cell `app`, its own
#      `toolchains` cell and execution platforms): two mount the snapshot
#      with `git submodule add`, at ./komira and at ./third_party/komira, and
#      one fetches it as a git external cell from a bare clone (file://,
#      pinned to the snapshot's commit). It builds the same targets in each,
#      with a fresh daemon.
# It passes only if every consumer command is a remote cache hit
# ("Commands: N (cached: N, remote: 0, local: 0)", N > 0) and every consumer
# ran the same actions with the same action digests as the standalone
# checkout (`buck2 log what-ran`).
#
# The consumer at ./third_party/komira uses the toolchains/BUCK frozen in
# tools/build/tests/functional/umbrella/toolchains.BUCK.frozen instead of a fresh copy,
# so a komira change that needs consumers to edit their copy fails here. In
# every checkout `buck2 targets toolchains//:` must list exactly
# tools/build/tests/functional/umbrella/toolchains_targets.txt. Before building, the
# submodule consumer at ./komira and the external consumer each plant an
# override, `komira_toolchains(mojo = {"target_cpu": "x86-64-v2"})`, and
# `buck2 aquery` of the hello example's mojo_build action must show
# `--target-cpu x86-64-v2` there and `x86-64-v3` in the standalone checkout:
# the override reaches the rules, so the rules take their toolchain from the
# consumer's own `toolchains` cell (analysis only; nothing runs). Then the
# consumer's copy is restored for the digest comparison.
#
# A fifth consumer, a git external cell like the third, has no
# `.buckconfig.local`: the remote-execution settings are appended to its root
# `.buckconfig` instead, and it runs with no user or system buckconfig
# (BUCK2_TEST_SKIP_DEFAULT_EXTERNAL_CONFIG) and HOME in the scratch directory.
# Its `app//platforms:default` must register only remote platforms, and the
# same targets must resolve to the same execution configurations as test 18
# pins; with `[komira] execution = remote`, a `[komira_re]` missing
# linux_x86_64_properties must refuse, naming the key
# (analysis only; nothing runs).
#
# The remote-execution settings come from `.buckconfig.local` in the repo root,
# copied into every scratch checkout when present, or from the machine-wide
# buckconfig (as on the CI runner), which the fifth consumer gets appended to
# its root `.buckconfig` in the same way. Scratch goes under $TMPDIR (set it to a
# disk directory where /tmp is memory); the checkouts, and their buck-out, are
# deleted on exit, pass or fail, unless KEEP_SCRATCH=1. Logs are kept.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
if [ -z "${BUCK2:-}" ]; then
    BUCK2="$ROOT/buck2"
fi
case "$BUCK2" in /*) ;; */*) BUCK2="$PWD/$BUCK2" ;; esac
W=$(mktemp -d "${TMPDIR:-/tmp}/komira_umbrella.XXXXXX")
# gc.auto=0: the snapshot commit may start a background `git gc --auto`,
# which repacks $W/src while the local clones below hardlink its objects
# ("hardlink different from source"). `-c` reaches the git commands these
# start (submodule add's clone) too.
GIT=(git -c user.name=komira-checks -c user.email=checks@example.invalid -c init.defaultBranch=main -c gc.auto=0)

die() { echo "FAIL  umbrella cache: $1"; echo "logs: $W"; exit 1; }

CHECKOUTS=(standalone umbrella umbrella_deep external)

stop_daemons() {
    local d
    for d in "${CHECKOUTS[@]}"; do
        [ -d "$W/$d" ] && (cd "$W/$d" && "$BUCK2" kill > /dev/null 2>&1)
    done
    [ -d "$W/rootcfg" ] && b2_rootcfg kill > /dev/null 2>&1
}
cleanup() {
    stop_daemons
    if [ "${KEEP_SCRATCH:-0}" != 1 ]; then
        local d
        for d in src komira.git "${CHECKOUTS[@]}" rootcfg rootcfg_home; do rm -rf "${W:?}/$d"; done
    fi
}
trap cleanup EXIT


# Snapshot the working tree (tracked and untracked, minus ignored files).
mkdir "$W/src"
(cd "$ROOT" && git ls-files -co --exclude-standard -z) |
    while IFS= read -r -d '' f; do [ -e "$ROOT/$f" ] && printf '%s\0' "$f"; done |
    (cd "$ROOT" && tar --null -T - -cf -) | tar -xf - -C "$W/src" || die "cannot snapshot the working tree"
("${GIT[@]}" -C "$W/src" init -q && "${GIT[@]}" -C "$W/src" add -A &&
    "${GIT[@]}" -C "$W/src" commit -qm snapshot) || die "cannot commit the snapshot"

# Standalone checkout.
"${GIT[@]}" clone -q "$W/src" "$W/standalone" || die "cannot clone the snapshot"
[ ! -f "$ROOT/.buckconfig.local" ] || cp "$ROOT/.buckconfig.local" "$W/standalone/"

# Repositories that use komira: two mount it with `git submodule add`, at
# depth 1 and 2, and one fetches it as a git external cell from a bare clone.
# Each is configured as tools/build/consumer.buckconfig says: that file as its
# .buckconfig, and its own toolchains/BUCK and platforms/BUCK copied from
# tools/build/cells/toolchains/BUCK and tools/build/platforms/default/BUCK.
"${GIT[@]}" clone -q --bare "$W/src" "$W/komira.git" || die "cannot make the bare clone"
SHA=$("${GIT[@]}" -C "$W/src" rev-parse HEAD)
make_consumer() { # checkout, mount path (empty: git external cell)
    local d=$1 m=$2 cfg
    mkdir "$W/$d"
    "${GIT[@]}" -C "$W/$d" init -q || die "$d: git init failed"
    cfg="$W/src/tools/build/consumer.buckconfig"
    if [ -n "$m" ]; then
        "${GIT[@]}" -C "$W/$d" -c protocol.file.allow=always submodule add -q "$W/src" "$m" ||
            die "$d: cannot add the submodule at $m"
        awk -v m="$m" '
            /^\[/ { skip = ($0 == "[external_cell_komira]") }
            skip { next }
            $0 == "  komira = git" { next }
            $0 == "  komira = komira-ext" { print "  komira = " m; next }
            { print }' "$cfg" > "$W/$d/.buckconfig"
    else
        sed -e "s|^  git_origin = .*|  git_origin = file://$W/komira.git|" \
            -e "s|^  commit_hash = .*|  commit_hash = $SHA|" "$cfg" > "$W/$d/.buckconfig"
    fi
    grep -q "^  komira = ${m:-komira-ext}\$" "$W/$d/.buckconfig" ||
        die "$d: tools/build/consumer.buckconfig no longer has the lines this check edits"
    [ ! -f "$ROOT/.buckconfig.local" ] || cp "$ROOT/.buckconfig.local" "$W/$d/"
    mkdir "$W/$d/toolchains" "$W/$d/platforms"
    if [ "$d" = umbrella_deep ]; then
        cp "$W/src/tools/build/tests/functional/umbrella/toolchains.BUCK.frozen" "$W/$d/toolchains/BUCK"
    else
        cp "$W/src/tools/build/cells/toolchains/BUCK" "$W/$d/toolchains/BUCK"
    fi
    cp "$W/src/tools/build/platforms/default/BUCK" "$W/$d/platforms/BUCK"
}
make_consumer umbrella komira
make_consumer umbrella_deep third_party/komira
make_consumer external ""
make_consumer rootcfg ""
rm -f "$W/rootcfg/.buckconfig.local"
if [ -f "$ROOT/.buckconfig.local" ]; then
    { echo; cat "$ROOT/.buckconfig.local"; } >> "$W/rootcfg/.buckconfig"
else
    # The machine-wide files buck2 reads, in its own order.
    for cfg in /etc/buckconfig /etc/buckconfig.d/* "$HOME/.buckconfig" "$HOME/.buckconfig.d"/*; do
        [ ! -f "$cfg" ] || { echo; cat "$cfg"; } >> "$W/rootcfg/.buckconfig"
    done
fi
mkdir "$W/rootcfg_home"
b2_rootcfg() { # buck2 in the rootcfg consumer, configured by its own .buckconfig alone
    (cd "$W/rootcfg" && env HOME="$W/rootcfg_home" BUCK2_TEST_SKIP_DEFAULT_EXTERNAL_CONFIG=true "$BUCK2" "$@")
}
TARGETS=(
    komira//tools/build/examples:hello komira//tools/build/examples:hellopkg komira//tools/build/examples:hello_pkg_user
    komira//tools/build/examples/libgate_ok:libgate_ok komira//tools/build/examples:test_hellopkg
    komira//tools/build/examples/cshim:cadd_user komira//tools/build/examples/snappy:test_snappy
    komira//tools/build/examples/s2n_tls:test_s2n_handshake
    komira//tools/build/examples/rust:prost_roundtrip komira//tools/build/proto-codegen:protoc-gen-mojo
)
RUN_CHECKS=("komira//tools/build/examples:hello[run_check]" "komira//tools/build/examples:hello_pkg_user[run_check]"
    "komira//tools/build/examples/cshim:cadd_user[run_check]")

# Analysis only. Outside the tests cell the coverage attributes are the
# rules' own (tools/build/mojo/coverage.bzl; test 46): in the consumer's
# cell, a BUCK file passing them to mojo_library is refused when it loads
# (even the policy's mode with komira's directories), and one calling
# mojo_library_rule itself is refused in analysis for a mode other than the
# policy's, a gate or branch coverage directory other than komira's,
# coverage runs with no gate for a library not in the ledger
# COVERAGE_NO_GATE, and a gate reading branch records for a library not in
# COVERAGE_BRANCH_GATE (`coverage_branch_gate`, which a BUCK file passing it
# to mojo_library is refused for too). A library the rule is given
# `coverage_tests` (its gate is then `<name>_cov_gate`) passes the rule's
# checks, and a conda package of it that waits for no such gate is refused.
CR="$W/umbrella/covrefuse"
mkdir -p "$CR/macro/lib" "$CR/macro_branch/lib" "$CR/rule/lib"
printf 'def one() -> Int:\n    return 1\n' > "$CR/macro/lib/__init__.mojo"
cp "$CR/macro/lib/__init__.mojo" "$CR/rule/lib/__init__.mojo"
cp "$CR/macro/lib/__init__.mojo" "$CR/macro_branch/lib/__init__.mojo"
cat > "$CR/macro_branch/BUCK" <<'BUCKEOF'
load("@komira//tools/build/mojo:defs.bzl", "mojo_library")

mojo_library(
    name = "lib",
    srcs = ["lib/__init__.mojo"],
    conda = False,
    coverage_branch_gate = True,
)
BUCKEOF
cp "$W/src/tools/build/coverage/ratchet.tsv" "$CR/rule/ratchet.tsv"
cat > "$CR/macro/BUCK" <<'BUCKEOF'
load("@komira//tools/build/coverage:policy.bzl", "COVERAGE_MODE")
load("@komira//tools/build/mojo:defs.bzl", "mojo_library")

mojo_library(
    name = "lib",
    srcs = ["lib/__init__.mojo"],
    conda = False,
    coverage_debug = "komira//tools/build/coverage/kcov:cov_link",
    coverage_gate = "komira//tools/build/coverage:cov_gate",
    coverage_mode = COVERAGE_MODE,
)
BUCKEOF
cat > "$CR/rule/BUCK" <<'BUCKEOF'
load("@komira//tools/build/coverage:defs.bzl", "cov_gate_dir")
load("@komira//tools/build/coverage/branch:defs.bzl", "cov_branch_dir")
load("@komira//tools/build/coverage:policy.bzl", "COVERAGE_MODE")
load("@komira//tools/build/mojo:defs.bzl", "mojo_library_rule")
load("@komira//tools/build/package:conda.bzl", "conda_package")

_GATE = "komira//tools/build/coverage:cov_gate"

cov_gate_dir(
    name = "lenient",
    ratchet = "ratchet.tsv",
)

cov_branch_dir(
    name = "mybranch",
)

[
    mojo_library_rule(
        name = name,
        srcs = ["lib/__init__.mojo"],
        conda = False,
        coverage_debug = "komira//tools/build/coverage/kcov:cov_link",
        coverage_run = "komira//tools/build/coverage/kcov:cov_run",
        import_name = "lib",
        **kw
    )
    for name, kw in {
        "mode": {"coverage_gate": _GATE, "coverage_mode": "neutral" if COVERAGE_MODE != "neutral" else "census"},
        "gate": {"coverage_gate": ":lenient", "coverage_mode": COVERAGE_MODE},
        "branch": {"coverage_branch": ":mybranch", "coverage_gate": _GATE, "coverage_mode": COVERAGE_MODE},
        "branch_gate": {"coverage_branch_gate": True, "coverage_gate": _GATE, "coverage_mode": COVERAGE_MODE},
        "runs": {},
    }.items()
]

mojo_library_rule(
    name = "named",
    srcs = ["lib/__init__.mojo"],
    coverage_debug = "komira//tools/build/coverage/kcov:cov_link",
    coverage_run = "komira//tools/build/coverage/kcov:cov_run",
    coverage_tests = [":no_such_test"],
    import_name = "lib",
)

conda_package(
    name = "named_conda",
    lib = ":named",
    summary = "a conda package waiting for no coverage gate",
)
BUCKEOF
# Each expected text is the formatted message (it names the target), not the
# fail() line of the .bzl file that buck2 also prints. The mode fixture asks
# for neutral, or census when the policy's mode is neutral.
pol=$(sed -n 's/^COVERAGE_MODE = "\(.*\)"$/\1/p' "$W/src/tools/build/coverage/policy.bzl")
other=neutral
[ "$pol" != neutral ] || other=census
for c in "macro|uquery|app//covrefuse/macro:lib|fail: lib: \`coverage_debug\`, \`coverage_run\`, \`coverage_gate\` and \`coverage_mode\` are set by mojo_library" \
    "mode|audit providers|app//covrefuse/rule:mode|app//covrefuse/rule:mode: coverage_mode is $other, but the policy's is $pol" \
    "gate|audit providers|app//covrefuse/rule:gate|app//covrefuse/rule:gate: coverage_gate is app//covrefuse/rule:lenient, not komira//tools/build/coverage:cov_gate" \
    "macro_branch|uquery|app//covrefuse/macro_branch:lib|fail: lib: \`coverage_branch_gate\` is set by mojo_library from COVERAGE_BRANCH_GATE" \
    "branch|audit providers|app//covrefuse/rule:branch|app//covrefuse/rule:branch: coverage_branch is app//covrefuse/rule:mybranch, not komira//tools/build/coverage/branch:cov_branch" \
    "branch_gate|audit providers|app//covrefuse/rule:branch_gate|app//covrefuse/rule:branch_gate: coverage_branch_gate is True, but the library is not in COVERAGE_BRANCH_GATE" \
    "runs|audit providers|app//covrefuse/rule:runs|app//covrefuse/rule:runs: coverage builds with no coverage_gate: its conda package would wait for no coverage gate" \
    "named|audit providers|app//covrefuse/rule:named_conda|app//covrefuse/rule:named_conda: the coverage gate of app//covrefuse/rule:named is its target"; do
    IFS='|' read -r n cmd t want <<< "$c"
    # shellcheck disable=SC2086 # `audit providers` is two words
    if (cd "$W/umbrella" && "$BUCK2" $cmd "$t") > "$W/umbrella.covrefuse_$n.log" 2>&1; then
        die "umbrella: the consumer's $t, which sets coverage attributes, was accepted (see $W/umbrella.covrefuse_$n.log)"
    fi
    grep -qF -- "$want" "$W/umbrella.covrefuse_$n.log" ||
        die "umbrella: $t was refused without '$want' (see $W/umbrella.covrefuse_$n.log)"
done
(cd "$W/umbrella" && "$BUCK2" kill > /dev/null 2>&1)
echo "      coverage attributes: refused in the consumer's cell, passed to mojo_library (any of them, coverage_branch_gate alone included) or to the rule (another mode, another gate, another branch coverage directory, branch records read off COVERAGE_BRANCH_GATE, runs without a gate, a conda package of a library naming coverage_tests that waits for no gate)"

# Analysis only. The toolchains cell of every checkout declares the expected
# targets; a planted override in a consumer's toolchains cell reaches hello's
# compile command.
aquery_cpu() { # checkout, log name -> the --target-cpu value of hello's mojo_build
    (cd "$W/$1" && "$BUCK2" aquery 'attrfilter(category, mojo_build, komira//tools/build/examples:hello)' \
        --output-attribute cmd) > "$W/$1.$2.json" 2>&1 || { echo "aquery failed: $W/$1.$2.json"; return; }
    grep -o -- '--target-cpu, [^,]*,' "$W/$1.$2.json" | sed -e 's/^--target-cpu, //' -e 's/,$//' | LC_ALL=C sort -u | tr '\n' ' '
}
EXPECTED_TOOLCHAINS="$W/src/tools/build/tests/functional/umbrella/toolchains_targets.txt"
for d in "${CHECKOUTS[@]}"; do
    (cd "$W/$d" && "$BUCK2" targets toolchains//:) > "$W/$d.toolchains" 2> "$W/$d.toolchains.err" ||
        die "$d: buck2 targets toolchains//: failed (see $W/$d.toolchains.err)"
    if ! LC_ALL=C sort "$W/$d.toolchains" | cmp -s - "$EXPECTED_TOOLCHAINS"; then
        LC_ALL=C sort "$W/$d.toolchains" | diff "$EXPECTED_TOOLCHAINS" - | head -n 8
        die "$d: the toolchains cell does not declare tools/build/tests/functional/umbrella/toolchains_targets.txt"
    fi
done
cpu=$(aquery_cpu standalone aquery)
[ "$cpu" = "x86-64-v3 " ] || die "standalone: hello's mojo_build has --target-cpu '${cpu}', expected x86-64-v3"
(cd "$W/standalone" && "$BUCK2" kill > /dev/null 2>&1)
for d in umbrella external; do
    cp "$W/$d/toolchains/BUCK" "$W/$d.toolchains.BUCK"
    sed -i 's/^komira_toolchains()$/komira_toolchains(mojo = {"target_cpu": "x86-64-v2"})/' "$W/$d/toolchains/BUCK"
    grep -q 'x86-64-v2' "$W/$d/toolchains/BUCK" || die "$d: cannot plant the override (no komira_toolchains() line)"
    cpu=$(aquery_cpu "$d" aquery_override)
    [ "$cpu" = "x86-64-v2 " ] ||
        die "$d: an override in its toolchains cell did not reach hello's mojo_build (--target-cpu '${cpu}', expected x86-64-v2)"
    cp "$W/$d.toolchains.BUCK" "$W/$d/toolchains/BUCK"
    (cd "$W/$d" && "$BUCK2" kill > /dev/null 2>&1)
done
echo "      toolchains cell: the expected targets in every checkout; a consumer override reaches the compile command (submodule and external cell)"

# Analysis only. Remote-execution settings in a consumer's root .buckconfig
# select the remote platforms, with the configurations test 18 pins.
EP=app//platforms:default
b2_rootcfg audit providers "$EP" > "$W/rootcfg.providers.txt" 2>&1 ||
    die "rootcfg: cannot read the providers of $EP (see $W/rootcfg.providers.txt)"
n_platforms=$(grep -c 'executor_config=' "$W/rootcfg.providers.txt")
n_local=$(grep -c 'executor: Local(' "$W/rootcfg.providers.txt")
labels=$(grep -oE '^ +label=komira//tools/build/platforms:[a-z0-9_-]+' "$W/rootcfg.providers.txt" | sed 's/.*://' | tr '\n' ' ')
[ "$n_platforms" -gt 0 ] && [ "$n_local" = 0 ] ||
    die "rootcfg: $EP registers $n_platforms platforms, $n_local of them local-only; want >0 and 0 (see $W/rootcfg.providers.txt)"
case " $labels" in *" linux-x86_64 "*) ;;
    *) die "rootcfg: registered platforms are [$labels], want linux-x86_64 among them (see $W/rootcfg.providers.txt)" ;; esac
EXPECT_RESOLUTION="
komira//tools/build/examples:hello komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be
komira//tools/build/examples:hellopkg komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be
komira//tools/build/examples:test_hellopkg komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be
toolchains//:mojo komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be
komira//tools/build/toolchains:zig komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be
komira//tools/build/toolchains:conda_unpack komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be"
want=$(printf '%s\n' "$EXPECT_RESOLUTION" | sed '/^$/d' | LC_ALL=C sort)
mapfile -t targets < <(printf '%s\n' "$want" | cut -d' ' -f1)
b2_rootcfg audit execution-platform-resolution "${targets[@]}" > "$W/rootcfg.resolution.txt" 2>&1 ||
    die "rootcfg: execution-platform-resolution failed (see $W/rootcfg.resolution.txt)"
got=$(awk '/^[^ ].* \(.*\):$/ { t = $1; next }
    t != "" && /^    Execution platform configuration: / { print t, $4; t = "" }' "$W/rootcfg.resolution.txt" | LC_ALL=C sort)
[ "$got" = "$want" ] ||
    die "rootcfg: resolution differs: $(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | grep '^[<>]' | tr '\n' ' ') (see $W/rootcfg.resolution.txt)"
key=linux_x86_64_properties
if b2_rootcfg audit providers -c komira.execution=remote -c "komira_re.$key=" "$EP" > "$W/rootcfg.no_$key.txt" 2>&1; then
    die "rootcfg: [komira] execution = remote without [komira_re] $key registered platforms (see $W/rootcfg.no_$key.txt)"
elif ! grep -qF "\`[komira_re] $key\` is not set" "$W/rootcfg.no_$key.txt"; then
    die "rootcfg: [komira] execution = remote without [komira_re] $key failed without naming it (see $W/rootcfg.no_$key.txt)"
fi
b2_rootcfg kill > /dev/null 2>&1
echo "      root .buckconfig: a consumer with the remote settings in its root .buckconfig registers $n_platforms remote platforms, resolves $(printf '%s\n' "$want" | wc -l) targets to the pinned configurations, and refuses execution = remote without linux_x86_64_properties"

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

# The external consumer built from buck2's own fetch of the pinned commit.
[ -d "$W/external/buck-out/v2/external_cells/git/$SHA" ] ||
    die "external: buck2 fetched no external cell at $SHA"
cut -f1,2 "$W/standalone.actions" | LC_ALL=C sort > "$W/standalone.digests"
n=$(wc -l < "$W/standalone.digests" | tr -d ' ')
[ "$n" != 0 ] || die "what-ran recorded no action digests"
for d in umbrella umbrella_deep external; do
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
# A package in the consumer's own cell depends on a komira package. buck2 keys a
# .bzl module by the cell of the BUCK file that loads it, so the rules load once
# for `app` and once for `komira`, and the two loads must still agree on what a
# package closure is. The same check, a library, its gated test, and a binary
# on the library, in the consumer that mounts komira at ./komira (the layout of
# a repository whose root cell contains the komira directory) and in the one that
# fetches it as an external cell. The binary's compile must put both packages on -I.
for d in umbrella external; do
    mkdir -p "$W/$d/cross/crosspkg" "$W/$d/cross/tests"
    cat > "$W/$d/cross/BUCK" <<'BUCKEOF'
load("@komira//tools/build/mojo:defs.bzl", "mojo_binary", "mojo_library")

mojo_library(
    name = "crosspkg",
    srcs = ["crosspkg/__init__.mojo"],
    test_srcs = ["tests/test_crosspkg.mojo"],
    deps = ["komira//tools/build/examples:hellopkg"],
    visibility = ["PUBLIC"],
)

mojo_binary(
    name = "cross_user",
    srcs = ["cross_user.mojo"],
    deps = [":crosspkg"],
    expected_stdout = "hello from hellopkg, via crosspkg\n",
)
BUCKEOF
    cat > "$W/$d/cross/crosspkg/__init__.mojo" <<'MOEOF'
from hellopkg import greeting


def shout() -> String:
    return greeting() + String(", via crosspkg")
MOEOF
    cat > "$W/$d/cross/tests/test_crosspkg.mojo" <<'MOEOF'
from crosspkg import shout
from std.testing import assert_equal


def main() raises:
    assert_equal(shout(), "hello from hellopkg, via crosspkg", "a package built on one from another cell")
    print("test_crosspkg: PASS")
MOEOF
    cat > "$W/$d/cross/cross_user.mojo" <<'MOEOF'
from crosspkg import shout


def main():
    print(shout())
MOEOF
    build "$d" 3 app//cross:crosspkg app//cross:cross_user "app//cross:cross_user[run_check]"
    (cd "$W/$d" && "$BUCK2" aquery 'attrfilter(category, mojo_build, app//cross:cross_user)' --output-attribute cmd) \
        > "$W/$d.cross.json" 2>&1 || die "$d: aquery of app//cross:cross_user failed (see $W/$d.cross.json)"
    for pkg in crosspkg hellopkg; do
        grep -q -- "-I[^,]*/__${pkg}__/" "$W/$d.cross.json" ||
            die "$d: app//cross:cross_user's compile does not put $pkg on -I (see $W/$d.cross.json)"
    done
    (cd "$W/$d" && "$BUCK2" kill > /dev/null 2>&1)
done
echo "      cross cell: a library, its gated test and a binary in the consumer's own cell build on a komira package (submodule and external cell)"

echo "PASS  umbrella cache: $n actions, identical digests as a submodule at depths 1 and 2 (one with a frozen toolchains copy) and as a git external cell, every consumer command a cache hit; consumer toolchain overrides take effect"
