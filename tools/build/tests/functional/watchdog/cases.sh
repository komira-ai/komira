# cases.sh -- runs tools/build/mojo/mojo_wrapper.sh's compile watchdog against
# stand-in compilers and requires each verdict. Writes one line per case to
# <report> ("ok <case>" or "BAD <case>: <why>"); exits 1 if any case is BAD.
#
# usage: busybox sh cases.sh <busybox> <mojo_wrapper.sh> <report>
#
# The stand-in toolchain holds only what the wrapper checks (CLOSURE_MANIFEST,
# bin/mojo, share/max/modular.cfg, zig). Its `mojo` is a shell script whose
# first argument picks a behaviour: a deadlock is a process tree that uses no
# CPU, which `sleep` is. Every case runs under `timeout`, so a watchdog that
# never fires makes a BAD case, not a hung action.
set -eu
case "$1" in /*) BB=$1 ;; *) BB=$PWD/$1 ;; esac
case "$2" in /*) WRAPPER=$2 ;; *) WRAPPER=$PWD/$2 ;; esac
REPORT=$3
D=$PWD/.komira_watchdog_cases
"$BB" rm -rf "$D"
"$BB" mkdir -p "$D/tc/bin" "$D/tc/share/max" "$D/zig"
printf 'bin/mojo\n' > "$D/tc/CLOSURE_MANIFEST"
printf '[max]\nroot = @@MOJO_TOOLCHAIN_ROOT@@\n' > "$D/tc/share/max/modular.cfg"
printf '#!%s sh\nexit 1\n' "$BB" > "$D/zig/zig"
cat > "$D/tc/bin/mojo" <<MOJO
#!$BB sh
out=""; prev=""
for a in "\$@"; do [ "\$prev" = -o ] && out=\$a; prev=\$a; done
spin() {
    end=\$((\$(date +%s) + \$1))
    while [ "\$(date +%s)" -lt "\$end" ]; do :; done
}
case "\$1" in
    hang) sleep 600 ;;
    hangpid) echo \$\$ > compiler.pid; sleep 600 & echo \$! > child.pid; wait ;;
    treehang) sleep 600 & echo \$! > child.pid; wait ;;
    orphan) sh -c 'sleep 600 & echo \$! > child.pid'; sleep 600 ;;
    orphanspin) (spin 7 & echo \$! > child.pid); sleep 8 ;;
    spin) spin 7 ;;
    childspin) spin 7 & wait ;;
    nap2) sleep 2 ;;
    nap5) sleep 5 ;;
    fail) exit 7 ;;
esac
echo compiled > "\$out"
MOJO
"$BB" chmod +x "$D/tc/bin/mojo" "$D/zig/zig"
: > "$REPORT"
bad=0

# expect <case> <want rc> <want text or -> <stand-in mode> <wrapper flags...>
expect() {
    name=$1 want=$2 text=$3 mode=$4
    shift 4
    c=$D/$name
    "$BB" mkdir -p "$c"
    rc=0
    echo "watchdog case: $name" >&2
    (cd "$c" && "$BB" timeout 60 "$BB" sh "$WRAPPER" "$BB" "$D/tc" "$D/zig" x86_64-linux-gnu "$@" -- "$mode" -o out.mojoc) > "$c/log" 2>&1 || rc=$?
    why=""
    [ "$rc" = "$want" ] || why="exit $rc, want $want"
    if [ -z "$why" ] && [ "$text" != - ] && ! "$BB" grep -qF -- "$text" "$c/log"; then
        why="no '$text' in output"
    fi
    # A killed child whose parent died too may linger as a zombie until the
    # action's reaper collects it; only a live state (not Z) outlived the kill.
    if [ -z "$why" ] && [ -s "$c/child.pid" ]; then
        st=$("$BB" sed -n 's/.*) \([A-Za-z]\).*/\1/p' "/proc/$("$BB" cat "$c/child.pid")/stat" 2> /dev/null || true)
        case "$st" in
            "" | Z | X) ;;
            *) why="the compiler's child $("$BB" cat "$c/child.pid") outlived the kill (state $st)" ;;
        esac
    fi
    if [ -s "$c/child.pid" ]; then "$BB" kill -9 "$("$BB" cat "$c/child.pid")" 2> /dev/null || true; fi
    if [ -z "$why" ]; then
        echo "ok $name" >> "$REPORT"
    else
        echo "BAD $name: $why: $("$BB" tail -n 3 "$c/log" | "$BB" tr '\n' ' ')" | "$BB" tee -a "$REPORT" >&2
        bad=1
    fi
}

