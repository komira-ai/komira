# =============================================================================
# test_L2_h2_hostile_frames.mojo -- the h2 server refuses a CONTINUATION flood
# and a content-length that wraps Int64
# =============================================================================
#
# Both sites are reached by any client before a request is dispatched.
#
# 1. CONTINUATION flood (the CVE-2024-27316 shape). HEADERS and CONTINUATION
#    are not flow-controlled (RFC 9113 §5.2.1: flow control is DATA-only), so
#    the receive window does not bound a header block. One HEADERS without
#    END_HEADERS followed by endless CONTINUATION grows the reassembly buffer
#    until the process dies, unless `_handle_headers_or_continuation` enforces
#    the H2ConnectionState ceilings (H2_MAX_HEADER_BLOCK_BYTES and
#    H2_MAX_HEADER_BLOCK_FRAMES). Refusal is observable as: the handler
#    returns False (close the connection), the buffer is dropped and a GOAWAY
#    with ENHANCE_YOUR_CALM is staged. The byte ceiling alone is not enough:
#    zero-length CONTINUATION frames add no bytes and are an unbounded
#    CPU flood, which only the frame-count ceiling closes. The HEADERS arm
#    has its own refusal: a single HEADERS whose fragment is over the byte
#    ceiling is refused before any CONTINUATION arrives.
# 2. `_parse_int_safe`, the h2 request content-length. Its value becomes
#    `StreamState.expected_content_length`, which decides the RFC 9113 §8.1.1
#    length-equality check and gates deferred dispatch. The overflow guard
#    must run before the multiply: after it, `18446744073709551621` (2^64 + 5)
#    wraps to 5 and `18446744073709551616` (2^64) to 0, both inside the
#    accepted range. Over-ceiling inputs such as 25 nines land in the band a
#    post-multiply guard rejects anyway, so they do not catch the defect.
#
# The h2 client's twin of (1) is pinned in komira_http_client's
# test_L2_h2_continuation_interleaving.mojo.
#
# It imports the private handler and parser on purpose, to drive each guard
# with a hand-built frame or string rather than through a socket.
#
# Defects it catches: `append_header_block`'s refusal ignored by the HEADERS
# or the CONTINUATION arm, a missing frame-count ceiling, a GOAWAY with the
# wrong code or none; `_parse_int_safe`'s pre-multiply guard removed or moved
# after the multiply, or its 2^62 ceiling tightened.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_http_core.codec.h2.connection_state import (
    H2_MAX_HEADER_BLOCK_BYTES,
    H2_MAX_HEADER_BLOCK_FRAMES,
    H2ConnectionState,
)
from komira_http_core.codec.h2.frame import (
    FRAME_CONTINUATION,
    FRAME_HEADERS,
    Frame,
    H2_ERR_ENHANCE_YOUR_CALM,
)
from komira_http_core.transport.grpc_emit import NoopGrpcDispatch
from komira_http_server.routing import Router
from komira_http_server.serve_h2 import _handle_headers_or_continuation
from komira_http_server.serve_h2_headers import _parse_int_safe


