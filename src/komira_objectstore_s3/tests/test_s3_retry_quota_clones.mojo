# A clone of S3Fs or of S3ConditionalStore pays for its retries from its
# OWN AwsRetryQuota. A store is one client and botocore keeps one quota per
# client; a clone builds its own store, so a clone whose original has spent
# its quota still retries, and a clone that shared the original's quota
# would not.
#
# Each store dials one ScriptedConnector from the factory, armed with:
#   a 500 then the 206: the first read is retried and succeeds, and the
#     success puts back what its retry cost (the quota is full again);
#   QUOTA / COST reads each answered 500 twice: each is retried once and
#     fails, and a failed call puts nothing back, so the quota is spent;
#   one 500: with the quota spent, that read is not retried and raises;
#   a 500 then the 206: never reached by the original.
# The original runs the first three; its clone, taken after, reads once and
# must be retried past a 500 to the 206 (from its own connector's first two
# answers). A clone sharing the original's store, and so its quota, would
# meet the last pair: its 500 would not be retried. Retries wait 1 ms.
from std.testing import assert_equal, assert_true

from komira_aws_core import (
    AWS_RETRY_COST,
    AWS_RETRY_QUOTA_CAPACITY,
    AwsCredential,
    FixedClock,
    StaticCredsSource,
)
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
)
from komira_retry import Backoff, Jitter, RetryPolicy


comptime _Fs = S3Fs[ScriptedConnector, StaticCredsSource, FixedClock]
comptime _Cond = S3ConditionalStore[ScriptedConnector, StaticCredsSource, FixedClock]

comptime _SPENDING_READS = AWS_RETRY_QUOTA_CAPACITY // AWS_RETRY_COST
"""The failed reads, each retried once, that spend a full quota."""


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
            max_attempts=2,
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


def _internal_error() -> ScriptedStream:
    var body = String(
        "<Error><Code>InternalError</Code><Message>We encountered an internal"
        " error. Please try again.</Message></Error>"
    )
    return ScriptedStream.from_read_script(
        _bytes(
            String("HTTP/1.1 500 Internal Server Error\r\nContent-Length: ")
            + String(body.byte_length())
            + "\r\nConnection: close\r\nContent-Type: application/xml\r\n\r\n"
            + body
        )
    )


def _range_0_3() -> ScriptedStream:
    """The 206 for `bytes=0-3` of a 10-byte object."""
    return ScriptedStream.from_read_script(
        _bytes(
            "HTTP/1.1 206 Partial Content\r\nContent-Length: 4\r\nConnection: close\r\n"
            'ETag: "e1"\r\nContent-Range: bytes 0-3/10\r\n\r\nabcd'
        )
    )


def _mk_quota_script() raises -> ScriptedConnector:
    var c = ScriptedConnector.with_stream(_internal_error())
    c.arm_next(_range_0_3())
    for _ in range(_SPENDING_READS):
        c.arm_next(_internal_error())
        c.arm_next(_internal_error())
    c.arm_next(_internal_error())
    c.arm_next(_internal_error())
    c.arm_next(_range_0_3())
    return c^


def test_an_s3fs_clone_retries_after_the_original_spent_its_quota() raises:
    var fs = _Fs("lake", _config(), _mk_quota_script, HttpClientConfig.defaults(), _creds(), FixedClock(1790000000))
    var file = fs.open("data/a.parquet")
    # A full quota: the 500 is retried.
    assert_equal(_buf_text(fs.read_at(file, 0, 4)), "abcd")
    # Spend it.
    for i in range(_SPENDING_READS):
        var raised = String("")
        try:
            _ = fs.read_at(file, 0, 4)
        except e:
            raised = String(e)
        assert_true(raised.find("status=500") >= 0, "read " + String(i) + " got: " + raised)
    # Spent: the next 500 is not retried.
    var raised = String("")
    try:
        _ = fs.read_at(file, 0, 4)
    except e:
        raised = String(e)
    assert_true(raised.find("status=500") >= 0, "the spent read got: " + raised)
    # The clone's own quota is full: its 500 is retried.
    var clone_fs = fs.clone()
    var clone_file = clone_fs.open("data/a.parquet")
    assert_equal(_buf_text(clone_fs.read_at(clone_file, 0, 4)), "abcd")


def test_an_s3_conditional_store_clone_retries_after_the_original_spent_its_quota() raises:
    var store = _Cond("lake", _config(), _mk_quota_script, HttpClientConfig.defaults(), _creds(), FixedClock(1790000000))
    var path = Path.parse("data/a.parquet")
    assert_equal(_text(store.get_range(path, 0, 4)), "abcd")
    for i in range(_SPENDING_READS):
        var raised = String("")
        try:
            _ = store.get_range(path, 0, 4)
        except e:
            raised = String(e)
        assert_true(raised.find("status=500") >= 0, "read " + String(i) + " got: " + raised)
    var raised = String("")
    try:
        _ = store.get_range(path, 0, 4)
    except e:
        raised = String(e)
    assert_true(raised.find("status=500") >= 0, "the spent read got: " + raised)
    var clone_store = store.clone()
    assert_equal(_text(clone_store.get_range(path, 0, 4)), "abcd")


def main() raises:
    test_an_s3fs_clone_retries_after_the_original_spent_its_quota()
    test_an_s3_conditional_store_clone_retries_after_the_original_spent_its_quota()
    print("OK")
