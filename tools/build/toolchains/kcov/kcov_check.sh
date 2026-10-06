#!/bin/sh
# The checks of the kcov distribution, each mode one build action of a
# validation target (defs.bzl, README.md "Checks"):
#   sh kcov_check.sh check <busybox> <zig_dir> <report_dir> <kcov_dir> <kcov.tar.gz>
#       <strip_prefix> <fixture_dir> <version> <zig_triple> <glibc_floor_minor>
#   sh kcov_check.sh cases <busybox> <zig_dir> <report_dir> <elf_rpath> <conda_payload>
#       <fixture_dir> <zig_triple> <glibc_floor_minor>
#   sh kcov_check.sh same  <busybox> - <report_dir> <dir_a> <dir_b>
#   sh kcov_check.sh identity <busybox> - <report_dir> <kcov_dir> <sha256> <usage_line>
# Exits 1 on the first wrong result, naming it; otherwise writes
# <report_dir>/validation.json, the validation result (and, for `check`, the
# fixture's reports).
#
# `check`, against the built kcov, with LD_LIBRARY_PATH set to a directory of
# decoys (files named like each library kcov could want, none of them ELF),
# as the test runner sets it to the Mojo toolchain's lib/:
#   1. The distribution holds bin/kcov, lib/libgcc_s.so.1 and the licence
#      files under share/licenses/, nothing else, and kcov's licence files
#      are the source archive's.
#   2. No GLIBC_2.<n> symbol version above the floor in bin/kcov (with the
#      libraries it embeds) or lib/.
#   3. bin/kcov imports from libgcc_s.so.1 (version GCC_3.0).
#   4. The loader resolves, for bin/kcov, its own lib/libgcc_s.so.1 and
#      glibc libraries from outside the distribution and the decoys, nothing
#      else.
#   5. `kcov --version` prints `kcov <version>`.
#   6. kcov run on fixtures/cov_fixture.c (zig cc -g -O0) reports each
#      COV:hit line hit and each COV:miss line missed, and the report, with
#      the source directory and the timestamp normalized, is
#      fixtures/cov_fixture.cobertura.xml byte for byte.
#   7. In that run the loader searched the DT_RPATH of bin/kcov and
#      initialised its lib/libgcc_s.so.1 and glibc libraries from outside the
#      distribution and the decoys, nothing else; and in the traced fixture
#      it initialised the preload library kcov wrote (libkcov_sowrapper.so).
#   8. kcov run as the coverage variant runs it, on fixtures/cov_fixture.c
#      and fixtures/cov_part.c compiled with their directory mapped to a
#      placeholder `/_..._` that exists nowhere:
#      `--replace-src-path=^/_+:<root>` (a regex, kcov's std::regex, so zig's
#      libc++) and `--configure=cobertura-full-paths=1`. Each COV line is
#      reported as marked in its file, and the normalized report is
#      fixtures/cov_fixture_relocated.cobertura.xml byte for byte.
#   9. The HTML report writes the data files of the source archive's data/
#      byte for byte (the arrays kcov_build.sh generated from them).
# `cases` runs the functions behind 2, 4 and 7, and elf_rpath and
# conda_payload, and the mode `identity` (in its own process), on inputs
# whose answer is known, wrong ones included.
# `same` compares two builds of the distribution: same files, modes, bytes.
# `identity` requires that bin/kcov is what the package guard refuses
# (tools/build/package/kcov_guard.sh): its sha256 is <sha256> and it holds
# <usage_line>, the two constants of identity.bzl.
# Every pipeline fails when any of its stages fails (pipefail), so a stage
# that cannot read its input never passes as an empty result. A grep that
# ends a pipeline reads to the end (`>/dev/null`, not `-q`): `-q` exits at
# the first match, and the stage before it would then fail on the closed
# pipe.
set -eu
# shellcheck disable=SC3040 # busybox sh (ash) has pipefail; :kcov_check_cases fails without it
set -o pipefail

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
MODE=$1
BB=$(abs "$2")
case "$3" in
    -) ZIG="" ;;
    *) ZIG=$(abs "$3")/zig ;;
esac
REPORT=$(abs "$4")
# This script, for the cases that run a mode of it in its own process.
SELF=$(abs "$0")
shift 4

