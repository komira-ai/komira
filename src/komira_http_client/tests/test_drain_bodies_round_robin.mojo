# =============================================================================
# src/komira_http_client/tests/test_drain_bodies_round_robin.mojo
# =============================================================================
# round-robin drain acceptance.
#
# Verifies the K-stream prefetch drain helper:
#   1. ORDER PRESERVATION: output[i] == body of input stream i, regardless
#      of completion order (the load-bearing property for parquet column
#      decode, which requires column ranges back in requested order).
#   2. Correct per-stream bytes for K bodies of DIFFERENT lengths.
#   3. K=1 and K=0 edge cases.
# =============================================================================

from std.testing import assert_equal, assert_true

from std.sys.info import CompilationTarget

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_collections.slab import Slab

from komira_http_client.response_body import (
    RecvRingBody,
    drain_bodies_round_robin,
)
from komira_http_core.transport.scripted import ScriptedStream


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        from komira_async.reactor.reactor import BACKEND_EPOLL
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


def _body_of_len(start: Int, n: Int) -> List[UInt8]:
    """Distinct byte pattern: byte j == (start + j) % 256. Lets the test
    assert each output came from the right input stream."""
    var out = List[UInt8]()
    var j = 0
    while j < n:
        out.append(UInt8((start + j) % 256))
        j = j + 1
    return out^


def _seeded_body(
    var content: List[UInt8],
) -> RecvRingBody[ScriptedStream]:
    """A RecvRingBody whose entire content is pre-seeded (Content-Length
    framed). `poll_frame` emits it all on the first call, then End."""
    var cl = content.__len__()
    var stream = ScriptedStream.from_read_script(List[UInt8]())
    return RecvRingBody[ScriptedStream].new_content_length(
        stream^, cl, content^,
    )


# =============================================================================
# Test 1: K=3 bodies of DIFFERENT lengths, distinct content — order + bytes.
# =============================================================================


def test_drain_three_distinct_bodies_in_order() raises:
    var lens = List[Int]()
    lens.append(5)
    lens.append(17)
    lens.append(3)
    # Distinct content per stream (start offset = stream index * 64).
    var bodies = Slab[RecvRingBody[ScriptedStream]]()
    var i = 0
    while i < 3:
        bodies.append(_seeded_body(_body_of_len(i * 64, lens[i])))
        i = i + 1

    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var out = drain_bodies_round_robin[
        PerCoreAsyncRuntime[NoopSink], ScriptedStream,
    ](bodies, reactor, tok)

    assert_equal(out.__len__(), 3)
    # Each output must equal the EXPECTED body for that input index — proves
    # order preservation (output[i] is stream i's body, not whichever
    # finished first).
    var s = 0
    while s < 3:
        var expected = _body_of_len(s * 64, lens[s])
        assert_equal(out[s].__len__(), lens[s])
        var b = 0
        while b < lens[s]:
            assert_equal(Int(out[s][b]), Int(expected[b]))
            b = b + 1
        s = s + 1


# =============================================================================
# Test 2: K=1 — single body drains correctly.
# =============================================================================


def test_drain_single_body() raises:
    var bodies = Slab[RecvRingBody[ScriptedStream]]()
    bodies.append(_seeded_body(_body_of_len(7, 9)))
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var out = drain_bodies_round_robin[
        PerCoreAsyncRuntime[NoopSink], ScriptedStream,
    ](bodies, reactor, tok)
    assert_equal(out.__len__(), 1)
    assert_equal(out[0].__len__(), 9)
    var expected = _body_of_len(7, 9)
    var b = 0
    while b < 9:
        assert_equal(Int(out[0][b]), Int(expected[b]))
        b = b + 1


# =============================================================================
# Test 3: K=0 — empty input yields empty output (no crash).
# =============================================================================


def test_drain_zero_bodies() raises:
    var bodies = Slab[RecvRingBody[ScriptedStream]]()
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var out = drain_bodies_round_robin[
        PerCoreAsyncRuntime[NoopSink], ScriptedStream,
    ](bodies, reactor, tok)
    assert_equal(out.__len__(), 0)


def main() raises:
    test_drain_three_distinct_bodies_in_order()
    test_drain_single_body()
    test_drain_zero_bodies()
    print("test_drain_bodies_round_robin: ALL PASS")
