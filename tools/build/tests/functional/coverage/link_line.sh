#!/bin/sh
# link_line.sh -- a check that a branch coverage link is the link of a
# release test (test 47), run as a build action by cov_link_line_check
# (defs.bzl):
#   sh link_line.sh <busybox> <out> <wrapper> <compiler_dir> <zig_dir> <cc_target> <cpu>
#       <test.mojo> <bitcode> <link_dir> [-I<dir>...]
#
# Both links run with a stand-in <zig_dir> whose `zig` records its argument
# list and runs the toolchain's zig:
#   1. mojo_wrapper.sh (the release build's, unchanged) builds <test.mojo>
#      against the -I closure, as the test's [coverage][bin] is built; `mojo
#      build` links through the wrapper's `cc` shim, so what zig is given is
#      the release link line;
#   2. <link_dir>/cov_branch_link.sh links <bitcode> (that test's
#      [coverage][bc]) as [coverage][pgo_bin] is linked.
# Each must run zig once. The lines must be the same once the compiler's
# object (mojo's archive, the link's instrumented object) is named <object>,
# the output <out>, the toolchain <TC>, the target <target> and the profile
# runtime <runtime>, and once the profile runtime, which only the branch
# link has, is removed: one `-Wl,--whole-archive <runtime>
# -Wl,--no-whole-archive`.
# A Mojo release that links with another library or flag, or a link script
# that drops or adds one, fails here, naming the two lines. Writes both
# lines to <out>; exits 1 naming the first failure, 2 for a usage error.
set -euf
# shellcheck disable=SC3040 # busybox sh (ash) has pipefail
set -o pipefail
abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
[ "$#" -ge 10 ] || { echo "link_line: usage error" >&2; exit 2; }
BB=$(abs "$1")
OUT=$(abs "$2")
WRAPPER=$(abs "$3")
TC=$(abs "$4")
ZIG=$(abs "$5")
TARGET=$6
CPU=$7
SRC=$(abs "$8")
BC=$(abs "$9")
LINK=$(abs "${10}")
shift 10
case "${BUCK_SCRATCH_PATH:-}" in
    "") K="$PWD/.link_line" ;;
    /*) K="$BUCK_SCRATCH_PATH/link_line" ;;
    *) K="$PWD/$BUCK_SCRATCH_PATH/link_line" ;;
esac
"$BB" mkdir -p "$K/bin" "$K/src/tests"
"$BB" --install -s "$K/bin"
PATH="$K/bin"
export PATH LC_ALL=C
red() {
    echo "link_line RED: $*" >&2
    exit 1
}

# The stand-in zigs, one per link: one line per argument, then a line
# `----` per run, written to $K/<link>.argv.
for n in mojo branch; do
    "$BB" mkdir -p "$K/zig_$n"
    cat >"$K/zig_$n/zig" <<EOF
#!$BB sh
for a in "\$@"; do printf '%s\n' "\$a"; done >>"$K/$n.argv"
printf '%s\n' ---- >>"$K/$n.argv"
exec "$ZIG/zig" "\$@"
EOF
    chmod +x "$K/zig_$n/zig"
done

# 1. The release build of the test, through the wrapper.
cp "$SRC" "$K/src/tests/${SRC##*/}"
"$BB" sh "$WRAPPER" "$BB" "$TC" "$K/zig_mojo" "$TARGET" "--source-root=$K/src" -- \
    build --optimization-level 0 --target-cpu "$CPU" --debug-level line-tables "$@" \
    "$K/src/tests/${SRC##*/}" -o "$K/mojo.exe" >"$K/mojo.log" 2>&1 ||
    red "mojo_wrapper.sh could not build ${SRC##*/}: $(tail -n 5 "$K/mojo.log" | tr '\n' ' ')"

# 2. The branch coverage link of its bitcode.
"$BB" sh "$LINK/cov_branch_link.sh" "$BB" "$TC" "$K/zig_branch" "$TARGET" \
    "$BC" "$K/branch.exe" >"$K/branch.log" 2>&1 ||
    red "cov_branch_link.sh could not link ${BC##*/}: $(tail -n 5 "$K/branch.log" | tr '\n' ' ')"

# One zig run each, normalised; the branch line without its runtime.
norm() { # argv file, object pattern -> the normalised line, one argument per line
    [ "$(grep -c -x -- ---- "$1")" = 1 ] || red "${1##*/}: zig ran $(grep -c -x -- ---- "$1") times, not once"
    awk -v tc="$TC" -v tgt="$TARGET" -v obj="$2" '
        $0 == "----" { next }
        after_o { print "<out>"; after_o = 0; next }
        $0 == "-o" { after_o = 1 }
        $0 == tgt { print "<target>"; next }
        $0 ~ obj { print "<object>"; next }
        /\/libclang_rt\.profile-x86_64\.a$/ { print "<runtime>"; next }
        index($0, tc "/") == 1 { print "<TC>/" substr($0, length(tc) + 2); next }
        { print }' "$1"
}
norm "$K/mojo.argv" '/mojo_archive-[^/]*\.a$' >"$K/mojo.line"
norm "$K/branch.argv" '/cov_branch_link/pg\.o$' >"$K/branch.full"
awk '
    $0 == "-Wl,--whole-archive" && !seen { held = 1; seen = 1; next }
    held && $0 == "-Wl,--no-whole-archive" { held = 0; next }
    held && $0 == "<runtime>" { rt = 1; next }
    held { print "<unexpected in the whole archive> " $0; next }
    { print }
    END { if (!rt) print "<no profile runtime>" }' "$K/branch.full" >"$K/branch.line"
if ! cmp -s "$K/mojo.line" "$K/branch.line"; then
    red "the branch coverage link is not the release link plus the profile runtime: release: $(tr '\n' ' ' <"$K/mojo.line")| branch: $(tr '\n' ' ' <"$K/branch.line")"
fi
{
    echo "release (mojo build through mojo_wrapper.sh's cc shim):"
    cat "$K/mojo.line"
    echo "branch coverage (cov_branch_link.sh):"
    cat "$K/branch.full"
} >"$OUT"
rm -rf "$K"
