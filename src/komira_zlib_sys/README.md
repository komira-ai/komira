# komira_zlib_sys

zlib 1.3.2 as a static native library for Mojo. The package is meant to ship `lib/libkomira_zlib_sys.a`,
the unmodified zlib C sources compiled for x86-64 Linux, and an empty Mojo module. It is the raw layer: it
has no Mojo API. A Mojo package that needs zlib lists `komira_zlib_sys` as a dependency, declares the zlib
functions it calls with `external_call` in the module that owns that use, and wraps them in a safe
function (that wrapper is `komira_zlib`'s place, not this package's).

zlib's licence is permissive (the zlib License, SPDX `Zlib`). `vendor/zlib-1.3.2/LICENSE` is its text, as
upstream ships it, and `mopm.toml` declares `license = "Zlib"`. A program that links this archive
statically redistributes zlib, so its distribution carries that notice.

Where the C comes from: [`VENDOR.md`](VENDOR.md).

Status: the sources, the manifest and the test are here; the build files are not. The archive is declared as
the package's own `[native.komira_zlib_sys]` in `mopm.toml` (sources, headers and flags), and the build
that compiles a member's own native and links it into the package's tests waits for buildrules and mopm
support for it.

## Test

`tests/test_zlib.mojo` calls zlib through FFI, from the test only, as a consumer of the archive would:
`zlibVersion()` is 1.3.2; `crc32` and `adler32` give the published check values and are incremental;
`compress2` then `uncompress` returns the input at every level, for text, incompressible bytes and nothing;
`compress2` of `abc` gives the exact stream RFC 1950 and RFC 1951 give, at the default level and at level 0;
a stream it did not write is read; a flipped checksum, a flipped data byte, a truncated stream and a
too-small buffer are refused with the right code.
