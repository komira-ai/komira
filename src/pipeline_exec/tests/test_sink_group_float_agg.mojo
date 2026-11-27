# =============================================================================
# The grouped aggregation sinks over FLOAT64 and FLOAT32 arguments
# =============================================================================
#
# The tests hand a grouped sink morsels directly, naming the worker of each and
# the order they arrive in, so a dealing a real schedule could produce is
# chosen here. Each morsel carries a source position (partition id, origin
# hint) as a Parquet or resident-batch source stamps it. The expected answers
# are written from the values alone, per group: SUM and AVG each position's
# values added from +0.0 in row order, then the positions' sums added from
# +0.0 in position order; MIN and MAX in DuckDB's order of floats (NaN above
# +inf), the value first in source order kept on a tie. Every float answer is
# compared bit for bit. What they prove:
#
#   * Folding by position (ORDER_ROW_RANGE), a 2000-row table of
#     non-dyadic values in seven groups and a NULL group, cut into 17-row
#     morsels, gives each group the model's SUM, AVG, MIN, MAX, COUNT(x) and
#     COUNT(*) on 1, 4 and 16 workers, dealt round robin, in reverse and
#     scrambled, arriving in order and last first. Folded by worker on 16
#     workers some group's sum is other bits: the table's sums depend on the
#     order. Folded by worker on one worker, the answer is the row-order
#     fold.
#   * Four one-row morsels 1e16, 1, -1e16, 1 of one group sum to exactly 1.0
#     (AVG 0.25) on every worker count and dealing.
#   * A group whose values are all NULL has NULL SUM, AVG, MIN and MAX, a
#     COUNT(x) of 0 and its rows in COUNT(*), beside groups with values.
#   * NaN and infinities per group: a NaN makes SUM, AVG and MAX NaN and MIN
#     the least other value; +inf and -inf sum to NaN; a sum past the double
#     range is +inf; a group of only NaN has NaN MIN.
#   * -0.0 and 0.0 tie in MIN and MAX, and by position the one first in
#     source order is kept on every dealing, last first included; a sum of
#     -0.0 values is +0.0.
#   * A computed argument (`d * 2.0`) folds per group like a column.
#   * A FLOAT32 argument sums in double and keeps FLOAT32 MIN and MAX.
#   * 50,000 groups, more than a worker's table starts with, each reached by
#     two morsels on different workers: every group's sum and count, and the
#     pool returns every byte after `take_output`.
#   * The string-keyed sink folds the same table by position to the same
#     answers on 1, 4 and 16 workers.
#   * Refusals by name: two morsels at one position; a pool that denies a
#     grain, the per-group index or a grain's rows, each by its bytes; a
#     spill directory, which a sink folding by position does not use and
#     says why.

from std.collections import Dict
from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.column_builder import ColumnBuilder
from arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from arrow.string_array import StringArray
from containers.slab import Slab
from morsel.morsel import Morsel
from morsel.pipeline_execution import PipelineExecution
from physical_plan.physical_plan import KEY_DTYPE_I64
from pipeline_exec.plan_harness import grouped_agg_data
from pipeline_exec.segment_pool import SegmentPool
from pipeline_exec.sink_group_agg import GroupAggSink
from pipeline_exec.sink_string_group_agg import StringGroupAggSink
from plan_expr.agg_expr import (
    AGG_COUNT,
    AGG_MAX,
    AGG_MEAN,
    AGG_MIN,
    AGG_SUM,
    AggExpr,
)
from plan_expr.expr import BIN_MUL, Expr
from plan_expr.scalar_value import ScalarValue
from runtime_paths import test_tmpdir

comptime _STRIDE = 1_048_576
"""The Parquet source's partition id stride per row group (2^20)."""
comptime _NULL_KEY = -1
"""The key the tests write for a NULL group key."""


# -----------------------------------------------------------------------------
# Rows, batches and the sinks
# -----------------------------------------------------------------------------


@fieldwise_init
struct _Row(Copyable, Movable):
    var key: Int
    """The group key, `_NULL_KEY` for NULL."""
    var val: Optional[Float64]


def _bits(x: Float64) -> UInt64:
    return bitcast[DType.uint64](x)


