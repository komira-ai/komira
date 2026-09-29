#!/bin/sh
# busybox.sh -- the busybox calling convention over the macOS base system.
#
# On a macOS execution host there is no static busybox, so every Mojo action
# runs its scripts through this front end instead. It accepts exactly the
# forms the rules use:
#
#   busybox.sh <applet> <args...>      run one applet
#   busybox.sh --install -s <dir>      link every applet in <dir> to this file
#   <dir>/<applet> <args...>           (such a link) run that applet
#
# An applet is resolved in /bin and /usr/bin only, which on macOS belong to
# the operating system (the sealed system volume), never to a developer tool
# installation, and only if it is in the fixed list below. Anything else is
# refused (exit 127), so a script cannot reach a tool the platform does not
# declare.

set -eu

APPLETS="awk basename cat chmod cmp cp cut dirname env expr find grep head ln ls mkdir mkfifo mktemp mv printf ps readlink rm rmdir sed sh sleep sort tail tee test touch tr uname wc"

self=$0
case "$self" in /*) ;; *) self="$PWD/$self" ;; esac

run() {
    applet=$1
    shift
    case " $APPLETS " in
        *" $applet "*) ;;
        *) echo "busybox.sh: REFUSING: '$applet' is not an applet of this platform" >&2; exit 127 ;;
    esac
    for d in /bin /usr/bin; do
        if [ -x "$d/$applet" ]; then exec "$d/$applet" "$@"; fi
    done
    echo "busybox.sh: REFUSING: '$applet' is not in /bin or /usr/bin on this host" >&2
    exit 127
}

name=${0##*/}
case "$name" in
    busybox|busybox.sh) ;;
    *) run "$name" "$@" ;;
esac

[ "$#" -ge 1 ] || { echo "busybox.sh: usage: busybox.sh <applet> <args...> | --install -s <dir>" >&2; exit 2; }
if [ "$1" = "--install" ]; then
    [ "$#" = 3 ] && [ "$2" = "-s" ] || { echo "busybox.sh: usage: --install -s <dir>" >&2; exit 2; }
    for a in $APPLETS; do
        /bin/ln -sf "$self" "$3/$a"
    done
    exit 0
fi
run "$@"
