# `AzureScanFs`: the opener that turns a scan's container into an `AzureFs`.
#
# Rows: an opened file system, reached only through the `ScanFsOpener` trait,
# reads the container the scan names (a blob's size and bytes through the
# fake Blob service, signed with a Shared Key) and its key prefix is that
# container's URL, so two containers never share a cache key; opening builds
# no client (a connector factory that fails is first called by the first
# verb, and a clone builds its own); a scheme other than Azure and an empty
# container are refused with SCAN_FS_UNSERVED, word for word, and a name
# Azure would not accept as azure_fs_for refuses it. The fake keeps blobs in
# memory: no socket.
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from azure_blob import AzureClientSpec, AzureConfig, AzureCredential, AzureScanFs
from azure_core import AzureSharedKey
from fs.scan_fs import ScanFsOpener
from plan_expr.fs_descriptor_pod import FS_SCHEME_AZURE, FS_SCHEME_GCS, FS_SCHEME_S3

from komira_test_fake_azure import FakeAzureConnector

comptime _ACCOUNT = "devstoreaccount1"
comptime _FAKE_KEY = "VGhpcyBpcyBhIGZha2Uga2V5IGZvciB0ZXN0aW5nIDEyMzQ1Njc4OTAxMjMK"
comptime _Opener = AzureScanFs[FakeAzureConnector]


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _mk_box() raises -> FakeAzureConnector:
    var c = FakeAzureConnector()
    c.seed("box", "d/digits", _bytes("0123456789"))
    return c^


def _mk_refused() raises -> FakeAzureConnector:
    raise Error("no connector here")


def _opener(mk: def () raises thin -> FakeAzureConnector) raises -> _Opener:
    return _Opener(
        AzureClientSpec[FakeAzureConnector](
            AzureConfig.azurite(String(_ACCOUNT)),
            AzureCredential.shared_key(AzureSharedKey(String(_ACCOUNT), String(_FAKE_KEY))),
            mk,
        )
    )


def _open[O: ScanFsOpener](opener: O, scheme: UInt8, bucket: String) raises -> O.FS:
    return opener.open_scan_fs(scheme, bucket)


def test_an_opened_file_system_reads_the_named_container() raises:
    var fs = _open(_opener(_mk_box), FS_SCHEME_AZURE, "box")
    assert_equal(fs.container(), "box")
    assert_equal(fs.key_prefix(), "az://box/")
    assert_equal(fs.file_size("d/digits"), 10)
    var h = fs.open("d/digits")
    var buf = fs.read_at(h, 2, 3)
    var got = buf.view_range_ro(0, 3).into_span()
    assert_equal(Int(got[0]), ord("2"))
    assert_equal(Int(got[2]), ord("4"))
    var footer = fs.read_footer("d/digits", 4)
    assert_equal(footer.file_size, 10)


def test_two_containers_have_two_key_prefixes() raises:
    var opener = _opener(_mk_box)
    var a = opener.open_scan_fs(FS_SCHEME_AZURE, "box")
    var b = opener.open_scan_fs(FS_SCHEME_AZURE, "other")
    assert_equal(b.container(), "other")
    assert_equal(b.key_prefix(), "az://other/")
    assert_true(a.key_prefix() != b.key_prefix())
    # The other container does not hold box's blob.
    with assert_raises(contains="StoreError[NOT_FOUND] HEAD az://other/d/digits status=404"):
        _ = b.file_size("d/digits")


def test_opening_builds_no_client() raises:
    var fs = _opener(_mk_refused).open_scan_fs(FS_SCHEME_AZURE, "box")
    assert_false(fs.client_built())
    with assert_raises(contains="no connector here"):
        _ = fs.file_size("d/digits")
    # A clone builds its own client on its first verb, from the same spec.
    var box = _opener(_mk_box).open_scan_fs(FS_SCHEME_AZURE, "box")
    var clone = box.clone()
    assert_false(clone.client_built())
    assert_equal(clone.file_size("d/digits"), 10)
    assert_true(clone.client_built())
    assert_false(box.client_built())


def _refusal(scheme: UInt8, bucket: String) raises -> String:
    try:
        _ = _opener(_mk_box).open_scan_fs(scheme, bucket)
    except e:
        return String(e)
    return String("not refused")


def test_another_scheme_is_refused() raises:
    assert_equal(
        _refusal(FS_SCHEME_GCS, "raw"),
        "SCAN_FS_UNSERVED: no file system of this run reads gs://raw",
    )
    assert_equal(
        _refusal(FS_SCHEME_S3, "lake"),
        "SCAN_FS_UNSERVED: no file system of this run reads s3://lake",
    )


def test_an_empty_or_malformed_container_is_refused() raises:
    assert_equal(
        _refusal(FS_SCHEME_AZURE, ""),
        "SCAN_FS_UNSERVED: an Azure scan names no container",
    )
    assert_equal(
        _refusal(FS_SCHEME_AZURE, "Box"),
        "azure_url: 'Box' is not an Azure container name (3 to 63 lowercase"
        " letters, digits and single hyphens, starting and ending with a letter"
        " or digit, or $root, $web, $logs)",
    )


def main() raises:
    test_an_opened_file_system_reads_the_named_container()
    test_two_containers_have_two_key_prefixes()
    test_opening_builds_no_client()
    test_another_scheme_is_refused()
    test_an_empty_or_malformed_container_is_refused()
    print("OK")
