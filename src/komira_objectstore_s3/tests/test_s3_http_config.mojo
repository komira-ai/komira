# The caller's HttpClientConfig is the one a store's HTTP client is built
# from: S3Store, S3Fs and S3ConditionalStore each take it as a constructor
# parameter with no default, and a clone of S3Fs or S3ConditionalStore
# builds its own store from the same one. Every other test here passes
# `HttpClientConfig.defaults()`, so a store that dropped the caller's config
# for the defaults would pass them all; these rows pass configs that differ
# from the defaults and observe the difference on the wire.
#
# Rows: a response body cap of 3 bytes refuses a 4-byte ranged read
# (BODY_TOO_LARGE, raised at once, not retried), and a cap of 4 reads the
# same answer, through S3Store, through S3Fs and its clone, and through
# S3ConditionalStore and its clone; and a 150 ms request budget against a
# server that takes the connection and never answers ends the read of an
# S3Fs, and of its clone, with the client's request deadline error, well
# inside 30 s (the defaults' budget is 600 s). Every connector is a
# ScriptedConnector: no socket.
#
# The 206 here is chunked, though S3 answers GetObject with Content-Length.
# komira_http_client applies the caller's `max_response_body_bytes` to every
# framing (chunked, read to EOF, Content-Length); the Content-Length case is
# pinned at the HttpClient level by komira_http_client's
# `test_content_length_body_cap`. These rows could gain a Content-Length
# answer; they have not yet.
#
# S3Store also hands `http_config` to its generated S3 client, but drives
# every verb through the client's `<op>_with` sends over its own transport,
# so only the transport's copy is used; these rows observe that one.
from std.testing import assert_equal, assert_raises, assert_true
from std.time import perf_counter_ns

from komira_aws_core import AwsCredential, FixedClock, StaticCredsSource
from komira_core.arrow.shared_aligned_buffer import SharedAlignedBuffer
from komira_core.io.heap_region import HeapRegion
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_objectstore.path import Path
from komira_objectstore_s3 import (
    AddressingStyle,
    S3ConditionalStore,
    S3Config,
    S3Fs,
    S3Store,
)
from komira_retry import Backoff, Jitter, RetryPolicy


comptime _Store = S3Store[ScriptedConnector, StaticCredsSource, FixedClock]
comptime _Fs = S3Fs[ScriptedConnector, StaticCredsSource, FixedClock]
comptime _Cond = S3ConditionalStore[ScriptedConnector, StaticCredsSource, FixedClock]

comptime _STUCK_BUDGET_US: Int = 150_000
"""The request budget of the stuck-server row (150 ms)."""

comptime _STUCK_WALL_LIMIT_NS: Int = 30_000_000_000
"""How long a stuck read may take (30 s): far over the 150 ms budget, far
under the defaults' 600 s."""

comptime _REQUEST_DEADLINE = "HttpError[TIMEOUT]: request deadline exceeded"


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _text(b: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(b))


def _buf_text(b: SharedAlignedBuffer[HeapRegion]) -> String:
    var view = b.view_range_ro(0, b.len())
    return String(unsafe_from_utf8=view.into_span())


def _config() raises -> S3Config:
    return S3Config(
        "us-east-1",
        endpoint="http://127.0.0.1:9000",
        addressing=AddressingStyle.path(),
        retry=RetryPolicy(
            Backoff(initial_ms=1, multiplier=2.0, max_ms=2, jitter=Jitter.full()),
            max_attempts=1,
            deadline_ms=Int64(60_000),
        ),
    )


def _creds() -> StaticCredsSource:
    return StaticCredsSource(
        AwsCredential(
            String("AKIDEXAMPLE"),
            String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
            String(""),
        )
    )


def _capped(max_body: Int) -> HttpClientConfig:
    """The defaults with a response body cap of `max_body` bytes."""
    var cfg = HttpClientConfig.defaults()
    cfg.max_response_body_bytes = max_body
    return cfg


def _mk_one_range() raises -> ScriptedConnector:
    """ONE answer: the 206 for `bytes=0-3` of a 10-byte object, its body
    chunked (see the header)."""
    return ScriptedConnector.with_stream(
        ScriptedStream.from_read_script(
            _bytes(
                "HTTP/1.1 206 Partial Content\r\nTransfer-Encoding: chunked\r\n"
                'Connection: close\r\nETag: "e1"\r\nContent-Range: bytes 0-3/10\r\n\r\n'
                "4\r\nabcd\r\n0\r\n\r\n"
            )
        )
    )


def _stuck_stream() -> ScriptedStream:
    var s = ScriptedStream.empty()
    s.queue_read_pending(50_000_000)
    return s^


