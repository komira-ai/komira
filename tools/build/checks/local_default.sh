#!/usr/bin/env bash
# local_default.sh -- a fresh clone with no `.buckconfig.local` builds on this
# machine: local execution is the default, remote execution is opt-in.
#
# usage: tools/build/checks/local_default.sh        (from the repo root; BUCK2 overrides the binary)
#
# The check snapshots the working tree (tracked and untracked, not ignored:
# `.buckconfig.local` is gitignored and never copied) into a scratch clone and
# runs buck2 there with its own daemon, no user or system buckconfig
# (BUCK2_TEST_SKIP_DEFAULT_EXTERNAL_CONFIG) and HOME in the scratch directory,
# so nothing on this machine can configure a remote service. Steps 1-4 only
# resolve configuration and build nothing; step 5 builds toolchain targets on
# this machine. On a Linux x86_64 host:
#   1. `[build] execution_platforms` is komira//tools/build/platforms/default:default,
#      and every platform it registers has a local executor and no remote one:
#      exactly exec-mojo and exec-light, in that order.
#   2. Mojo targets (a binary, a library, a test, the Mojo toolchain) resolve
#      to exec-mojo and toolchain unpack/copy targets to exec-light, with the
#      configuration hashes that run_checks.sh check 18 pins: local and
#      remote builds configure every target identically.
#   3. A target requiring numa_multi fails to configure: a local host is
#      never assumed to span NUMA nodes.
#   4. `-c komira.execution=remote` refuses, naming `[komira_re]`; a
#      `[buck2_re_client]` address, engine_address, cas_address or
#      action_cache_address with no `[komira_re]`
#      refuses (fail closed: a misspelled or missing `[komira_re]` must not
#      build here), naming both ways out; a `[komira_re]` missing
#      light_properties refuses, naming it; `-c komira.execution=local` still
#      builds here with a service named; `[komira] execution = remote` in a
#      user ~/.buckconfig.local refuses; and an unknown `komira.execution`
#      refuses, naming the modes.
#   5. Toolchain actions run locally, concurrently, with an empty host PATH:
#      zig unpacked, then two zig programs (conda_unpack, zig_cc_launcher)
#      built at once (about 45 MB downloaded; no Mojo compile). Local actions
#      share the checkout root as their working directory, so this fails if
#      they share scratch space.
# On any other host, (1) is replaced by the refusal that names the host and
# `.buckconfig.local`.
#
# Only (5) executes anything, and only on Linux x86_64.
#
# Scratch goes under $TMPDIR (a disk directory where /tmp is memory); it is
# deleted on exit, pass or fail, unless KEEP_SCRATCH=1. Needs git and python3.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
if [ -z "${BUCK2:-}" ]; then
    BUCK2="$ROOT/buck2"
fi
case "$BUCK2" in /*) ;; */*) BUCK2="$PWD/$BUCK2" ;; *) BUCK2=$(command -v "$BUCK2") ;; esac
W=$(mktemp -d "${TMPDIR:-/tmp}/komira_local.XXXXXX")
GIT=(git -c user.name=komira-checks -c user.email=checks@example.invalid -c init.defaultBranch=main)
C="$W/clone"

b2() { # buck2 in the clone, configured by the clone alone
    (cd "$C" && env HOME="$W/home" BUCK2_TEST_SKIP_DEFAULT_EXTERNAL_CONFIG=true "$BUCK2" "$@")
}
die() { echo "FAIL  local default: $1"; echo "logs: $W"; exit 1; }
cleanup() {
    [ -d "$C" ] && b2 kill > /dev/null 2>&1
    [ "${KEEP_SCRATCH:-0}" = 1 ] || rm -rf "${W:?}/src" "${W:?}/clone" "${W:?}/home"
}
trap cleanup EXIT

mkdir "$W/src" "$W/home"
(cd "$ROOT" && git ls-files -co --exclude-standard -z) |
    while IFS= read -r -d '' f; do [ -e "$ROOT/$f" ] && printf '%s\0' "$f"; done |
    (cd "$ROOT" && tar --null -T - -cf -) | tar -xf - -C "$W/src" || die "cannot snapshot the working tree"
("${GIT[@]}" -C "$W/src" init -q && "${GIT[@]}" -C "$W/src" add -A &&
    "${GIT[@]}" -C "$W/src" commit -qm snapshot) || die "cannot commit the snapshot"
"${GIT[@]}" clone -q "$W/src" "$C" || die "cannot clone the snapshot"
[ ! -e "$C/.buckconfig.local" ] || die "the fresh clone has a .buckconfig.local; .gitignore no longer covers it"

EP=komira//tools/build/platforms/default:default
got_ep=$(b2 audit config build.execution_platforms --style json 2> "$W/ep.err" |
    python3 -c 'import json, sys; print(list(json.load(sys.stdin).values())[0])' 2>> "$W/ep.err")
