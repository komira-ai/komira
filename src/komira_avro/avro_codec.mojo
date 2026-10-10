# =============================================================================
# avro_codec.mojo — OCF block codec compression and decompression (full matrix).
# =============================================================================
#
# The full Avro 1.11.1 codec matrix:
#   null      — no-op passthrough.
#   snappy    — raw_snappy ‖ BE4 crc32(uncompressed) framing.
#   deflate   — libz inflateInit2(-15), RAW RFC-1951 — NOT
#               zlib-wrapped; NOT reusable from Parquet's GZIP arm.
#   zstandard — libzstd ZSTD_decompress; wire string is "zstandard"
#               byte-equal, NOT "zstd" — dispatch enforced in ocf_header.
#   bzip2     — libbz2 BZ2_bzBuffToBuffDecompress; no Avro framing.
#   xz        — liblzma lzma_stream_buffer_decode; no Avro framing.
#
# CRITICAL Avro snappy wire detail: the snappy block payload is
#
#     raw_snappy_compressed_bytes ‖ BE4 crc32(uncompressed_bytes)
#
# i.e. the last 4 bytes are a big-endian CRC32 (IEEE 802.3) of the
# UNCOMPRESSED data. The decoder MUST strip those 4 bytes BEFORE calling
# `snappy_uncompress`, then VALIDATE the CRC32 of the decompressed result
# against the trailer. A direct libsnappy call on the raw payload FAILS.
#
# Encapsulation: the public entry `decompress_block(codec_tag, payload)` takes
# a borrowed `Span[UInt8]` and returns an owned `List[UInt8]` of decompressed
# bytes; `compress_block` is its inverse. No UnsafePointer crosses the module
# boundary, and none is taken here but the null codec's memcpy.
#
# The codec libraries are komira_compression's: this module calls its codec
# API (snappy_block, zlib, zstd_frame, bzip2_buffer, xz_buffer) and declares
# no FFI of its own. komira_compression owns every codec soname and the
# snappy symbols.
# =============================================================================

from std.memory import unsafe_memcpy

from komira_compression.bzip2_buffer import (
    BZIP2_DEFAULT_BLOCK_SIZE_100K,
    BZIP2_DEFAULT_WORK_FACTOR,
    bzip2_compress_into,
    bzip2_decompress_into,
)
from komira_compression.snappy_block import (
    snappy_compress_into,
    snappy_max_compressed_length,
    snappy_uncompress_into,
    snappy_uncompressed_length,
)
from komira_compression.xz_buffer import (
    XZ_CHECK_CRC64,
    XZ_DEFAULT_MEMLIMIT,
    XZ_PRESET_DEFAULT,
    xz_compress_into,
    xz_decompress_into,
)
from komira_compression.zlib import (
    ZLIB_LEVEL_DEFAULT,
    ZLIB_WINDOW_BITS_RAW,
    Z_BUF_ERROR,
    Z_OK,
    Z_STREAM_END,
    zlib_compress_bound,
    zlib_deflate_into,
    zlib_inflate_once,
)
from komira_compression.zstd_frame import (
    ZSTD_CONTENTSIZE_ERROR,
    ZSTD_CONTENTSIZE_UNKNOWN,
    ZSTD_DEFAULT_LEVEL,
    zstd_compress_bound,
    zstd_compress_into,
    zstd_decompress_into,
    zstd_frame_content_size,
)

from .ocf_header import (
    AVRO_CODEC_NULL,
    AVRO_CODEC_SNAPPY,
    AVRO_CODEC_DEFLATE,
    AVRO_CODEC_BZIP2,
    AVRO_CODEC_XZ,
    AVRO_CODEC_ZSTANDARD,
    codec_wire_name,
)


# =============================================================================
# Public entry — decompress one OCF block payload by codec tag.
# =============================================================================


