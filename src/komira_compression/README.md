# komira_compression

Byte-stream codec trait and the eight codec implementations, and the codec
API the file formats call.

This package owns the codec libraries: the snappy C API (statically linked
from `//third_party/snappy`) and the sonames of libzstd, libbz2 and liblzma,
each opened once per process (`codec_libraries.mojo`). libz and liblz4 are
opened by its implementation layers `komira_zlib` and `komira_lz4`, which it
re-exports.

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
  `LZMA_BUF_ERROR`).
- `zlib`: komira_zlib's deflate API, with `zlib_inflate_once` for a
  grow-and-retry caller.
- `lz4`: komira_lz4's raw block and frame API, with
  `lz4_frames_decompress_into` for concatenated frames.

Every entry takes Spans: the destination's length is its capacity, and no
signature holds a pointer. A codec library that cannot be loaded aborts the
process at first use, with the message `komira_compression: cannot load
<soname>: <the loader's error>`.
