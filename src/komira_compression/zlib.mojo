# =============================================================================
# zlib.mojo: deflate streams (raw, zlib and gzip framings), from komira_zlib
# =============================================================================
#
# Re-exports komira_zlib's Span API, the implementation layer that owns libz
# (its soname, its process-lifetime handle and its FFI) for this package. A
# package outside komira_compression imports these names from here.
#
#   * `zlib_inflate_into(dst, src, window_bits=ZLIB_WINDOW_BITS_AUTO) -> Int`
#   * `zlib_inflate_once(dst, src, window_bits) -> ZlibInflateOutcome`
#   * `zlib_deflate_into(dst, src, level, window_bits) -> Int`
#   * `zlib_compress_bound(src_len, window_bits) -> Int`
#   * `zlib_skip_stream(src, window_bits=ZLIB_WINDOW_BITS_AUTO) -> Int`
#   * `zlib_crc32(data, crc=0) -> UInt32`
#   * `ZLIB_WINDOW_BITS_ZLIB` / `_RAW` / `_GZIP` / `_AUTO`, `ZLIB_LEVEL_DEFAULT`
#   * `Z_OK`, `Z_STREAM_END`, `Z_BUF_ERROR`: the `ZlibInflateOutcome.rc`
#     values a grow-and-retry caller tells apart
# =============================================================================

from komira_zlib import (
    ZLIB_LEVEL_DEFAULT,
    ZLIB_WINDOW_BITS_AUTO,
    ZLIB_WINDOW_BITS_GZIP,
    ZLIB_WINDOW_BITS_RAW,
    ZLIB_WINDOW_BITS_ZLIB,
    ZlibInflateOutcome,
    zlib_compress_bound,
    zlib_crc32,
    zlib_deflate_into,
    zlib_inflate_into,
    zlib_inflate_once,
    zlib_skip_stream,
)

# zlib.h return codes.
comptime Z_OK: Int32 = 0
comptime Z_STREAM_END: Int32 = 1
comptime Z_BUF_ERROR: Int32 = -5
