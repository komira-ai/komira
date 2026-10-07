# `S3Fs.clone()`. A reader that opens several files of a directory moves one
# file system into each file's reader, so it opens each from a clone of the
# one it was given; a clone must read as the original does, and must not
# share the original's connection. (LocalFs's clone is komira_fs's
# test_local_fs_clone.)
#
# Rows: a clone keeps the bucket, the configuration and the options, and
# moves whole; a clone builds its OWN store from the factory: each factory
# call here is a ScriptedConnector armed with ONE answer, so the original
# and the clone each read once, and a second read on either finds its own
# connector's script spent (a shared store would have spent one script on
# both reads); a file system whose connector cannot be made fails when its
# store is built, `built` at construction and the plain constructor at the
# first verb, and so does its clone. No socket.
from std.testing import assert_equal, assert_raises, assert_true

from komira_aws_core import AwsCredential, FixedClock, StaticCredsSource
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_objectstore_s3 import AddressingStyle, S3Config, S3Fs, S3FsOptions
from komira_retry import Backoff, Jitter, RetryPolicy


comptime _Fs = S3Fs[ScriptedConnector, StaticCredsSource, FixedClock]


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _buf_text(b: SharedAlignedBuffer[HeapRegion]) -> String:
    var view = b.view_range_ro(0, b.len())
    return String(unsafe_from_utf8=view.into_span())


# =============================================================================
# S3Fs.
# =============================================================================


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


def _http() -> HttpClientConfig:
    return HttpClientConfig.defaults()


def _creds() -> StaticCredsSource:
    return StaticCredsSource(
        AwsCredential(
            String("AKIDEXAMPLE"),
            String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
            String(""),
        )
    )


def _mk_one_range() raises -> ScriptedConnector:
    """ONE answer: the 206 for `bytes=0-3` of a 10-byte object."""
    return ScriptedConnector.with_stream(
        ScriptedStream.from_read_script(
            _bytes(
                "HTTP/1.1 206 Partial Content\r\nContent-Length: 4\r\nConnection: close\r\n"
                'ETag: "e1"\r\nContent-Range: bytes 0-3/10\r\n\r\nabcd'
            )
        )
    )


def _mk_refused() raises -> ScriptedConnector:
    raise Error("no connector here")


def test_s3fs_clone_keeps_bucket_config_and_options() raises:
    var fs = _Fs(
        "my-bucket",
        _config(),
        _mk_one_range,
        _http(),
        _creds(),
        FixedClock(1790000000),
        S3FsOptions(prefetch_max_inflight=3, prefetch_depth=32),
    )
    var clone_fs = fs.clone()
    assert_equal(fs.bucket(), "my-bucket")
    assert_equal(clone_fs.bucket(), "my-bucket")
    assert_equal(clone_fs.prefetch_depth(), 32)
    assert_equal(clone_fs.options().prefetch_max_inflight(), 3)
    # Both move whole.
    var fs_moved = fs^
    var clone_moved = clone_fs^
    assert_equal(fs_moved.bucket(), "my-bucket")
    assert_equal(clone_moved.bucket(), "my-bucket")


def test_s3fs_clone_builds_its_own_store() raises:
    var fs = _Fs.built("lake", _config(), _mk_one_range, _http(), _creds(), FixedClock(1790000000))
    var clone_fs = fs.clone()
    var file_a = fs.open("data/a.parquet")
    var file_b = clone_fs.open("data/b.parquet")
    assert_equal(file_a.key(), "data/a.parquet")
    assert_equal(file_b.key(), "data/b.parquet")
    # One answer each: the original's store and the clone's own.
    assert_equal(_buf_text(fs.read_at(file_a, 0, 4)), "abcd")
    assert_equal(_buf_text(clone_fs.read_at(file_b, 0, 4)), "abcd")
    # And each connector's one script is now spent: the next read dials
    # again and finds no stream.
    with assert_raises(contains="ScriptedConnector.connect: no stream armed for dial #2"):
        _ = fs.read_at(file_a, 0, 4)
    with assert_raises(contains="ScriptedConnector.connect: no stream armed for dial #2"):
        _ = clone_fs.read_at(file_b, 0, 4)


def test_s3fs_whose_connector_cannot_be_made() raises:
    with assert_raises(contains="no connector here"):
        _ = _Fs.built("lake", _config(), _mk_refused, _http(), _creds(), FixedClock(1790000000))
    var fs = _Fs("lake", _config(), _mk_refused, _http(), _creds(), FixedClock(1790000000))
    var clone_fs = fs.clone()
    var file_a = fs.open("k")
    with assert_raises(contains="no connector here"):
        _ = fs.read_at(file_a, 0, 4)
    var file_b = clone_fs.open("k")
    with assert_raises(contains="no connector here"):
        _ = clone_fs.read_at(file_b, 0, 4)
    assert_true(clone_fs.supports_random_read())


def main() raises:
    test_s3fs_clone_keeps_bucket_config_and_options()
    test_s3fs_clone_builds_its_own_store()
    test_s3fs_whose_connector_cannot_be_made()
    print("OK")
