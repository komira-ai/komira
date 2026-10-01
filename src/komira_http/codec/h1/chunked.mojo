# =============================================================================
# src/komira_http/codec/h1/chunked.mojo — Transfer-Encoding: chunked decoder
# =============================================================================
#
#
#
# Implements RFC 7230 §4.1 — chunked transfer-encoding.
#   chunked-body   = *chunk
#                    last-chunk
#                    trailer-part
#                    CRLF
#   chunk          = chunk-size [ chunk-ext ] CRLF
#                    chunk-data CRLF
#   chunk-size     = 1*HEXDIG
#   last-chunk     = 1*("0") [ chunk-ext ] CRLF
#   chunk-data     = 1*OCTET ; a sequence of chunk-size octets
#   trailer-part   = *( header-field CRLF )
#
# Decoder is incremental: caller drives `decode` repeatedly with newly-
# received bytes; the decoder appends to a destination buffer until
# either DONE, NEED_MORE, or ERROR.
#
# `chunk-ext` is parsed-and-ignored. Trailers are parsed-and-discarded
# (length-validated against header limits; not folded into the request's
# header map per RFC 7230 §4.1.2 — trailers in HTTP/1.1 are rarely used
# and most servers either ignore or reject; we ignore).
#
# No UnsafePointer in any public sig. No wildcard origin.
# =============================================================================

from komira_http.codec.h1.limits import (
    DEFAULT_MAX_CHUNK_SIZE_LINE_BYTES,
    DEFAULT_MAX_TOTAL_CHUNK_EXT_BYTES,
    PARSE_ERR_BODY_TOO_LARGE,
    PARSE_ERR_CHUNK_EXT_TOO_LARGE,
    PARSE_ERR_CHUNK_MISSING_CRLF,
    PARSE_ERR_CHUNK_SIZE_INVALID,
    PARSE_ERR_CHUNK_TRAILER_INVALID,
    PARSE_ERR_CHUNK_TRAILER_TOO_LARGE,
    ParseError,
    ParseLimits,
)


# =============================================================================
# §1 — Decoder state.
# =============================================================================

comptime _DECODE_STATE_INIT: UInt8 = 0
comptime _DECODE_STATE_CHUNK_SIZE: UInt8 = 1
comptime _DECODE_STATE_CHUNK_DATA: UInt8 = 2
comptime _DECODE_STATE_CHUNK_DATA_CRLF: UInt8 = 3
comptime _DECODE_STATE_TRAILER: UInt8 = 4
comptime _DECODE_STATE_DONE: UInt8 = 5
comptime _DECODE_STATE_ERROR: UInt8 = 6


@fieldwise_init
struct ChunkedDecoder(Movable, Deinitable):
    """Incremental state machine for chunked transfer-encoding.

    Construct with `init()` then drive via `decode_block` until the
    decoder reports DONE or ERROR. Output bytes are appended into the
    caller's `body` buffer.

    Fields all default-initialized so a single `ChunkedDecoder()` is a
    valid starting state.
    """

    var state: UInt8
    """One of _DECODE_STATE_*."""

    var current_chunk_remaining: Int
    """Bytes left in the current chunk's data section."""

    var bytes_emitted: Int
    """Total decoded body bytes appended so far (for max_body_bytes check)."""

    var trailer_fields: Int
    """Trailer field-lines accepted so far, against `limits.max_headers`.

    RFC 9110 §6.5 -- a trailer section IS a field section, so the header
    section's count ceiling governs it. Without this the cheapest way past a
    header-count limit is to move the fields after the body."""

    var trailer_bytes: Int
    """Cumulative bytes (line + CRLF) accepted in the trailer section, against
    `limits.max_total_header_bytes`.

    ⚠ THIS IS THE FIELD WHOSE ABSENCE MADE THE SECTION BUDGET DEPEND ON TCP
    SEGMENTATION. The only bound the loop used to carry compared the PARTIAL
    tail to `max_total_header_bytes`, so N individually-tiny lines summed to an
    unbounded section, and the same oversized line got two different framing
    verdicts depending on how the peer packetised it."""

    var chunk_ext_bytes: Int
    """Cumulative `chunk-ext` bytes scanned across the whole body, against
    `DEFAULT_MAX_TOTAL_CHUNK_EXT_BYTES`. Extension bytes ONLY -- never framing
    bytes; see that constant's comment for why the distinction is the fix."""

    var err: ParseError

    @staticmethod
    def init() -> ChunkedDecoder:
        return ChunkedDecoder(
            state=_DECODE_STATE_INIT,
            current_chunk_remaining=0,
            bytes_emitted=0,
            trailer_fields=0,
            trailer_bytes=0,
            chunk_ext_bytes=0,
            err=ParseError.none(),
        )

    def is_done(self) -> Bool:
        return self.state == _DECODE_STATE_DONE

    def is_error(self) -> Bool:
        return self.state == _DECODE_STATE_ERROR


