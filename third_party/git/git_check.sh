#!/bin/sh
# The checks of the git oracle, one build action of the `git_check`
# validation (defs.bzl, README.md "Checks"):
#   sh git_check.sh <busybox> <report_dir> <git_dir> <git-lfs> <version> <lfs_version> <glibc_floor_minor>
# Exits 1 on the first wrong result, naming it; otherwise writes
# <report_dir>/validation.json, the validation result.
#
# Every git command runs with PATH set to a directory of decoys ahead of the
# busybox applets: programs named git, git-upload-pack, git-receive-pack,
# git-remote-http and git-lfs that record that they ran and fail. git finds
# its own programs through its exec path (RUNTIME_PREFIX), which it puts
# ahead of PATH, so a decoy runs only if git, or this script, reaches for a
# git other than the one under test.
#   1. The distribution holds bin/git, the programs of libexec/git-core and
#      the licence files, and no shared library.
#   2. `git --version` prints `git version <version>`.
#   3. No GLIBC_2.<n> symbol version above the floor in any of its programs.
#   4. The loader's list for bin/git, git-remote-http and git-http-fetch
#      holds glibc's libraries only: libcurl and zlib are linked in.
#   5. `git --exec-path` is the distribution's libexec/git-core.
#   6. The object ids git computes are the SHA-1s of the object bytes
#      (busybox sha1sum): a blob, the empty tree, and a commit with fixed
#      identities and dates.
#   7. Clone over the pack protocol (file://, git-upload-pack) and push
#      (git-receive-pack) carry that commit; fsck --strict passes on both.
#   8. The HTTP transport is compiled in and HTTPS is not: ls-remote to a
#      closed port on 127.0.0.1 fails in libcurl's connect, and to an https
#      URL fails as a disabled protocol (libcurl's whole messages).
#   9. `git-lfs version` prints `git-lfs/<lfs_version> `, and `git lfs
#      version`, which git runs as git-lfs from PATH, prints the same line.
#      git-lfs runs `git` from PATH, so a test that runs git-lfs itself puts
#      the distribution's bin/ first on PATH, as this check does.
#  10. No decoy ran.
set -eu
# shellcheck disable=SC3040 # busybox sh (ash) has pipefail
set -o pipefail

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
BB=$(abs "$1")
REPORT=$(abs "$2")
DIST=$(abs "$3")
LFS=$(abs "$4")
VERSION=$5
LFS_VERSION=$6
FLOOR=$7