def decompress_block(
    codec_tag: Int, payload: Span[UInt8, _], uncompressed_hint: Int = 0
) raises -> List[UInt8]:
    """Decompress an OCF block payload by codec tag (full Avro codec matrix).

    Args:
        codec_tag: AVRO_CODEC_* tag from the OCF header.
        payload: Borrowed view of the on-disk (post-compression) block bytes.
        uncompressed_hint: Optional hint for the decompressed size. Used by the
            grow-on-overflow codecs (deflate / bzip2 / xz) to seed the first
            output-buffer estimate; ignored by snappy / zstandard (which carry
            their own length preamble / frame header).

    Returns:
        Owned List[UInt8] of decompressed bytes.

    Raises:
        On an unknown codec tag or a codec failure (snappy status /
        CRC32 mismatch / inflate / bzip2 / xz / zstd error).
    """
    if codec_tag == AVRO_CODEC_NULL:
        # No-op codec: copy the borrowed bytes into an owned List via a single
        # bulk `List.extend(Span)` -> `uninit_copy_n` -> one memcpy (a per-byte
        # append loop is measurably slower on a null-codec read). Same shape
        # as the string accumulator's `push_bytes` in `action_table.mojo`.
        var n = len(payload)
        var out = List[UInt8](capacity=n)
        out.extend(payload)
        return out^
    elif codec_tag == AVRO_CODEC_SNAPPY:
        return _decompress_snappy_avro(payload)
    elif codec_tag == AVRO_CODEC_DEFLATE:
        return _decompress_deflate_avro(payload, uncompressed_hint)
    elif codec_tag == AVRO_CODEC_ZSTANDARD:
        return _decompress_zstandard_avro(payload, uncompressed_hint)
    elif codec_tag == AVRO_CODEC_BZIP2:
        return _decompress_bzip2_avro(payload, uncompressed_hint)
    elif codec_tag == AVRO_CODEC_XZ:
        return _decompress_xz_avro(payload, uncompressed_hint)
    raise Error(
        String("AvroCodecError.UNKNOWN_CODEC: tag ") + String(codec_tag)
    )


# =============================================================================
# Grow-on-overflow output sizing for the codecs without an inline length.
# =============================================================================
#
# Avro OCF blocks do NOT carry the uncompressed length inline (unlike snappy's
# preamble or a zstd frame header). For deflate / bzip2, we must guess an
# output capacity and grow it on a buffer-too-small signal. The first guess is
# max(uncompressed_hint, 4 * payload, MIN); each retry quadruples capacity.

comptime _MIN_OUTPUT_GUESS: Int = 4096
comptime _MAX_OUTPUT_CAP: Int = 1 << 31  # 2 GiB ceiling — refuse beyond this.

# UNTRUSTED INPUT. Two codecs let the COMPRESSED STREAM
# declare its own decompressed size — snappy's varint preamble and zstd's
# Frame_Content_Size — and both declarations were used verbatim as an
# allocation size with no relation to the block's actual byte count. A ~40-byte
# block could ask for 4 GiB (snappy) or, once `Int(content)` went negative,
# make the allocation and the declared `dstCapacity` disagree (zstd, a genuine
# heap overflow). This ceiling is the shared upper bound: an Avro block is a
# batching unit, typically 64 KiB and never remotely this large, so 2 GiB
# refuses nothing real. Kept equal to `_MAX_OUTPUT_CAP` so the declared-size
# codecs and the grow-loop codecs enforce one number.
comptime MAX_DECOMPRESSED_BLOCK_BYTES: Int = _MAX_OUTPUT_CAP


@always_inline
def _initial_output_guess(payload_len: Int, hint: Int) -> Int:
    var guess = payload_len * 4
    if hint > guess:
        guess = hint
    if guess < _MIN_OUTPUT_GUESS:
        guess = _MIN_OUTPUT_GUESS
    return guess


def _output_buffer(cap: Int) -> List[UInt8]:
    """A List of `cap` bytes for a codec to write into. The bytes are not
    initialized; the caller cuts the List to what the codec wrote."""
    var out = List[UInt8](capacity=cap)
    # SAFETY: `cap` bytes were reserved above; every byte read later is one
    # the codec wrote (`_trimmed` keeps exactly those).
    out.resize(unsafe_uninit_length=cap)
    return out^


def _trimmed(var out: List[UInt8], written: Int) -> List[UInt8]:
    """`out` cut to its first `written` bytes. A List whose capacity was a
    guess well past the result is copied into one of the right size, so a
    decoded block does not hold the guess's memory."""
    if written == len(out):
        return out^
    var exact = List[UInt8](capacity=written)
    exact.extend(Span(out)[0:written])
    return exact^


# =============================================================================
# Snappy (Avro framing: raw_snappy ‖ BE4 crc32(uncompressed)).
# =============================================================================


