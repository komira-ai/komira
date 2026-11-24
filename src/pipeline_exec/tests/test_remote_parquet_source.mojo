# The Parquet arm of a segment whose spec names a remote store
# (`SourceSpecPod.parquet_fs`): the builder reads it through the file system
# its `ScanFsOpener` opens on the spec's bucket, never the local file system.
#
# The opener here (`_BucketDirs`) serves the one bucket `lake` with a local
# file system, so these tests need no object store: they hold the routing,
# and sdk_exec's test_run_lowered_plan_s3 holds the same plans against a fake
# S3. Rows: a remote spec of one key with a pushed filter, a projection and
# operators answers what the same spec answers locally; a remote spec that
# lists its keys reads every row of each; a builder given no opener refuses a
# remote spec with SCAN_FS_UNSERVED naming the store; the opener's own refusal
# of a bucket is the run's error; the local entry point refuses a remote spec
# rather than read a local file of that name; the default opener opens
# nothing.
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from arrow.schema import Field, RecordBatch
from async_api.token import CancellationToken
from async_rt.ops.waker_sink import NoopSink
from fs.local_fs import LocalFs
from fs.scan_fs import ScanFsOpener
from parquet.runtime_footer_cache import ParquetMetadataCache
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from physical_plan.physical_plan import MorselOp, SegmentDescPod, SourceSpecPod
from pipeline_exec.fake_dispatch import InlineDispatch
from pipeline_exec.plan_harness import (
    chain,
    int64_column,
    parquet_segment,
    project_columns,
    sample_batch,
    string_column,
)
from pipeline_exec.real_builder import RealBuilder
from pipeline_exec.run_plan import run_plan
from pipeline_exec.source_parquet import LocalOnlyScanFs, build_parquet_source
from plan_expr.expr import BIN_GE, BIN_GT, Expr
from plan_expr.expr_pool import ExprPool
from plan_expr.fs_descriptor_pod import FS_SCHEME_S3, FsDescriptorPod
from plan_expr.scalar_value import ScalarValue
from runtime_paths import test_tmpdir


struct _BucketDirs(ScanFsOpener):
    """Serves bucket `lake` with the local file system; refuses any other."""

    comptime FS = LocalFs[NoopSink]

    def __init__(out self):
        pass

    def open_scan_fs(self, scheme: UInt8, bucket: String) raises -> Self.FS:
        if scheme != FS_SCHEME_S3 or bucket != "lake":
            raise Error("_BucketDirs: no bucket " + bucket)
        return LocalFs[NoopSink].from_root(test_tmpdir())


def _lake() -> FsDescriptorPod:
    return FsDescriptorPod.cloud(FS_SCHEME_S3, "lake", 0)


def _cmp(op: UInt8, name: String, v: Int) -> Expr:
    return Expr.binary(op, Expr.col_ref(name), Expr.literal(ScalarValue.from_int(v)))


def _names(a: String, b: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    out.append(b)
    return out^


def _write(name: String, start: Int, rows: Int) raises -> String:
    var path = test_tmpdir() + "/" + name + ".parquet"
    var bytes = write_record_batch_to_parquet_bytes(sample_batch(start, rows), max_rows_per_rg=7)
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path^


def _plan(path: String) -> SegmentDescPod:
    """Scan with a pushed a >= 10, keep b > 150, project (s, a)."""
    return parquet_segment(
        0,
        path,
        None,
        Optional(_cmp(BIN_GE, "a", 10)),
        chain(MorselOp.filter(_cmp(BIN_GT, "b", 150)), project_columns(_names("s", "a"))),
    )


def _one(var desc: SegmentDescPod) -> List[SegmentDescPod]:
    var out = List[SegmentDescPod]()
    out.append(desc^)
    return out^


def _run_with_opener(var desc: SegmentDescPod) raises -> RecordBatch:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf), _BucketDirs](
        cache, pool, _BucketDirs()
    )
    var dispatch = InlineDispatch()
    var out = run_plan(_one(desc^), builder, dispatch, 1, CancellationToken.new())
    return out.take(0)


def test_a_remote_key_answers_what_the_local_file_answers() raises:
    var path = _write("remote_one", 0, 40)
    var local = _run_with_opener(_plan(path))
    var remote_desc = _plan(path)
    remote_desc.source_spec.parquet_fs = _lake()
    var remote = _run_with_opener(remote_desc^)
    var local_a = int64_column(local, 1)
    var remote_a = int64_column(remote, 1)
    var local_s = string_column(local, 0)
    var remote_s = string_column(remote, 0)
    assert_true(len(local_a) > 0)
    assert_equal(len(remote_a), len(local_a))
    for i in range(len(local_a)):
        assert_equal(remote_a[i], local_a[i])
        assert_equal(remote_s[i], local_s[i])


def test_a_remote_spec_that_lists_its_keys_reads_each() raises:
    var keys = List[String]()
    keys.append(_write("remote_a", 0, 12))
    keys.append(_write("remote_b", 100, 9))
    var desc = parquet_segment(0, String(""))
    desc.source_spec = SourceSpecPod.parquet_files(
        keys^, List[Field](), List[List[String]](), None, None, _lake()
    )
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf), _BucketDirs](
        cache, pool, _BucketDirs()
    )
    var dispatch = InlineDispatch()
    var out = run_plan(_one(desc^), builder, dispatch, 1, CancellationToken.new())
    var a = int64_column(out.take(0), 0)
    assert_equal(len(a), 21)
    assert_equal(a[0], 0)
    assert_equal(a[11], 11)
    assert_equal(a[12], 100)
    assert_equal(a[20], 108)


def test_a_builder_with_no_opener_refuses_a_remote_spec() raises:
    var desc = _plan(_write("remote_unserved", 0, 5))
    desc.source_spec.parquet_fs = _lake()
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](cache, pool)
    var dispatch = InlineDispatch()
    with assert_raises(contains="SCAN_FS_UNSERVED: no file system of this run reads s3://lake"):
        _ = run_plan(_one(desc^), builder, dispatch, 1, CancellationToken.new())


def test_the_openers_refusal_of_a_bucket_is_the_runs_error() raises:
    var desc = _plan(_write("remote_other", 0, 5))
    desc.source_spec.parquet_fs = FsDescriptorPod.cloud(FS_SCHEME_S3, "other", 0)
    with assert_raises(contains="_BucketDirs: no bucket other"):
        _ = _run_with_opener(desc^)


def test_the_local_entry_point_refuses_a_remote_spec() raises:
    var spec = SourceSpecPod.parquet(_write("remote_local_entry", 0, 5), None, None, True, _lake())
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var refused = False
    try:
        _ = build_parquet_source[origin_of(cache), origin_of(pool), origin_of(nf)](spec, 0, 1, cache, pool)
    except e:
        assert_equal(String(e), "SCAN_FS_UNSERVED: no file system of this run reads s3://lake")
        refused = True
    assert_true(refused)


def test_the_default_opener_opens_nothing() raises:
    var refused = False
    try:
        _ = LocalOnlyScanFs().open_scan_fs(FS_SCHEME_S3, "lake")
    except e:
        assert_equal(String(e), "SCAN_FS_UNSERVED: no file system of this run reads s3://lake")
        refused = True
    assert_true(refused)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
