# komira_compression

Byte-stream codec trait and the eight codec implementations, and the codec
API the file formats call.

This package is meant to be the one owner of the codec libraries: the snappy
C API (statically linked from `//third_party/snappy`) and the sonames of
libzstd, libbz2 and liblzma, each opened once per process
(`codec_libraries.mojo`). libz and liblz4 are opened by its implementation
layers `komira_zlib` and `komira_lz4`, which it re-exports. komira_avro,
komira_orc and komira_parquet_codec still declare their own copies of the
snappy symbols and open some of these sonames themselves; they move onto
this package's API in follow-up changes.

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
signature holds a pointer. When libzstd, libbz2 or liblzma cannot be
loaded, the process aborts at first use with the message
`komira_compression: cannot load <soname>: <the loader's error>`. libz and
liblz4 are opened by `komira_zlib` and `komira_lz4`, which abort with their
own messages (`libz dlopen failed (komira_zlib FFI handle init)` and
`liblz4 dlopen failed (komira_lz4 raw-block handle init)`), naming neither
the soname nor the loader's error.

## Examples

A raw snappy block, compressed and decompressed by the snappy library this
package links (its shared library, from an installed package):

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
(`mopm.toml`). The library is `src/komira_compression/`, its tests are `tests/`. It depends on `komira_lz4` and
`komira_zlib`, and it has one native library of its own and three it opens at run time:

- snappy is linked: `[native.snappy]` of `mopm.toml`, whose archive `libsnappy.a` is built by the `native_library`
  target `//third_party/snappy:snappy_native` (snappy 1.2.2 from its pinned release archive, C++17, the C API renamed
  `komira_snappy_*`, the C++ names left as they are) and named in `natives` of `BUCK`. It is linked into every test of
  the package and of the packages that depend on it, and `:conda` holds it at `lib/libsnappy.a`. `native/snappy_provided.c`
  is not compiled: `mopm.toml` names a source for every native, and this one is built elsewhere.
- libbz2, liblzma and libzstd are opened by name when a codec is first used, so `mopm.toml` declares them under
  `[native-dependencies]` with `mode = "load"` and the conda package records `bzip2`, `liblzma` and `zstd` as
  dependencies; `mopm.lock` pins them for each platform.

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the two Mojo dependencies, the three libraries opened at run time, snappy, where the library and its tests are |
| `mopm.lock` | what `mopm lock` writes (with no registry reachable): the path dependencies and, under `system_libs`, the conda packages of the libraries opened at run time, for each platform |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above; `buildrules mojo check` fails when they are stale |
| `coverage_floor.txt` | the line and branch coverage the package's tests must keep (`:coverage_floor`) |

`:lib` is the library file and exists only once every test of `tests/` has passed. After any change to a source, a test,
`mopm.toml`, `mopm.lock` or `mopm-toolchain.toml`, run `buildrules mojo sync`, commit what it writes, and build
`komira//src/komira_compression:lib` on the farm.

`:conda` is the `.conda` of the mopm package (`mojo-komira_compression-0.1.0-mojo1.0.0_0.conda`): the `.mojoc` and
`lib/libsnappy.a`, requiring `komira_lz4`, `komira_zlib` and the three conda packages above; `:conda_holds` reads it back.
`:komira_compression` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`); it declares the three
sonames in `dlopen`, which `:komira_compression_conda` (the release set's packaging) turns into the same requirements,
and it names `:komira_compression_native`, the shared library of the release set that links the older
`//third_party/snappy:snappy`. It also compiles and runs the README's examples above (`[tests][readme]`) against `:lib`.
