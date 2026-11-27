# =============================================================================
# StoreFs's GCS arm and the access of a GCS bucket, over a fake GCS store
# =============================================================================
#
# Covers so/store_fs.mojo's GCS arm and so/gcs_access.mojo. The store is
# objectstore_gcs's in-memory FakeGcsStorageBackend behind `_Buckets` below,
# which StoreConnectors' GCS factory builds from a bucket's GcsAccess as the
# production factory builds the gRPC backend: bucket `raw` (t/a.parquet,
# t/b.parquet, u/c.parquet) is served only at Google's endpoint and bucket
# `emu` (t/a.parquet, holding c's rows) only at the emulator's
# (https://gcs.emulator.test:4443); a backend built with any token but _TOKEN
# refuses every verb as the service refuses an unauthenticated call, and a
# bucket asked of an endpoint that does not serve it is not found. S3 is
# komira_test_fake_s3 (bucket `lake`, key AKIDRIGHT). No socket is opened, and
# no name is resolved. The gs:// binding is test_gcs_binding's.
#
# What each test holds:
#   * test_a_gcs_bucket_reads_its_footer_size_and_bytes: read_footer,
#     file_size, open + read_at, read_ranges_prefetched and a clone of a
#     StoreFs on bucket `raw` give the seeded file's bytes and size; an absent
#     object is the store's NOT_FOUND.
#   * test_a_gcs_bucket_lists_its_keys_and_directories: list, is_dir and
#     list_dir_shallow through StoreFs.
#   * test_a_gcs_bucket_names_its_store_and_refuses_writes: key_prefix,
#     prefetch_depth and supports_random_read; every write verb, delete and
#     fsync are GcsFs's own refusals, unchanged.
#   * test_a_handle_of_another_store_is_refused_by_name: a GCS handle given to
#     an S3 file system and an S3 handle given to a GCS one are
#     STORE_FS_HANDLE, for every verb that takes a handle.
#   * test_an_opener_serves_the_gcs_buckets_it_was_told_of: serves and
#     open_scan_fs for GCS, SCAN_FS_UNSERVED word for word for a bucket it was
#     not told of, STORE_FS_DUPLICATE for a bucket added twice.
#   * test_each_gcs_bucket_reads_with_its_own_token_and_endpoint: the token
#     and the endpoint of each bucket reach its backend: a wrong token is
#     PERMISSION_DENIED word for word, holding no token, and a bucket at an
#     endpoint that does not serve it is NOT_FOUND.
#   * test_an_endpoint_is_https_host_and_port: what GcsAccess.at reads (the
#     default, a port, a final `/`, the scheme in any case, ports 1 and
#     65535) and every refusal of gcs_endpoint_refusal word for word, none
#     echoing the endpoint.
#   * test_the_backend_is_built_on_its_first_verb: LazyGcsBackend builds
#     nothing until a verb, passes all six verbs through, and keeps nothing
#     when its factory fails; GcsFs's own clone factory is refused by name.
#   * test_the_production_backend_is_built_without_dialing: kernel_gcs_backend
#     carries the token and the transport bound, and kernel_store_connectors
#     opens a GCS file system and its clone with nothing dialed.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from aws_core import AwsCredential, FixedClock, SystemAwsClock
from byte_buffer.heap_region import HeapRegion
from byte_buffer.shared_aligned_buffer import SharedAlignedBuffer
from fs.file_system import WriteMode
from http_client import KernelSchemeConnector
from http_client.client import HttpClientConfig
from objectstore_gcs import (
    GCS_GRPC_HOST,
    GCS_GRPC_PORT,
    FakeGcsStorageBackend,
    GcsFileHandle,
    GcsStorageBackend,
    GcsWriteFile,
    ListPageRaw,
    ObjectMetaRaw,
)
from objectstore_s3 import S3Config, S3WriteFile
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from plan_expr.fs_descriptor_pod import FS_SCHEME_GCS, FS_SCHEME_S3

from komira_test_fake_azure import FakeAzureConnector
from komira_test_fake_s3 import FakeS3Connector
from so import (
    GcsAccess,
    KernelGcsBackend,
    LazyGcsBackend,
    StoreConnectors,
    StoreFile,
    StoreFs,
    StoreScanFs,
    StoreWriteFile,
    gcs_endpoint_refusal,
    kernel_gcs_backend,
    kernel_store_connectors,
)
from so.gcs_access import _refuse_gcs_clone