def _zeros(n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(UInt8(0))
    return out^


def _frame(kind: UInt8, stream_id: Int, var payload: List[UInt8]) -> Frame:
    """A decoded frame with no flags (so never END_HEADERS)."""
    var f = Frame()
    f.header.length = UInt32(len(payload))
    f.header.kind = kind
    f.header.flags = UInt8(0)
    f.header.stream_id = UInt32(stream_id)
    f.payload = payload^
    return f^


def _flood(continuation_len: Int, max_frames: Int) raises -> Tuple[Int, Bool, Int, Int]:
    """HEADERS (no END_HEADERS) on stream 1, then up to `max_frames`
    CONTINUATION frames of `continuation_len` bytes. Returns (the 1-based
    index of the CONTINUATION refused, or 0; GOAWAY staged; its code; bytes
    left in the reassembly buffer)."""
    var h2 = H2ConnectionState()
    h2.mark_preface_ok()
    var router = Router()
    var grpc = NoopGrpcDispatch()
    var reqs = Int64(0)
    var sent = Int64(0)
    var opened = _handle_headers_or_continuation(
        h2, _frame(FRAME_HEADERS, 1, _zeros(16)), router, grpc, reqs, sent
    )
    assert_true(opened, "the opening HEADERS must be accepted")
    var refused_at = 0
    for k in range(max_frames):
        if not _handle_headers_or_continuation(
            h2,
            _frame(FRAME_CONTINUATION, 1, _zeros(continuation_len)),
            router,
            grpc,
            reqs,
            sent,
        ):
            refused_at = k + 1
            break
    return (
        refused_at,
        h2.is_goaway_sent(),
        Int(h2.goaway_error_code),
        len(h2.cont_reasm_buf),
    )


# -----------------------------------------------------------------------------
# 1. CONTINUATION flood
# -----------------------------------------------------------------------------


def test_continuation_byte_flood_is_refused() raises:
    """16 KiB CONTINUATIONs trip the byte ceiling: 16 + 4 * 16384 > 64 KiB on
    the fourth."""
    var r = _flood(16384, 64)
    var expect = H2_MAX_HEADER_BLOCK_BYTES // 16384  # the first one over
    assert_equal(r[0], expect, "refused at the wrong CONTINUATION")
    assert_true(r[1], "no GOAWAY staged")
    assert_equal(r[2], Int(H2_ERR_ENHANCE_YOUR_CALM))
    assert_equal(r[3], 0, "the reassembly buffer was not dropped")


def test_empty_continuation_flood_is_refused() raises:
    """Zero-length CONTINUATIONs add no bytes; the frame count refuses them.
    The opening HEADERS is frame 1, so CONTINUATION number
    H2_MAX_HEADER_BLOCK_FRAMES is the first over the ceiling."""
    var r = _flood(0, H2_MAX_HEADER_BLOCK_FRAMES + 8)
    assert_equal(r[0], H2_MAX_HEADER_BLOCK_FRAMES)
    assert_true(r[1], "no GOAWAY staged")
    assert_equal(r[2], Int(H2_ERR_ENHANCE_YOUR_CALM))


def test_short_header_block_is_not_refused() raises:
    """A block of a few small frames is accepted while it awaits END_HEADERS."""
    var r = _flood(100, 8)
    assert_equal(r[0], 0)
    assert_false(r[1])
    assert_equal(r[3], 16 + 8 * 100)


def test_oversized_headers_fragment_is_refused() raises:
    """One HEADERS (no END_HEADERS) one byte over the byte ceiling: the
    HEADERS arm itself must refuse it, stage GOAWAY ENHANCE_YOUR_CALM and
    leave no reassembly open."""
    var h2 = H2ConnectionState()
    h2.mark_preface_ok()
    var router = Router()
    var grpc = NoopGrpcDispatch()
    var reqs = Int64(0)
    var sent = Int64(0)
    var ok = _handle_headers_or_continuation(
        h2,
        _frame(FRAME_HEADERS, 1, _zeros(H2_MAX_HEADER_BLOCK_BYTES + 1)),
        router,
        grpc,
        reqs,
        sent,
    )
    assert_false(ok, "an over-ceiling HEADERS fragment was accepted")
    assert_true(h2.is_goaway_sent(), "no GOAWAY staged")
    assert_equal(Int(h2.goaway_error_code), Int(H2_ERR_ENHANCE_YOUR_CALM))
    assert_equal(len(h2.cont_reasm_buf), 0)
    assert_equal(Int(h2.cont_reasm_stream_id), 0, "a reassembly was left open")


# -----------------------------------------------------------------------------
# 2. content-length
# -----------------------------------------------------------------------------


def test_content_length_wrap_to_five_is_rejected() raises:
    var res = _parse_int_safe(String("18446744073709551621"))
    assert_false(
        res[0], "content-length 2^64+5 must be rejected, not believed as 5"
    )


def test_content_length_wrap_to_zero_is_rejected() raises:
    var res = _parse_int_safe(String("18446744073709551616"))
    assert_false(res[0], "content-length 2^64 must not be believed as 0")


def test_content_length_ceiling_and_ordinary_values_accepted() raises:
    var ceil = _parse_int_safe(String("4611686018427387904"))  # 1 << 62
    assert_true(ceil[0])
    assert_equal(ceil[1], 1 << 62)
    var normal = _parse_int_safe(String("1048576"))
    assert_true(normal[0])
    assert_equal(normal[1], 1048576)
    assert_false(_parse_int_safe(String("4611686018427387905"))[0])
    assert_false(_parse_int_safe(String("9999999999999999999999999"))[0])
    assert_false(_parse_int_safe(String(""))[0])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
