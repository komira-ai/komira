#!/usr/bin/env bash
# bundle.sh -- checks of the bundle of //examples:hello (//package).
#
# usage: checks/bundle.sh [--no-uncached]   (from anywhere; BUCK2 overrides)
#
#   layout      the bundle holds exactly the expected files, bin/hello is the
#               only executable, SHA256SUMS verifies, VERSION equals
#               checks/bundle_expected/VERSION; the launcher needs glibc's
#               own libraries only, no symbol newer than GLIBC_2.34, and has
#               run path $ORIGIN/../lib; lib<name>.so sits in
#               lib/glibc-hwcaps/x86-64-v3/, its SONAME is its file name and
#               its run path $ORIGIN/../..; the run paths of every file are
#               exactly checks/bundle_expected/run_paths.txt (the Mojo and C++
#               runtime libraries are vendor files, copied unchanged, and keep
#               the vendor's), all $ORIGIN-relative; no file names a buck-out
#               path.
#   relocated   a copy of the bundle in a fresh directory prints the greeting
#               with an empty environment, and so does a symlink to its
#               bin/hello found on PATH.
#   refusal     the TEST launcher ([test_launcher], built with the test hook)
#               told the CPU is a Nehalem (x86-64-v2) prints exactly
#               "hello requires an x86-64-v3 CPU (Haswell or newer)" and exits
#               126, even with lib/ deleted (nothing is loaded before the
#               check); told Haswell, it runs the program. The shipped
#               launcher carries no hook: it ignores $KOMIRA_TEST_CPU and holds
#               no such string.
#   loader      (needs a host whose glibc supports x86-64-v3) glibc's loader
#               finds libhello.so through the launcher's run path in
#               lib/glibc-hwcaps/x86-64-v3/, first try (LD_DEBUG=libs); with
#               hwcaps masked below v3 (GLIBC_TUNABLES) the launcher exits 127
#               and says the library is present only for x86-64-v3 and the
#               loader did not accept that level; LD_LIBRARY_PATH comes before
#               the run path (RUNPATH semantics, accepted): a different
#               libhello.so there is loaded and refused for lacking
#               komira_main, exit 127.
#   uncached    two builds in two fresh daemons with --no-remote-cache
#               (every action, the compiles included, runs again) give
#               byte-identical bundles (modes included), tarballs and docker
#               archives, and the same image digest (checks/formats.sh checks
#               what those files hold).
#
# Local runs are of the small built programs only, under `ulimit -v`.
set -uo pipefail

uncached=1
[ "${1:-}" = "--no-uncached" ] && uncached=0
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
if [ -z "${BUCK2:-}" ]; then
    if command -v buck2 > /dev/null; then BUCK2=buck2; else BUCK2="$ROOT/tools/buck2"; fi
fi
W=$(mktemp -d "${TMPDIR:-/tmp}/komira_bundle.XXXXXX")
fails=0
pass() { echo "PASS  bundle $1"; }
fail() { echo "FAIL  bundle $1"; fails=$((fails + 1)); }
EXPECT_REFUSAL="hello requires an x86-64-v3 CPU (Haswell or newer)"
MEM_KB=4000000

built() { # target -> path of its (materialized) default output
    "$BUCK2" build "$1" --materializations all --show-full-simple-output 2>> "$W/build.log" | tail -n 1
}

# A plain copy: buck-out entries may be symlinks and read-only.
copy_bundle() { # src dst
    cp -rL "$1" "$2" && chmod -R u+w "$2"
}

listing() { # dir -> "mode sha256 path" per file, sorted by path
    (cd "$1" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s %s %s\n' "$(stat -c %a "$f")" "$(sha256sum < "$f" | cut -c1-64)" "$f"
    done)
}

run_in() { # dir, env..., -- , command... ; stdout+stderr to $W/run.out, returns rc
    local dir=$1; shift
    local envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    (cd "$dir" && ulimit -v "$MEM_KB" && env -i ${envs[@]+"${envs[@]}"} "$@" > "$W/run.out" 2>&1 < /dev/null)
}

