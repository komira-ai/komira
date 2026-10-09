# =============================================================================
# src/komira_http_core/codec/h1/limits.mojo — parser limits + error taxonomy
# =============================================================================
#
# All hard limits
# and error categorizations live here so the parser, the chunked decoder,
# and the integration layer agree on what to reject and how.
#
# `ParseLimits` is the public knob bundle; `HttpServerConfig` constructs
# one from its own equivalent fields and threads it through.
# `ParseErrorKind` + `ParseError` are the structured outcome tags; the
# http status to send is encoded in the ParseError so the integration
# layer doesn't have to re-derive it.
# =============================================================================


# =============================================================================
# §1 — Parse limit defaults.
# =============================================================================
# These defaults are chosen to match common server defaults (nginx,
# Caddy). All can be overridden per HttpServerConfig.

comptime DEFAULT_MAX_HEADERS: Int = 100
comptime DEFAULT_MAX_HEADER_BYTES: Int = 8192
comptime DEFAULT_MAX_TOTAL_HEADER_BYTES: Int = 65536
comptime DEFAULT_MAX_BODY_BYTES: Int = 10 * 1024 * 1024
comptime DEFAULT_MAX_REQUEST_LINE_BYTES: Int = 8192
comptime DEFAULT_MAX_CHUNK_SIZE_LINE_BYTES: Int = 256
# Cumulative `chunk-ext` bytes the decoder will scan across a WHOLE chunked
# body. ⚠ THIS IS AN *EXTENSION* BUDGET, NOT A FRAMING-OVERHEAD RATIO, AND THE
# DIFFERENCE IS THE WHOLE POINT. A ratio detector rejects a legitimate
# byte-at-a-time producer (`1\r\nX\r\n` is 83% framing and perfectly legal --
# Go's TestChunkReaderByteAtATime), while leaving the actual attack untouched
# if the attacker just pads the payload. `chunk-ext` is what is unbounded and
# what nothing consumes: we parse it and throw it away, so every byte of it is
# pure attacker-chosen work. 64 KiB across an entire body is orders of
# magnitude more than any real producer emits.
# hyper: test_read_chunked_extensions_over_limit. Go: TestChunkReaderTooMuchOverhead.
comptime DEFAULT_MAX_TOTAL_CHUNK_EXT_BYTES: Int = 65536
# Max bytes the parser will sniff for the headers terminator (CRLFCRLF)
# before declaring the headers block too large. Distinct from
# max_total_header_bytes which is a parser-policy gate; this is a
# safety belt on the buffer we read into.
comptime DEFAULT_MAX_HEADERS_SCAN_BYTES: Int = 65536


