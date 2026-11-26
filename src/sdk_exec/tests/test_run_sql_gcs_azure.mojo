# =============================================================================
# run_sql_with over Parquet objects in GCS and Azure: the local file's answer
# =============================================================================
#
# Covers: run_sql_with over catalog tables whose ParquetSource names a GCS
# bucket or an Azure container (the scheme as source_url reads a gs:// or az://
# URL), read through GcsScanFs over objectstore_gcs's in-memory fake and
# through AzureScanFs over komira_test_fake_azure's fake Blob service
# (objectstore_gcs, azure_blob, azure_core, source_url and
# komira_test_fake_azure are test_deps for it): a filter and a projection, a
# GROUP BY and a count, a table of two keys, and one key in two buckets (two
# containers) under UNION ALL each answer what the same files answer locally
# through run_sql; a missing and a refused object are the store's NOT_FOUND and
# PERMISSION_DENIED at step execute; run_sql, and the opener of the other
# store, refuse each with SCAN_FS_UNSERVED naming the store.
#
# Each test writes Parquet files under `test_tmpdir()` and puts the same bytes
# in a fake store: GCS objects in objectstore_gcs's in-memory
# `FakeGcsStorageBackend` (one per bucket, behind `_GcsBuckets` below) and
# Azure blobs in komira_test_fake_azure's fake Blob service (in memory, no
# socket, read over HTTP and signed with a Shared Key). It registers the local
# files with `register_parquet` and the objects as catalog tables whose
# `ParquetSource` names the store, its scheme code taken from the URL a user
# writes (`source_url.source_scheme_for_url`: `gs://` and `az://`). It runs
# the same SQL over the local tables through `run_sql` and over the remote
# ones through `run_sql_with` and a `GcsScanFs` or an `AzureScanFs` over the
# fake, and compares the answers. Two workers, so the scan's per-worker file
# systems each build their own backend or client.
#
# What each test proves, for GCS and for Azure alike:
#   * test_a_filter_and_a_projection_answer_what_the_local_file_answers: a
#     pushed filter, a projection and ORDER BY over a file of several row
#     groups give the local rows, and they are the rows the test wrote.
#   * test_a_group_by_answers_what_the_local_file_answers: GROUP BY a string
#     with count(*), min and max, and an ungrouped count, equal the local
#     answers and an oracle computed here.
#   * test_a_table_of_several_keys_reads_every_key: a source listing two keys
#     answers the rows of both, as the local directory of the two files does.
#   * test_one_key_in_two_buckets_is_two_objects: a UNION ALL of the key
#     `t/a.parquet` of two buckets (two containers) holding different rows
#     answers both objects' rows, as the two local files do: the run's footer
#     cache keys the two apart (`gs://<bucket>/`, `az://<container>/`).
#   * test_a_missing_object_is_refused_at_execute_naming_it: a key the store
#     lacks is the store's NOT_FOUND error, naming the object's URL.
#   * test_a_refused_read_is_refused_at_execute_naming_it: an object the store
#     denies is the store's PERMISSION_DENIED error, naming the object's URL.
#   * test_run_sql_without_an_opener_refuses_the_scan: `run_sql` reads the
#     local file system only, so each remote table is refused at step
#     `execute` with SCAN_FS_UNSERVED naming the store, word for word.
#   * test_an_opener_for_another_store_refuses_the_scan: a GCS table run with
#     the Azure opener, and an Azure table run with the GCS opener, are
#     refused at step `execute` with SCAN_FS_UNSERVED naming the store the
#     opener does not serve, never read as a store of the other kind.
# =============================================================================

