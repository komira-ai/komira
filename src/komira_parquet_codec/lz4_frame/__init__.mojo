# =============================================================================
# lz4_frame — the page codec's LZ4 FRAME entries (package-private)
# =============================================================================
#
# `lz4_ffi.mojo` holds the entries `compression.mojo` calls
# (`_lz4_frame_decompress_into`, `_lz4_frame_compress_into`,
# `_lz4_frame_compress_bound`), over komira_compression's lz4 module; the
# public surface is `decompress_lz4_frame`, `compress_lz4_frame` and
# `lz4_frame_compress_bound` in `compression.mojo`.
#
# The LZ4 RAW-BLOCK codec comes from the same komira_compression module.
# =============================================================================
