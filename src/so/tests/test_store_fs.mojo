# =============================================================================
# StoreFs and StoreScanFs: S3 and Azure Blob behind one file system, over the
# fakes (no socket, no network)
# =============================================================================
#
# Covers so/store_fs.mojo. Parquet bytes written with parquet_writer are
# seeded in komira_test_fake_s3 (FakeS3Connector) and komira_test_fake_azure
# (FakeAzureConnector); a StoreScanFs opens the file systems and each verb of
# the FileSystem trait is called through them.
#
# What each test proves:
#   * test_an_s3_bucket_reads_its_footer_size_and_bytes: read_footer, file_size,
#     open + read_at, read_ranges_prefetched and clone on an S3 bucket give the
#     bytes and size of the seeded Parquet file.
#   * test_an_azure_container_reads_its_footer_size_and_bytes: the same on an
#     Azure container.
#   * test_an_s3_bucket_lists_its_keys_and_directories: list, is_dir and
#     list_dir_shallow on S3.
#   * test_an_azure_listing_is_the_stores_answer: the Azure fake serves no
#     listing, so list, is_dir and list_dir_shallow raise the store's
#     NOT_FOUND through StoreFs unchanged.
#   * test_the_capabilities_and_key_prefix_name_the_store: key_prefix,
#     prefetch_depth, supports_random_read and the comptime flags of each store.
#   * test_an_s3_object_is_written_read_back_and_deleted: open_write, write_at,
#     close_write, file_size, delete, fsync_file and fsync_dir on S3; an
#     aborted write leaves no object; append, create-exclusive and pwrite_at
#     are refused as S3Fs refuses them.
#   * test_an_azure_container_refuses_writes_as_azure_does: open_write,
#     write_at, pwrite_at, close_write, abort_write, delete, fsync_file and
#     fsync_dir are Azure's own refusals, unchanged.
#   * test_a_handle_of_the_other_store_is_refused_by_name: a read or write
#     handle of one store given to the file system of another is
#     STORE_FS_HANDLE, for every verb that takes a handle, both ways (the GCS
#     arm's are test_gcs_binding's).
#   * test_an_opener_serves_the_buckets_it_was_told_of: serves and
#     open_scan_fs for S3 and Azure, and what they do not serve.
#   * test_an_opener_refuses_what_it_does_not_serve_word_for_word:
#     SCAN_FS_UNSERVED naming an unserved bucket, container, scheme, the empty
#     bucket and the local scheme, as LocalOnlyScanFs says it.
#   * test_a_bucket_added_twice_is_refused: STORE_FS_DUPLICATE for S3 and
#     Azure, and the first entry still serves.
#   * test_a_refused_add_serves_nothing: an S3 endpoint with another scheme, a
#     bad container name and a Shared Key of another account are refused and
#     the name is not served.
#   * test_each_bucket_signs_with_its_own_credential: two buckets of one
#     store, one signed with a key the store knows and one with another; the
#     second is PERMISSION_DENIED and its error holds no secret.
#   * test_an_https_endpoint_is_refused_by_a_connector_that_is_not_tls: a
#     bucket whose endpoint is https is read through the TLS factory (the
#     fake's connectors are plaintext), so the client refuses it.
#   * test_the_production_connectors_open_file_systems_without_dialing:
#     kernel_store_connectors serves an S3 and an Azure entry and opens them
#     with nothing dialed.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from arrow.string_array import StringArray
from aws_core import AwsCredential, FixedClock, SystemAwsClock
from azure_blob import (
    AzureCredential,
    AzureFsConfig,
    AzureWriteFile,
)
from azure_core import AzureSharedKey
from byte_buffer.heap_region import HeapRegion
from byte_buffer.shared_aligned_buffer import SharedAlignedBuffer
from fs.file_system import WriteMode
from http_client import KernelSchemeConnector
from objectstore_s3 import S3Config, S3WriteFile
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from plan_expr.fs_descriptor_pod import (
    FS_SCHEME_AZURE,
    FS_SCHEME_FILE,
    FS_SCHEME_GCS,
    FS_SCHEME_S3,
)

from komira_test_fake_azure import FakeAzureConnector
from komira_test_fake_s3 import FakeS3Connector
from objectstore_gcs import FakeGcsStorageBackend