from std.os import makedirs
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from arrow.string_array import StringArray
from azure_blob import AzureClientSpec, AzureConfig, AzureCredential, AzureScanFs
from azure_core import AzureSharedKey
from objectstore_gcs import (
    FakeGcsStorageBackend,
    GcsScanFs,
    GcsStorageBackend,
    ListPageRaw,
    ObjectMetaRaw,
)
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from plan_expr.fs_descriptor_pod import FsDescriptorPod
from runtime_paths import test_tmpdir
from scan_source.parquet_source import ParquetSource
from sdk_exec.engine_catalog import register_parquet
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import (
    STEP_EXECUTE,
    SqlOutcome,
    SqlRefusal,
    run_sql,
    run_sql_with,
)
from source_url.source_url import source_scheme_for_url

from komira_test_fake_azure import FakeAzureConnector


# ---- the data: two files, the same bytes on disk and in each store ---------


def _s_of(id: Int) -> String:
    return String("s") + String(id % 3)


def _batch(first: Int, n: Int) raises -> RecordBatch:
    """Rows id = first .. first + n - 1 with s = _s_of(id)."""
    var ids = PrimitiveArray[DType.int64].allocate(n)
    var strs = List[String]()
    for i in range(n):
        ids.set(i, Int64(first + i))
        strs.append(_s_of(first + i))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    rb.add_column(Column.from_primitive[DType.int64](ids^))
    sb.add_field(Field("s", ArrowType.STRING, False))
    rb.add_column(Column.from_string(StringArray.from_strings(strs)))
    return rb.build(sb.build())


def _bytes_a() raises -> List[UInt8]:
    """40 rows from id 0, in row groups of 7."""
    return write_record_batch_to_parquet_bytes(_batch(0, 40), max_rows_per_rg=7)


def _bytes_b() raises -> List[UInt8]:
    """9 rows from id 100, in row groups of 4."""
    return write_record_batch_to_parquet_bytes(_batch(100, 9), max_rows_per_rg=4)


def _write(dir: String, name: String, bytes: List[UInt8]) raises -> String:
    makedirs(dir, exist_ok=True)
    var path = dir + "/" + name
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path^


# ---- GCS: bucket `raw` (t/a.parquet, t/b.parquet, t/denied.parquet) and
# bucket `other` (t/a.parquet holding file b's rows) ------------------------


comptime _DENIED = "t/denied.parquet"


struct _GcsBuckets(GcsStorageBackend, Movable, Deinitable):
    """Two `FakeGcsStorageBackend`s, one per bucket (the fake models one),
    with every verb routed by its bucket; a read of `_DENIED` in `raw` is
    refused as GCS refuses a caller without access. A bucket that is neither
    is not found."""

    var _raw: FakeGcsStorageBackend
    var _other: FakeGcsStorageBackend

    def __init__(out self) raises:
        self._raw = FakeGcsStorageBackend()
        self._other = FakeGcsStorageBackend()
        _ = self._raw.conditional_create("raw", "t/a.parquet", _bytes_a())
        _ = self._raw.conditional_create("raw", "t/b.parquet", _bytes_b())
        _ = self._raw.conditional_create("raw", _DENIED, _bytes_a())
        _ = self._other.conditional_create("other", "t/a.parquet", _bytes_b())

    @staticmethod
    def _check(method: String, bucket: String, key: String) raises:
        if bucket == "raw" and key == _DENIED:
            raise Error(
                String("StoreError[PERMISSION_DENIED] ")
                + method
                + " gs://raw/"
                + key
                + " status=403 grpc_code=7 grpc_detail=caller has no access"
            )
        if bucket != "raw" and bucket != "other":
            raise Error(
                String("StoreError[NOT_FOUND] ")
                + method
                + " gs://"
                + bucket
                + "/"
                + key
                + " status=404 grpc_code=5 grpc_detail=bucket not found"
            )

    def conditional_create(
        mut self, bucket: String, key: String, data: List[UInt8]
    ) raises -> Int64:
        Self._check("WriteObject", bucket, key)
        if bucket == "raw":
            return self._raw.conditional_create(bucket, key, data)
        return self._other.conditional_create(bucket, key, data)

    def compare_and_swap(
        mut self,
        bucket: String,
        key: String,
        data: List[UInt8],
        expected_generation: Int64,
    ) raises -> Int64:
        Self._check("WriteObject", bucket, key)
        if bucket == "raw":
            return self._raw.compare_and_swap(bucket, key, data, expected_generation)
        return self._other.compare_and_swap(bucket, key, data, expected_generation)

    def read_range(
        mut self,
        bucket: String,
        key: String,
        read_offset: Int64,
        read_limit: Int64,
    ) raises -> List[UInt8]:
        Self._check("ReadObject", bucket, key)
        if bucket == "raw":
            return self._raw.read_range(bucket, key, read_offset, read_limit)
        return self._other.read_range(bucket, key, read_offset, read_limit)

    def get_object(mut self, bucket: String, key: String) raises -> ObjectMetaRaw:
        Self._check("GetObject", bucket, key)
        if bucket == "raw":
            return self._raw.get_object(bucket, key)
        return self._other.get_object(bucket, key)

    def delete_object(mut self, bucket: String, key: String) raises:
        Self._check("DeleteObject", bucket, key)
        if bucket == "raw":
            self._raw.delete_object(bucket, key)
        else:
            self._other.delete_object(bucket, key)

    def list_objects(
        mut self,
        bucket: String,
        prefix: String,
        page_token: String,
        delimiter: String = String(""),
    ) raises -> ListPageRaw:
        Self._check("ListObjects", bucket, prefix)
        if bucket == "raw":
            return self._raw.list_objects(bucket, prefix, page_token, delimiter)
        return self._other.list_objects(bucket, prefix, page_token, delimiter)


