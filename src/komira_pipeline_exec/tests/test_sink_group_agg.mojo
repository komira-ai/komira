# =============================================================================
# The grouped aggregation sink over fixed-width keys, fed morsels directly
# =============================================================================
#
# The tests hand the sink morsels, a different worker for each, so every
# worker's table is non-empty when `combine` merges them (the driver's
# single-thread dispatchers let the first worker drain the source). The
# expected answers come from a plain loop over the rows with a `Dict` from the
# key's text to a running tally, written here from the row number alone
# (`group_harness` says what each cell of row r holds), never from the engine.
# What they prove:
#
#   * One key (an INT64 with NULLs) and two keys (INT64 and INT32, both with
#     NULLs): every group has the oracle's COUNT(*), COUNT, SUM, MIN, MAX, AVG
#     (the AVG bit for bit) and DECIMAL SUM, the number of groups is the
#     oracle's, and rows whose key is NULL form their own group.
#   * The same answer for one to five workers and for the rows dealt in
#     order and in reverse, so the merge does not depend on who held what.
#   * A DECIMAL(38,0) value of 10^38 - 1 under one key in each of two workers
#     is refused by the merge, and the same values under two different keys
#     are not: the overflow rule is per group and the merge is what hits it.
#   * FLOAT64 and FLOAT32 keys: -0.0 and 0.0 are one group (whose key is +0.0,
#     asserted on the bits), every NaN is one group (five bit patterns each:
#     quiet, negative, signalling, with a payload, all ones), NULL is another.
#   * INT8 and INT16 keys, negative values and NULLs included.
#   * A sum that overflows inside one worker is refused at its row; a table
#     that would pass its group limit is refused by name, in a worker and in
#     the merge.
#   * No rows: no group, and the declared columns.
#   * What the sink refuses by name: a key column of the wrong family for its
#     row, a declared key type that is not a key type of the row, a declared
#     key type that is not the input's, no group-by expression.
#   * Memory: the pool is charged as the tables grow (more groups, more held),
#     growth past the budget is refused by name in a worker and in the merge,
#     and the pool is whole again after take_output, after a refusal and after
#     the sink is dropped without a combine.

from std.collections import Dict
from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_collections.slab import Slab
from komira_morsel.morsel import Morsel
from komira_morsel.pipeline_execution import PipelineExecution
from komira_physical_plan.physical_plan import (
    AggSinkData,
    KEY_DTYPE_F32,
    KEY_DTYPE_F64,
    KEY_DTYPE_I32,
    KEY_DTYPE_I64,
)
from komira_pipeline_exec.group_harness import (
    d_null,
    d_unscaled,
    float_batch,
    float_class,
    float_null,
    group_batch,
    k16_value,
    k1_null,
    k1_value,
    k2_null,
    k2_value,
    k8_null,
    k8_value,
    nan_batch,
    small_int_batch,
    v_null,
    v_value,
)
from komira_pipeline_exec.group_table import GroupTable
from komira_pipeline_exec.plan_harness import grouped_agg_data
from komira_pipeline_exec.segment_pool import SegmentPool
from komira_pipeline_exec.sink_group_agg import GroupAggSink
from komira_plan_expr.agg_expr import (
    AGG_COUNT,
    AGG_MAX,
    AGG_MEAN,
    AGG_MIN,
    AGG_SUM,
    AggExpr,
)
from komira_plan_expr.expr import Expr
from komira_scalar_arithmetic.decimal_arith import I128


def _agg(func: UInt8, col: String) -> AggExpr:
    return AggExpr(func, Optional(Expr.col_ref(col)), None)


def _aggs() -> Slab[AggExpr]:
    var aggs = Slab[AggExpr]()
    aggs.append(AggExpr(AGG_COUNT, None, None))
    aggs.append(_agg(AGG_COUNT, "v"))
    aggs.append(_agg(AGG_SUM, "v"))
    aggs.append(_agg(AGG_MIN, "v"))
    aggs.append(_agg(AGG_MAX, "v"))
    aggs.append(_agg(AGG_MEAN, "v"))
    aggs.append(_agg(AGG_SUM, "d"))
    return aggs^