B=$(built //examples:hello_bundle)
TL=$(built "//examples:hello_bundle[test_launcher]")
if [ ! -d "$B" ] || [ ! -f "$TL" ]; then
    fail "build: cannot build //examples:hello_bundle (see $W/build.log)"
    echo "logs: $W"; exit 1
fi

# ---- layout ------------------------------------------------------------------
copy_bundle "$B" "$W/layout"
L="$W/layout"
problems=""
(cd "$L" && find . \( -type f -o -type l \) | sed 's|^\./||' | LC_ALL=C sort) > "$W/files.txt"
if ! diff -u checks/bundle_expected/files.txt "$W/files.txt" > "$W/files.diff"; then
    problems="$problems files-differ:$(grep -E '^[-+][^-+]' "$W/files.diff" | tr '\n' ' ')"
fi
[ -z "$(cd "$L" && find . -type l)" ] || problems="$problems symlinks-in-bundle"
execs=$(cd "$L" && find . -type f -perm -u+x | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' ')
[ "$execs" = "bin/hello " ] || problems="$problems executables:[$execs]"
(cd "$L" && sha256sum -c --quiet SHA256SUMS > "$W/sums.log" 2>&1) || problems="$problems SHA256SUMS-does-not-verify"
[ "$(cut -c67- "$L/SHA256SUMS" | tr '\n' ' ')" = "$(grep -vx SHA256SUMS "$W/files.txt" | tr '\n' ' ')" ] ||
    problems="$problems SHA256SUMS-does-not-list-every-other-file"
cmp -s checks/bundle_expected/VERSION "$L/VERSION" || problems="$problems VERSION-differs"
dyn() { readelf -d "$1" 2> /dev/null | sed -nE "s/.*\\($2\\).*\\[(.*)\\]\$/\\1/p" | tr '\n' ' '; }
SO=lib/glibc-hwcaps/x86-64-v3/libhello.so
# The launcher must start on any host with glibc 2.34 or later, before it has
# checked anything: it may need glibc's own libraries only.
for n in $(dyn "$L/bin/hello" NEEDED); do
    case "$n" in libc.so.6 | libpthread.so.0 | libdl.so.2) ;; *) problems="$problems launcher-NEEDED:$n" ;; esac
done
newest=$(objdump -T "$L/bin/hello" | grep -oE 'GLIBC_[0-9.]+' | sed 's/GLIBC_//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
case "$newest" in 2.[0-9] | 2.[0-9].* | 2.[12][0-9] | 2.[12][0-9].* | 2.3[0-4] | 2.3[0-4].*) ;; *) problems="$problems launcher-needs-GLIBC_$newest" ;; esac
[ "$(dyn "$L/bin/hello" RUNPATH)" = '$ORIGIN/../lib ' ] || problems="$problems launcher-RUNPATH:[$(dyn "$L/bin/hello" RUNPATH)]"
[ "$(dyn "$L/$SO" SONAME)" = "libhello.so " ] || problems="$problems so-SONAME:[$(dyn "$L/$SO" SONAME)]"
[ "$(dyn "$L/$SO" RUNPATH)" = '$ORIGIN/../.. ' ] || problems="$problems so-RUNPATH:[$(dyn "$L/$SO" RUNPATH)]"
nrp=0
while IFS= read -r f; do
    head -c 4 "$L/$f" | grep -q 'ELF' || continue
    readelf -d "$L/$f" | sed -nE "s|.*\\((RPATH\|RUNPATH)\\).*\\[(.*)\\]\$|$f \\1 \\2|p" >> "$W/run_paths.txt"
    for p in $(readelf -d "$L/$f" | sed -nE 's/.*\((RPATH|RUNPATH)\).*\[(.*)\]$/\2/p' | tr ':' ' '); do
        nrp=$((nrp + 1))
        case "$p" in '$ORIGIN' | '$ORIGIN/'*) ;; *) problems="$problems run-path:$f:$p" ;; esac
    done
done < "$W/files.txt"
grep -v '^#' checks/bundle_expected/run_paths.txt | diff - "$W/run_paths.txt" > "$W/run_paths.diff" ||
    problems="$problems run-paths-differ:$(grep -E '^[<>]' "$W/run_paths.diff" | cut -c1-160 | tr '\n' ' ')"
grep -rlaF 'buck-out/' "$L" > "$W/buckout.txt" && problems="$problems names-buck-out:[$(tr '\n' ' ' < "$W/buckout.txt")]"
grep -qaF KOMIRA_TEST_CPU "$L/bin/hello" && problems="$problems shipped-launcher-has-test-hook"
grep -qaF KOMIRA_TEST_CPU "$TL" || problems="$problems test-launcher-has-no-hook"
if [ -n "$problems" ]; then
    fail "layout:$problems"
