# `S3ScanFs`: the opener that turns a scan's bucket into an `S3Fs`.
#
# Rows: an opened file system reads the bucket the scan names (an object's
# size and bytes through the fake S3), its key prefix is that bucket's URL,
# so two buckets never share a cache key; opening dials nothing (a connector
# factory that fails is first called by the first read); a scheme other than
# S3 and an empty bucket are refused with SCAN_FS_UNSERVED, word for word.
# The fake keeps objects in memory: no socket.
from std.testing import assert_equal, assert_raises, assert_true

from aws_core import AwsCredential, FixedClock, StaticCredsSource
from http_client.client import HttpClientConfig
from objectstore_s3 import AddressingStyle, S3Config, S3ScanFs
from plan_expr.fs_descriptor_pod import FS_SCHEME_GCS, FS_SCHEME_S3
from retry import Backoff, Jitter, RetryPolicy

from komira_test_fake_s3 import FakeS3Connector

comptime _Opener = S3ScanFs[FakeS3Connector, StaticCredsSource, FixedClock]


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


def _mk_lake() raises -> FakeS3Connector:
    var c = FakeS3Connector()
    c.seed("d/digits", "0123456789")
    return c^


def _mk_refused() raises -> FakeS3Connector:
    raise Error("no connector here")


def _opener(mk: def () raises thin -> FakeS3Connector) raises -> _Opener:
    return _Opener(_config(), mk, HttpClientConfig.defaults(), _creds(), FixedClock(1790000000))


def test_an_opened_file_system_reads_the_named_bucket() raises:
    var fs = _opener(_mk_lake).open_scan_fs(FS_SCHEME_S3, "lake")
    assert_equal(fs.bucket(), "lake")
    assert_equal(fs.key_prefix(), "s3://lake/")
    assert_equal(fs.file_size("d/digits"), 10)
    var h = fs.open("d/digits")
    var buf = fs.read_at(h, 2, 3)
    var got = buf.view_range_ro(0, 3).into_span()
    assert_equal(Int(got[0]), ord("2"))
    assert_equal(Int(got[2]), ord("4"))


def test_two_buckets_have_two_key_prefixes() raises:
    var opener = _opener(_mk_lake)
    var a = opener.open_scan_fs(FS_SCHEME_S3, "lake")
    var b = opener.open_scan_fs(FS_SCHEME_S3, "other")
    assert_equal(b.bucket(), "other")
    assert_true(a.key_prefix() != b.key_prefix())


def test_opening_dials_nothing() raises:
    var fs = _opener(_mk_refused).open_scan_fs(FS_SCHEME_S3, "lake")
    assert_equal(fs.stores_built(), 0)
    with assert_raises(contains="no connector here"):
        _ = fs.file_size("d/digits")


def test_another_scheme_is_refused() raises:
    var refused = False
    try:
        _ = _opener(_mk_lake).open_scan_fs(FS_SCHEME_GCS, "raw")
    except e:
        assert_equal(String(e), "SCAN_FS_UNSERVED: no file system of this run reads gs://raw")
        refused = True
    assert_true(refused)


def test_an_empty_bucket_is_refused() raises:
    var refused = False
    try:
        _ = _opener(_mk_lake).open_scan_fs(FS_SCHEME_S3, "")
    except e:
        assert_equal(String(e), "SCAN_FS_UNSERVED: an S3 scan names no bucket")
        refused = True
    assert_true(refused)


def main() raises:
    test_an_opened_file_system_reads_the_named_bucket()
    test_two_buckets_have_two_key_prefixes()
    test_opening_dials_nothing()
    test_another_scheme_is_refused()
    test_an_empty_bucket_is_refused()
    print("OK")