from so.gcs_access import GcsAccess, KernelGcsBackend
from so.store_fs import (
    STORE_FS_HANDLE,
    StoreConnectors,
    StoreFs,
    StoreScanFs,
    StoreWriteFile,
    kernel_store_connectors,
)

comptime _Connectors = StoreConnectors[
    FakeS3Connector, FakeAzureConnector, FakeGcsStorageBackend, FixedClock
]
comptime _Opener = StoreScanFs[
    FakeS3Connector, FakeAzureConnector, FakeGcsStorageBackend, FixedClock
]
comptime _Fs = StoreFs[
    FakeS3Connector, FakeAzureConnector, FakeGcsStorageBackend, FixedClock
]

comptime _ACCOUNT = "devstoreaccount1"
comptime _FAKE_KEY = "VGhpcyBpcyBhIGZha2Uga2V5IGZvciB0ZXN0aW5nIDEyMzQ1Njc4OTAxMjMK"
comptime _SECRET = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
comptime _KEY_ID = "AKIDLAKE"


# ---- the data ---------------------------------------------------------------


def _batch(first: Int, n: Int) raises -> RecordBatch:
    """Rows id = first .. first + n - 1 with s = "s" + id % 3."""
    var ids = PrimitiveArray[DType.int64].allocate(n)
    var strs = List[String]()
    for i in range(n):
        ids.set(i, Int64(first + i))
        strs.append(String("s") + String((first + i) % 3))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    rb.add_column(Column.from_primitive[DType.int64](ids^))
    sb.add_field(Field("s", ArrowType.STRING, False))
    rb.add_column(Column.from_string(StringArray.from_strings(strs)))
    return rb.build(sb.build())


def _bytes_a() raises -> List[UInt8]:
    return write_record_batch_to_parquet_bytes(_batch(0, 40), max_rows_per_rg=7)


def _bytes_b() raises -> List[UInt8]:
    return write_record_batch_to_parquet_bytes(_batch(100, 9), max_rows_per_rg=4)


def _text_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


# ---- the stores -------------------------------------------------------------


def _mk_s3() raises -> FakeS3Connector:
    """Buckets `lake` and `plus`: t/a.parquet and t/b.parquet; bucket
    `denied`: t/a.parquet. Requests must be signed with key id AKIDLAKE."""
    var c = FakeS3Connector(key_id=_KEY_ID)
    c.seed_bytes("t/a.parquet", _bytes_a())
    c.seed_bytes("t/b.parquet", _bytes_b())
    c.seed_in("plus", "t/a.parquet", _bytes_a())
    c.seed_in("denied", "t/a.parquet", _bytes_a())
    return c^


def _mk_s3_tls() raises -> FakeS3Connector:
    return FakeS3Connector()


def _mk_azure() raises -> FakeAzureConnector:
    """Container `box`: t/a.parquet and t/b.parquet."""
    var c = FakeAzureConnector()
    c.seed("box", "t/a.parquet", _bytes_a())
    c.seed("box", "t/b.parquet", _bytes_b())
    return c^


def _mk_azure_tls() raises -> FakeAzureConnector:
    return FakeAzureConnector()


def _mk_gcs(access: GcsAccess) raises -> FakeGcsStorageBackend:
    """An empty bucket: the GCS arm is test_gcs_binding's."""
    return FakeGcsStorageBackend()


def _connectors() -> _Connectors:
    return _Connectors(
        _mk_s3,
        _mk_s3_tls,
        _mk_azure,
        _mk_azure_tls,
        _mk_gcs,
        FixedClock(1790000000),
    )


def _aws(key_id: String) -> AwsCredential:
    return AwsCredential(key_id, String(_SECRET), String(""))


def _s3_config() raises -> S3Config:
    return S3Config.custom_endpoint("us-east-1", "http://127.0.0.1:9000")


def _az_config() -> AzureFsConfig:
    return AzureFsConfig(String(_ACCOUNT), String("http://127.0.0.1:10000"), True)


def _az_credential() raises -> AzureCredential:
    return AzureCredential.shared_key(
        AzureSharedKey(String(_ACCOUNT), String(_FAKE_KEY))
    )