def _schema(keys: List[ArrowType]) raises -> Schema:
    var sb = SchemaBuilder()
    for k in range(len(keys)):
        sb.add_field(Field("key" + String(k), keys[k], True))
    sb.add_field(Field("cs", ArrowType.INT64, False))
    sb.add_field(Field("cv", ArrowType.INT64, False))
    sb.add_field(Field("sv", ArrowType.INT64, True))
    sb.add_field(Field("mn", ArrowType.INT64, True))
    sb.add_field(Field("mx", ArrowType.INT64, True))
    sb.add_field(Field("av", ArrowType.FLOAT64, True))
    sb.add_field(Field.decimal128("sd", 38, 2, True))
    return sb.build()


def _keys(names: List[String]) -> Slab[Expr]:
    var out = Slab[Expr]()
    for i in range(len(names)):
        out.append(Expr.col_ref(names[i]))
    return out^


def _names1() -> List[String]:
    var out = List[String]()
    out.append("k1")
    return out^


def _names2() -> List[String]:
    var out = List[String]()
    out.append("k1")
    out.append("k2")
    return out^


def _types1() -> List[ArrowType]:
    var out = List[ArrowType]()
    out.append(ArrowType.INT64)
    return out^


def _types2() -> List[ArrowType]:
    var out = List[ArrowType]()
    out.append(ArrowType.INT64)
    out.append(ArrowType.INT32)
    return out^


def _data(two: Bool) raises -> AggSinkData:
    if two:
        return grouped_agg_data(_keys(_names2()), _aggs(), _schema(_types2()))
    return grouped_agg_data(_keys(_names1()), _aggs(), _schema(_types1()))


