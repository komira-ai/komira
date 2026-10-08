#!/bin/sh
# The checks of the LLVM pieces of branch coverage, each mode one build
# action of a validation target (defs.bzl, README.md "Checks"):
#   sh check.sh <mode> <busybox> <zig_dir> <report_dir> <lld_dir or -> <tools_dir or -> <fixture_dir or -> <key>=<value>...
# The <key>=<value> arguments are what the mode expects (the `want` of the
# target). Exits 1 on the first wrong result, naming it; otherwise writes
# <report_dir>/validation.json, the validation result, and what it measured.
#
# `lld`, against <lld_dir> (want: lld=<major>):
#   1. The directory holds bin/lld, lib/libgcc_s.so.1 and lib/libstdc++.so.6,
#      regular files, nothing else.
#   2. With LD_LIBRARY_PATH set to a directory of decoys (a text file named
#      like each of its libraries, as a test runner sets LD_LIBRARY_PATH),
#      the loader resolves bin/lld's libraries to its own lib/ and glibc,
#      nothing else.
#   3. `lld -flavor gnu --version` prints `LLD <major>.`.
# `tools`, against <tools_dir> (want: profdata=<version>,
# symbols=<name>,<name>...):
#   1. The directory holds bin/llvm-profdata, bin/llvm-nm, their libraries
#      under lib/ and runtime/libclang_rt.profile-x86_64.a, regular files,
#      nothing else.
#   2. The loader resolves the libraries of both programs as in lld 2.
#   3. `llvm-profdata --version` prints `LLVM version <version>`.
#   4. The runtime is an ar archive that defines each of <symbols>
#      (llvm-nm --defined-only).
# `raw_version`, against both and <fixture_dir> (want: functions=<n>,
# counts=<function>:<count>,<count>..., raw=<raw>, triple=<zig triple>),
# the version coupling of README.md:
#   1. zig cc compiles fixtures/profile_fixture.c to LLVM bitcode.
#   2. Mojo's lld instruments it as a coverage build does (`-r`,
#      `pgo-instr-gen,instrprof,default<O0>`). The instrumented object
#      defines __llvm_profile_raw_version strongly (llvm-nm: not U, W, V or
#      a local), and the runtime archive defines it only weakly: the version
#      the runtime writes is the instrumenter's, not the runtime's default.
#   3. zig cc links it with the profile runtime (whole archive); it runs,
#      exits 0 and writes its raw profile.
#   4. The raw profile starts with the 64-bit raw magic; its version field
#      is read, and its variant flags carry the IR-instrumentation bit
#      (0x01000000 of the high word), which only the instrumenter's
#      definition sets: the runtime's default has no flags.
#   5. llvm-profdata merges it: the raw version the LLVM 24 instrumentation
#      wrote is one this llvm-profdata accepts. Otherwise: `raw profile
#      version <N> not accepted by llvm-profdata <version>, which expects
#      <M>` when llvm-profdata reports LLVM's `raw profile version mismatch`,
#      and `llvm-profdata merge failed on ...` for any other refusal. The
#      version it accepted must be <raw> (RAW_PROFILE_VERSION of defs.bzl,
#      which every branch coverage run requires of each raw profile).
#   6. `llvm-profdata show` reports <functions> functions, and <function>'s
#      counters hold <count>... (sorted: the order is the instrumentation's).
#   7. The same profile with its version field set to <N>+1 is refused by
#      5 as a version mismatch, with llvm-profdata expecting <N>: the check
#      of 5 can fail, and tells a version refusal from any other.
# Every pipeline fails when any of its stages fails (pipefail). A grep that
# ends a pipeline reads to the end (`>/dev/null`, not `-q`).
set -eu
# shellcheck disable=SC3040 # busybox sh (ash) has pipefail
set -o pipefail
# No word here is a pathname pattern: an unquoted expansion (a list of names,
# the <key>=<value> expectations) is split into words and never globbed.
set -f

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
opt() { case "$1" in -) printf '' ;; *) abs "$1" ;; esac; }
MODE=$1
BB=$(abs "$2")
ZIG=$(abs "$3")/zig
REPORT=$(abs "$4")
LLD_DIR=$(opt "$5")
TOOLS_DIR=$(opt "$6")
FIX=$(opt "$7")
shift 7

