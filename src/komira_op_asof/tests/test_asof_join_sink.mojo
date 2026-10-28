# =============================================================================
# test_asof_join_sink -- `AsofJoinSink`, end to end: consume the left side,
# sort both sides, walk, assemble (komira_op_asof.asof_join_sink)
# =============================================================================
#
# Each case is an ASOF LEFT JOIN with a hand-computed DuckDB answer:
#
#   SELECT * FROM l ASOF LEFT JOIN r ON l.k = r.k AND l.t >= r.t   (BACKWARD)
#   SELECT * FROM l ASOF LEFT JOIN r ON l.k = r.k AND l.t <= r.t   (FORWARD)
#
#   * a NULL right key whose slot holds 0 sorts among the 0 keys; it matches
#     nothing and must not hide the 0-keyed row after it;
#   * a NaN ASOF value is the largest value and equals NaN;
#   * an equal ASOF value matches (the inequality includes equality);
#   * output: left columns, then right columns nullable and renamed on a name
#     collision; an unmatched left row has NULL right columns.
# =============================================================================

from std.math import nan
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_buffer.heap_region import HeapRegion
from komira_physical_plan.physical_plan import AsofJoinSinkData
from komira_plan_ir.logical_plan import (
    ASOF_BACKWARD,
    ASOF_FORWARD,
    ASOF_NEAREST,
    AsofTolerance,
)

from komira_op_asof.asof_join_sink import AsofJoinSink


comptime I64 = DType.int64
comptime F64 = DType.float64


def _col[
    dt: DType
](values: List[Scalar[dt]], nulls: List[Bool]) raises -> Column[HeapRegion]:
    """A column of `values`; a True in `nulls` makes that row NULL (its slot
    keeps the value)."""
    var a = PrimitiveArray[dt].allocate_nullable(len(values))
    for i in range(len(values)):
        a.set(i, values[i])
        if nulls[i]:
            a._set_null(i)
    return Column.from_primitive[dt](a^)


def _no_nulls(n: Int) -> List[Bool]:
    var out = List[Bool]()
    for _ in range(n):
        out.append(False)
    return out^


def _kt_batch(
    k: List[Int64], k_nulls: List[Bool], t: List[Int64], v_name: String, v: List[Int64]
) raises -> RecordBatch:
    """Columns k (INT64, nullable), t (INT64), <v_name> (INT64)."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, True))
    sb.add_field(Field(String("t"), ArrowType.INT64, False))
    sb.add_field(Field(v_name, ArrowType.INT64, False))
    var rbb = RecordBatchBuilder.with_capacity(3)
    rbb.add_column(_col[I64](k, k_nulls))
    rbb.add_column(_col[I64](t, _no_nulls(len(t))))
    rbb.add_column(_col[I64](v, _no_nulls(len(v))))
    return rbb.build(sb.build())


def _t_batch[dt: DType](t: List[Scalar[dt]], v_name: String, v: List[Int64]) raises -> RecordBatch:
    """Columns t (`dt`), <v_name> (INT64)."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("t"), ArrowType.from_dtype(dt), False))
    sb.add_field(Field(v_name, ArrowType.INT64, False))
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(_col[dt](t, _no_nulls(len(t))))
    rbb.add_column(_col[I64](v, _no_nulls(len(v))))
    return rbb.build(sb.build())


def _spec(
    keys: List[String],
    strategy: UInt8,
    asof_dtype: DType,
    tolerance: AsofTolerance = AsofTolerance.none(),
    left_sorted: Bool = False,
    right_sorted: Bool = False,
) raises -> AsofJoinSinkData:
    """A spec over the ASOF column `t` of both sides. `left_sorted` /
    `right_sorted` fill the plan's pre-sort hint for that side."""
    var esb = SchemaBuilder()
    var left_sort = List[String]()
    var left_desc = List[Bool]()
    if left_sorted:
        left_sort.append(String("t"))
        left_desc.append(False)
    var right_sort = List[String]()
    var right_desc = List[Bool]()
    if right_sorted:
        right_sort.append(String("t"))
        right_desc.append(False)
    return AsofJoinSinkData(
        keys.copy(),
        keys.copy(),
        String("t"),
        String("t"),
        strategy,
        tolerance,
        left_sort^,
        left_desc^,
        right_sort^,
        right_desc^,
        esb.build(),
        asof_dtype=asof_dtype,
    )