def _combine_and_take(mut sink: GroupAggSink, workers: Int) raises -> RecordBatch:
    var pipeline = PipelineExecution(workers, 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


def _run_rows(
    rows: Int, morsel: Int, workers: Int, reverse: Bool, two: Bool
) raises -> RecordBatch:
    """Rows 0 .. rows - 1 in morsels of `morsel`, morsel m going to worker
    m % workers (or workers - 1 - m % workers when `reverse`)."""
    var sink = GroupAggSink(_data(two), KEY_DTYPE_I64, SegmentPool(), 0)
    sink.resize_worker_state(workers)
    var m = 0
    var start = 0
    while start < rows:
        var n = min(morsel, rows - start)
        var w = m % workers
        if reverse:
            w = workers - 1 - w
        sink.consume(w, Morsel(group_batch(start, n), m, 0))
        m += 1
        start += n
    return _combine_and_take(sink, workers)


struct _Tally(Copyable, Movable):
    var rows: Int
    var cnt_v: Int
    var sum_v: Int
    var min_v: Int
    var max_v: Int
    var sum_d: Int
    var cnt_d: Int

    def __init__(out self):
        self.rows = 0
        self.cnt_v = 0
        self.sum_v = 0
        self.min_v = 0
        self.max_v = 0
        self.sum_d = 0
        self.cnt_d = 0


def _key_text(r: Int, two: Bool) -> String:
    var s = String("N") if k1_null(r) else String(k1_value(r))
    if two:
        s += "|" + (String("N") if k2_null(r) else String(k2_value(r)))
    return s^


struct _Oracle(Movable):
    var index: Dict[String, Int]
    var tallies: List[_Tally]

    def __init__(out self, rows: Int, two: Bool) raises:
        self.index = Dict[String, Int]()
        self.tallies = List[_Tally]()
        for r in range(rows):
            var key = _key_text(r, two)
            if key not in self.index:
                self.index[key] = len(self.tallies)
                self.tallies.append(_Tally())
            var at = self.index[key]
            self.tallies[at].rows += 1
            if not v_null(r):
                var v = v_value(r)
                if self.tallies[at].cnt_v == 0:
                    self.tallies[at].min_v = v
                    self.tallies[at].max_v = v
                else:
                    self.tallies[at].min_v = min(self.tallies[at].min_v, v)
                    self.tallies[at].max_v = max(self.tallies[at].max_v, v)
                self.tallies[at].cnt_v += 1
                self.tallies[at].sum_v += v
            if not d_null(r):
                self.tallies[at].cnt_d += 1
                self.tallies[at].sum_d += d_unscaled(r)


def _check(ref out: RecordBatch, rows: Int, two: Bool) raises:
    var want = _Oracle(rows, two)
    var nk = 2 if two else 1
    assert_equal(out.num_rows(), len(want.tallies), "number of groups")
    assert_equal(out.num_columns(), nk + 7)
    var seen = List[Bool](length=len(want.tallies), fill=False)
    var k1 = out.column_at(0).as_primitive[DType.int64]()
    for i in range(out.num_rows()):
        var key = String("N") if out.column_at(0).is_null_at(i) else String(
            Int(k1.get(i))
        )
        if two:
            var k2 = out.column_at(1).as_primitive[DType.int32]()
            key += "|" + (
                String("N") if out.column_at(1).is_null_at(i) else String(
                    Int(k2.get(i))
                )
            )
        assert_true(key in want.index, "unexpected group " + key)
        var at = want.index[key]
        assert_true(not seen[at], "group " + key + " twice")
        seen[at] = True
        ref t = want.tallies[at]
        var cs = out.column_at(nk).as_primitive[DType.int64]()
        var cv = out.column_at(nk + 1).as_primitive[DType.int64]()
        assert_equal(Int(cs.get(i)), t.rows, "COUNT(*) of " + key)
        assert_equal(Int(cv.get(i)), t.cnt_v, "COUNT(v) of " + key)
        for c in range(2, 6):
            assert_equal(
                out.column_at(nk + c).is_null_at(i),
                t.cnt_v == 0,
                "NULL-ness of column " + String(c) + " of " + key,
            )
        if t.cnt_v > 0:
            var sv = out.column_at(nk + 2).as_primitive[DType.int64]()
            var mn = out.column_at(nk + 3).as_primitive[DType.int64]()
            var mx = out.column_at(nk + 4).as_primitive[DType.int64]()
            var av = out.column_at(nk + 5).as_primitive[DType.float64]()
            assert_equal(Int(sv.get(i)), t.sum_v, "SUM(v) of " + key)
            assert_equal(Int(mn.get(i)), t.min_v, "MIN(v) of " + key)
            assert_equal(Int(mx.get(i)), t.max_v, "MAX(v) of " + key)
            assert_equal(
                av.get(i), Float64(t.sum_v) / Float64(t.cnt_v), "AVG of " + key
            )
        assert_equal(
            out.column_at(nk + 6).is_null_at(i), t.cnt_d == 0, "SUM(d) NULL"
        )
        if t.cnt_d > 0:
            var sd = out.column_at(nk + 6).as_decimal128()
            assert_true(
                sd.get_i128(i) == I128(t.sum_d), "SUM(d) of " + key
            )
    for at in range(len(seen)):
        assert_true(seen[at], "a group of the oracle is missing")


def test_one_key_with_null_keys_matches_the_oracle() raises:
    var oracle = _Oracle(500, False)
    assert_true("N" in oracle.index, "the table has no NULL key")
    _check(_run_rows(500, 37, 4, False, False), 500, False)


def test_two_keys_with_null_keys_match_the_oracle() raises:
    var oracle = _Oracle(900, True)
    assert_true("N|N" in oracle.index and "3|N" in oracle.index)
    assert_true(len(oracle.tallies) > 30, "too few groups to mean much")
    _check(_run_rows(900, 41, 4, False, True), 900, True)


def test_any_worker_count_and_dealing_gives_the_same_groups() raises:
    for workers in range(1, 6):
        _check(_run_rows(600, 29, workers, False, True), 600, True)
        _check(_run_rows(600, 29, workers, True, True), 600, True)


def test_no_row_gives_no_group_and_the_declared_columns() raises:
    var sink = GroupAggSink(_data(True), KEY_DTYPE_I64, SegmentPool(), 0)
    sink.resize_worker_state(3)
    var out = _combine_and_take(sink, 3)
    assert_equal(out.num_rows(), 0)
    assert_equal(out.num_columns(), 9)
    assert_equal(out.schema.field_arrow_type(1), ArrowType.INT32)


def _nines_batch(keys: List[Int]) raises -> RecordBatch:
    var nines = I128(1)
    for _ in range(38):
        nines = nines * I128(10)
    nines = nines - I128(1)
    var k = PrimitiveArray[DType.int64].allocate(len(keys))
    var d = Decimal128Array.allocate_nullable(len(keys), 38, 0)
    for i in range(len(keys)):
        k.set(i, Int64(keys[i]))
        d.set_i128(i, nines)
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    rb.add_column(Column.from_primitive[DType.int64](k^))
    sb.add_field(Field.decimal128("d", 38, 0, True))
    rb.add_column(Column.from_decimal128(d^))
    return rb.build(sb.build())


def _nines_sink() raises -> GroupAggSink:
    var keys = Slab[Expr]()
    keys.append(Expr.col_ref("k"))
    var aggs = Slab[AggExpr]()
    aggs.append(_agg(AGG_SUM, "d"))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field.decimal128("s", 38, 0, True))
    return GroupAggSink(
        grouped_agg_data(keys^, aggs^, sb.build()),
        KEY_DTYPE_I64,
        SegmentPool(),
        0,
    )


