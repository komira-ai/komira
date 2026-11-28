# =============================================================================
# SOURCE_ICEBERG: the planned files of one Iceberg snapshot
# =============================================================================
#
# Each test writes Parquet data files from the sample table (a = r, b = r * 10
# with NULL where r % 5 == 2, s = "s" + r % 4; no field ids, so the reader
# binds the spec's columns to the files' by name) under the test's scratch
# directory, builds a SOURCE_ICEBERG spec the way lowering does (the planned
# files and every bound column with its field id) and reads it through
# `read_iceberg_spec` or through a plan on `RealBuilder`. What these tests
# prove:
#
#   * The rows of several data files come back once each, in the order the spec
#     lists the files, at the bound columns, a NULL cell as NULL.
#   * A bound column that a file lacks reads as NULL in every row of it.
#   * A spec that lists no file reads no row under the bound columns.
#   * A plan over the source filters, projects and collects every matching row
#     once on several workers and cut morsels, in file order.
#   * A file whose column is not the bound type is refused with
#     ICEBERG_DATA_FILE_MISMATCH, a missing file is refused, and the error
#     reaches the run.
#   * A source kind the builder does not serve is refused, and the message
#     lists SOURCE_ICEBERG among the served kinds.

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from arrow.arrow_types import ArrowType
from arrow.schema import RecordBatch
from async_api.token import CancellationToken
from containers.slab import Slab
from parquet.runtime_footer_cache import ParquetMetadataCache
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from physical_plan.iceberg_scan_spec import (
    IcebergDataFileSpec,
    IcebergDeleteSpec,
    IcebergScanSpec,
)
from physical_plan.physical_plan import (
    KEY_DTYPE_NONE,
    MorselOp,
    SegmentDescPod,
    SINK_COLLECT,
    SINK_ORIENT_COLUMNAR,
    SourceSpecPod,
)
from pipeline_exec.fake_dispatch import InlineDispatch
from pipeline_exec.plan_harness import (
    b_is_null,
    chain,
    column_names,
    iceberg_segment,
    int64_column,
    null_column,
    project_columns,
    sample_batch,
    string_column,
)
from pipeline_exec.real_builder import RealBuilder
from pipeline_exec.run_plan import run_plan
from pipeline_exec.source_iceberg import read_iceberg_spec
from plan_expr.expr import BIN_GT, Expr
from plan_expr.expr_pool import ExprPool
from plan_expr.scalar_value import ScalarValue
from runtime_paths import test_tmpdir


def _names(a: String, b: String = "", c: String = "") -> List[String]:
    var out = List[String]()
    out.append(a)
    if b.byte_length() > 0:
        out.append(b)
    if c.byte_length() > 0:
        out.append(c)
    return out^


def _write(name: String, start: Int, rows: Int) raises -> String:
    var path = test_tmpdir() + "/" + name + ".parquet"
    var bytes = write_record_batch_to_parquet_bytes(
        sample_batch(start, rows), max_rows_per_rg=4
    )
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path^


def _file(path: String) -> IcebergDataFileSpec:
    return IcebergDataFileSpec(
        path, "file://" + path, List[Int](), List[Int]()
    )


def _spec(
    var files: List[IcebergDataFileSpec],
    var names: List[String],
    var types: List[ArrowType],
) -> SourceSpecPod:
    var ids = List[Int]()
    for i in range(len(names)):
        ids.append(i + 1)
    return SourceSpecPod.iceberg(
        IcebergScanSpec(
            names^, types^, ids^, files^, List[IcebergDeleteSpec]()
        )
    )


def _sample_types() -> List[ArrowType]:
    var t = List[ArrowType]()
    t.append(ArrowType.INT64)
    t.append(ArrowType.INT64)
    t.append(ArrowType.STRING)
    return t^


def _sample_spec(var files: List[IcebergDataFileSpec]) -> SourceSpecPod:
    return _spec(files^, _names("a", "b", "s"), _sample_types())


def _two_files() raises -> List[IcebergDataFileSpec]:
    var files = List[IcebergDataFileSpec]()
    files.append(_file(_write("first", 0, 10)))
    files.append(_file(_write("second", 10, 5)))
    return files^


def test_the_rows_of_every_file_come_back_in_spec_order_at_the_bound_columns() raises:
    var batch = read_iceberg_spec(_sample_spec(_two_files()))
    assert_equal(batch.num_rows(), 15)
    var names = column_names(batch)
    assert_equal(len(names), 3)
    assert_equal(names[0], "a")
    assert_equal(names[1], "b")
    assert_equal(names[2], "s")
    assert_true(batch.column_at(0).arrow_type == ArrowType.INT64)
    assert_true(batch.column_at(2).arrow_type == ArrowType.STRING)
    var a = int64_column(batch, 0)
    var b = int64_column(batch, 1)
    var b_null = null_column(batch, 1)
    var s = string_column(batch, 2)
    for r in range(15):
        assert_equal(a[r], r)
        assert_equal(b_null[r], b_is_null(r), "row " + String(r))
        if not b_is_null(r):
            assert_equal(b[r], r * 10)
        assert_equal(s[r], "s" + String(r % 4))


