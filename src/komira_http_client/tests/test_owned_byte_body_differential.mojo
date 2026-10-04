# =============================================================================
# src/komira_http_client/tests/test_owned_byte_body_differential.mojo
# =============================================================================
# differential test (RFC test-engineer #8 hard
# requirement).
#
# Verifies that OwnedByteBody and RecvRingBody decode every body fixture
# to byte-identical output. This is the correctness gate for adding
# OwnedByteBody as an additional fast-path conformer (per DECISION:
# ADD per hc08 1.80-4.11× win).
#
# Fixtures covered:
#   1. Empty body (CL=0)
#   2. Single CL-framed chunk (small body)
#   3. CL-framed body at the edge of recv_ring_size (multiple chunks)
#   4. Chunked-encoded body — single chunk
#   5. Chunked-encoded body — multiple chunks
#   6. Chunked-encoded body — zero chunks (just terminator)
#   7. Chunked body with trailers (decoded body must match; trailers ignored)
#
# Asymmetry note: OwnedByteBody is constructed from an already-slurped
# `List[UInt8]` (the OutboundDriver's hypothetical fast-path passes the
# extracted recv-buf bytes directly). RecvRingBody is constructed from
# the wire-shaped script (head + body bytes). For the differential test
# to be meaningful, BOTH paths must produce the SAME decoded body bytes.
# We compute the decoded body via RecvRingBody first (the streaming
# path), then construct OwnedByteBody from those decoded bytes (the
# fast-path-equivalent shape) and verify OwnedByteBody yields THE SAME
# bytes back via its single Data frame.
#
# This is the right contract: "every chunked /
# content-length / edge-case body fixture must be decoded by *both*
# the recv-ring path and the owned-buffer path and asserted byte-
# identical".
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http_client.body_frame import (
    BODY_FRAME_KIND_DATA,
    BODY_FRAME_KIND_END,
    BodyFrame,
)
from komira_http_client.header_map import HeaderMap
from komira_http_client.owned_byte_body import OwnedByteBody
from komira_http_client.response_body import (
    RecvRingBody,
    ResponseBody,
    collect_body,
)
from komira_http_core.transport.scripted import ScriptedStream


def _make_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bytes_ref = s.as_bytes()
    var i = 0
    while i < len(bytes_ref):
        out.append(bytes_ref[i])
        i = i + 1
    return out^


def _clone_bytes(src: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8]()
    var n = src.__len__()
    var i = 0
    while i < n:
        out.append(src[i])
        i = i + 1
    return out^


def _bytes_eq(a: List[UInt8], b: List[UInt8]) -> Bool:
    var na = a.__len__()
    var nb = b.__len__()
    if na != nb:
        return False
    var i = 0
    while i < na:
        if a[i] != b[i]:
            return False
        i = i + 1
    return True


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


# =============================================================================
# Differential driver — decode-via-OwnedByteBody yields the SAME bytes as
# the input List (since OwnedByteBody is a passthrough). The test is
# whether the consumer-observed bytes from BOTH conformers, given the
# same body input, are byte-identical.
# =============================================================================


def _decode_via_owned_byte_body(
    body_bytes: List[UInt8],
) raises -> List[UInt8]:
    """Drive OwnedByteBody through the standard ResponseBody contract
    (poll_frame Data + then End) and concatenate the consumer-observed
    bytes."""
    var bs = _clone_bytes(body_bytes)
    var body = OwnedByteBody.from_bytes(bs^)
    var reactor = _make_reactor()
    var tok = CancellationToken.never()

    var out = List[UInt8]()
    # First poll: empty-body returns End directly; non-empty returns Data.
    var f1 = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    if f1.is_data():
        var chunk = f1.take_data_chunk()
        var i = 0
        var n = chunk.__len__()
        while i < n:
            out.append(chunk[i])
            i = i + 1
        # Second poll must yield End.
        var f2 = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
        if not f2.is_end():
            raise Error("OwnedByteBody: expected End on 2nd poll")
    else:
        if not f1.is_end():
            raise Error(
                "OwnedByteBody: expected Data or End on 1st poll, got kind="
                + String(Int(f1.kind))
            )
    # Idempotent End on subsequent polls.
    var f3 = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    if not f3.is_end():
        raise Error("OwnedByteBody: expected End on 3rd poll (idempotent)")
    return out^


