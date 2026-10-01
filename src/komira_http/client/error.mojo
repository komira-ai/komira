# =============================================================================
# src/komira_http/client/error.mojo — HttpError typed error
# =============================================================================
#
# A thiserror-shaped enum with context-carrying variants. The taxonomy:
#   ConnectFailed / TlsVerifyFailed / TlsHandshakeFailed /
#   RetryableTransport / ResponseFraming / H2Protocol /
#   ProtocolStatus / BodyTooLarge / Cancelled / Timeout
#
# The RetryableTransport vs everything-else split is the load-bearing
# distinction — what `RetryLayer` and `komira_objectstore` both
# branch on.
#
# Mojo 1.0.0b1 has no comptime enums. We use a UInt8 sentinel namespace
# and an `HttpError` POD struct carrying (kind, detail, status). The error
# `detail` is for log lines + actionable messages; per the parser-
# hardening idiom) it MUST NEVER contain client-controlled bytes
# verbatim — sanitize via `sanitize_for_log` from the codec/h1 limits
# module before passing client-derived content here.
#
# Pointer discipline:
#   * ZERO UnsafePointer in any signature.
#   * ZERO wildcard origins.
#   * ZERO `unsafe_from_address`.
#   * `detail` is a String (owned). No borrowed-origin fields.
# =============================================================================


# =============================================================================
# §1 — HttpErrorKind UInt8 sentinel namespace.
# =============================================================================
# Numeric ranges grouped by failure class so future variants stay
# semantically clustered (10..19 = connect, 20..29 = TLS, 30..39 =
# transport, 40..49 = protocol/framing, 50..59 = HTTP/2 specific,
# 60..69 = body, 70..79 = control, 80.. = generic).

comptime HTTP_ERROR_NONE: UInt8 = 0
"""No error sentinel — used by HttpError.none() for default-construction
and assertions. NEVER returned from a raises path."""

# --- Connect setup ----------------------------------------------------------

comptime HTTP_ERROR_CONNECT_FAILED: UInt8 = 10
"""Dial failed — DNS resolution failure, ECONNREFUSED, EHOSTUNREACH, the
fd creation syscall fails, etc. NOT retryable at the L7 level by default
(the connect attempt itself is presumed terminal); the consumer may
re-issue with a different endpoint."""

comptime HTTP_ERROR_CONNECT_TIMEOUT: UInt8 = 11
"""Dial timed out — the configured `connect_timeout` elapsed without a
SO_ERROR-clear. NOT retryable at the L7 level by default;
RetryLayer with explicit backoff may re-attempt."""

# --- TLS --------------------------------------------------------------------

comptime HTTP_ERROR_TLS_VERIFY_FAILED: UInt8 = 20
"""Cert chain / hostname / expiry validation failed. NOT retryable —
a fresh dial would fail the same way. Surfaced AS-IS."""

comptime HTTP_ERROR_TLS_HANDSHAKE_FAILED: UInt8 = 21
"""S2n handshake error other than verification (e.g. truncated record,
unexpected protocol version, ALPN mismatch). Treat as transient at
the consumer's discretion."""

# --- Transport (raw I/O) ----------------------------------------------------

comptime HTTP_ERROR_IO_ERROR: UInt8 = 30
"""Raw I/O error after the connection was established — read/write
syscall returned an errno other than EAGAIN/EWOULDBLOCK. The
HttpError.status field carries the errno value when this kind fires."""

comptime HTTP_ERROR_RETRYABLE_TRANSPORT: UInt8 = 31
"""Connection reset (RST) before any response byte was received, OR
the peer closed mid-headers, OR — under HTTP/2 — a GOAWAY stream-id
indicates this stream is safe to retry on a new connection. This is
the load-bearing 'retry-safe' indicator the RetryLayer and
komira_objectstore branch on. RFC 7230 §6.3.1: this is exactly when
a client may retry a non-idempotent method safely (no bytes reached
the server-side application)."""

