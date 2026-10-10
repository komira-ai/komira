#!/bin/sh
# Builds kcov from its pinned source archive with the pinned zig, as one
# build action of the `kcov_dist` rule (defs.bzl):
#   sh kcov_build.sh <busybox> <zig_dir> <conda_payload> <elf_rpath> <kcov.tar.gz> <strip_prefix>
#       <version> <zig_triple> <shim_dir> <out_dir> <name>=<package.conda>...
# The conda packages are elfutils, zlib, bzip2, zstd and lzma (static
# archives) and libgcc (libgcc_s.so.1). kcov is the Linux source list of
# kcov's src/CMakeLists.txt with dummy-coveralls-writer.cc and
# dummy-disassembler.cc (what its KCOV_STATIC_BUILD and no-libbfd branches
# choose): no libcurl, no libbfd; shim/ defines the three curl functions
# utils.cc calls.
#
# Every library is linked statically (libdw.a, libelf.a, libz.a, liblzma.a,
# libbz2.a, libzstd.a, zig's libc++) except the unwinder: <out_dir>/bin/kcov
# needs glibc and <out_dir>/lib/libgcc_s.so.1 only. <out_dir>/share/licenses
# holds the licence files.
#   glibc's pthread_cancel, which kcov calls on every run (solib-handler.cc),
#   dlopens libgcc_s.so.1 (the worker has none) and unwinds the cancelled
#   thread's C++ frames with it, through the personality routine of zig's
#   libc++abi. Linked against zig's static libunwind, that routine reads
#   libgcc's unwind context as libunwind's and kcov segfaults (measured).
#   So kcov links libgcc_s.so.1 itself, as an input ahead of zig's own
#   libraries, for its _Unwind_* symbols; glibc's dlopen then finds the
#   loaded library by its soname.
#   bin/kcov finds it through its DT_RPATH $ORIGIN/../lib, which the loader
#   searches before LD_LIBRARY_PATH (a DT_RUNPATH comes after it, and the
#   test runner sets LD_LIBRARY_PATH). zig 0.12 gives an executable a
#   DT_RUNPATH whatever the flags say (elf_rpath.zig), so elf_rpath turns it
#   into a DT_RPATH after the link.
# Every pipeline fails when any of its stages fails (pipefail): an `od` that
# cannot read a file never becomes an empty generated array.
set -eu
# shellcheck disable=SC3040 # busybox sh (ash) has pipefail (:kcov_check_cases proves it for kcov_check.sh)
set -o pipefail

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
BB=$(abs "$1")
ZIG=$(abs "$2")/zig
PAYLOAD=$(abs "$3")
ELF_RPATH=$(abs "$4")
ARCHIVE=$(abs "$5")
PREFIX=$6
VERSION=$7
TRIPLE=$8
SHIM=$(abs "$9")
OUT=$(abs "${10}")
shift 10