def _mk_gcs() raises -> _GcsBuckets:
    """Each backend a file system builds holds the buckets alike."""
    return _GcsBuckets()


def _gcs() -> GcsScanFs[_GcsBuckets]:
    return GcsScanFs[_GcsBuckets](_mk_gcs)


# ---- Azure: container `box` (t/a.parquet, t/b.parquet) and container
# `other` (t/a.parquet holding file b's rows), in account devstoreaccount1 --


comptime _ACCOUNT = "devstoreaccount1"
comptime _FAKE_KEY = "VGhpcyBpcyBhIGZha2Uga2V5IGZvciB0ZXN0aW5nIDEyMzQ1Njc4OTAxMjMK"


def _seeded(var c: FakeAzureConnector) raises -> FakeAzureConnector:
    c.seed("box", "t/a.parquet", _bytes_a())
    c.seed("box", "t/b.parquet", _bytes_b())
    c.seed("other", "t/a.parquet", _bytes_b())
    return c^


def _mk_azure() raises -> FakeAzureConnector:
    """Each connector a client builds holds the containers alike."""
    return _seeded(FakeAzureConnector())


def _mk_azure_refusing_a() raises -> FakeAzureConnector:
    """As `_mk_azure`, and every request for t/a.parquet is answered 403."""
    return _seeded(FakeAzureConnector(trap="t/a.parquet"))


def _azure(mk: def () raises thin -> FakeAzureConnector) raises -> AzureScanFs[FakeAzureConnector]:
    return AzureScanFs[FakeAzureConnector](
        AzureClientSpec[FakeAzureConnector](
            AzureConfig.azurite(String(_ACCOUNT)),
            AzureCredential.shared_key(AzureSharedKey(String(_ACCOUNT), String(_FAKE_KEY))),
            mk,
        )
    )


# ---- the context -----------------------------------------------------------


def _store(url: String) raises -> FsDescriptorPod:
    """The store of `<scheme>://<bucket>/...`: its scheme code as source_url
    maps the URL's prefix, and its bucket (container)."""
    var scheme = source_scheme_for_url(url)
    var start = url.find("://") + 3
    var end = url.find("/", start)
    return FsDescriptorPod.cloud(scheme, String(url[byte=start:end]), 0)