def _mk_stuck() raises -> ScriptedConnector:
    """A server that takes the connection and does not answer: its first
    50,000,000 reads are Pending, far longer than the 150 ms budget, so the
    budget ends the attempt. Past them it closes, which a client without the
    budget meets as a transport error, not the deadline error."""
    return ScriptedConnector.with_stream(_stuck_stream())


# =============================================================================
# The response body cap.
# =============================================================================


def test_s3store_reads_through_the_callers_body_cap() raises:
    var small = _Store(_config(), _mk_one_range, _capped(3), _creds(), FixedClock(1790000000))
    with assert_raises(contains="BODY_TOO_LARGE"):
        _ = small.get_range("lake", "k", 0, 4)
    var exact = _Store(_config(), _mk_one_range, _capped(4), _creds(), FixedClock(1790000000))
    assert_equal(_text(exact.get_range("lake", "k", 0, 4)), "abcd")


def test_s3fs_and_its_clone_read_through_the_callers_body_cap() raises:
    var fs = _Fs("lake", _config(), _mk_one_range, _capped(3), _creds(), FixedClock(1790000000))
    var clone_fs = fs.clone()
    var file_a = fs.open("data/a.parquet")
    with assert_raises(contains="BODY_TOO_LARGE"):
        _ = fs.read_at(file_a, 0, 4)
    var file_b = clone_fs.open("data/b.parquet")
    with assert_raises(contains="BODY_TOO_LARGE"):
        _ = clone_fs.read_at(file_b, 0, 4)
    var exact = _Fs("lake", _config(), _mk_one_range, _capped(4), _creds(), FixedClock(1790000000))
    var exact_clone = exact.clone()
    var file_c = exact.open("data/c.parquet")
    assert_equal(_buf_text(exact.read_at(file_c, 0, 4)), "abcd")
    var file_d = exact_clone.open("data/d.parquet")
    assert_equal(_buf_text(exact_clone.read_at(file_d, 0, 4)), "abcd")


def test_s3_conditional_store_and_its_clone_read_through_the_callers_body_cap() raises:
    var store = _Cond("lake", _config(), _mk_one_range, _capped(3), _creds(), FixedClock(1790000000))
    var clone_store = store.clone()
    with assert_raises(contains="BODY_TOO_LARGE"):
        _ = store.get_range(Path.parse("k"), 0, 4)
    with assert_raises(contains="BODY_TOO_LARGE"):
        _ = clone_store.get_range(Path.parse("k"), 0, 4)
    var exact = _Cond("lake", _config(), _mk_one_range, _capped(4), _creds(), FixedClock(1790000000))
    var exact_clone = exact.clone()
    assert_equal(_text(exact.get_range(Path.parse("k"), 0, 4)), "abcd")
    assert_equal(_text(exact_clone.get_range(Path.parse("k"), 0, 4)), "abcd")


# =============================================================================
# The request budget.
# =============================================================================


def _assert_ends_at_the_budget(fs: _Fs, who: String) raises:
    """A read through `fs` against the stuck server raises the request
    deadline error, and within `_STUCK_WALL_LIMIT_NS`."""
    var file = fs.open("data/a.parquet")
    var raised = String("")
    var t0 = Int(perf_counter_ns())
    try:
        _ = fs.read_at(file, 0, 4)
    except e:
        raised = String(e)
    var elapsed_ns = Int(perf_counter_ns()) - t0
    assert_true(raised.find(_REQUEST_DEADLINE) >= 0, who + " got: " + raised)
    assert_true(
        elapsed_ns < _STUCK_WALL_LIMIT_NS,
        who + " took " + String(elapsed_ns) + " ns",
    )


def test_s3fs_and_its_clone_end_a_stuck_read_at_the_callers_budget() raises:
    # The defaults' budget is 600 s, so a read that ends with the deadline
    # error here ended at the 150 ms the caller configured.
    var cfg = HttpClientConfig.defaults()
    cfg.request_timeout_us = _STUCK_BUDGET_US
    var fs = _Fs("lake", _config(), _mk_stuck, cfg, _creds(), FixedClock(1790000000))
    var clone_fs = fs.clone()
    _assert_ends_at_the_budget(fs, "the original")
    _assert_ends_at_the_budget(clone_fs, "the clone")


def main() raises:
    # The body cap rows first: a store that dropped the caller's config
    # fails them at once, before the stuck row waits on a server.
    test_s3store_reads_through_the_callers_body_cap()
    test_s3fs_and_its_clone_read_through_the_callers_body_cap()
    test_s3_conditional_store_and_its_clone_read_through_the_callers_body_cap()
    test_s3fs_and_its_clone_end_a_stuck_read_at_the_callers_budget()
    print("OK")
