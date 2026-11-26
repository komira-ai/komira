# =============================================================================
# run_sql: a grouped FLOAT / DOUBLE sum() or avg() is the same bits on every
# worker count
# =============================================================================
#
# A grouped SUM / AVG over FLOAT32 / FLOAT64 is lowered ordered by source
# position (ORDER_ROW_RANGE) and the grouped sink merges, per group, one
# partial per morsel in file order. Each test writes a Parquet table with small
# row groups (one row group is one morsel: the aggregation segment's morsel
# size is at least 1024 rows, far above 37, so a row group is never split),
# runs SQL text through `run_sql` on contexts of 1, 4 and 16 workers, several
# runs each, and compares every answer bit for bit (as UInt64) with a model
# computed HERE from the same values: per group, each row group's kept values
# added from +0.0 in row order, then the row groups' sums added from +0.0 in
# file order; MIN and MAX in DuckDB's order of floats. No answer is compared
# with another run of the engine. What each test proves:
#
#   * test_grouped_float_aggregates_match_the_model_on_1_4_and_16_workers:
#     GROUP BY an INT64 key with a NULL group, over 30 row groups of 37 rows
#     of non-dyadic values of mixed magnitude and sign with NULLs: each
#     group's sum, avg, min, max, count(v) and count(*) on every worker count
#     and run.
#   * test_a_string_keyed_grouped_float_sum_matches_the_model: the same
#     table grouped by a STRING key.
#   * test_a_two_column_key_grouped_float_sum_matches_the_model: the same
#     table grouped by the INT64 and the STRING key together (one key of
#     mixed types).
#   * test_a_grouped_sum_of_a_computed_float_input_matches_the_model:
#     sum(v * 2.0) and avg(v * 2.0) per group.
#   * test_cancelling_values_per_group_sum_to_one_on_every_worker_count: one
#     row per row group, rows 1e16, 1, -1e16, 1 in each of two groups: each
#     group's sum is exactly 1.0. Folded by worker, a dealing of the four
#     morsels to two workers can give 0.0 or 2.0.

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
from arrow.string_array import StringArray
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from runtime_paths import test_tmpdir
from sdk_exec.engine_catalog import register_parquet
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import run_sql

comptime _RUNS = 3
comptime _ROW_GROUP_ROWS = 37
comptime _ROW_GROUPS = 30
comptime _KEYS = 5
comptime _NULL_KEY = -1


def _worker_counts() -> List[Int]:
    var w = List[Int]()
    w.append(1)
    w.append(4)
    w.append(16)
    return w^


def _bits(x: Float64) -> UInt64:
    return UInt64(x.to_bits())


struct _Table(Movable):
    var key: List[Int]
    var v: List[Float64]
    var v_null: List[Bool]

    def __init__(out self):
        self.key = List[Int]()
        self.v = List[Float64]()
        self.v_null = List[Bool]()


def _mixed() -> _Table:
    """Key x % 5 (NULL where x % 17 == 3); non-dyadic values of mixed
    magnitude and sign, NULL where x % 11 == 0."""
    var scales = List[Float64]()
    scales.append(1e-3)
    scales.append(1.0)
    scales.append(1e6)
    scales.append(1e12)
    scales.append(1e-9)
    scales.append(1e15)
    scales.append(7.0)
    var t = _Table()
    for x in range(_ROW_GROUPS * _ROW_GROUP_ROWS):
        var mag = (Float64(x) * 0.1 + 1.0 / 3.0) * scales[x % len(scales)]
        if x % 3 == 1:
            mag = -mag
        t.key.append(_NULL_KEY if x % 17 == 3 else x % _KEYS)
        t.v.append(mag)
        t.v_null.append(x % 11 == 0)
    return t^


