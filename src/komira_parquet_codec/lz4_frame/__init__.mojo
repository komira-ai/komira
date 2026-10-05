# =============================================================================
# lz4_frame — FFI shim for liblz4's FRAME format (package-private)
# =============================================================================
#
# `lz4_ffi.mojo` holds the entries `compression.mojo` calls
# (`_lz4_frame_decompress_into`, `_lz4_frame_compress_into`,
# `_lz4_frame_compress_bound`); the public surface is `decompress_lz4_frame`,
# `compress_lz4_frame` and `lz4_frame_compress_bound` in `compression.mojo`.
#
# The LZ4 RAW-BLOCK codec is a separate shared library (komira_lz4).
# =============================================================================