def _one(k: Int) -> List[Int]:
    var out = List[Int]()
    out.append(k)
    return out^


def test_a_group_summed_over_two_workers_overflows_only_in_the_merge() raises:
    var sink = _nines_sink()
    sink.resize_worker_state(2)
    # Each worker folds one value under key 7: no fold sees an overflow.
    sink.consume(0, Morsel(_nines_batch(_one(7)), 0, 0))
    sink.consume(1, Morsel(_nines_batch(_one(7)), 1, 0))
    with assert_raises(contains="left the 128-bit range"):
        _ = _combine_and_take(sink, 2)


def test_the_same_values_under_different_keys_do_not_overflow() raises:
    var sink = _nines_sink()
    sink.resize_worker_state(2)
    sink.consume(0, Morsel(_nines_batch(_one(7)), 0, 0))
    sink.consume(1, Morsel(_nines_batch(_one(8)), 1, 0))
    var out = _combine_and_take(sink, 2)
    assert_equal(out.num_rows(), 2)
    var sums = out.column_at(1).as_decimal128()
    assert_true(sums.get_i128(0) == sums.get_i128(1))


def test_null_is_a_group_of_its_own_and_not_zero() raises:
    # Keys: NULL, 0, NULL, 0, 0 -> two groups of two and three rows.
    var k = PrimitiveArray[DType.int64].allocate_nullable(5)
    k.set(0, 0)
    k._set_null(0)
    k.set(1, 0)
    k.set(2, 0)
    k._set_null(2)
    k.set(3, 0)
    k.set(4, 0)
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    rb.add_column(Column.from_primitive[DType.int64](k^))
    var keys = Slab[Expr]()
    keys.append(Expr.col_ref("k"))
    var aggs = Slab[AggExpr]()
    aggs.append(AggExpr(AGG_COUNT, None, None))
    var osb = SchemaBuilder()
    osb.add_field(Field("k", ArrowType.INT64, True))
    osb.add_field(Field("n", ArrowType.INT64, False))
    var sink = GroupAggSink(
        grouped_agg_data(keys^, aggs^, osb.build()),
        KEY_DTYPE_I64,
        SegmentPool(),
        0,
    )
    sink.resize_worker_state(1)
    sink.consume(0, Morsel(rb.build(sb.build()), 0, 0))
    var out = _combine_and_take(sink, 1)
    assert_equal(out.num_rows(), 2)
    var n = out.column_at(1).as_primitive[DType.int64]()
    for i in range(2):
        var is_null = out.column_at(0).is_null_at(i)
        assert_equal(Int(n.get(i)), 2 if is_null else 3)


def _float_sink(key_type: ArrowType, key_dtype: UInt8, key_col: String) raises -> GroupAggSink:
    var keys = Slab[Expr]()
    keys.append(Expr.col_ref(key_col))
    var aggs = Slab[AggExpr]()
    aggs.append(AggExpr(AGG_COUNT, None, None))
    aggs.append(_agg(AGG_SUM, "v"))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", key_type, True))
    sb.add_field(Field("n", ArrowType.INT64, False))
    sb.add_field(Field("sv", ArrowType.INT64, True))
    return GroupAggSink(
        grouped_agg_data(keys^, aggs^, sb.build()),
        key_dtype,
        SegmentPool(),
        0,
    )


def _class_of_row(r: Int) -> String:
    if float_null(r):
        return "N"
    var c = float_class(r)
    if c <= 1:
        return "zero"
    if c == 2:
        return "nan"
    return "plain"


