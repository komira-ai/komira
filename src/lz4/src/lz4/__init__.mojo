# lz4 — the shared LZ4 raw-block and frame codecs over lz4 1.10.0, linked
# statically with every symbol renamed komira_lz4_*.
#
#   * codec.mojo — `lz4_compress`, `lz4_decompress` and `lz4_compress_bound`
#     (Span in, List out), `lz4_compress_into` and `lz4_decompress_into`
#     (Span in, caller-owned Span out). No public signature holds a raw
#     pointer; the pointer-taking `_lz4_*_ffi` entries are underscore-prefixed
#     (private by convention; the compiler does not enforce it). Nothing is
#     opened at run time: the C library is linked into the program.
#
#   * frame.mojo — the LZ4 FRAME codec (`LZ4F_*`, the Arrow IPC LZ4_FRAME
#     framing): `lz4_frame_compress_bound`, `lz4_frame_compress_into`,
#     `lz4_frame_decompress_into`, `lz4_frames_decompress_into` (one or more
#     concatenated frames) and `Lz4FrameDecoder` (a reusable decompression
#     context). The same linked library as codec.mojo; no pointer in
#     any public signature.
