# =============================================================================
# brotli — FFI shim facade for libbrotlidec
# =============================================================================
#
# A single FFI shim over libbrotlidec's one-shot `BrotliDecoderDecompress`
# for the Parquet read path, laid out like zstd / lz4_frame (libbrotlidec
# opened at run time).
#
# Decompression only; this package does not write Brotli.
#
# Public symbols (the surface `compression.mojo` uses):
#   * `brotli_decompress_ffi(dst, dst_cap, src, src_size) -> Int`
#
# See `brotli_ffi.mojo` for the FFI implementation.
# =============================================================================

from .brotli_ffi import brotli_decompress_ffi