# =============================================================================
# §2 — Outcome of one `decode_block` invocation.
# =============================================================================

# Indicates what the caller should do next.
comptime CHUNKED_RES_NEED_MORE: UInt8 = 0
comptime CHUNKED_RES_DONE: UInt8 = 1
comptime CHUNKED_RES_ERROR: UInt8 = 2


@fieldwise_init
struct ChunkedDecodeResult(Copyable, Movable, Deinitable):
    """Result of `decode_block`. `consumed` = bytes from the input
    that the decoder processed (caller should advance its buffer
    pointer by this). `outcome` = NEED_MORE / DONE / ERROR."""
    var outcome: UInt8
    var consumed: Int


# =============================================================================
# §3 — Hex parsing helpers.
# =============================================================================


def _is_hex_digit(b: UInt8) -> Bool:
    var c = Int(b)
    if c >= Int(ord("0")) and c <= Int(ord("9")):
        return True
    if c >= Int(ord("a")) and c <= Int(ord("f")):
        return True
    if c >= Int(ord("A")) and c <= Int(ord("F")):
        return True
    return False


def _hex_value(b: UInt8) -> Int:
    var c = Int(b)
    if c >= Int(ord("0")) and c <= Int(ord("9")):
        return c - Int(ord("0"))
    if c >= Int(ord("a")) and c <= Int(ord("f")):
        return 10 + (c - Int(ord("a")))
    if c >= Int(ord("A")) and c <= Int(ord("F")):
        return 10 + (c - Int(ord("A")))
    return -1


def _find_crlf_in(buf: Span[UInt8, _], start: Int, limit: Int) -> Int:
    """Find CR LF at offset >= start, up to `limit` total bytes. Returns
    the offset of the CR or -1 if not found within the limit."""
    var n = len(buf)
    var stop = n if n < limit else limit
    var i = start
    while i + 1 < stop:
        if buf[i] == UInt8(0x0D) and buf[i + 1] == UInt8(0x0A):
            return i
        i = i + 1
    return -1


comptime _MAX_CHUNK_SIZE: Int = 1 << 62
"""Ceiling on a decoded chunk-size. Retained from the original guard."""

comptime _MAX_CHUNK_SIZE_DIV16: Int = _MAX_CHUNK_SIZE >> 4
"""Pre-multiply admission bound: `v <= this` makes `v * 16 + 15` unable to
exceed `_MAX_CHUNK_SIZE + 15`, so the accumulate cannot wrap Int64. A shift,
not a divide — this is per hex digit of a <= 256-byte line, not a hot loop,
but there is no reason to spend a division either."""