def _opener() raises -> _Opener:
    """S3 buckets `lake` and `plus` signed with the key the fake knows, and
    `denied` signed with another; Azure container `box`."""
    var o = _Opener(_connectors())
    o.add_s3("lake", _s3_config(), _aws(_KEY_ID))
    o.add_s3("plus", _s3_config(), _aws(_KEY_ID))
    o.add_s3("denied", _s3_config(), _aws("AKIDWRONG"))
    o.add_azure("box", _az_config(), _az_credential())
    return o^


def _s3() raises -> _Fs:
    return _opener().open_scan_fs(FS_SCHEME_S3, "lake")


def _azure() raises -> _Fs:
    return _opener().open_scan_fs(FS_SCHEME_AZURE, "box")


def _u8(ref buf: SharedAlignedBuffer[HeapRegion], at: Int) -> Int:
    return Int(buf.read_u8_at(at))


def _handle_refusal(verb: String) -> String:
    return (
        String(STORE_FS_HANDLE)
        + ": StoreFs."
        + verb
        + " was given a handle of another object store"
    )


def _one_range() -> List[Tuple[Int64, Int64]]:
    var r = List[Tuple[Int64, Int64]]()
    r.append((Int64(0), Int64(4)))
    return r^


# ---- reading ----------------------------------------------------------------


def _check_reads(fs: _Fs, size: Int) raises:
    """The footer, the size, a read at an offset, ranged reads and a clone of
    `fs` over `t/a.parquet` hold the file's bytes."""
    var footer = fs.read_footer("t/a.parquet", 64 * 1024)
    assert_equal(footer.file_size, size)
    assert_equal(footer.offset + footer.len(), size)
    assert_equal(Int(footer.bytes[footer.len() - 1]), 49)  # "PAR1" ends the file
    assert_equal(fs.file_size("t/a.parquet"), size)
    var f = fs.open("t/a.parquet")
    var head = fs.read_at(f, 0, 4)
    assert_equal(head.len(), 4)
    assert_equal(_u8(head, 0), 80)
    assert_equal(_u8(head, 1), 65)
    assert_equal(_u8(head, 2), 82)
    assert_equal(_u8(head, 3), 49)
    var ranges = _one_range()
    ranges.append((Int64(size - 4), Int64(4)))
    var got = fs.read_ranges_prefetched(f, ranges)
    assert_equal(len(got), 2)
    assert_equal(_u8(got[0], 0), 80)
    assert_equal(_u8(got[1], 3), 49)
    var copy = fs.clone()
    assert_equal(copy.file_size("t/a.parquet"), size)
    assert_equal(copy.key_prefix(), fs.key_prefix())


def test_an_s3_bucket_reads_its_footer_size_and_bytes() raises:
    _check_reads(_s3(), len(_bytes_a()))
    with assert_raises(contains="StoreError[NOT_FOUND] HeadObject s3://lake/t/absent status=404"):
        _ = _s3().file_size("t/absent")


def test_an_azure_container_reads_its_footer_size_and_bytes() raises:
    _check_reads(_azure(), len(_bytes_a()))
    with assert_raises(contains="NOT_FOUND"):
        _ = _azure().file_size("t/absent")


# ---- listing ----------------------------------------------------------------


def test_an_s3_bucket_lists_its_keys_and_directories() raises:
    var fs = _s3()
    var keys = fs.list("t/")
    assert_equal(len(keys), 2)
    assert_equal(keys[0], "t/a.parquet")
    assert_equal(keys[1], "t/b.parquet")
    assert_true(fs.is_dir("t"))
    assert_false(fs.is_dir("nothing"))
    var shallow = fs.list_dir_shallow("t/")
    assert_equal(len(shallow), 2)
    assert_equal(shallow[0].name, "a.parquet")
    assert_false(shallow[0].is_dir)
    assert_equal(shallow[1].name, "b.parquet")
    assert_false(shallow[1].is_dir)
    var root = fs.list_dir_shallow("")
    assert_equal(len(root), 1)
    assert_equal(root[0].name, "t")
    assert_true(root[0].is_dir)


def test_an_azure_listing_is_the_stores_answer() raises:
    var fs = _azure()
    with assert_raises(contains="StoreError[NOT_FOUND]"):
        _ = fs.list("t/")
    with assert_raises(contains="StoreError[NOT_FOUND]"):
        _ = fs.is_dir("t")
    with assert_raises(contains="StoreError[NOT_FOUND]"):
        _ = fs.list_dir_shallow("t/")


