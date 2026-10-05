# =============================================================================
# snappy — the Snappy codec: the snappy C API and a Mojo decoder
# =============================================================================
#
# Re-exports the FFI shim in `snappy_ffi.mojo` and the `kSlopBytes` constant
# a page decoder uses to size its output buffer.
#
# Public symbols:
#   * `snappy_decompress(compressed, dst) -> Int`
#   * `snappy_compress(src, dst) -> Int`
#   * `snappy_uncompressed_length(compressed) -> Int`
#   * `snappy_max_compressed_length(input_len) -> Int`
#   * `kSlopBytes: Int = 64` (the decoder's slop budget: a caller that sizes
#     its output `uncompressed_len + kSlopBytes` lets the Mojo decoder's fast
#     paths write past the logical end; the C decoder does not need it)
#
# See:
#   - `snappy_ffi.mojo` for the FFI implementation
#   - `decompress.mojo` for the Mojo decoder
#   - `format.mojo` for the kSlopBytes constant definition
# =============================================================================

from .snappy_ffi import (
    snappy_decompress,
    snappy_compress,
    snappy_uncompressed_length,
    snappy_max_compressed_length,
)
from .format import kSlopBytes
