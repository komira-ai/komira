# cases.sh -- runs tools/build/mojo/mem_cap.sh against a stand-in for
# gate_runner.sh and requires each verdict where the process tree cannot be
# read, the cap itself is signalled, or a child left the runner's process
# tree. Writes one line per case to <report>
# ("ok <case>" or "BAD <case>: <why>"); exits 1 if any case is BAD.
#
# usage: busybox sh cases.sh <busybox> <mem_cap.sh> <report>
#
# The stand-in `runner` writes its pid to runner.pid, starts a child that
# sleeps (the test) and writes its pid to child.pid, and waits for it; in its
# daemon modes the sleeping child is reparented out of the runner's process
# tree (and daemon_hog then waits on a second child over the cap). A case
# whose verdict is a kill requires that neither is alive (a zombie has
# exited) within 5 s of the cap's exit. Every case runs under `timeout`, so a
# cap that leaves the stand-in running makes a BAD case, not a hung action.
set -eu
case "$1" in /*) BB=$1 ;; *) BB=$PWD/$1 ;; esac
case "$2" in /*) MEMCAP=$2 ;; *) MEMCAP=$PWD/$2 ;; esac
REPORT=$3
D=$PWD/.komira_mem_cap_cases
"$BB" rm -rf "$D"
"$BB" mkdir -p "$D"
cat > "$D/runner" <<RUNNER
case "\$1" in
    exit7) exit 7 ;;
    hang) echo \$\$ > runner.pid; "$BB" sleep 600 & echo \$! > child.pid; wait \$! ;;
    daemon | daemon_hog)
        echo \$\$ > runner.pid
        # The subshell exits at once: its sleep is reparented out of the
        # runner's process tree but stays in the runner's session.
        ( "$BB" sleep 600 & echo \$! > child.pid )
        [ "\$1" = daemon ] && exit 0
        # A child holding 40 MB resident, over an 8 MiB cap.
        "$BB" sh -c 'x=\$("$BB" head -c 40000000 /dev/zero | "$BB" tr "\\\\0" a); "$BB" sleep 600' &
        wait \$!
        ;;
esac
RUNNER
# A busybox whose cat of a /proc path fails, writing nothing, from its 11th
# such call on (about 1 s of samples), counted in cat.count in the cap's
# working directory: /proc that stops being readable while the test runs.
cat > "$D/bb_noproc" <<SHIM
#!$BB sh
if [ "\$1" = cat ]; then
    case "\$*" in
        */proc/*)
            n=\$(("\$("$BB" cat cat.count 2> /dev/null || echo 0)" + 1))
            echo "\$n" > cat.count
            [ "\$n" -le 10 ] || exit 1
            ;;
    esac
fi
exec "$BB" "\$@"
SHIM
"$BB" chmod +x "$D/bb_noproc"
: > "$REPORT"
bad=0
LABEL=//mem_cap:case

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
    [ -z "$left" ] || why="${why:+$why; }still alive 5 s after the cap exited:$left"
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

# expect <case> <busybox for the cap> <want rc> <want text or -> <runner mode> [cap MiB]
expect() {
    name=$1 capbb=$2 want=$3 text=$4 mode=$5 cap=${6:-4096}
    c=$D/$name
    "$BB" mkdir -p "$c"
    rc=0
    echo "mem_cap case: $name" >&2
    (cd "$c" && "$BB" timeout 60 "$BB" sh "$MEMCAP" "$capbb" "$cap" "$LABEL" -- "$BB" sh "$D/runner" "$mode") > "$c/log" 2>&1 || rc=$?
    why=""
    [ "$rc" = "$want" ] || why="exit $rc, want $want"
    if [ -z "$why" ] && [ "$text" != - ] && ! "$BB" grep -qF -- "$text" "$c/log"; then
        why="no '$text' in output"
    fi
    if [ -z "$why" ] && [ "$mode" != exit7 ] && { [ ! -s "$c/runner.pid" ] || [ ! -s "$c/child.pid" ]; }; then
        why="the stand-in did not start its child"
    fi
    verdict "$name" "$why"
}

# The runner's status is the cap's.
expect status "$BB" 7 - exit7
# /proc stops being readable: the cap ends the run (exit 2) and kills the
# runner and its child; it does not wait for them uncapped.
expect unreadable "$D/bb_noproc" 2 "mem_cap: cannot read the process tree of $LABEL from /proc; killed it rather than run it uncapped" hang
# The runner leaves a child that was reparented out of its process tree but
# not out of its session. On a normal exit, and when the cap kills the
# runner's memory-hungry child (which is the runner's to report: rc 137 from
# its wait), the cap kills the session's group before it exits.
expect daemon_normal "$BB" 0 - daemon
expect daemon_capped "$BB" 137 "MEMORY CAP: killed $LABEL at " daemon_hog 8

# killed <case> <signal> <want rc>: the cap is signalled while the runner and
# its child hang. A caught signal kills them before the cap exits (rc 128 +
# signal); SIGKILL cannot be caught, and the tether in the runner's session
# must kill them (rc 137, from the shell).
killed() {
    name=$1 sig=$2 want=$3
    c=$D/$name
    "$BB" mkdir -p "$c"
    echo "mem_cap case: $name" >&2
    (cd "$c" && exec "$BB" sh "$MEMCAP" "$BB" 4096 "$LABEL" -- "$BB" sh "$D/runner" hang) > "$c/log" 2>&1 &
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
        [ "$rc" = "$want" ] || why="the cap exited $rc, want $want"
    fi
    verdict "$name" "$why"
}
killed term TERM 143
killed kill KILL 137
"$BB" rm -rf "$D"
exit "$bad"