KNOBS="--watchdog-idle-secs=3 --watchdog-sample-secs=1"
KILLED="mojo-watchdog: killed deadlocked compiler"
# $KNOBS is split into its two flags on purpose.
expect hang 124 "$KILLED" hang $KNOBS
expect treehang 124 "$KILLED" treehang $KNOBS
expect orphan 124 "$KILLED" orphan $KNOBS
# The root sleeps while an orphaned member of its session does the work: CPU
# anywhere in the session counts, so it is not killed.
expect orphanspin 0 - orphanspin $KNOBS
expect spin 0 - spin $KNOBS
expect childspin 0 - childspin $KNOBS
expect short_nap 0 - nap2 $KNOBS
expect compiler_error 7 - fail $KNOBS
expect disabled 0 - nap5 --watchdog-idle-secs=0 --watchdog-sample-secs=1
expect enabled 124 "$KILLED" nap5 --watchdog-idle-secs=2 --watchdog-sample-secs=1
expect default_knobs 0 - nap2
expect bad_sample 2 "watchdog-sample-secs must be at least 1" nap2 --watchdog-sample-secs=0
expect bad_idle 2 "whole numbers" nap2 --watchdog-idle-secs=5m

# killed <case> <signal> <want rc>: the wrapper is signalled while its
# compiler (and the compiler's child) hang with the watchdog far from firing.
# Within 5 s of the signal both must be gone: a caught signal kills the tree
# before the wrapper exits (rc 128 + signal); SIGKILL cannot be caught, and
# the tether in the compiler's session must kill it (rc 137, from the shell).
alive() { # pid: running, stopped or sleeping, not a zombie
    st=$("$BB" sed -n 's/.*) \([A-Za-z]\).*/\1/p' "/proc/$1/stat" 2> /dev/null || true)
    case "$st" in "" | Z | X) return 1 ;; *) return 0 ;; esac
}
killed() {
    name=$1 sig=$2 want=$3
    c=$D/$name
    "$BB" mkdir -p "$c"
    echo "watchdog case: $name" >&2
    (cd "$c" && exec "$BB" sh "$WRAPPER" "$BB" "$D/tc" "$D/zig" x86_64-linux-gnu \
        --watchdog-idle-secs=600 --watchdog-sample-secs=1 -- hangpid -o out.mojoc) > "$c/log" 2>&1 &
    w=$!
    n=0
    while [ ! -s "$c/child.pid" ] && [ "$n" -lt 20 ]; do "$BB" sleep 1; n=$((n + 1)); done
    why=""
    if [ ! -s "$c/child.pid" ] || [ ! -s "$c/compiler.pid" ]; then
        why="the stand-in compiler did not start"
        "$BB" kill -s KILL "$w" 2> /dev/null || true
    fi
    rc=0
    if [ -z "$why" ]; then
        "$BB" kill -s "$sig" "$w"
        wait "$w" || rc=$?
        [ "$rc" = "$want" ] || why="the wrapper exited $rc, want $want"
    fi
    left=""
    n=0
    while [ -z "$why" ] && [ "$n" -lt 5 ]; do
        left=""
        for p in "$("$BB" cat "$c/compiler.pid")" "$("$BB" cat "$c/child.pid")"; do
            if alive "$p"; then left="$left $p"; fi
        done
        [ -n "$left" ] || break
        "$BB" sleep 1
        n=$((n + 1))
    done
    [ -z "$left" ] || why="${why:+$why; }still alive 5 s after SIG$sig to the wrapper:$left"
    for p in "$("$BB" cat "$c/compiler.pid" 2> /dev/null)" "$("$BB" cat "$c/child.pid" 2> /dev/null)"; do
        [ -z "$p" ] || "$BB" kill -9 "$p" 2> /dev/null || true
    done
    if [ -z "$why" ]; then
        echo "ok $name" >> "$REPORT"
    else
        echo "BAD $name: $why: $("$BB" tail -n 3 "$c/log" | "$BB" tr '\n' ' ')" | "$BB" tee -a "$REPORT" >&2
        bad=1
    fi
}
killed wrapper_term TERM 143
killed wrapper_kill KILL 137
"$BB" rm -rf "$D"
exit "$bad"
