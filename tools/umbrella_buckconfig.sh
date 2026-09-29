#!/usr/bin/env bash
# umbrella_buckconfig.sh -- print the .buckconfig sections a repository needs
# to mount this one as a set of cells.
#
# usage: tools/umbrella_buckconfig.sh <mount>
#
#   <mount>  where this repository is checked out, relative to the mounting
#            repository's root (for a git submodule, its path).
#
# Buck2 registers cells only from the project root's `[cells]`: a cell's own
# `[cells]` entries are aliases for cells the root already declares, and
# `<file:...>` includes are not read when resolving cells. So a mounting
# repository has to restate every cell this one declares. This script derives
# that restatement from this repository's .buckconfig, so it cannot drift from
# it: every cell keeps its name and moves under <mount>, and `[cell_aliases]`,
# `[external_cells]`, `[buildfile]`, `[parser]` and `[buck2_re_client]` (the
# client-side batch size limit; endpoints are never in .buckconfig) are
# copied unchanged.
#
# Paste the output into the mounting repository's .buckconfig, then add that
# repository's own root cell, its `[build] execution_platforms`, and its
# remote-execution settings (see "Mounting komira in another repository" in
# README.md). Regenerate it whenever the mounted revision changes.
set -euo pipefail

if [ $# -ne 1 ] || [ -z "$1" ]; then
    echo "usage: $0 <mount>" >&2
    exit 1
fi
mount=${1%/}
case "$mount" in
    /*) echo "$0: <mount> must be relative to the mounting repository's root" >&2; exit 1 ;;
esac

config="$(cd "$(dirname "$0")/.." && pwd)/.buckconfig"

awk -v mount="$mount" '
    function flush() { if (section != "" && body != "") printf "[%s]\n%s\n", section, body; body = "" }
    /^[ \t]*[#;]/ || /^[ \t]*$/ { next }
    /^\[[^]]+\][ \t]*$/ {
        flush()
        name = $0; gsub(/^\[|\][ \t]*$/, "", name)
        keep = (name == "cells" || name == "cell_aliases" || name == "external_cells" ||
                name == "buildfile" || name == "parser" || name == "buck2_re_client")
        section = keep ? name : ""
        next
    }
    section == "" { next }
    section == "cells" {
        split($0, kv, "="); key = kv[1]; path = substr($0, index($0, "=") + 1)
        gsub(/[ \t]/, "", key); gsub(/^[ \t]+|[ \t]+$/, "", path)
        if (path == ".") path = mount; else path = mount "/" path
        body = body sprintf("  %s = %s\n", key, path)
        cells++
        next
    }
    { sub(/^[ \t]+/, ""); body = body "  " $0 "\n" }
    END {
        flush()
        if (cells == 0) { print "no [cells] found" > "/dev/stderr"; exit 1 }
    }
' "$config"
