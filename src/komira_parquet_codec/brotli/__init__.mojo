# =============================================================================
# brotli — FFI shim for libbrotlidec (package-private)
# =============================================================================
#
# A single FFI shim over libbrotlidec's one-shot `BrotliDecoderDecompress`
# for the Parquet read path (libbrotlidec opened at run time). Decompression
# only; this package does not write Brotli.
#
# `brotli_ffi.mojo` holds `_brotli_decompress_into`, which `compression.mojo`
# calls; nothing is re-exported, because the package's Brotli surface is
# `decompress` with `CompressionCodec.BROTLI`.
# =============================================================================