def _check_float_groups(ref out: RecordBatch, rows: Int, f32: Bool) raises:
    var want_n = Dict[String, Int]()
    var want_sum = Dict[String, Int]()
    for r in range(rows):
        var c = _class_of_row(r)
        want_n[c] = want_n.get(c, 0) + 1
        if not v_null(r):
            want_sum[c] = want_sum.get(c, 0) + v_value(r)
    assert_equal(out.num_rows(), 4, "N, zero, nan and plain")
    var n = out.column_at(1).as_primitive[DType.int64]()
    var sv = out.column_at(2).as_primitive[DType.int64]()
    for i in range(out.num_rows()):
        var c = String("N")
        if not out.column_at(0).is_null_at(i):
            var v = Float64(0)
            if f32:
                v = out.column_at(0).as_primitive[DType.float32]().get(i).cast[
                    DType.float64
                ]()
            else:
                v = out.column_at(0).as_primitive[DType.float64]().get(i)
            if v != v:
                c = "nan"
            elif v == 0.0:
                c = "zero"
                # The group's key is +0.0 whichever zero came first.
                assert_equal(bitcast[DType.int64](v), 0, "sign of the zero key")
            else:
                c = "plain"
        assert_equal(Int(n.get(i)), want_n[c], "COUNT(*) of " + c)
        assert_equal(Int(sv.get(i)), want_sum.get(c, 0), "SUM of " + c)


def test_float64_keys_group_signed_zeros_and_nans_together() raises:
    var sink = _float_sink(ArrowType.FLOAT64, KEY_DTYPE_F64, "kf")
    sink.resize_worker_state(3)
    for m in range(6):
        sink.consume(m % 3, Morsel(float_batch(m * 12, 12), m, 0))
    _check_float_groups(_combine_and_take(sink, 3), 72, False)


def test_float32_keys_group_signed_zeros_and_nans_together() raises:
    var sink = _float_sink(ArrowType.FLOAT32, KEY_DTYPE_F32, "kg")
    sink.resize_worker_state(3)
    for m in range(6):
        sink.consume(m % 3, Morsel(float_batch(m * 12, 12), m, 0))
    _check_float_groups(_combine_and_take(sink, 3), 72, True)


def test_a_key_column_of_the_wrong_family_is_refused_by_name() raises:
    var ints_as_floats = _float_sink(ArrowType.FLOAT64, KEY_DTYPE_F64, "k1")
    ints_as_floats.resize_worker_state(1)
    with assert_raises(contains="the F64 and F32 rows key FLOAT32 and FLOAT64"):
        ints_as_floats.consume(0, Morsel(group_batch(0, 10), 0, 0))
    var floats_as_ints = _float_sink(ArrowType.INT64, KEY_DTYPE_I64, "kf")
    floats_as_ints.resize_worker_state(1)
    with assert_raises(contains="the I64 and I32 rows key INT8 to INT64"):
        floats_as_ints.consume(0, Morsel(float_batch(0, 10), 0, 0))


def test_what_the_sink_refuses_when_it_is_built() raises:
    with assert_raises(contains="declares output column 0 (a key) as"):
        _ = _float_sink(ArrowType.STRING, KEY_DTYPE_I64, "k1")
    with assert_raises(contains="declares output column 0 (a key) as"):
        _ = _float_sink(ArrowType.FLOAT64, KEY_DTYPE_I64, "k1")
    with assert_raises(contains="has no group-by expression"):
        var aggs = Slab[AggExpr]()
        aggs.append(AggExpr(AGG_COUNT, None, None))
        var sb = SchemaBuilder()
        sb.add_field(Field("n", ArrowType.INT64, False))
        _ = GroupAggSink(
            grouped_agg_data(Slab[Expr](), aggs^, sb.build()),
            KEY_DTYPE_I64,
            SegmentPool(),
            0,
        )
    with assert_raises(contains="declares 1 output columns for 1 keys and 2"):
        var keys = Slab[Expr]()
        keys.append(Expr.col_ref("k1"))
        var aggs = Slab[AggExpr]()
        aggs.append(AggExpr(AGG_COUNT, None, None))
        aggs.append(AggExpr(AGG_COUNT, None, None))
        var sb = SchemaBuilder()
        sb.add_field(Field("k", ArrowType.INT64, True))
        _ = GroupAggSink(
            grouped_agg_data(keys^, aggs^, sb.build()),
            KEY_DTYPE_I64,
            SegmentPool(),
            0,
        )


