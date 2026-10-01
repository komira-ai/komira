# =============================================================================
# src/komira_http/tests/test_recv_ring_chunked_error_kinds.mojo
# =============================================================================
# ⛔ THE ERROR FRAME MUST NAME WHICH FRAMING TOKEN WAS MALFORMED.
#
# Companion to `test_recv_ring_chunked_split_inside_framing.mojo`, which pins
# that a decoder in _DECODE_STATE_ERROR surfaces an Error frame AT ALL (the
# ~300s half of the chunked-truncation failure: with the outcome of
# `decode_block` discarded, a parse failure is reported minutes later
# as "EOF_MID_RESPONSE: chunked body unterminated" — truncation, over what was
# really a parse failure). That test asserts `is_error()` for ONE shape, a
# malformed chunk-size line.
#
# ⚠ `is_error()` IS NOT ENOUGH, AND THAT IS THIS FILE'S WHOLE SUBJECT. An
# UNINFORMATIVE log line costs days: every chunked failure, whatever its
# cause, arrives as the same sentence. A single
# Error-frame assertion re-creates that: three genuinely different defects —
# a size line that is not hex, chunk data not followed by its CRLF, a trailer
# line with no colon — would all satisfy it while still being
# indistinguishable to whoever reads the log.
#
# `decode_block` already discriminates them (PARSE_ERR_CHUNK_SIZE_INVALID /
# _CHUNK_MISSING_CRLF / _CHUNK_TRAILER_INVALID, codec/h1/limits.mojo), and
# `RecvRingBody._chunked_error_detail` already renders the kind. Nothing
# asserted that the right kind reaches the frame, so a caller that pinned the
# wrong error, or a renderer that lost the kind, was free to.
#
# Each case asserts the SPECIFIC kind AND — via `_kinds_are_distinct` — that
# the three do not collapse onto one value, which is the property a reader of
# the log actually depends on.
#
# No UnsafePointer crosses a boundary here; no wildcard origin.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_not_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http.client.response_body import RecvRingBody
from komira_http.codec.h1.limits import (
    PARSE_ERR_CHUNK_MISSING_CRLF,
    PARSE_ERR_CHUNK_SIZE_INVALID,
    PARSE_ERR_CHUNK_TRAILER_INVALID,
)
from komira_http.transport.scripted import ScriptedStream


def _make_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        out.append(b[i])
        i = i + 1
    return out^


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


