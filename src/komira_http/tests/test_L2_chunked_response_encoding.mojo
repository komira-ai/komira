# =============================================================================
# tests/test_L2_chunked_response_encoding.mojo
# =============================================================================
#
# GATE for the chunked RESPONSE encoder — the lever that lifts the HTTP/1
# response size ceiling.
#
# ★ WHAT IS BROKEN WITHOUT IT. Cloud Run caps an HTTP/1 response at 32 MiB
# *"if not using `Transfer-Encoding: chunked` or streaming mechanisms"*
# (https://docs.cloud.google.com/run/quotas). With only `Content-Length`
# framing, a repo whose clone pack exceeds 32 MiB is UN-CLONABLE regardless of
# how small every commit in it is. That is not a size policy question; it is
# whether the product works.
#
# ⚠ WHAT THIS FILE DOES **NOT** PROVE — say it here so nobody cites it wrongly.
# It proves we EMIT the framing Google's escape clause names. It does NOT prove
# Google's frontend then relays an unbounded chunked response: that needs a
# >32 MiB chunked response served FROM a Cloud Run revision and cloned through,
# which is a live-deployment check, not a unit test. It also does NOT
# reduce resident memory by one byte — see `codec/h1/chunked_encode.mojo`.
#
# MEASURED, the client half: a clone
# through a server that emits BOTH the `info/refs` advertisement AND the
# `git-upload-pack` result as chunked succeeds — 881 KiB pack, `git fsck` clean,
# worktree byte-identical to the source. So no client-side compatibility risk.
#
# Hermetic: pure codec, no socket, no subprocess, no live git.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http.codec.h1.chunked import (
    CHUNKED_RES_DONE,
    ChunkedDecoder,
    decode_block,
)
from komira_http.codec.h1.chunked_encode import (
    append_chunk,
    append_chunk_size_line,
    append_chunked_body,
    append_last_chunk,
)
from komira_http.codec.h1.limits import ParseLimits
from komira_http.codec.response_framing import (
    response_may_be_chunked,
    serialize_response_framed,
)
from komira_http.codec.types import (
    HttpResponse,
    serialize_response,
)


# -----------------------------------------------------------------------------
# Helpers.
# -----------------------------------------------------------------------------


def _as_str(b: List[UInt8]) -> String:
    var out = String("")
    for i in range(len(b)):
        out += chr(Int(b[i]))
    return out^


def _contains(hay: String, needle: String) -> Bool:
    return hay.find(needle) >= 0


def _head_of(wire: List[UInt8]) raises -> String:
    """The header section (through the blank line), as a String."""
    var n = len(wire)
    var i = 0
    while i + 3 < n:
        if (
            wire[i] == UInt8(0x0D)
            and wire[i + 1] == UInt8(0x0A)
            and wire[i + 2] == UInt8(0x0D)
            and wire[i + 3] == UInt8(0x0A)
        ):
            var head = List[UInt8]()
            for k in range(i + 4):
                head.append(wire[k])
            return _as_str(head)
        i = i + 1
    raise Error("no header terminator in serialized response")


def _body_offset(wire: List[UInt8]) raises -> Int:
    var n = len(wire)
    var i = 0
    while i + 3 < n:
        if (
            wire[i] == UInt8(0x0D)
            and wire[i + 1] == UInt8(0x0A)
            and wire[i + 2] == UInt8(0x0D)
            and wire[i + 3] == UInt8(0x0A)
        ):
            return i + 4
        i = i + 1
    raise Error("no header terminator in serialized response")


def _filled_body(n: Int) -> List[UInt8]:
    """`n` bytes with a position-dependent value, so a truncation or a
    reordering anywhere in the chunking is detectable, not just a length
    change."""
    var b = List[UInt8](capacity=n)
    for i in range(n):
        b.append(UInt8((i * 31 + (i >> 8)) & 0xFF))
    return b^


# =============================================================================
# GATE 1 — the encoder's framing, against the RFC 9112 §7.1 grammar.
# =============================================================================


