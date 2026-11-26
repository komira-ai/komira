# =============================================================================
# run_sql: a FLOAT / DOUBLE sum() or avg() is the same bits on every worker count
# =============================================================================
#
# Covers: run_sql over a DOUBLE and a FLOAT column in small row groups on 1, 2,
# 3 and 7 workers, several runs each: an ungrouped sum() and avg() have the
# same bits on every worker count, equal to a model that adds each row group
# from +0.0 in row order and the row groups in file order (exact 1.0 / 0.25 for
# 1e16, 1, -1e16, 1; mixed magnitudes with NULLs; under a WHERE), and an
# integer sum beside them stays an exact DECIMAL(38, 0).
#
# Adding floats is not associative, so a sum that each worker folds over the
# morsels it happened to take would change with the worker count. An ungrouped
# SUM / AVG over FLOAT32 / FLOAT64 is lowered ordered by source position
# (ORDER_ROW_RANGE) and the sink merges one partial per morsel in file order.
# Each test writes a Parquet table with small row groups (one row group is one
# morsel: the aggregation segment's morsel size is at least
# MIN_MORSEL_ROWS_DEFAULT = 1024 rows, far above 37 rows, so a row group is never
# split), runs SQL text through `run_sql` on contexts of 1, 2, 3 and 7 workers,
# several runs each, and compares every answer bit for bit (bitcast to UInt64)
# with a model computed HERE from the same values: each row group's kept values
# added from +0.0 in row order, then the row groups' sums added from +0.0 in
# file order. No answer is compared with another run of the engine.
#
# What each test proves, and the defect it would catch:
#   * test_cancelling_sums_answer_the_same_exact_value_on_every_worker_count:
#     one row per row group, rows 1e16, 1.0, -1e16, 1.0 of a DOUBLE and a FLOAT
#     column: sum(v) is exactly 1.0, avg(v) 0.25, count(*) 4, and sum(f) is
#     the model's value, on 1, 2, 3 and 7 workers, ten runs each. Catches a
#     sum folded in an order that depends on which worker took which morsel
#     (1e16 + 1.0 - 1e16 is 0.0 and 1.0 + 1.0 + 1e16 - 1e16 is 0.0 when the 1.0s
#     are added first).
#   * test_a_sum_and_avg_of_mixed_magnitudes_are_bit_identical_to_the_model:
#     30 row groups of 37 rows of non-dyadic values of mixed magnitude and sign
#     with NULLs: sum(v) and avg(v) have the model's bits on every worker count
#     and run. Catches a worker-count-dependent association of the partials, or
#     an avg that divides by the row count instead of the non-NULL count.
#   * test_a_filtered_float_sum_is_bit_identical_to_the_model: the same table
#     under WHERE v > 0 gives the model's bits over the kept rows only.
#     Catches an order that follows the post-filter batches rather than the
#     source position.
#   * test_an_integer_sum_beside_a_float_sum_stays_exact: sum(i) beside sum(v)
#     is still the exact DECIMAL(38, 0) total, and the float sum beside it has
#     the model's bits.

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from runtime_paths import test_tmpdir
from scalar_arithmetic.decimal_arith import I128
from sdk_exec.engine_catalog import register_parquet
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import run_sql

comptime _RUNS = 10
comptime _ROW_GROUP_ROWS = 37
comptime _ROW_GROUPS = 30


def _worker_counts() -> List[Int]:
    var w = List[Int]()
    w.append(1)
    w.append(2)
    w.append(3)
    w.append(7)
    return w^


def _bits(x: Float64) -> UInt64:
    return UInt64(x.to_bits())


def _write(
    name: String,
    v: List[Float64],
    v_null: List[Bool],
    f: List[Float32],
    i: List[Int64],
    rows_per_group: Int,
) raises -> String:
    var n = len(v)
    var va = PrimitiveArray[DType.float64].allocate_nullable(n)
    var fa = PrimitiveArray[DType.float32].allocate_nullable(n)
    var ia = PrimitiveArray[DType.int64].allocate_nullable(n)
    for x in range(n):
        va.set(x, v[x])
        fa.set(x, f[x])
        ia.set(x, i[x])
    for x in range(n):
        if v_null[x]:
            va._set_null(x)
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("v", ArrowType.FLOAT64, True))
    sb.add_field(Field("f", ArrowType.FLOAT32, True))
    sb.add_field(Field("i", ArrowType.INT64, True))
    rb.add_column(Column.from_primitive[DType.float64](va^))
    rb.add_column(Column.from_primitive[DType.float32](fa^))
    rb.add_column(Column.from_primitive[DType.int64](ia^))
    var batch = rb.build(sb.build())
    var path = test_tmpdir() + "/sql_float_sum_" + name + ".parquet"
    var bytes = write_record_batch_to_parquet_bytes(
        batch, max_rows_per_rg=rows_per_group
    )
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path


def _context(workers: Int, table: String, path: String) raises -> EngineContext:
    var ctx = EngineContext(EngineOptions(worker_count=workers))
    register_parquet(ctx, table, path)
    return ctx^


def _run(mut ctx: EngineContext, sql: String) raises -> RecordBatch:
    var out = run_sql(ctx, sql)
    if out.refusal:
        assert_true(
            False,
            "refused at "
            + out.refusal.value().step
            + ": "
            + out.refusal.value().reason
            + " -- "
            + sql,
        )
    assert_equal(len(out.batches), 1)
    return out.batches.pop(0)


def _double(ref batch: RecordBatch, col: Int) raises -> Float64:
    assert_true(
        batch.schema.field_arrow_type(col) == ArrowType.FLOAT64,
        "column " + String(col) + " is not declared FLOAT64",
    )
    assert_true(not batch.column_at(col).is_null_at(0), "the answer is NULL")
    return batch.column_at(col).as_primitive[DType.float64]().get(0)