[ "$got_ep" = "$EP" ] || die "[build] execution_platforms is '$got_ep', not $EP (see $W/ep.err)"

if [ "$(uname -s)/$(uname -m)" != Linux/x86_64 ]; then
    if b2 audit providers "$EP" > "$W/providers.txt" 2>&1; then
        die "on $(uname -s)/$(uname -m), $EP registered platforms instead of refusing (see $W/providers.txt)"
    elif ! grep -qF 'which is not Linux x86_64' "$W/providers.txt" || ! grep -qF '.buckconfig.local' "$W/providers.txt"; then
        die "on $(uname -s)/$(uname -m), $EP failed without naming the host and .buckconfig.local (see $W/providers.txt)"
    fi
    echo "PASS  local default: on $(uname -s)/$(uname -m) a fresh clone refuses local execution and points to .buckconfig.local"
    exit 0
fi

# 1
b2 audit providers "$EP" > "$W/providers.txt" 2>&1 || die "cannot read the providers of $EP (see $W/providers.txt)"
n_platforms=$(grep -c 'executor_config=' "$W/providers.txt")
n_local=$(grep -c 'executor: Local(' "$W/providers.txt")
labels=$(grep -oE '^ +label=komira//tools/build/platforms:exec-[a-z0-9-]+' "$W/providers.txt" | sed 's/.*://' | tr '\n' ' ')
[ "$n_platforms" = 2 ] && [ "$n_local" = 2 ] ||
    die "$EP registers $n_platforms platforms, $n_local of them local-only; want 2 and 2 (see $W/providers.txt)"
[ "$labels" = "exec-mojo exec-light " ] || die "registered platforms are [$labels], want [exec-mojo exec-light] in that order"
! grep -qiE 'remote_execution_properties|executor: Remote|RemoteEnabled|Hybrid' "$W/providers.txt" ||
    die "a registered platform names a remote executor or properties (see $W/providers.txt)"

# 2, 3
EXPECT="
komira//tools/build/examples:hello komira//tools/build/platforms:exec-mojo#a37dd214722ae04e
komira//tools/build/examples:hellopkg komira//tools/build/platforms:exec-mojo#a37dd214722ae04e
komira//tools/build/examples:test_hellopkg komira//tools/build/platforms:exec-mojo#a37dd214722ae04e
toolchains//:mojo komira//tools/build/platforms:exec-mojo#a37dd214722ae04e
komira//tools/build/toolchains:zig komira//tools/build/platforms:exec-light#6dbe0803a8efd9e4
komira//tools/build/toolchains:conda_unpack komira//tools/build/platforms:exec-light#6dbe0803a8efd9e4
komira//tools/build/toolchains:mojo_compiler komira//tools/build/platforms:exec-light#6dbe0803a8efd9e4
komira//tools/build/toolchains:mojo_runtime komira//tools/build/platforms:exec-light#6dbe0803a8efd9e4
checks//numa:hello_multi_numa FAILED"
want=$(printf '%s\n' "$EXPECT" | sed '/^$/d' | LC_ALL=C sort)
mapfile -t targets < <(printf '%s\n' "$want" | cut -d' ' -f1)
b2 audit execution-platform-resolution "${targets[@]}" > "$W/resolution.txt" 2>&1 ||
    die "execution-platform-resolution failed (see $W/resolution.txt)"