case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.kcov_$MODE" ;;
    /*) T="$BUCK_SCRATCH_PATH/kcov_$MODE" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/kcov_$MODE" ;;
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
    echo "kcov_check $MODE RED: $*" >&2
    [ -f "$T/log" ] && { echo "--- log:" >&2; tail -n 40 "$T/log" >&2; }
    exit 1
}
pass() { N=$((N + 1)); }
green() {
    rm -rf "$T"
    printf '{"version": 1, "data": {"status": "success", "message": "kcov_check %s: %s checks passed"}}\n' "$MODE" "$N" >"$REPORT/validation.json"
    echo "kcov_check $MODE GREEN: $N checks"
}

# ---- The checks, as functions of their subject ------------------------------

# The decoy directory <dir>: a file named like each library in <name>...,
# holding text, so the loader fails loudly if it ever maps one.
decoys() {
    d=$1
    shift
    mkdir -p "$d"
    for n in "$@"; do echo "decoy" >"$d/$n"; done
}

# The GLIBC_2.<n> versions above GLIBC_2.<floor> that <file>... name, one per
# line (none: empty). Version names are strings of the dynamic string table,
# so this also reads the libraries kcov embeds as byte arrays. Fails when a
# stage does (a <file> it cannot read); grep finding no version is not a
# failure.
glibc_over() {
    floor=$1
    shift
    cat "$@" | strings -n 8 | { grep -o 'GLIBC_2\.[0-9][0-9.]*' || [ "$?" = 1 ]; } | sort -u | awk -F. -v f="$floor" '$2 + 0 > f + 0 { print }'
}

# The loader's list of what <exe> loads, with LD_LIBRARY_PATH=<decoy>, into
# <out>. Status 1 when the loader fails (it mapped a decoy) or names one.
trace_loads() {
    LD_LIBRARY_PATH="$2" LD_TRACE_LOADED_OBJECTS=1 "$1" >"$3" 2>&1 || return 1
    if grep -q "$2" "$3"; then return 1; fi
    return 0
}

# The LD_DEBUG_OUTPUT file of <prefix>.* that searched <exe>'s DT_RPATH
# ("RPATH from file"; a DT_RUNPATH reads "RUNPATH from file"), or nothing.
rpath_record() {
    for f in "$2".*; do
        [ -f "$f" ] && grep -qF "(RPATH from file $1)" "$f" && { echo "$f"; return 0; }
    done
    return 0
}

# Status 0 when <path> is a glibc library (by name) at an absolute path
# outside the program's directory <dir> and the decoy directory <decoy>.
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

# The first entry of the loader's list <ldd> (LD_TRACE_LOADED_OBJECTS) of a
# program in <dir>/bin that is neither one of its own libraries <own>...
# (<dir>/bin/../lib/<own>) nor a glibc library outside <dir> and <decoy>;
# nothing when there is none.
ldd_stray() {
    ldd=$1
    dir=$2
    decoy=$3
    shift 3
    while read -r name arrow path _; do
        case "$name" in linux-vdso.so.1 | /lib64/ld-linux-x86-64.so.2) continue ;; esac
        if [ "$arrow" = "=>" ]; then
            for o in "$@"; do
                [ "$name" = "$o" ] && [ "$path" = "$dir/bin/../lib/$o" ] && continue 2
            done
            glibc_outside "$path" "$dir" "$decoy" && continue
        fi
        echo "$name $arrow $path"
        return 0
    done <"$ldd"
    return 0
}

# The first path in <inits> (the objects an LD_DEBUG=libs record initialised,
# one per line) of a program in <dir>/bin that is neither one of its own
# libraries <own>... nor a glibc library outside <dir> and <decoy>; nothing
# when there is none.
inits_stray() {
    inits=$1
    dir=$2
    decoy=$3
    shift 3
    while read -r path; do
        for o in "$@"; do
            [ "$path" = "$dir/bin/../lib/$o" ] && continue 2
        done
        glibc_outside "$path" "$dir" "$decoy" && continue
        echo "$path"
        return 0
    done <"$inits"
    return 0
}

# Fails unless, in the Cobertura report <xml>, the class of the source file
# <dir>/<file> reports each line marked COV:hit hit and each COV:miss missed.
markers() {
    xml=$1
    dir=$2
    file=$3
    sed -n "/<class [^>]*filename=\"[^\"]*\\/$file\"/,/<\\/class>/p" "$xml" >"$T/class"
    [ -s "$T/class" ] || red "$file is not in ${xml#"$T"/} (by its full path): $(cat "$xml")"
    for kind in hit miss; do
        lines=$(grep -n "/\* COV:$kind \*/" "$dir/$file" | cut -d: -f1) || red "$file has no COV:$kind line (or cannot be read)"
        [ -n "$lines" ] || red "$file has no COV:$kind line"
        for l in $lines; do
            case "$kind" in
                hit) grep -q "<line number=\"$l\" hits=\"[1-9][0-9]*\"/>" "$T/class" || red "$file line $l (COV:hit) is not reported as hit: $(grep '<line ' "$T/class")" ;;
                miss) grep -q "<line number=\"$l\" hits=\"0\"/>" "$T/class" || red "$file line $l (COV:miss) is not reported as missed: $(grep '<line ' "$T/class")" ;;
            esac
        done
    done
}

# <xml> with the directory <dir> written <name> and the timestamp 0, into <out>.
normalize() {
    re=$(printf '%s' "$2" | sed 's/[][\\.*^$|]/\\&/g')
    sed -e "s|$re|$3|g" -e 's/timestamp="[0-9]*"/timestamp="0"/' "$1" >"$4"
}

# ---- check -------------------------------------------------------------------

