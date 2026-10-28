# komira_compression

Byte-stream codec trait and the eight codec implementations, and the codec
API the file formats call.

This package is meant to be the one owner of the codec libraries: the sonames
of libsnappy, libzstd, libbz2 and liblzma, each system library opened once
per process with `dlopen` (`codec_libraries.mojo`). snappy is not linked into
the package: its C API (`snappy_compress`, `snappy_uncompress`,
`snappy_uncompressed_length`) is called through the opened handle.
libz and liblz4 are opened by its implementation layers `komira_zlib` and
`komira_lz4`, which it re-exports.

- `compression` / `compression_codecs`: the `Compression` and
  `ArrowIpcCompression` traits and their conformers (`Snappy`, `Zstd`, `Gzip`,
  `Lz4Raw`, `Lz4Frame`, ...).
- `snappy_block`: `snappy_compress_into`, `snappy_uncompress_into` (never
  writes past `len(dst)`), `snappy_uncompressed_length`,
  `snappy_max_compressed_length`.
- `zstd_frame`: `zstd_compress_into`, `zstd_decompress_into`,
  `zstd_decompress_once` (libzstd's error code handed back, for a
  grow-and-retry caller),
  `zstd_compress_bound`, `zstd_frame_content_size` and its two sentinels.
- `bzip2_buffer`: `bzip2_compress_into`, `bzip2_decompress_into` (None when
  the destination is too small).
- `xz_buffer`: `xz_compress_into`, `xz_decompress_into` (None on
  `LZMA_BUF_ERROR`; a truncated stream is None before xz 5.8.4 and a raise
  with rc=9 from 5.8.4 on).
- `zlib`: komira_zlib's deflate API, with `zlib_inflate_once` for a
  grow-and-retry caller.
- `lz4`: komira_lz4's raw block and frame API, with
  `lz4_frames_decompress_into` for concatenated frames.

Every entry takes Spans: the destination's length is its capacity, and no
signature holds a pointer. When libsnappy, libzstd, libbz2 or liblzma cannot
be loaded, the process aborts at first use with the message
`komira_compression: cannot load <soname>: <the loader's error>`. libz and
liblz4 are opened by `komira_zlib` and `komira_lz4`, which abort with their
own messages (`libz dlopen failed (komira_zlib FFI handle init)` and
`liblz4 dlopen failed (komira_lz4 raw-block handle init)`), naming neither
the soname nor the loader's error.

## Examples

A raw snappy block, compressed and decompressed by the system snappy
library the package opens at run time (the conda package `snappy`, which
installing this package installs):

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_compression.snappy_block import snappy_compress_into, snappy_max_compressed_length
from komira_compression.snappy_block import snappy_uncompress_into, snappy_uncompressed_length

var src: List[UInt8] = [104, 105, 104, 105, 104, 105, 104, 105, 104, 105, 104, 105]
var packed = List[UInt8](length=snappy_max_compressed_length(len(src)), fill=0)
var n = snappy_compress_into(Span(packed), Span(src))
packed.resize(unsafe_uninit_length=n)
assert_equal(snappy_uncompressed_length(Span(packed)), len(src))

var out = List[UInt8](length=len(src), fill=0)  # the destination's length is its capacity
assert_equal(snappy_uncompress_into(Span(out), Span(packed)), len(src))
for i in range(len(src)):
    assert_equal(out[i], src[i])
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_compression`, version 0.1.0
(`mopm.toml`). The library is `src/komira_compression/`, its tests are `tests/`. It depends on two packages,
`komira_lz4` and `komira_zlib`, sibling directories (`[dependencies]` of `mopm.toml`), and opens four system
libraries at run time (`[native-dependencies]`, each `mode = "load"`): libsnappy, libzstd, libbz2 and liblzma. Its
`.conda` records the two Mojo packages and the conda packages `snappy`, `zstd`, `bzip2` and `xz` as dependencies, so
installing `komira_compression` installs everything it opens. It links no C and ships no shared library of its own.
The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the Mojo dependencies, the four libraries it loads and where the library and its tests are |
| `mopm.lock` | the toolchain pins, the two path dependencies and `system_libs`: the conda package of each library it loads, and of what those need, for each platform (`mopm lock` writes them from the catalog of the mopm in `mopm-toolchain.toml`) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `coverage_census.tsv` | what the coverage census measured |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifests of the siblings; `buildrules mojo check` fails when they are stale |

`:lib` is the library file, built from the `:lib` of `komira_lz4` and `komira_zlib`, and exists only once every test
of `tests/` has passed. The tests open the real libraries: a machine that has no `libsnappy.so.1` (and the other
three) fails them at the first codec call, naming the soname. After any change to a source, a test, a manifest of
this package or of a sibling, run `buildrules mojo sync` with the three packages staged, commit what it writes, and
build `komira//src/komira_compression:lib` on the farm.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package
(`mojo-komira_compression-0.1.0-mojo1.0.0_0.conda`), packed with the siblings' manifests beside its own (`members`).
Publishing it (`mopm publish`) uploads, so it is a step of a CI job that takes that file, not a build action.

`:komira_compression` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`): its `deps` are the adopted
target of each package in `[dependencies]`, and the rule refuses a list that is not the closure `:lib` was built
from. It also compiles and runs the README's examples above (`[tests][readme]`) against `:lib`; the tests are not
run again.