def _parse_chunk_size_line(
    buf: Span[UInt8, _], start: Int, end_excl: Int,
) -> Int:
    """Parse the chunk-size line up to the first ';' (chunk-ext start)
    or end. Returns the decoded chunk size, or -1 on error.

    Chunk-extension after ';' is parsed-and-ignored.
    """
    var i = start
    var v = 0
    var saw_digit = False
    while i < end_excl:
        var b = buf[i]
        if b == UInt8(ord(";")):
            break
        if b == UInt8(0x20) or b == UInt8(0x09):
            # Trailing whitespace before ';' or before CRLF — be
            # tolerant per RFC 7230 §4.1.1.
            #
            # ⛔ BUT TOLERANCE IS NOT SILENCE, AND THE OLD FORM WAS SILENCE.
            # It `break`ed here and returned the size it had accumulated
            # WITHOUT LOOKING AT WHAT FOLLOWED, so every byte after the first
            # space was ignored whatever it was: `2 erfrferferf` framed a
            # 2-byte chunk. Go's chunked reader rejects that line
            # (`parseHexUint` errors on the first non-hex byte), and a peer
            # that rejects while we accept disagree about where the NEXT
            # message starts — a response-smuggling primitive of the same
            # family as the `10000000000000005` overflow guarded above.
            #
            # RFC 9112 §7.1: `chunk = chunk-size [ chunk-ext ] CRLF`. So after
            # the BWS run exactly two things are legal — the end of the line,
            # or the `;` that opens a chunk-ext. Anything else is junk and the
            # line is rejected. (`3 ; spaced = yes ` stays legal: BWS, then a
            # `;`.)
            var j = i
            while j < end_excl and (
                buf[j] == UInt8(0x20) or buf[j] == UInt8(0x09)
            ):
                j = j + 1
            if j < end_excl and buf[j] != UInt8(ord(";")):
                return -1
            break
        if not _is_hex_digit(b):
            return -1
        # ⚠ THE GUARD IS BEFORE THE MULTIPLY, AND THAT IS THE WHOLE POINT.
        # Doing `v = v * 16 + d` and THEN testing
        # `v > (1 << 62)` is too late: the multiply has already happened: with
        # v == 1 << 62 admitted by the prior iteration, `v * 16` is ~2^66 and
        # WRAPS, and the wrapped value can be small and POSITIVE, so the test
        # passes. At ASSERT=none the chunk-size line
        # "10000000000000005" (17 hex digits, inside the 256-byte line cap)
        # would be accepted and return **5**. A peer or proxy that parses the
        # same line correctly sees 2^64 + 5 — that difference is a
        # request-smuggling primitive, and it is not an ASSERT question:
        # nothing here was ever a bounds check.
        if v > _MAX_CHUNK_SIZE_DIV16:
            return -1
        v = v * 16 + _hex_value(b)
        saw_digit = True
        if v > _MAX_CHUNK_SIZE:
            return -1
        i = i + 1
    if not saw_digit:
        return -1
    return v


def _chunk_ext_bytes_in(
    buf: Span[UInt8, _], start: Int, end_excl: Int,
) -> Int:
    """Count the `chunk-ext` bytes on one chunk-size line: from the first ';'
    through the end of the line. 0 when the line carries no extension.

    ⚠ EXTENSION BYTES, NOT FRAMING BYTES. A byte-at-a-time producer emitting
    `1\\r\\nX\\r\\n` has 83% framing overhead and zero extension bytes, and it
    is entirely legal (Go TestChunkReaderByteAtATime); charging it framing
    would reject a conforming peer to catch nothing."""
    var i = start
    while i < end_excl:
        if buf[i] == UInt8(ord(";")):
            return end_excl - i
        i = i + 1
    return 0


def _is_field_octet(b: UInt8) -> Bool:
    """RFC 9110 §5.5 `field-content` octets: HTAB, SP, VCHAR (0x21-0x7E) and
    obs-text (0x80-0xFF).

    Everything else is forbidden inside a field line — NUL, DEL, and every
    other C0 control INCLUDING A BARE CR. The bare CR is the one that matters
    here: `_find_crlf_in` only matches CR+LF, so a lone CR used to be
    swallowed into the middle of an accepted trailer line. A downstream parser
    that terminates lines on CR alone then sees two fields where we saw one,
    which is response splitting."""
    if b == UInt8(0x09):
        return True
    if b >= UInt8(0x20) and b <= UInt8(0x7E):
        return True
    if b >= UInt8(0x80):
        return True
    return False