comptime HTTP_ERROR_EOF_MID_RESPONSE: UInt8 = 32
"""Peer closed cleanly DURING the response body — the body framing
(Content-Length or chunked) expected more bytes than arrived. The
response is incomplete; NOT retry-safe."""

# --- Protocol / framing -----------------------------------------------------

comptime HTTP_ERROR_RESPONSE_FRAMING: UInt8 = 40
"""Content-Length / chunked disagreement (CL+TE both present —
smuggling defense per RFC 7230 §3.3.3), bad chunk-size hex, missing
chunk-terminator CRLF, two distinct CL values, etc. Surfaced from the
response parser."""

comptime HTTP_ERROR_STATUS_LINE_INVALID: UInt8 = 41
"""Malformed HTTP/1.1 status line: bad version literal, non-digit
status, missing reason phrase. The HTTP version is rejected."""

comptime HTTP_ERROR_HEADER_INVALID: UInt8 = 42
"""Malformed response header line: missing colon, obs-fold, invalid
field-name characters, control characters in value. Per RFC 7230
§3.2 — these MUST be rejected by a recipient."""

comptime HTTP_ERROR_HEADERS_TOO_LARGE: UInt8 = 43
"""Response headers exceeded `max_total_header_bytes` (defaults from
ParseLimits)."""

# --- HTTP/2 (reserved for) ---------------------------------------

comptime HTTP_ERROR_H2_PROTOCOL: UInt8 = 50
"""HTTP/2 protocol error: COMPRESSION_ERROR / FLOW_CONTROL_ERROR /
FRAME_SIZE_ERROR / etc. RESERVED — The client is H1-only, this kind
is for the H2 client."""

# --- Body -------------------------------------------------------------------

comptime HTTP_ERROR_BODY_TOO_LARGE: UInt8 = 60
"""Response body exceeded `max_body_bytes`. The parser/decoder
stopped accumulating; the partial body is discarded."""

# --- Control --------------------------------------------------------------

comptime HTTP_ERROR_PROTOCOL_STATUS: UInt8 = 70
"""A 4xx or 5xx final status was returned. The HttpError.status field
carries the status code. The response object is also surfaced
alongside the error (the consumer can read body / headers); this kind
fires when a Layer opts to surface non-2xx as a raise
rather than a successful return."""

comptime HTTP_ERROR_CANCELLED: UInt8 = 71
"""The caller cancelled the request via a CancellationToken before
the response completed. NOT a server-side error."""

comptime HTTP_ERROR_TIMEOUT: UInt8 = 72
"""A configured per-request timeout elapsed (read timeout, write
timeout, response timeout). Distinct from CONNECT_TIMEOUT which fires
during dial."""

comptime HTTP_ERROR_BODY_NOT_REPLAYABLE: UInt8 = 73
"""A retry was attempted but the request body conformer's
`replayable()` returned False (StreamingBody / consumed-body — the
producer state is gone). 'fail-loud' guidance, the retry
layer raises this typed error instead of silently sending an empty
or partial body. Caller's recourse: use a BytesBody for retry-eligible
requests, or accept the underlying error without retry."""

# --- Parse-time (request build) --------------------------------------------

comptime HTTP_ERROR_URL_INVALID: UInt8 = 80
"""URL parse failed: missing scheme, unsupported scheme, malformed
authority, port out of range. Surfaced from Url.parse(), not from a
network round-trip."""

comptime HTTP_ERROR_RANGE_NOT_HONORED: UInt8 = 81
"""Client sent a `Range:` header in get_range
but the server returned `200 OK` (full body) instead of `206 Partial
Content`. The server is RFC 7233 §3.1 within its rights to ignore
Range, but if the caller wanted a partial body, this is an actionable
error — the full body is much larger than expected, and the caller
should adjust their semantics. The HttpError.status field carries the
returned HTTP status (typically 200)."""


# =============================================================================
# §2 — HttpError struct.
# =============================================================================


