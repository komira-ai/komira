# cases.sh -- install_gate.sh, the switch between SKIP and FAIL of the pixi
# install case of conda.sh and conda_set.sh, on PATHs with and without a
# stand-in pixi and curl; both scripts refusing --require-install with
# --no-install; and each script's own install_gate call, run on a PATH with
# no pixi and no curl. Writes one line per case to <report> ("ok <case>" or
# "BAD <case>: <why>"); exits 1 if any case is BAD.
#
# usage: busybox sh cases.sh <busybox> <install_gate.sh> <conda.sh> <conda_set.sh> <report>
#
# Every PATH here is a directory this script made: `bare` holds nothing (no
# pixi, no curl), the others a stand-in `pixi` and/or a `curl` that succeeds or
# fails. No case reaches the network.
set -eu
case "$1" in /*) BB=$1 ;; *) BB=$PWD/$1 ;; esac
case "$2" in /*) GATE=$2 ;; *) GATE=$PWD/$2 ;; esac
case "$3" in /*) CONDA=$3 ;; *) CONDA=$PWD/$3 ;; esac
case "$4" in /*) CONDA_SET=$4 ;; *) CONDA_SET=$PWD/$4 ;; esac
REPORT=$5
D=$PWD/.komira_install_gate_cases
URL=https://channel.invalid/repodata.json
"$BB" mkdir -p "$D/bare" "$D/pixi_online" "$D/pixi_offline" "$D/applets"
printf '#!%s sh\nexit 0\n' "$BB" > "$D/pixi_online/pixi"
printf '#!%s sh\nexit 0\n' "$BB" > "$D/pixi_online/curl"
printf '#!%s sh\nexit 0\n' "$BB" > "$D/pixi_offline/pixi"
printf '#!%s sh\nexit 6\n' "$BB" > "$D/pixi_offline/curl"
"$BB" chmod +x "$D/pixi_online/pixi" "$D/pixi_online/curl" "$D/pixi_offline/pixi" "$D/pixi_offline/curl"
"$BB" ln -s "$BB" "$D/applets/dirname"
: > "$REPORT"
bad=0

verdict() { # name, why ("" is ok)
    if [ -z "$2" ]; then
        echo "ok $1" >> "$REPORT"
    else
        echo "BAD $1: $2" >> "$REPORT"
        bad=1
    fi
}

# gate <case> <want rc> <want stdout, exactly> <PATH dir> <install_gate args...>
gate() {
    name=$1 want=$2 text=$3 dir=$4
    shift 4
    rc=0
    PATH=$D/$dir "$BB" sh -c '. "$0"; install_gate "$@"' "$GATE" "$@" > "$D/$name.out" 2> "$D/$name.err" || rc=$?
    got=$("$BB" cat "$D/$name.out")
    why=""
    [ "$rc" = "$want" ] || why="exit $rc, want $want"
    [ -n "$why" ] || [ "$got" = "$text" ] || why="stdout [$got], want [$text]"
    [ -n "$why" ] || [ ! -s "$D/$name.err" ] || why="stderr [$("$BB" cat "$D/$name.err")]"
    verdict "$name" "$why"
}

# refuse <case> <script> <name it prints>: --no-install --require-install is exit 2 and that one line
refuse() {
    rc=0
    PATH=$D/applets "$BB" sh "$2" --no-install --require-install > "$D/$1.out" 2> "$D/$1.err" || rc=$?
    got=$("$BB" cat "$D/$1.err")
    want="$3: --require-install and --no-install contradict each other"
    why=""
    [ "$rc" = 2 ] || why="exit $rc, want 2"
    [ -n "$why" ] || [ "$got" = "$want" ] || why="stderr [$got], want [$want]"
    [ -n "$why" ] || [ ! -s "$D/$1.out" ] || why="stdout [$("$BB" cat "$D/$1.out")]"
    verdict "$1" "$why"
}

# script <case> <script> <flag or ""> <want stdout line>: the script, copied
# into the layout it finds install_gate.sh in, run on PATH=applets (dirname
# only). With a flag: exit 1, stdout exactly the line, stderr empty. Without:
# the first stdout line is the line (the script goes on and stops at its next
# missing tool).
R=$D/root/tools/build/tests/functional
"$BB" mkdir -p "$R/install_gate"
"$BB" cp "$CONDA" "$R/conda.sh"
"$BB" cp "$CONDA_SET" "$R/conda_set.sh"
"$BB" cp "$GATE" "$R/install_gate/install_gate.sh"
script() {
    rc=0
    if [ -n "$3" ]; then
        PATH=$D/applets "$BB" sh "$R/$2" "$3" > "$D/$1.out" 2> "$D/$1.err" || rc=$?
    else
        PATH=$D/applets "$BB" sh "$R/$2" > "$D/$1.out" 2> "$D/$1.err" || rc=$?
    fi
    why=""
    if [ -n "$3" ]; then
        got=$("$BB" cat "$D/$1.out")
        [ "$rc" = 1 ] || why="exit $rc, want 1"
        [ -n "$why" ] || [ "$got" = "$4" ] || why="stdout [$got], want [$4]"
        [ -n "$why" ] || [ ! -s "$D/$1.err" ] || why="stderr [$("$BB" cat "$D/$1.err")]"
    else
        got=$("$BB" head -n 1 "$D/$1.out")
        [ "$got" = "$4" ] || why="first stdout line [$got], want [$4]"
    fi
    verdict "$1" "$why"
}

# No pixi on PATH: a SKIP line without --require-install, a FAIL line with it.
gate skip_no_pixi 1 "SKIP  conda install (no pixi)" bare conda 1 0
gate fail_no_pixi 2 "FAIL  conda install: --require-install, but it cannot run (no pixi)" bare conda 1 1
gate fail_no_pixi_set 2 "FAIL  conda_set install: --require-install, but it cannot run (no pixi)" bare conda_set 1 1
# Every reason is named, on one line.
gate skip_no_pixi_no_network 1 "SKIP  conda install (no pixi, no network)" bare conda 1 0 "$URL"
gate fail_no_pixi_no_network 2 "FAIL  conda install: --require-install, but it cannot run (no pixi, no network)" bare conda 1 1 "$URL"
# pixi present, the URL unreachable.
gate skip_no_network 1 "SKIP  conda install (no network)" pixi_offline conda 1 0 "$URL"
gate fail_no_network 2 "FAIL  conda install: --require-install, but it cannot run (no network)" pixi_offline conda 1 1 "$URL"
# pixi present and the URL reachable: the case runs, with or without --require-install.
gate runs 0 "" pixi_online conda 1 0 "$URL"
gate runs_required 0 "" pixi_online conda 1 1 "$URL"
# --no-install skips even where it could run, and probes no URL.
gate skip_no_install 1 "SKIP  conda install (--no-install)" pixi_offline conda 0 0 "$URL"
# The scripts take the flag, and refuse it beside --no-install.
refuse conda_contradiction "$CONDA" conda.sh
refuse conda_set_contradiction "$CONDA_SET" conda_set.sh
# Each script, run on the bare PATH as far as its own install_gate call (which
# comes before any build): the call passes the script's suite name, --no-install
# and --require-install. With --require-install the script prints the FAIL line
# and exits 1 there; without it the first line is the SKIP line.
script required_conda conda.sh --require-install "FAIL  conda install: --require-install, but it cannot run (no pixi, no network)"
script required_conda_set conda_set.sh --require-install "FAIL  conda_set install: --require-install, but it cannot run (no pixi, no network)"
script unrequired_conda conda.sh "" "SKIP  conda install (no pixi, no network)"
script unrequired_conda_set conda_set.sh "" "SKIP  conda_set install (no pixi, no network)"

"$BB" cat "$REPORT"
[ "$bad" = 0 ]