def _batch(ref rows: List[_Row], start: Int, end: Int) raises -> RecordBatch:
    """Rows `start` to `end`: key `k` (INT64), the same key as a string `s`
    ("g<k>"), value `d` (FLOAT64) and `f` (FLOAT32, the value rounded)."""
    var kc = ColumnBuilder[DType.int64].with_capacity(end - start)
    var dc = ColumnBuilder[DType.float64].with_capacity(end - start)
    var fc = ColumnBuilder[DType.float32].with_capacity(end - start)
    var strs = List[String]()
    var valid = List[Bool]()
    for i in range(start, end):
        if rows[i].key == _NULL_KEY:
            kc.append_null()
            strs.append("")
            valid.append(False)
        else:
            kc.append(Int64(rows[i].key))
            strs.append("g" + String(rows[i].key))
            valid.append(True)
        if rows[i].val:
            dc.append(rows[i].val.value())
            fc.append(rows[i].val.value().cast[DType.float32]())
        else:
            dc.append_null()
            fc.append_null()
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    rb.add_column(kc^.materialize())
    sb.add_field(Field("s", ArrowType.STRING, True))
    rb.add_column(
        Column.from_string(StringArray.from_strings_with_validity(strs, valid))
    )
    sb.add_field(Field("d", ArrowType.FLOAT64, True))
    rb.add_column(dc^.materialize())
    sb.add_field(Field("f", ArrowType.FLOAT32, True))
    rb.add_column(fc^.materialize())
    return rb.build(sb.build())


def _agg(func: UInt8, var arg: Expr) -> AggExpr:
    return AggExpr(func, Optional(arg^), None)


def _six(arg: Expr) -> Slab[AggExpr]:
    """SUM, AVG, MIN, MAX and COUNT of `arg`, and COUNT(*)."""
    var aggs = Slab[AggExpr]()
    aggs.append(_agg(AGG_SUM, arg.copy()))
    aggs.append(_agg(AGG_MEAN, arg.copy()))
    aggs.append(_agg(AGG_MIN, arg.copy()))
    aggs.append(_agg(AGG_MAX, arg.copy()))
    aggs.append(_agg(AGG_COUNT, arg.copy()))
    aggs.append(AggExpr(AGG_COUNT, None, None))
    return aggs^


def _schema(key: ArrowType, minmax: ArrowType) raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", key, True))
    sb.add_field(Field("s", ArrowType.FLOAT64, True))
    sb.add_field(Field("a", ArrowType.FLOAT64, True))
    sb.add_field(Field("mn", minmax, True))
    sb.add_field(Field("mx", minmax, True))
    sb.add_field(Field("c", ArrowType.INT64, False))
    sb.add_field(Field("n", ArrowType.INT64, False))
    return sb.build()


def _keys(col: String) -> Slab[Expr]:
    var keys = Slab[Expr]()
    keys.append(Expr.col_ref(col))
    return keys^


def _int_sink(
    arg: Expr,
    by_position: Bool,
    minmax: ArrowType = ArrowType.FLOAT64,
    var pool: SegmentPool = SegmentPool(),
    spill_dir: String = "",
) raises -> GroupAggSink:
    return GroupAggSink(
        grouped_agg_data(_keys("k"), _six(arg), _schema(ArrowType.INT64, minmax)),
        KEY_DTYPE_I64,
        pool^,
        0,
        spill_dir=spill_dir,
        by_position=by_position,
    )


def _string_sink(arg: Expr, by_position: Bool) raises -> StringGroupAggSink:
    return StringGroupAggSink(
        grouped_agg_data(
            _keys("s"), _six(arg), _schema(ArrowType.STRING, ArrowType.FLOAT64)
        ),
        False,
        SegmentPool(),
        0,
        by_position=by_position,
    )


# -----------------------------------------------------------------------------
# Dealings and positions
# -----------------------------------------------------------------------------

comptime _ROUND_ROBIN = 0
comptime _REVERSED = 1
comptime _SCRAMBLED = 2