def _v_at(rb: RecordBatch, col: Int, row: Int) raises -> Int64:
    return rb.column_as_primitive[I64](col).get(row)


def test_sink_null_key_among_equal_keys_hides_nothing() raises:
    """r: k=[0, NULL(slot 0), 0], t=[3, 2, 1], v=[30, 20, 10]; l: k=0, t=10.
    DuckDB: the 0-keyed rows are t=3 and t=1; the last at or before 10 is
    t=3, v=30. The sort orders r as (0,1), (NULL,2), (0,3).

    A NULL-keyed right row does not end the group: the answer is v=30, not v=10."""
    var sink = AsofJoinSink.new(_spec(["k"], ASOF_BACKWARD, I64))
    sink.consume(_kt_batch([0], [False], [10], "lv", [1]))
    var right = _kt_batch([0, 0, 0], [False, True, False], [3, 2, 1], "v", [30, 20, 10])
    var out = sink.materialize_with_right(right^)
    assert_equal(out.num_rows(), 1)
    assert_equal(out.schema.field_name(5), "v")
    assert_false(out.column_at(5).is_null_at(0), "matched")
    assert_equal(_v_at(out, 5, 0), 30, "the t=3 row, not the t=1 row")


def test_sink_null_left_key_matches_nothing() raises:
    """l: k=[0, NULL(slot 0), 0], t=[10, 15, 20]; r: k=0, t=5, v=7. Both
    0-keyed left rows get v=7; the NULL-keyed one gets NULL."""
    var sink = AsofJoinSink.new(_spec(["k"], ASOF_BACKWARD, I64))
    sink.consume(
        _kt_batch([0, 0, 0], [False, True, False], [10, 15, 20], "lv", [1, 2, 3])
    )
    var out = sink.materialize_with_right(_kt_batch([0], [False], [5], "v", [7]))
    assert_equal(out.num_rows(), 3)
    var matched = 0
    for r in range(3):
        var lv = _v_at(out, 2, r)
        if lv == 2:
            assert_true(out.column_at(5).is_null_at(r), "NULL key -> NULL v")
        else:
            assert_false(out.column_at(5).is_null_at(r))
            assert_equal(_v_at(out, 5, r), 7)
            matched += 1
    assert_equal(matched, 2, "both 0-keyed left rows match")


def test_sink_nan_asof_value_is_largest_and_equals_nan() raises:
    """No equi key. r: t=[NaN, 1.0], v=[1, 2]; l: t=[NaN, 5.0]. BACKWARD:
    NaN >= NaN, so l NaN -> v=1; 5.0 >= 1.0 and not >= NaN -> v=2.

    An IEEE `<=` would miss the NaN row; the NaN left row must not come out
    with a NULL v."""
    var sink = AsofJoinSink.new(_spec(List[String](), ASOF_BACKWARD, F64))
    var lt: List[Float64] = [nan[F64](), 5.0]
    sink.consume(_t_batch[F64](lt, "lv", [10, 20]))
    var rt: List[Float64] = [nan[F64](), 1.0]
    var out = sink.materialize_with_right(_t_batch[F64](rt, "v", [1, 2]))
    assert_equal(out.num_rows(), 2)
    for r in range(2):
        var lv = _v_at(out, 1, r)
        assert_false(out.column_at(3).is_null_at(r), "every left row matches")
        if lv == 10:
            assert_equal(_v_at(out, 3, r), 1, "NaN -> the NaN row")
        else:
            assert_equal(_v_at(out, 3, r), 2, "5.0 -> 1.0, not NaN")


