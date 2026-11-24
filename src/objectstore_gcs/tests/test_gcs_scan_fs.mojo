# `GcsScanFs`: the opener that turns a scan's bucket into a `GcsFs`.
#
# Rows: an opened file system, reached only through the `ScanFsOpener` trait,
# reads the bucket the scan names (an object's size and bytes through the
# in-memory fake) and its key prefix is that bucket's URL, so two buckets
# never share a cache key; opening builds no backend (a factory that fails is
# first called by the first read, and a clone builds its own); a scheme other
# than GCS and an empty bucket are refused with SCAN_FS_UNSERVED, word for
# word. The fake keeps objects in memory: no socket.
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from fs.scan_fs import ScanFsOpener
from objectstore_gcs import FakeGcsStorageBackend, GcsScanFs
from plan_expr.fs_descriptor_pod import FS_SCHEME_AZURE, FS_SCHEME_GCS, FS_SCHEME_S3

comptime _Opener = GcsScanFs[FakeGcsStorageBackend]


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _mk_lake() raises -> FakeGcsStorageBackend:
    var b = FakeGcsStorageBackend()
    _ = b.conditional_create("lake", "d/digits", _bytes("0123456789"))
    return b^


def _mk_refused() raises -> FakeGcsStorageBackend:
    raise Error("no backend here")


def _open[O: ScanFsOpener](opener: O, scheme: UInt8, bucket: String) raises -> O.FS:
    return opener.open_scan_fs(scheme, bucket)


def test_an_opened_file_system_reads_the_named_bucket() raises:
    var fs = _open(_Opener(_mk_lake), FS_SCHEME_GCS, "lake")
    assert_equal(fs.bucket(), "lake")
    assert_equal(fs.key_prefix(), "gs://lake/")
    assert_equal(fs.file_size("d/digits"), 10)
    var h = fs.open("d/digits")
    var buf = fs.read_at(h, 2, 3)
    var got = buf.view_range_ro(0, 3).into_span()
    assert_equal(Int(got[0]), ord("2"))
    assert_equal(Int(got[2]), ord("4"))


def test_two_buckets_have_two_key_prefixes() raises:
    var opener = _Opener(_mk_lake)
    var a = opener.open_scan_fs(FS_SCHEME_GCS, "lake")
    var b = opener.open_scan_fs(FS_SCHEME_GCS, "other")
    assert_equal(b.bucket(), "other")
    assert_equal(b.key_prefix(), "gs://other/")
    assert_true(a.key_prefix() != b.key_prefix())


def test_opening_builds_no_backend() raises:
    var fs = _Opener(_mk_refused).open_scan_fs(FS_SCHEME_GCS, "lake")
    assert_false(fs.backend_built())
    with assert_raises(contains="no backend here"):
        _ = fs.file_size("d/digits")
    # A clone builds its own backend on its first read, from the same
    # factory.
    var lake = _Opener(_mk_lake).open_scan_fs(FS_SCHEME_GCS, "lake")
    var clone = lake.clone()
    assert_false(clone.backend_built())
    assert_equal(clone.file_size("d/digits"), 10)
    assert_true(clone.backend_built())
    assert_false(lake.backend_built())


def _refusal(scheme: UInt8, bucket: String) raises -> String:
    try:
        _ = _Opener(_mk_lake).open_scan_fs(scheme, bucket)
    except e:
        return String(e)
    return String("not refused")


def test_another_scheme_is_refused() raises:
    assert_equal(
        _refusal(FS_SCHEME_S3, "lake"),
        "SCAN_FS_UNSERVED: no file system of this run reads s3://lake",
    )
    assert_equal(
        _refusal(FS_SCHEME_AZURE, "box"),
        "SCAN_FS_UNSERVED: no file system of this run reads az://box",
    )


def test_an_empty_bucket_is_refused() raises:
    assert_equal(
        _refusal(FS_SCHEME_GCS, ""),
        "SCAN_FS_UNSERVED: a GCS scan names no bucket",
    )


def main() raises:
    test_an_opened_file_system_reads_the_named_bucket()
    test_two_buckets_have_two_key_prefixes()
    test_opening_builds_no_backend()
    test_another_scheme_is_refused()
    test_an_empty_bucket_is_refused()
    print("OK")