comptime _TOKEN = "ya29.fake-token-the-store-answers"
comptime _WRONG_TOKEN = "ya29.fake-token-the-store-refuses"
comptime _EMU = "https://gcs.emulator.test:4443"
comptime _EMU_HOST = "gcs.emulator.test"
comptime _EMU_PORT: UInt16 = 4443
comptime _KEY_ID = "AKIDRIGHT"
comptime _SECRET = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"


# ---- the data ----------------------------------------------------------------


def _batch(first: Int, n: Int) raises -> RecordBatch:
    """Rows id = first .. first + n - 1."""
    var ids = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        ids.set(i, Int64(first + i))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    rb.add_column(Column.from_primitive[DType.int64](ids^))
    return rb.build(sb.build())


def _bytes_a() raises -> List[UInt8]:
    """40 rows from id 0, in row groups of 7."""
    return write_record_batch_to_parquet_bytes(_batch(0, 40), max_rows_per_rg=7)


def _bytes_b() raises -> List[UInt8]:
    """9 rows from id 100."""
    return write_record_batch_to_parquet_bytes(_batch(100, 9), max_rows_per_rg=4)


def _bytes_c() raises -> List[UInt8]:
    """3 rows from id 500."""
    return write_record_batch_to_parquet_bytes(_batch(500, 3), max_rows_per_rg=4)