def test_a_declared_key_type_that_is_not_the_inputs_is_refused() raises:
    # k1 is INT64; the plan declares INT32.
    var sink = _float_sink(ArrowType.INT32, KEY_DTYPE_I32, "k1")
    sink.resize_worker_state(1)
    sink.consume(0, Morsel(group_batch(0, 10), 0, 0))
    with assert_raises(contains="cannot fill the declared output type"):
        _ = _combine_and_take(sink, 1)


def test_nans_of_every_bit_pattern_are_one_group_in_float64() raises:
    var sink = _float_sink(ArrowType.FLOAT64, KEY_DTYPE_F64, "kf")
    sink.resize_worker_state(2)
    sink.consume(0, Morsel(nan_batch(), 0, 0))
    sink.consume(1, Morsel(nan_batch(), 1, 0))
    _check_nan_groups(_combine_and_take(sink, 2), False)


def test_nans_of_every_bit_pattern_are_one_group_in_float32() raises:
    var sink = _float_sink(ArrowType.FLOAT32, KEY_DTYPE_F32, "kg")
    sink.resize_worker_state(2)
    sink.consume(0, Morsel(nan_batch(), 0, 0))
    sink.consume(1, Morsel(nan_batch(), 1, 0))
    _check_nan_groups(_combine_and_take(sink, 2), True)


def _check_nan_groups(ref out: RecordBatch, f32: Bool) raises:
    # Five NaN rows and two rows of 1.5, in each of two workers: v sums to
    # 0+1+2+3+4 = 10 and 5+6 = 11 per worker.
    assert_equal(out.num_rows(), 2, "all NaNs are one group, 1.5 another")
    var n = out.column_at(1).as_primitive[DType.int64]()
    var sv = out.column_at(2).as_primitive[DType.int64]()
    var nans = 0
    for i in range(2):
        var v = Float64(0)
        if f32:
            v = out.column_at(0).as_primitive[DType.float32]().get(i).cast[
                DType.float64
            ]()
        else:
            v = out.column_at(0).as_primitive[DType.float64]().get(i)
        if v != v:
            nans += 1
            assert_equal(Int(n.get(i)), 10)
            assert_equal(Int(sv.get(i)), 20)
        else:
            assert_equal(v, 1.5)
            assert_equal(Int(n.get(i)), 4)
            assert_equal(Int(sv.get(i)), 22)
    assert_equal(nans, 1)


def test_int8_and_int16_keys_group_by_value_with_negatives_and_nulls() raises:
    var keys = Slab[Expr]()
    keys.append(Expr.col_ref("k8"))
    keys.append(Expr.col_ref("k16"))
    var aggs = Slab[AggExpr]()
    aggs.append(AggExpr(AGG_COUNT, None, None))
    aggs.append(_agg(AGG_SUM, "v"))
    var sb = SchemaBuilder()
    sb.add_field(Field("k8", ArrowType.INT8, True))
    sb.add_field(Field("k16", ArrowType.INT16, True))
    sb.add_field(Field("n", ArrowType.INT64, False))
    sb.add_field(Field("sv", ArrowType.INT64, True))
    var sink = GroupAggSink(
        grouped_agg_data(keys^, aggs^, sb.build()),
        KEY_DTYPE_I32,
        SegmentPool(),
        0,
    )
    sink.resize_worker_state(3)
    for m in range(8):
        sink.consume(m % 3, Morsel(small_int_batch(m * 50, 50), m, 0))
    var out = _combine_and_take(sink, 3)
    var want_n = Dict[String, Int]()
    var want_sum = Dict[String, Int]()
    var negative = False
    for r in range(400):
        var key = (
            String("N") if k8_null(r) else String(k8_value(r))
        ) + "|" + String(k16_value(r))
        negative = negative or (not k8_null(r) and k8_value(r) < 0)
        want_n[key] = want_n.get(key, 0) + 1
        want_sum[key] = want_sum.get(key, 0) + v_value(r)
    assert_true(negative, "the fixture has no negative INT8 key")
    assert_equal(out.num_rows(), len(want_n))
    assert_equal(out.schema.field_arrow_type(0), ArrowType.INT8)
    assert_equal(out.schema.field_arrow_type(1), ArrowType.INT16)
    var k8 = out.column_at(0).as_primitive[DType.int8]()
    var k16 = out.column_at(1).as_primitive[DType.int16]()
    var n = out.column_at(2).as_primitive[DType.int64]()
    var sv = out.column_at(3).as_primitive[DType.int64]()
    for i in range(out.num_rows()):
        var key = (
            String("N") if out.column_at(0).is_null_at(i) else String(
                Int(k8.get(i))
            )
        ) + "|" + String(Int(k16.get(i)))
        assert_equal(Int(n.get(i)), want_n[key], "COUNT(*) of " + key)
        assert_equal(Int(sv.get(i)), want_sum.get(key, 0), "SUM of " + key)