@fieldwise_init
struct ParseLimits(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """Limits the parser enforces on every request.

    All sizes are bytes; all counts are integers. A request that violates
    any of these limits gets rejected with the corresponding HTTP status
    (see ParseErrorKind / `ParseError.status_code()`).
    """

    var max_headers: Int
    """Maximum number of header lines (excluding the request line itself).
    Default 100. Overflow → 431 Request Header Fields Too Large."""

    var max_header_bytes: Int
    """Maximum bytes in a single header line (Name: Value\\r\\n). Default
    8192. Overflow → 431."""

    var max_total_header_bytes: Int
    """Maximum aggregate bytes across all header lines + the request
    line. Default 65536. Overflow → 431."""

    var max_body_bytes: Int
    """Maximum Content-Length value the parser will accept (and the
    max bytes the chunked decoder will accumulate). Default 10 MiB.
    Overflow → 413 Payload Too Large."""

    var max_request_line_bytes: Int
    """Maximum bytes in the request line itself. Default 8192. Overflow →
    414 URI Too Long (we map to 414 only for URI overflow; bad shape
    is 400)."""

    @staticmethod
    def defaults() -> ParseLimits:
        return ParseLimits(
            max_headers=DEFAULT_MAX_HEADERS,
            max_header_bytes=DEFAULT_MAX_HEADER_BYTES,
            max_total_header_bytes=DEFAULT_MAX_TOTAL_HEADER_BYTES,
            max_body_bytes=DEFAULT_MAX_BODY_BYTES,
            max_request_line_bytes=DEFAULT_MAX_REQUEST_LINE_BYTES,
        )


# =============================================================================
# §2 — Error taxonomy.
# =============================================================================
# Distinct error kinds so tests can assert WHICH validation failed
# without depending on the response body (which is sanitized + static).
#
# Status mapping below is the canonical RFC 7230 / 9110 mapping:
#   400 Bad Request      — generic well-formed-ness failure
#   408 Request Timeout  — (not used yet — connection-layer concern)
#   411 Length Required  — POST/PUT without CL or TE
#   413 Payload Too Large — body exceeds max_body_bytes
#   414 URI Too Long     — request-target exceeds max_request_line_bytes
#   417 Expectation Failed — Expect: <non-100-continue token>
#   431 Request Header Fields Too Large — header count/bytes overflow
#   501 Not Implemented  — a method this parser does not recognize
#                          (RFC 9110 §9.1), lowercase spellings included
#   505 HTTP Version Not Supported — a major version other than HTTP/1

comptime PARSE_ERR_NONE: UInt8 = 0
# Request-line errors → 400 Bad Request (some specific 414/501/505 carve-outs).
comptime PARSE_ERR_REQUEST_LINE_MALFORMED: UInt8 = 1
comptime PARSE_ERR_METHOD_UNKNOWN: UInt8 = 2       # → 501
comptime PARSE_ERR_METHOD_LOWERCASE: UInt8 = 3     # → 501
comptime PARSE_ERR_URI_WHITESPACE: UInt8 = 4
comptime PARSE_ERR_URI_TOO_LONG: UInt8 = 5         # → 414
comptime PARSE_ERR_HTTP_VERSION_BAD: UInt8 = 6
comptime PARSE_ERR_HTTP_VERSION_UNSUPPORTED: UInt8 = 7  # → 505
comptime PARSE_ERR_HTTP_09_REJECTED: UInt8 = 8     # → 400
# Header errors.
comptime PARSE_ERR_HEADER_NO_COLON: UInt8 = 20
comptime PARSE_ERR_HEADER_NAME_INVALID: UInt8 = 21
comptime PARSE_ERR_HEADER_VALUE_CONTROL_CHAR: UInt8 = 22
comptime PARSE_ERR_HEADER_OBS_FOLD: UInt8 = 23
comptime PARSE_ERR_HEADER_COUNT_OVERFLOW: UInt8 = 24    # → 431
comptime PARSE_ERR_HEADER_SIZE_OVERFLOW: UInt8 = 25     # → 431
comptime PARSE_ERR_HEADER_TOTAL_OVERFLOW: UInt8 = 26    # → 431
# Body / encoding errors.
comptime PARSE_ERR_CONTENT_LENGTH_INVALID: UInt8 = 40
comptime PARSE_ERR_CONTENT_LENGTH_CONFLICT: UInt8 = 41
comptime PARSE_ERR_CONTENT_LENGTH_AND_CHUNKED: UInt8 = 42
comptime PARSE_ERR_CHUNK_SIZE_INVALID: UInt8 = 43
comptime PARSE_ERR_CHUNK_MISSING_CRLF: UInt8 = 44
comptime PARSE_ERR_CHUNK_TRAILER_INVALID: UInt8 = 45
comptime PARSE_ERR_BODY_TOO_LARGE: UInt8 = 46           # → 413
comptime PARSE_ERR_EXPECT_UNSUPPORTED: UInt8 = 47       # → 417
comptime PARSE_ERR_TRANSFER_ENCODING_UNSUPPORTED: UInt8 = 48
comptime PARSE_ERR_CHUNK_TRAILER_TOO_LARGE: UInt8 = 49   # → 431
comptime PARSE_ERR_CHUNK_EXT_TOO_LARGE: UInt8 = 50       # → 400
# Incomplete (caller may retry with more bytes — NOT a hard error).
comptime PARSE_ERR_NEED_MORE: UInt8 = 100


@fieldwise_init
struct ParseError(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """Structured parse-failure outcome.

    Fields:
      kind   — PARSE_ERR_* (see aliases above)
      status — HTTP status code to send on the wire (0 if kind==NONE)
      offset — byte offset in the buffer where the error was detected
               (-1 if not applicable)

    `ParseError(kind=PARSE_ERR_NONE)` represents "no error" — the parser
    fills this on success.
    """
    var kind: UInt8
    var status: UInt16
    var offset: Int

    @staticmethod
    def none() -> ParseError:
        return ParseError(kind=PARSE_ERR_NONE, status=UInt16(0), offset=-1)

    @staticmethod
    def need_more(offset: Int) -> ParseError:
        return ParseError(
            kind=PARSE_ERR_NEED_MORE, status=UInt16(0), offset=offset,
        )

    @staticmethod
    def make(kind: UInt8, offset: Int) -> ParseError:
        """Construct a ParseError + auto-fill the status from `kind`."""
        var s = _kind_to_status(kind)
        return ParseError(kind=kind, status=s, offset=offset)

    def is_ok(self) -> Bool:
        return self.kind == PARSE_ERR_NONE

    def is_need_more(self) -> Bool:
        return self.kind == PARSE_ERR_NEED_MORE


def _kind_to_status(kind: UInt8) -> UInt16:
    """Map a ParseErrorKind to the HTTP status code to send."""
    if kind == PARSE_ERR_NONE:
        return UInt16(0)
    if kind == PARSE_ERR_NEED_MORE:
        return UInt16(0)
    # 414 URI Too Long
    if kind == PARSE_ERR_URI_TOO_LONG:
        return UInt16(414)
    # 501 Not Implemented: RFC 9110 §9.1, an unrecognized method. Methods
    # are case-sensitive, so a lowercase spelling is an unrecognized method.
    if kind == PARSE_ERR_METHOD_UNKNOWN:
        return UInt16(501)
    if kind == PARSE_ERR_METHOD_LOWERCASE:
        return UInt16(501)
    # 505 HTTP Version Not Supported
    if kind == PARSE_ERR_HTTP_VERSION_UNSUPPORTED:
        return UInt16(505)
    # 431 Request Header Fields Too Large
    if kind == PARSE_ERR_HEADER_COUNT_OVERFLOW:
        return UInt16(431)
    if kind == PARSE_ERR_HEADER_SIZE_OVERFLOW:
        return UInt16(431)
    if kind == PARSE_ERR_HEADER_TOTAL_OVERFLOW:
        return UInt16(431)
    # RFC 9110 §6.5: a trailer section IS a field section, so an oversized
    # one is the same 431 an oversized header section is.
    if kind == PARSE_ERR_CHUNK_TRAILER_TOO_LARGE:
        return UInt16(431)
    # 413 Payload Too Large
    if kind == PARSE_ERR_BODY_TOO_LARGE:
        return UInt16(413)
    # 417 Expectation Failed
    if kind == PARSE_ERR_EXPECT_UNSUPPORTED:
        return UInt16(417)
    # All other categories — Bad Request.
    return UInt16(400)


# =============================================================================
# §3 — Sanitization helpers (XSS / log-injection prevention).
# =============================================================================


def sanitize_for_log(src: String, max_len: Int) -> String:
    """Strip control characters + truncate. Use for log lines that
    include user-controlled bytes.

    Replaces every byte < 0x20 OR == 0x7F with '?'. Truncates to
    max_len. Does NOT do HTML-escape — the parser never writes user
    bytes into HTTP response bodies (those are static error strings).
    """
    var out = String()
    var bytes_ref = src.as_bytes()
    var n = len(bytes_ref)
    var lim = n if n < max_len else max_len
    var i = 0
    while i < lim:
        var b = Int(bytes_ref[i])
        if b < 0x20 or b == 0x7F:
            out = out + "?"
        else:
            # Map back via a 1-byte string. Safe because we only kept
            # printable ASCII; no UTF-8 multi-byte sequence concerns.
            out = out + chr(b)
        i = i + 1
    if n > max_len:
        out = out + "..."
    return out^