def _text(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


# ---- the GCS store -------------------------------------------------------------


struct _Buckets(GcsStorageBackend, Movable, Deinitable):
    """Bucket `raw` (t/a.parquet, t/b.parquet, u/c.parquet) at Google's
    endpoint and bucket `emu` (t/a.parquet, holding c's rows) at the
    emulator's, in a FakeGcsStorageBackend (the fake models one bucket). A
    backend built with any token but _TOKEN refuses every verb as the
    service refuses an unauthenticated call, and a bucket its endpoint does
    not serve is not found."""

    var _store: FakeGcsStorageBackend
    var _bucket: String
    var _authorized: Bool

    def __init__(out self, access: GcsAccess) raises:
        var store = FakeGcsStorageBackend()
        var bucket = String("")
        if access.host == GCS_GRPC_HOST and access.port == GCS_GRPC_PORT:
            bucket = String("raw")
            _ = store.conditional_create(bucket, "t/a.parquet", _bytes_a())
            _ = store.conditional_create(bucket, "t/b.parquet", _bytes_b())
            _ = store.conditional_create(bucket, "u/c.parquet", _bytes_c())
        elif access.host == _EMU_HOST and access.port == _EMU_PORT:
            bucket = String("emu")
            _ = store.conditional_create(bucket, "t/a.parquet", _bytes_c())
        self._store = store^
        self._bucket = bucket^
        self._authorized = access.token == _TOKEN

    def _check(self, method: String, bucket: String, key: String) raises:
        if not self._authorized:
            raise Error(
                String("StoreError[PERMISSION_DENIED] ") + method + " gs://"
                + bucket + "/" + key + " status=403 grpc_code=16 (UNAUTHENTICATED)"
            )
        if bucket != self._bucket:
            raise Error(
                String("StoreError[NOT_FOUND] ") + method + " gs://" + bucket
                + "/" + key + " status=404 grpc_code=5 (NOT_FOUND)"
            )

    def conditional_create(
        mut self, bucket: String, key: String, data: List[UInt8]
    ) raises -> Int64:
        self._check("WriteObject", bucket, key)
        return self._store.conditional_create(bucket, key, data)

    def compare_and_swap(
        mut self,
        bucket: String,
        key: String,
        data: List[UInt8],
        expected_generation: Int64,
    ) raises -> Int64:
        self._check("WriteObject", bucket, key)
        return self._store.compare_and_swap(bucket, key, data, expected_generation)

    def read_range(
        mut self,
        bucket: String,
        key: String,
        read_offset: Int64,
        read_limit: Int64,
    ) raises -> List[UInt8]:
        self._check("ReadObject", bucket, key)
        return self._store.read_range(bucket, key, read_offset, read_limit)

    def get_object(mut self, bucket: String, key: String) raises -> ObjectMetaRaw:
        self._check("GetObject", bucket, key)
        return self._store.get_object(bucket, key)

    def delete_object(mut self, bucket: String, key: String) raises:
        self._check("DeleteObject", bucket, key)
        self._store.delete_object(bucket, key)

    def list_objects(
        mut self,
        bucket: String,
        prefix: String,
        page_token: String,
        delimiter: String = String(""),
    ) raises -> ListPageRaw:
        self._check("ListObjects", bucket, prefix)
        return self._store.list_objects(bucket, prefix, page_token, delimiter)


comptime _Connectors = StoreConnectors[
    FakeS3Connector, FakeAzureConnector, _Buckets, FixedClock
]
comptime _Opener = StoreScanFs[
    FakeS3Connector, FakeAzureConnector, _Buckets, FixedClock
]
comptime _Fs = StoreFs[FakeS3Connector, FakeAzureConnector, _Buckets, FixedClock]


def _mk_gcs(access: GcsAccess) raises -> _Buckets:
    return _Buckets(access)


def _mk_refused(access: GcsAccess) raises -> _Buckets:
    raise Error("test: no backend is built here")


def _mk_s3() raises -> FakeS3Connector:
    """Bucket `lake`: t/a.parquet and t/b.parquet, signed with AKIDRIGHT."""
    var c = FakeS3Connector(key_id=_KEY_ID)
    c.seed_bytes("t/a.parquet", _bytes_a())
    c.seed_bytes("t/b.parquet", _bytes_b())
    return c^


def _mk_azure() raises -> FakeAzureConnector:
    return FakeAzureConnector()


def _connectors() -> _Connectors:
    return _Connectors(
        _mk_s3, _mk_s3, _mk_azure, _mk_azure, _mk_gcs, FixedClock(1790000000)
    )


def _opener() raises -> _Opener:
    """GCS bucket `raw` at Google's endpoint and `emu` at the emulator's,
    both with the right token, and S3 bucket `lake`."""
    var o = _Opener(_connectors())
    o.add_gcs("raw", GcsAccess.at("", _TOKEN))
    o.add_gcs("emu", GcsAccess.at(_EMU, _TOKEN))
    o.add_s3(
        "lake",
        S3Config.custom_endpoint("us-east-1", "http://127.0.0.1:9000"),
        AwsCredential(String(_KEY_ID), String(_SECRET), String("")),
    )
    return o^


def _gcs() raises -> _Fs:
    return _opener().open_scan_fs(FS_SCHEME_GCS, "raw")


def _u8(ref buf: SharedAlignedBuffer[HeapRegion], at: Int) -> Int:
    return Int(buf.read_u8_at(at))


def _one_range() -> List[Tuple[Int64, Int64]]:
    var r = List[Tuple[Int64, Int64]]()
    r.append((Int64(0), Int64(4)))
    return r^


def _refusal_of_handle(verb: String) -> String:
    return (
        "STORE_FS_HANDLE: StoreFs." + verb
        + " was given a handle of another object store"
    )


# ---- StoreFs over a GCS bucket ---------------------------------------------------


def test_a_gcs_bucket_reads_its_footer_size_and_bytes() raises:
    var fs = _gcs()
    var size = len(_bytes_a())
    var footer = fs.read_footer("t/a.parquet", 64 * 1024)
    assert_equal(footer.file_size, size)
    assert_equal(footer.offset + footer.len(), size)
    assert_equal(Int(footer.bytes[footer.len() - 1]), 49)  # "PAR1" ends the file
    assert_equal(fs.file_size("t/a.parquet"), size)
    var f = fs.open("t/a.parquet")
    var head = fs.read_at(f, 0, 4)
    assert_equal(head.len(), 4)
    assert_equal(_u8(head, 0), 80)
    assert_equal(_u8(head, 3), 49)
    var ranges = _one_range()
    ranges.append((Int64(size - 4), Int64(4)))
    var got = fs.read_ranges_prefetched(f, ranges)
    assert_equal(len(got), 2)
    assert_equal(_u8(got[0], 1), 65)
    assert_equal(_u8(got[1], 3), 49)
    var copy = fs.clone()
    assert_equal(copy.file_size("t/a.parquet"), size)
    assert_equal(copy.key_prefix(), "gs://raw/")
    with assert_raises(
        contains="StoreError[NOT_FOUND] GetObject gs://raw/t/absent status=404"
    ):
        _ = fs.file_size("t/absent")


def test_a_gcs_bucket_lists_its_keys_and_directories() raises:
    var fs = _gcs()
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
    var root = fs.list_dir_shallow("")
    assert_equal(len(root), 2)
    assert_equal(root[0].name, "t")
    assert_true(root[0].is_dir)
    assert_equal(root[1].name, "u")


def test_a_gcs_bucket_names_its_store_and_refuses_writes() raises:
    var fs = _gcs()
    assert_equal(fs.key_prefix(), "gs://raw/")
    assert_equal(fs.prefetch_depth(), 64)
    assert_true(fs.supports_random_read())
    with assert_raises(contains="GcsFs.open_write: GcsFs does not write. path=w/out"):
        _ = fs.open_write("w/out", WriteMode.create_truncate())
    var w = StoreWriteFile.of_gcs(GcsWriteFile(String("w/out")))
    with assert_raises(contains="GcsFs.write_at: GcsFs does not write."):
        _ = fs.write_at(w, Span(_text("x")))
    with assert_raises(contains="GcsFs.pwrite_at: GCS has no disjoint-range concurrent write"):
        _ = fs.pwrite_at(w, 0, Span(_text("x")))
    with assert_raises(contains="GcsFs.close_write: GcsFs does not write."):
        fs.close_write(StoreWriteFile.of_gcs(GcsWriteFile(String("w/out"))))
    with assert_raises(contains="FileSystem.abort_write: unimplemented"):
        fs.abort_write(StoreWriteFile.of_gcs(GcsWriteFile(String("w/out"))))
    with assert_raises(contains="FileSystem.delete: unimplemented"):
        fs.delete("t/a.parquet")
    with assert_raises(contains="FileSystem.fsync_file: unimplemented"):
        fs.fsync_file("t/a.parquet")
    with assert_raises(contains="FileSystem.fsync_dir: unimplemented"):
        fs.fsync_dir("t")


def test_a_handle_of_another_store_is_refused_by_name() raises:
    var o = _opener()
    var gcs = o.open_scan_fs(FS_SCHEME_GCS, "raw")
    var s3 = o.open_scan_fs(FS_SCHEME_S3, "lake")
    var gcs_file = StoreFile.of_gcs(GcsFileHandle(String("t/a.parquet")))
    var s3_file = s3.open("t/a.parquet")
    with assert_raises(contains=_refusal_of_handle("read_at")):
        _ = gcs.read_at(s3_file, 0, 4)
    with assert_raises(contains=_refusal_of_handle("read_at")):
        _ = s3.read_at(gcs_file, 0, 4)
    with assert_raises(contains=_refusal_of_handle("read_ranges_prefetched")):
        _ = gcs.read_ranges_prefetched(s3_file, _one_range())
    with assert_raises(contains=_refusal_of_handle("read_ranges_prefetched")):
        _ = s3.read_ranges_prefetched(gcs_file, _one_range())
    var gcs_write = StoreWriteFile.of_gcs(GcsWriteFile(String("w/x")))
    var s3_write = StoreWriteFile.of_s3(S3WriteFile(String("w/x")))
    with assert_raises(contains=_refusal_of_handle("write_at")):
        _ = gcs.write_at(s3_write, Span(_text("x")))
    with assert_raises(contains=_refusal_of_handle("write_at")):
        _ = s3.write_at(gcs_write, Span(_text("x")))
    with assert_raises(contains=_refusal_of_handle("pwrite_at")):
        _ = gcs.pwrite_at(s3_write, 0, Span(_text("x")))
    with assert_raises(contains=_refusal_of_handle("pwrite_at")):
        _ = s3.pwrite_at(gcs_write, 0, Span(_text("x")))
    with assert_raises(contains=_refusal_of_handle("close_write")):
        gcs.close_write(StoreWriteFile.of_s3(S3WriteFile(String("w/x"))))
    with assert_raises(contains=_refusal_of_handle("close_write")):
        s3.close_write(StoreWriteFile.of_gcs(GcsWriteFile(String("w/x"))))
    with assert_raises(contains=_refusal_of_handle("abort_write")):
        gcs.abort_write(StoreWriteFile.of_s3(S3WriteFile(String("w/x"))))
    with assert_raises(contains=_refusal_of_handle("abort_write")):
        s3.abort_write(StoreWriteFile.of_gcs(GcsWriteFile(String("w/x"))))


# ---- StoreScanFs and the access of a bucket --------------------------------------


def test_an_opener_serves_the_gcs_buckets_it_was_told_of() raises:
    var o = _opener()
    assert_true(o.serves(FS_SCHEME_GCS, "raw"))
    assert_true(o.serves(FS_SCHEME_GCS, "emu"))
    assert_false(o.serves(FS_SCHEME_GCS, "lake"))
    assert_false(o.serves(FS_SCHEME_S3, "raw"))
    assert_equal(o.open_scan_fs(FS_SCHEME_GCS, "emu").key_prefix(), "gs://emu/")
    with assert_raises(
        contains="SCAN_FS_UNSERVED: no file system of this run reads gs://nowhere"
    ):
        _ = o.open_scan_fs(FS_SCHEME_GCS, "nowhere")
    with assert_raises(
        contains="STORE_FS_DUPLICATE: gs://raw is already served by this run's file systems"
    ):
        o.add_gcs("raw", GcsAccess.at(_EMU, _TOKEN))
    # The first entry still serves, at its own endpoint.
    assert_equal(
        o.open_scan_fs(FS_SCHEME_GCS, "raw").file_size("t/a.parquet"),
        len(_bytes_a()),
    )
    var empty = _Opener(_connectors())
    assert_false(empty.serves(FS_SCHEME_GCS, "raw"))


def test_each_gcs_bucket_reads_with_its_own_token_and_endpoint() raises:
    var o = _opener()
    assert_equal(
        o.open_scan_fs(FS_SCHEME_GCS, "emu").file_size("t/a.parquet"),
        len(_bytes_c()),
    )
    var other = _Opener(_connectors())
    other.add_gcs("raw", GcsAccess.at("", _WRONG_TOKEN))
    other.add_gcs("emu", GcsAccess.at("", _TOKEN))
    var denied = String("")
    try:
        _ = other.open_scan_fs(FS_SCHEME_GCS, "raw").file_size("t/a.parquet")
    except e:
        denied = String(e)
    assert_equal(
        denied,
        "StoreError[PERMISSION_DENIED] GetObject gs://raw/t/a.parquet"
        " status=403 grpc_code=16 (UNAUTHENTICATED)",
    )
    with assert_raises(
        contains="StoreError[NOT_FOUND] GetObject gs://emu/t/a.parquet status=404"
    ):
        _ = other.open_scan_fs(FS_SCHEME_GCS, "emu").file_size("t/a.parquet")


comptime _NOT_HTTPS = (
    "a gs:// endpoint must start with https://: Cloud Storage is read over"
    " gRPC on TLS, with no plaintext route"
)
comptime _A_PATH = "a gs:// endpoint must not carry a path"
comptime _NO_HOST = "a gs:// endpoint names no host"
comptime _BAD_PORT = "a gs:// endpoint's port must be a number from 1 to 65535"


def test_an_endpoint_is_https_host_and_port() raises:
    var google = GcsAccess.at("", _TOKEN)
    assert_equal(google.host, "storage.googleapis.com")
    assert_equal(google.port, UInt16(443))
    var emu = GcsAccess.at(_EMU, _TOKEN)
    assert_equal(emu.host, _EMU_HOST)
    assert_equal(emu.port, _EMU_PORT)
    assert_equal(emu.token, _TOKEN)
    assert_equal(GcsAccess.at("https://gcs.emulator.test/", _TOKEN).port, UInt16(443))
    assert_equal(GcsAccess.at("HTTPS://gcs.emulator.test:1", _TOKEN).port, UInt16(1))
    assert_equal(
        GcsAccess.at("https://gcs.emulator.test:65535", _TOKEN).port, UInt16(65535)
    )
    for ok in [String(""), String(_EMU), String("https://gcs.emulator.test/")]:
        assert_equal(gcs_endpoint_refusal(ok), "")
    assert_equal(gcs_endpoint_refusal("http://gcs.emulator.test:4443"), _NOT_HTTPS)
    assert_equal(gcs_endpoint_refusal("gcs.emulator.test"), _NOT_HTTPS)
    assert_equal(gcs_endpoint_refusal("https://gcs.emulator.test/storage/v1"), _A_PATH)
    assert_equal(gcs_endpoint_refusal("https://gcs.emulator.test//"), _A_PATH)
    assert_equal(
        gcs_endpoint_refusal("https://u:topsecret@gcs.emulator.test"),
        "a gs:// endpoint must not carry user information",
    )
    assert_equal(
        gcs_endpoint_refusal("https://gcs.emulator.test/?k=topsecret"),
        "a gs:// endpoint must not carry a query or a fragment",
    )
    assert_equal(gcs_endpoint_refusal("https://"), _NO_HOST)
    assert_equal(gcs_endpoint_refusal("https://:4443"), _NO_HOST)
    for port in [String(""), String("0"), String("65536"), String("123456"), String("44a3")]:
        assert_equal(
            gcs_endpoint_refusal("https://gcs.emulator.test:" + port), _BAD_PORT
        )
    # An IPv6 literal is not read: its first `:` is taken for the port's.
    assert_equal(gcs_endpoint_refusal("https://[::1]:4443"), _BAD_PORT)
    with assert_raises(contains="STORAGE_URL_REFUSED: gcs endpoint: " + _NO_HOST):
        _ = GcsAccess.at("https://", _TOKEN)


def test_the_backend_is_built_on_its_first_verb() raises:
    var lazy = LazyGcsBackend[_Buckets](GcsAccess.at("", _TOKEN), _mk_gcs)
    assert_false(lazy.built())
    var first = lazy.conditional_create("raw", "w/new", _text("x"))
    assert_true(lazy.built())
    assert_equal(lazy.get_object("raw", "w/new").size, Int64(1))
    var second = lazy.compare_and_swap("raw", "w/new", _text("yz"), first)
    assert_true(second != first)
    assert_equal(len(lazy.read_range("raw", "w/new", 0, 0)), 2)
    var page = lazy.list_objects("raw", "w/", "")
    assert_equal(len(page.objects), 1)
    assert_equal(page.objects[0].key, "w/new")
    lazy.delete_object("raw", "w/new")
    with assert_raises(contains="StoreError[NOT_FOUND]"):
        _ = lazy.get_object("raw", "w/new")
    # A factory that fails builds nothing, and the next verb tries again.
    var refused = LazyGcsBackend[_Buckets](GcsAccess.at("", _TOKEN), _mk_refused)
    with assert_raises(contains="test: no backend is built here"):
        _ = refused.get_object("raw", "t/a.parquet")
    assert_false(refused.built())
    with assert_raises(contains="test: no backend is built here"):
        _ = refused.read_range("raw", "t/a.parquet", 0, 4)
    with assert_raises(
        contains="StoreFs: a GCS file system is cloned through StoreFs.clone"
    ):
        _ = _refuse_gcs_clone[_Buckets]()


def test_the_production_backend_is_built_without_dialing() raises:
    var backend = kernel_gcs_backend(GcsAccess.at(_EMU, "ya29.a-production-token"))
    assert_equal(backend.token_source().access_token(), "ya29.a-production-token")
    assert_equal(
        backend.request_timeout_us(), HttpClientConfig.defaults().request_timeout_us
    )
    var o = StoreScanFs[
        KernelSchemeConnector,
        KernelSchemeConnector,
        KernelGcsBackend,
        SystemAwsClock,
    ](kernel_store_connectors())
    o.add_gcs("raw", GcsAccess.at("", "ya29.a-production-token"))
    var fs = o.open_scan_fs(FS_SCHEME_GCS, "raw")
    assert_equal(fs.key_prefix(), "gs://raw/")
    assert_equal(fs.clone().key_prefix(), "gs://raw/")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
