# runner_cases.sh -- runs tools/build/mojo/gate_runner.sh against a stand-in
# test in ONE action directory and requires each verdict. Writes one line per
# case to <report> ("ok <case>" or "BAD <case>: <why>"); exits 1 if any case is
# BAD.
#
# usage: busybox sh runner_cases.sh <busybox> <gate_runner.sh> <report>
#
# Two gated tests in two actions cannot show that their TEST_TMPDIRs differ:
# on remote execution each runs in its own action directory and is then
# cached, so a runner that used one fixed directory for every run would pass
# them. Here both runs share one action directory, one after the other.
set -eu
case "$1" in /*) BB=$1 ;; *) BB=$PWD/$1 ;; esac
case "$2" in /*) RUNNER=$2 ;; *) RUNNER=$PWD/$2 ;; esac
REPORT=$3
D=$PWD/.komira_runner_cases
"$BB" rm -rf "$D"
"$BB" mkdir -p "$D/root/bin"
# The stand-in test; PROBE_MODE (given through --env) picks its behaviour.
cat > "$D/root/bin/probe" <<PROBE
#!$BB sh
case "\${PROBE_MODE:-}" in
    red) exit 1 ;;
    tmp)
        [ -n "\${TEST_TMPDIR:-}" ] || { echo "probe: TEST_TMPDIR unset"; exit 11; }
        [ -d "\$TEST_TMPDIR" ] || { echo "probe: \$TEST_TMPDIR is not a directory"; exit 12; }
        [ -z "\$(ls -A "\$TEST_TMPDIR")" ] || { echo "probe: \$TEST_TMPDIR is not empty"; exit 13; }
        [ "\${TMPDIR:-}" = "\$TEST_TMPDIR" ] || { echo "probe: TMPDIR != TEST_TMPDIR"; exit 14; }
        echo "\$TEST_TMPDIR" >> "\$PROBE_LOG"
        : > "\$TEST_TMPDIR/left_by_probe"
        exit 0 ;;
    *) echo "probe: PROBE_MODE='\${PROBE_MODE:-}'"; exit 15 ;;
esac
PROBE
"$BB" chmod +x "$D/root/bin/probe"
: > "$REPORT"
bad=0

ok() { echo "ok $1" >> "$REPORT"; }
bad() { echo "BAD $1: $2" | "$BB" tee -a "$REPORT" >&2; bad=1; }

# run <case> <marker> <runner options...>: runs the runner from this action's
# directory; sets rc and leaves its output in $D/<case>.log.
run() {
    name=$1 marker=$2
    shift 2
    rc=0
    "$BB" rm -f "$marker"
    "$BB" timeout 60 "$BB" sh "$RUNNER" "$BB" "$D/tc" "//x:$name" "$D/root/bin/probe" "$marker" "$@" > "$D/$name.log" 2>&1 || rc=$?
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
run env_held "$D/m3" --env PROBE_MODE=red --env HELD=1
if [ "$rc" = 0 ] || [ -e "$D/m3" ]; then
    bad env_held "a red test with --env HELD=1 gave rc $rc, marker '$("$BB" cat "$D/m3" 2> /dev/null)'"
else
    ok env_held
fi
run env_bin "$D/m4" --env PROBE_MODE=red --env BIN=true
if [ "$rc" = 0 ] || [ -e "$D/m4" ]; then
    bad env_bin "a red test with --env BIN=true gave rc $rc, marker '$("$BB" cat "$D/m4" 2> /dev/null)'"
else
    ok env_bin
fi
run env_rc "$D/m5" --env PROBE_MODE=red --env rc=0 --env MARKER=/dev/null --env LABEL=x
if [ "$rc" = 0 ] || [ -e "$D/m5" ]; then bad env_rc "a red test with --env rc=0 gave rc $rc"; else ok env_rc; fi
# The inversion itself still works: a held red is satisfied.
run held_red "$D/m6" --env PROBE_MODE=red --hold e 1 reason
if [ "$rc" = 0 ] && [ "$("$BB" cat "$D/m6" 2> /dev/null)" = "HELD //x:held_red" ]; then ok held_red; else bad held_red "rc $rc, marker '$("$BB" cat "$D/m6" 2> /dev/null)'"; fi

"$BB" rm -rf "$D"
exit "$bad"