got=$(awk '/^[^ ].* \(.*\):$/ { t = $1; next }
    t != "" && /^    Execution platform configuration: / { print t, $4; t = "" }
    t != "" && /^  Failed to configure/ { print t, "FAILED"; t = "" }' "$W/resolution.txt" | LC_ALL=C sort)
[ "$got" = "$want" ] ||
    die "resolution differs: $(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | grep '^[<>]' | tr '\n' ' ') (see $W/resolution.txt)"
grep -qF 'exec_compatible_with requires `komira//tools/build/platforms:numa_multi` but it was not satisfied' "$W/resolution.txt" ||
    die "the multi-NUMA refusal does not name numa_multi (see $W/resolution.txt)"
grep -q "linux-x86_64#03cc1a891c89e4be" "$W/resolution.txt" ||
    die "the target configuration is not linux-x86_64#03cc1a891c89e4be (see $W/resolution.txt)"

# 4
if b2 audit providers -c komira.execution=remote "$EP" > "$W/forced_remote.txt" 2>&1; then
    die "-c komira.execution=remote registered platforms with no [komira_re] (see $W/forced_remote.txt)"
elif ! grep -qF '`[komira_re] light_properties` is not set' "$W/forced_remote.txt"; then
    die "-c komira.execution=remote failed without naming [komira_re] (see $W/forced_remote.txt)"
fi
# A service named without worker property sets, or a partly filled-in
# [komira_re], refuses instead of building here; `-c komira.execution=local`
# still builds here.
RE_ADDR=grpc://re.example.invalid:8980
for key in address engine_address cas_address action_cache_address; do
    if b2 audit providers -c "buck2_re_client.$key=$RE_ADDR" "$EP" > "$W/re_client_$key.txt" 2>&1; then
        die "[buck2_re_client] $key with no [komira_re] registered platforms instead of refusing (see $W/re_client_$key.txt)"
    elif ! grep -qF "\`[buck2_re_client] $key\` names a remote-execution service" "$W/re_client_$key.txt" ||
        ! grep -qF 'komira.execution=local' "$W/re_client_$key.txt"; then
        die "[buck2_re_client] $key with no [komira_re] failed without naming both ways out (see $W/re_client_$key.txt)"
    fi
done
if b2 audit providers -c komira_re.mojo_compile_properties=pool=mojo "$EP" > "$W/partial_re.txt" 2>&1; then
    die "a [komira_re] without light_properties registered platforms (see $W/partial_re.txt)"
elif ! grep -qF '`[komira_re] light_properties` is not set' "$W/partial_re.txt"; then
    die "a [komira_re] without light_properties failed without naming it (see $W/partial_re.txt)"
fi
b2 audit providers -c "buck2_re_client.engine_address=$RE_ADDR" -c komira.execution=local "$EP" > "$W/forced_local.txt" 2>&1 ||
    die "-c komira.execution=local with a service named did not register platforms (see $W/forced_local.txt)"
[ "$(grep -c 'executor: Local(' "$W/forced_local.txt")" = 2 ] ||
    die "-c komira.execution=local with a service named did not register the two local platforms (see $W/forced_local.txt)"
# `[komira] execution = remote` in a user buckconfig makes a checkout with no
# .buckconfig.local refuse: how a machine that must never build locally says
# so (DEVELOPMENT.md, step 3). Its own daemon, reading the user config.
mkdir -p "$W/home_user"
printf '[komira]\n  execution = remote\n' > "$W/home_user/.buckconfig.local"
if (cd "$C" && env HOME="$W/home_user" "$BUCK2" --isolation-dir user_cfg audit providers "$EP") > "$W/user_cfg.txt" 2>&1; then
    die "[komira] execution = remote in ~/.buckconfig.local registered platforms instead of refusing (see $W/user_cfg.txt)"
elif ! grep -qF '`[komira_re] light_properties` is not set' "$W/user_cfg.txt"; then
    die "[komira] execution = remote in ~/.buckconfig.local failed without naming [komira_re] (see $W/user_cfg.txt)"
fi
(cd "$C" && env HOME="$W/home_user" "$BUCK2" --isolation-dir user_cfg kill) > /dev/null 2>&1
if b2 audit providers -c komira.execution=farm "$EP" > "$W/bad_mode.txt" 2>&1; then
    die "-c komira.execution=farm was accepted (see $W/bad_mode.txt)"
elif ! grep -qF '`[komira] execution`: expected one of' "$W/bad_mode.txt"; then
    die "-c komira.execution=farm failed without naming the modes (see $W/bad_mode.txt)"
fi

# 5
# The daemon takes its environment from the client that starts it, and local
# actions inherit it: start it with nothing but HOME.
b2 kill > /dev/null 2>&1
if ! (cd "$C" && env -i HOME="$W/home" BUCK2_TEST_SKIP_DEFAULT_EXTERNAL_CONFIG=true PATH=/nonexistent \
        "$BUCK2" build komira//tools/build/toolchains:conda_unpack komira//tools/build/toolchains:zig_cc_launcher) > "$W/local_build.log" 2>&1; then
    die "the local toolchain build failed with an empty PATH (see $W/local_build.log)"
fi
b2 log what-ran --format json > "$W/local_what_ran.json" 2>&1 || die "cannot read what-ran of the local build"
ran=$(python3 - "$W/local_what_ran.json" << 'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.startswith("{")]
execs = [r.get("reproducer", {}).get("executor", "") for r in rows]
builds = sum(1 for r in rows if r.get("identity", "").endswith("(zig_build_exe)"))
if not rows or any(e.lower() != "local" for e in execs):
    print("executors %s, want only local" % sorted(set(execs)))
elif builds < 2:
    print("%d zig_build_exe actions ran, want 2" % builds)
else:
    print(len(rows))
PY
)
case "$ran" in '' | *[!0-9]*) die "local build: ${ran:-cannot read $W/local_what_ran.json}" ;; esac

echo "PASS  local default: a fresh clone registers only local platforms (exec-mojo, exec-light); $(printf '%s\n' "$want" | grep -c '#') targets resolve to them with the pinned configuration hashes, numa_multi does not configure, forcing remote names [komira_re], a service named without [komira_re] refuses; $ran toolchain actions ran locally, concurrently, with an empty PATH"
