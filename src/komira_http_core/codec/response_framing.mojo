# =============================================================================
# src/komira_http_core/codec/response_framing.mojo
#   — WHO decides a response may be chunked, and the emitter that obeys.
# =============================================================================
#
# ★ THE SEAM, IN ONE SENTENCE: **the handler ASKS for chunked framing
# (`HttpResponse.mark_chunked()`), the TRANSPORT decides whether it may have it
# (`response_may_be_chunked`), and this module's emitter obeys the decision.**
#
# WHY THE DECISION CANNOT LIVE WITH THE HANDLER. `Transfer-Encoding` is legal
# only towards an HTTP/1.1-or-later client (RFC 9112 §7.1: *"A server MUST NOT
# send a response containing Transfer-Encoding unless the corresponding request
# indicates HTTP/1.1"*), only on a response that may carry a body, and never
# towards a HEAD request. A `RequestDispatcher` conformer sees none of those
# three facts — `HttpRequest` carries no version, and the dispatcher has already
# answered by the time the round knows what it is answering. The transport round
# holds all three (`outcome.http_version_minor`, `req.method`, `response.status`)
# and is the only layer that does. Putting the gate anywhere else would make
# every handler responsible for a protocol rule it cannot see.
#
# WHY THE DOWNGRADE IS FREE. The body is a whole `List[UInt8]` at the moment the
# decision is taken, so "downgrade to content-length" is `len(body)` and nothing
# else. This is the property that makes a FRAMING seam so much smaller than a
# STREAMING seam: a producer could not be downgraded without buffering it, which
# is the thing a producer exists to avoid.
#
# ⚠⚠ WHAT THIS BUYS. The wire framing that Cloud Run's response-size escape
# clause names ("32 MiB **if not using `Transfer-Encoding: chunked` or streaming
# mechanisms**", https://docs.cloud.google.com/run/quotas). It does NOT reduce
# peak resident memory by one byte — see the header of
# `codec/h1/chunked_encode.mojo`.
#
# ⛔ AND IT DOES NOT MAKE A LARGE RESPONSE SAFE, ONLY LEGAL. A chunked response
# is cut mid-body at the platform's REQUEST TIMEOUT and the client can see
# **HTTP 200 with a well-formed terminating chunk**. **The real ceiling is
# `bytes / bandwidth < timeout`, not 32 MiB**, and no HTTP-level signal
# distinguishes a truncated response from a complete one. ⇒ Any caller emitting
# a large chunked body must carry its OWN end-to-end completeness check;
# `git-upload-pack` is safe only because a packfile carries a trailing checksum.
#
# ⚠ COUPLING: **this escape hatch can CLOSE when a service is put behind an API
# gateway.** API Gateway's own limits are 32 MB per request AND per response
# with *"Streaming is not supported"*
# (https://docs.cloud.google.com/api-gateway/docs/quotas), whatever the framing
# of the backend hop. That needs NO code change at all, so a deployment that
# fronts a chunking service with a gateway must check for it.
#
# # Encapsulation discipline
#   * ZERO UnsafePointer; in/out are `HttpResponse` borrows, `List[UInt8]`,
#     `Span[UInt8]`, `Int`, `Bool`.
#   * ZERO wildcard origins, ZERO `unsafe_from_address`, ZERO FFI.
#   * No struct here, and `HttpResponse` is never byte-slab stored.
# =============================================================================

from komira_http_core.codec.h1.chunked_encode import append_chunked_body
from komira_http_core.codec.types import (
    HttpResponse,
    serialize_response_head,
)


def response_may_be_chunked(
    status: Int32,
    http_version_minor: Int8,
    is_head_request: Bool,
) -> Bool:
    """THE GATE. True iff a response with `status`, answering a request that
    arrived as `HTTP/1.<http_version_minor>` with method HEAD-ness
    `is_head_request`, may legally be framed with `Transfer-Encoding: chunked`.

    Three independent refusals, each of which corrupts the wire if skipped:

    1. **HTTP/1.0 clients cannot do chunked.** RFC 9112 §7.1 — *"A server MUST
       NOT send a response containing Transfer-Encoding unless the corresponding
       request indicates HTTP/1.1 (or later)."* A 1.0 client that receives
       chunked framing reads the hex size lines as body content and silently
       corrupts the payload; there is no error anywhere. (Our parser records the
       version at `codec/h1/parser.mojo` -> `HeadersParseOutcome.
       http_version_minor`; HTTP/0.9 is already rejected and 2.0+ is already
       unsupported, so the value is 0 or 1.)

    2. **A response to HEAD carries no body.** RFC 9112 §6.3 — the framing
       headers describe *what would have been sent*, and no body follows. Emit a
       chunked body (even the bare `0\\r\\n\\r\\n` terminator) and those five
       bytes become the head of the NEXT response on a keep-alive connection.

    3. **1xx / 204 / 304 cannot carry a body at all** (RFC 9112 §6.3 items 1-2),
       for the same reason: the terminator would be read as the next message.

    ★ Measured, and the reason the gate is worth having rather than assuming:
    stock `git 2.51.0` sends `HTTP/1.1` request lines on both the `GET
    /info/refs` advertisement and the `POST /git-upload-pack` fetch, and clones
    successfully when BOTH responses are chunked (881 KiB pack, `git fsck`
    clean, byte-identical worktree). So the git path always passes this gate —
    but a `curl --http1.0`, a HEAD probe, or a 304 on a conditional GET does
    not, and every one of those shares the same emitter.
    """
    if http_version_minor < Int8(1):
        return False
    if is_head_request:
        return False
    var s = Int(status)
    if s < 200:
        return False  # 1xx — informational, no body.
    if s == 204 or s == 304:
        return False
    return True


def serialize_response_framed(
    response: HttpResponse,
    client_allows_chunked: Bool,
    mut out: List[UInt8],
):
    """Serialize `response` to wire bytes, honouring its requested body framing
    ONLY IF `client_allows_chunked` (which the caller obtains from
    `response_may_be_chunked`).

    Exactly one framing header is emitted, always:
      * chunked  — `transfer-encoding: chunked`, any `content-length` dropped,
        body re-framed as `<hex>CRLF<data>CRLF ... 0CRLFCRLF`.
      * otherwise — the caller's headers verbatim, plus an injected
        `content-length` if the response had asked for chunked (and so had its
        own content-length removed by `mark_chunked`).

    A response that never called `mark_chunked` is emitted BYTE-IDENTICALLY to
    `serialize_response`, regardless of `client_allows_chunked`. That is what
    makes this safe to install on a shared serve round: opting in is the only
    way to change any byte on the wire.
    """
    var use_chunked = client_allows_chunked and response.wants_chunked()
    serialize_response_head(response, use_chunked, out)
    if use_chunked:
        append_chunked_body(out, Span[UInt8](response.body))
    else:
        var k = 0
        while k < len(response.body):
            out.append(response.body[k])
            k = k + 1