check() {
    KDIR=$(abs "$1")
    ARCHIVE=$(abs "$2")
    PREFIX=$3
    FIX=$(abs "$4")
    VERSION=$5
    TRIPLE=$6
    FLOOR=$7
    KCOV="$KDIR/bin/kcov"
    OWN="$KDIR/bin/../lib/libgcc_s.so.1"
    DECOY="$T/decoy"
    decoys "$DECOY" libz.so.1 libdw.so.1 libelf.so.1 liblzma.so.5 libbz2.so.1.0 libzstd.so.1 libcurl.so.4 libstdc++.so.6 libgcc_s.so.1
    mkdir -p "$T/src"
    tar -xzf "$ARCHIVE" -C "$T/src" "$PREFIX/data" "$PREFIX/COPYING" "$PREFIX/COPYING.externals"
    UP="$T/src/$PREFIX"

    # 1. The files of the distribution. A file in lib/ is searched before
    # LD_LIBRARY_PATH and before the system (DT_RPATH), whatever its name.
    (cd "$KDIR" && find . ! -type d | sort) >"$T/files"
    printf '%s\n' ./bin/kcov ./lib/libgcc_s.so.1 ./share/licenses/NOTICE ./share/licenses/kcov/COPYING \
        ./share/licenses/kcov/COPYING.externals >"$T/want"
    cmp "$T/want" "$T/files" >/dev/null 2>&1 || red "the distribution holds $(tr '\n' ' ' <"$T/files"), want $(tr '\n' ' ' <"$T/want")"
    for f in COPYING COPYING.externals; do
        cmp "$UP/$f" "$KDIR/share/licenses/kcov/$f" >/dev/null 2>&1 || red "share/licenses/kcov/$f is not the source archive's $f"
    done
    pass

    # 2. glibc floor (the static checks first)
    cat "$KCOV" "$KDIR"/lib/* | strings -n 8 | grep 'GLIBC_2\.' >/dev/null || red "no GLIBC_ symbol version in bin/kcov: not a glibc binary?"
    over=$(glibc_over "$FLOOR" "$KCOV" "$KDIR"/lib/*) || red "glibc_over failed on bin/kcov or lib/"
    [ -z "$over" ] || red "bin/kcov or lib/ needs $over, above the floor GLIBC_2.$FLOOR"
    pass

    # 3. The unwinder. glibc's pthread_cancel unwinds kcov's threads with
    # libgcc_s.so.1; kcov's C++ frames must name the same unwinder. This
    # sees one GCC_3.0 import, not where every _Unwind_* comes from: the
    # run of check 6 ends in pthread_cancel, and a second unwinder crashes it.
    strings -n 7 "$KCOV" | grep -x 'GCC_3\.0' >/dev/null ||
        red "bin/kcov imports no GCC_3.0 symbol from libgcc_s.so.1: its _Unwind_* are another unwinder's (README.md, The unwinder)"
    pass

    # 4. what the loader resolves
    trace_loads "$KCOV" "$DECOY" "$T/ldd" || red "the loader took a decoy from LD_LIBRARY_PATH for bin/kcov: $(cat "$T/ldd")"
    grep -q "^[[:space:]]*libgcc_s.so.1 => $OWN " "$T/ldd" || red "bin/kcov does not load libgcc_s.so.1 from its own lib/: $(cat "$T/ldd")"
    stray=$(ldd_stray "$T/ldd" "$KDIR" "$DECOY" libgcc_s.so.1)
    [ -z "$stray" ] || red "bin/kcov loads $stray, which is neither glibc from the system nor its own lib/libgcc_s.so.1: $(cat "$T/ldd")"
    pass

    # 5. version
    v=$(LD_LIBRARY_PATH="$DECOY" "$KCOV" --version 2>"$T/log") || red "kcov --version failed"
    [ "$v" = "kcov $VERSION" ] || red "kcov --version printed '$v', want 'kcov $VERSION'"
    pass

    # 6. A coverage run, with kcov's defaults and --cobertura-only. The
    # fixture is copied to a real directory: kcov reports the realpath of a
    # source file and drops one it cannot open.
    SRC="$T/fixture"
    mkdir -p "$SRC"
    cp "$FIX/cov_fixture.c" "$SRC/cov_fixture.c"
    SRC=$(realpath "$SRC")
    (cd "$SRC" && "$ZIG" cc -target "$TRIPLE" -g -O0 -fno-sanitize=undefined cov_fixture.c -o "$T/cov_fixture") >"$T/log" 2>&1 ||
        red "zig cc of the fixture failed"
    LD_DEBUG=libs LD_DEBUG_OUTPUT="$T/lddebug" LD_LIBRARY_PATH="$DECOY" \
        "$KCOV" --cobertura-only "--include-path=$SRC" "$T/kout" "$T/cov_fixture" >"$T/log" 2>&1 ||
        red "kcov run failed"
    grep -q '^cov_fixture 2$' "$T/log" || red "the fixture's output is missing under kcov"
    # With --cobertura-only, kcov v42 writes <out>/cov.xml only (its writer
    # names it for an editor plugin), not <out>/<binary>/cobertura.xml.
    XML="$T/kout/cov.xml"
    [ -s "$XML" ] || red "kcov wrote no cov.xml: $(find "$T/kout")"
    cp "$XML" "$REPORT/cov.xml"
    markers "$XML" "$SRC" cov_fixture.c
    normalize "$XML" "$SRC" @SRC@ "$REPORT/cov.normalized.xml"
    diff "$FIX/cov_fixture.cobertura.xml" "$REPORT/cov.normalized.xml" >"$T/log" 2>&1 ||
        red "the fixture's report is not fixtures/cov_fixture.cobertura.xml (normalized: @SRC@, timestamp 0)"
    pass

    # 7. The loader's records of that run (the traced fixture inherits
    # LD_DEBUG and writes a file of its own). kcov's is the one that searched
    # the DT_RPATH of bin/kcov.
    rec=$(rpath_record "$KCOV" "$T/lddebug")
    [ -n "$rec" ] || red "no loader record searched a DT_RPATH of bin/kcov: $(grep -h 'search path\|RUNPATH\|RPATH' "$T"/lddebug.* | head -n 20)"
    sed -n 's/.*calling init: //p' "$rec" | sort -u >"$T/inits"
    grep -qxF "$OWN" "$T/inits" || red "kcov did not initialise lib/libgcc_s.so.1 of its own directory: $(cat "$T/inits")"
    stray=$(inits_stray "$T/inits" "$KDIR" "$DECOY" libgcc_s.so.1)
    [ -z "$stray" ] || red "kcov loaded $stray, which is neither glibc from the system nor its own lib/libgcc_s.so.1: $(cat "$T/inits")"
    # The fixture's: kcov preloads the library it embeds (libkcov_sowrapper.so,
    # written to its output directory) to hear of shared libraries the
    # program loads. A loader that cannot map it ignores it with a warning,
    # and the run above still passes.
    found=""
    for f in "$T"/lddebug.*; do
        [ "$f" = "$rec" ] && continue
        grep -q 'calling init: .*/libkcov_sowrapper\.so$' "$f" && found=$f
    done
    [ -n "$found" ] || red "the fixture did not initialise the preload library libkcov_sowrapper.so: $(grep -h 'sowrapper' "$T"/lddebug.* | head -n 5)"
    pass

    # 8. The coverage variant's run (tools/build/coverage). Its binaries'
    # DWARF names their sources under a placeholder `/_..._` that never
    # exists, which kcov maps back to a source root (realpath first, then
    # the regex), and it writes full paths. The build directory is deleted
    # before the run, so only the mapping finds the sources.
    B="$T/reloc_build"
    ROOT="$T/srcroot"
    mkdir -p "$B" "$ROOT"
    cp "$FIX/cov_fixture.c" "$FIX/cov_part.c" "$B/"
    cp "$FIX/cov_fixture.c" "$FIX/cov_part.c" "$ROOT/"
    B=$(realpath "$B")
    ROOT=$(realpath "$ROOT")
    PH=/________________
    (cd "$B" && "$ZIG" cc -target "$TRIPLE" -g -O0 -fno-sanitize=undefined "-fdebug-prefix-map=$B=$PH" \
        cov_fixture.c cov_part.c -o "$T/cov_reloc") >"$T/log" 2>&1 || red "zig cc of the relocated fixture failed"
    rm -rf "$B"
    strings -n 8 "$T/cov_reloc" >"$T/reloc_strings"
    grep -qF "$PH" "$T/reloc_strings" || red "the relocated fixture's DWARF does not name the placeholder $PH"
    if grep -qF "$B" "$T/reloc_strings"; then red "the relocated fixture still names its build directory $B"; fi
    LD_LIBRARY_PATH="$DECOY" "$KCOV" --cobertura-only --configure=cobertura-full-paths=1 "--include-path=$ROOT" \
        "--replace-src-path=^/_+:$ROOT" "$T/rout" "$T/cov_reloc" >"$T/log" 2>&1 || red "kcov run of the relocated fixture failed"
    grep -q '^cov_fixture 2$' "$T/log" || red "the relocated fixture's output is missing under kcov"
    XML="$T/rout/cov.xml"
    [ -s "$XML" ] || red "kcov wrote no cov.xml for the relocated fixture: $(find "$T/rout")"
    cp "$XML" "$REPORT/cov_relocated.xml"
    if grep -qF "$PH" "$XML"; then red "the relocated report still names the placeholder: $(grep -F "$PH" "$XML")"; fi
    markers "$XML" "$ROOT" cov_fixture.c
    markers "$XML" "$ROOT" cov_part.c
    normalize "$XML" "$ROOT" @ROOT@ "$REPORT/cov_relocated.normalized.xml"
    diff "$FIX/cov_fixture_relocated.cobertura.xml" "$REPORT/cov_relocated.normalized.xml" >"$T/log" 2>&1 ||
        red "the relocated fixture's report is not fixtures/cov_fixture_relocated.cobertura.xml (normalized: @ROOT@, timestamp 0)"
    pass

    # 9. The HTML report (kcov's default output) and the arrays behind it.
    # The arrays of the bash and Python helpers and of kcov_system_lib are
    # not checked: the variant runs none of those engines.
    DATA="$UP/data"
    LD_LIBRARY_PATH="$DECOY" "$KCOV" "--include-path=$SRC" "$T/hout" "$T/cov_fixture" >"$T/log" 2>&1 || red "kcov run with the HTML report failed"
    [ -s "$T/hout/index.html" ] || red "the HTML report has no index.html: $(find "$T/hout")"
    for pair in amber.png=amber.png glass.png=glass.png bcov.css=bcov.css tablesorter-theme.css=tablesorter-theme.css \
        js/handlebars.js=js/handlebars.js js/kcov.js=js/kcov.js js/jquery.min.js=js/jquery.min.js \
        js/tablesorter.min.js=js/jquery.tablesorter.min.js \
        js/jquery.tablesorter.widgets.min.js=js/jquery.tablesorter.widgets.min.js; do
        cmp "$T/hout/data/${pair%%=*}" "$DATA/${pair#*=}" >"$T/log" 2>&1 ||
            red "the HTML report's data/${pair%%=*} is not the archive's data/${pair#*=}"
    done
    pass
    green
}