def test_sink_equal_asof_value_matches() raises:
    """The inequality includes equality. BACKWARD l t=10 over r t=[5, 10]:
    the t=10 row. FORWARD l t=10 over r t=[10, 15]: the t=10 row."""
    var b = AsofJoinSink.new(_spec(List[String](), ASOF_BACKWARD, I64))
    var lt: List[Int64] = [10]
    b.consume(_t_batch[I64](lt, "lv", [1]))
    var rb: List[Int64] = [5, 10]
    var out_b = b.materialize_with_right(_t_batch[I64](rb, "v", [50, 100]))
    assert_equal(_v_at(out_b, 3, 0), 100, "BACKWARD 10 -> 10")

    var f = AsofJoinSink.new(_spec(List[String](), ASOF_FORWARD, I64))
    f.consume(_t_batch[I64](lt, "lv", [1]))
    var rf: List[Int64] = [15, 10]
    var out_f = f.materialize_with_right(_t_batch[I64](rf, "v", [150, 100]))
    assert_equal(_v_at(out_f, 3, 0), 100, "FORWARD 10 -> 10")


def test_sink_output_schema_and_unmatched_row() raises:
    """l (t, lv) and r (t, v): output t, lv, t_right, v; the right columns
    nullable. l t=5 has no right row at or before it: NULL t_right and v.
    Left batches arrive in two `consume` calls."""
    var sink = AsofJoinSink.new(_spec(List[String](), ASOF_BACKWARD, I64))
    var l0: List[Int64] = [15]
    var l1: List[Int64] = [5]
    sink.consume(_t_batch[I64](l0, "lv", [2]))
    sink.consume(_t_batch[I64](l1, "lv", [1]))
    var r: List[Int64] = [10]
    var out = sink.materialize_with_right(_t_batch[I64](r, "v", [100]))
    assert_equal(out.num_rows(), 2)
    assert_equal(out.num_columns(), 4)
    assert_equal(out.schema.field_name(0), "t")
    assert_equal(out.schema.field_name(1), "lv")
    assert_equal(out.schema.field_name(2), "t_right")
    assert_equal(out.schema.field_name(3), "v")
    assert_true(out.schema.field_nullable(2))
    assert_true(out.schema.field_nullable(3))
    # Rows come in the sorted left order: t=5, then t=15.
    assert_equal(_v_at(out, 0, 0), 5)
    assert_true(out.column_at(2).is_null_at(0), "t=5: no match")
    assert_true(out.column_at(3).is_null_at(0))
    assert_equal(_v_at(out, 0, 1), 15)
    assert_equal(_v_at(out, 2, 1), 10)
    assert_equal(_v_at(out, 3, 1), 100)


def test_sink_no_left_rows_and_materialize() raises:
    var sink = AsofJoinSink.new(_spec(List[String](), ASOF_BACKWARD, I64))
    var r: List[Int64] = [10]
    var out = sink.materialize_with_right(_t_batch[I64](r, "v", [100]))
    assert_equal(out.num_rows(), 0)
    var raised = False
    try:
        _ = sink.materialize()
    except e:
        raised = True
    assert_true(raised, "materialize without the right side raises")


def test_sink_three_left_batches_come_out_in_sorted_order() raises:
    """Three left batches (t=30, t=10, t=20) over r t=[5, 15, 25] with
    v=[50, 150, 250], BACKWARD. The output is one batch in sorted left order:
    t=10 -> 50, t=20 -> 150, t=30 -> 250."""
    var sink = AsofJoinSink.new(_spec(List[String](), ASOF_BACKWARD, I64))
    var l0: List[Int64] = [30]
    var l1: List[Int64] = [10]
    var l2: List[Int64] = [20]
    sink.consume(_t_batch[I64](l0, "lv", [3]))
    sink.consume(_t_batch[I64](l1, "lv", [1]))
    sink.consume(_t_batch[I64](l2, "lv", [2]))
    var r: List[Int64] = [5, 15, 25]
    var out = sink.materialize_with_right(_t_batch[I64](r, "v", [50, 150, 250]))
    assert_equal(out.num_rows(), 3)
    assert_equal(_v_at(out, 0, 0), 10)
    assert_equal(_v_at(out, 3, 0), 50)
    assert_equal(_v_at(out, 0, 1), 20)
    assert_equal(_v_at(out, 3, 1), 150)
    assert_equal(_v_at(out, 0, 2), 30)
    assert_equal(_v_at(out, 3, 2), 250)