def _worker_of(k: Int, workers: Int, dealing: Int) -> Int:
    if dealing == _ROUND_ROBIN:
        return k % workers
    if dealing == _REVERSED:
        return workers - 1 - k % workers
    return (k * 7 + k // 3) % workers


def _position(k: Int) -> Tuple[Int, Int]:
    """A Parquet-like position for morsel k: row group 2 * (k / 3) (every
    other row group skipped, as a pruned scan does), index k % 3 in it."""
    var sub = k % 3
    return (2 * (k // 3) * _STRIDE + sub, sub)


def _morsels(n_rows: Int, morsel_rows: Int) -> Int:
    return (n_rows + morsel_rows - 1) // morsel_rows


def _deal(
    mut sink: GroupAggSink,
    ref rows: List[_Row],
    morsel_rows: Int,
    workers: Int,
    dealing: Int,
    last_first: Bool,
) raises:
    """Hand `rows`, cut into morsels of `morsel_rows`, to `sink`: morsel k at
    `_position(k)` to the worker the dealing names."""
    sink.resize_worker_state(workers)
    var n = _morsels(len(rows), morsel_rows)
    for j in range(n):
        var k = n - 1 - j if last_first else j
        var start = k * morsel_rows
        var end = min(start + morsel_rows, len(rows))
        var pos = _position(k)
        sink.consume(
            _worker_of(k, workers, dealing),
            Morsel(_batch(rows, start, end), j, pos[0], pos[1]),
        )


def _take(mut sink: GroupAggSink, workers: Int) raises -> RecordBatch:
    var pipeline = PipelineExecution(workers, 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


def _dealt(
    ref rows: List[_Row],
    morsel_rows: Int,
    workers: Int,
    dealing: Int,
    last_first: Bool,
    by_position: Bool,
    arg: Expr = Expr.col_ref("d"),
    minmax: ArrowType = ArrowType.FLOAT64,
) raises -> RecordBatch:
    var sink = _int_sink(arg, by_position, minmax)
    _deal(sink, rows, morsel_rows, workers, dealing, last_first)
    return _take(sink, workers)


def _dealt_strings(
    ref rows: List[_Row],
    morsel_rows: Int,
    workers: Int,
    dealing: Int,
    last_first: Bool,
) raises -> RecordBatch:
    var sink = _string_sink(Expr.col_ref("d"), True)
    sink.resize_worker_state(workers)
    var n = _morsels(len(rows), morsel_rows)
    for j in range(n):
        var k = n - 1 - j if last_first else j
        var start = k * morsel_rows
        var end = min(start + morsel_rows, len(rows))
        var pos = _position(k)
        sink.consume(
            _worker_of(k, workers, dealing),
            Morsel(_batch(rows, start, end), j, pos[0], pos[1]),
        )
    var pipeline = PipelineExecution(workers, 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


# -----------------------------------------------------------------------------
# The model
# -----------------------------------------------------------------------------


def _fless(a: Float64, b: Float64) -> Bool:
    """`a < b` in DuckDB's order of floats: NaN above every other value."""
    if a != a:
        return False
    if b != b:
        return True
    return a < b


struct _Want(Copyable, Movable):
    """One group's expected answers."""

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


def _model(ref rows: List[_Row], morsel_rows: Int) raises -> Dict[Int, _Want]:
    """Per group: each morsel's values added from +0.0 in row order, the
    morsels' sums added from +0.0 in position order (`_position` increases
    with k), MIN and MAX the first least or greatest in row order."""
    var out = Dict[Int, _Want]()
    var start = 0
    while start < len(rows):
        var end = min(start + morsel_rows, len(rows))
        var parts = Dict[Int, Float64]()
        for i in range(start, end):
            var key = rows[i].key
            if key not in out:
                out[key] = _Want()
            ref w = out[key]
            w.rows += 1
            if not rows[i].val:
                continue
            var v = rows[i].val.value()
            if w.count == 0 or _fless(v, w.mn):
                w.mn = v
            if w.count == 0 or _fless(w.mx, v):
                w.mx = v
            w.count += 1
            parts[key] = parts.get(key, 0.0) + v
        for e in parts.items():
            out[e.key].sum += e.value
        start = end
    return out^


def _name(key: Int) -> String:
    """A group key as the string key column writes it, "NULL" for NULL."""
    if key == _NULL_KEY:
        return "NULL"
    return "g" + String(key)


def _rows_by_name(
    ref b: RecordBatch, is_string: Bool
) raises -> Dict[String, Int]:
    var out = Dict[String, Int]()
    ref col = b.column_at(0)
    for r in range(b.num_rows()):
        var name = String("NULL")
        if not col.is_null_at(r):
            if is_string:
                name = String(col.as_string().get(r))
            else:
                name = _name(Int(col.as_primitive[DType.int64]().get(r)))
        out[name] = r
    return out^


def _row_of(ref b: RecordBatch, is_string: Bool) raises -> Dict[Int, Int]:
    """The output row of each group key of `_table` (`_NULL_KEY` for the
    NULL group), however the key column is typed."""
    var by_name = _rows_by_name(b, is_string)
    var out = Dict[Int, Int]()
    for e in by_name.items():
        var key = _NULL_KEY
        if e.key != "NULL":
            key = Int(e.key.removeprefix("g"))
        out[key] = e.value
    return out^


def _f(ref b: RecordBatch, col: Int, row: Int) raises -> Float64:
    return b.column_at(col).as_primitive[DType.float64]().get(row)


def _i(ref b: RecordBatch, col: Int, row: Int) raises -> Int:
    return Int(b.column_at(col).as_primitive[DType.int64]().get(row))


def _check(
    ref b: RecordBatch,
    ref want: Dict[Int, _Want],
    label: String,
    is_string: Bool = False,
) raises:
    """Every group of `want`, and no other, with its answers bit for bit."""
    var at = _row_of(b, is_string)
    assert_equal(len(at), len(want), label + ": groups")
    for e in want.items():
        var key = e.key
        ref w = e.value
        var tag = label + ", group " + String(key)
        assert_true(key in at, tag + " is missing")
        var r = at[key]
        assert_equal(_i(b, 6, r), w.rows, tag + " COUNT(*)")
        assert_equal(_i(b, 5, r), w.count, tag + " COUNT(d)")
        if w.count == 0:
            for c in range(1, 5):
                assert_true(b.column_at(c).is_null_at(r), tag + " NULL")
            continue
        assert_equal(_bits(_f(b, 1, r)), _bits(w.sum), tag + " SUM")
        assert_equal(
            _bits(_f(b, 2, r)),
            _bits(w.sum / Float64(w.count)),
            tag + " AVG",
        )
        assert_equal(_bits(_f(b, 3, r)), _bits(w.mn), tag + " MIN")
        assert_equal(_bits(_f(b, 4, r)), _bits(w.mx), tag + " MAX")


def _table(n: Int) -> List[_Row]:
    """Row r: key (r * 31) % 7, NULL where r % 23 == 5; value
    ((r * 7919) % 10007 - 2000) / 7, NULL where r % 6 == 4. Not dyadic, so
    the order of the additions shows in the last bits."""
    var out = List[_Row]()
    for r in range(n):
        var key = _NULL_KEY if r % 23 == 5 else (r * 31) % 7
        var v = Optional[Float64](Float64((r * 7919) % 10007 - 2000) / 7.0)
        if r % 6 == 4:
            v = None
        out.append(_Row(key, v))
    return out^


def _counts() -> List[Int]:
    var c = List[Int]()
    c.append(1)
    c.append(4)
    c.append(16)
    return c^


def _every_dealing(
    ref rows: List[_Row], morsel_rows: Int, what: String
) raises:
    """`rows` folded by position on 1, 4 and 16 workers, every dealing and
    arrival order, against the model."""
    var want = _model(rows, morsel_rows)
    var counts = _counts()
    for c in range(len(counts)):
        for dealing in range(3):
            for lf in range(2):
                var label = (
                    what
                    + ", "
                    + String(counts[c])
                    + " workers, dealing "
                    + String(dealing)
                    + ", last first "
                    + String(lf == 1)
                )
                var b = _dealt(
                    rows, morsel_rows, counts[c], dealing, lf == 1, True
                )
                _check(b, want, label)


# -----------------------------------------------------------------------------
# The same bits on every worker count and dealing
# -----------------------------------------------------------------------------


def test_group_sums_are_the_position_fold_on_1_4_and_16_workers() raises:
    var rows = _table(2000)
    _every_dealing(rows, 17, "table")
    # Folded by worker on 16 workers, some group's sum is other bits than
    # the position fold: the table's sums depend on the order.
    var want = _model(rows, 17)
    var by_worker = _dealt(rows, 17, 16, _SCRAMBLED, False, False)
    var at = _row_of(by_worker, False)
    var differs = False
    for e in want.items():
        if _bits(_f(by_worker, 1, at[e.key])) != _bits(e.value.sum):
            differs = True
    assert_true(differs, "the table must be one whose sums depend on order")
    # Folded by worker on one worker, it is the row-order fold: one morsel
    # of every row has the same model.
    var one = _dealt(rows, 17, 1, _ROUND_ROBIN, False, False)
    _check(one, _model(rows, len(rows)), "by worker, one worker")


def test_cancelling_values_of_one_group_sum_to_one() raises:
    var rows = List[_Row]()
    rows.append(_Row(3, Optional[Float64](1e16)))
    rows.append(_Row(3, Optional[Float64](1.0)))
    rows.append(_Row(3, Optional[Float64](-1e16)))
    rows.append(_Row(3, Optional[Float64](1.0)))
    _every_dealing(rows, 1, "cancelling")
    var b = _dealt(rows, 1, 16, _REVERSED, True, True)
    assert_equal(_f(b, 1, 0), 1.0)
    assert_equal(_f(b, 2, 0), 0.25)


# -----------------------------------------------------------------------------
# NULL, NaN, infinities and zeros
# -----------------------------------------------------------------------------


def test_a_group_of_only_null_values_is_null() raises:
    var rows = List[_Row]()
    for r in range(12):
        if r % 3 == 0:
            rows.append(_Row(9, None))
        else:
            rows.append(_Row(r % 2, Optional[Float64](Float64(r) + 0.5)))
    rows.append(_Row(_NULL_KEY, None))
    _every_dealing(rows, 5, "only NULL")
    for bp in range(2):
        var b = _dealt(rows, 5, 4, _ROUND_ROBIN, False, bp == 1)
        var r = _row_of(b, False)[9]
        for c in range(1, 5):
            assert_true(b.column_at(c).is_null_at(r), "only NULL values")
        assert_equal(_i(b, 5, r), 0)
        assert_equal(_i(b, 6, r), 4)


def test_nan_and_infinities_per_group() raises:
    var nan = Float64(0) / Float64(0)
    var inf = Float64.MAX * 2.0
    var rows = List[_Row]()
    # Group 0: a NaN among values. Group 1: +inf among values. Group 2: +inf
    # and -inf. Group 3: only NaN. Group 4: a sum past the double range.
    rows.append(_Row(0, Optional[Float64](1.0)))
    rows.append(_Row(1, Optional[Float64](inf)))
    rows.append(_Row(2, Optional[Float64](inf)))
    rows.append(_Row(3, Optional[Float64](nan)))
    rows.append(_Row(4, Optional[Float64](Float64.MAX)))
    rows.append(_Row(0, Optional[Float64](nan)))
    rows.append(_Row(1, Optional[Float64](-3.0)))
    rows.append(_Row(2, Optional[Float64](-inf)))
    rows.append(_Row(3, Optional[Float64](nan)))
    rows.append(_Row(4, Optional[Float64](Float64.MAX)))
    rows.append(_Row(0, Optional[Float64](-2.0)))
    _every_dealing(rows, 2, "NaN and infinities")
    var b = _dealt(rows, 2, 4, _SCRAMBLED, True, True)
    var at = _row_of(b, False)
    assert_true(_f(b, 1, at[0]) != _f(b, 1, at[0]), "SUM with a NaN is NaN")
    assert_true(_f(b, 4, at[0]) != _f(b, 4, at[0]), "MAX with a NaN is NaN")
    assert_equal(_f(b, 3, at[0]), -2.0)
    assert_equal(_f(b, 1, at[1]), inf)
    assert_equal(_f(b, 3, at[1]), -3.0)
    assert_true(_f(b, 1, at[2]) != _f(b, 1, at[2]), "inf + -inf is NaN")
    assert_equal(_f(b, 3, at[2]), -inf)
    assert_equal(_f(b, 4, at[2]), inf)
    assert_true(_f(b, 3, at[3]) != _f(b, 3, at[3]), "MIN of only NaN")
    assert_equal(_f(b, 1, at[4]), inf)


def test_min_and_max_keep_the_zero_first_in_source_order() raises:
    var rows = List[_Row]()
    # One row per morsel: group 0 meets -0.0 first, group 1 meets 0.0 first,
    # group 2 sums -0.0 values.
    rows.append(_Row(0, Optional[Float64](-0.0)))
    rows.append(_Row(1, Optional[Float64](0.0)))
    rows.append(_Row(2, Optional[Float64](-0.0)))
    rows.append(_Row(0, Optional[Float64](0.0)))
    rows.append(_Row(1, Optional[Float64](-0.0)))
    rows.append(_Row(2, Optional[Float64](-0.0)))
    _every_dealing(rows, 1, "zeros")
    var neg = _bits(-0.0)
    var pos = _bits(0.0)
    var counts = _counts()
    for c in range(len(counts)):
        for dealing in range(3):
            var b = _dealt(rows, 1, counts[c], dealing, True, True)
            var at = _row_of(b, False)
            assert_equal(_bits(_f(b, 3, at[0])), neg, "MIN keeps -0.0")
            assert_equal(_bits(_f(b, 4, at[0])), neg, "MAX keeps -0.0")
            assert_equal(_bits(_f(b, 3, at[1])), pos, "MIN keeps 0.0")
            assert_equal(_bits(_f(b, 4, at[1])), pos, "MAX keeps 0.0")
            assert_equal(_bits(_f(b, 1, at[2])), pos, "a sum of -0.0 is 0.0")


# -----------------------------------------------------------------------------
# A computed argument and FLOAT32
# -----------------------------------------------------------------------------


def test_a_computed_argument_folds_per_group() raises:
    var rows = _table(600)
    var doubled = List[_Row]()
    for i in range(len(rows)):
        var v = rows[i].val
        if v:
            v = Optional[Float64](v.value() * 2.0)
        doubled.append(_Row(rows[i].key, v))
    var want = _model(doubled, 13)
    var arg = Expr.binary(
        BIN_MUL, Expr.col_ref("d"), Expr.literal(ScalarValue.from_float(2.0))
    )
    var counts = _counts()
    for c in range(len(counts)):
        var b = _dealt(rows, 13, counts[c], _SCRAMBLED, True, True, arg)
        _check(b, want, "d * 2.0 on " + String(counts[c]) + " workers")


def test_a_float32_argument_sums_in_double_and_keeps_float32_min_max() raises:
    var rows = _table(500)
    var rounded = List[_Row]()
    for i in range(len(rows)):
        var v = rows[i].val
        if v:
            v = Optional[Float64](
                v.value().cast[DType.float32]().cast[DType.float64]()
            )
        rounded.append(_Row(rows[i].key, v))
    var want = _model(rounded, 11)
    var b = _dealt(
        rows, 11, 4, _REVERSED, False, True, Expr.col_ref("f"), ArrowType.FLOAT32
    )
    var at = _row_of(b, False)
    for e in want.items():
        var r = at[e.key]
        var tag = "FLOAT32, group " + String(e.key)
        assert_equal(_bits(_f(b, 1, r)), _bits(e.value.sum), tag + " SUM")
        var mn = b.column_at(3).as_primitive[DType.float32]().get(r)
        var mx = b.column_at(4).as_primitive[DType.float32]().get(r)
        assert_equal(mn.cast[DType.float64](), e.value.mn, tag + " MIN")
        assert_equal(mx.cast[DType.float64](), e.value.mx, tag + " MAX")


# -----------------------------------------------------------------------------
# Many groups, string keys
# -----------------------------------------------------------------------------


def test_many_groups_grow_the_tables_and_return_the_pool() raises:
    # 50,000 groups, each reached by two morsels on different workers.
    var groups = 50_000
    var rows = List[_Row]()
    for half in range(2):
        for g in range(groups):
            rows.append(_Row(g, Optional[Float64](Float64(g) / 3.0 + Float64(half))))
    var pool = SegmentPool()
    var sink = _int_sink(Expr.col_ref("d"), True, pool=pool.share())
    _deal(sink, rows, 1000, 4, _ROUND_ROBIN, True)
    var b = _take(sink, 4)
    assert_equal(b.num_rows(), groups)
    _check(b, _model(rows, 1000), "50,000 groups")
    assert_equal(pool.granted(), 0)


def test_string_keys_fold_floats_by_position_on_1_4_and_16_workers() raises:
    var rows = _table(1500)
    var want = _model(rows, 19)
    var counts = _counts()
    for c in range(len(counts)):
        for dealing in range(3):
            var label = (
                "string keys, "
                + String(counts[c])
                + " workers, dealing "
                + String(dealing)
            )
            var b = _dealt_strings(rows, 19, counts[c], dealing, dealing == 1)
            _check(b, want, label, is_string=True)


# -----------------------------------------------------------------------------
# Refusals
# -----------------------------------------------------------------------------


def test_two_morsels_at_one_position_are_refused() raises:
    var rows = _table(10)
    var sink = _int_sink(Expr.col_ref("d"), True)
    sink.resize_worker_state(2)
    sink.consume(0, Morsel(_batch(rows, 0, 5), 0, 7, 2))
    sink.consume(1, Morsel(_batch(rows, 5, 10), 1, 7, 2))
    var pipeline = PipelineExecution(2, 0)
    try:
        sink.combine(pipeline)
        assert_true(False, "two morsels at one position were merged")
    except e:
        assert_equal(
            String(e),
            "pipeline_exec: the grouped aggregation sink of segment 0 folds"
            " its float aggregates by source position, and two morsels"
            " carried position (partition 7, origin 2); its source does not"
            " stamp one position per morsel",
        )


def test_a_denied_position_entry_is_refused_by_name() raises:
    # Budgets grown 8 bytes at a time (less than any one charge) until one
    # serves the morsel: the group table is charged first, then the grain,
    # the per-group index and the grain's rows, so each of the three
    # position charges is the one denied at some budget, and the last
    # refusal before the morsel is served is the position folds'.
    var rows = _table(4)
    var budget = 0
    var refused = String("")
    var denied = List[Int]()
    while budget < 1 << 20:
        budget += 8
        var sink = _int_sink(
            Expr.col_ref("d"), True, pool=SegmentPool(budget)
        )
        sink.resize_worker_state(1)
        try:
            sink.consume(0, Morsel(_batch(rows, 0, 4), 0, 0, 0))
            break
        except e:
            refused = String(e)
            if "for its float folds by source position" in refused:
                # "... was denied <bytes> bytes ...": the charge denied.
                var at = refused.find(" was denied ") + 12
                var bytes = Int(refused[byte = at : refused.find(" bytes", at)])
                if len(denied) == 0 or denied[len(denied) - 1] != bytes:
                    denied.append(bytes)
    # The list of grains (4 grains), the per-group index (64 groups of two
    # Ints) and the grain's rows (8 rows of a group id and 4 cells of 16
    # bytes), denied in that order.
    assert_equal(len(denied), 3)
    assert_true(denied[0] > 0)
    assert_equal(denied[1], 64 * 2 * 8)
    assert_equal(denied[2], 8 * (8 + 4 * 16))
    assert_true(
        "for its float folds by source position (budget " in refused,
        "the last refusal before the budget served the morsel: " + refused,
    )
    assert_true(
        refused.startswith(
            "MEMORY_BUDGET_EXCEEDED: pipeline_exec: the grouped aggregation"
            " sink of segment 0 was denied "
        ),
        refused,
    )


def test_a_spill_directory_is_not_used_by_position() raises:
    var rows = _table(4)
    var sink = _int_sink(
        Expr.col_ref("d"),
        True,
        pool=SegmentPool(1),
        spill_dir=test_tmpdir() + "/spill",
    )
    sink.resize_worker_state(1)
    try:
        sink.consume(0, Morsel(_batch(rows, 0, 4), 0, 0, 0))
        assert_true(False, "a one-byte pool served a group table")
    except e:
        var msg = String(e)
        assert_true(
            msg.endswith(
                "; a spill directory is set, and a sink that folds its float"
                " aggregates by source position does not spill"
            ),
            msg,
        )


def test_an_unserved_argument_type_is_refused_naming_the_type() raises:
    # SUM over the STRING column `s`: the type stays refused by name in a
    # grouped sink, by position or not.
    for bp in range(2):
        var sink = _int_sink(Expr.col_ref("s"), bp == 1)
        sink.resize_worker_state(1)
        try:
            sink.consume(0, Morsel(_batch(_table(4), 0, 4), 0, 0, 0))
            assert_true(False, "SUM over a STRING column was folded")
        except e:
            assert_equal(
                String(e),
                "pipeline_exec: SUM (output column 1) is not served over this"
                " column type ("
                + String(ArrowType.STRING)
                + "): SUM, AVG, STDDEV_SAMP, STDDEV_POP, VAR_SAMP and VAR_POP"
                " take signed integers, DECIMAL128, FLOAT32 and FLOAT64; MIN"
                " and MAX also DATE32; MEDIAN and QUANTILE_CONT signed"
                " integers and FLOAT64 (over a DECIMAL128 or a FLOAT32 DuckDB's"
                " answer keeps the input's type, not the DOUBLE the plan"
                " declares)",
            )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