struct HttpError(Movable, Deinitable):
    """Typed HTTP client error.

    Movable, NOT Copyable — the `detail` String is owned and we don't
    want callers silently cloning it.

    Fields:
      kind    — UInt8 sentinel (HTTP_ERROR_*); the load-bearing
                discriminator the consumer branches on.
      detail  — Actionable, fail-fast message. ASCII only; sanitized via
                `sanitize_for_log()` if it incorporates anything
                client/server-derived. NEVER contains raw header values
                or response bytes verbatim.
      status  — Auxiliary integer. Semantics depend on `kind`:
                  IO_ERROR              -> errno value
                  PROTOCOL_STATUS       -> HTTP status code (4xx/5xx)
                  RESPONSE_FRAMING      -> 0 or the offset where the
                                           framing inconsistency was
                                           detected
                  others                -> 0
    """

    var kind: UInt8
    var detail: String
    var status: Int32

    def __init__(out self):
        self.kind = HTTP_ERROR_NONE
        self.detail = String()
        self.status = Int32(0)

    def __init__(out self, kind: UInt8, var detail: String):
        self.kind = kind
        self.detail = detail^
        self.status = Int32(0)

    def __init__(out self, kind: UInt8, var detail: String, status: Int32):
        self.kind = kind
        self.detail = detail^
        self.status = status

    @staticmethod
    def none() -> HttpError:
        """The no-error sentinel. Used by callers that pre-allocate an
        HttpError slot."""
        return HttpError()

    @staticmethod
    def connect_failed(var detail: String) -> HttpError:
        return HttpError(kind=HTTP_ERROR_CONNECT_FAILED, detail=detail^)

    @staticmethod
    def connect_timeout() -> HttpError:
        return HttpError(
            kind=HTTP_ERROR_CONNECT_TIMEOUT,
            detail=String("connect timeout"),
        )

    @staticmethod
    def io_error(errno: Int32) -> HttpError:
        return HttpError(
            kind=HTTP_ERROR_IO_ERROR,
            detail=String("io error"),
            status=errno,
        )

    @staticmethod
    def retryable_transport(var detail: String) -> HttpError:
        return HttpError(
            kind=HTTP_ERROR_RETRYABLE_TRANSPORT, detail=detail^,
        )

    @staticmethod
    def eof_mid_response() -> HttpError:
        return HttpError(
            kind=HTTP_ERROR_EOF_MID_RESPONSE,
            detail=String("peer closed during response body"),
        )

    @staticmethod
    def response_framing(var detail: String) -> HttpError:
        return HttpError(kind=HTTP_ERROR_RESPONSE_FRAMING, detail=detail^)

    @staticmethod
    def status_line_invalid(var detail: String) -> HttpError:
        return HttpError(
            kind=HTTP_ERROR_STATUS_LINE_INVALID, detail=detail^,
        )

    @staticmethod
    def header_invalid(var detail: String) -> HttpError:
        return HttpError(kind=HTTP_ERROR_HEADER_INVALID, detail=detail^)

    @staticmethod
    def headers_too_large() -> HttpError:
        return HttpError(
            kind=HTTP_ERROR_HEADERS_TOO_LARGE,
            detail=String("response headers exceed configured limit"),
        )

    @staticmethod
    def body_too_large() -> HttpError:
        return HttpError(
            kind=HTTP_ERROR_BODY_TOO_LARGE,
            detail=String("response body exceeds configured limit"),
        )

    @staticmethod
    def protocol_status(status: Int32) -> HttpError:
        return HttpError(
            kind=HTTP_ERROR_PROTOCOL_STATUS,
            detail=String("non-2xx response"),
            status=status,
        )

    @staticmethod
    def cancelled() -> HttpError:
        return HttpError(
            kind=HTTP_ERROR_CANCELLED,
            detail=String("request cancelled"),
        )

    @staticmethod
    def timeout() -> HttpError:
        return HttpError(
            kind=HTTP_ERROR_TIMEOUT,
            detail=String("request timed out"),
        )

    @staticmethod
    def url_invalid(var detail: String) -> HttpError:
        return HttpError(kind=HTTP_ERROR_URL_INVALID, detail=detail^)

    @staticmethod
    def range_not_honored(status: Int32) -> HttpError:
        return HttpError(
            kind=HTTP_ERROR_RANGE_NOT_HONORED,
            detail=String("server returned non-206 to Range request"),
            status=status,
        )

    @always_inline
    def is_ok(self) -> Bool:
        """True iff the error is the no-error sentinel."""
        return self.kind == HTTP_ERROR_NONE

    @always_inline
    def is_retryable_transport(self) -> Bool:
        """True iff the consumer's RetryLayer should retry this request
        on a fresh connection. RFC 7230 §6.3.1 compliance."""
        return self.kind == HTTP_ERROR_RETRYABLE_TRANSPORT

    @always_inline
    def is_protocol_status(self) -> Bool:
        """True iff this represents a 4xx/5xx final status. The
        `status` field carries the code."""
        return self.kind == HTTP_ERROR_PROTOCOL_STATUS

    def _write_kind_name[W: Writer](self, mut writer: W):
        """WRITE what `kind_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

        The arms live here so no string constant is ever SELECTED and
        returned. A literal-returning ladder lowers to two parallel
        (pointer, length) constant arrays whose two call-site references
        an `--emit shared-lib` link binds INDEPENDENTLY, and a pair bound
        CROSSED takes the process down with it."""
        var k = self.kind
        if k == HTTP_ERROR_NONE:
            writer.write(String("NONE"))
            return
        if k == HTTP_ERROR_CONNECT_FAILED:
            writer.write(String("CONNECT_FAILED"))
            return
        if k == HTTP_ERROR_CONNECT_TIMEOUT:
            writer.write(String("CONNECT_TIMEOUT"))
            return
        if k == HTTP_ERROR_TLS_VERIFY_FAILED:
            writer.write(String("TLS_VERIFY_FAILED"))
            return
        if k == HTTP_ERROR_TLS_HANDSHAKE_FAILED:
            writer.write(String("TLS_HANDSHAKE_FAILED"))
            return
        if k == HTTP_ERROR_IO_ERROR:
            writer.write(String("IO_ERROR"))
            return
        if k == HTTP_ERROR_RETRYABLE_TRANSPORT:
            writer.write(String("RETRYABLE_TRANSPORT"))
            return
        if k == HTTP_ERROR_EOF_MID_RESPONSE:
            writer.write(String("EOF_MID_RESPONSE"))
            return
        if k == HTTP_ERROR_RESPONSE_FRAMING:
            writer.write(String("RESPONSE_FRAMING"))
            return
        if k == HTTP_ERROR_STATUS_LINE_INVALID:
            writer.write(String("STATUS_LINE_INVALID"))
            return
        if k == HTTP_ERROR_HEADER_INVALID:
            writer.write(String("HEADER_INVALID"))
            return
        if k == HTTP_ERROR_HEADERS_TOO_LARGE:
            writer.write(String("HEADERS_TOO_LARGE"))
            return
        if k == HTTP_ERROR_H2_PROTOCOL:
            writer.write(String("H2_PROTOCOL"))
            return
        if k == HTTP_ERROR_BODY_TOO_LARGE:
            writer.write(String("BODY_TOO_LARGE"))
            return
        if k == HTTP_ERROR_PROTOCOL_STATUS:
            writer.write(String("PROTOCOL_STATUS"))
            return
        if k == HTTP_ERROR_CANCELLED:
            writer.write(String("CANCELLED"))
            return
        if k == HTTP_ERROR_TIMEOUT:
            writer.write(String("TIMEOUT"))
            return
        if k == HTTP_ERROR_URL_INVALID:
            writer.write(String("URL_INVALID"))
            return
        if k == HTTP_ERROR_RANGE_NOT_HONORED:
            writer.write(String("RANGE_NOT_HONORED"))
            return
        writer.write(String("UNKNOWN"))
        return

    def kind_name(self) -> String:
        """Symbolic name for the kind sentinel. For log lines + test
        assertions. Returns 'UNKNOWN' for any unrecognized code (a code
        we haven't documented here)."""
        var out = String()
        self._write_kind_name(out)
        return out^
