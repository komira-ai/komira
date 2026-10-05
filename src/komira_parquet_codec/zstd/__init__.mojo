# =============================================================================
# zstd — FFI shim facade for libzstd
# =============================================================================
#
# Public symbols (the surface `compression.mojo` uses):
#   * `zstd_decompress_ffi(dst, dst_cap, src, src_size) -> Int`
#   * `zstd_compress_ffi(dst, dst_cap, src, src_size, level) -> Int`
#   * `zstd_compress_bound_ffi(src_size) -> Int`
#
# See `zstd_ffi.mojo` for the FFI implementation.
# =============================================================================

from .zstd_ffi import (
    zstd_decompress_ffi,
    zstd_compress_ffi,
    zstd_compress_bound_ffi,
)