def _decompress_snappy_avro(payload: Span[UInt8, _]) raises -> List[UInt8]:
    """Strip + validate the BE4 CRC32 trailer, then snappy-uncompress.

    The Avro snappy block is `raw_snappy_compressed ‖ BE4 crc32(uncompressed)`.
    """
    var total = len(payload)
    if total < 4:
        raise Error(
            "AvroCodecError.SNAPPY_TRUNCATED: payload < 4-byte CRC trailer"
        )
    var snappy_len = total - 4
    # BE4 CRC32 trailer (last 4 bytes, big-endian).
    var crc_expected: UInt32 = 0
    crc_expected |= UInt32(payload[snappy_len + 0]) << 24
    crc_expected |= UInt32(payload[snappy_len + 1]) << 16
    crc_expected |= UInt32(payload[snappy_len + 2]) << 8
    crc_expected |= UInt32(payload[snappy_len + 3])

    var out = _snappy_uncompress(payload, snappy_len)

    var crc_actual = crc32_ieee(Span(out))
    if crc_actual != crc_expected:
        raise Error(
            String("AvroCodecError.SNAPPY_CRC32_MISMATCH: expected ")
            + String(Int(crc_expected))
            + ", got "
            + String(Int(crc_actual))
        )
    return out^


def _snappy_uncompress(
    payload: Span[UInt8, _], snappy_len: Int
) raises -> List[UInt8]:
    """Decode the raw snappy block in the first `snappy_len` bytes of
    `payload` (the trailer already excluded by length) with
    komira_compression's snappy codec; return the decoded bytes.

    snappy writes straight into the returned List, sized from the block's
    preamble. Every reader (columnar and row-typed, serial and parallel)
    dispatches through this helper via `decompress_block(SNAPPY, raw)`.
    """
    var block = payload[0:snappy_len]
    var ulen: Int
    try:
        ulen = snappy_uncompressed_length(block)
    except:
        raise Error("AvroCodecError.SNAPPY_LENGTH_FAILED")
    # UNTRUSTED INPUT. `ulen` is the snappy stream's own
    # uncompressed-length preamble — an attacker-chosen varint inside the block
    # payload. The WRITE is safe (snappy bounds its output by the destination's
    # length), so unbounded this is allocation amplification rather than
    # corruption: a ~40-byte block could declare 4 GiB and get it. Bounded
    # here, at the one place the declaration enters the process.
    if ulen < 0 or ulen > MAX_DECOMPRESSED_BLOCK_BYTES:
        raise Error(
            String(
                "AvroCodecError.SNAPPY_LENGTH_OUT_OF_RANGE: stream declares "
            )
            + String(ulen)
            + " uncompressed bytes from a "
            + String(snappy_len)
            + "-byte block; the ceiling is "
            + String(MAX_DECOMPRESSED_BLOCK_BYTES)
        )
    var out = _output_buffer(ulen)
    var written: Int
    try:
        written = snappy_uncompress_into(Span(out), block)
    except e:
        raise Error("AvroCodecError.SNAPPY_UNCOMPRESS_FAILED: " + String(e))
    return _trimmed(out^, written)


# =============================================================================
# Deflate (RAW RFC-1951).
# =============================================================================
#
# Avro deflate blocks are RAW DEFLATE (RFC 1951): no zlib header, no ADLER32
# trailer. This is NOT the framing Parquet's GZIP arm uses (zlib-wrapped or
# auto-detect windowBits=15+32): the inflate runs with windowBits -15
# (`ZLIB_WINDOW_BITS_RAW`).


def _decompress_deflate_avro(
    payload: Span[UInt8, _], hint: Int
) raises -> List[UInt8]:
    """Inflate a RAW RFC-1951 deflate block.

    One `inflate` pass per attempt (`zlib_inflate_once`); grows the output
    buffer when libz stops with Z_BUF_ERROR or Z_OK short of the stream's
    end having filled it (Avro blocks carry no inline uncompressed length).
    A stop short of the end with output space left means libz ran out of
    input: the block is truncated (DEFLATE_TRUNCATED), and a larger buffer
    would not change that.
    """
    var cap = _initial_output_guess(len(payload), hint)
    while True:
        var out = _output_buffer(cap)
        var res = zlib_inflate_once(Span(out), payload, ZLIB_WINDOW_BITS_RAW)
        if res.rc == Z_STREAM_END:
            return _trimmed(out^, res.written)
        if res.rc != Z_BUF_ERROR and res.rc != Z_OK:
            raise Error(
                String("AvroCodecError.DEFLATE_FAILED: inflate rc ")
                + String(Int(res.rc))
            )
        if res.unwritten > 0:
            raise Error(
                "AvroCodecError.DEFLATE_TRUNCATED: the deflate stream ends"
                " before its final block does"
            )
        if cap >= _MAX_OUTPUT_CAP:
            raise Error("AvroCodecError.DEFLATE_OUTPUT_OVERFLOW")  # cov: unreachable needs a deflate block that decodes to over 2 GiB
        cap *= 4