case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.llvm_branch_$MODE" ;;
    /*) T="$BUCK_SCRATCH_PATH/llvm_branch_$MODE" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/llvm_branch_$MODE" ;;
esac
"$BB" mkdir -p "$T/bin" "$T/home"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
ZIG_GLOBAL_CACHE_DIR="$T/zig-global"
ZIG_LOCAL_CACHE_DIR="$T/zig-local"
HOME="$T/home"
export PATH LC_ALL=C ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR HOME
mkdir -p "$REPORT"
N=0

red() {
    echo "llvm_branch $MODE RED: $*" >&2
    [ -f "$T/log" ] && { echo "--- log:" >&2; tail -n 40 "$T/log" >&2; }
    exit 1
}
pass() { N=$((N + 1)); }
green() {
    rm -rf "$T"
    printf '{"version": 1, "data": {"status": "success", "message": "llvm_branch %s: %s checks passed"}}\n' "$MODE" "$N" >"$REPORT/validation.json"
    echo "llvm_branch $MODE GREEN: $N checks"
}

# The value of <key> among the <key>=<value> arguments; fails when absent.
want() {
    for kv in $WANT; do
        case "$kv" in "$1="*) printf '%s' "${kv#*=}" && return 0 ;; esac
    done
    red "no '$1=' expectation given"
}
WANT="$*"

# Fails unless <dir> holds exactly the files <path>... (regular files; no
# link, no other file).
exactly() {
    dir=$1
    shift
    printf '%s\n' "$@" | sort >"$T/want.txt"
    (cd "$dir" && find . ! -type d | sed 's|^\./||' | sort) >"$T/got.txt"
    diff "$T/want.txt" "$T/got.txt" >"$T/log" 2>&1 || red "$dir does not hold exactly its files (diff: - missing, + extra)"
    links=$(cd "$dir" && find . -type l)
    [ -z "$links" ] || red "$dir holds symbolic links: $links"
}

# Status 0 when <path> is a glibc library (by name) at an absolute path
# outside <dir> and <decoy>.
glibc_outside() {
    case "${1##*/}" in
        libc.so.6 | libm.so.6 | libdl.so.2 | libpthread.so.0 | librt.so.1 | ld-linux-x86-64.so.2) ;;
        *) return 1 ;;
    esac
    case "$1" in
        "$2"/* | "$3"/*) return 1 ;;
        /*) return 0 ;;
    esac
    return 1
}

# Fails unless the loader, with LD_LIBRARY_PATH set to decoys named like each
# <own> library, resolves every library of <dir>/<exe> to <dir>/lib/<own>
# (through bin/'s $ORIGIN/../lib, possibly with lib/'s own `$ORIGIN/.`) or
# to a glibc library outside <dir>, and nothing else.
closure() {
    dir=$1
    exe=$2
    shift 2
    decoy="$T/decoy"
    mkdir -p "$decoy"
    for o in "$@"; do echo "decoy" >"$decoy/$o"; done
    LD_LIBRARY_PATH="$decoy" LD_TRACE_LOADED_OBJECTS=1 "$dir/$exe" >"$T/log" 2>&1 || red "the loader failed for $exe under a decoy LD_LIBRARY_PATH"
    cp "$T/log" "$REPORT/$(basename "$exe").loads.txt"
    while read -r name arrow path _; do
        case "$name" in linux-vdso.so.1 | /lib64/ld-linux-x86-64.so.2) continue ;; esac
        if [ "$arrow" = "=>" ]; then
            rel=${path#"$dir"/bin/../lib/}
            while [ "${rel#./}" != "$rel" ]; do rel=${rel#./}; done
            for o in "$@"; do
                [ "$name" = "$o" ] && [ "$rel" = "$o" ] && continue 2
            done
            glibc_outside "$path" "$dir" "$decoy" && continue
        fi
        red "$exe loads '$name $arrow $path': neither its own lib/$name nor glibc (README.md, Checks)"
    done <"$T/log"
}

# ---- lld -----------------------------------------------------------------------

lld() {
    major=$(want lld)
    exactly "$LLD_DIR" bin/lld lib/libgcc_s.so.1 lib/libstdc++.so.6
    [ -x "$LLD_DIR/bin/lld" ] || red "bin/lld is not executable"
    pass
    closure "$LLD_DIR" bin/lld libgcc_s.so.1 libstdc++.so.6
    pass
    "$LLD_DIR/bin/lld" -flavor gnu --version >"$T/log" 2>&1 || red "lld -flavor gnu --version failed"
    cp "$T/log" "$REPORT/lld_version.txt"
    grep -F "LLD $major." "$T/log" >/dev/null ||
        red "lld -flavor gnu --version does not print 'LLD $major.': the Mojo package's lld is another LLVM. A new Mojo is a new instrumenter: re-run the version coupling (README.md, Updating) before changing lld= in BUCK"
    pass
    green
}

# ---- tools -----------------------------------------------------------------------

LIBS23="libLLVM.so.23.1 libgcc_s.so.1 libiconv.so.2 libstdc++.so.6 libxml2.so.16 libz.so.1 libzstd.so.1"
RUNTIME=runtime/libclang_rt.profile-x86_64.a

tools() {
    version=$(want profdata)
    symbols=$(want symbols)
    # shellcheck disable=SC2086,SC2046 # LIBS23 is a list of names, which hold no space
    exactly "$TOOLS_DIR" bin/llvm-nm bin/llvm-profdata $RUNTIME $(for l in $LIBS23; do echo "lib/$l"; done)
    [ -x "$TOOLS_DIR/bin/llvm-profdata" ] && [ -x "$TOOLS_DIR/bin/llvm-nm" ] || red "bin/llvm-profdata or bin/llvm-nm is not executable"
    pass
    for exe in bin/llvm-profdata bin/llvm-nm; do
        # shellcheck disable=SC2086 # LIBS23 is a list of names
        closure "$TOOLS_DIR" "$exe" $LIBS23
    done
    pass
    "$TOOLS_DIR/bin/llvm-profdata" --version >"$T/log" 2>&1 || red "llvm-profdata --version failed"
    cp "$T/log" "$REPORT/profdata_version.txt"
    grep -F "LLVM version $version" "$T/log" >/dev/null ||
        red "llvm-profdata --version does not print 'LLVM version $version' (the profdata= of BUCK)"
    pass
    head -c 8 "$TOOLS_DIR/$RUNTIME" >"$T/magic"
    printf '!<arch>\n' | cmp -s - "$T/magic" || red "$RUNTIME is not an ar archive"
    "$TOOLS_DIR/bin/llvm-nm" -g --defined-only "$TOOLS_DIR/$RUNTIME" >"$T/nm.txt" 2>"$T/log" || red "llvm-nm failed on $RUNTIME"
    for s in $(echo "$symbols" | tr ',' ' '); do
        awk -v s="$s" '$NF == s && NF == 3 { found = 1 } END { exit !found }' "$T/nm.txt" ||
            red "$RUNTIME does not define $s: it is not the profile runtime a coverage build links"
    done
    pass
    green
}

# ---- raw_version -------------------------------------------------------------

# The raw profile <file>'s version field (the low 32 bits of the second
# 64-bit word; the high bits are variant flags), after checking the 64-bit
# raw magic.
raw_version() {
    magic=$(od -A n -t x8 -N 8 "$1" | tr -d ' \n')
    [ "$magic" = "ff6c70726f667281" ] || red "$1 does not start with the 64-bit raw profile magic (got '$magic')"
    od -A n -t u4 -j 8 -N 4 "$1" | tr -d ' \n'
}

# Status 0 when llvm-profdata merges the raw profile <file> into <out>;
# otherwise prints why and returns 1. A refusal is a version refusal only
# when llvm-profdata says so in LLVM's words (`raw profile version
# mismatch: ... expected version = <M>`); the log also holds <file>'s path,
# which may contain any word. Run it in a command substitution: its
# variables (av, pv, ev) stay in that subshell.
accepts() {
    av=$(raw_version "$1")
    if "$TOOLS_DIR/bin/llvm-profdata" merge -o "$2" "$1" >"$T/merge.log" 2>&1; then return 0; fi
    pv=$("$TOOLS_DIR/bin/llvm-profdata" --version | sed -n 's/^ *LLVM version //p')
    if grep -F "raw profile version mismatch" "$T/merge.log" >/dev/null; then
        ev=$(sed -n 's/^.*; expected version = \([0-9][0-9]*\).*$/\1/p' "$T/merge.log" | tr '\n' ' ')
        echo "raw profile version $av not accepted by llvm-profdata $pv, which expects ${ev% }: $(head -n 2 "$T/merge.log" | tr '\n' ' ')"
    else
        echo "llvm-profdata merge failed on $1 (raw version $av): $(head -n 2 "$T/merge.log" | tr '\n' ' ')"
    fi
    return 1
}

# Writes the byte <value> (1 to 255) at byte <offset> of <file>.
poke8() {
    printf "\\$(printf %03o "$3")" | dd of="$1" bs=1 seek="$2" count=1 conv=notrunc 2>"$T/log"
}

raw_version_mode() {
    functions=$(want functions)
    counts=$(want counts)
    raw=$(want raw)
    triple=$(want triple)
    W="$T/w"
    mkdir -p "$W"
    "$ZIG" cc -target "$triple" -c -emit-llvm -O0 -g0 -fno-sanitize=undefined "$FIX/profile_fixture.c" -o "$W/fixture.bc" >"$T/log" 2>&1 ||
        red "zig cc could not compile the fixture to bitcode"
    [ "$(od -A n -t x1 -N 4 "$W/fixture.bc" | tr -d ' \n')" = "4243c0de" ] || red "zig cc -emit-llvm did not write LLVM bitcode"
    pass
    "$LLD_DIR/bin/lld" -flavor gnu -r -m elf_x86_64 "$W/fixture.bc" -o "$W/pg.o" --lto-O0 \
        "--lto-newpm-passes=pgo-instr-gen,instrprof,default<O0>" >"$T/log" 2>&1 || red "lld could not instrument the fixture"
    # Who defines the version the runtime writes: the instrumented object
    # strongly, the runtime archive weakly (llvm-nm classes: an upper-case
    # letter is global; U is undefined, W and V are weak).
    "$TOOLS_DIR/bin/llvm-nm" "$W/pg.o" >"$W/pg.nm" 2>"$T/log" || red "llvm-nm failed on the instrumented fixture"
    pg_class=$(awk '$NF == "__llvm_profile_raw_version" && NF == 3 { printf "%s ", $2 }' "$W/pg.nm")
    case "$pg_class" in
        [ABDGRST]" ") ;;
        *) red "the instrumented fixture does not define __llvm_profile_raw_version strongly (llvm-nm class '${pg_class% }'): the version in the raw profile would be the runtime's default, not LLVM 24's" ;;
    esac
    "$TOOLS_DIR/bin/llvm-nm" --defined-only "$TOOLS_DIR/$RUNTIME" >"$W/rt.nm" 2>"$T/log" || red "llvm-nm failed on $RUNTIME"
    rt_class=$(awk '$NF == "__llvm_profile_raw_version" && NF == 3 { printf "%s ", $2 }' "$W/rt.nm")
    case "$rt_class" in
        [VW]" ") ;;
        *) red "$RUNTIME does not define __llvm_profile_raw_version once and weakly (llvm-nm classes '${rt_class% }'): it would override or clash with the instrumenter's" ;;
    esac
    printf '__llvm_profile_raw_version: instrumented fixture %s, runtime %s\n' "${pg_class% }" "${rt_class% }" >"$REPORT/raw_version_symbol.txt"
    pass
    "$ZIG" cc -target "$triple" "$W/pg.o" -Wl,--whole-archive "$TOOLS_DIR/$RUNTIME" -Wl,--no-whole-archive -o "$W/pg.exe" >"$T/log" 2>&1 ||
        red "zig cc could not link the instrumented fixture with the profile runtime"
    rc=0
    LLVM_PROFILE_FILE="$W/pg.profraw" "$W/pg.exe" >"$T/log" 2>&1 || rc=$?
    [ "$rc" = 0 ] || red "the instrumented fixture exited $rc"
    [ -s "$W/pg.profraw" ] || red "the instrumented fixture wrote no raw profile"
    pass
    v=$(raw_version "$W/pg.profraw")
    flags=$(od -A n -t x4 -j 12 -N 4 "$W/pg.profraw" | tr -d ' \n')
    printf 'raw profile version %s, variant flags 0x%s\n' "$v" "$flags" >"$REPORT/raw_version.txt"
    [ $((0x$flags & 0x01000000)) != 0 ] ||
        red "the raw profile's variant flags 0x$flags lack the IR-instrumentation bit 0x01000000: its version word is the runtime's default, not the instrumenter's"
    pass
    why=$(accepts "$W/pg.profraw" "$W/pg.profdata") || red "$why (README.md, The version coupling)"
    [ "$v" = "$raw" ] ||
        red "llvm-profdata accepts raw version $v, but RAW_PROFILE_VERSION of defs.bzl, which every branch coverage run requires of each raw profile, is $raw: change it to $v (README.md, Updating)"
    pass
    "$TOOLS_DIR/bin/llvm-profdata" show "$W/pg.profdata" >"$T/log" 2>&1 || red "llvm-profdata show failed"
    cp "$T/log" "$REPORT/show.txt"
    grep -x "Total functions: $functions" "$T/log" >/dev/null || red "llvm-profdata show does not report 'Total functions: $functions'"
    fn=${counts%%:*}
    "$TOOLS_DIR/bin/llvm-profdata" show --counts --function="$fn" "$W/pg.profdata" >"$T/log" 2>&1 || red "llvm-profdata show --function=$fn failed"
    cp "$T/log" "$REPORT/show_$fn.txt"
    got=$(sed -n 's/^ *Block counts: \[\(.*\)\]$/\1/p' "$T/log" | tr -d ' ' | tr ',' '\n' | sort -n | tr '\n' ',')
    [ "$got" = "${counts#*:}," ] || red "llvm-profdata show reports the counters of $fn as '$got', not '${counts#*:}'"
    pass
    # The version is the low byte of a little-endian field whose next three
    # bytes are 0 (a version of 255 or more would need more than one byte).
    [ "$v" -lt 255 ] || red "raw version $v does not fit the one-byte doctoring of check 7"
    cp "$W/pg.profraw" "$W/doctored.profraw"
    poke8 "$W/doctored.profraw" 8 $((v + 1)) || red "dd could not write the doctored profile"
    [ "$(raw_version "$W/doctored.profraw")" = $((v + 1)) ] || red "could not write version $((v + 1)) into the doctored profile"
    if why=$(accepts "$W/doctored.profraw" "$W/doctored.profdata"); then
        red "llvm-profdata accepted raw version $((v + 1)): the version check cannot fail"
    fi
    case "$why" in
        "raw profile version $((v + 1)) not accepted by llvm-profdata "*", which expects $v: "*) ;;
        *) red "the doctored profile was refused, but not for its version: $why" ;;
    esac
    echo "doctored: $why" >>"$REPORT/raw_version.txt"
    pass
    green
}

case "$MODE" in
    lld) [ -n "$LLD_DIR" ] || red "lld needs <lld_dir>" ;;
    tools) [ -n "$TOOLS_DIR" ] || red "tools needs <tools_dir>" ;;
    raw_version) [ -n "$LLD_DIR" ] && [ -n "$TOOLS_DIR" ] && [ -n "$FIX" ] || red "raw_version needs <lld_dir>, <tools_dir> and <fixture_dir>" ;;
    *) red "unknown mode '$MODE'" ;;
esac
case "$MODE" in
    raw_version) raw_version_mode ;;
    *) "$MODE" ;;
esac