def _add_remote(
    mut ctx: EngineContext,
    name: String,
    var keys: List[String],
    schema_of: String,
    url: String,
) raises:
    """Table `name`: `keys` of the store `url` names, with the file schema of
    the local table `schema_of`."""
    var schema = ctx.catalog.table_of(schema_of).source._parquet.value().schema()
    var ps = ParquetSource.partitioned(
        keys^, schema^, List[Field](), List[List[String]]()
    ).with_fs_descriptor(_store(url))
    ctx.catalog.add_parquet_source(name, ps^)


def _keys(a: String, b: String = "") -> List[String]:
    var out = List[String]()
    out.append(a)
    if b.byte_length() > 0:
        out.append(b)
    return out^


def _context(name: String) raises -> EngineContext:
    """Local tables local_a, local_b and local_ab (a directory of both
    files); remote tables gcs_a (gs://raw/t/a.parquet) and az_a
    (az://box/t/a.parquet)."""
    var ctx = EngineContext(EngineOptions(worker_count=2))
    var dir = test_tmpdir() + "/gcs_azure_" + name
    register_parquet(ctx, "local_a", _write(dir + "/a", "a.parquet", _bytes_a()))
    register_parquet(ctx, "local_b", _write(dir + "/b", "b.parquet", _bytes_b()))
    _ = _write(dir + "/ab", "a.parquet", _bytes_a())
    _ = _write(dir + "/ab", "b.parquet", _bytes_b())
    register_parquet(ctx, "local_ab", dir + "/ab")
    _add_remote(ctx, "gcs_a", _keys("t/a.parquet"), "local_a", "gs://raw/t/a.parquet")
    _add_remote(ctx, "az_a", _keys("t/a.parquet"), "local_a", "az://box/t/a.parquet")
    return ctx^


# ---- reading answers -------------------------------------------------------


def _ok(var out: SqlOutcome, sql: String) raises -> SqlOutcome:
    if out.refusal:
        assert_true(
            False,
            "refused at " + out.refusal.value().step + ": " + out.refusal.value().reason + " -- " + sql,
        )
    return out^


def _local(mut ctx: EngineContext, sql: String) raises -> SqlOutcome:
    return _ok(run_sql(ctx, sql), sql)


def _on_gcs(mut ctx: EngineContext, sql: String) raises -> SqlOutcome:
    return _ok(run_sql_with(ctx, sql, _gcs()), sql)


def _on_azure(mut ctx: EngineContext, sql: String) raises -> SqlOutcome:
    return _ok(run_sql_with(ctx, sql, _azure(_mk_azure)), sql)


def _ints(ref out: SqlOutcome, col: Int) raises -> List[Int]:
    var r = List[Int]()
    for b in range(len(out.batches)):
        ref batch = out.batches[b]
        var a = batch.column_at(col).as_primitive[DType.int64]()
        for i in range(batch.num_rows()):
            r.append(Int(a.get(i)))
    return r^


def _strs(ref out: SqlOutcome, col: Int) raises -> List[String]:
    var r = List[String]()
    for b in range(len(out.batches)):
        ref batch = out.batches[b]
        var a = batch.column_at(col).as_string()
        for i in range(batch.num_rows()):
            r.append(a.get(i))
    return r^


def _sorted(var v: List[Int]) -> List[Int]:
    for i in range(1, len(v)):
        var j = i
        while j > 0 and v[j - 1] > v[j]:
            var t = v[j]
            v[j] = v[j - 1]
            v[j - 1] = t
            j -= 1
    return v^


def _same_ints(got: List[Int], want: List[Int], what: String) raises:
    assert_equal(len(got), len(want), what + ": row count")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": row " + String(i))


def _same_strs(got: List[String], want: List[String], what: String) raises:
    assert_equal(len(got), len(want), what + ": row count")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": row " + String(i))


def _refusal(var out: SqlOutcome) raises -> SqlRefusal:
    assert_false(out.ok(), "expected a refusal")
    assert_equal(len(out.batches), 0)
    return out.refusal.value().copy()


