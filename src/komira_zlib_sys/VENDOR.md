# Vendored C: zlib

The C in `vendor/zlib-1.3.2/` is zlib, copied unmodified from the upstream release tarball. Nothing in
it was edited, renamed or reformatted.

| | |
|---|---|
| project | zlib, <https://zlib.net/> |
| version | 1.3.2 |
| tarball | `zlib-1.3.2.tar.gz`, 1502830 bytes |
| url | `https://zlib.net/zlib-1.3.2.tar.gz` |
| same file from | `https://github.com/madler/zlib/releases/download/v1.3.2/zlib-1.3.2.tar.gz` |
| sha256 | `bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16` |
| licence | zlib License (SPDX `Zlib`), permissive: the text is `vendor/zlib-1.3.2/LICENSE` |

## Where the checksum comes from

The sha256 is the one zlib's download page lists for this tarball. The tarball downloaded from the
project's site and the release asset of the project's repository have the same sha256. The
detached signature the site publishes for it (`zlib-1.3.2.tar.gz.asc`) verifies as a good signature of the
tarball by the key with fingerprint `5ED4 6A67 21D3 6558 7791  E2AA 783F CD8E 58BC AFBA`, the zlib
maintainers' release key (fetched from a public key server; its signature was checked, the key was not
otherwise certified).

## What is vendored

Of the tarball, only what the library needs to compile:

- the C sources of the library: `adler32.c`, `compress.c`, `crc32.c`, `deflate.c`, `gzclose.c`, `gzlib.c`,
  `gzread.c`, `gzwrite.c`, `infback.c`, `inffast.c`, `inflate.c`, `inftrees.c`, `trees.c`, `uncompr.c`,
  `zutil.c` (the list of `ZLIB_SRCS` in the tarball's `CMakeLists.txt`);
- the headers they include: `crc32.h`, `deflate.h`, `gzguts.h`, `inffast.h`, `inffixed.h`, `inflate.h`,
  `inftrees.h`, `trees.h`, `zutil.h`, and the two public ones, `zconf.h` and `zlib.h`;
- `LICENSE`, which zlib's licence requires to stay with the source.

No examples, no tests, no `contrib/`, no build scripts (`configure`, `Makefile`, `CMakeLists.txt`) and no
documentation. None of the tarball's scripts was run: the files were read and copied.

## How it is checked

To re-verify by hand: download the tarball from the url above, compare its sha256 with the one in the
table, and compare each file of `vendor/zlib-1.3.2/` with the file of the same name under `zlib-1.3.2/` in
the tarball (they are identical). A build check that does this (fetch by sha256, compare every file, and
read the sha256 back from this file) is planned with the package's build files.

## Updating

A new zlib release replaces the directory (`vendor/zlib-<version>/`), this file, `mopm.toml`'s version and
paths, and the version string in `tests/test_zlib.mojo`. The sha256 comes from the project's download page
and the signature is verified as above; both are recorded here.