def _write(name: String, ref t: _Table, rows_per_group: Int) raises -> String:
    var n = len(t.v)
    var ka = PrimitiveArray[DType.int64].allocate_nullable(n)
    var va = PrimitiveArray[DType.float64].allocate_nullable(n)
    var strs = List[String]()
    var valid = List[Bool]()
    for x in range(n):
        va.set(x, t.v[x])
        if t.v_null[x]:
            va._set_null(x)
        if t.key[x] == _NULL_KEY:
            ka.set(x, 0)
            ka._set_null(x)
            strs.append("")
            valid.append(False)
        else:
            ka.set(x, Int64(t.key[x]))
            strs.append("g" + String(t.key[x]))
            valid.append(True)
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    sb.add_field(Field("v", ArrowType.FLOAT64, True))
    rb.add_column(Column.from_primitive[DType.int64](ka^))
    rb.add_column(
        Column.from_string(StringArray.from_strings_with_validity(strs, valid))
    )
    rb.add_column(Column.from_primitive[DType.float64](va^))
    var batch = rb.build(sb.build())
    var path = test_tmpdir() + "/sql_grouped_float_" + name + ".parquet"
    var bytes = write_record_batch_to_parquet_bytes(
        batch, max_rows_per_rg=rows_per_group
    )
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path


def _context(workers: Int, path: String) raises -> EngineContext:
    var ctx = EngineContext(EngineOptions(worker_count=workers))
    register_parquet(ctx, "t", path)
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


def _fless(a: Float64, b: Float64) -> Bool:
    """`a < b` in DuckDB's order of floats: NaN above every other value."""
    if a != a:
        return False
    if b != b:
        return True
    return a < b


struct _Group(Copyable, Movable):
    var sum: Float64
    var count: Int
    var rows: Int
    var mn: Float64
    var mx: Float64

    def __init__(out self):
        self.sum = 0.0
        self.count = 0
        self.rows = 0
        self.mn = 0.0
        self.mx = 0.0


def _model(ref t: _Table, rows_per_group: Int, scale: Float64) -> List[_Group]:
    """Per group, in output order (the NULL group first, then keys 0 to 4):
    each row group's values times `scale` added from +0.0 in row order, the
    row groups' sums added from +0.0 in file order."""
    var out = List[_Group]()
    for _ in range(_KEYS + 1):
        out.append(_Group())
    var start = 0
    while start < len(t.v):
        var end = min(start + rows_per_group, len(t.v))
        var parts = List[Float64](length=_KEYS + 1, fill=0.0)
        for x in range(start, end):
            var g = t.key[x] + 1
            out[g].rows += 1
            if t.v_null[x]:
                continue
            var v = t.v[x] * scale
            if out[g].count == 0 or _fless(v, out[g].mn):
                out[g].mn = v
            if out[g].count == 0 or _fless(out[g].mx, v):
                out[g].mx = v
            out[g].count += 1
            parts[g] += v
        for g in range(_KEYS + 1):
            out[g].sum += parts[g]
        start = end
    return out^


def _f(ref b: RecordBatch, col: Int, row: Int) raises -> Float64:
    assert_true(
        b.schema.field_arrow_type(col) == ArrowType.FLOAT64,
        "column " + String(col) + " is not declared FLOAT64",
    )
    assert_true(not b.column_at(col).is_null_at(row), "the answer is NULL")
    return b.column_at(col).as_primitive[DType.float64]().get(row)


def _i(ref b: RecordBatch, col: Int, row: Int) raises -> Int:
    return Int(b.column_at(col).as_primitive[DType.int64]().get(row))


def _check_six(
    ref b: RecordBatch, ref want: List[_Group], is_string: Bool, label: String
) raises:
    """Rows ordered NULL key first, then keys 0 to 4: columns key, sum, avg,
    min, max, count(v), count(*)."""
    assert_equal(b.num_rows(), _KEYS + 1, label)
    assert_true(b.column_at(0).is_null_at(0), label + ": the NULL group first")
    for g in range(_KEYS + 1):
        var tag = label + ", row " + String(g)
        if g > 0:
            if is_string:
                assert_equal(
                    String(b.column_at(0).as_string().get(g)),
                    "g" + String(g - 1),
                    tag,
                )
            else:
                assert_equal(_i(b, 0, g), g - 1, tag)
        ref w = want[g]
        assert_equal(_bits(_f(b, 1, g)), _bits(w.sum), tag + " sum")
        assert_equal(
            _bits(_f(b, 2, g)), _bits(w.sum / Float64(w.count)), tag + " avg"
        )
        assert_equal(_bits(_f(b, 3, g)), _bits(w.mn), tag + " min")
        assert_equal(_bits(_f(b, 4, g)), _bits(w.mx), tag + " max")
        assert_equal(_i(b, 5, g), w.count, tag + " count(v)")
        assert_equal(_i(b, 6, g), w.rows, tag + " count(*)")


