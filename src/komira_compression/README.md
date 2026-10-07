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