# ---- the tests -------------------------------------------------------------


def _check_filter(ref local: SqlOutcome, ref remote: SqlOutcome, what: String) raises:
    _same_ints(_ints(remote, 1), _ints(local, 1), what + " id")
    _same_strs(_strs(remote, 0), _strs(local, 0), what + " s")
    # The rows the test wrote: id 10 .. 30.
    var ids = _ints(remote, 1)
    assert_equal(len(ids), 21, what)
    assert_equal(ids[0], 10, what)
    assert_equal(ids[20], 30, what)
    assert_equal(_strs(remote, 0)[0], _s_of(10), what)


def test_a_filter_and_a_projection_answer_what_the_local_file_answers() raises:
    var ctx = _context("filter")
    var q = " WHERE id >= 10 AND id < 31 ORDER BY id"
    var local = _local(ctx, "SELECT s, id FROM local_a" + q)
    _check_filter(local, _on_gcs(ctx, "SELECT s, id FROM gcs_a" + q), "gcs")
    _check_filter(local, _on_azure(ctx, "SELECT s, id FROM az_a" + q), "azure")


def _check_group(ref local: SqlOutcome, ref remote: SqlOutcome, what: String) raises:
    _same_strs(_strs(remote, 0), _strs(local, 0), what + " group")
    for c in range(1, 4):
        _same_ints(_ints(remote, c), _ints(local, c), what + " column " + String(c))
    # The oracle: ids 0 .. 39 by id % 3 (s0: 14 rows 0..39, s1: 13 rows
    # 1..37, s2: 13 rows 2..38).
    _same_ints(_ints(remote, 1), [14, 13, 13], what + " count")
    _same_ints(_ints(remote, 2), [0, 1, 2], what + " min")
    _same_ints(_ints(remote, 3), [39, 37, 38], what + " max")


def test_a_group_by_answers_what_the_local_file_answers() raises:
    var ctx = _context("group")
    var q = " GROUP BY s ORDER BY s"
    var local = _local(ctx, "SELECT s, count(*), min(id), max(id) FROM local_a" + q)
    _check_group(local, _on_gcs(ctx, "SELECT s, count(*), min(id), max(id) FROM gcs_a" + q), "gcs")
    _check_group(local, _on_azure(ctx, "SELECT s, count(*), min(id), max(id) FROM az_a" + q), "azure")
    _same_ints(_ints(_on_gcs(ctx, "SELECT count(*) FROM gcs_a"), 0), [40], "gcs count(*)")
    _same_ints(_ints(_on_azure(ctx, "SELECT count(*) FROM az_a"), 0), [40], "azure count(*)")


def test_a_table_of_several_keys_reads_every_key() raises:
    var ctx = _context("keys")
    _add_remote(ctx, "gcs_ab", _keys("t/a.parquet", "t/b.parquet"), "local_a", "gs://raw/t")
    _add_remote(ctx, "az_ab", _keys("t/a.parquet", "t/b.parquet"), "local_a", "az://box/t")
    var want = _ints(_local(ctx, "SELECT id FROM local_ab ORDER BY id"), 0)
    assert_equal(len(want), 49)
    _same_ints(_ints(_on_gcs(ctx, "SELECT id FROM gcs_ab ORDER BY id"), 0), want, "gcs id")
    _same_ints(_ints(_on_azure(ctx, "SELECT id FROM az_ab ORDER BY id"), 0), want, "azure id")