def test_a_sum_that_overflows_inside_one_worker_is_refused_at_the_row() raises:
    var sink = _nines_sink()
    sink.resize_worker_state(2)
    var keys = List[Int]()
    keys.append(7)
    keys.append(7)
    with assert_raises(contains="left the 128-bit range"):
        sink.consume(0, Morsel(_nines_batch(keys), 0, 0))


# --- memory -----------------------------------------------------------------


def _id_sink(var pool: SegmentPool) raises -> GroupAggSink:
    var keys = Slab[Expr]()
    keys.append(Expr.col_ref("id"))
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, True))
    sb.add_field(Field("cs", ArrowType.INT64, False))
    sb.add_field(Field("cv", ArrowType.INT64, False))
    sb.add_field(Field("sv", ArrowType.INT64, True))
    sb.add_field(Field("mn", ArrowType.INT64, True))
    sb.add_field(Field("mx", ArrowType.INT64, True))
    sb.add_field(Field("av", ArrowType.FLOAT64, True))
    sb.add_field(Field.decimal128("sd", 38, 2, True))
    return GroupAggSink(
        grouped_agg_data(keys^, _aggs(), sb.build()),
        KEY_DTYPE_I64,
        pool^,
        0,
    )


def _per_group() -> Int:
    return GroupTable(1, 7).per_group_bytes()


def test_the_pool_is_charged_as_the_tables_grow_and_whole_after_take_output() raises:
    var pool = SegmentPool(1 << 30)
    var sink = _id_sink(pool.share())
    sink.resize_worker_state(1)
    sink.consume(0, Morsel(group_batch(0, 10), 0, 0))
    var small = pool.granted()
    assert_true(small >= 64 * _per_group(), "the first step is not charged")
    for m in range(1, 6):
        sink.consume(0, Morsel(group_batch(1000 * m - 990, 1000), m, 0))
    var big = pool.granted()
    # 5,010 groups: the table has doubled up to 8,192 groups of capacity.
    assert_true(big >= 8192 * _per_group(), "the doublings are not charged")
    assert_true(big > small)
    var out = _combine_and_take(sink, 1)
    assert_equal(out.num_rows(), 5010)
    assert_equal(pool.granted(), 0)


def test_growth_past_the_budget_is_refused_by_name_in_a_worker() raises:
    var pool = SegmentPool(300_000)
    var sink = _id_sink(pool.share())
    sink.resize_worker_state(1)
    with assert_raises(contains="denied"):
        for m in range(30):
            sink.consume(0, Morsel(group_batch(500 * m, 500), m, 0))
    assert_true(pool.granted() <= 300_000)
    sink.finalize()
    _ = sink^
    assert_equal(pool.granted(), 0)


def _two_workers(ref pool: SegmentPool, groups: Int) raises -> GroupAggSink:
    """A sink whose two workers hold the same `groups` keys, so the merged
    table has `groups` groups and each worker's table is as big as it."""
    var sink = _id_sink(pool.share())
    sink.resize_worker_state(2)
    sink.consume(0, Morsel(group_batch(0, groups), 0, 0))
    sink.consume(1, Morsel(group_batch(0, groups), 1, 0))
    return sink^


