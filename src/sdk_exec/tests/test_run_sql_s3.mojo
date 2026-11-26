# =============================================================================
# run_sql_with over Parquet objects in S3: the answer the local file gives
# =============================================================================
#
# Covers: run_sql_with over catalog tables whose ParquetSource names an S3
# bucket, read through S3ScanFs over the fake S3 (objectstore_s3, aws_core and
# komira_test_fake_s3 are test_deps for it): a filter and a projection, a GROUP
# BY and a count, a table of two keys, and one key in two buckets under UNION
# ALL each answer what the same files answer locally through run_sql; a missing
# and a refused object are the store's NOT_FOUND and PERMISSION_DENIED at step
# execute; run_sql refuses the S3 scan with SCAN_FS_UNSERVED, and so does the
# S3 opener a gs:// table.
#
# Each test writes Parquet files under `test_tmpdir()` and seeds the same
# bytes as objects of a fake S3 (komira_test_fake_s3: objects in memory, no
# socket), registers the local files with `register_parquet` and the objects
# as catalog tables whose `ParquetSource` names the bucket (the plan carries
# the bucket and the keys; `S3ScanFs` reaches the store), runs the same SQL
# over the local tables through `run_sql` and over the remote ones through
# `run_sql_with` and an `S3ScanFs` over the fake, and compares the answers. Two workers, so
# the scan's per-worker file systems each build their own store.
#
# What each test proves:
#   * test_a_filter_and_a_projection_answer_what_the_local_file_answers: a
#     pushed filter, a projection and ORDER BY over a file of several row
#     groups give the local rows, and they are the rows the test wrote.
#   * test_a_group_by_answers_what_the_local_file_answers: GROUP BY a string
#     with count(*), min and max, and an ungrouped count, equal the local
#     answers and an oracle computed here.
#   * test_a_table_of_several_keys_reads_every_key: a source listing two keys
#     answers the rows of both, as the local directory of the two files does.
#   * test_one_key_in_two_buckets_is_two_objects: a UNION ALL of the key
#     `t/a.parquet` of bucket `lake` and of bucket `other` (different rows)
#     answers both objects' rows, as the two local files do: the run's footer
#     cache keeps the two apart, and so does the optimizer's shared-subtree
#     rewrite (the two scans render their stores, so they are not one
#     subtree).
#   * test_a_missing_object_is_refused_at_execute_naming_it: a key the bucket
#     lacks is the store's NOT_FOUND error, naming the object's URL.
#   * test_a_refused_read_is_refused_at_execute_naming_it: an object the store
#     answers 403 for is the store's PERMISSION_DENIED error.
#   * test_run_sql_without_an_opener_refuses_the_scan: `run_sql` reads the
#     local file system only, so the S3 table is refused at step `execute`
#     with SCAN_FS_UNSERVED naming the bucket, word for word.
#   * test_a_scan_of_another_store_is_refused_by_the_opener: a table on
#     gs:// lowers, and the S3 opener refuses it at step `execute` with
#     SCAN_FS_UNSERVED naming it, never reading it as an S3 bucket.
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
from aws_core import AwsCredential, FixedClock, StaticCredsSource
from http_client.client import HttpClientConfig
from objectstore_s3 import S3Config, S3ScanFs
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from plan_expr.fs_descriptor_pod import (
    FS_SCHEME_GCS,
    FS_SCHEME_S3,
    FsDescriptorPod,
)
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

from komira_test_fake_s3 import FakeS3Connector

comptime _Opener = S3ScanFs[FakeS3Connector, StaticCredsSource, FixedClock]


# ---- the data: two files, the same bytes on disk and in the store ----------


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


# ---- the store -------------------------------------------------------------


def _mk_store() raises -> FakeS3Connector:
    """Bucket `lake`: t/a.parquet and t/b.parquet; bucket `other`:
    t/a.parquet holding file b's rows. Each store a file system builds gets
    a connector seeded alike."""
    var c = FakeS3Connector()
    c.seed_bytes("t/a.parquet", _bytes_a())
    c.seed_bytes("t/b.parquet", _bytes_b())
    c.seed_in("other", "t/a.parquet", _bytes_b())
    return c^