# ---- cases -------------------------------------------------------------------

# The bytes of the hex pairs <hh>... (busybox printf has octal escapes only).
bytes() {
    for h in "$@"; do
        # shellcheck disable=SC2059 # the format is the escape being built
        printf "\\$(printf '%03o' "$((0x$h))")"
    done
}

# Writes the bytes of the hex pairs <hh>... into <file> at byte <offset>.
poke() {
    f=$1
    at=$2
    shift 2
    bytes "$@" | dd of="$f" bs=1 seek="$at" conv=notrunc 2>/dev/null
}

# The file offset of the first entry tagged <tag> in the PT_DYNAMIC segment
# of the ELF64 little-endian <file>, or nothing.
dyn_tag_off() {
    dt_f=$1
    dt_want=$2
    dt_phoff=$(od -An -tu4 -j32 -N4 "$dt_f" | tr -d ' ')
    dt_phent=$(od -An -tu2 -j54 -N2 "$dt_f" | tr -d ' ')
    dt_phnum=$(od -An -tu2 -j56 -N2 "$dt_f" | tr -d ' ')
    dt_i=0
    while [ "$dt_i" -lt "$dt_phnum" ]; do
        dt_ph=$((dt_phoff + dt_i * dt_phent))
        if [ "$(od -An -tu4 -j"$dt_ph" -N4 "$dt_f" | tr -d ' ')" = 2 ]; then
            dt_at=$(od -An -tu4 -j$((dt_ph + 8)) -N4 "$dt_f" | tr -d ' ')
            dt_end=$((dt_at + $(od -An -tu4 -j$((dt_ph + 32)) -N4 "$dt_f" | tr -d ' ')))
            while [ $((dt_at + 16)) -le "$dt_end" ]; do
                # shellcheck disable=SC2046 # the two halves of d_tag
                set -- $(od -An -tu4 -j"$dt_at" -N8 "$dt_f")
                [ "$1" = 0 ] && [ "$2" = 0 ] && return 0
                [ "$1" = "$dt_want" ] && [ "$2" = 0 ] && { echo "$dt_at"; return 0; }
                dt_at=$((dt_at + 16))
            done
            return 0
        fi
        dt_i=$((dt_i + 1))
    done
}

