# komira_lz4 — the shared LZ4 raw-block codec over liblz4.
#
#   * codec.mojo — `lz4_compress`, `lz4_decompress` and `lz4_compress_bound`
#     (Span in, List out), `lz4_compress_into` and `lz4_decompress_into`
#     (Span in, caller-owned Span out). No public signature holds a raw
#     pointer; the pointer-taking `_lz4_*_ffi` entries are underscore-prefixed
#     (private by convention; the compiler does not enforce it). liblz4
#     is opened at run time with OwnedDLHandle and cached in the
#     process-lifetime `_Global` slot `komira_lz4_codec_handle`.
#
# The LZ4 FRAME format (`LZ4F_*`) is a different codec and is not here.