def test_the_files_are_read_in_the_order_the_spec_lists_them() raises:
    var files = List[IcebergDataFileSpec]()
    files.append(_file(_write("later", 10, 5)))
    files.append(_file(_write("earlier", 0, 3)))
    var a = int64_column(read_iceberg_spec(_sample_spec(files^)), 0)
    assert_equal(len(a), 8)
    assert_equal(a[0], 10)
    assert_equal(a[4], 14)
    assert_equal(a[5], 0)
    assert_equal(a[7], 2)


def test_a_bound_column_a_file_lacks_reads_as_null() raises:
    var files = List[IcebergDataFileSpec]()
    files.append(_file(_write("lacks", 0, 6)))
    var types = List[ArrowType]()
    types.append(ArrowType.INT64)
    types.append(ArrowType.INT64)
    var batch = read_iceberg_spec(_spec(files^, _names("a", "added"), types^))
    assert_equal(batch.num_rows(), 6)
    assert_equal(batch.num_columns(), 2)
    var added_null = null_column(batch, 1)
    for r in range(6):
        assert_true(added_null[r], "row " + String(r))
        assert_false(batch.column_at(0).is_null_at(r))


def test_a_spec_with_no_file_reads_no_row_under_the_bound_columns() raises:
    var batch = read_iceberg_spec(_sample_spec(List[IcebergDataFileSpec]()))
    assert_equal(batch.num_rows(), 0)
    assert_equal(batch.num_columns(), 3)
    assert_equal(batch.schema.field_name(2), "s")
    assert_true(batch.column_at(2).arrow_type == ArrowType.STRING)


def test_a_file_whose_column_is_not_the_bound_type_is_refused_by_name() raises:
    var files = List[IcebergDataFileSpec]()
    files.append(_file(_write("mistyped", 0, 4)))
    var types = List[ArrowType]()
    types.append(ArrowType.INT64)
    types.append(ArrowType.INT64)
    types.append(ArrowType.INT64)
    with assert_raises(contains="ICEBERG_DATA_FILE_MISMATCH: "):
        _ = read_iceberg_spec(_spec(files^, _names("a", "b", "s"), types^))


def test_a_missing_data_file_is_refused() raises:
    var files = List[IcebergDataFileSpec]()
    files.append(_file(test_tmpdir() + "/no_such_file.parquet"))
    with assert_raises():
        _ = read_iceberg_spec(_sample_spec(files^))


def _one(var desc: SegmentDescPod) -> List[SegmentDescPod]:
    var out = List[SegmentDescPod]()
    out.append(desc^)
    return out^


def _a_gt(v: Int) -> Expr:
    return Expr.binary(
        BIN_GT, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int(v))
    )


def _run_plan(
    var spec: SourceSpecPod, workers: Int, morsel_rows: Int
) raises -> RecordBatch:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var dispatch = InlineDispatch()
    var ops = chain(
        MorselOp.filter(_a_gt(5)), project_columns(_names("s", "a"))
    )
    var out = run_plan(
        _one(iceberg_segment(0, spec^, ops^, morsel_rows)),
        builder,
        dispatch,
        workers,
        CancellationToken.new(),
    )
    return out.take(0)


def test_a_plan_over_the_iceberg_source_filters_projects_and_collects() raises:
    var files = _two_files()
    # One worker at the default morsel size, and three workers over morsels
    # of four rows: the same rows, in file order.
    var runs = List[RecordBatch]()
    runs.append(_run_plan(_sample_spec(files.copy()), 1, 0))
    runs.append(_run_plan(_sample_spec(files^), 3, 4))
    for i in range(len(runs)):
        ref batch = runs[i]
        var names = column_names(batch)
        assert_equal(len(names), 2)
        assert_equal(names[0], "s")
        assert_equal(names[1], "a")
        var a = int64_column(batch, 1)
        assert_equal(len(a), 9)
        for r in range(9):
            assert_equal(a[r], r + 6)
        var s = string_column(batch, 0)
        assert_equal(s[0], "s2")
        assert_equal(s[8], "s2")


def test_a_refused_iceberg_spec_is_the_runs_error() raises:
    var files = List[IcebergDataFileSpec]()
    files.append(_file(test_tmpdir() + "/gone.parquet"))
    with assert_raises():
        _ = _run_plan(_sample_spec(files^), 2, 0)


def test_an_unserved_source_kind_is_refused_listing_the_served_ones() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var dispatch = InlineDispatch()
    var unknown = SegmentDescPod(
        0,
        UInt8(200),
        SourceSpecPod(),
        Slab[MorselOp](),
        SINK_COLLECT,
        KEY_DTYPE_NONE,
        SINK_ORIENT_COLUMNAR,
        -1,
        0,
        List[Int](),
        List[UInt8](),
    )
    with assert_raises(
        contains=(
            "pipeline_exec: source kind 200 of segment 0 is not served"
            " (SOURCE_PARQUET, SOURCE_BATCH, SOURCE_SINK_OUTPUT, SOURCE_CSV,"
            " SOURCE_ICEBERG, SOURCE_CONCAT, SOURCE_JSONL and SOURCE_ORC are)"
        )
    ):
        _ = run_plan(
            _one(unknown^), builder, dispatch, 1, CancellationToken.new()
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