# <n> as 2 or 4 little-endian bytes.
le16() { bytes "$(printf '%02x' $(($1 & 255)))" "$(printf '%02x' $(($1 >> 8 & 255)))"; }
le32() {
    le16 $(($1 & 65535))
    le16 $(($1 >> 16 & 65535))
}

# A zip local header and the data of a member <name>, compression <method>,
# the data the hex pairs <data>; its sizes 32-bit (<zip64> 0), or 0xffffffff
# with a zip64 extra field holding them (<zip64> 1).
zip_member() {
    name=$1
    method=$2
    zip64=$3
    data=$4
    n=$(printf '%s' "$data" | wc -w)
    bytes 50 4b 03 04 0a 00 00 00
    le16 "$method"
    bytes 00 00 00 00 00 00 00 00
    if [ "$zip64" = 1 ]; then
        bytes ff ff ff ff ff ff ff ff
    else
        le32 "$n"
        le32 "$n"
    fi
    le16 "${#name}"
    if [ "$zip64" = 1 ]; then le16 20; else le16 0; fi
    printf '%s' "$name"
    if [ "$zip64" = 1 ]; then
        bytes 01 00 10 00
        le32 "$n"
        le32 0
        le32 "$n"
        le32 0
    fi
    # shellcheck disable=SC2086 # one word per byte
    bytes $data
}

