# =============================================================================
# src/komira_http/codec/h1/chunked_encode.mojo
#   — Transfer-Encoding: chunked RESPONSE encoder (RFC 9112 §7.1)
# =============================================================================
#
# ★ WHY THIS EXISTS — the clone ceiling, and the one escape clause that lifts it.
#
# Cloud Run's documented limits are asymmetric, and the asymmetry is the whole
# reason this file exists (https://docs.cloud.google.com/run/quotas):
#
#   request  — "Maximum HTTP/1 request size: 32 MiB if using HTTP/1 server.
#               No limit if using HTTP/2 server."
#   response — "Maximum HTTP/1 response size: 32 MiB IF NOT USING
#               `Transfer-Encoding: chunked` or streaming mechanisms."
#
# The RESPONSE cap has an HTTP/1 escape hatch; the REQUEST cap does not.
# Without a chunked-response encoder — `serialize_response` emits the caller's
# `content-length` and nothing else — every large response (a git packfile, an
# archive) is on the wrong side of that clause, and the 32 MiB cap applies to
# it however the content is split.
#
# ⚠⚠ WHAT THIS FILE DOES AND DOES NOT BUY — read this before citing it.
#
#   * It buys the WIRE FRAMING. A response emitted through here carries
#     `Transfer-Encoding: chunked` and no `Content-Length`, which is the literal
#     condition Google's clause names.
#   * It does NOT buy STREAMING, and it does NOT lower peak resident memory by
#     one byte. `HttpResponse.body` is still a fully-materialised `List[UInt8]`;
#     this encoder re-frames a buffer that is already whole. A large response
#     can still exhaust the container's memory; it just cannot be refused by
#     the edge for framing.
#
# ★★ THE CEILING MOVES; IT DOES NOT VANISH — AND THE NEW ONE FAILS SILENTLY.
#
#   **A chunked response is cut mid-body at the platform's REQUEST TIMEOUT, and
#   the client can see HTTP 200 and a clean exit.** The frontend may close the
#   stream with a *well-formed terminating chunk*, so nothing at the HTTP layer
#   detects the truncation. The documented 504 is only reachable before the
#   response headers are sent, and a chunked response has already committed
#   200.
#
#   ⇒ **THE REAL CEILING IS `bytes / bandwidth < timeout`, NOT 32 MiB.**
#
#   ⇒ ⛔ **DO NOT TREAT AN HTTP STATUS AS COMPLETENESS ON THIS TRANSPORT.** A
#   caller that needs to know it got everything must carry its own end-to-end
#   check. `git-upload-pack` is safe because a packfile carries a trailing
#   checksum that `index-pack` verifies; **anything else sent this way
#   (archive download, CAS blob read) has no such property and needs one.**
#   A silently-truncated 200 is a fail-quiet result.
#
#   ⚠ A GATEWAY IN FRONT OF THE SERVICE MAY IMPOSE THE CAP ITSELF, whatever the
#   framing of the backend hop, so the escape hatch is a property of the whole
#   path, not of this encoder.
#
# # The grammar (RFC 9112 §7.1)
#
#   chunked-body = *chunk last-chunk trailer-section CRLF
#   chunk        = chunk-size [ chunk-ext ] CRLF chunk-data CRLF
#   chunk-size   = 1*HEXDIG
#   last-chunk   = 1*("0") [ chunk-ext ] CRLF
#
# We emit no chunk extensions and no trailers, so a complete body is
#   <hex>\r\n<data>\r\n ... <hex>\r\n<data>\r\n 0\r\n\r\n
#
# ★ `Content-Length` and `Transfer-Encoding` are MUTUALLY EXCLUSIVE (RFC 9112
# §6.2: "A sender MUST NOT send a Content-Length header field in any message
# that contains a Transfer-Encoding header field"). Emitting both is a request-
# smuggling shape and intermediaries reject or mis-frame it. Enforcing that is
# `serialize_response_framed`'s job, not this file's — this file only frames
# bytes — but it is stated here because the two are one contract.
#
# # Encapsulation discipline
#   * ZERO UnsafePointer anywhere; in/out are `List[UInt8]` / `Span[UInt8]`
#     / `Int` only.
#   * ZERO wildcard origins, ZERO `unsafe_from_address`, ZERO FFI.
#   * Nothing here is a struct, let alone one stored in a byte-slab.
# =============================================================================


# -----------------------------------------------------------------------------
# Constants.
# -----------------------------------------------------------------------------

