# =============================================================================
# zstd/zstd_ffi.mojo
# =============================================================================
#
# Zstandard for the page codec: komira_compression's zstd_frame (which owns
# libzstd: its soname, its process-lifetime handle and its FFI), with this
# package's one policy on top: an empty ZSTD page is refused.
#
# # API (package-private: `compression.mojo` is the caller)
#
# `dst` is a Span with a mutable origin, `src` a Span; the full signatures
# are on the functions.
#
#   _zstd_decompress_into(dst, src) raises -> Int
#   _zstd_compress_into(dst, src, compression_level) raises -> Int
#   _zstd_compress_bound(src_size: Int) raises -> Int
# =============================================================================

from komira_compression.zstd_frame import (
    zstd_compress_bound,
    zstd_compress_into,
    zstd_decompress_into,
)


def _zstd_decompress_into[
    dori: MutOrigin
](dst: Span[UInt8, dori], src: Span[UInt8, _]) raises -> Int:
    """Decompress one or more concatenated zstd frames in `src` into `dst`;
    return the bytes written. `len(dst)` is the capacity: frames that decode
    to more are refused (`ZSTD_decompress failed (result=R, input_len=N,
    output_cap=C)`), and no byte past it is written.
    """
    # libzstd decodes a 0-byte input to 0 bytes, with no error. A zstd page
    # always holds at least one frame (an empty payload is still a frame
    # header and an empty block), so no input is refused, as SNAPPY refuses
    # it.
    if len(src) == 0:
        raise Error("ZSTD_decompress: empty input holds no zstd frame")
    return zstd_decompress_into(dst, src)


def _zstd_compress_into[
    dori: MutOrigin
](
    dst: Span[UInt8, dori],
    src: Span[UInt8, _],
    compression_level: Int32,
) raises -> Int:
    """Compress `src` into `dst` at `compression_level`; return the bytes
    written. `dst` should hold `_zstd_compress_bound(len(src))` bytes;
    libzstd refuses a destination too small for the frame it produces.
    """
    return zstd_compress_into(dst, src, compression_level)


def _zstd_compress_bound(src_size: Int) raises -> Int:
    """ZSTD_compressBound(srcSize) — maximum possible compressed size."""
    return zstd_compress_bound(src_size)