# ---- capabilities -----------------------------------------------------------


def test_the_capabilities_and_key_prefix_name_the_store() raises:
    var s3 = _s3()
    var az = _azure()
    assert_equal(s3.key_prefix(), "s3://lake/")
    assert_equal(az.key_prefix(), "az://box/")
    assert_equal(s3.prefetch_depth(), 64)
    assert_equal(az.prefetch_depth(), 64)
    assert_true(s3.supports_random_read())
    assert_true(az.supports_random_read())
    assert_false(_Fs.SUPPORTS_PARALLEL_WRITES)
    assert_false(_Fs.IS_MMAP_BACKED)
    assert_false(_Fs.SUPPORTS_LAZY_HIVE)


# ---- writing ----------------------------------------------------------------


def test_an_s3_object_is_written_read_back_and_deleted() raises:
    var fs = _s3()
    var w = fs.open_write("w/out", WriteMode.create_truncate())
    assert_equal(fs.write_at(w, Span(_text_bytes("hello, "))), 7)
    assert_equal(fs.write_at(w, Span(_text_bytes("world"))), 5)
    fs.close_write(w^)
    assert_equal(fs.file_size("w/out"), 12)
    fs.fsync_file("w/out")
    fs.fsync_dir("w")
    fs.delete("w/out")
    with assert_raises(contains="StoreError[NOT_FOUND] HeadObject s3://lake/w/out status=404"):
        _ = fs.file_size("w/out")
    # An aborted write leaves no object.
    var a = fs.open_write("w/aborted", WriteMode.create_truncate())
    _ = fs.write_at(a, Span(_text_bytes("x")))
    fs.abort_write(a^)
    with assert_raises(contains="StoreError[NOT_FOUND] HeadObject s3://lake/w/aborted status=404"):
        _ = fs.file_size("w/aborted")
    # What S3Fs does not serve is S3Fs's refusal.
    with assert_raises(contains="an S3 object cannot be appended to"):
        _ = fs.open_write("w/out", WriteMode.append())
    with assert_raises(contains="WriteMode.create_exclusive is not supported"):
        _ = fs.open_write("w/out", WriteMode.create_exclusive())
    var p = fs.open_write("w/p", WriteMode.create_truncate())
    with assert_raises(contains="S3Fs.pwrite_at: S3 has no disjoint-range concurrent write"):
        _ = fs.pwrite_at(p, 0, Span(_text_bytes("x")))


def test_an_azure_container_refuses_writes_as_azure_does() raises:
    var fs = _azure()
    with assert_raises(contains="AzureFs.open_write: AzureFs is read-only"):
        _ = fs.open_write("w/out", WriteMode.create_truncate())
    var w = StoreWriteFile.of_azure(AzureWriteFile(String("w/out")))
    with assert_raises(contains="AzureFs.write_at: AzureFs is read-only"):
        _ = fs.write_at(w, Span(_text_bytes("x")))
    with assert_raises(contains="AzureFs.pwrite_at: Azure block-blob does not support"):
        _ = fs.pwrite_at(w, 0, Span(_text_bytes("x")))
    with assert_raises(contains="AzureFs.close_write: AzureFs is read-only"):
        fs.close_write(StoreWriteFile.of_azure(AzureWriteFile(String("w/out"))))
    with assert_raises(contains="FileSystem.abort_write: unimplemented"):
        fs.abort_write(StoreWriteFile.of_azure(AzureWriteFile(String("w/out"))))
    with assert_raises(contains="FileSystem.delete: unimplemented"):
        fs.delete("w/out")
    with assert_raises(contains="FileSystem.fsync_file: unimplemented"):
        fs.fsync_file("w/out")
    with assert_raises(contains="FileSystem.fsync_dir: unimplemented"):
        fs.fsync_dir("w")


# ---- handles of the other store ----------------------------------------------