def test_growth_past_the_budget_is_refused_by_name_in_the_merge() raises:
    # Measure what the two workers hold, whatever the table layout is.
    var probe = SegmentPool(1 << 30)
    var measured = _two_workers(probe, 3000)
    var held = probe.granted()
    _ = measured^
    assert_equal(probe.granted(), 0)
    # Room for both workers and a quarter of that again: the merged table,
    # about half of it, does not fit.
    var tight = SegmentPool(held + held // 4)
    var sink = _two_workers(tight, 3000)
    with assert_raises(contains="group table"):
        _ = _combine_and_take(sink, 2)
    _ = sink^
    assert_equal(tight.granted(), 0)
    # With room for the workers and the merged table, the same tables merge.
    var roomy = SegmentPool(2 * held)
    var ok = _two_workers(roomy, 3000)
    assert_equal(_combine_and_take(ok, 2).num_rows(), 3000)
    assert_equal(roomy.granted(), 0)


def _capped_sink(max_groups: Int) raises -> GroupAggSink:
    var keys = Slab[Expr]()
    keys.append(Expr.col_ref("id"))
    var aggs = Slab[AggExpr]()
    aggs.append(AggExpr(AGG_COUNT, None, None))
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("n", ArrowType.INT64, False))
    return GroupAggSink(
        grouped_agg_data(keys^, aggs^, sb.build()),
        KEY_DTYPE_I64,
        SegmentPool(),
        0,
        max_groups,
    )


def test_more_groups_than_a_table_holds_are_refused_by_name() raises:
    # A table's group index is 32 bits wide; the limit is a parameter so the
    # refusal can be reached with a few groups. 128 groups fit, 129 do not.
    var worker = _capped_sink(128)
    worker.resize_worker_state(1)
    worker.consume(0, Morsel(group_batch(0, 128), 0, 0))
    with assert_raises(contains="more groups than a group table holds (128)"):
        worker.consume(0, Morsel(group_batch(128, 1), 1, 0))
    # Two workers of 100 distinct groups each fit alone; the merged 200 do not.
    var merge = _capped_sink(128)
    merge.resize_worker_state(2)
    merge.consume(0, Morsel(group_batch(0, 100), 0, 0))
    merge.consume(1, Morsel(group_batch(100, 100), 1, 0))
    with assert_raises(contains="more groups than a group table holds (128)"):
        _ = _combine_and_take(merge, 2)


def test_a_sink_dropped_without_a_combine_returns_its_memory() raises:
    var pool = SegmentPool(1 << 30)
    var sink = _id_sink(pool.share())
    sink.resize_worker_state(3)
    for w in range(3):
        sink.consume(w, Morsel(group_batch(100 * w, 100), w, 0))
    assert_true(pool.granted() > 0)
    _ = sink^
    assert_equal(pool.granted(), 0)


def main() raises:
    var suite = TestSuite()
    suite.test[test_one_key_with_null_keys_matches_the_oracle]()
    suite.test[test_two_keys_with_null_keys_match_the_oracle]()
    suite.test[test_any_worker_count_and_dealing_gives_the_same_groups]()
    suite.test[test_no_row_gives_no_group_and_the_declared_columns]()
    suite.test[test_a_group_summed_over_two_workers_overflows_only_in_the_merge]()
    suite.test[test_the_same_values_under_different_keys_do_not_overflow]()
    suite.test[test_null_is_a_group_of_its_own_and_not_zero]()
    suite.test[test_float64_keys_group_signed_zeros_and_nans_together]()
    suite.test[test_float32_keys_group_signed_zeros_and_nans_together]()
    suite.test[test_a_key_column_of_the_wrong_family_is_refused_by_name]()
    suite.test[test_what_the_sink_refuses_when_it_is_built]()
    suite.test[test_a_declared_key_type_that_is_not_the_inputs_is_refused]()
    suite.test[test_nans_of_every_bit_pattern_are_one_group_in_float64]()
    suite.test[test_nans_of_every_bit_pattern_are_one_group_in_float32]()
    suite.test[test_int8_and_int16_keys_group_by_value_with_negatives_and_nulls]()
    suite.test[test_a_sum_that_overflows_inside_one_worker_is_refused_at_the_row]()
    suite.test[test_more_groups_than_a_table_holds_are_refused_by_name]()
    suite.test[test_the_pool_is_charged_as_the_tables_grow_and_whole_after_take_output]()
    suite.test[test_growth_past_the_budget_is_refused_by_name_in_a_worker]()
    suite.test[test_growth_past_the_budget_is_refused_by_name_in_the_merge]()
    suite.test[test_a_sink_dropped_without_a_combine_returns_its_memory]()
    suite^.run()
