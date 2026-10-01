# =============================================================================
# src/komira_http/codec/h2/continuation_splitter.mojo — split header blocks
# =============================================================================
#
# split an outbound HPACK-encoded header block across
# HEADERS + CONTINUATION* frames per RFC 9113 §6.10.
#
# Wire shape:
#   1. The FIRST frame on the wire is HEADERS (kind=0x01). It carries the
#      first up-to-`max_frame_size` bytes of the block.
#   2. Each subsequent frame is CONTINUATION (kind=0x09). Each carries
#      up to `max_frame_size` more bytes.
#   3. The LAST frame on the wire (HEADERS if no CONTINUATION needed,
#      else the final CONTINUATION) sets `FLAG_END_HEADERS`.
#   4. `FLAG_END_STREAM` (if set) goes ONLY on the HEADERS frame — never
#      on CONTINUATION (RFC 9113 §6.10: CONTINUATION carries no flags
#      other than END_HEADERS).
#   5. Each frame's `stream_id` is the same (the request/response stream).
#
# Encapsulation: pure-functional. No UnsafePointer. No wildcard origin.
# =============================================================================

from komira_http.codec.h2.frame import (
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FRAME_CONTINUATION,
    FRAME_HEADERS,
    MAX_FRAME_PAYLOAD_DEFAULT,
    encode_frame_header,
)


def split_header_block_into_frames(
    stream_id: UInt32,
    var block: List[UInt8],
    max_frame_size: Int,
    end_stream: Bool,
    mut out: List[UInt8],
):
    """Serialize `block` (HPACK-encoded header bytes) as HEADERS +
    CONTINUATION* frames into `out`.

    Args:
        stream_id: The H2 stream identifier (request/response stream).
        block: The HPACK header block bytes (caller produced via
            HpackEncoder.encode_block).
        max_frame_size: SETTINGS_MAX_FRAME_SIZE (caller's effective per-
            frame payload cap; usually `h2.max_frame_size_peer`).
        end_stream: If True, set FLAG_END_STREAM on the HEADERS frame
            (signals server's response has no body / client's request
            has no body).
        out: Byte buffer to append the wire bytes to.

    Edge cases:
      * empty block (len(block) == 0): emits ONE HEADERS frame with
        zero-length payload + FLAG_END_HEADERS (and optional END_STREAM).
      * block size exactly == max_frame_size: ONE HEADERS frame (no
        CONTINUATION needed); END_HEADERS set on the HEADERS frame.
      * block size > max_frame_size: HEADERS (no END_HEADERS) +
        CONTINUATION* (last one sets END_HEADERS).
    """
    var n = len(block)
    if max_frame_size <= 0:
        # Defensive: treat 0 as the default to avoid divide-by-zero.
        # Caller should never pass <= 0 (RFC 9113 §6.5.2 requires >= 16384).
        var mfs_fallback = MAX_FRAME_PAYLOAD_DEFAULT
        split_header_block_into_frames(
            stream_id, block^, mfs_fallback, end_stream, out,
        )
        return

    # Compute first-frame payload size + how many CONTINUATION frames follow.
    var first_size = n if n < max_frame_size else max_frame_size

    # HEADERS frame flags: END_STREAM if requested; END_HEADERS only if the
    # block fits in this single frame.
    var headers_flags = UInt8(0)
    if end_stream:
        headers_flags = headers_flags | FLAG_END_STREAM
    var is_single_frame = n <= max_frame_size
    if is_single_frame:
        headers_flags = headers_flags | FLAG_END_HEADERS

    # Emit HEADERS frame.
    encode_frame_header(
        UInt32(first_size), FRAME_HEADERS, headers_flags, stream_id, out,
    )
    var i = 0
    while i < first_size:
        out.append(block[i])
        i = i + 1

    if is_single_frame:
        return

    # Emit CONTINUATION frames for the remainder.
    var off = first_size
    while off < n:
        var remaining = n - off
        var chunk = remaining if remaining < max_frame_size else max_frame_size
        var is_last = (off + chunk) >= n
        var cont_flags = UInt8(0)
        if is_last:
            cont_flags = cont_flags | FLAG_END_HEADERS
        encode_frame_header(
            UInt32(chunk), FRAME_CONTINUATION, cont_flags, stream_id, out,
        )
        var j = 0
        while j < chunk:
            out.append(block[off + j])
            j = j + 1
        off = off + chunk