# =============================================================================
# §4 — decode_block — the public entry point.
# =============================================================================


def decode_block(
    mut decoder: ChunkedDecoder,
    src: Span[UInt8, _],
    limits: ParseLimits,
    mut body: List[UInt8],
) -> ChunkedDecodeResult:
    """Drive the decoder forward against `src`. Appends decoded body
    bytes into `body` (up to `limits.max_body_bytes`).

    Returns the # of bytes from `src` consumed + an outcome.

    On `outcome == CHUNKED_RES_DONE`: decoder is in DONE state; the
    request body is fully in `body`. Caller may discard the decoder.
    On `outcome == CHUNKED_RES_NEED_MORE`: decoder retains state;
    caller should call again with more bytes appended to `src`.
    On `outcome == CHUNKED_RES_ERROR`: `decoder.err` contains the
    ParseError; integration layer should serialize the corresponding
    HTTP status and close the conn.
    """
    var n = len(src)
    var i = 0
    while True:
        if decoder.state == _DECODE_STATE_INIT or decoder.state == _DECODE_STATE_CHUNK_SIZE:
            # Need a CRLF-terminated chunk-size line.
            var crlf = _find_crlf_in(src, i, n)
            if crlf < 0:
                # Hard cap on chunk-size line length.
                if n - i > DEFAULT_MAX_CHUNK_SIZE_LINE_BYTES:
                    decoder.state = _DECODE_STATE_ERROR
                    decoder.err = ParseError.make(
                        PARSE_ERR_CHUNK_SIZE_INVALID, i,
                    )
                    return ChunkedDecodeResult(
                        outcome=CHUNKED_RES_ERROR, consumed=i,
                    )
                return ChunkedDecodeResult(
                    outcome=CHUNKED_RES_NEED_MORE, consumed=i,
                )
            if crlf - i > DEFAULT_MAX_CHUNK_SIZE_LINE_BYTES:
                decoder.state = _DECODE_STATE_ERROR
                decoder.err = ParseError.make(
                    PARSE_ERR_CHUNK_SIZE_INVALID, i,
                )
                return ChunkedDecodeResult(
                    outcome=CHUNKED_RES_ERROR, consumed=i,
                )
            var sz = _parse_chunk_size_line(src, i, crlf)
            if sz < 0:
                decoder.state = _DECODE_STATE_ERROR
                decoder.err = ParseError.make(
                    PARSE_ERR_CHUNK_SIZE_INVALID, i,
                )
                return ChunkedDecodeResult(
                    outcome=CHUNKED_RES_ERROR, consumed=i,
                )
            # Cumulative chunk-extension budget. An extension is parsed and
            # thrown away, so every byte of it is attacker-chosen work that
            # nothing consumes; the per-line 256-byte cap above is no bound at
            # all on a peer that simply repeats the line. ~10k chunks each
            # carrying 100 extension bytes is 1 MB of wire for 10 KB of
            # payload. Charged ONCE per line: `i` advances past the line below
            # and `consumed` never re-presents it.
            var ext_len = _chunk_ext_bytes_in(src, i, crlf)
            if ext_len > 0:
                decoder.chunk_ext_bytes = decoder.chunk_ext_bytes + ext_len
                if decoder.chunk_ext_bytes > DEFAULT_MAX_TOTAL_CHUNK_EXT_BYTES:
                    decoder.state = _DECODE_STATE_ERROR
                    decoder.err = ParseError.make(
                        PARSE_ERR_CHUNK_EXT_TOO_LARGE, i,
                    )
                    return ChunkedDecodeResult(
                        outcome=CHUNKED_RES_ERROR, consumed=i,
                    )
            # Advance past chunk-size line.
            i = crlf + 2
            if sz == 0:
                # Last chunk — transition to trailer parse.
                decoder.state = _DECODE_STATE_TRAILER
                continue
            # Body-size cap check.
            if decoder.bytes_emitted + sz > limits.max_body_bytes:
                decoder.state = _DECODE_STATE_ERROR
                decoder.err = ParseError.make(
                    PARSE_ERR_BODY_TOO_LARGE, i,
                )
                return ChunkedDecodeResult(
                    outcome=CHUNKED_RES_ERROR, consumed=i,
                )
            decoder.current_chunk_remaining = sz
            decoder.state = _DECODE_STATE_CHUNK_DATA
            continue

        if decoder.state == _DECODE_STATE_CHUNK_DATA:
            var available = n - i
            if available <= 0:
                return ChunkedDecodeResult(
                    outcome=CHUNKED_RES_NEED_MORE, consumed=i,
                )
            var to_take = decoder.current_chunk_remaining
            if available < to_take:
                to_take = available
            var k = 0
            while k < to_take:
                body.append(src[i + k])
                k = k + 1
            i = i + to_take
            decoder.current_chunk_remaining = (
                decoder.current_chunk_remaining - to_take
            )
            decoder.bytes_emitted = decoder.bytes_emitted + to_take
            if decoder.current_chunk_remaining > 0:
                return ChunkedDecodeResult(
                    outcome=CHUNKED_RES_NEED_MORE, consumed=i,
                )
            # Full chunk data done — expect terminating CRLF.
            decoder.state = _DECODE_STATE_CHUNK_DATA_CRLF
            continue

        if decoder.state == _DECODE_STATE_CHUNK_DATA_CRLF:
            if n - i < 2:
                return ChunkedDecodeResult(
                    outcome=CHUNKED_RES_NEED_MORE, consumed=i,
                )
            if src[i] != UInt8(0x0D) or src[i + 1] != UInt8(0x0A):
                decoder.state = _DECODE_STATE_ERROR
                decoder.err = ParseError.make(
                    PARSE_ERR_CHUNK_MISSING_CRLF, i,
                )
                return ChunkedDecodeResult(
                    outcome=CHUNKED_RES_ERROR, consumed=i,
                )
            i = i + 2
            decoder.state = _DECODE_STATE_CHUNK_SIZE
            continue

        if decoder.state == _DECODE_STATE_TRAILER:
            # Read header-field-shaped lines until we hit an empty
            # line. Lines are CRLF-terminated. The empty line terminates
            # the trailer (CRLF). Per RFC 7230 §4.1.2 we discard.
            var crlf2 = _find_crlf_in(src, i, n)
            if crlf2 < 0:
                # NO CRLF IN HAND, so `src[i..n]` is at most ONE partial line.
                #
                # ⛔ THE OLD BOUND HERE WAS THE SECTION BUDGET APPLIED TO THE
                # PARTIAL TAIL, and it was the section's ONLY bound. That is
                # what made the same 200 KB trailer line get two different
                # framing verdicts depending on TCP segmentation: delivered in
                # 64 KiB reads the carry outgrew 65536 before the CRLF
                # arrived and it was rejected; handed over in one buffer the
                # `crlf2 < 0` arm never ran and it was accepted. A framing
                # decision that depends on packetisation is the exact property
                # an attacker picks. Both bounds below are now stated on BOTH
                # arms, so the verdict is a function of the bytes alone.
                if n - i > limits.max_header_bytes:
                    decoder.state = _DECODE_STATE_ERROR
                    decoder.err = ParseError.make(
                        PARSE_ERR_CHUNK_TRAILER_TOO_LARGE, i,
                    )
                    return ChunkedDecodeResult(
                        outcome=CHUNKED_RES_ERROR, consumed=i,
                    )
                if (
                    decoder.trailer_bytes + (n - i)
                    > limits.max_total_header_bytes
                ):
                    decoder.state = _DECODE_STATE_ERROR
                    decoder.err = ParseError.make(
                        PARSE_ERR_CHUNK_TRAILER_TOO_LARGE, i,
                    )
                    return ChunkedDecodeResult(
                        outcome=CHUNKED_RES_ERROR, consumed=i,
                    )
                return ChunkedDecodeResult(
                    outcome=CHUNKED_RES_NEED_MORE, consumed=i,
                )
            if crlf2 == i:
                # Empty line → end of trailer + end of chunked body.
                i = i + 2
                decoder.state = _DECODE_STATE_DONE
                return ChunkedDecodeResult(
                    outcome=CHUNKED_RES_DONE, consumed=i,
                )
            # A COMPLETE trailer line is in hand. RFC 9110 §6.5 makes a
            # trailer section a field section, so the header section's three
            # ceilings govern it — per-line bytes, field count, and the
            # aggregate byte budget. Envoy's
            # `LargeTrailersRejectedEvenWhenDisabled` is why "we discard
            # trailers anyway" is not a defence: a disabled feature that still
            # READS its input is an unbounded sink, and a cheaper one than a
            # supported feature because no limit was ever wired to it.
            if crlf2 - i > limits.max_header_bytes:
                decoder.state = _DECODE_STATE_ERROR
                decoder.err = ParseError.make(
                    PARSE_ERR_CHUNK_TRAILER_TOO_LARGE, i,
                )
                return ChunkedDecodeResult(
                    outcome=CHUNKED_RES_ERROR, consumed=i,
                )
            if decoder.trailer_fields + 1 > limits.max_headers:
                decoder.state = _DECODE_STATE_ERROR
                decoder.err = ParseError.make(
                    PARSE_ERR_CHUNK_TRAILER_TOO_LARGE, i,
                )
                return ChunkedDecodeResult(
                    outcome=CHUNKED_RES_ERROR, consumed=i,
                )
            var line_bytes = (crlf2 + 2) - i
            if (
                decoder.trailer_bytes + line_bytes
                > limits.max_total_header_bytes
            ):
                decoder.state = _DECODE_STATE_ERROR
                decoder.err = ParseError.make(
                    PARSE_ERR_CHUNK_TRAILER_TOO_LARGE, i,
                )
                return ChunkedDecodeResult(
                    outcome=CHUNKED_RES_ERROR, consumed=i,
                )
            # Shape: a colon, and every octet a legal field octet. The old
            # loop asked only "is there a colon somewhere" and BROKE on the
            # first one, so any octet except a CRLF pair rode through — a NUL
            # or a bare CR included.
            var has_colon = False
            var k2 = i
            while k2 < crlf2:
                var cb = src[k2]
                if not _is_field_octet(cb):
                    decoder.state = _DECODE_STATE_ERROR
                    decoder.err = ParseError.make(
                        PARSE_ERR_CHUNK_TRAILER_INVALID, k2,
                    )
                    return ChunkedDecodeResult(
                        outcome=CHUNKED_RES_ERROR, consumed=i,
                    )
                if cb == UInt8(ord(":")):
                    has_colon = True
                k2 = k2 + 1
            if not has_colon:
                decoder.state = _DECODE_STATE_ERROR
                decoder.err = ParseError.make(
                    PARSE_ERR_CHUNK_TRAILER_INVALID, i,
                )
                return ChunkedDecodeResult(
                    outcome=CHUNKED_RES_ERROR, consumed=i,
                )
            decoder.trailer_fields = decoder.trailer_fields + 1
            decoder.trailer_bytes = decoder.trailer_bytes + line_bytes
            i = crlf2 + 2
            continue

        if decoder.state == _DECODE_STATE_DONE:
            return ChunkedDecodeResult(
                outcome=CHUNKED_RES_DONE, consumed=i,
            )

        if decoder.state == _DECODE_STATE_ERROR:
            return ChunkedDecodeResult(
                outcome=CHUNKED_RES_ERROR, consumed=i,
            )

        # Unreachable — defensive bail.
        return ChunkedDecodeResult(
            outcome=CHUNKED_RES_ERROR, consumed=i,
        )