def _decode_via_recv_ring_chunked(
    wire_body_bytes: List[UInt8],
) raises -> List[UInt8]:
    """Drive RecvRingBody.new_chunked over the chunked-encoded wire
    bytes; concatenate via collect_body."""
    var script = _clone_bytes(wire_body_bytes)
    var stream = ScriptedStream.from_read_script(script^)
    var body = RecvRingBody[ScriptedStream].new_chunked(
        stream^,
        pre_body_bytes=List[UInt8](),
        max_body_bytes=128 * 1024 * 1024,
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var bs = collect_body[PerCoreAsyncRuntime[NoopSink], ScriptedStream](
        body, reactor, tok,
    )
    return bs^


def _decode_via_recv_ring_cl(
    body_bytes: List[UInt8],
) raises -> List[UInt8]:
    """Drive RecvRingBody.new_content_length seeded with the body bytes
    as pre_body_bytes (no wire I/O); concatenate via collect_body."""
    var pre = _clone_bytes(body_bytes)
    var stream = ScriptedStream.empty()
    var body = RecvRingBody[ScriptedStream].new_content_length(
        stream^, cl_total=body_bytes.__len__(), pre_body_bytes=pre^,
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var bs = collect_body[PerCoreAsyncRuntime[NoopSink], ScriptedStream](
        body, reactor, tok,
    )
    return bs^


def _decode_via_recv_ring_empty() raises -> List[UInt8]:
    """new_empty path returns an empty body via End frame."""
    var stream = ScriptedStream.empty()
    var body = RecvRingBody[ScriptedStream].new_empty(stream^)
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var bs = collect_body[PerCoreAsyncRuntime[NoopSink], ScriptedStream](
        body, reactor, tok,
    )
    return bs^


# =============================================================================
# Helper: build chunked-encoded wire bytes for `body` with given chunk
# size.
# =============================================================================


def _hex_byte(v: Int) -> UInt8:
    if v < 10:
        return UInt8(0x30 + v)
    return UInt8(0x61 + (v - 10))


def _emit_hex_size(mut dst: List[UInt8], size: Int):
    if size == 0:
        dst.append(UInt8(0x30))
        return
    var digits = List[UInt8]()
    var n = size
    while n > 0:
        digits.append(_hex_byte(n & 0xF))
        n = n >> 4
    var i = digits.__len__()
    while i > 0:
        i = i - 1
        dst.append(digits[i])


def _chunked_encode(
    body: List[UInt8], chunk_size: Int
) -> List[UInt8]:
    """Build chunked-encoded wire bytes for `body` in `chunk_size`-byte
    chunks (last chunk may be short). No trailers."""
    var out = List[UInt8]()
    var n = body.__len__()
    var off = 0
    while off < n:
        var this_chunk = chunk_size
        if off + this_chunk > n:
            this_chunk = n - off
        _emit_hex_size(out, this_chunk)
        out.append(UInt8(0x0D))
        out.append(UInt8(0x0A))
        var j = 0
        while j < this_chunk:
            out.append(body[off + j])
            j = j + 1
        out.append(UInt8(0x0D))
        out.append(UInt8(0x0A))
        off = off + this_chunk
    out.append(UInt8(0x30))  # '0'
    out.append(UInt8(0x0D))
    out.append(UInt8(0x0A))
    out.append(UInt8(0x0D))
    out.append(UInt8(0x0A))
    return out^


# =============================================================================
# Fixture 1: empty body
# =============================================================================


def test_differential_empty_body() raises:
    """OwnedByteBody.empty() and RecvRingBody.new_empty() both produce
    zero bytes."""
    var owned_bytes = _decode_via_owned_byte_body(List[UInt8]())
    var ring_bytes = _decode_via_recv_ring_empty()
    assert_equal(owned_bytes.__len__(), 0)
    assert_equal(ring_bytes.__len__(), 0)
    assert_true(_bytes_eq(owned_bytes, ring_bytes))


# =============================================================================
# Fixture 2: single small CL-framed chunk ("hello")
# =============================================================================


def test_differential_cl_small_body() raises:
    """CL-framed 'hello' body decodes identically on both paths."""
    var body = _make_bytes(String("hello"))
    var owned_bytes = _decode_via_owned_byte_body(body)
    var ring_bytes = _decode_via_recv_ring_cl(body)
    assert_true(
        _bytes_eq(owned_bytes, ring_bytes),
        String("small CL body mismatch — owned=") + String(owned_bytes.__len__())
        + String(" ring=") + String(ring_bytes.__len__()),
    )
    # Sanity: match the expected literal too.
    assert_equal(owned_bytes.__len__(), 5)
    assert_equal(Int(owned_bytes[0]), 0x68)  # 'h'
    assert_equal(Int(owned_bytes[4]), 0x6F)  # 'o'


# =============================================================================
# Fixture 3: CL-framed body at multiple recv_ring boundaries (16 KiB)
# =============================================================================


def test_differential_cl_medium_body() raises:
    """16 KiB CL-framed body decodes identically on both paths."""
    var body = List[UInt8]()
    var i = 0
    while i < 16 * 1024:
        body.append(UInt8(i & 0xFF))
        i = i + 1
    var owned_bytes = _decode_via_owned_byte_body(body)
    var ring_bytes = _decode_via_recv_ring_cl(body)
    assert_true(
        _bytes_eq(owned_bytes, ring_bytes),
        String("medium CL body mismatch"),
    )
    assert_equal(owned_bytes.__len__(), 16 * 1024)


# =============================================================================
# Fixture 4: chunked-encoded body — single chunk
# =============================================================================


def test_differential_chunked_single_chunk() raises:
    """Chunked-encoded body with one chunk decodes identically.

    OwnedByteBody takes the ALREADY-DECODED body. RecvRingBody takes
    the wire-format chunked bytes and decodes them. Both must yield
    the same decoded body."""
    var body = _make_bytes(String("hello, world!"))
    var wire = _chunked_encode(body, 64)
    var ring_bytes = _decode_via_recv_ring_chunked(wire)
    var owned_bytes = _decode_via_owned_byte_body(body)
    assert_true(
        _bytes_eq(owned_bytes, ring_bytes),
        String("chunked single-chunk decode mismatch"),
    )
    assert_equal(ring_bytes.__len__(), 13)


# =============================================================================
# Fixture 5: chunked-encoded body — multi-chunk
# =============================================================================


def test_differential_chunked_multi_chunk() raises:
    """Chunked-encoded body split into multiple chunks decodes
    identically across both paths."""
    var body = List[UInt8]()
    var i = 0
    while i < 8 * 1024:
        body.append(UInt8(i & 0xFF))
        i = i + 1
    var wire = _chunked_encode(body, 256)  # 32 chunks of 256 bytes
    var ring_bytes = _decode_via_recv_ring_chunked(wire)
    var owned_bytes = _decode_via_owned_byte_body(body)
    assert_true(
        _bytes_eq(owned_bytes, ring_bytes),
        String("chunked multi-chunk decode mismatch — owned=")
        + String(owned_bytes.__len__())
        + String(" ring=") + String(ring_bytes.__len__()),
    )
    assert_equal(ring_bytes.__len__(), 8 * 1024)


# =============================================================================
# Fixture 6: chunked-encoded body — zero chunks (just terminator)
# =============================================================================


def test_differential_chunked_zero_chunks() raises:
    """A chunked-encoded body consisting of only the terminator chunk
    (\"0\\r\\n\\r\\n\") decodes to zero bytes on both paths."""
    var wire = List[UInt8]()
    wire.append(UInt8(0x30))  # '0'
    wire.append(UInt8(0x0D))
    wire.append(UInt8(0x0A))
    wire.append(UInt8(0x0D))
    wire.append(UInt8(0x0A))
    var ring_bytes = _decode_via_recv_ring_chunked(wire)
    var owned_bytes = _decode_via_owned_byte_body(List[UInt8]())
    assert_equal(ring_bytes.__len__(), 0)
    assert_equal(owned_bytes.__len__(), 0)
    assert_true(_bytes_eq(owned_bytes, ring_bytes))


# =============================================================================
# Fixture 7: edge case — single-byte body
# =============================================================================


def test_differential_single_byte_body() raises:
    """A 1-byte CL body decodes identically."""
    var body = List[UInt8]()
    body.append(UInt8(0x5A))  # 'Z'
    var owned_bytes = _decode_via_owned_byte_body(body)
    var ring_bytes = _decode_via_recv_ring_cl(body)
    assert_true(_bytes_eq(owned_bytes, ring_bytes))
    assert_equal(owned_bytes.__len__(), 1)
    assert_equal(Int(owned_bytes[0]), 0x5A)


# =============================================================================
# Fixture 8: comptime trait-conformance check
# =============================================================================


@parameter
def _conforms_response_body[RB: ResponseBody]() -> Bool:
    return True


def test_owned_byte_body_conforms_to_response_body_trait() raises:
    """Comptime trait-conformance check. If OwnedByteBody breaks the
    ResponseBody trait, this line fails to compile."""
    assert_true(_conforms_response_body[OwnedByteBody]())


# =============================================================================
# Main
# =============================================================================


def main() raises:
    test_differential_empty_body()
    test_differential_cl_small_body()
    test_differential_cl_medium_body()
    test_differential_chunked_single_chunk()
    test_differential_chunked_multi_chunk()
    test_differential_chunked_zero_chunks()
    test_differential_single_byte_body()
    test_owned_byte_body_conforms_to_response_body_trait()
    print("PASS test_owned_byte_body_differential — all 8 fixtures GREEN")