# Private scratch (as in tools/build/mojo/toolchain.bzl).
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.kcov_build" ;;
    /*) T="$BUCK_SCRATCH_PATH/kcov_build" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/kcov_build" ;;
esac
"$BB" mkdir -p "$T/bin" "$T/home"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
ZIG_GLOBAL_CACHE_DIR="$T/zig-global"
ZIG_LOCAL_CACHE_DIR="$T/zig-local"
HOME="$T/home"
export PATH LC_ALL=C ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR HOME

# The conda packages: <name>=<package.conda>, unpacked into $T/conda/<name>.
for spec in "$@"; do
    name=${spec%%=*}
    d="$T/conda/$name"
    mkdir -p "$d"
    "$PAYLOAD" "$(abs "${spec#*=}")" "$d.tar"
    tar -xf "$d.tar" -C "$d"
    rm -f "$d.tar"
done
C="$T/conda"
for need in elfutils/include/elfutils/libdw.h elfutils/lib/libdw.a elfutils/lib/libelf.a \
    zlib/include/zlib.h zlib/lib/libz.a bzip2/lib/libbz2.a zstd/lib/libzstd.a lzma/lib/liblzma.a \
    libgcc/lib/libgcc_s.so.1; do
    [ -s "$C/$need" ] || { echo "kcov_build: $need is missing from the pinned packages" >&2; exit 2; }
done

# libelf.a and libz.a both define crc32, the same function (CRC-32,
# polynomial 0xedb88320, inverted before and after), and a static link pulls
# both members. libelf's objects are linked without its crc32.o, so its
# callers take zlib's.
mkdir -p "$T/libelf"
(cd "$T/libelf" && ar x "$C/elfutils/lib/libelf.a")
dups=$(ar t "$C/elfutils/lib/libelf.a" | sort | uniq -d)
[ -z "$dups" ] || { echo "kcov_build: libelf.a has two members of one name" >&2; exit 2; }
[ -f "$T/libelf/crc32.o" ] || { echo "kcov_build: libelf.a has no crc32.o; drop the workaround" >&2; exit 2; }
rm "$T/libelf/crc32.o"
LIBELF_OBJS=$(find "$T/libelf" -name '*.o' | sort)

mkdir -p "$T/src"
tar -xzf "$ARCHIVE" -C "$T/src"
S="$T/src/$PREFIX/src"
DATA="$T/src/$PREFIX/data"
[ -f "$S/CMakeLists.txt" ] || { echo "kcov_build: $PREFIX/src is not in the archive" >&2; exit 2; }
G="$T/gen"
mkdir -p "$G"

# The patches (README.md, "Patches"): kcov_patch <file> <count> <sed expression>
# rewrites <file> under src/, and must add exactly <count> lines holding
# KOMIRA PATCH: an expression that matches nothing (a new kcov) fails here.
kcov_patch() {
    f="$S/$1"
    before=$(grep -c -F "KOMIRA PATCH" "$f" || true)
    sed -e "$3" "$f" >"$f.patched"
    after=$(grep -c -F "KOMIRA PATCH" "$f.patched" || true)
    [ "$((after - before))" = "$2" ] || { echo "kcov_build: the patch of $1 marked $((after - before)) line(s), expected $2" >&2; exit 2; }
    mv "$f.patched" "$f"
}
# 1. No CPU pin: kcov pins itself and the test to the CPU it started on
#    (tie_process_to_cpu: sched_setaffinity to one CPU), so every traced test
#    ran on one CPU where the release gate gives it all of the worker's.
kcov_patch engines/ptrace_linux.cc 1 \
    's|^\([[:space:]]*\)panic_if(sched_setaffinity(pid, CPU_ALLOC_SIZE(max_cpu), set) < 0, "Can.t set CPU affinity. Coincident won.t work");$|\1(void) pid; /* KOMIRA PATCH: no CPU pin */|'
# 2. The exit status is the test's: kcov set it from the exit of every traced
#    process, so the last one to exit (a child the test left behind) won,
#    and from a signal death as the bare signal number.
kcov_patch collector.cc 1 \
    '/^[[:space:]]*case ev_exit:$/{n;s|m_exitCode = ev.data;|/* KOMIRA PATCH: not the status of another process */|;}'
kcov_patch collector.cc 1 \
    '/^[[:space:]]*case ev_signal_exit:$/,/^[[:space:]]*case ev_exit_first_process:$/s|m_exitCode = ev.data;|m_exitCode = 128 + ev.data; /* KOMIRA PATCH: as a shell reports it */|'
kcov_patch engines/ptrace.cc 1 \
    's|^\([[:space:]]*\)if (!childrenLeft())$|\1if (who == m_firstChild) /* KOMIRA PATCH: the test, not another process */|'