case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.git_check" ;;
    /*) T="$BUCK_SCRATCH_PATH/git_check" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/git_check" ;;
esac
"$BB" mkdir -p "$T/bin" "$T/home" "$T/decoy" "$T/lfs"
"$BB" --install -s "$T/bin"
PATH="$T/decoy:$T/bin"
HOME="$T/home"
export PATH LC_ALL=C HOME
export GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat
mkdir -p "$REPORT"
N=0
GIT="$DIST/bin/git"

red() {
    echo "git_check RED: $*" >&2
    [ -f "$T/log" ] && { echo "--- log:" >&2; tail -n 40 "$T/log" >&2; }
    exit 1
}
pass() { N=$((N + 1)); }

for d in git git-upload-pack git-receive-pack git-remote-http git-lfs; do
    printf '#!%s/sh\necho "%s $*" >>"%s/decoy_ran"\nexit 97\n' "$T/bin" "$d" "$T" >"$T/decoy/$d"
    chmod 755 "$T/decoy/$d"
done
cp "$LFS" "$T/lfs/git-lfs"
chmod 755 "$T/lfs/git-lfs"

# 1. The files.
for f in bin/git libexec/git-core/git-remote-http libexec/git-core/git-upload-pack libexec/git-core/git-receive-pack \
    share/licenses/NOTICE share/licenses/git/COPYING share/licenses/git/LGPL-2.1 share/licenses/curl/COPYING \
    share/licenses/zlib/LICENSE; do
    [ -s "$DIST/$f" ] || red "the distribution has no $f"
done
so=$(find "$DIST" -name '*.so' -o -name '*.so.*')
[ -z "$so" ] || red "the distribution holds shared libraries: $so"
pass

# 2. The version.
got=$("$GIT" --version 2>&1) || red "git --version failed: $got"
[ "$got" = "git version $VERSION" ] || red "git --version printed '$got', want 'git version $VERSION'"
pass

# The regular files of the distribution that are ELF programs.
find "$DIST" -type f | sort | while read -r f; do
    if [ "$(head -c 4 "$f" | od -An -c | tr -d ' ')" = '177ELF' ]; then echo "$f"; fi
done >"$T/elfs"
[ -s "$T/elfs" ] || red "found no ELF program in the distribution"

# 3. The glibc floor. Version names are strings of the dynamic string table.
over=$(cat "$T/elfs" | while read -r f; do cat "$f"; done | strings -n 8 |
    { grep -o 'GLIBC_2\.[0-9][0-9.]*' || [ "$?" = 1 ]; } | sort -u | awk -F. -v f="$FLOOR" '$2 + 0 > f + 0 { print }')
[ -z "$over" ] || red "the programs need $(echo "$over" | tr '\n' ' ')above the floor GLIBC_2.$FLOOR"
pass

# 4. What the loader maps: glibc's libraries and nothing else.
for p in bin/git libexec/git-core/git-remote-http libexec/git-core/git-http-fetch; do
    LD_TRACE_LOADED_OBJECTS=1 "$DIST/$p" >"$T/log" 2>&1 || red "the loader failed on $p"
    while read -r name _; do
        case "$name" in
            linux-vdso.so.1 | libc.so.6 | libm.so.6 | libpthread.so.0 | libdl.so.2 | librt.so.1 | /lib64/ld-linux-x86-64.so.2) ;;
            *) red "$p loads $name, which is not glibc's" ;;
        esac
    done <"$T/log"
done
pass

# 5. The exec path is the distribution's own.
got=$("$GIT" --exec-path 2>&1) || red "git --exec-path failed: $got"
[ "$(realpath "$got")" = "$(realpath "$DIST/libexec/git-core")" ] || red "git --exec-path is '$got', not the distribution's libexec/git-core"
pass

# 6. Object ids against sha1sum of the object bytes.
R="$T/repo"
"$GIT" init -q -b main "$R" >"$T/log" 2>&1 || red "git init failed"
sha() { sha1sum | cut -c1-40; }
printf 'hello\n' >"$R/hello.txt"
got=$("$GIT" -C "$R" hash-object -w hello.txt 2>"$T/log") || red "git hash-object failed"
want=$(printf 'blob 6\000hello\n' | sha)
[ "$got" = "$want" ] || red "hash-object of 'hello\\n' is $got, want $want"
tree=$("$GIT" -C "$R" mktree </dev/null 2>"$T/log") || red "git mktree failed"
want=$(printf 'tree 0\000' | sha)
[ "$tree" = "$want" ] || red "the empty tree is $tree, want $want"
body=$(printf 'tree %s\nauthor A U Thor <author@example.com> 1790000000 +0000\ncommitter C O Mitter <committer@example.com> 1790000000 +0000\n\nsmoke\n' "$tree")
printf '%s\n' "$body" >"$T/commit"
commit=$(GIT_AUTHOR_NAME="A U Thor" GIT_AUTHOR_EMAIL=author@example.com GIT_AUTHOR_DATE="1790000000 +0000" \
    GIT_COMMITTER_NAME="C O Mitter" GIT_COMMITTER_EMAIL=committer@example.com GIT_COMMITTER_DATE="1790000000 +0000" \
    "$GIT" -C "$R" commit-tree -m smoke "$tree" 2>"$T/log") || red "git commit-tree failed"
want=$({ printf 'commit %s\000' "$(wc -c <"$T/commit" | tr -d ' ')"; cat "$T/commit"; } | sha)
[ "$commit" = "$want" ] || red "commit-tree gave $commit, want $want"
"$GIT" -C "$R" update-ref refs/heads/main "$commit" >"$T/log" 2>&1 || red "git update-ref failed"
pass

# 7. The pack protocol, both ways.
"$GIT" clone -q --no-local "file://$R" "$T/clone" >"$T/log" 2>&1 || red "git clone over file:// failed"
got=$("$GIT" -C "$T/clone" rev-parse HEAD 2>"$T/log") || red "rev-parse in the clone failed"
[ "$got" = "$commit" ] || red "the clone's HEAD is $got, want $commit"
"$GIT" -C "$T/clone" fsck --strict >"$T/log" 2>&1 || red "fsck --strict of the clone failed"
"$GIT" init -q --bare "$T/bare.git" >"$T/log" 2>&1 || red "git init --bare failed"
"$GIT" -C "$R" push -q "file://$T/bare.git" main >"$T/log" 2>&1 || red "git push over file:// failed"
got=$("$GIT" -C "$T/bare.git" rev-parse refs/heads/main 2>"$T/log") || red "rev-parse in the bare repository failed"
[ "$got" = "$commit" ] || red "the pushed main is $got, want $commit"
"$GIT" -C "$T/bare.git" fsck --strict >"$T/log" 2>&1 || red "fsck --strict of the pushed repository failed"
pass

# 8. The HTTP transport. Port 1 on the loopback has no listener.
if "$GIT" ls-remote http://127.0.0.1:1/r >"$T/log" 2>&1; then red "ls-remote to a closed port succeeded"; fi
# libcurl's message, with the milliseconds it waited written <ms>.
got=$(sed -e 's/ after [0-9]* ms: / after <ms> ms: /' "$T/log")
want="fatal: unable to access 'http://127.0.0.1:1/r/': Failed to connect to 127.0.0.1:1 after <ms> ms: Could not connect to server"
[ "$got" = "$want" ] || red "ls-remote http:// printed '$got', want '$want'"
if "$GIT" ls-remote https://127.0.0.1:1/r >"$T/log" 2>&1; then red "ls-remote to an https URL succeeded"; fi
got=$(cat "$T/log")
want="fatal: unable to access 'https://127.0.0.1:1/r/': Protocol \"https\" is disabled"
[ "$got" = "$want" ] || red "ls-remote https:// printed '$got', want '$want'"
pass

# 9. git-lfs, alone and through git. git-lfs runs `git` from PATH (`git
# version`, `git rev-parse`, `git remote`), so run alone it gets the
# distribution's bin/ first on PATH; run by git, it finds git through the
# exec path git puts first.
got=$(PATH="$DIST/bin:$PATH" "$T/lfs/git-lfs" version 2>&1) || red "git-lfs version failed: $got"
case "$got" in "git-lfs/$LFS_VERSION "*) ;; *) red "git-lfs version printed '$got', want 'git-lfs/$LFS_VERSION ...'" ;; esac
via=$(PATH="$T/lfs:$PATH" "$GIT" lfs version 2>&1) || red "git lfs version failed: $via"
[ "$via" = "$got" ] || red "git lfs version printed '$via', want '$got'"
pass

# 10. No decoy ran.
[ ! -e "$T/decoy_ran" ] || red "a git from PATH ran instead of the distribution's: $(tr '\n' ' ' <"$T/decoy_ran")"
pass

rm -rf "$T"
printf '{"version": 1, "data": {"status": "success", "message": "git_check: %s checks passed"}}\n' "$N" >"$REPORT/validation.json"
echo "git_check GREEN: $N checks"
