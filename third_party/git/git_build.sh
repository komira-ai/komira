#!/bin/sh
# Builds git from its pinned source archive with the pinned zig, in two build
# actions of the `git_build` rule (defs.bzl, README.md):
#   sh git_build.sh deps <busybox> <zig_dir> <zig_triple> <out_dir> curl=<tar.gz> make=<tar.gz> zlib=<tar.gz>
#   sh git_build.sh git  <busybox> <zig_dir> <zig_triple> <out_dir> deps=<deps_dir> git=<tar.gz>
# `deps` builds GNU make (its configure and build.sh, which need no make),
# zlib (its sources compiled directly) and libcurl (its configure and make)
# into <out_dir>: bin/make, lib/libz.a, lib/libcurl.a, include/, and
# share/licenses/{zlib,curl}/.
# `git` builds git with that make against those archives into <out_dir>:
# bin/git, libexec/git-core/, share/git-core/templates/, share/licenses/.
#
# Every program runs from the pinned busybox and zig: PATH is a directory of
# busybox applets plus the cc/ar/ranlib/ld wrappers written below, so nothing is
# taken from the worker but its kernel and the glibc the programs link.
# Every library is static except glibc, whose floor is <zig_triple>'s.
set -eu
# shellcheck disable=SC3040 # busybox sh (ash) has pipefail
set -o pipefail

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
MODE=$1
BB=$(abs "$2")
ZIG=$(abs "$3")/zig
TRIPLE=$4
OUT=$(abs "$5")
shift 5