def _mk_store_refusing_a() raises -> FakeS3Connector:
    """As `_mk_store`, and every request for t/a.parquet is answered 403."""
    var c = FakeS3Connector(trap="t/a.parquet")
    c.seed_bytes("t/a.parquet", _bytes_a())
    return c^


def _creds() -> StaticCredsSource:
    return StaticCredsSource(
        AwsCredential(
            String("AKIDEXAMPLE"),
            String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
            String(""),
        )
    )


def _opener(mk: def () raises thin -> FakeS3Connector) raises -> _Opener:
    return _Opener(
        S3Config.custom_endpoint("us-east-1", "http://127.0.0.1:9000"),
        mk,
        HttpClientConfig.defaults(),
        _creds(),
        FixedClock(1790000000),
    )


# ---- the context -----------------------------------------------------------


def _file_schema(ctx: EngineContext, local_table: String) raises -> Schema:
    """The file schema the footer of a registered local table gave."""
    return ctx.catalog.table_of(local_table).source._parquet.value().schema()


def _add_remote(
    mut ctx: EngineContext,
    name: String,
    var keys: List[String],
    schema_of: String,
    desc: FsDescriptorPod,
) raises:
    """Table `name`: `keys` of the store `desc` names, with the file schema
    of the local table `schema_of`."""
    var schema = _file_schema(ctx, schema_of)
    var ps = ParquetSource.partitioned(
        keys^, schema^, List[Field](), List[List[String]]()
    ).with_fs_descriptor(desc)
    ctx.catalog.add_parquet_source(name, ps^)


def _keys(a: String, b: String = "") -> List[String]:
    var out = List[String]()
    out.append(a)
    if b.byte_length() > 0:
        out.append(b)
    return out^


def _lake() -> FsDescriptorPod:
    return FsDescriptorPod.cloud(FS_SCHEME_S3, "lake", 0)


def _context(name: String) raises -> EngineContext:
    """Local tables local_a, local_b and local_ab (a directory of both
    files), and the remote table remote_a (lake's t/a.parquet)."""
    var ctx = EngineContext(EngineOptions(worker_count=2))
    var dir = test_tmpdir() + "/s3_" + name
    register_parquet(ctx, "local_a", _write(dir + "/a", "a.parquet", _bytes_a()))
    register_parquet(ctx, "local_b", _write(dir + "/b", "b.parquet", _bytes_b()))
    _ = _write(dir + "/ab", "a.parquet", _bytes_a())
    _ = _write(dir + "/ab", "b.parquet", _bytes_b())
    register_parquet(ctx, "local_ab", dir + "/ab")
    _add_remote(ctx, "remote_a", _keys("t/a.parquet"), "local_a", _lake())
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


def _remote(mut ctx: EngineContext, sql: String) raises -> SqlOutcome:
    return _ok(run_sql_with(ctx, sql, _opener(_mk_store)), sql)


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


def test_a_filter_and_a_projection_answer_what_the_local_file_answers() raises:
    var ctx = _context("filter")
    var q = " WHERE id >= 10 AND id < 31 ORDER BY id"
    var local = _local(ctx, "SELECT s, id FROM local_a" + q)
    var remote = _remote(ctx, "SELECT s, id FROM remote_a" + q)
    _same_ints(_ints(remote, 1), _ints(local, 1), "id")
    _same_strs(_strs(remote, 0), _strs(local, 0), "s")
    # The rows the test wrote: id 10 .. 30.
    var ids = _ints(remote, 1)
    assert_equal(len(ids), 21)
    assert_equal(ids[0], 10)
    assert_equal(ids[20], 30)
    assert_equal(_strs(remote, 0)[0], _s_of(10))


