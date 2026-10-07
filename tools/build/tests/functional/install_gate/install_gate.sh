# install_gate.sh -- whether the pixi install case of conda.sh or conda_set.sh
# runs, is skipped, or fails because it cannot run. Sourced by both (POSIX sh;
# busybox sh runs it in tests//functional/install_gate:cases).
#
# install_gate <suite> <install> <require> [<url>]
#   <install>  1 unless the script was given --no-install
#   <require>  1 when the script was given --require-install
#   <url>      a URL the install needs; probed with curl when <install> is 1
# Returns 0 when the case can run: <install> is 1, `pixi` is on PATH and,
# with a <url>, `curl -fsSL -I` reaches it. Otherwise it prints one line
# naming every reason, comma-separated, and returns 1 after
#   SKIP  <suite> install (<reasons>)
# or, when <require> is 1, returns 2 after
#   FAIL  <suite> install: --require-install, but it cannot run (<reasons>)
install_gate() {
    _ig_why=""
    [ "$2" = 1 ] || _ig_why="--no-install"
    command -v pixi > /dev/null 2>&1 || _ig_why="${_ig_why:+$_ig_why, }no pixi"
    if [ "$2" = 1 ] && [ -n "${4:-}" ]; then
        curl -fsSL -o /dev/null -I "$4" > /dev/null 2>&1 || _ig_why="${_ig_why:+$_ig_why, }no network"
    fi
    [ -n "$_ig_why" ] || return 0
    if [ "$3" = 1 ]; then
        echo "FAIL  $1 install: --require-install, but it cannot run ($_ig_why)"
        return 2
    fi
    echo "SKIP  $1 install ($_ig_why)"
    return 1
}
