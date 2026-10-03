# =============================================================================
# src/komira_http/tests/test_body_frame_smoke.mojo
# =============================================================================
# smoke test — verify BodyFrame + ResponseBody +
# BufferedResponseBody compile + link + behave per the contract.

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true, assert_false

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http.client.body_frame import (
    BODY_FRAME_KIND_DATA,
    BODY_FRAME_KIND_END,
    BODY_FRAME_KIND_ERROR,
    BODY_FRAME_KIND_PENDING,
    BODY_FRAME_KIND_TRAILERS,
    BodyFrame,
    body_frame_kind_name,
)
from komira_http.client.header_map import HeaderMap
from komira_http.client.response_body import (
    BufferedResponseBody,
    ResponseBody,
)


def _make_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bytes_ref = s.as_bytes()
    var i = 0
    while i < len(bytes_ref):
        out.append(bytes_ref[i])
        i = i + 1
    return out^


def _bytes_eq(buf: List[UInt8], s: String) -> Bool:
    var bytes_ref = s.as_bytes()
    if buf.__len__() != len(bytes_ref):
        return False
    var i = 0
    while i < buf.__len__():
        if buf[i] != bytes_ref[i]:
            return False
        i = i + 1
    return True


def _make_reactor() raises -> Reactor[NoopSink]:
    """Build a Reactor[NoopSink] with the platform's native backend.

    Mirrors `src/komira_http/server.mojo:_build_reactor()` and
    `src/komira_http/tests/test_kernel_tcp_loopback.mojo:_backend_for_os()`
    so this test runs on both macOS arm64 (kqueue) and Linux x86_64 (epoll).
    """
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
    )


# =============================================================================
# BodyFrame: discriminator + factories.
# =============================================================================


def test_body_frame_end() raises:
    var f = BodyFrame.end()
    assert_equal(Int(f.kind), Int(BODY_FRAME_KIND_END))
    assert_true(f.is_end())
    assert_false(f.is_data())
    assert_false(f.is_trailers())
    assert_false(f.is_pending())
    assert_false(f.is_error())
    assert_equal(f.chunk_len(), 0)


def test_body_frame_pending() raises:
    var f = BodyFrame.pending()
    assert_equal(Int(f.kind), Int(BODY_FRAME_KIND_PENDING))
    assert_true(f.is_pending())
    assert_false(f.is_data())


def test_body_frame_data() raises:
    var chunk = _make_bytes(String("hello"))
    var f = BodyFrame.data(chunk^)
    assert_true(f.is_data())
    assert_equal(f.chunk_len(), 5)
    assert_equal(Int(f.kind), Int(BODY_FRAME_KIND_DATA))
    var taken = f.take_data_chunk()
    assert_true(_bytes_eq(taken, String("hello")))


def test_body_frame_error() raises:
    var f = BodyFrame.error(String("HttpError[IO_ERROR]"))
    assert_true(f.is_error())
    assert_equal(f.error_detail(), String("HttpError[IO_ERROR]"))


def test_body_frame_trailers() raises:
    var hdrs = HeaderMap()
    hdrs.append(String("x-amz-checksum-sha256"), String("abc123"))
    var f = BodyFrame.trailers(hdrs^)
    assert_true(f.is_trailers())
    var taken = f.take_trailers()
    assert_true(taken.contains(String("x-amz-checksum-sha256")))


def test_body_frame_kind_name() raises:
    assert_equal(body_frame_kind_name(BODY_FRAME_KIND_DATA), String("DATA"))
    assert_equal(body_frame_kind_name(BODY_FRAME_KIND_END), String("END"))
    assert_equal(body_frame_kind_name(BODY_FRAME_KIND_PENDING), String("PENDING"))
    assert_equal(body_frame_kind_name(BODY_FRAME_KIND_TRAILERS), String("TRAILERS"))
    assert_equal(body_frame_kind_name(BODY_FRAME_KIND_ERROR), String("ERROR"))


# =============================================================================
# BufferedResponseBody: one Data + then End.
# =============================================================================


def test_buffered_empty() raises:
    """Empty body — first poll returns End directly (no Data)."""
    var body = BufferedResponseBody.empty()
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    assert_true(body.data_emitted())  # No Data to emit.
    assert_equal(body.bytes_remaining(), 0)
    var f = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    assert_true(f.is_end())


def test_buffered_from_bytes_one_data_then_end() raises:
    """Non-empty body — first poll yields Data(full body), then End
    idempotently."""
    var bs = _make_bytes(String("hello world"))
    var body = BufferedResponseBody.from_bytes(bs^)
    var reactor = _make_reactor()
    var tok = CancellationToken.never()

    assert_false(body.data_emitted())
    assert_equal(body.bytes_remaining(), 11)

    # First poll: Data frame with full body.
    var f1 = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    assert_true(f1.is_data())
    assert_equal(f1.chunk_len(), 11)
    var chunk = f1.take_data_chunk()
    assert_true(_bytes_eq(chunk, String("hello world")))

    # Conformer now in End state.
    assert_true(body.data_emitted())
    assert_equal(body.bytes_remaining(), 0)

    # Second poll: End. Third: End. Idempotent.
    var f2 = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    assert_true(f2.is_end())
    var f3 = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    assert_true(f3.is_end())


def test_buffered_conformance_with_trait_bound() raises:
    """Verify BufferedResponseBody satisfies the ResponseBody trait
    bound — this is a comptime check; if the trait conformance is
    broken, this test fails to COMPILE."""
    @parameter
    def _conforms[RB: ResponseBody]() -> Bool:
        return True
    var ok = _conforms[BufferedResponseBody]()
    assert_true(ok)


def main() raises:
    test_body_frame_end()
    test_body_frame_pending()
    test_body_frame_data()
    test_body_frame_error()
    test_body_frame_trailers()
    test_body_frame_kind_name()
    test_buffered_empty()
    test_buffered_from_bytes_one_data_then_end()
    test_buffered_conformance_with_trait_bound()
    print("OK: test_body_frame_smoke")