def test_sink_a_side_the_plan_calls_sorted_is_not_reordered() raises:
    """With the pre-sort hint set on both sides, already sorted input joins
    as usual (l t=[10, 30] over r t=[5, 25]: 50 and 250). With the hint set
    on the left only, a left side handed over in descending order (t=30, then
    t=10) keeps that row order: the sink trusts the plan and does not sort."""
    var sorted_sink = AsofJoinSink.new(
        _spec(
            List[String](),
            ASOF_BACKWARD,
            I64,
            left_sorted=True,
            right_sorted=True,
        )
    )
    var ls: List[Int64] = [10, 30]
    sorted_sink.consume(_t_batch[I64](ls, "lv", [1, 3]))
    var rs: List[Int64] = [5, 25]
    var out = sorted_sink.materialize_with_right(
        _t_batch[I64](rs, "v", [50, 250])
    )
    assert_equal(out.num_rows(), 2)
    assert_equal(_v_at(out, 3, 0), 50)
    assert_equal(_v_at(out, 3, 1), 250)

    var kept = AsofJoinSink.new(
        _spec(List[String](), ASOF_BACKWARD, I64, left_sorted=True)
    )
    var ld: List[Int64] = [30, 10]
    kept.consume(_t_batch[I64](ld, "lv", [3, 1]))
    var rk: List[Int64] = [5]
    var out_kept = kept.materialize_with_right(_t_batch[I64](rk, "v", [50]))
    assert_equal(out_kept.num_rows(), 2)
    assert_equal(_v_at(out_kept, 0, 0), 30, "input order kept")
    assert_equal(_v_at(out_kept, 0, 1), 10, "input order kept")


def test_sink_empty_right_batch_gives_null_right_columns() raises:
    """Every left row survives with NULL right columns when the right batch
    has no rows."""
    var sink = AsofJoinSink.new(_spec(List[String](), ASOF_BACKWARD, I64))
    var l: List[Int64] = [1, 2]
    sink.consume(_t_batch[I64](l, "lv", [10, 20]))
    var r = List[Int64]()
    var out = sink.materialize_with_right(_t_batch[I64](r, "v", List[Int64]()))
    assert_equal(out.num_rows(), 2)
    assert_equal(out.num_columns(), 4)
    for row in range(2):
        assert_true(out.column_at(2).is_null_at(row), "t_right NULL")
        assert_true(out.column_at(3).is_null_at(row), "v NULL")
    assert_equal(_v_at(out, 1, 0), 10)
    assert_equal(_v_at(out, 1, 1), 20)


def test_sink_tolerance_bounds_the_match() raises:
    """BACKWARD, tolerance 2 (inclusive), r t=[8, 15]: l t=10 is 2 from 8 and
    matches; l t=20 is 5 from 15 and gets NULL."""
    var sink = AsofJoinSink.new(
        _spec(List[String](), ASOF_BACKWARD, I64, AsofTolerance.int64(2))
    )
    var l: List[Int64] = [10, 20]
    sink.consume(_t_batch[I64](l, "lv", [1, 2]))
    var r: List[Int64] = [8, 15]
    var out = sink.materialize_with_right(_t_batch[I64](r, "v", [80, 150]))
    assert_equal(out.num_rows(), 2)
    assert_equal(_v_at(out, 0, 0), 10)
    assert_false(out.column_at(3).is_null_at(0))
    assert_equal(_v_at(out, 3, 0), 80)
    assert_equal(_v_at(out, 0, 1), 20)
    assert_true(out.column_at(3).is_null_at(1), "5 away is outside 2")


def test_sink_nearest_takes_the_closest_and_ties_go_backward() raises:
    """NEAREST over r t=[9, 13]: l t=11 is 2 from both, the tie goes to the
    earlier row (9, v=90); l t=20 is closest to 13 (v=130)."""
    var sink = AsofJoinSink.new(_spec(List[String](), ASOF_NEAREST, I64))
    var l: List[Int64] = [11, 20]
    sink.consume(_t_batch[I64](l, "lv", [1, 2]))
    var r: List[Int64] = [9, 13]
    var out = sink.materialize_with_right(_t_batch[I64](r, "v", [90, 130]))
    assert_equal(out.num_rows(), 2)
    assert_equal(_v_at(out, 3, 0), 90, "tie -> backward")
    assert_equal(_v_at(out, 3, 1), 130)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