else
    pass "layout: $(wc -l < "$W/files.txt") files as expected, SHA256SUMS verifies, launcher needs [$(dyn "$L/bin/hello" NEEDED)] up to GLIBC_$newest, $nrp run paths all \$ORIGIN-relative and as listed"
fi

# ---- relocated ---------------------------------------------------------------
mkdir -p "$W/elsewhere/deeper" "$W/pathbin" "$W/cwd"
copy_bundle "$B" "$W/elsewhere/deeper/hello-0.1.0"
ln -s "$W/elsewhere/deeper/hello-0.1.0/bin/hello" "$W/pathbin/hello"
problems=""
run_in "$W/cwd" -- "$W/elsewhere/deeper/hello-0.1.0/bin/hello" || problems="$problems copy-rc=$?"
[ "$(cat "$W/run.out")" = "hello from mojo" ] || problems="$problems copy-output:[$(head -c 300 "$W/run.out")]"
run_in "$W/cwd" "PATH=$W/pathbin" -- hello || problems="$problems path-symlink-rc=$?"
[ "$(cat "$W/run.out")" = "hello from mojo" ] || problems="$problems path-symlink-output:[$(head -c 300 "$W/run.out")]"
if [ -n "$problems" ]; then fail "relocated:$problems"; else pass "relocated: a copy elsewhere and a symlink on PATH both run with an empty environment"; fi

# ---- refusal -----------------------------------------------------------------
problems=""
copy_bundle "$B" "$W/test_bundle"
cp --remove-destination "$TL" "$W/test_bundle/bin/hello"
chmod 0755 "$W/test_bundle/bin/hello"
rc=0; run_in "$W/cwd" "KOMIRA_TEST_CPU=haswell" -- "$W/test_bundle/bin/hello" || rc=$?
[ "$rc" = 0 ] && [ "$(cat "$W/run.out")" = "hello from mojo" ] || problems="$problems haswell:rc=$rc:[$(head -c 300 "$W/run.out")]"
for model in nehalem qemu64; do
    rc=0; run_in "$W/cwd" "KOMIRA_TEST_CPU=$model" -- "$W/test_bundle/bin/hello" || rc=$?
    [ "$rc" = 126 ] && [ "$(cat "$W/run.out")" = "$EXPECT_REFUSAL" ] || problems="$problems $model:rc=$rc:[$(head -c 300 "$W/run.out")]"
done
chmod -R u+w "$W/test_bundle/lib" && find "$W/test_bundle/lib" -type f -delete
rc=0; run_in "$W/cwd" "KOMIRA_TEST_CPU=nehalem" -- "$W/test_bundle/bin/hello" || rc=$?
[ "$rc" = 126 ] && [ "$(cat "$W/run.out")" = "$EXPECT_REFUSAL" ] || problems="$problems nehalem-without-lib:rc=$rc:[$(head -c 300 "$W/run.out")]"
rc=0; run_in "$W/cwd" "KOMIRA_TEST_CPU=nehalem" -- "$W/elsewhere/deeper/hello-0.1.0/bin/hello" || rc=$?
[ "$rc" = 0 ] && [ "$(cat "$W/run.out")" = "hello from mojo" ] || problems="$problems shipped-launcher-honours-hook:rc=$rc:[$(head -c 300 "$W/run.out")]"
if [ -n "$problems" ]; then fail "refusal:$problems"; else pass "refusal: below x86-64-v3 -> '$EXPECT_REFUSAL', exit 126, nothing loaded; shipped launcher has no hook"; fi

