# =============================================================================
# lz4.mojo: the LZ4 raw block and the LZ4 frame, from komira_lz4
# =============================================================================
#
# Re-exports komira_lz4's Span API, the implementation layer that owns liblz4
# (its soname, its process-lifetime handle and its FFI) for this package. A
# package outside komira_compression imports these names from here.
#
# Raw block (`LZ4_*`; Parquet LZ4_RAW, ORC LZ4):
#   * `lz4_compress_bound(input_len) -> Int`
#   * `lz4_compress_into(dst, src) -> Int`, `lz4_decompress_into(dst, src) -> Int`
#   * `lz4_compress(src) -> List[UInt8]`,
#     `lz4_decompress(src, uncompressed_len) -> List[UInt8]`
# Frame (`LZ4F_*`; Arrow IPC LZ4_FRAME, `.lz4` files):
#   * `lz4_frame_compress_bound(src_len) -> Int`
#   * `lz4_frame_compress_into(dst, src) -> Int`
#   * `lz4_frame_decompress_into(dst, src) -> Int` (exactly one frame, one call)
#   * `lz4_frames_decompress_into(dst, src) -> Int` (one or more frames)
#   * `Lz4FrameDecoder` (a decompression context reused across frames)
# =============================================================================

from komira_lz4.codec import (
    lz4_compress,
    lz4_compress_bound,
    lz4_compress_into,
    lz4_decompress,
    lz4_decompress_into,
)
from komira_lz4.frame import (
    Lz4FrameDecoder,
    lz4_frame_compress_bound,
    lz4_frame_compress_into,
    lz4_frame_decompress_into,
    lz4_frames_decompress_into,
)
