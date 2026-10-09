# cases.sh -- runs tools/build/mojo/test_deadline.sh against a stand-in for
# gate_runner.sh and requires each verdict: the runner's status passed through
# with no wait for the limit, the test killed at the limit with the runner
# left to report it, and nothing of the run alive after a normal exit or when
# the script itself is signalled. Writes one line per case to <report>
# ("ok <case>" or "BAD <case>: <why>"); exits 1 if any case is BAD.
#
# usage: busybox sh cases.sh <busybox> <test_deadline.sh> <report>
#
# The stand-in `runner` writes its pid to runner.pid, starts the "test" (a
# copy of busybox at another path, so its executable is not <busybox>, as a
# Mojo test's is not)
# that sleeps, writes its pid to child.pid, waits for it and prints
# `runner saw exit <n>`. A case whose verdict is a kill requires that neither
# is alive (a zombie has exited) within 5 s of the script's exit. Every case
# runs under `timeout`, so a script that leaves the stand-in running makes a
# BAD case, not a hung action.
set -eu
case "$1" in /*) BB=$1 ;; *) BB=$PWD/$1 ;; esac
case "$2" in /*) DEADLINE=$2 ;; *) DEADLINE=$PWD/$2 ;; esac
REPORT=$3
D=$PWD/.komira_test_deadline_cases
"$BB" rm -rf "$D"
"$BB" mkdir -p "$D"
"$BB" mkdir -p "$D/t"
"$BB" cp "$BB" "$D/t/busybox"
cat > "$D/runner" <<RUNNER
case "\$1" in
    exit7) exit 7 ;;
    hang)
        echo \$\$ > runner.pid
        "$D/t/busybox" sleep 600 & echo \$! > child.pid
        rc=0; wait \$! || rc=\$?
        echo "runner saw exit \$rc"
        exit "\$rc"
        ;;
    daemon)
        echo \$\$ > runner.pid
        # The subshell exits at once: its sleep is reparented out of the
        # runner's process tree but stays in the runner's session.
        ( "$D/t/busybox" sleep 600 & echo \$! > child.pid )
        exit 0
        ;;
esac
RUNNER
: > "$REPORT"
bad=0
LABEL=//test_deadline:case

alive() { # pid: running, stopped or sleeping, not a zombie
    st=$("$BB" sed -n 's/.*) \([A-Za-z]\).*/\1/p' "/proc/$1/stat" 2> /dev/null || true)
    case "$st" in "" | Z | X) return 1 ;; *) return 0 ;; esac
}

# verdict <case> <why so far>: requires runner and child (when started) gone
# within 5 s, kills what is left, and records the case.
verdict() {
    name=$1 why=$2
    c=$D/$name
    left=""
    n=0
    while [ "$n" -lt 5 ]; do
        left=""
        for f in runner.pid child.pid; do
            [ -s "$c/$f" ] || continue
            p=$("$BB" cat "$c/$f")
            if alive "$p"; then left="$left $f=$p"; fi
        done
        [ -n "$left" ] || break
        "$BB" sleep 1
        n=$((n + 1))
    done
    [ -z "$left" ] || why="${why:+$why; }still alive 5 s after the script exited:$left"
    for f in runner.pid child.pid; do
        [ -s "$c/$f" ] && "$BB" kill -9 "$("$BB" cat "$c/$f")" 2> /dev/null || true
    done
    if [ -z "$why" ]; then
        echo "ok $name" >> "$REPORT"
    else
        echo "BAD $name: $why: $("$BB" tail -n 3 "$c/log" | "$BB" tr '\n' ' ')" | "$BB" tee -a "$REPORT" >&2
        bad=1
    fi
}

# expect <case> <limit s> <want rc> <runner mode> <max s> <text or -> [text or -]:
# the script's status, that it returned within <max s>, and each text in its
# output; a text starting with `!` must not appear.
expect() {
    name=$1 limit=$2 want=$3 mode=$4 max=$5
    shift 5
    c=$D/$name
    "$BB" mkdir -p "$c"
    rc=0
    echo "test_deadline case: $name" >&2
    t0=$("$BB" date +%s)
    (cd "$c" && "$BB" timeout 60 "$BB" sh "$DEADLINE" "$BB" "$limit" 62 "$LABEL" -- "$BB" sh "$D/runner" "$mode") > "$c/log" 2>&1 || rc=$?
    t=$(($("$BB" date +%s) - t0))
    why=""
    [ "$rc" = "$want" ] || why="exit $rc, want $want"
    [ -n "$why" ] || [ "$t" -le "$max" ] || why="returned after $t s, want at most $max"
    for text in "$@"; do
        [ -z "$why" ] || break
        case "$text" in
            -) ;;
            !*) if "$BB" grep -qF -- "${text#!}" "$c/log"; then why="'${text#!}' in output"; fi ;;
            *) "$BB" grep -qF -- "$text" "$c/log" || why="no '$text' in output" ;;
        esac
    done
    if [ -z "$why" ] && [ "$mode" != exit7 ] && { [ ! -s "$c/runner.pid" ] || [ ! -s "$c/child.pid" ]; }; then
        why="the stand-in did not start its child"
    fi
    verdict "$name" "$why"
}

# The runner's status is the script's, at once: the timer does not hold the
# script until the limit.
expect status 30 7 exit7 10 "!TEST TIME LIMIT"
# Past the limit the test (the non-busybox child) is killed and the runner
# lives to report it; then the script says why.
expect expired 2 137 hang 20 "runner saw exit 137" "TEST TIME LIMIT: killed $LABEL after 2 s, under the test runner's timeout of 62 s (komira.test_timeout_s)"
# A child reparented out of the runner's process tree (still in its session)
# does not outlive a normal exit (the script's group kill and the tether each
# see to it).
expect daemon 30 0 daemon 10 "!TEST TIME LIMIT"
# A limit that is not a positive whole number is refused.
expect zero_limit 0 2 exit7 10 "test_deadline: REFUSING: '0' is not a positive whole number of seconds"

# killed <case> <signal> <want rc>: the script is signalled while the runner
# and its child hang. A caught signal kills them before the script exits (rc
# 128 + signal); SIGKILL cannot be caught, and the tether in the runner's
# session must kill them (rc 137, from the shell).
killed() {
    name=$1 sig=$2 want=$3
    c=$D/$name
    "$BB" mkdir -p "$c"
    echo "test_deadline case: $name" >&2
    (cd "$c" && exec "$BB" sh "$DEADLINE" "$BB" 600 662 "$LABEL" -- "$BB" sh "$D/runner" hang) > "$c/log" 2>&1 &
    w=$!
    n=0
    while [ ! -s "$c/child.pid" ] && [ "$n" -lt 20 ]; do "$BB" sleep 1; n=$((n + 1)); done
    why=""
    if [ ! -s "$c/child.pid" ] || [ ! -s "$c/runner.pid" ]; then
        why="the stand-in did not start its child"
        "$BB" kill -s KILL "$w" 2> /dev/null || true
    fi
    rc=0
    if [ -z "$why" ]; then
        "$BB" kill -s "$sig" "$w"
        wait "$w" || rc=$?
        [ "$rc" = "$want" ] || why="the script exited $rc, want $want"
    fi
    verdict "$name" "$why"
}
killed term TERM 143
killed kill KILL 137
"$BB" rm -rf "$D"
exit "$bad"
