# =============================================================================
# src/komira_http_client/request_writer.mojo — HTTP/1.1 request serializer
# =============================================================================
#
# outbound state machine
# WritingRequestHeaders + WritingRequestBody. Serializes a request into
# an owned `List[UInt8]` buffer that the state machine drains to the
# wire via `IoStream.try_write`.
#
# Two-phase serialization:
#   * `serialize_request_head(method, url, headers, content_length, ..., out)`
#       Writes the request-line + headers + terminating CRLFCRLF.
#       Caller has computed content_length (-1 = chunked); we inject
#       Content-Length OR Transfer-Encoding accordingly. The default
#       Host: header is injected if the caller did NOT set one.
#       Connection: close handling is the caller's responsibility (this
#       client opens one connection per request — see client.send).
#   * Body bytes are drained by the state machine via `RequestBody.read_chunk`
#       and appended to the same buffer (or written directly to the
#       wire). This module's responsibility ends at the CRLFCRLF.
#
# NEVER include
# client-controlled bytes verbatim in error messages or in fields that
# could surface to logs without sanitization. The values we emit on the
# wire are caller-controlled by design (HTTP request bodies) — that's
# different from the server's "never echo client input in errors"
# discipline.
#
# Pointer discipline:
#   * ZERO UnsafePointer in any signature.
#   * ZERO wildcard origins.
#   * ZERO `unsafe_from_address`.
#   * Output is a `mut out: List[UInt8]` — owned-buffer append.
# =============================================================================


from komira_http_client.body import RequestBody
from komira_http_client.header_map import HeaderBytes, HeaderEntry, HeaderMap
from komira_http_client.url import Url
from komira_http_core.codec.types import (
    HTTP_METHOD_DELETE,
    HTTP_METHOD_GET,
    HTTP_METHOD_HEAD,
    HTTP_METHOD_OPTIONS,
    HTTP_METHOD_PATCH,
    HTTP_METHOD_POST,
    HTTP_METHOD_PUT,
    HttpMethod,
)


# =============================================================================
# §1 — Internal append helpers (byte-by-byte writes into the output buffer).
# =============================================================================


@always_inline
def _append_byte(mut out: List[UInt8], b: UInt8):
    out.append(b)


def _append_str(mut out: List[UInt8], s: String):
    var bytes_ref = s.as_bytes()
    var n = len(bytes_ref)
    var i = 0
    while i < n:
        out.append(bytes_ref[i])
        i = i + 1


def _append_sab(mut out: List[UInt8], hb: HeaderBytes):
    """Append a HeaderBytes's bytes directly to the output buffer — no
    String materialization.3.F.2b: was `sab: SharedAlignedBuffer[64]`;
    flipped to `hb: HeaderBytes` (refcounted byte-view) — the underlying
    primitive changed but the loop body is identical (unsafe_get(i)
    bytes-out)."""
    var n = hb.length
    var i = 0
    while i < n:
        out.append(hb.unsafe_get(i))
        i = i + 1


def _append_sab_lower(mut out: List[UInt8], hb: HeaderBytes):
    """Append a HeaderBytes's bytes lower-cased directly to the output
    buffer — no String materialization. Used for HEADER NAMES (HeaderMap
    stores them in wire-form casing but HTTP/1.1 emission is the lowercase
    canonical)."""
    var n = hb.length
    var i = 0
    while i < n:
        var b = hb.unsafe_get(i)
        var c = Int(b)
        # ASCII A-Z -> a-z.
        if c >= Int(ord("A")) and c <= Int(ord("Z")):
            out.append(UInt8(c + 32))
        else:
            out.append(b)
        i = i + 1


def _append_crlf(mut out: List[UInt8]):
    out.append(UInt8(0x0D))
    out.append(UInt8(0x0A))


# =============================================================================
# §2 — Public entry: serialize_request_head.
# =============================================================================