# =============================================================================
# Zstandard (wire string "zstandard", NOT "zstd").
# =============================================================================
#
# zstd frames carry the content size in the frame header, so we query it via
# `zstd_frame_content_size` and allocate exactly. When the size is unknown
# (streamed-without-size frames return a sentinel) the first output guess is
# used.


def _decompress_zstandard_avro(
    payload: Span[UInt8, _], hint: Int
) raises -> List[UInt8]:
    """Decompress a standard zstd frame.

    Takes the frame header's content size for an exact allocation when it is
    present; otherwise the hint-seeded guess.
    """
    var in_len = len(payload)
    var content = zstd_frame_content_size(payload)
    var cap: Int
    if content == ZSTD_CONTENTSIZE_UNKNOWN or content == ZSTD_CONTENTSIZE_ERROR:
        cap = _initial_output_guess(in_len, hint)
    else:
        # UNTRUSTED INPUT. `content` is the zstd frame header's
        # Frame_Content_Size: an attacker-chosen 64-bit field inside the
        # compressed block payload. Only the two sentinels are filtered above;
        # for any `content` in [2^63, 2^64-3] `Int(content)` is negative.
        # Refuse a content size that is negative-when-narrowed or beyond any
        # credible block, and size the destination Span and the allocation
        # from ONE value, so the capacity libzstd is told can never exceed the
        # memory behind it.
        if content > UInt64(MAX_DECOMPRESSED_BLOCK_BYTES):
            raise Error(
                String(
                    "AvroCodecError.ZSTD_CONTENT_SIZE_OUT_OF_RANGE: frame"
                    " header declares "
                )
                + String(content)
                + " decompressed bytes; the ceiling is "
                + String(MAX_DECOMPRESSED_BLOCK_BYTES)
            )
        cap = Int(content)
        if cap == 0:
            cap = 1
    var out = _output_buffer(max(cap, 1))
    var result: Int
    try:
        result = zstd_decompress_into(Span(out), payload)
    except e:
        raise Error("AvroCodecError.ZSTD_FAILED: " + String(e))
    return _trimmed(out^, result)


# =============================================================================
# Bzip2 (no Avro framing).
# =============================================================================


def _decompress_bzip2_avro(
    payload: Span[UInt8, _], hint: Int
) raises -> List[UInt8]:
    """Decompress a standard bzip2 stream.

    Grows the output buffer when it is too small (BZ_OUTBUFF_FULL, which
    `bzip2_decompress_into` answers with None).
    """
    var cap = _initial_output_guess(len(payload), hint)
    while True:
        var out = _output_buffer(cap)
        var got: Optional[Int]
        try:
            got = bzip2_decompress_into(Span(out), payload)
        except e:
            raise Error("AvroCodecError.BZIP2_FAILED: " + String(e))
        if got:
            return _trimmed(out^, got.value())
        if cap >= _MAX_OUTPUT_CAP:
            raise Error("AvroCodecError.BZIP2_OUTPUT_OVERFLOW")  # cov: unreachable needs a bzip2 block that decodes to over 2 GiB
        cap *= 4


# =============================================================================
# Xz (no Avro framing).
# =============================================================================