def test_a_handle_of_the_other_store_is_refused_by_name() raises:
    var s3 = _s3()
    var az = _azure()
    var s3_file = s3.open("t/a.parquet")
    var az_file = az.open("t/a.parquet")
    with assert_raises(contains=_handle_refusal("read_at")):
        _ = s3.read_at(az_file, 0, 4)
    with assert_raises(contains=_handle_refusal("read_at")):
        _ = az.read_at(s3_file, 0, 4)
    with assert_raises(contains=_handle_refusal("read_ranges_prefetched")):
        _ = s3.read_ranges_prefetched(az_file, _one_range())
    with assert_raises(contains=_handle_refusal("read_ranges_prefetched")):
        _ = az.read_ranges_prefetched(s3_file, _one_range())
    var s3_write = s3.open_write("w/x", WriteMode.create_truncate())
    var az_write = StoreWriteFile.of_azure(AzureWriteFile(String("w/x")))
    with assert_raises(contains=_handle_refusal("write_at")):
        _ = s3.write_at(az_write, Span(_text_bytes("x")))
    with assert_raises(contains=_handle_refusal("write_at")):
        _ = az.write_at(s3_write, Span(_text_bytes("x")))
    with assert_raises(contains=_handle_refusal("pwrite_at")):
        _ = s3.pwrite_at(az_write, 0, Span(_text_bytes("x")))
    with assert_raises(contains=_handle_refusal("pwrite_at")):
        _ = az.pwrite_at(s3_write, 0, Span(_text_bytes("x")))
    with assert_raises(contains=_handle_refusal("close_write")):
        s3.close_write(StoreWriteFile.of_azure(AzureWriteFile(String("w/x"))))
    with assert_raises(contains=_handle_refusal("close_write")):
        az.close_write(StoreWriteFile.of_s3(S3WriteFile(String("w/x"))))
    with assert_raises(contains=_handle_refusal("abort_write")):
        s3.abort_write(StoreWriteFile.of_azure(AzureWriteFile(String("w/x"))))
    with assert_raises(contains=_handle_refusal("abort_write")):
        az.abort_write(StoreWriteFile.of_s3(S3WriteFile(String("w/x"))))


# ---- the opener -------------------------------------------------------------


def test_an_opener_serves_the_buckets_it_was_told_of() raises:
    var o = _opener()
    assert_true(o.serves(FS_SCHEME_S3, "lake"))
    assert_true(o.serves(FS_SCHEME_S3, "plus"))
    assert_true(o.serves(FS_SCHEME_AZURE, "box"))
    assert_false(o.serves(FS_SCHEME_S3, "box"))
    assert_false(o.serves(FS_SCHEME_AZURE, "lake"))
    assert_false(o.serves(FS_SCHEME_S3, "nowhere"))
    assert_false(o.serves(FS_SCHEME_AZURE, "nowhere"))
    assert_false(o.serves(FS_SCHEME_GCS, "lake"))
    assert_false(o.serves(FS_SCHEME_FILE, ""))
    assert_equal(o.open_scan_fs(FS_SCHEME_S3, "plus").key_prefix(), "s3://plus/")
    assert_equal(o.open_scan_fs(FS_SCHEME_AZURE, "box").key_prefix(), "az://box/")
    # An opener told of nothing serves nothing.
    var empty = _Opener(_connectors())
    assert_false(empty.serves(FS_SCHEME_S3, "lake"))
    assert_false(empty.serves(FS_SCHEME_AZURE, "box"))


def test_an_opener_refuses_what_it_does_not_serve_word_for_word() raises:
    var o = _opener()
    with assert_raises(contains="SCAN_FS_UNSERVED: no file system of this run reads s3://nowhere"):
        _ = o.open_scan_fs(FS_SCHEME_S3, "nowhere")
    with assert_raises(contains="SCAN_FS_UNSERVED: no file system of this run reads s3://"):
        _ = o.open_scan_fs(FS_SCHEME_S3, "")
    with assert_raises(contains="SCAN_FS_UNSERVED: no file system of this run reads az://nowhere"):
        _ = o.open_scan_fs(FS_SCHEME_AZURE, "nowhere")
    with assert_raises(contains="SCAN_FS_UNSERVED: no file system of this run reads gs://raw"):
        _ = o.open_scan_fs(FS_SCHEME_GCS, "raw")
    with assert_raises(contains="SCAN_FS_UNSERVED: no file system of this run reads file://"):
        _ = o.open_scan_fs(FS_SCHEME_FILE, "")