# The per-chunk payload size used by `append_chunked_body`. 64 KiB matches the
# order of the git side-band pkt-line chunk (65500) that the payload is already
# framed into, so a git response's chunk boundaries land near its pkt-line
# boundaries and the framing overhead is ~0.02% of the body.
#
# NOT a correctness parameter: any positive value produces a well-formed body,
# and a receiver reassembles the octet stream identically regardless. It is a
# framing-overhead / syscall-granularity knob only.
comptime CHUNKED_ENCODE_CHUNK_BYTES: Int = 65536


@always_inline
def _hex_digit(nibble: Int) -> UInt8:
    """A single lowercase-hex ASCII digit for `nibble` in 0..15."""
    if nibble < 10:
        return UInt8(48 + nibble)  # '0'..'9'
    return UInt8(87 + nibble)  # 'a'..'f'  (87 == 'a' - 10)


def append_chunk_size_line(mut out: List[UInt8], size: Int):
    """Append `<hex-size>CRLF` — the chunk header.

    The size is written in lowercase hex with NO leading zeros and NO chunk
    extension, most-significant nibble first, and always at least one digit
    (so `size == 0` writes `0`, which is the `last-chunk` header).

    `size` is expected non-negative; a negative value would be a caller bug and
    is clamped to 0 rather than emitting a `-`-prefixed size that no HTTP
    receiver can parse.
    """
    var n = size
    if n <= 0:
        out.append(UInt8(48))  # '0'
    else:
        # Find the most-significant non-zero nibble, then emit downward. An Int
        # is 64-bit so at most 16 nibbles; shift 60, 56, ... 0.
        var shift = 60
        while shift > 0 and ((n >> shift) & 0xF) == 0:
            shift = shift - 4
        while shift >= 0:
            out.append(_hex_digit((n >> shift) & 0xF))
            shift = shift - 4
    out.append(UInt8(0x0D))  # CR
    out.append(UInt8(0x0A))  # LF


def append_chunk(mut out: List[UInt8], data: Span[UInt8, _]):
    """Append ONE complete chunk — `<hex-size>CRLF<data>CRLF` — for `data`.

    ⚠ A ZERO-LENGTH `data` IS A NO-OP, DELIBERATELY. A zero-size chunk header is
    the `last-chunk` marker, so emitting one here would terminate the body early
    and silently truncate everything after it — the receiver would report a
    short-but-well-formed response, which is the worst failure shape available.
    Call `append_last_chunk` to terminate; this function never can.
    """
    var n = len(data)
    if n == 0:
        return
    append_chunk_size_line(out, n)
    out.reserve(len(out) + n + 2)
    for i in range(n):
        out.append(data[i])
    out.append(UInt8(0x0D))  # CR
    out.append(UInt8(0x0A))  # LF


def append_last_chunk(mut out: List[UInt8]):
    """Append the terminator — `0CRLF` (last-chunk) + `CRLF` (empty trailer
    section). After this the chunked body is complete and the connection may
    carry the next response (keep-alive preserved, which a `Connection: close`
    delimited body would not).
    """
    out.append(UInt8(48))  # '0'
    out.append(UInt8(0x0D))
    out.append(UInt8(0x0A))
    out.append(UInt8(0x0D))
    out.append(UInt8(0x0A))


def append_chunked_body(
    mut out: List[UInt8],
    body: Span[UInt8, _],
    chunk_bytes: Int = CHUNKED_ENCODE_CHUNK_BYTES,
):
    """Append `body` to `out` as a COMPLETE chunked body: zero or more chunks of
    at most `chunk_bytes` payload each, then the terminator.

    An EMPTY `body` produces exactly `0\\r\\n\\r\\n` — a well-formed zero-length
    chunked body, which is what an empty 200 must look like under this framing
    (NOT nothing at all: a receiver that read no terminator would block).

    `chunk_bytes <= 0` is clamped to the default rather than dividing by zero or
    emitting one chunk per byte.
    """
    var step = chunk_bytes
    if step <= 0:
        step = CHUNKED_ENCODE_CHUNK_BYTES
    var n = len(body)
    # Framing overhead is bounded: per chunk, <=16 hex digits + 2 CRLF pairs.
    var chunks = (n + step - 1) // step
    out.reserve(len(out) + n + (chunks * 20) + 5)
    var off = 0
    while off < n:
        var end = off + step
        if end > n:
            end = n
        append_chunk(out, body[off:end])
        off = end
    append_last_chunk(out)