def serialize_request_head(
    method: HttpMethod,
    url: Url,
    headers: HeaderMap,
    content_length: Int,
    mut out: List[UInt8],
):
    """Serialize the request-line + headers block into `out`.

    Format per RFC 7230 §3:
      Request-Line: <method> SP <request-target> SP HTTP/1.1 CRLF
      *( header-field CRLF )
      CRLF

    Semantics:
      * The request-target is the URL's origin-form (`url.request_target()`
        = path + "?" + query). Absolute-form is rejected (CONNECT proxy
        is out of scope here).
      * If `headers` does NOT contain `host`, one is injected from
        `url.authority()`.
      * If `headers` does NOT contain `user-agent`, one is injected with
        a default identifier.
      * If `content_length >= 0` and no Content-Length header set, one
        is injected. If `content_length < 0`, a Transfer-Encoding: chunked
        header is injected (caller is responsible for chunked-encoding
        the body bytes that follow — scope).
      * Existing `host` / `content-length` / `transfer-encoding` headers
        in the map override the injected defaults.

    `headers` is consumed by REFERENCE only — caller retains ownership.
    Output is appended; the caller is responsible for pre-clearing
    `out` if it wants a clean buffer.
    """
    # ----- Request line -----
    _append_str(out, method.name())
    _append_byte(out, UInt8(0x20))  # SP
    _append_str(out, url.request_target())
    _append_byte(out, UInt8(0x20))  # SP
    _append_str(out, String("HTTP/1.1"))
    _append_crlf(out)

    # ----- Default-header injection -----
    # Track which defaults have been overridden by the caller.
    # Option C migration: `contains_static` accepts a StaticString
    # (zero per-call alloc for the lookup name) — 4× per request.
    var has_host = headers.contains_static("host")
    var has_user_agent = headers.contains_static("user-agent")
    var has_content_length = headers.contains_static("content-length")
    var has_transfer_encoding = headers.contains_static("transfer-encoding")

    if not has_host:
        _append_str(out, String("Host: "))
        _append_str(out, url.authority())
        _append_crlf(out)
    if not has_user_agent:
        _append_str(out, String("User-Agent: komira-http/1.0"))
        _append_crlf(out)
    # Framing: prefer caller-set CL/TE; otherwise inject based on
    # `content_length`. content_length >= 0 -> CL; -1 -> chunked TE.
    if not has_content_length and not has_transfer_encoding:
        if content_length >= 0:
            _append_str(out, String("Content-Length: "))
            _append_str(out, String(content_length))
            _append_crlf(out)
        else:
            _append_str(out, String("Transfer-Encoding: chunked"))
            _append_crlf(out)

    # ----- Caller-provided headers -----
    # Emit in insertion order. Names are written in their canonicalized
    # lowercase form (HeaderMap stores them lowercase). HTTP/1.1 wire
    # format is case-insensitive, so lowercase emission is wire-correct
    # — and matches what nginx + Go's http.Header.Write do.
    #
    # Option C migration: walk SAB views directly via
    # `len()` + `entry_at_view(i)`, append bytes via `_append_sab`.
    # Saves N × (name-String + value-String) allocations per request,
    # where N is the user-attached header count.
    var n_entries = headers.len()
    var i = 0
    while i < n_entries:
        var entry_view = headers.entry_at_view(i)
        # Names emit lowercase (HTTP/1.1 wire is case-insensitive; nginx
        # + Go's net/http canonicalize to the same form). Values are
        # emitted verbatim — caller-controlled bytes preserved.
        _append_sab_lower(out, entry_view.name)
        _append_str(out, String(": "))
        _append_sab(out, entry_view.value)
        _append_crlf(out)
        i = i + 1

    # ----- Terminator CRLF -----
    _append_crlf(out)


# =============================================================================
# §3 — Public entry: drain_body_into.
# =============================================================================


def drain_body_into[B: RequestBody](
    mut body: B,
    mut out: List[UInt8],
) -> Int:
    """Drain the entire body conformer into `out`. Returns the number of
    bytes drained.

    For an EmptyBody this is a no-op (returns 0). For BytesBody, this
    appends all buffer bytes in chunks (typically one chunk if dst is
    sized adequately). The state machine drives this for fully-buffered
    bodies; streaming bodies are drained chunk-at-a-time directly
    to the wire instead of into `out`.

    NOTE: this is the simplest path — fully buffer the body before
    sending. introduces the streaming-write path where Body chunks
    are written directly to IoStream.try_write without first being
    buffered.
    """
    var scratch = List[UInt8]()
    # Use a 64 KiB scratch buffer.
    var SCRATCH_SIZE: Int = 65536
    var i = 0
    while i < SCRATCH_SIZE:
        scratch.append(UInt8(0))
        i = i + 1

    var total: Int = 0
    while True:
        var n = body.read_chunk(Span[UInt8](scratch))
        if n == 0:
            break
        var k = 0
        while k < n:
            out.append(scratch[k])
            k = k + 1
        total = total + n
    return total


# =============================================================================
# §4 — Method shortcuts (for tests and ergonomic API).
# =============================================================================


@always_inline
def method_get() -> HttpMethod:
    return HttpMethod.get()


@always_inline
def method_head() -> HttpMethod:
    return HttpMethod.head()


@always_inline
def method_post() -> HttpMethod:
    return HttpMethod.post()


@always_inline
def method_put() -> HttpMethod:
    return HttpMethod.put()


@always_inline
def method_delete() -> HttpMethod:
    return HttpMethod.delete()


@always_inline
def method_patch() -> HttpMethod:
    return HttpMethod.patch()


@always_inline
def method_options() -> HttpMethod:
    return HttpMethod.options()
