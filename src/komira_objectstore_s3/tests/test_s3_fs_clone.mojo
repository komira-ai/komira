# `FileSystem.clone()`, for LocalFs and S3Fs. A reader that opens several
# files of a directory moves one file system into each file's reader, so it
# opens each from a clone of the one it was given; a clone must read as the
# original does, and for S3 it must not share the original's connection.
#
# Rows: a LocalFs clone reads the bytes the original reads, and opens the
# same paths (its scratch files under the test's own TEST_TMPDIR, from
# komira_runtime_paths); an S3Fs clone keeps the bucket, the configuration
# and the options, and moves whole; an S3Fs clone builds its OWN store from
# the factory: each factory call here is a ScriptedConnector armed with ONE
# answer, so the original and the clone each read once, and a second read on
# either finds its own script spent (a shared store would have spent one
# script on both reads); a file system whose connector cannot be made fails
# when its store is built, `built` at construction and the plain
# constructor at the first verb, and so does its clone. No socket.
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_aws_core import AwsCredential, FixedClock, StaticCredsSource
from komira_core.arrow.shared_aligned_buffer import SharedAlignedBuffer
from komira_core.io.heap_region import HeapRegion
from komira_fs.local_fs import LocalFs
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_objectstore_s3 import AddressingStyle, S3Config, S3Fs, S3FsOptions
from komira_retry import Backoff, Jitter, RetryPolicy
from komira_runtime_paths import test_tmpdir


comptime _Fs = S3Fs[ScriptedConnector, StaticCredsSource, FixedClock]


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _buf_text(b: SharedAlignedBuffer[HeapRegion]) -> String:
    var view = b.view_range_ro(0, b.len())
    return String(unsafe_from_utf8=view.into_span())


# =============================================================================
# LocalFs.
# =============================================================================


def _write_payload(path: String, n: Int) raises:
    """`n` bytes of the pattern `i % 251` at `path`."""
    var buf = List[UInt8](capacity=n)
    for i in range(n):
        buf.append(UInt8(i % 251))
    with open(path, "w") as fh:
        fh.write_bytes(buf)


def test_localfs_clone_reads_as_the_original() raises:
    var path = test_tmpdir() + "/clone_round_trip.bin"
    _write_payload(path, 4096)
    var fs = LocalFs[NoopSink].new()
    var clone_fs = fs.clone()
    var file_a = fs.open(path)
    var buf_a = fs.read_at(file_a, Int64(100), Int64(64))
    var file_b = clone_fs.open(path)
    var buf_b = clone_fs.read_at(file_b, Int64(100), Int64(64))
    assert_equal(buf_a.len(), 64)
    assert_equal(buf_b.len(), 64)
    var a = buf_a.view_range_ro(0, 64).into_span()
    var b = buf_b.view_range_ro(0, 64).into_span()
    for i in range(64):
        assert_equal(Int(a[i]), (100 + i) % 251)
        assert_equal(a[i], b[i])


def test_localfs_clone_keeps_its_root() raises:
    var root = test_tmpdir()
    var path = root + "/clone_root.bin"
    _write_payload(path, 256)
    var fs = LocalFs[NoopSink].from_root(root)
    var clone_fs = fs.clone()
    var file_a = fs.open(path)
    var file_b = clone_fs.open(path)
    assert_equal(file_a.path(), file_b.path())
    assert_false(file_a.is_mmap_cached())
    assert_false(file_b.is_mmap_cached())


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
        _creds(),
        FixedClock(1790000000),
        S3FsOptions(prefetch_max_inflight=3, prefetch_depth=32),
    )
    var clone_fs = fs.clone()
    assert_equal(fs.bucket(), "my-bucket")
    assert_equal(clone_fs.bucket(), "my-bucket")
    assert_equal(clone_fs.prefetch_depth(), 32)
    assert_equal(clone_fs.options().prefetch_max_inflight, 3)
    # Both move whole.
    var fs_moved = fs^
    var clone_moved = clone_fs^
    assert_equal(fs_moved.bucket(), "my-bucket")
    assert_equal(clone_moved.bucket(), "my-bucket")


def test_s3fs_clone_builds_its_own_store() raises:
    var fs = _Fs.built("lake", _config(), _mk_one_range, _creds(), FixedClock(1790000000))
    var clone_fs = fs.clone()
    var file_a = fs.open("data/a.parquet")
    var file_b = clone_fs.open("data/b.parquet")
    assert_equal(file_a.key(), "data/a.parquet")
    assert_equal(file_b.key(), "data/b.parquet")
    # One answer each: the original's store and the clone's own.
    assert_equal(_buf_text(fs.read_at(file_a, 0, 4)), "abcd")
    assert_equal(_buf_text(clone_fs.read_at(file_b, 0, 4)), "abcd")
    # And each script is now spent.
    with assert_raises():
        _ = fs.read_at(file_a, 0, 4)
    with assert_raises():
        _ = clone_fs.read_at(file_b, 0, 4)


def test_s3fs_whose_connector_cannot_be_made() raises:
    with assert_raises(contains="no connector here"):
        _ = _Fs.built("lake", _config(), _mk_refused, _creds(), FixedClock(1790000000))
    var fs = _Fs("lake", _config(), _mk_refused, _creds(), FixedClock(1790000000))
    var clone_fs = fs.clone()
    var file_a = fs.open("k")
    with assert_raises(contains="no connector here"):
        _ = fs.read_at(file_a, 0, 4)
    var file_b = clone_fs.open("k")
    with assert_raises(contains="no connector here"):
        _ = clone_fs.read_at(file_b, 0, 4)
    assert_true(clone_fs.supports_random_read())


def main() raises:
    test_localfs_clone_reads_as_the_original()
    test_localfs_clone_keeps_its_root()
    test_s3fs_clone_keeps_bucket_config_and_options()
    test_s3fs_clone_builds_its_own_store()
    test_s3fs_whose_connector_cannot_be_made()
    print("OK")