def test_chunk_size_line_is_lowercase_hex_no_leading_zeros() raises:
    var out = List[UInt8]()
    append_chunk_size_line(out, 0)
    assert_equal(_as_str(out), String("0\r\n"))

    var out2 = List[UInt8]()
    append_chunk_size_line(out2, 255)
    assert_equal(_as_str(out2), String("ff\r\n"))

    var out3 = List[UInt8]()
    append_chunk_size_line(out3, 65536)
    assert_equal(_as_str(out3), String("10000\r\n"))

    # A 33 MiB single chunk — the size line a >32 MiB response would carry if it
    # were emitted in one piece. Proves the hex writer does not truncate above
    # 16 bits (the pkt-line writer next door is fixed at 4 hex digits, and
    # copying that shape here would silently mis-frame every large response).
    var out4 = List[UInt8]()
    append_chunk_size_line(out4, 34_603_008)
    assert_equal(_as_str(out4), String("2100000\r\n"))


def test_empty_chunk_is_a_noop_not_a_terminator() raises:
    """A zero-size chunk header IS the last-chunk marker. If `append_chunk`
    emitted one for empty data it would terminate the body early and every byte
    after it would be silently dropped — a short-but-well-formed response, the
    worst failure shape available. It must emit NOTHING."""
    var out = List[UInt8]()
    var empty = List[UInt8]()
    append_chunk(out, Span[UInt8](empty))
    assert_equal(len(out), 0)


def test_empty_body_is_the_bare_terminator() raises:
    var out = List[UInt8]()
    var empty = List[UInt8]()
    append_chunked_body(out, Span[UInt8](empty))
    assert_equal(_as_str(out), String("0\r\n\r\n"))


def test_chunked_body_round_trips_through_our_own_decoder() raises:
    """Encode with the new encoder, decode with the EXISTING RFC 7230 decoder
    (`codec/h1/chunked.mojo`, which has been in the tree since and is what
    reads `git push` bodies). Byte equality both ways is the strongest available
    self-check short of a live client."""
    var body = _filled_body(200_000)  # spans 4 chunks at the 64 KiB default
    var wire = List[UInt8]()
    append_chunked_body(wire, Span[UInt8](body))

    var dec = ChunkedDecoder.init()
    var decoded = List[UInt8]()
    var limits = ParseLimits.defaults()
    var res = decode_block(dec, Span[UInt8](wire), limits, decoded)
    assert_equal(Int(res.outcome), Int(CHUNKED_RES_DONE))
    assert_equal(res.consumed, len(wire))
    assert_equal(len(decoded), len(body))
    for i in range(len(body)):
        assert_equal(decoded[i], body[i])


def test_chunk_boundary_is_honoured() raises:
    """A body of exactly 2.5 chunks must produce sizes 8, 8, 4 at an 8-byte
    chunk size — i.e. the last chunk is short, not padded, and no chunk is
    empty."""
    var body = _filled_body(20)
    var wire = List[UInt8]()
    append_chunked_body(wire, Span[UInt8](body), 8)
    assert_true(
        _contains(_as_str(wire), String("8\r\n")),
        String("expected an 8-byte chunk header"),
    )
    assert_true(
        _contains(_as_str(wire), String("4\r\n")),
        String("expected a 4-byte final chunk header"),
    )
    # Terminator present, and exactly once at the end.
    var tail = List[UInt8]()
    for i in range(len(wire) - 5, len(wire)):
        tail.append(wire[i])
    assert_equal(_as_str(tail), String("0\r\n\r\n"))


# =============================================================================
# GATE 2 — ★ THE HEADLINE: a >32 MiB response is emitted CHUNKED with NO
#          `content-length`. This is the assertion the clone ceiling turns on.
# =============================================================================