def test_a_group_by_answers_what_the_local_file_answers() raises:
    var ctx = _context("group")
    var q = " GROUP BY s ORDER BY s"
    var local = _local(ctx, "SELECT s, count(*), min(id), max(id) FROM local_a" + q)
    var remote = _remote(ctx, "SELECT s, count(*), min(id), max(id) FROM remote_a" + q)
    _same_strs(_strs(remote, 0), _strs(local, 0), "group")
    for c in range(1, 4):
        _same_ints(_ints(remote, c), _ints(local, c), "column " + String(c))
    # The oracle: ids 0 .. 39 by id % 3 (s0: 14 rows 0..39, s1: 13 rows
    # 1..37, s2: 13 rows 2..38).
    _same_ints(_ints(remote, 1), [14, 13, 13], "count")
    _same_ints(_ints(remote, 2), [0, 1, 2], "min")
    _same_ints(_ints(remote, 3), [39, 37, 38], "max")
    var count = _remote(ctx, "SELECT count(*) FROM remote_a")
    _same_ints(_ints(count, 0), [40], "count(*)")


def test_a_table_of_several_keys_reads_every_key() raises:
    var ctx = _context("keys")
    _add_remote(
        ctx, "remote_ab", _keys("t/a.parquet", "t/b.parquet"), "local_a", _lake()
    )
    var local = _local(ctx, "SELECT id FROM local_ab ORDER BY id")
    var remote = _remote(ctx, "SELECT id FROM remote_ab ORDER BY id")
    _same_ints(_ints(remote, 0), _ints(local, 0), "id")
    assert_equal(len(_ints(remote, 0)), 49)


def test_one_key_in_two_buckets_is_two_objects() raises:
    var ctx = _context("buckets")
    _add_remote(
        ctx,
        "remote_other_a",
        _keys("t/a.parquet"),
        "local_b",
        FsDescriptorPod.cloud(FS_SCHEME_S3, "other", 1),
    )
    var local = _local(ctx, "SELECT id FROM local_a UNION ALL SELECT id FROM local_b")
    var remote = _remote(ctx, "SELECT id FROM remote_a UNION ALL SELECT id FROM remote_other_a")
    var want = _sorted(_ints(local, 0))
    _same_ints(_sorted(_ints(remote, 0)), want, "id")
    assert_equal(len(want), 49)
    assert_equal(want[48], 108)


def test_a_missing_object_is_refused_at_execute_naming_it() raises:
    var ctx = _context("missing")
    _add_remote(ctx, "remote_missing", _keys("t/missing.parquet"), "local_a", _lake())
    var r = _refusal(run_sql_with(ctx, "SELECT id FROM remote_missing", _opener(_mk_store)))
    assert_equal(r.step, String(STEP_EXECUTE))
    assert_true("StoreError[NOT_FOUND]" in r.reason, r.reason)
    assert_true("s3://lake/t/missing.parquet" in r.reason, r.reason)


def test_a_refused_read_is_refused_at_execute_naming_it() raises:
    var ctx = _context("denied")
    var r = _refusal(run_sql_with(ctx, "SELECT id FROM remote_a", _opener(_mk_store_refusing_a)))
    assert_equal(r.step, String(STEP_EXECUTE))
    assert_true("StoreError[PERMISSION_DENIED]" in r.reason, r.reason)
    assert_true("s3://lake/t/a.parquet" in r.reason, r.reason)


def test_run_sql_without_an_opener_refuses_the_scan() raises:
    var ctx = _context("unserved")
    var r = _refusal(run_sql(ctx, "SELECT id FROM remote_a"))
    assert_equal(r.step, String(STEP_EXECUTE))
    assert_equal(r.reason, "SCAN_FS_UNSERVED: no file system of this run reads s3://lake")
    # The local table still answers through run_sql.
    var local = _ok(run_sql(ctx, "SELECT count(*) FROM local_a"), "count")
    _same_ints(_ints(local, 0), [40], "local count")


def test_a_scan_of_another_store_is_refused_by_the_opener() raises:
    var ctx = _context("gcs")
    _add_remote(
        ctx,
        "remote_gcs",
        _keys("t/a.parquet"),
        "local_a",
        FsDescriptorPod.cloud(FS_SCHEME_GCS, "raw", 2),
    )
    var r = _refusal(run_sql_with(ctx, "SELECT id FROM remote_gcs", _opener(_mk_store)))
    assert_equal(r.step, String(STEP_EXECUTE))
    assert_equal(r.reason, "SCAN_FS_UNSERVED: no file system of this run reads gs://raw")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