cases() {
    ELF_RPATH=$(abs "$1")
    PAYLOAD=$(abs "$2")
    FIX=$(abs "$3")
    TRIPLE=$4
    FLOOR=$5
    CC="$ZIG cc -target $TRIPLE -O1"
    R="$T/rpath"
    DECOY="$T/decoy"
    decoys "$DECOY" libkcovprobe.so.1
    mkdir -p "$R/bin" "$R/lib" "$T/glibc"

    # glibc_over: silent on a binary linked for the floor, and names the
    # version of a binary that needs a newer glibc (arc4random is GLIBC_2.36).
    # shellcheck disable=SC2086 # $CC is a command line
    $CC "$FIX/glibc_new.c" -o "$T/glibc/floor" >"$T/log" 2>&1 && red "glibc_new.c linked for the floor: it must need a newer glibc"
    grep -q arc4random "$T/log" || red "glibc_new.c failed to link for the floor, but not over arc4random"
    "$ZIG" cc -target "${TRIPLE%%.*}.2.38" -O1 "$FIX/glibc_new.c" -o "$T/glibc/new" >"$T/log" 2>&1 || red "zig cc of glibc_new.c for glibc 2.38 failed"
    over=$(glibc_over "$FLOOR" "$T/glibc/new") || red "glibc_over failed on a binary needing GLIBC_2.36"
    [ "$over" = "GLIBC_2.36" ] || red "glibc_over says '$over' of a binary needing GLIBC_2.36, want 'GLIBC_2.36'"
    pass
    # A stage of glibc_over's pipeline that fails fails it (set -o pipefail):
    # without that, `cat` of a file it cannot read leaves an empty list, which
    # reads as "nothing above the floor".
    if glibc_over "$FLOOR" "$T/glibc/missing" >"$T/log" 2>&1; then
        red "glibc_over exited 0 on a file that does not exist: a failing stage of its pipeline is ignored (set -o pipefail)"
    fi
    pass

    # The decoy and the run path. libkcovprobe.so.1 and a program linked
    # against it as kcov links libgcc_s.so.1: a positional input, with
    # --disable-new-dtags and $ORIGIN/../lib.
    # shellcheck disable=SC2086
    $CC -shared -fPIC "$FIX/rpath_lib.c" -Wl,-soname,libkcovprobe.so.1 -o "$R/lib/libkcovprobe.so.1" >"$T/log" 2>&1 || red "zig cc of rpath_lib.c failed"
    # shellcheck disable=SC2086,SC2016 # $ORIGIN is for the loader
    $CC "$FIX/rpath_main.c" "$R/lib/libkcovprobe.so.1" -Wl,--disable-new-dtags '-Wl,-rpath,$ORIGIN/../lib' -o "$R/bin/probe" >"$T/log" 2>&1 ||
        red "zig cc of rpath_main.c failed"
    # shellcheck disable=SC2086
    $CC "$FIX/rpath_main.c" "$R/lib/libkcovprobe.so.1" -o "$R/bin/plain" >"$T/log" 2>&1 || red "zig cc of rpath_main.c without a run path failed"
    over=$(glibc_over "$FLOOR" "$R/bin/probe" "$R/lib/libkcovprobe.so.1") || red "glibc_over failed on the probe"
    [ -z "$over" ] || red "glibc_over says '$over' of binaries linked for the floor"
    pass
    [ "$("$R/bin/probe")" = "kcov_probe 42" ] || red "the probe does not find its library through its run path"
    pass
    # As zig links it, the run path is a DT_RUNPATH: LD_LIBRARY_PATH comes
    # first, the decoy wins, and both detectors see it.
    trace_loads "$R/bin/probe" "$DECOY" "$T/ldd" && red "trace_loads missed a decoy that wins over a DT_RUNPATH: $(cat "$T/ldd")"
    LD_DEBUG=libs LD_DEBUG_OUTPUT="$T/runpath" LD_LIBRARY_PATH="$DECOY" "$R/bin/probe" >"$T/log" 2>&1 &&
        red "the probe ran with a decoy on LD_LIBRARY_PATH and a DT_RUNPATH: zig wrote a DT_RPATH (drop elf_rpath, README.md)"
    # With nothing on LD_LIBRARY_PATH holding the library, the loader reaches
    # the DT_RUNPATH and records that search, which rpath_record must not
    # take for a DT_RPATH one. (The decoy run above fails before the loader
    # searches the run path, so its record cannot show this.)
    mkdir -p "$T/empty"
    LD_DEBUG=libs LD_DEBUG_OUTPUT="$T/runpath_found" LD_LIBRARY_PATH="$T/empty" "$R/bin/probe" >"$T/log" 2>&1 ||
        red "the unconverted probe failed with an empty LD_LIBRARY_PATH"
    grep -qF "(RUNPATH from file $R/bin/probe)" "$T"/runpath_found.* ||
        red "the loader's record of the unconverted probe names no DT_RUNPATH search, so this case shows nothing"
    [ -z "$(rpath_record "$R/bin/probe" "$T/runpath_found")" ] || red "rpath_record took a DT_RUNPATH search for a DT_RPATH one"
    pass
    # elf_rpath makes it a DT_RPATH: the loader's own lib/ comes first.
    cp "$R/bin/probe" "$T/probe.runpath"
    "$ELF_RPATH" "$R/bin/probe" >"$T/log" 2>&1 || red "elf_rpath refused a file with one DT_RUNPATH"
    trace_loads "$R/bin/probe" "$DECOY" "$T/ldd" || red "after elf_rpath the loader still took the decoy: $(cat "$T/ldd")"
    out=$(LD_DEBUG=libs LD_DEBUG_OUTPUT="$T/rpath" LD_LIBRARY_PATH="$DECOY" "$R/bin/probe" 2>"$T/log") || red "after elf_rpath the probe fails with a decoy on LD_LIBRARY_PATH"
    [ "$out" = "kcov_probe 42" ] || red "after elf_rpath the probe printed '$out'"
    [ -n "$(rpath_record "$R/bin/probe" "$T/rpath")" ] || red "rpath_record found no DT_RPATH search of the converted probe"
    [ "$(cmp -l "$T/probe.runpath" "$R/bin/probe" | wc -l)" = 1 ] || red "elf_rpath changed more than the one tag byte"
    pass
    # ldd_stray and inits_stray (checks 4 and 7) are silent on the converted
    # probe, which loads its own library and glibc from the system...
    stray=$(ldd_stray "$T/ldd" "$R" "$DECOY" libkcovprobe.so.1)
    [ -z "$stray" ] || red "ldd_stray says '$stray' of the converted probe, which loads only its own library and glibc: $(cat "$T/ldd")"
    sed -n 's/.*calling init: //p' "$(rpath_record "$R/bin/probe" "$T/rpath")" | sort -u >"$T/inits"
    grep -qxF "$R/bin/../lib/libkcovprobe.so.1" "$T/inits" || red "the probe's record initialised no lib/libkcovprobe.so.1 of its own: $(cat "$T/inits")"
    stray=$(inits_stray "$T/inits" "$R" "$DECOY" libkcovprobe.so.1)
    [ -z "$stray" ] || red "inits_stray says '$stray' of the converted probe: $(cat "$T/inits")"
    pass
    # A decoy that is an ELF library, as the Mojo toolchain's lib/ holds one:
    # the loader maps it without a word, so only the detectors can see it.
    # The unconverted probe (DT_RUNPATH) takes it; trace_loads must fail, and
    # ldd_stray must name a library of the probe's own name taken from there.
    E="$T/elf_decoy"
    mkdir -p "$E"
    # shellcheck disable=SC2086
    $CC -shared -fPIC "$FIX/rpath_lib.c" -Wl,-soname,libkcovprobe.so.1 -o "$E/libkcovprobe.so.1" >"$T/log" 2>&1 || red "zig cc of the ELF decoy failed"
    cp "$T/probe.runpath" "$R/bin/probe.runpath"
    LD_LIBRARY_PATH="$E" LD_TRACE_LOADED_OBJECTS=1 "$R/bin/probe.runpath" >"$T/ldd" 2>&1 ||
        red "the loader refused the ELF decoy, so this case shows nothing: $(cat "$T/ldd")"
    trace_loads "$R/bin/probe.runpath" "$E" "$T/ldd" && red "trace_loads missed an ELF decoy that wins over a DT_RUNPATH: $(cat "$T/ldd")"
    stray=$(ldd_stray "$T/ldd" "$R" "$E" libkcovprobe.so.1)
    [ "$stray" = "libkcovprobe.so.1 => $E/libkcovprobe.so.1" ] ||
        red "ldd_stray says '$stray' of a probe taking its own library's name from the ELF decoy, want that decoy: $(cat "$T/ldd")"
    rm "$R/bin/probe.runpath"
    pass
    # ...and each names a library with a glibc name that the loader took from
    # the program's own lib/ (searched before the system): a probe linked
    # like the first one, with a libm.so.6 of its own.
    M="$T/glibc_named"
    mkdir -p "$M/bin" "$M/lib"
    cp "$R/lib/libkcovprobe.so.1" "$M/lib/libkcovprobe.so.1"
    # shellcheck disable=SC2086
    $CC -shared -fPIC -Dkcov_probe=kcov_glibc_named "$FIX/rpath_lib.c" -Wl,-soname,libm.so.6 -o "$M/lib/libm.so.6" >"$T/log" 2>&1 ||
        red "zig cc of rpath_lib.c as libm.so.6 failed"
    # shellcheck disable=SC2086,SC2016 # $ORIGIN is for the loader
    $CC "$FIX/rpath_main.c" "$M/lib/libkcovprobe.so.1" "$M/lib/libm.so.6" -Wl,--disable-new-dtags '-Wl,-rpath,$ORIGIN/../lib' \
        -o "$M/bin/probe" >"$T/log" 2>&1 || red "zig cc of rpath_main.c with a libm.so.6 failed"
    "$ELF_RPATH" "$M/bin/probe" >"$T/log" 2>&1 || red "elf_rpath refused the probe with a libm.so.6"
    trace_loads "$M/bin/probe" "$DECOY" "$T/ldd" || red "the probe with a libm.so.6 took the decoy: $(cat "$T/ldd")"
    grep -q "^[[:space:]]*libm.so.6 => $M/bin/../lib/libm.so.6 " "$T/ldd" ||
        red "the probe does not load libm.so.6 from its own lib/, so this case shows nothing: $(cat "$T/ldd")"
    stray=$(ldd_stray "$T/ldd" "$M" "$DECOY" libkcovprobe.so.1)
    [ "$stray" = "libm.so.6 => $M/bin/../lib/libm.so.6" ] || red "ldd_stray says '$stray' of a probe loading libm.so.6 from its own lib/, want that libm.so.6"
    LD_DEBUG=libs LD_DEBUG_OUTPUT="$T/named" LD_LIBRARY_PATH="$DECOY" "$M/bin/probe" >"$T/log" 2>&1 || red "the probe with a libm.so.6 of its own failed"
    rec=$(rpath_record "$M/bin/probe" "$T/named")
    [ -n "$rec" ] || red "rpath_record found no DT_RPATH search of the probe with a libm.so.6"
    sed -n 's/.*calling init: //p' "$rec" | sort -u >"$T/inits"
    stray=$(inits_stray "$T/inits" "$M" "$DECOY" libkcovprobe.so.1)
    [ "$stray" = "$M/bin/../lib/libm.so.6" ] || red "inits_stray says '$stray' of a probe initialising libm.so.6 from its own lib/, want that libm.so.6: $(cat "$T/inits")"
    pass
    # elf_rpath refuses, leaving the file as it was, unless the file is an
    # x86_64 executable or shared object with one PT_DYNAMIC header, exactly
    # one DT_RUNPATH and no DT_RPATH. The last five subjects are the
    # unconverted probe, which it converts, with one edit each: e_machine
    # aarch64, e_type ET_REL, the first program header retyped PT_DYNAMIC,
    # and its DT_DEBUG entry retagged DT_RPATH (a file with both run paths)
    # or DT_RUNPATH (a file with two).
    phoff=$(od -An -tu4 -j32 -N4 "$T/probe.runpath" | tr -d ' ')
    [ "$(od -An -tu4 -j"$phoff" -N4 "$T/probe.runpath" | tr -d ' ')" != 2 ] || red "the probe's first program header is PT_DYNAMIC already"
    debug=$(dyn_tag_off "$T/probe.runpath" 21)
    [ -n "$debug" ] || red "the probe has no DT_DEBUG entry to retag"
    [ -n "$(dyn_tag_off "$T/probe.runpath" 29)" ] || red "dyn_tag_off finds no DT_RUNPATH in the unconverted probe"
    [ -z "$(dyn_tag_off "$T/probe.runpath" 15)" ] || red "dyn_tag_off finds a DT_RPATH in the unconverted probe"
    for defect in machine type dynamic both_paths two_runpaths; do
        cp "$T/probe.runpath" "$T/$defect"
        case "$defect" in
            machine) poke "$T/$defect" 18 b7 00 ;;
            type) poke "$T/$defect" 16 01 00 ;;
            dynamic) poke "$T/$defect" "$phoff" 02 00 00 00 ;;
            both_paths) poke "$T/$defect" "$debug" 0f ;;
            two_runpaths) poke "$T/$defect" "$debug" 1d ;;
        esac
        [ "$(cmp -l "$T/probe.runpath" "$T/$defect" | wc -l)" -ge 1 ] || red "the $defect edit changed nothing"
    done
    for subject in "$R/bin/probe" "$R/bin/plain" "$DECOY/libkcovprobe.so.1" "$T/machine" "$T/type" "$T/dynamic" "$T/both_paths" "$T/two_runpaths"; do
        cp "$subject" "$T/before"
        rc=0
        "$ELF_RPATH" "$subject" >"$T/log" 2>&1 || rc=$?
        [ "$rc" = 2 ] || red "elf_rpath exited $rc on ${subject##*/}, want 2"
        cmp "$T/before" "$subject" >/dev/null || red "elf_rpath changed ${subject##*/}, which it refused"
        pass
    done

    # conda_payload: the zstd payload of the pkg-*.tar.zst member, with a
    # 32-bit or a zip64 size; a refusal (exit 2, no output) otherwise. The
    # payload is one zstd frame of one raw block, `kcov\n`.
    FRAME="28 b5 2f fd 20 05 29 00 00 6b 63 6f 76 0a"
    C="$T/conda"
    mkdir -p "$C"
    { zip_member info-x.tar.zst 0 0 "00" && zip_member pkg-x.tar.zst 0 0 "$FRAME"; } >"$C/plain.conda"
    zip_member pkg-x.tar.zst 0 1 "$FRAME" >"$C/zip64.conda"
    zip_member info-x.tar.zst 0 0 "$FRAME" >"$C/nopkg.conda"
    zip_member pkg-x.tar.zst 8 0 "$FRAME" >"$C/deflate.conda"
    for p in plain zip64; do
        "$PAYLOAD" "$C/$p.conda" "$C/$p.tar" >"$T/log" 2>&1 || red "conda_payload refused $p.conda"
        [ "$(cat "$C/$p.tar")" = "kcov" ] || red "conda_payload wrote '$(cat "$C/$p.tar")' for $p.conda, want 'kcov'"
        pass
    done
    for p in nopkg deflate; do
        rc=0
        "$PAYLOAD" "$C/$p.conda" "$C/$p.tar" >"$T/log" 2>&1 || rc=$?
        [ "$rc" = 2 ] || red "conda_payload exited $rc on $p.conda, want 2"
        [ ! -e "$C/$p.tar" ] || red "conda_payload wrote an output for $p.conda, which it refused"
        pass
    done

    # identity, in its own process, on a fixture standing for bin/kcov (its
    # sha256 written here, not computed): accepted with its sha256 and a line
    # it holds; refused, naming the constant and the sha256 to update it to,
    # with a sha256 one digit off; refused with a line it does not hold.
    I="$T/identity"
    mkdir -p "$I/kcov/bin"
    ID_SHA=3350799a0c9ff68ad6e690405c7a42bba0fe583311a46c7aea97c4a855abced2
    ID_LINE="Usage: kcov_identity case [OPTIONS]"
    printf 'kcov_check cases: this file stands for bin/kcov\000%s\000tail\n' "$ID_LINE" >"$I/kcov/bin/kcov"
    for c in "ok|$ID_SHA|$ID_LINE|" \
        "sha|4${ID_SHA#?}|$ID_LINE|Update KCOV_BIN_SHA256 to $ID_SHA" \
        "line|$ID_SHA|$ID_LINE out-dir|does not hold KCOV_USAGE_LINE"; do
        name=${c%%|*}
        rest=${c#*|}
        sha=${rest%%|*}
        rest=${rest#*|}
        line=${rest%%|*}
        want=${rest#*|}
        rm -rf "$I/report" "$I/scratch"
        rc=0
        BUCK_SCRATCH_PATH="$I/scratch" "$BB" sh "$SELF" identity "$BB" - "$I/report" "$I/kcov" "$sha" "$line" >"$I/out" 2>"$I/err" || rc=$?
        case "$want" in
            "")
                [ "$rc" = 0 ] || red "identity_$name: exited $rc, want 0: $(cat "$I/err")"
                grep -F -q '2 checks passed' "$I/report/validation.json" || red "identity_$name: the result is not 2 checks: $(cat "$I/report/validation.json")"
                ;;
            *)
                [ "$rc" = 1 ] || red "identity_$name: exited $rc, want 1: $(cat "$I/err")"
                grep -F -q -e "$want" "$I/err" || red "identity_$name: the refusal does not say '$want': $(cat "$I/err")"
                [ ! -e "$I/report/validation.json" ] || red "identity_$name: refused, but wrote a result"
                ;;
        esac
        pass
    done
    green
}