def _decompress_xz_avro(
    payload: Span[UInt8, _], hint: Int
) raises -> List[UInt8]:
    """Decompress a standard .xz stream, with a 16 GiB decoder memory limit
    (`XZ_DEFAULT_MEMLIMIT`, so large dictionaries decode).

    Grows the output buffer on LZMA_BUF_ERROR (which `xz_decompress_into`
    answers with None). liblzma before xz 5.8.4 answers a truncated stream
    with LZMA_BUF_ERROR too, and on an error it reports neither the input it
    consumed nor the output it wrote, so the grow loop cannot tell the two
    apart. A block that starts like an .xz stream but does not end with a
    valid stream footer is therefore refused up front (XZ_TRUNCATED), with
    every liblzma version.
    """
    if _xz_lacks_stream_footer(payload):
        raise Error(
            "AvroCodecError.XZ_TRUNCATED: the block does not end with an xz"
            " stream footer"
        )
    var cap = _initial_output_guess(len(payload), hint)
    while True:
        var out = _output_buffer(cap)
        var got: Optional[Int]
        try:
            got = xz_decompress_into(Span(out), payload, XZ_DEFAULT_MEMLIMIT)
        except e:
            raise Error("AvroCodecError.XZ_FAILED: " + String(e))
        if got:
            return _trimmed(out^, got.value())
        if cap >= _MAX_OUTPUT_CAP:
            raise Error("AvroCodecError.XZ_OUTPUT_OVERFLOW")  # cov: unreachable needs an xz block that decodes to over 2 GiB
        cap *= 4


# The .xz container (xz file format 1.2.1, section 2.1): a stream starts with
# the 6-byte header magic FD 37 7A 58 5A 00 and ends with a 12-byte footer:
# CRC32 (little-endian, over the next 6 bytes) | Backward Size (4) | Stream
# Flags (2) | magic "YZ". `lzma_stream_buffer_decode` (flags 0) takes exactly
# one stream with no padding after it, so a block whose last 12 bytes are not
# such a footer cannot decode.
comptime _XZ_HEADER_MAGIC_LEN: Int = 6
comptime _XZ_STREAM_HEADER_LEN: Int = 12
comptime _XZ_STREAM_FOOTER_LEN: Int = 12


def _xz_lacks_stream_footer(payload: Span[UInt8, _]) -> Bool:
    """True when `payload` is non-empty and starts like an .xz stream (its
    first bytes are the header magic, or a prefix of it) but does not end
    with a valid stream footer (magic "YZ" and a matching CRC32): a truncated
    stream. A payload that does not start like an .xz stream is left to
    liblzma, which names what is wrong with it."""
    var magic: InlineArray[UInt8, _XZ_HEADER_MAGIC_LEN] = [
        0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00
    ]
    var n = len(payload)
    if n == 0:
        return False
    for i in range(min(n, _XZ_HEADER_MAGIC_LEN)):
        if payload[i] != magic[i]:
            return False
    if n < _XZ_STREAM_HEADER_LEN + _XZ_STREAM_FOOTER_LEN:
        return True
    var f = n - _XZ_STREAM_FOOTER_LEN
    if payload[n - 2] != UInt8(ord("Y")) or payload[n - 1] != UInt8(ord("Z")):
        return True
    var stored = (
        UInt32(payload[f])
        | (UInt32(payload[f + 1]) << 8)
        | (UInt32(payload[f + 2]) << 16)
        | (UInt32(payload[f + 3]) << 24)
    )
    return crc32_ieee(payload[f + 4 : n - 2]) != stored


# =============================================================================
# CRC32 (IEEE 802.3) — for the Avro snappy trailer validation.
# =============================================================================
#
# Standard reflected CRC32 with polynomial 0xEDB88320, init 0xFFFFFFFF, final
# XOR 0xFFFFFFFF. This is the same CRC32 the Avro Java reference + zlib's
# `crc32` use for the snappy block trailer.


@always_inline
def _build_crc32_table() -> Array[UInt32, 256]:
    """Returns an InlineArray (stack-allocated; no heap): a `List[UInt32]`
    would allocate and grow via 256 appends on EVERY snappy WRITE call.
    """
    var table = Array[UInt32, 256](fill=UInt32(0))
    for i in range(256):
        var c = UInt32(i)
        for _j in range(8):
            if (c & UInt32(1)) != 0:
                c = UInt32(0xEDB88320) ^ (c >> 1)
            else:
                c = c >> 1
        table[i] = c
    return table^


