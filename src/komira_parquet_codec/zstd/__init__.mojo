# =============================================================================
# zstd — the page codec's zstd entries (package-private)
# =============================================================================
#
# `zstd_ffi.mojo` holds the entries `compression.mojo` calls
# (`_zstd_decompress_into`, `_zstd_compress_into`, `_zstd_compress_bound`),
# over komira_compression's zstd_frame; nothing is re-exported, because the
# package's zstd surface is `compress` / `decompress` with
# `CompressionCodec.ZSTD`.
# =============================================================================