def test_one_key_in_two_buckets_is_two_objects() raises:
    var ctx = _context("buckets")
    _add_remote(ctx, "gcs_other_a", _keys("t/a.parquet"), "local_b", "gs://other/t/a.parquet")
    _add_remote(ctx, "az_other_a", _keys("t/a.parquet"), "local_b", "az://other/t/a.parquet")
    var want = _sorted(_ints(_local(ctx, "SELECT id FROM local_a UNION ALL SELECT id FROM local_b"), 0))
    assert_equal(len(want), 49)
    assert_equal(want[48], 108)
    var gcs = _on_gcs(ctx, "SELECT id FROM gcs_a UNION ALL SELECT id FROM gcs_other_a")
    _same_ints(_sorted(_ints(gcs, 0)), want, "gcs id")
    var azure = _on_azure(ctx, "SELECT id FROM az_a UNION ALL SELECT id FROM az_other_a")
    _same_ints(_sorted(_ints(azure, 0)), want, "azure id")


def test_a_missing_object_is_refused_at_execute_naming_it() raises:
    var ctx = _context("missing")
    _add_remote(ctx, "gcs_missing", _keys("t/missing.parquet"), "local_a", "gs://raw/t")
    _add_remote(ctx, "az_missing", _keys("t/missing.parquet"), "local_a", "az://box/t")
    var g = _refusal(run_sql_with(ctx, "SELECT id FROM gcs_missing", _gcs()))
    assert_equal(g.step, String(STEP_EXECUTE))
    assert_true("StoreError[NOT_FOUND]" in g.reason, g.reason)
    assert_true("gs://raw/t/missing.parquet" in g.reason, g.reason)
    var a = _refusal(run_sql_with(ctx, "SELECT id FROM az_missing", _azure(_mk_azure)))
    assert_equal(a.step, String(STEP_EXECUTE))
    assert_true("StoreError[NOT_FOUND]" in a.reason, a.reason)
    assert_true("az://box/t/missing.parquet" in a.reason, a.reason)


def test_a_refused_read_is_refused_at_execute_naming_it() raises:
    var ctx = _context("denied")
    _add_remote(ctx, "gcs_denied", _keys(_DENIED), "local_a", "gs://raw/t")
    var g = _refusal(run_sql_with(ctx, "SELECT id FROM gcs_denied", _gcs()))
    assert_equal(g.step, String(STEP_EXECUTE))
    assert_true("StoreError[PERMISSION_DENIED]" in g.reason, g.reason)
    assert_true("gs://raw/t/denied.parquet" in g.reason, g.reason)
    var a = _refusal(run_sql_with(ctx, "SELECT id FROM az_a", _azure(_mk_azure_refusing_a)))
    assert_equal(a.step, String(STEP_EXECUTE))
    assert_true("StoreError[PERMISSION_DENIED]" in a.reason, a.reason)
    assert_true("az://box/t/a.parquet" in a.reason, a.reason)


def test_run_sql_without_an_opener_refuses_the_scan() raises:
    var ctx = _context("unserved")
    var g = _refusal(run_sql(ctx, "SELECT id FROM gcs_a"))
    assert_equal(g.step, String(STEP_EXECUTE))
    assert_equal(g.reason, "SCAN_FS_UNSERVED: no file system of this run reads gs://raw")
    var a = _refusal(run_sql(ctx, "SELECT id FROM az_a"))
    assert_equal(a.step, String(STEP_EXECUTE))
    assert_equal(a.reason, "SCAN_FS_UNSERVED: no file system of this run reads az://box")
    # The local table still answers through run_sql.
    _same_ints(_ints(_local(ctx, "SELECT count(*) FROM local_a"), 0), [40], "local count")


def test_an_opener_for_another_store_refuses_the_scan() raises:
    var ctx = _context("crossed")
    var g = _refusal(run_sql_with(ctx, "SELECT id FROM gcs_a", _azure(_mk_azure)))
    assert_equal(g.step, String(STEP_EXECUTE))
    assert_equal(g.reason, "SCAN_FS_UNSERVED: no file system of this run reads gs://raw")
    var a = _refusal(run_sql_with(ctx, "SELECT id FROM az_a", _gcs()))
    assert_equal(a.step, String(STEP_EXECUTE))
    assert_equal(a.reason, "SCAN_FS_UNSERVED: no file system of this run reads az://box")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