def crc32_ieee(bytes: Span[UInt8, _]) -> UInt32:
    """CRC32 (IEEE 802.3, reflected, poly 0xEDB88320) of a byte sequence."""
    var table = _build_crc32_table()
    var crc = UInt32(0xFFFFFFFF)
    for i in range(len(bytes)):
        var idx = Int((crc ^ UInt32(bytes[i])) & UInt32(0xFF))
        crc = table[idx] ^ (crc >> 8)
    return crc ^ UInt32(0xFFFFFFFF)


# =============================================================================
# Public entry — COMPRESS one OCF block payload by codec tag.
# =============================================================================
#
# The inverse of `decompress_block`. Given the raw (uncompressed) Avro-binary
# block payload and a codec tag, returns the on-disk (post-compression) bytes
# the OCF block body should carry. Each codec's framing matches what
# `decompress_block` expects on the way back in:
#   null      — passthrough (no-op).
#   deflate   — RAW RFC-1951 (libz deflateInit2 windowBits=-15; NO zlib header,
#               NO ADLER32 trailer — the read path uses inflateInit2(-15)).
#   snappy    — raw_snappy ‖ BE4 crc32(uncompressed) — the Avro snappy framing
#               the decompressor strips + validates.
#   zstandard — a standard zstd frame (libzstd ZSTD_compress).
#   bzip2     — a standard bzip2 stream (libbz2 BZ2_bzBuffToBuffCompress).
#   xz        — a standard .xz stream (liblzma lzma_easy_buffer_encode).
#
# Encapsulation: takes a borrowed Span[UInt8], returns an owned List[UInt8].
# Each codec is komira_compression's codec API; this module declares no FFI
# and takes no pointer but the null codec's memcpy.


def compress_block(codec_tag: Int, payload: Span[UInt8, _]) raises -> List[UInt8]:
    """Compress an OCF block payload by codec tag (full Avro codec matrix).

    Args:
        codec_tag: AVRO_CODEC_* tag from the writer options.
        payload: Borrowed view of the raw (uncompressed) block bytes.

    Returns:
        Owned List[UInt8] of on-disk (post-compression) bytes, framed exactly
        as `decompress_block` expects.

    Raises:
        On an unknown codec tag or a codec failure.
    """
    if codec_tag == AVRO_CODEC_NULL:
        # Bulk memcpy, not a per-byte append loop. Pre-reserve + resize + memcpy.
        var n = len(payload)
        var out = List[UInt8](capacity=n)
        if n > 0:
            # SAFETY: dst is the freshly-reserved List backing store; src is
            # the borrowed Span's underlying buffer (alive across the call).
            unsafe_memcpy(
                dest=out.unsafe_ptr(),
                src=payload.unsafe_ptr(),
                count=n,
            )
        out.resize(unsafe_uninit_length=n)
        return out^
    elif codec_tag == AVRO_CODEC_DEFLATE:
        return _compress_deflate_avro(payload)
    elif codec_tag == AVRO_CODEC_SNAPPY:
        return _compress_snappy_avro(payload)
    elif codec_tag == AVRO_CODEC_ZSTANDARD:
        return _compress_zstandard_avro(payload)
    elif codec_tag == AVRO_CODEC_BZIP2:
        return _compress_bzip2_avro(payload)
    elif codec_tag == AVRO_CODEC_XZ:
        return _compress_xz_avro(payload)
    raise Error(
        String("AvroCodecError.UNKNOWN_CODEC: tag ") + String(codec_tag)
    )


# -----------------------------------------------------------------------------
# Deflate compress (RAW RFC-1951: level 6, windowBits -15).
# -----------------------------------------------------------------------------


def _compress_deflate_avro(payload: Span[UInt8, _]) raises -> List[UInt8]:
    """RAW-deflate-compress (level 6, windowBits -15): the inverse of
    `_decompress_deflate_avro`. libz writes straight into the returned List,
    sized at libz's own bound."""
    var cap = zlib_compress_bound(len(payload), ZLIB_WINDOW_BITS_RAW)
    var out = _output_buffer(max(cap, 1))
    var written: Int
    try:
        written = zlib_deflate_into(
            Span(out), payload, ZLIB_LEVEL_DEFAULT, ZLIB_WINDOW_BITS_RAW
        )
    except e:
        raise Error("AvroCodecError.DEFLATE_COMPRESS_FAILED: " + String(e))  # cov: unreachable output sized to the codec's bound; only a library failure raises
    out.resize(unsafe_uninit_length=written)
    return out^