def _drain_detail(wire: String) raises -> String:
    """Drive a chunked RecvRingBody over `wire` to its terminal frame.
    Returns "" on a clean End, else the Error frame's detail string.

    Data frames are DISCARDED on purpose: a decoder can legitimately emit
    bytes it had already decoded before the malformed token (the
    `5\\r\\nhello` case does), and the subject here is the detail that
    arrives after them."""
    var stream = ScriptedStream.from_read_script(_make_bytes(wire))
    var body = RecvRingBody[ScriptedStream].new_chunked(
        stream^, pre_body_bytes=List[UInt8](), max_body_bytes=1024 * 1024,
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var iter = 0
    while True:
        iter = iter + 1
        if iter > 100000:
            return String("ITER_CAP")
        var f = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
        if f.is_end():
            return String("")
        if f.is_error():
            return f.error_detail()
        if f.is_data():
            var _chunk = f.take_data_chunk()
    return String("")


def _kind_token(kind: UInt8) -> String:
    """The substring `_chunked_error_detail` renders for a parse-error kind.
    Built from the codec's OWN constant rather than a literal, so renumbering
    PARSE_ERR_* moves the expectation with it instead of silently passing."""
    return String("kind=") + String(Int(kind))


# =============================================================================
# Case A — the chunk-SIZE line is not hexadecimal.
# =============================================================================


def test_bad_chunk_size_line_reports_chunk_size_invalid() raises:
    """`zz` is not 1*HEXDIG (RFC 7230 §4.1), so `_parse_chunk_size_line`
    returns -1 and the decoder latches PARSE_ERR_CHUNK_SIZE_INVALID."""
    var detail = _drain_detail(String("zz\r\nAAAA\r\n0\r\n\r\n"))
    assert_true(
        detail.find(_kind_token(PARSE_ERR_CHUNK_SIZE_INVALID)) >= 0,
        String("expected CHUNK_SIZE_INVALID kind in detail, got: ") + detail,
    )


# =============================================================================
# Case B — chunk DATA is not followed by its terminating CRLF.
# =============================================================================


def test_chunk_data_without_crlf_reports_missing_crlf() raises:
    """`chunk = chunk-size CRLF chunk-data CRLF`. Here the 5 data octets
    are followed by `XX`, so _DECODE_STATE_CHUNK_DATA_CRLF sees a non-CRLF
    and latches PARSE_ERR_CHUNK_MISSING_CRLF.

    ⚠ This shape emits Data BEFORE it errors — `hello` is already decoded
    and is correctly handed to the caller — so it is also the case that
    proves the error is surfaced on a LATER poll rather than being lost
    behind the emitted bytes."""
    var detail = _drain_detail(String("5\r\nhelloXX"))
    assert_true(
        detail.find(_kind_token(PARSE_ERR_CHUNK_MISSING_CRLF)) >= 0,
        String("expected CHUNK_MISSING_CRLF kind in detail, got: ") + detail,
    )


# =============================================================================
# Case C — a trailer line that is not a header-field.
# =============================================================================


def test_trailer_without_colon_reports_trailer_invalid() raises:
    """`trailer-part = *( header-field CRLF )` — a trailer line with no
    colon is not a header-field, and the decoder latches
    PARSE_ERR_CHUNK_TRAILER_INVALID.

    This is the LAST framing token of a chunked message, reached only
    after the 0-length chunk, so it is the shape most likely to be
    mis-reported as truncation: the body is complete, the payload is
    correct, and only the trailer is malformed."""
    var detail = _drain_detail(String("0\r\nnocolon\r\n\r\n"))
    assert_true(
        detail.find(_kind_token(PARSE_ERR_CHUNK_TRAILER_INVALID)) >= 0,
        String("expected CHUNK_TRAILER_INVALID kind in detail, got: ") + detail,
    )


# =============================================================================
# Case D — the three must not collapse onto one value.
# =============================================================================


def test_the_three_chunked_error_kinds_are_distinct() raises:
    """⛔ THE ANTI-COLLAPSE ASSERTION, and the one that encodes the actual
    point of the distinct kinds. Cases A-C above each pin one kind; a
    renderer that dropped the kind and emitted a constant string would fail
    them — but a codec change that merged two of these kinds into one would
    NOT, and the log would quietly go back to being uninformative in a way
    no single-case assertion notices.

    Asserted on the DETAILS the body actually produced, not on the
    constants, so it covers the whole path (decoder latch -> err.kind ->
    `_chunked_error_detail` render) rather than restating limits.mojo."""
    var d_size = _drain_detail(String("zz\r\nAAAA\r\n0\r\n\r\n"))
    var d_crlf = _drain_detail(String("5\r\nhelloXX"))
    var d_trail = _drain_detail(String("0\r\nnocolon\r\n\r\n"))
    assert_not_equal(d_size, d_crlf)
    assert_not_equal(d_crlf, d_trail)
    assert_not_equal(d_size, d_trail)


# =============================================================================
# Case E — ANTI-VACUITY. A well-formed body of the same SHAPE must succeed.
# =============================================================================


def test_wellformed_counterpart_of_each_error_case_succeeds() raises:
    """Without this, every assertion above is satisfiable by a decoder that
    reports a parse error for EVERY chunked body. Each wire here is the
    minimal well-formed correction of the case it mirrors."""
    assert_equal(_drain_detail(String("4\r\nAAAA\r\n0\r\n\r\n")), String(""))
    assert_equal(_drain_detail(String("5\r\nhello\r\n0\r\n\r\n")), String(""))
    assert_equal(
        _drain_detail(String("0\r\nX-Has: colon\r\n\r\n")), String(""),
    )


def main() raises:
    test_bad_chunk_size_line_reports_chunk_size_invalid()
    test_chunk_data_without_crlf_reports_missing_crlf()
    test_trailer_without_colon_reports_trailer_invalid()
    test_the_three_chunked_error_kinds_are_distinct()
    test_wellformed_counterpart_of_each_error_case_succeeds()
    print("PASS recv-ring chunked error-kind tests")
