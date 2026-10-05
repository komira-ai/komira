# =============================================================================
# brotli — FFI shim for the Brotli decoder (package-private)
# =============================================================================
#
# A single FFI shim over the Brotli decoder's one-shot
# `BrotliDecoderDecompress` for the Parquet read path (linked statically from
# //third_party/brotli). Decompression only; this package does not write
# Brotli.
#
# `brotli_ffi.mojo` holds `_brotli_decompress_into`, which `compression.mojo`
# calls; nothing is re-exported, because the package's Brotli surface is
# `decompress` with `CompressionCodec.BROTLI`.
# =============================================================================