# bin-to-c-source.py of kcov, in sh: <out.cc> (<file> <name>)...
bin2c() {
    o=$1
    shift
    {
        printf '#include <stdint.h>\n#include <stdlib.h>\n#include <generated-data-base.hh>\nusing namespace kcov;\n'
        while [ $# -gt 0 ]; do
            [ -s "$1" ] || { echo "kcov_build: bin2c: $1 is missing or empty" >&2; exit 2; }
            printf 'const uint8_t %s_data_raw[] = {\n' "$2"
            od -An -v -tx1 "$1" | sed -e 's/ \([0-9a-f][0-9a-f]\)/0x\1,/g'
            printf '};\nGeneratedData %s_data(%s_data_raw, sizeof(%s_data_raw));\n' "$2" "$2" "$2"
            shift 2
        done
    } >"$o"
}

TGT="-target $TRIPLE"
DEFS="-D_GLIBCXX_USE_NANOSLEEP -DKCOV_LIBRARY_PREFIX=/tmp -DKCOV_HAS_LIBBFD=0 -DKCOV_LIBFD_DISASM_STYLED=0 -DPACKAGE -DPACKAGE_VERSION"
INC="-I$S/include -I$SHIM -I$C/elfutils/include -I$C/zlib/include"
CFLAGS="$TGT -O2 -g0 -fPIC $DEFS $INC"
CXXFLAGS="$TGT -std=c++17 -O2 -g0 -fPIC $DEFS $INC"
STATIC_LIBS="$C/elfutils/lib/libdw.a $LIBELF_OBJS $C/zlib/lib/libz.a $C/lzma/lib/liblzma.a $C/bzip2/lib/libbz2.a $C/zstd/lib/libzstd.a"

# The C objects (zig c++ would pass -std=c++17 to a .c source).
printf 'const char *kcov_version = "%s";\n' "$VERSION" >"$G/version.c"
# shellcheck disable=SC2086 # word splitting of the flag lists is intended
"$ZIG" cc $CFLAGS -c "$G/version.c" -o "$G/version.o"
# shellcheck disable=SC2086
"$ZIG" cc $CFLAGS -c "$S/solib-parser/phdr_data.c" -o "$G/phdr_data.o"
# shellcheck disable=SC2086
"$ZIG" cc $CFLAGS -c "$SHIM/curl_shim.c" -o "$G/curl_shim.o"

# The libraries kcov embeds and writes out at run time. Each is stripped
# (-s), as bin/kcov is: zig builds its C runtime objects and libc++ with
# debug information, whose compilation directory is the worker's absolute
# path, and those bytes would make every build of kcov differ.
# shellcheck disable=SC2086
"$ZIG" cc $CFLAGS -shared -s "$S/solib-parser/phdr_data.c" "$S/solib-parser/lib.c" -ldl -o "$G/libkcov_sowrapper.so"
# shellcheck disable=SC2086
"$ZIG" cc $CFLAGS -shared -s "$S/engines/bash-execve-redirector.c" -ldl -o "$G/bash_execve_redirector.so"
# shellcheck disable=SC2086
"$ZIG" cc $CFLAGS -shared -s "$S/engines/bash-tracefd-cloexec.c" -ldl -o "$G/bash_tracefd_cloexec.so"
# shellcheck disable=SC2086
"$ZIG" c++ $CXXFLAGS -shared -s "$S/engines/system-mode-binary-lib.cc" "$S/utils.cc" "$S/system-mode/registration.cc" \
    "$G/curl_shim.o" "$C/zlib/lib/libz.a" -ldl -o "$G/kcov_system_lib.so"

bin2c "$G/library.cc" "$G/libkcov_sowrapper.so" __library
bin2c "$G/bash-redirector-library.cc" "$G/bash_execve_redirector.so" bash_redirector_library
bin2c "$G/bash-cloexec-library.cc" "$G/bash_tracefd_cloexec.so" bash_cloexec_library
bin2c "$G/kcov-system-library.cc" "$G/kcov_system_lib.so" kcov_system_library
bin2c "$G/python-helper.cc" "$S/engines/python-helper.py" python_helper
bin2c "$G/bash-helper.cc" "$S/engines/bash-helper.sh" bash_helper "$S/engines/bash-helper-debug-trap.sh" bash_helper_debug_trap
bin2c "$G/html-data-files.cc" \
    "$DATA/bcov.css" css_text \
    "$DATA/amber.png" icon_amber \
    "$DATA/glass.png" icon_glass \
    "$DATA/source-file.html" source_file_text \
    "$DATA/index.html" index_text \
    "$DATA/js/handlebars.js" handlebars_text \
    "$DATA/js/kcov.js" kcov_text \
    "$DATA/js/jquery.min.js" jquery_text \
    "$DATA/js/jquery.tablesorter.min.js" tablesorter_text \
    "$DATA/js/jquery.tablesorter.widgets.min.js" tablesorter_widgets_text \
    "$DATA/tablesorter-theme.css" tablesorter_theme_text

# kcov_SRCS of src/CMakeLists.txt for Linux, without libbfd and libcurl.
SRCS=""
for f in capabilities.cc collector.cc configuration.cc engine-factory.cc \
    engines/bash-engine.cc engines/system-mode-engine.cc engines/system-mode-file-format.cc engines/python-engine.cc \
    filter.cc gcov.cc main.cc merge-file-parser.cc output-handler.cc parsers/dummy-disassembler.cc \
    parser-manager.cc reporter.cc source-file-cache.cc utils.cc \
    writers/cobertura-writer.cc writers/codecov-writer.cc writers/json-writer.cc writers/dummy-coveralls-writer.cc \
    writers/html-writer.cc writers/sonarqube-xml-writer.cc writers/writer-base.cc \
    engines/clang-coverage-engine.cc engines/ptrace.cc engines/ptrace_linux.cc engines/kernel-engine.cc \
    parsers/elf.cc parsers/elf-parser.cc parsers/dwarf.cc solib-handler.cc system-mode/file-data.cc; do
    SRCS="$SRCS $S/$f"
done
GEN="$G/library.cc $G/bash-redirector-library.cc $G/bash-cloexec-library.cc $G/python-helper.cc $G/bash-helper.cc $G/kcov-system-library.cc $G/html-data-files.cc"

mkdir -p "$OUT/bin" "$OUT/lib"
# shellcheck disable=SC2086,SC2016 # $ORIGIN is for the loader, not the shell
"$ZIG" c++ $CXXFLAGS $SRCS $GEN "$G/version.o" "$G/phdr_data.o" "$G/curl_shim.o" $STATIC_LIBS "$C/libgcc/lib/libgcc_s.so.1" \
    -lpthread -ldl -lm -s -Wl,--disable-new-dtags '-Wl,-rpath,$ORIGIN/../lib' -o "$OUT/bin/kcov"
"$ELF_RPATH" "$OUT/bin/kcov"
test -x "$OUT/bin/kcov"
cp -L "$C/libgcc/lib/libgcc_s.so.1" "$OUT/lib/libgcc_s.so.1"

# The licences (README.md, "Licences"): kcov's own files, and what else
# bin/kcov and lib/ hold.
mkdir -p "$OUT/share/licenses/kcov"
cp "$T/src/$PREFIX/COPYING" "$T/src/$PREFIX/COPYING.externals" "$OUT/share/licenses/kcov/"
cat >"$OUT/share/licenses/NOTICE" <<'EOF'
This directory is kcov, built from the source archive of its tag with the
changes komira's kcov_build.sh makes (each changed line says KOMIRA PATCH:
no CPU pin; the exit status is the traced program's). kcov is
GPL-2.0 (kcov/COPYING); the files of its data/ that bin/kcov embeds are
listed with their licences in kcov/COPYING.externals.

bin/kcov also holds, linked statically (licences as their conda-forge
packages declare them):
  elfutils libdw and libelf    LGPL-3.0-only
  zlib                         Zlib
  bzip2                        bzip2-1.0.6
  zstd                         BSD-3-Clause
  liblzma (xz)                 0BSD
  zig's libc++ and libc++abi   Apache-2.0 WITH LLVM-exception

lib/libgcc_s.so.1 is GCC's runtime library from the conda-forge libgcc
package: GPL-3.0-or-later WITH GCC-exception-3.1.
EOF
rm -rf "$T"