struct _Model(Movable):
    """The expected sum and non-NULL count of the kept rows of column v."""

    var sum: Float64
    var count: Int

    def __init__(out self, sum: Float64, count: Int):
        self.sum = sum
        self.count = count

    def avg(self) -> Float64:
        return self.sum / Float64(self.count)


def _model(
    v: List[Float64], v_null: List[Bool], rows_per_group: Int, positive_only: Bool
) -> _Model:
    """Each row group's kept values added from +0.0 in row order, the row
    groups' sums added from +0.0 in file order."""
    var total = Float64(0.0)
    var count = 0
    var start = 0
    while start < len(v):
        var part = Float64(0.0)
        var end = min(start + rows_per_group, len(v))
        for x in range(start, end):
            if v_null[x]:
                continue
            if positive_only and not (v[x] > 0.0):
                continue
            part += v[x]
            count += 1
        total += part
        start = end
    return _Model(total, count)


def _mixed(
    mut v: List[Float64],
    mut v_null: List[Bool],
    mut f: List[Float32],
    mut i: List[Int64],
):
    """Non-dyadic values of mixed magnitude and sign, with some NULLs."""
    var scales = List[Float64]()
    scales.append(1e-3)
    scales.append(1.0)
    scales.append(1e6)
    scales.append(1e12)
    scales.append(1e-9)
    scales.append(1e15)
    scales.append(7.0)
    for x in range(_ROW_GROUPS * _ROW_GROUP_ROWS):
        var mag = (Float64(x) * 0.1 + 1.0 / 3.0) * scales[x % len(scales)]
        if x % 3 == 1:
            mag = -mag
        v.append(mag)
        v_null.append(x % 11 == 0)
        f.append(Float32(mag))
        i.append(Int64(x) * 1000003)


def test_cancelling_sums_answer_the_same_exact_value_on_every_worker_count() raises:
    var v = List[Float64]()
    var v_null = List[Bool]()
    var f = List[Float32]()
    var i = List[Int64]()
    var big = Float64(1e16)
    v.append(big)
    v.append(1.0)
    v.append(-big)
    v.append(1.0)
    for x in range(4):
        v_null.append(False)
        f.append(Float32(v[x]))
        i.append(Int64(x))
    # One row per row group: four morsels, added in file order.
    var path = _write("cancel", v, v_null, f, i, 1)
    var f_model = Float64(0.0)
    for x in range(4):
        f_model += Float64(f[x])
    for w in _worker_counts():
        var ctx = _context(w, "t", path)
        for _ in range(_RUNS):
            var batch = _run(
                ctx, "select sum(v), avg(v), sum(f), count(*) from t"
            )
            assert_equal(batch.num_rows(), 1)
            assert_equal(_bits(_double(batch, 0)), _bits(1.0))
            assert_equal(_bits(_double(batch, 1)), _bits(0.25))
            assert_equal(_bits(_double(batch, 2)), _bits(f_model))
            assert_equal(
                batch.column_at(3).as_primitive[DType.int64]().get(0), Int64(4)
            )


def test_a_sum_and_avg_of_mixed_magnitudes_are_bit_identical_to_the_model() raises:
    var v = List[Float64]()
    var v_null = List[Bool]()
    var f = List[Float32]()
    var i = List[Int64]()
    _mixed(v, v_null, f, i)
    var path = _write("mixed", v, v_null, f, i, _ROW_GROUP_ROWS)
    var m = _model(v, v_null, _ROW_GROUP_ROWS, False)
    for w in _worker_counts():
        var ctx = _context(w, "t", path)
        for _ in range(_RUNS):
            var batch = _run(ctx, "select sum(v), avg(v) from t")
            assert_equal(_bits(_double(batch, 0)), _bits(m.sum))
            assert_equal(_bits(_double(batch, 1)), _bits(m.avg()))


def test_a_filtered_float_sum_is_bit_identical_to_the_model() raises:
    var v = List[Float64]()
    var v_null = List[Bool]()
    var f = List[Float32]()
    var i = List[Int64]()
    _mixed(v, v_null, f, i)
    var path = _write("filtered", v, v_null, f, i, _ROW_GROUP_ROWS)
    var m = _model(v, v_null, _ROW_GROUP_ROWS, True)
    for w in _worker_counts():
        var ctx = _context(w, "t", path)
        for _ in range(_RUNS):
            var batch = _run(
                ctx, "select sum(v), avg(v) from t where v > 0"
            )
            assert_equal(_bits(_double(batch, 0)), _bits(m.sum))
            assert_equal(_bits(_double(batch, 1)), _bits(m.avg()))


def test_an_integer_sum_beside_a_float_sum_stays_exact() raises:
    var v = List[Float64]()
    var v_null = List[Bool]()
    var f = List[Float32]()
    var i = List[Int64]()
    _mixed(v, v_null, f, i)
    var path = _write("beside", v, v_null, f, i, _ROW_GROUP_ROWS)
    var m = _model(v, v_null, _ROW_GROUP_ROWS, False)
    var want = I128(0)
    for x in range(len(i)):
        want += Scalar[DType.int64](i[x]).cast[DType.int128]()
    for w in _worker_counts():
        var ctx = _context(w, "t", path)
        var batch = _run(ctx, "select sum(i), sum(v) from t")
        assert_true(
            batch.schema.field_arrow_type(0) == ArrowType.DECIMAL128,
            "sum(i) is not DECIMAL128",
        )
        assert_true(
            batch.column_at(0).as_decimal128().get_i128(0) == want,
            "sum(i) is not exact",
        )
        assert_equal(_bits(_double(batch, 1)), _bits(m.sum))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
