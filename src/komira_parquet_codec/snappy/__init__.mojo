# =============================================================================
# snappy — the Snappy codec: the snappy C API and a Mojo decoder
# =============================================================================
#
# Re-exports the entries of `snappy_ffi.mojo` and the `kSlopBytes` constant a
# page decoder uses to size its output buffer.
#
# Public symbols (Span in, caller-owned Span out, bytes written back):
#   * `snappy_decompress(compressed, dst) -> Int`
#   * `snappy_compress(src, dst) -> Int`
#   * `snappy_uncompressed_length(compressed) -> Int`
#   * `snappy_max_compressed_length(input_len) -> Int`
#   * `SnappyDecoder`, `set_snappy_decoder(decoder)`, `snappy_decoder()`:
#     which decoder `snappy_decompress` uses (the C library's by default)
#   * `kSlopBytes: Int = 64` (the decoder's slop budget: a caller that sizes
#     its output `uncompressed_len + kSlopBytes` lets the Mojo decoder's fast
#     paths write past the logical end; the C decoder does not need it)
#
# See:
#   - `snappy_ffi.mojo` for the FFI implementation and the decoder selection
#   - `decompress.mojo` for the Mojo decoder
#   - `format.mojo` for the kSlopBytes constant definition
# =============================================================================

from .snappy_ffi import (
    SnappyDecoder,
    set_snappy_decoder,
    snappy_compress,
    snappy_decoder,
    snappy_decompress,
    snappy_max_compressed_length,
    snappy_uncompressed_length,
)
from .format import kSlopBytes