# -----------------------------------------------------------------------------
# Snappy compress (Avro framing: raw_snappy ‖ BE4 crc32(uncompressed)).
# -----------------------------------------------------------------------------


def _compress_snappy_avro(payload: Span[UInt8, _]) raises -> List[UInt8]:
    """Snappy-compress then append the BE4 CRC32 trailer of the UNCOMPRESSED
    bytes (the Avro snappy block framing the decompressor expects).

    snappy writes straight into the returned List, which reserves
    `snappy_max_compressed_length + 4` bytes so the trailer fits without a
    reallocation.
    """
    var in_len = len(payload)
    var out_cap = snappy_max_compressed_length(in_len)
    var out = _output_buffer(out_cap + 4)
    var written: Int
    try:
        written = snappy_compress_into(Span(out)[0:out_cap], payload)
    except e:
        raise Error("AvroCodecError.SNAPPY_COMPRESS_FAILED: " + String(e))  # cov: unreachable output sized to the codec's bound; only a library failure raises
    # BE4 CRC32 of the UNCOMPRESSED payload (the Avro snappy trailer).
    var crc = crc32_ieee(payload)
    out[written + 0] = UInt8((crc >> 24) & UInt32(0xFF))
    out[written + 1] = UInt8((crc >> 16) & UInt32(0xFF))
    out[written + 2] = UInt8((crc >> 8) & UInt32(0xFF))
    out[written + 3] = UInt8(crc & UInt32(0xFF))
    out.resize(unsafe_uninit_length=written + 4)
    return out^


# -----------------------------------------------------------------------------
# Zstandard compress (level 3, libzstd's default).
# -----------------------------------------------------------------------------


def _compress_zstandard_avro(payload: Span[UInt8, _]) raises -> List[UInt8]:
    """Compress to a standard zstd frame at level 3. libzstd writes straight
    into the returned List, sized at libzstd's bound."""
    var out = _output_buffer(max(zstd_compress_bound(len(payload)), 1))
    var written: Int
    try:
        written = zstd_compress_into(Span(out), payload, ZSTD_DEFAULT_LEVEL)
    except e:
        raise Error("AvroCodecError.ZSTD_COMPRESS_FAILED: " + String(e))  # cov: unreachable output sized to the codec's bound; only a library failure raises
    out.resize(unsafe_uninit_length=written)
    return out^


# -----------------------------------------------------------------------------
# Bzip2 compress (block size 900k, the default work factor).
# -----------------------------------------------------------------------------


def _compress_bzip2_avro(payload: Span[UInt8, _]) raises -> List[UInt8]:
    """Compress to a standard bzip2 stream. libbz2 writes straight into the
    returned List, sized at its documented worst case plus headroom."""
    var in_len = len(payload)
    # bzip2 worst-case = in + 1% + 600 bytes (libbz2 docs).
    var out = _output_buffer(in_len + (in_len // 100) + 1024)
    var written: Int
    try:
        written = bzip2_compress_into(
            Span(out),
            payload,
            BZIP2_DEFAULT_BLOCK_SIZE_100K,
            BZIP2_DEFAULT_WORK_FACTOR,
        )
    except e:
        raise Error("AvroCodecError.BZIP2_COMPRESS_FAILED: " + String(e))  # cov: unreachable output sized to the libbz2 documented worst case plus headroom; only a library failure raises
    out.resize(unsafe_uninit_length=written)
    return out^


# -----------------------------------------------------------------------------
# Xz compress (preset 6, CRC64 check: liblzma's defaults).
# -----------------------------------------------------------------------------


def _compress_xz_avro(payload: Span[UInt8, _]) raises -> List[UInt8]:
    """Compress to a standard .xz stream. liblzma writes straight into the
    returned List, sized with generous headroom over the container's small
    overhead."""
    var in_len = len(payload)
    var out = _output_buffer(in_len + (in_len // 3) + 1024)
    var written: Int
    try:
        written = xz_compress_into(
            Span(out), payload, XZ_PRESET_DEFAULT, XZ_CHECK_CRC64
        )
    except e:
        raise Error("AvroCodecError.XZ_COMPRESS_FAILED: " + String(e))  # cov: unreachable output sized at input + 1/3 + 1024, above the xz worst-case expansion; only a library failure raises
    out.resize(unsafe_uninit_length=written)
    return out^