def test_response_over_32mib_is_chunked_with_no_content_length() raises:
    """34 MiB — deliberately ABOVE Cloud Run's 32 MiB HTTP/1 response cap, which
    is the exact size class that could not be served before this landed.

    Asserts three things that must ALL hold, because any one of them alone is
    satisfiable by a broken emitter:
      1. `transfer-encoding: chunked` is present — the literal condition
         Google's escape clause names.
      2. `content-length` is ABSENT. Both together is forbidden by RFC 9112 §6.2
         and is the request-smuggling shape; an intermediary that sees both may
         reject the message or, worse, mis-frame the connection.
      3. The body is really re-framed (ends with the terminator and is LONGER
         than the payload by the framing overhead) — not merely relabelled.
    """
    var n = 34 * 1024 * 1024
    var r = HttpResponse(status=Int32(200))
    r.headers[String("content-type")] = String(
        "application/x-git-upload-pack-result"
    )
    r.headers[String("content-length")] = String(n)  # set, then superseded
    r.body = _filled_body(n)
    r.mark_chunked()

    # `mark_chunked` must itself have removed the content-length, so the two can
    # never be left inconsistent by statement ordering at the call site.
    assert_false(
        Bool(r.headers.find(String("content-length"))),
        String("mark_chunked must delete content-length"),
    )

    var wire = List[UInt8]()
    serialize_response_framed(r, True, wire)
    var head = _head_of(wire)
    assert_true(
        _contains(head, String("transfer-encoding: chunked")),
        String("expected chunked framing, got head: ") + head,
    )
    assert_false(
        _contains(head, String("content-length")),
        String("content-length must not appear with transfer-encoding: ") + head,
    )

    var body_off = _body_offset(wire)
    var framed_len = len(wire) - body_off
    assert_true(
        framed_len > n,
        String("chunk framing must add bytes, got ") + String(framed_len),
    )
    # Terminator at the very end.
    var tail = List[UInt8]()
    for i in range(len(wire) - 5, len(wire)):
        tail.append(wire[i])
    assert_equal(tail[0], UInt8(48))  # '0'
    assert_equal(tail[1], UInt8(0x0D))
    assert_equal(tail[2], UInt8(0x0A))
    assert_equal(tail[3], UInt8(0x0D))
    assert_equal(tail[4], UInt8(0x0A))


# =============================================================================
# GATE 3 — the GATE. Who may NOT receive chunked framing.
# =============================================================================


def test_http10_client_never_receives_chunked() raises:
    """RFC 9112 §7.1: *"A server MUST NOT send a response containing
    Transfer-Encoding unless the corresponding request indicates HTTP/1.1."* An
    HTTP/1.0 client reads the hex size lines as body content and silently
    corrupts the payload — there is no error anywhere, which is why this must be
    a gate and not a convention."""
    assert_false(response_may_be_chunked(Int32(200), Int8(0), False))
    assert_true(response_may_be_chunked(Int32(200), Int8(1), False))


def test_head_request_never_receives_chunked() raises:
    """A response to HEAD carries no body (RFC 9112 §6.3). Even the bare
    `0\\r\\n\\r\\n` terminator would be read as the head of the NEXT response on
    a keep-alive connection."""
    assert_false(response_may_be_chunked(Int32(200), Int8(1), True))


def test_bodiless_statuses_never_receive_chunked() raises:
    assert_false(response_may_be_chunked(Int32(100), Int8(1), False))
    assert_false(response_may_be_chunked(Int32(204), Int8(1), False))
    assert_false(response_may_be_chunked(Int32(304), Int8(1), False))
    assert_true(response_may_be_chunked(Int32(404), Int8(1), False))


def test_refused_chunked_downgrades_to_content_length_not_to_nothing() raises:
    """★ THE FAILURE THIS FORECLOSES. `mark_chunked()` DELETES the response's
    content-length. If the gate then refuses chunked and the emitter merely
    "didn't chunk", the message would go out with NO framing header at all —
    legal only under connection-close delimiting, which kills keep-alive and
    mis-frames the next response on a pipelined connection. The downgrade must
    RE-DERIVE the length, which it can only do because the body is whole."""
    var r = HttpResponse(status=Int32(200))
    r.body = _filled_body(1234)
    r.mark_chunked()

    var wire = List[UInt8]()
    serialize_response_framed(r, False, wire)  # gate said no
    var head = _head_of(wire)
    assert_true(
        _contains(head, String("content-length: 1234")),
        String("downgrade must re-derive content-length, got: ") + head,
    )
    assert_false(_contains(head, String("transfer-encoding")))
    # And the body is the RAW payload, not chunk-framed.
    assert_equal(len(wire) - _body_offset(wire), 1234)