def test_grouped_float_aggregates_match_the_model_on_1_4_and_16_workers() raises:
    var t = _mixed()
    var path = _write("int_key", t, _ROW_GROUP_ROWS)
    var want = _model(t, _ROW_GROUP_ROWS, 1.0)
    for w in _worker_counts():
        var ctx = _context(w, path)
        for run in range(_RUNS):
            var b = _run(
                ctx,
                "select k, sum(v), avg(v), min(v), max(v), count(v), count(*)"
                " from t group by k order by k nulls first",
            )
            _check_six(
                b,
                want,
                False,
                String(w) + " workers, run " + String(run),
            )


def test_a_string_keyed_grouped_float_sum_matches_the_model() raises:
    var t = _mixed()
    var path = _write("string_key", t, _ROW_GROUP_ROWS)
    var want = _model(t, _ROW_GROUP_ROWS, 1.0)
    for w in _worker_counts():
        var ctx = _context(w, path)
        for run in range(_RUNS):
            var b = _run(
                ctx,
                "select s, sum(v), avg(v), min(v), max(v), count(v), count(*)"
                " from t group by s order by s nulls first",
            )
            _check_six(
                b,
                want,
                True,
                "string key, " + String(w) + " workers, run " + String(run),
            )


def test_a_two_column_key_grouped_float_sum_matches_the_model() raises:
    var t = _mixed()
    var path = _write("two_keys", t, _ROW_GROUP_ROWS)
    var want = _model(t, _ROW_GROUP_ROWS, 1.0)
    for w in _worker_counts():
        var ctx = _context(w, path)
        for run in range(_RUNS):
            var b = _run(
                ctx,
                "select k, sum(v), avg(v), min(v), max(v), count(v), count(*)"
                " from t group by k, s order by k nulls first",
            )
            _check_six(
                b,
                want,
                False,
                "two keys, " + String(w) + " workers, run " + String(run),
            )


def test_a_grouped_sum_of_a_computed_float_input_matches_the_model() raises:
    var t = _mixed()
    var path = _write("computed", t, _ROW_GROUP_ROWS)
    var want = _model(t, _ROW_GROUP_ROWS, 2.0)
    for w in _worker_counts():
        var ctx = _context(w, path)
        var b = _run(
            ctx,
            "select k, sum(v * 2.0), avg(v * 2.0) from t group by k"
            " order by k nulls first",
        )
        assert_equal(b.num_rows(), _KEYS + 1)
        for g in range(_KEYS + 1):
            var tag = String(w) + " workers, row " + String(g)
            ref m = want[g]
            assert_equal(_bits(_f(b, 1, g)), _bits(m.sum), tag + " sum")
            assert_equal(
                _bits(_f(b, 2, g)),
                _bits(m.sum / Float64(m.count)),
                tag + " avg",
            )


def test_cancelling_values_per_group_sum_to_one_on_every_worker_count() raises:
    var t = _Table()
    var big = Float64(1e16)
    for g in range(2):
        t.key.append(g)
        t.v.append(big)
        t.key.append(g)
        t.v.append(1.0)
        t.key.append(g)
        t.v.append(-big)
        t.key.append(g)
        t.v.append(1.0)
    for _ in range(len(t.v)):
        t.v_null.append(False)
    # One row per row group: eight morsels, added in file order per group.
    var path = _write("cancel", t, 1)
    for w in _worker_counts():
        var ctx = _context(w, path)
        for _ in range(_RUNS):
            var b = _run(
                ctx, "select k, sum(v), avg(v) from t group by k order by k"
            )
            assert_equal(b.num_rows(), 2)
            for g in range(2):
                assert_equal(_bits(_f(b, 1, g)), _bits(1.0))
                assert_equal(_bits(_f(b, 2, g)), _bits(0.25))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
