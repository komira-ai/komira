#!/usr/bin/env bash
# glibc_level.sh -- the launcher's x86-64 level for this host's CPU against
# the level this host's glibc loader supports.
#
# usage: tools/build/tests/functional/glibc_level.sh <level_test program>   (//tools/build/package:level_test[bin])
#
# glibc (2.33 or later) prints the hwcaps subdirectories it will search in
# `ld.so --list-diagnostics`: dl_hwcaps_subdirs_active is a mask over
# x86-64-v4:x86-64-v3:x86-64-v2 counted from the lowest, so 0x0/0x4/0x6/0x7
# are levels 1/2/3/4. glibc cannot tell baseline from below baseline, so a
# launcher level 0 counts as 1. Prints one line; exit 0 when they agree, 1
# when they do not, 2 when this host has no x86-64 glibc loader to ask.
set -uo pipefail
LD=/lib64/ld-linux-x86-64.so.2
if [ "$(uname -sm)" != "Linux x86_64" ] || [ ! -x "$LD" ]; then
    echo "not an x86-64 glibc host"; exit 2
fi
k=$( (ulimit -v 1000000 && env -i "$1") 2>&1 | sed -n 's/^this cpu: level //p')
[ "$k" = 0 ] && k=1
m=$(env -i "$LD" --list-diagnostics 2> /dev/null | sed -n 's/^dl_hwcaps_subdirs_active=//p')
case "$m" in 0x0) g=1 ;; 0x4) g=2 ;; 0x6) g=3 ;; 0x7) g=4 ;; *) g="unknown(dl_hwcaps_subdirs_active=[$m])" ;; esac
echo "this host: launcher level ${k:-none}, glibc level $g"
[ -n "$k" ] && [ "$k" = "$g" ]