def test_content_length_set_AFTER_mark_chunked_is_still_suppressed() raises:
    """★ THE ORDERING THIS FORECLOSES, AND WHY IT IS A SEPARATE TEST.

    There are TWO independent mechanisms keeping `content-length` and
    `transfer-encoding` from appearing together: `mark_chunked()` DELETES the
    header, and the EMITTER SUPPRESSES it. The headline >32 MiB test above sets
    content-length BEFORE `mark_chunked()`, so the deletion alone satisfies it —
    MEASURED by mutation: deleting the emitter's suppression left that test
    GREEN. `headers` is a public `Dict` and nothing stops a caller writing it
    after marking (a middleware `after` leg is the obvious way), so the emitter's
    suppression is the mechanism that actually holds on the wire, and this is the
    test that asserts it. Mutating the suppression must turn THIS red."""
    var r = HttpResponse(status=Int32(200))
    r.body = _filled_body(4096)
    r.mark_chunked()
    # A later writer — e.g. a middleware `after` leg — puts it back.
    r.headers[String("content-length")] = String(4096)

    var wire = List[UInt8]()
    serialize_response_framed(r, True, wire)
    var head = _head_of(wire)
    assert_true(_contains(head, String("transfer-encoding: chunked")))
    assert_false(
        _contains(head, String("content-length")),
        String(
            "emitter must suppress a content-length written AFTER"
            " mark_chunked; got head: "
        )
        + head,
    )


def test_legacy_serialize_response_never_chunks() raises:
    """`serialize_response` has no request context, so it can never satisfy the
    HTTP/1.0 gate. It must downgrade, exactly like a refused gate."""
    var r = HttpResponse(status=Int32(200))
    r.body = _filled_body(77)
    r.mark_chunked()
    var wire = List[UInt8]()
    serialize_response(r, wire)
    var head = _head_of(wire)
    assert_false(_contains(head, String("transfer-encoding")))
    assert_true(_contains(head, String("content-length: 77")))


# =============================================================================
# GATE 4 — ★ the no-regression gate: an unmarked response is BYTE-IDENTICAL.
# =============================================================================


def test_unmarked_response_is_byte_identical_through_both_emitters() raises:
    """Installing the framing gate on the shared serve round must change NOTHING
    for the ~140 existing `HttpResponse` construction sites. Opting in via
    `mark_chunked()` must be the ONLY way to move a byte. Asserted both ways
    (gate permitting AND refusing), because a gate that only agrees when it says
    no is not a proof."""
    var a = HttpResponse.ok(String("hello world"))
    var w_legacy = List[UInt8]()
    serialize_response(a, w_legacy)

    var b = HttpResponse.ok(String("hello world"))
    var w_allowed = List[UInt8]()
    serialize_response_framed(b, True, w_allowed)

    var c = HttpResponse.ok(String("hello world"))
    var w_refused = List[UInt8]()
    serialize_response_framed(c, False, w_refused)

    assert_equal(len(w_legacy), len(w_allowed))
    assert_equal(len(w_legacy), len(w_refused))
    for i in range(len(w_legacy)):
        assert_equal(w_legacy[i], w_allowed[i])
        assert_equal(w_legacy[i], w_refused[i])


def main() raises:
    test_chunk_size_line_is_lowercase_hex_no_leading_zeros()
    test_empty_chunk_is_a_noop_not_a_terminator()
    test_empty_body_is_the_bare_terminator()
    test_chunked_body_round_trips_through_our_own_decoder()
    test_chunk_boundary_is_honoured()
    test_response_over_32mib_is_chunked_with_no_content_length()
    test_http10_client_never_receives_chunked()
    test_head_request_never_receives_chunked()
    test_bodiless_statuses_never_receive_chunked()
    test_refused_chunked_downgrades_to_content_length_not_to_nothing()
    test_content_length_set_AFTER_mark_chunked_is_still_suppressed()
    test_legacy_serialize_response_never_chunks()
    test_unmarked_response_is_byte_identical_through_both_emitters()
    print("test_L2_chunked_response_encoding: OK")