# ---- loader ------------------------------------------------------------------
R="$W/elsewhere/deeper/hello-0.1.0"
active=$(env -i /lib64/ld-linux-x86-64.so.2 --list-diagnostics 2> /dev/null | sed -n 's/^dl_hwcaps_subdirs_active=//p')
case "$active" in
0x6 | 0x7)
    problems=""
    run_in "$W/cwd" LD_DEBUG=libs -- "$R/bin/hello" || problems="$problems ld-debug-rc=$?"
    first=$(grep -A 2 'find library=libhello.so' "$W/run.out" | sed -n 's/.*trying file=//p' | head -n 1)
    [ "$first" = "$R/bin/../lib/glibc-hwcaps/x86-64-v3/libhello.so" ] || problems="$problems first-try:[$first]"
    grep -qF "calling init: $R/bin/../lib/glibc-hwcaps/x86-64-v3/libhello.so" "$W/run.out" || problems="$problems not-loaded-from-hwcaps"
    grep -qx 'hello from mojo' "$W/run.out" || problems="$problems no-greeting"
    rc=0; run_in "$W/cwd" "GLIBC_TUNABLES=glibc.cpu.hwcaps=-AVX2" -- "$R/bin/hello" || rc=$?
    [ "$rc" = 127 ] && grep -qxF "hello: libhello.so is present only for x86-64-v3 and the system loader did not accept that level (glibc older than 2.33, or hwcaps masked by GLIBC_TUNABLES or --glibc-hwcaps-mask)" "$W/run.out" ||
        problems="$problems hwcaps-masked:rc=$rc:[$(head -c 300 "$W/run.out")]"
    mkdir -p "$W/decoy" && cp "$R/lib/libMSupportGlobals.so" "$W/decoy/libhello.so"
    rc=0; run_in "$W/cwd" "LD_LIBRARY_PATH=$W/decoy" -- "$R/bin/hello" || rc=$?
    [ "$rc" = 127 ] && [ "$(cat "$W/run.out")" = "hello: libhello.so has no komira_main" ] ||
        problems="$problems ld-library-path:rc=$rc:[$(head -c 300 "$W/run.out")]"
    if [ -n "$problems" ]; then fail "loader:$problems"; else pass "loader: libhello.so found first try in lib/glibc-hwcaps/x86-64-v3/; hwcaps masked -> exit 127 naming the level; LD_LIBRARY_PATH decoy wins (RUNPATH, accepted) -> exit 127"; fi
    ;;
*) echo "SKIP  bundle loader (this host's glibc does not support x86-64-v3: dl_hwcaps_subdirs_active=[$active])" ;;
esac

# ---- uncached ----------------------------------------------------------------
if [ "$uncached" = 1 ]; then
    for side in a b; do
        (timeout 900 "$BUCK2" --isolation-dir "komira_checks_bundle_$side" build --no-remote-cache \
            //examples:hello_bundle //examples:hello_tarball "//examples:hello_image[digest]" \
            "//examples:hello_image[docker_archive]" --materializations all --show-full-output \
            > "$W/uncached_$side.out" 2> "$W/uncached_$side.log"; echo "$?" > "$W/uncached_$side.rc") &
    done
    wait
    problems=""
    for side in a b; do
        if [ "$(cat "$W/uncached_$side.rc")" != 0 ]; then
            problems="$problems build-$side-failed"
        else
            out_of() { sed -n "s|^komira//examples:$1 ||p" "$W/uncached_$side.out"; }
            {
                listing "$(out_of hello_bundle)"
                echo "tarball $(sha256sum < "$(out_of hello_tarball)" | cut -c1-64)"
                echo "image $(cat "$(out_of 'hello_image\[digest\]')")"
                echo "docker_archive $(sha256sum < "$(out_of 'hello_image\[docker_archive\]')" | cut -c1-64)"
            } > "$W/listing_$side.txt"
            for t in hello_bundle hello_tarball 'hello_image\[digest\]' 'hello_image\[docker_archive\]'; do
                o=$(out_of "$t")
                [ -n "$o" ] && [ -s "$o" ] || [ -d "$o" ] || problems="$problems build-$side-has-no-${t%%\\*}"
            done
            grep -qE 'Commands: [0-9]+ \(cached: 0, remote: [1-9]' "$W/uncached_$side.log" || problems="$problems build-$side-did-not-execute"
        fi
    done
    if [ -z "$problems" ] && ! cmp -s "$W/listing_a.txt" "$W/listing_b.txt"; then
        problems=" differ: $(diff "$W/listing_a.txt" "$W/listing_b.txt" | grep '^[<>]' | head -n 4 | tr '\n' ' ')"
    fi
    for side in a b; do "$BUCK2" --isolation-dir "komira_checks_bundle_$side" kill > /dev/null 2>&1; done
    if [ -n "$problems" ]; then
        fail "uncached:$problems (see $W)"
    else
        pass "uncached: two uncached builds give identical bundles ($(($(wc -l < "$W/listing_a.txt") - 3)) files), tarballs, docker archives and image digest $(sed -n 's/^image //p' "$W/listing_a.txt" | cut -c1-19) ($(grep -oE 'Commands: [0-9]+' "$W/uncached_a.log" | tail -n 1))"
    fi
else
    echo "SKIP  bundle uncached (--no-uncached)"
fi

echo "logs: $W"
[ "$fails" = 0 ]