# ---- same --------------------------------------------------------------------

# The listing of <dir>: `<mode> <sha256 or -> <path>` per entry, sorted.
listing() {
    (cd "$1" && find . | sort | while read -r p; do
        if [ -f "$p" ]; then
            printf '%s %s %s\n' "$(ls -ld "$p" | cut -c1-10)" "$(sha256sum "$p" | cut -d' ' -f1)" "$p"
        else
            printf '%s - %s\n' "$(ls -ld "$p" | cut -c1-10)" "$p"
        fi
    done)
}

same() {
    listing "$(abs "$1")" >"$REPORT/a.txt"
    listing "$(abs "$2")" >"$REPORT/b.txt"
    [ -s "$REPORT/a.txt" ] || red "the first build is empty"
    diff "$REPORT/a.txt" "$REPORT/b.txt" >"$T/log" 2>&1 || red "two builds of the distribution differ (README.md, Reproducible)"
    pass
    rm -f "$REPORT/a.txt" "$REPORT/b.txt"
    green
}

# ---- identity ----------------------------------------------------------------

identity() {
    KCOV="$(abs "$1")/bin/kcov"
    WANT=$2
    LINE=$3
    [ -f "$KCOV" ] || red "$KCOV is not a file"
    got=$(sha256sum <"$KCOV") || red "cannot read bin/kcov"
    got=${got%% *}
    [ "$got" = "$WANT" ] ||
        red "bin/kcov's sha256 is $got, but KCOV_BIN_SHA256 in tools/build/toolchains/kcov/identity.bzl is $WANT: kcov's bytes changed (a pin, kcov_build.sh or zig). Update KCOV_BIN_SHA256 to $got: the package guard refuses a file by it (tools/build/package/README.md, \"kcov is never packed\")"
    pass
    rc=0
    grep -F -q -e "$LINE" "$KCOV" || rc=$?
    case "$rc" in
        0) ;;
        1) red "bin/kcov does not hold KCOV_USAGE_LINE of tools/build/toolchains/kcov/identity.bzl, '$LINE': kcov's help text changed, so the package guard would find no kcov by it. Update KCOV_USAGE_LINE to a line of kcov's usage text that bin/kcov holds" ;;
        *) red "grep failed (exit $rc) on bin/kcov" ;;
    esac
    pass
    green
}

case "$MODE" in
    check) [ $# -eq 7 ] || red "usage: check needs 7 arguments after the report dir" ;;
    cases) [ $# -eq 5 ] || red "usage: cases needs 5 arguments after the report dir" ;;
    same) [ $# -eq 2 ] || red "usage: same needs 2 arguments after the report dir" ;;
    identity) [ $# -eq 3 ] || red "usage: identity needs 3 arguments after the report dir" ;;
    *) red "unknown mode '$MODE'" ;;
esac
"$MODE" "$@"