def test_a_bucket_added_twice_is_refused() raises:
    var o = _opener()
    with assert_raises(
        contains="STORE_FS_DUPLICATE: s3://lake is already served by this run's file systems"
    ):
        o.add_s3("lake", _s3_config(), _aws(_KEY_ID))
    with assert_raises(
        contains="STORE_FS_DUPLICATE: az://box is already served by this run's file systems"
    ):
        o.add_azure("box", _az_config(), _az_credential())
    # The first entry still serves.
    assert_equal(_check_size(o.open_scan_fs(FS_SCHEME_S3, "lake")), len(_bytes_a()))
    assert_equal(_check_size(o.open_scan_fs(FS_SCHEME_AZURE, "box")), len(_bytes_a()))


def _check_size(fs: _Fs) raises -> Int:
    return fs.file_size("t/a.parquet")


def test_a_refused_add_serves_nothing() raises:
    var o = _Opener(_connectors())
    with assert_raises(
        contains="s3_endpoint: an S3 endpoint must start with http:// or https://, got 'ftp://store.example.com'"
    ):
        o.add_s3(
            "lake",
            S3Config.custom_endpoint("us-east-1", "ftp://store.example.com"),
            _aws(_KEY_ID),
        )
    assert_false(o.serves(FS_SCHEME_S3, "lake"))
    with assert_raises(contains="is not an Azure container name"):
        o.add_azure("NOT_A_CONTAINER", _az_config(), _az_credential())
    assert_false(o.serves(FS_SCHEME_AZURE, "NOT_A_CONTAINER"))
    with assert_raises(contains="the shared key is for account"):
        o.add_azure(
            "box",
            AzureFsConfig(String("otheraccount"), String("http://127.0.0.1:10000"), True),
            _az_credential(),
        )
    assert_false(o.serves(FS_SCHEME_AZURE, "box"))
    # Refused adds leave the names free to add.
    o.add_s3("lake", _s3_config(), _aws(_KEY_ID))
    assert_true(o.serves(FS_SCHEME_S3, "lake"))


# ---- credentials ------------------------------------------------------------


def test_each_bucket_signs_with_its_own_credential() raises:
    var o = _opener()
    assert_equal(_check_size(o.open_scan_fs(FS_SCHEME_S3, "lake")), len(_bytes_a()))
    assert_equal(_check_size(o.open_scan_fs(FS_SCHEME_S3, "plus")), len(_bytes_a()))
    var message = String("")
    try:
        _ = _check_size(o.open_scan_fs(FS_SCHEME_S3, "denied"))
    except e:
        message = String(e)
    assert_true(message.find("PERMISSION_DENIED") >= 0)
    assert_equal(message.find(_SECRET), -1)


def test_an_https_endpoint_is_refused_by_a_connector_that_is_not_tls() raises:
    var o = _Opener(_connectors())
    o.add_s3(
        "lake",
        S3Config.custom_endpoint("us-east-1", "https://127.0.0.1:9443"),
        _aws(_KEY_ID),
    )
    o.add_azure(
        "box",
        AzureFsConfig(String(_ACCOUNT), String("https://127.0.0.1:10443"), True),
        _az_credential(),
    )
    var s3 = o.open_scan_fs(FS_SCHEME_S3, "lake")
    var message = String("")
    try:
        _ = s3.file_size("t/a.parquet")
    except e:
        message = String(e)
    assert_true(message.byte_length() > 0)
    var az = o.open_scan_fs(FS_SCHEME_AZURE, "box")
    message = String("")
    try:
        _ = az.file_size("t/a.parquet")
    except e:
        message = String(e)
    assert_true(message.byte_length() > 0)


def test_the_production_connectors_open_file_systems_without_dialing() raises:
    var o = StoreScanFs[
        KernelSchemeConnector,
        KernelSchemeConnector,
        KernelGcsBackend,
        SystemAwsClock,
    ](kernel_store_connectors())
    o.add_s3("lake", S3Config.aws("us-east-1"), _aws(_KEY_ID))
    o.add_s3("local", _s3_config(), _aws(_KEY_ID))
    o.add_azure("box", AzureFsConfig.azure(String(_ACCOUNT)), AzureCredential.anonymous())
    assert_equal(o.open_scan_fs(FS_SCHEME_S3, "lake").key_prefix(), "s3://lake/")
    assert_equal(o.open_scan_fs(FS_SCHEME_S3, "local").key_prefix(), "s3://local/")
    assert_equal(o.open_scan_fs(FS_SCHEME_AZURE, "box").key_prefix(), "az://box/")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
