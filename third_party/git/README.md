# git, the oracle of komira_git

`komira//third_party/git:git` is git 2.56.0, built from source on the farm,
and with the pinned git-lfs 3.8.0 ([`third_party/git-lfs`](../git-lfs/BUCK))
it is the oracle of komira_git's conformance tests: what real git writes and
accepts is what komira_git must write and accept. The target is a directory
(`[bin]` is its `bin/git`):

| path | what |
|---|---|
| `bin/git` | git, linked statically against everything except glibc |
| `libexec/git-core/` | the programs git runs: `git-remote-http` (the HTTP transport, with libcurl), `git-upload-pack`, `git-receive-pack`, and the others of a git install |
| `share/git-core/templates/` | what `git init` copies |
| `share/licenses/` | git's `COPYING` and `LGPL-2.1`, curl's `COPYING`, zlib's `LICENSE`, and a `NOTICE` |

It is test input: nothing ships it and no library or binary links it. A test
names `komira//third_party/git:git` (and `komira//third_party/git-lfs:git-lfs[git-lfs]`)
and runs it as a child process. Its checks are build actions that `:git`
depends on, so no build that uses the oracle succeeds unless they pass
([Checks](#checks)). It is built and checked on linux-x86_64 only (every
target carries `target_compatible_with = LINUX_X86_64` with the marker
`komira-limit:git-oracle-linux-x86-64`,
[limits.tsv](../../tools/build/platforms/limits.tsv)).

## Why from source

A distribution's git links libcurl, OpenSSL, PCRE, libexpat and more
dynamically, which a worker does not have, and its glibc floor is that
distribution's. Built here, as [kcov](../../tools/build/toolchains/kcov/README.md)
is:

- every library except glibc is linked from a static archive, and the glibc
  floor is the platform row's own (`zig_triple`, `x86_64-linux-gnu.2.34`): zig
  links against glibc 2.34's symbols, so the link fails if git or curl calls a
  newer one, and check 3 reads the symbol versions of the result;
- nothing is taken from the worker: the compiler is the pinned zig, the
  shell and utilities are the pinned busybox, and every input is a sha256 pin.
  The one exception is at run time: git runs `/bin/sh` for shell aliases,
  hooks, and the commands it starts through a shell;
- libcurl is HTTP only, without TLS and without proxy support: the
  conformance tests talk to servers on the loopback, and no proxy variable a
  worker sets can redirect them.

## What is pinned

| target | what |
|---|---|
| `:git-2.56.0.tar.gz` | git's release archive from kernel.org (GPL-2.0-only); kernel.org's `sha256sums.asc` lists the same sha256 |
| `:curl-8.22.0.tar.gz` | curl's release archive from curl.se (the curl licence) |
| `:make-4.4.1.tar.gz` | GNU make's release archive from ftp.gnu.org (GPL-3.0-or-later), the build tool of curl and git; nothing of it is in the distribution |
| `//third_party/zlib:zlib-1.3.1.tar.gz` | zlib's release archive, the pin komira_zlib's tests already use |
| `//third_party/git-lfs:git-lfs-linux-amd64.tar.gz` | git-lfs's release binary archive (MIT); the release notes list the same sha256 |

A pin bump changes the pin and `_VERSION` (or `_LFS_VERSION`) in
[`BUCK`](BUCK); check 2 (or 9) fails until both agree.

## How it is built

[`git_build.sh`](git_build.sh) runs as two actions ([`defs.bzl`](defs.bzl)).
Both put a directory of busybox applets and four wrappers, `cc`
(`zig cc -target <zig_triple>`), `ar`, `ranlib` and `ld` (`zig ld.lld`, which
make's `configure` looks for), on an otherwise empty `PATH`.

1. **`:deps`.** GNU make, from its `configure` and `build.sh` (which needs no
   make). zlib, its fifteen library sources compiled with the flags its
   `configure` picks on Linux and archived into `libz.a`. libcurl, from its
   `configure` (static only, no TLS, no proxy, every protocol but HTTP
   disabled) and `make` in `lib/`; the action fails if `curl_config.h` shows
   proxy support, a TLS backend, or no HTTP.
2. **`:git_dist`.** git's own Makefile, run by that make with `NO_PERL`,
   `NO_PYTHON`, `NO_TCLTK`, `NO_GETTEXT`, `NO_EXPAT` (no WebDAV push; smart
   HTTP push needs none), `NO_OPENSSL` (git's built-in SHA-1 with
   collision detection) and `NO_RUST` (git 2.x's Rust code is optional and
   needs cargo; git 3.0 makes it required, so a pin to 3.0 has to build it), `ZLIB_PATH` and `CURLDIR` naming `:deps`, and:
   - `RUNTIME_PREFIX`: git finds `libexec/git-core` and its templates relative
     to `/proc/self/exe`, so the directory works wherever buck2 materializes
     it, and the system config it reads is `<dist>/etc/gitconfig` (there is
     none), never the worker's `/etc/gitconfig`;
   - `INSTALL_SYMLINKS`: the `git-<builtin>` programs of `libexec/git-core`
     are relative symlinks to `bin/git`, not copies. They are not skipped
     (`SKIP_DASHED_BUILT_INS`): git runs some by name, `git-upload-pack` for a
     `file://` clone among them;
   - `LINK_FUZZ_PROGRAMS` empty: `config.mak.uname` links git's oss-fuzz
     programs on Linux, with a linker flag zig's lld driver refuses;
   - `SHELL_PATH` is the scratch busybox `sh`, which make runs recipes with,
     while the shell compiled into git (`SHELL_PATH_CQ_SQ`) is `/bin/sh`. The
     scripts and hook samples git installs are written with the scratch
     shell's path (in the `#!` line, and in `git-filter-branch`'s body too),
     and the action rewrites it to `/bin/sh`.
   - `-O2 -g0` and `-s`: no debug information, which would hold the worker's
     paths;
   - `CC_LD_DYNPATH` empty: with `ZLIB_PATH` and `CURLDIR` set, git's
     Makefile otherwise gives every program a run path (`-Wl,-rpath`) to
     `:deps` on the worker that built it. Both libraries are static, so the
     programs need none.

   The action fails if any installed file names its scratch directory or
   any other path under the action's directory on the worker.

## Checks

[`git_check.sh`](git_check.sh) runs as the validation `:git_check`, which
`:git` depends on. Every git command runs with `PATH` set to a directory of
decoys ahead of the busybox applets: programs named `git`,
`git-upload-pack`, `git-receive-pack`, `git-remote-http` and `git-lfs` that
record that they ran and exit 97. git puts its own exec path ahead of `PATH`,
so a decoy runs only when something reaches for a git other than the one
under test. Each row names the defect the check catches and the planted
defect it was seen to fail on.

| # | check | catches | planted, red |
|---|---|---|---|
| 1 | the distribution holds `bin/git`, `git-remote-http`, `git-upload-pack`, `git-receive-pack` and the licence files, and no shared library | a build without the HTTP transport (no libcurl found), a missing licence | `LGPL-2.1` not copied: `the distribution has no share/licenses/git/LGPL-2.1` |
| 2 | `git --version` prints `git version 2.56.0` | the wrong source, a git that does not start | `_VERSION` set to `2.55.0`: `git --version printed 'git version 2.56.0', want 'git version 2.55.0'` |
| 3 | no `GLIBC_2.<n>` above the row's floor in any ELF file | git or curl needing a newer glibc than the workers and users have | the floor passed as 27 (git itself is not rebuilt): `the programs need GLIBC_2.28 GLIBC_2.33 GLIBC_2.34 above the floor GLIBC_2.27` |
| 4 | the loader's list for `bin/git`, `git-remote-http` and `git-http-fetch` (the programs that link libcurl) names glibc's libraries only | libcurl or zlib linked dynamically, so taken from the worker | `libc.so.6` dropped from the check's list of glibc libraries: `bin/git loads libc.so.6, which is not glibc's` |
| 5 | `git --exec-path` is the distribution's `libexec/git-core` | a git built without `RUNTIME_PREFIX`, which looks for its programs at a path compiled in, and on a worker with git installed finds that git's | git built without `RUNTIME_PREFIX`: `git --exec-path is '/git/libexec/git-core', not the distribution's libexec/git-core` |
| 6 | `hash-object` of `hello\n`, the empty tree, and a commit with fixed identities and dates are the SHA-1s of the object bytes computed by busybox `sha1sum` | a git that does not start or write objects; the object format | the expected blob computed from `hellp\n`: `hash-object of 'hello\n' is <id>, want <other id>` |
| 7 | `clone --no-local` over `file://` (git-upload-pack) and `push` (git-receive-pack) carry that commit, and `fsck --strict` passes on both sides | the pack protocol's programs missing from the exec path | `git-upload-pack` deleted after the build's own install check, and dropped from check 1's list: `git clone over file:// failed` |
| 8 | `ls-remote` to `http://127.0.0.1:1/r` fails in libcurl's connect, and to `https://...` as a disabled protocol (whole messages) | a git without the HTTP transport; a libcurl with TLS | the first expected messages, written before libcurl 8.22's were seen (`... port 1`, `... not supported`): each red with the message libcurl prints |
| 9 | `git-lfs version` (with the distribution's `bin/` first on `PATH`) prints `git-lfs/3.8.0 ...`, and `git lfs version` prints the same line | the wrong git-lfs pin; a git that cannot run git-lfs from `PATH` | `_LFS_VERSION` set to `3.7.0`: `git-lfs version printed 'git-lfs/3.8.0 (...)', want 'git-lfs/3.7.0 ...'` |
| 10 | no decoy ran | a git, or a check, that ran a program from `PATH` instead of the distribution | git-lfs run alone with only the decoys on `PATH`: `a git from PATH ran instead of the distribution's: git version git ... rev-parse --git-dir ...` |

The build actions refuse a wrong result too, each seen red on a planted
defect:

| refusal | planted, red |
|---|---|
| a source archive whose sha256 is not the pin (buck2's download) | the git pin's sha256 with one digit changed: `Invalid sha256 digest. Expected 826817fe..., got 826817fd...` |
| `curl_config.h` with proxy support, a TLS backend, or no HTTP | `--disable-proxy` dropped: `git_build: libcurl was configured with proxy support` |
| an installed file naming the action's scratch directory | the `#!` rewrite skipped: `git_build: these files name the build's scratch directory: .../templates/hooks/post-update.sample` |
| an installed file naming a path under the action's directory | `CC_LD_DYNPATH=` dropped: `git_build: these files name the build's scratch directory: /worker/build/<id>/root/.../git/bin/git`, then `bin/git-upload-pack`, `bin/scalar` and the other programs (the run path to `:deps`) |
| git's `README.md` or `compat/regex/regex.c` no longer holding the sentence the `NOTICE` relies on (the GPLv2-compatible statement; LGPL-2.1-or-later), say after a version bump | the regex.c row of `cites` given `README.md` as its file: `git_build: git's README.md does not say: under the terms of the GNU Lesser General Public License ...` |
| a `NOTICE` sentence that cites `README.md` or `compat/regex/regex.c` but does not make that file's claim (`compatible with GPLv2`; `LGPL-2.1-or-later`), makes the other file's claim, or a `NOTICE` that does not cite one of them (the check reads the `NOTICE` the build wrote, split into sentences) | the earlier `NOTICE` text that called compat/regex LGPL-2.1 as README.md says: `git_build: the NOTICE cites git's README.md in a sentence that does not say "compatible with GPLv2": git is GPL-2.0-only ...`; the two claims joined into one sentence: `git_build: the NOTICE cites git's README.md for "LGPL-2.1-or-later", which compat/regex/regex.c says: ...`; regex.c named as "its regex.c": `git_build: the NOTICE does not cite git's compat/regex/regex.c`; the `NOTICE`'s last sentence, which ends without a period, made to cite `README.md` (the reader once skipped that unterminated last line, and both of these built green): `regex LGPL-2.1 (git/LGPL-2.1), as git's README.md says` appended gives `git_build: the NOTICE cites git's README.md in a sentence that does not say "compatible with GPLv2": bin/git and the programs of libexec/git-core also hold ...`, and `; git's README.md says parts are compatible with GPLv2 and LGPL-2.1-or-later` appended gives `git_build: the NOTICE cites git's README.md for "LGPL-2.1-or-later", which compat/regex/regex.c says: bin/git and the programs of libexec/git-core also hold ...` |
| `bin/git`, `git-remote-http`, `git-upload-pack` or `git-receive-pack` not installed | `NO_CURL`: `git_build: libexec/git-core/git-remote-http was not installed`; `SKIP_DASHED_BUILT_INS`: the same for `git-upload-pack` |

git-lfs runs `git` from `PATH` (`git version`, `git rev-parse`, `git
remote`, even for `git-lfs version`); check 10 caught that when check 9 first
ran git-lfs with only the decoys on `PATH`. A test that runs git-lfs itself
puts the distribution's `bin/` first on `PATH`. Run by git (`git lfs ...`),
git-lfs finds the distribution's git through the exec path git puts first.

## Licences

git is GPL-2.0-only, with parts under other GPLv2-compatible licences
(compat/regex is LGPL-2.1-or-later, as its header says); curl is under the curl
licence and zlib under the zlib licence; GNU make (GPL-3.0-or-later) only
builds and is not in the distribution. As with kcov, the repository holds
only the recipe: the sources are fetched by their pinned hashes and built on
the build's own machines, and the result is a build-time and test-time tool
that no komira package links or ships. A remote cache that holds the built
git must stay private to the people who build komira; making it readable by
others distributes git, with GPL-2.0's obligation to offer its source.
