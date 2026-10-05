# =============================================================================
# lz4_frame — FFI shim facade for liblz4's FRAME format
# =============================================================================
#
# Public symbols (LZ4 FRAME codec only):
#   * `lz4_frame_decompress_ffi(dst, dst_cap, src, src_size) -> Int`
#   * `lz4_frame_compress_ffi(dst, dst_cap, src, src_size) -> Int`
#   * `lz4_frame_compress_bound_ffi(src_size) -> Int`
#
# The LZ4 RAW-BLOCK codec is a separate shared library (komira_lz4), so that
# Parquet and other raw-block users depend on one copy; import the raw-block
# entries from there, not from here.
#
# See `lz4_ffi.mojo` for the FRAME FFI implementation.
# =============================================================================

from .lz4_ffi import (
    lz4_frame_decompress_ffi,
    lz4_frame_compress_ffi,
    lz4_frame_compress_bound_ffi,
)