# Private scratch (as in tools/build/mojo/toolchain.bzl).
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.git_build_$MODE" ;;
    /*) T="$BUCK_SCRATCH_PATH/git_build_$MODE" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/git_build_$MODE" ;;
esac
"$BB" mkdir -p "$T/bin" "$T/home" "$T/tmp" "$T/tools"
"$BB" --install -s "$T/bin"
SH="$T/bin/sh"
# The compiler, archiver, indexer and linker every configure and Makefile
# calls (make's configure looks for an `ld`; the compiler drives the link).
for tool in cc ar ranlib ld; do
    case $tool in
        cc) cmd="\"$ZIG\" cc -target $TRIPLE" ;;
        ld) cmd="\"$ZIG\" ld.lld" ;;
        *) cmd="\"$ZIG\" $tool" ;;
    esac
    printf '#!%s\nexec %s "$@"\n' "$SH" "$cmd" >"$T/tools/$tool"
    "$BB" chmod 755 "$T/tools/$tool"
done
PATH="$T/tools:$T/bin"
ZIG_GLOBAL_CACHE_DIR="$T/zig-global"
ZIG_LOCAL_CACHE_DIR="$T/zig-local"
HOME="$T/home"
TMPDIR="$T/tmp"
CONFIG_SHELL=$SH
export PATH LC_ALL=C ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR HOME TMPDIR CONFIG_SHELL
unset CC CFLAGS CPPFLAGS LDFLAGS LIBS MAKEFLAGS MFLAGS
JOBS=$(nproc)

# The name=path arguments.
IN_curl="" IN_deps="" IN_git="" IN_make="" IN_zlib=""
for spec in "$@"; do
    p=$(abs "${spec#*=}")
    case "${spec%%=*}" in
        curl) IN_curl=$p ;;
        deps) IN_deps=$p ;;
        git) IN_git=$p ;;
        make) IN_make=$p ;;
        zlib) IN_zlib=$p ;;
        *) echo "git_build: unknown input $spec" >&2; exit 2 ;;
    esac
done

# Unpacks <archive> into $T/src and prints the one top directory it holds.
unpack() {
    d="$T/src/$(basename "$1")"
    mkdir -p "$d"
    tar -xzf "$1" -C "$d"
    top=$(ls "$d")
    [ "$(echo "$top" | wc -l)" = 1 ] || { echo "git_build: $1 has more than one top directory" >&2; exit 2; }
    printf '%s/%s' "$d" "$top"
}

# Runs "$@" with its output in $T/log; on failure prints the log's tail.
logged() {
    if ! "$@" >"$T/log" 2>&1; then
        echo "git_build $MODE: failed: $*" >&2
        tail -n 60 "$T/log" >&2
        exit 1
    fi
}

deps() {
    mkdir -p "$OUT/bin" "$OUT/lib" "$OUT/include/curl" "$OUT/share/licenses/zlib" "$OUT/share/licenses/curl"

    # GNU make, with no make: its configure, then build.sh.
    m=$(unpack "$IN_make")
    (cd "$m" && logged "$SH" ./configure --disable-nls --without-guile --disable-dependency-tracking CC=cc CFLAGS="-O2 -g0")
    (cd "$m" && logged "$SH" ./build.sh)
    cp "$m/make" "$OUT/bin/make"

    # zlib: the library sources of its Makefile, with the flags its configure
    # chooses on Linux.
    z=$(unpack "$IN_zlib")
    mkdir -p "$T/zlib"
    for f in adler32 compress crc32 deflate gzclose gzlib gzread gzwrite infback inffast inflate inftrees trees uncompr zutil; do
        cc -O2 -g0 -fPIC -D_LARGEFILE64_SOURCE=1 -DHAVE_HIDDEN -I"$z" -c "$z/$f.c" -o "$T/zlib/$f.o"
    done
    ar rcs "$OUT/lib/libz.a" "$T"/zlib/*.o
    cp "$z/zlib.h" "$z/zconf.h" "$OUT/include/"
    cp "$z/LICENSE" "$OUT/share/licenses/zlib/LICENSE"

    # libcurl: HTTP only, without TLS (the oracle talks to servers on the
    # loopback), without proxies (no proxy variable of the worker can
    # redirect it), static only. Only lib/ is built: git links libcurl.a.
    c=$(unpack "$IN_curl")
    (cd "$c" && logged "$SH" ./configure \
        --disable-shared --enable-static --disable-dependency-tracking \
        --without-ssl --with-zlib="$OUT" --without-brotli --without-zstd --without-libpsl \
        --without-libidn2 --without-nghttp2 --without-nghttp3 --without-ngtcp2 --without-libssh2 \
        --without-libssh --without-libgsasl --without-ca-bundle --without-ca-path --without-ca-fallback \
        --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet --disable-tftp \
        --disable-pop3 --disable-imap --disable-smb --disable-smtp --disable-gopher --disable-mqtt \
        --disable-ftp --disable-file --disable-ipfs --disable-websockets --disable-proxy \
        --disable-ntlm --disable-kerberos-auth --disable-negotiate-auth --disable-aws \
        --disable-manual --disable-docs \
        CC=cc AR=ar RANLIB=ranlib CFLAGS="-O2 -g0")
    (cd "$c/lib" && logged "$OUT/bin/make" -j"$JOBS" SHELL="$SH" libcurl.la)
    cp "$c/lib/.libs/libcurl.a" "$OUT/lib/libcurl.a"
    cp "$c"/include/curl/*.h "$OUT/include/curl/"
    cp "$c/COPYING" "$OUT/share/licenses/curl/COPYING"
    # What the oracle depends on, as configure recorded it: HTTP in,
    # proxies and every TLS backend out.
    grep -qxF '#define CURL_DISABLE_PROXY 1' "$c/lib/curl_config.h" || { echo "git_build: libcurl was configured with proxy support" >&2; exit 2; }
    if grep -q '^#define CURL_DISABLE_HTTP \|^#define USE_OPENSSL \|^#define USE_GNUTLS \|^#define USE_MBEDTLS \|^#define USE_WOLFSSL \|^#define USE_RUSTLS ' "$c/lib/curl_config.h"; then
        echo "git_build: libcurl was configured without HTTP or with a TLS backend" >&2
        exit 2
    fi
}

git_() {
    D=$IN_deps
    g=$(unpack "$IN_git")
    # SHELL_PATH is the shell make runs recipes with; SHELL_PATH_CQ_SQ is the
    # one compiled into git (for shell aliases and hooks), the usual /bin/sh,
    # not this action's scratch busybox.
    # RUNTIME_PREFIX: git finds libexec/git-core and its templates relative
    # to /proc/self/exe, so the directory works wherever it is materialized,
    # and the system config it reads is <dist>/etc/gitconfig, not /etc's.
    # INSTALL_SYMLINKS: the git-<builtin> programs of libexec/git-core are
    # relative symlinks to bin/git, not copies. They stay: git runs some of
    # them by name (git-upload-pack for a file:// clone).
    # NO_RUST: git 2.x's Rust code is optional and needs cargo.
    # LINK_FUZZ_PROGRAMS empty: config.mak.uname links the oss-fuzz programs
    # on Linux, with a linker flag zig's lld driver refuses.
    # CC_LD_DYNPATH empty: ZLIB_PATH and CURLDIR otherwise add a run path
    # (-Wl,-rpath) naming :deps on this worker to every program; both
    # libraries are static, so the programs need no run path.
    set -- -C "$g" -j"$JOBS" \
        prefix=/git \
        CC=cc AR=ar \
        "SHELL_PATH=$SH" 'SHELL_PATH_CQ_SQ="/bin/sh"' \
        CFLAGS="-O2 -g0" LDFLAGS="-s" \
        NO_PERL=YesPlease NO_PYTHON=YesPlease NO_TCLTK=YesPlease NO_GETTEXT=YesPlease \
        NO_EXPAT=YesPlease NO_OPENSSL=YesPlease NO_RUST=YesPlease LINK_FUZZ_PROGRAMS= \
        RUNTIME_PREFIX=YesPlease INSTALL_SYMLINKS=YesPlease \
        ZLIB_PATH="$D" CURLDIR="$D" CC_LD_DYNPATH= CURL_CONFIG=false CURL_LDFLAGS="-lcurl -lz"
    logged "$D/bin/make" "$@" all
    logged "$D/bin/make" "$@" DESTDIR="$T/inst" install
    cp -a "$T/inst/git/." "$OUT/"

    # Shell scripts and hook samples are written with `$(SHELL_PATH)` in
    # their `#!` line (and git-filter-branch in its body too): give them the
    # /bin/sh compiled into git. Only scripts: an ELF file naming the scratch
    # shell fails the check below.
    find "$OUT" -type f | while read -r f; do
        if [ "$(head -c 2 "$f")" = '#!' ] && grep -qF "$SH" "$f"; then
            sed -i "s|$SH|/bin/sh|g" "$f"
        fi
    done
    # No file names this action's scratch directory or any other path under
    # the action's root (a run path to :deps, say): those paths differ on
    # every worker, and would make every build of git differ.
    if leaked=$(grep -rlF -e "$T" -e "$PWD/" "$OUT"); then
        echo "git_build: these files name the build's scratch directory: $leaked" >&2
        exit 2
    fi
    for need in bin/git libexec/git-core/git-remote-http libexec/git-core/git-upload-pack libexec/git-core/git-receive-pack; do
        [ -f "$OUT/$need" ] && [ -x "$OUT/$need" ] || { echo "git_build: $need was not installed" >&2; exit 2; }
    done

    mkdir -p "$OUT/share/licenses/git"
    cp "$g/COPYING" "$g/LGPL-2.1" "$OUT/share/licenses/git/"
    cp -a "$D/share/licenses/." "$OUT/share/licenses/"
    # The NOTICE says which file of git's source says each licence. Each row
    # of `cites` is <file>|<sentence the file holds>|<what the NOTICE says
    # where it cites the file>. After writing the NOTICE the build refuses it
    # unless (1) each file holds its sentence (runs of blanks and newlines read
    # as one space; grep without -q reads all its input, so tr is never cut off
    # by SIGPIPE under pipefail) and (2) the NOTICE, read as sentences, names
    # each file, and every sentence naming a file says that row's claim and no
    # other row's. The split leaves the last sentence with no newline (tr
    # turns the NOTICE's own into a space), so the reader also takes a last
    # line that read reports as unterminated.
    says() {
        tr -s ' \t\n' '   ' <"$g/$1" | grep -F "$2" >/dev/null || {
            echo "git_build: git's $1 does not say: $2" >&2
            exit 2
        }
    }
    cites='README.md|some parts of it are under different licenses, compatible with the GPLv2|compatible with GPLv2
compat/regex/regex.c|under the terms of the GNU Lesser General Public License as published by the Free Software Foundation; either version 2.1 of the License, or (at your option) any later version.|LGPL-2.1-or-later'
    cat >"$OUT/share/licenses/NOTICE" <<'EOF'
This directory is git, built from its release source archive. git is
GPL-2.0-only (git/COPYING); git's README.md says some parts of it are
under different licences, compatible with GPLv2. compat/regex is
LGPL-2.1-or-later (git/LGPL-2.1), as the header of compat/regex/regex.c
says.

bin/git and the programs of libexec/git-core also hold, linked statically:
  zlib       Zlib (zlib/LICENSE)
  libcurl    curl (curl/COPYING), in git-remote-http (and its links
             git-remote-https, git-remote-ftp, git-remote-ftps) and
             git-http-fetch only
EOF
    printf '%s\n' "$cites" >"$T/cites"
    tr -s ' \t\n' '   ' <"$OUT/share/licenses/NOTICE" | sed 's/\. /.\n/g' >"$T/notice_sentences"
    while IFS='|' read -r file sentence claim; do
        says "$file" "$sentence"
        named=0
        while IFS= read -r s || [ -n "$s" ]; do
            case "$s" in *"$file"*) ;; *) continue ;; esac
            named=1
            case "$s" in
                *"$claim"*) ;;
                *) echo "git_build: the NOTICE cites git's $file in a sentence that does not say \"$claim\": $s" >&2; exit 2 ;;
            esac
            while IFS='|' read -r other _ other_claim; do
                if [ "$other" != "$file" ]; then
                    case "$s" in
                        *"$other_claim"*) echo "git_build: the NOTICE cites git's $file for \"$other_claim\", which $other says: $s" >&2; exit 2 ;;
                    esac
                fi
            done <"$T/cites"
        done <"$T/notice_sentences"
        if [ "$named" = 0 ]; then
            echo "git_build: the NOTICE does not cite git's $file" >&2
            exit 2
        fi
    done <"$T/cites"
}

case "$MODE" in
    deps) deps ;;
    git) git_ ;;
    *) echo "git_build: unknown mode $MODE" >&2; exit 2 ;;
esac
rm -rf "$T"
