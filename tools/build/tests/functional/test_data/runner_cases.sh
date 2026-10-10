# runner_cases.sh -- runs tools/build/mojo/gate_runner.sh against a stand-in
# test in ONE action directory and requires each verdict. Writes one line per
# case to <report> ("ok <case>" or "BAD <case>: <why>"); exits 1 if any case is
# BAD.
#
# usage: busybox sh runner_cases.sh <busybox> <gate_runner.sh> <report> <dyld_prelude.sh>
#
# Two gated tests in two actions cannot show that their TEST_TMPDIRs differ:
# on remote execution each runs in its own action directory and is then
# cached, so a runner that used one fixed directory for every run would pass
# them. Here both runs share one action directory, one after the other.
#
# The darwin case runs the runner as the macOS toolchain builds it
# (dyld_prelude.sh, then gate_runner.sh) with a stand-in busybox that drops
# every DYLD_* variable before each applet, as dyld does for the protected
# /bin and /usr/bin binaries the macOS busybox (busybox.sh) runs. The
# test must still see DYLD_LIBRARY_PATH: nothing between the runner and the
# test may be an applet.
set -eu
case "$1" in /*) BB=$1 ;; *) BB=$PWD/$1 ;; esac
case "$2" in /*) RUNNER=$2 ;; *) RUNNER=$PWD/$2 ;; esac
REPORT=$3
case "$4" in /*) PRELUDE=$4 ;; *) PRELUDE=$PWD/$4 ;; esac
D=$PWD/.komira_runner_cases
"$BB" rm -rf "$D"
"$BB" mkdir -p "$D/root/bin"
# The stand-in test; PROBE_MODE (given through --env) picks its behaviour.
cat > "$D/root/bin/probe" <<PROBE
#!$BB sh
case "\${PROBE_MODE:-}" in
    red) exit 1 ;;
    killed) kill -KILL \$\$ ;;
    aborted) kill -ABRT \$\$ ;;
    tmp)
        [ -n "\${TEST_TMPDIR:-}" ] || { echo "probe: TEST_TMPDIR unset"; exit 11; }
        [ -d "\$TEST_TMPDIR" ] || { echo "probe: \$TEST_TMPDIR is not a directory"; exit 12; }
        [ -z "\$(ls -A "\$TEST_TMPDIR")" ] || { echo "probe: \$TEST_TMPDIR is not empty"; exit 13; }
        [ "\${TMPDIR:-}" = "\$TEST_TMPDIR" ] || { echo "probe: TMPDIR != TEST_TMPDIR"; exit 14; }
        echo "\$TEST_TMPDIR" >> "\$PROBE_LOG"
        : > "\$TEST_TMPDIR/left_by_probe"
        exit 0 ;;
    other) exit 0 ;;
    seen)
        [ "\${SEEN_VAR:-}" = "a=b c" ] || { echo "probe: SEEN_VAR='\${SEEN_VAR:-}'"; exit 16; }
        [ -n "\${LD_LIBRARY_PATH:-}" ] || { echo "probe: LD_LIBRARY_PATH unset"; exit 17; }
        exit 0 ;;
    args)
        [ "\$#" = 3 ] || { echo "probe: \$# arguments"; exit 18; }
        [ "\$1" = "--pair=\$EXPECT_DIR/a,\$EXPECT_DIR/b" ] || { echo "probe: first argument '\$1'"; exit 19; }
        [ "\$2" = "two words" ] || { echo "probe: second argument '\$2'"; exit 20; }
        [ "\$3" = "SEEN_ARG=1" ] || { echo "probe: third argument '\$3'"; exit 21; }
        [ -z "\${SEEN_ARG:-}" ] || { echo "probe: an argument was exported"; exit 22; }
        exit 0 ;;
    loader)
        [ "\${DYLD_LIBRARY_PATH-}" = "\$EXPECT_LIB" ] || { echo "probe: DYLD_LIBRARY_PATH='\${DYLD_LIBRARY_PATH-}', not '\$EXPECT_LIB'"; exit 23; }
        [ "\${LD_LIBRARY_PATH-}" = "\$EXPECT_LIB" ] || { echo "probe: LD_LIBRARY_PATH='\${LD_LIBRARY_PATH-}', not '\$EXPECT_LIB'"; exit 24; }
        exit 0 ;;
    skip) exit 77 ;;
    *) echo "probe: PROBE_MODE='\${PROBE_MODE:-}'"; exit 15 ;;
esac
PROBE
"$BB" chmod +x "$D/root/bin/probe"
: > "$REPORT"
bad=0

ok() { echo "ok $1" >> "$REPORT"; }
bad() { echo "BAD $1: $2" | "$BB" tee -a "$REPORT" >&2; bad=1; }

# run <case> <marker> <runner options...>: runs the runner ($RUN_SCRIPT, given
# $RUN_BB as its busybox) from this action's directory; sets rc and leaves its
# output in $D/<case>.log.
RUN_SCRIPT=$RUNNER
RUN_BB=$BB
run() {
    name=$1 marker=$2
    shift 2
    rc=0
    "$BB" rm -f "$marker"
    "$BB" timeout 60 "$BB" sh "$RUN_SCRIPT" "$RUN_BB" "$D/tc" "//x:$name" "$D/root/bin/probe" "$marker" "$@" > "$D/$name.log" 2>&1 || rc=$?
}

# TEST_TMPDIR: two runs, one action directory.
LOGF=$D/tmpdirs
: > "$LOGF"
run tmp1 "$D/m1" --env PROBE_MODE=tmp --env "PROBE_LOG=$LOGF"
rc1=$rc
run tmp2 "$D/m2" --env PROBE_MODE=tmp --env "PROBE_LOG=$LOGF"
rc2=$rc
if [ "$rc1" != 0 ] || [ "$rc2" != 0 ]; then
    bad tmpdir "runs exited $rc1 and $rc2: $("$BB" cat "$D/tmp1.log" "$D/tmp2.log" | "$BB" tr '\n' ' ')"
else
    p1=$("$BB" sed -n 1p "$LOGF")
    p2=$("$BB" sed -n 2p "$LOGF")
    why=""
    [ -n "$p1" ] && [ -n "$p2" ] || why="the probe recorded '$p1' and '$p2'"
    [ -n "$why" ] || [ "$p1" != "$p2" ] || why="both runs used TEST_TMPDIR $p1"
    for p in "$p1" "$p2"; do
        [ -n "$why" ] || case "$p" in "$PWD"/*) ;; *) why="TEST_TMPDIR $p is not under the action directory $PWD" ;; esac
        [ -n "$why" ] || [ ! -e "$p" ] || why="TEST_TMPDIR $p outlived its run"
    done
    if [ -z "$why" ]; then ok tmpdir; else bad tmpdir "$why"; fi
fi

# A test's env reaches the test and never the runner's own variables.
run env_bin "$D/m4" --env PROBE_MODE=red --env BIN=true
if [ "$rc" = 0 ] || [ -e "$D/m4" ]; then
    bad env_bin "a red test with --env BIN=true gave rc $rc, marker '$("$BB" cat "$D/m4" 2> /dev/null)'"
else
    ok env_bin
fi
# BIN naming ANOTHER program that would pass: the test must still run (and fail).
printf '#!%s sh\nexit 0\n' "$BB" > "$D/other"
"$BB" chmod +x "$D/other"
run env_bin_other "$D/m4b" --env PROBE_MODE=red --env "BIN=$D/other"
if [ "$rc" = 0 ] || [ -e "$D/m4b" ]; then
    bad env_bin_other "a red test with --env BIN=<passing script> gave rc $rc, marker '$("$BB" cat "$D/m4b" 2> /dev/null)'"
else
    ok env_bin_other
fi
# Every other name the runner's shell uses after the export step.
run env_names "$D/m4c" --env PROBE_MODE=red --env T=/nonexistent --env CWD=/nonexistent --env HELD=1 --env HOLD_ENTRY=e --env IFS=x --env ENV=/dev/null --env BB=true --env RUNNER=true
if [ "$rc" = 0 ] || [ -e "$D/m4c" ]; then
    bad env_names "a red test with runner-variable names in --env gave rc $rc"
else
    ok env_names
fi
# The test's own variables reach it (a value with a space and an =), alongside the runner's.
run env_seen "$D/m4d" --env PROBE_MODE=seen --env "SEEN_VAR=a=b c"
if [ "$rc" = 0 ] && [ "$("$BB" cat "$D/m4d" 2> /dev/null)" = "PASS //x:env_seen" ]; then ok env_seen; else bad env_seen "rc $rc: $("$BB" tail -n 3 "$D/env_seen.log")"; fi
run env_rc "$D/m5" --env PROBE_MODE=red --env rc=0 --env MARKER=/dev/null --env LABEL=x
if [ "$rc" = 0 ] || [ -e "$D/m5" ]; then bad env_rc "a red test with --env rc=0 gave rc $rc"; else ok env_rc; fi
# A test killed by a signal is red with its own status (128+N) and no marker:
# SIGKILL, what a memory limit delivers, and SIGABRT.
run killed "$D/m6" --env PROBE_MODE=killed
if [ "$rc" = 137 ] && [ ! -e "$D/m6" ]; then ok killed; else bad killed "rc $rc, marker '$("$BB" cat "$D/m6" 2> /dev/null)'"; fi
run aborted "$D/m7" --env PROBE_MODE=aborted
if [ "$rc" = 134 ] && [ ! -e "$D/m7" ]; then ok aborted; else bad aborted "rc $rc, marker '$("$BB" cat "$D/m7" 2> /dev/null)'"; fi

# --arg: in order, verbatim but for @KOMIRA_ACTION_DIR@ (every occurrence)
# becoming the action's directory, and never exported.
run args "$D/m8" --env PROBE_MODE=args --env "EXPECT_DIR=$PWD" --arg "--pair=@KOMIRA_ACTION_DIR@/a,@KOMIRA_ACTION_DIR@/b" --arg "two words" --arg SEEN_ARG=1
if [ "$rc" = 0 ] && [ "$("$BB" cat "$D/m8" 2> /dev/null)" = "PASS //x:args" ]; then ok args; else bad args "rc $rc: $("$BB" tail -n 3 "$D/args.log")"; fi
run args_order "$D/m9" --arg x --env PROBE_MODE=other
if [ "$rc" = 2 ] && [ ! -e "$D/m9" ]; then ok args_order; else bad args_order "--env after --arg gave rc $rc"; fi
# Exit 77, "skipped" to automake and some harnesses, is red here like any other status.
run skip "$D/m10" --env PROBE_MODE=skip
if [ "$rc" = 77 ] && [ ! -e "$D/m10" ]; then ok skip; else bad skip "rc $rc, marker '$("$BB" cat "$D/m10" 2> /dev/null)'"; fi

# macOS: the runner with dyld_prelude.sh prepended, and a busybox whose every
# applet loses DYLD_* (what dyld does to a protected binary). The test sees
# both loader variables at the toolchain's lib/: DYLD_LIBRARY_PATH from the
# prelude, LD_LIBRARY_PATH from the runner.
"$BB" cat "$PRELUDE" "$RUNNER" > "$D/darwin_gate_runner.sh"
cat > "$D/sip_busybox" <<SIPBB
#!$BB sh
unset DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_INSERT_LIBRARIES
exec "$BB" "\$@"
SIPBB
"$BB" chmod +x "$D/sip_busybox"
RUN_SCRIPT=$D/darwin_gate_runner.sh
RUN_BB=$D/sip_busybox
run darwin_loader "$D/m11" --env PROBE_MODE=loader --env "EXPECT_LIB=$D/tc/lib"
if [ "$rc" = 0 ] && [ "$("$BB" cat "$D/m11" 2> /dev/null)" = "PASS //x:darwin_loader" ]; then ok darwin_loader; else bad darwin_loader "rc $rc: $("$BB" tail -n 3 "$D/darwin_loader.log" | "$BB" tr '\n' ' ')"; fi
RUN_SCRIPT=$RUNNER
RUN_BB=$BB

"$BB" rm -rf "$D"
exit "$bad"
