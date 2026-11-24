# `scan_fs`: the opener a scan on a store other than the local disk is read
# through, its refusal, and the cache key prefix every file system names.
#
# Rows: the refusal names its code and the store, word for word; the local
# file system's key prefix is empty, so a shared cache keys a local file by
# its path alone; a generic caller reaches an opener only through the trait,
# gets a file system of the opener's `FS` type that reads, and gets the
# opener's refusal for a scheme it does not serve.
from std.testing import assert_equal, assert_true

from async_rt.ops.waker_sink import NoopSink
from fs.local_fs import LocalFs
from fs.scan_fs import SCAN_FS_UNSERVED, ScanFsOpener, scan_fs_unserved
from runtime_paths import test_tmpdir


struct _LocalOpener(ScanFsOpener):
    """Serves scheme 0 only, over the local file system."""

    comptime FS = LocalFs[NoopSink]

    def __init__(out self):
        pass

    def open_scan_fs(self, scheme: UInt8, bucket: String) raises -> Self.FS:
        if scheme != 0:
            raise scan_fs_unserved("scheme " + String(Int(scheme)) + "://" + bucket)
        return LocalFs[NoopSink].new()


def _open[O: ScanFsOpener](opener: O, scheme: UInt8, bucket: String) raises -> O.FS:
    return opener.open_scan_fs(scheme, bucket)


def test_the_refusal_names_its_code_and_the_store() raises:
    assert_equal(
        String(scan_fs_unserved("s3://lake")),
        "SCAN_FS_UNSERVED: no file system of this run reads s3://lake",
    )
    assert_equal(String(SCAN_FS_UNSERVED), "SCAN_FS_UNSERVED")


def test_the_local_key_prefix_is_empty() raises:
    assert_equal(LocalFs[NoopSink].new().key_prefix(), "")


def test_a_generic_caller_opens_through_the_trait() raises:
    var path = test_tmpdir() + "/scan_fs_opened.bin"
    with open(path, "w") as fh:
        fh.write("komira")
    var fs = _open(_LocalOpener(), 0, "")
    assert_equal(fs.file_size(path), 6)


def test_a_scheme_the_opener_does_not_serve_is_refused() raises:
    var refused = False
    try:
        _ = _open(_LocalOpener(), 1, "lake")
    except e:
        assert_equal(
            String(e),
            "SCAN_FS_UNSERVED: no file system of this run reads scheme 1://lake",
        )
        refused = True
    assert_true(refused)


def main() raises:
    test_the_refusal_names_its_code_and_the_store()
    test_the_local_key_prefix_is_empty()
    test_a_generic_caller_opens_through_the_trait()
    test_a_scheme_the_opener_does_not_serve_is_refused()
    print("OK")
