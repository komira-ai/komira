# =============================================================================
# The grouped aggregation sink over a composite key of mixed types
# =============================================================================
#
# `StringGroupAggSink` built `composite=True` is the (SINK_AGG,
# KEY_DTYPE_COMPOSITE, COLUMNAR) row: a key of several columns, each of its own
# type. The tests hand it morsels, morsel m to worker m % workers, and compute
# the expected COUNT(*) and SUM(v) of every group here, by a loop over the row
# numbers with a `Dict` from the key's text to a tally, never from the engine.
# The key of row r is a function of r alone:
#
#   i  INT32, NULL where r % 11 == 3, else r % 5 - 2 (negative, zero, positive)
#   s  STRING, NULL where r % 7 == 2, else S[(r // 3) % 4], S = ["x", "", "yy",
#      "été"] (the empty string is a value, distinct from NULL); flat, or a
#      dictionary, or a shuffled dictionary with two codes for one string
#      (`string_harness`)
#   d  DATE32, NULL where r % 13 == 6, else 17 - 400 * ((r // 2) % 3) (days
#      before the epoch too)
#   m  DECIMAL(30, 4), NULL where r % 9 == 4, else one of 2^64, -1 and
#      2^64 - 1 (unscaled), so the two 64-bit halves both tell keys apart
#   b  BOOL, NULL where r % 8 == 5, else r % 2 == 0
#   f  FLOAT64, NULL where r % 10 == 7, else 0.0, -0.0, NaN (a payload per
#      row) or 1.5 by r % 4 (0.0 and -0.0 are one group, every NaN is one
#      group)
#   v  INT64, r * 3 - 50, never NULL
#
# What each test proves:
#   * test_int_string_date_keys_match_the_oracle_in_every_string_form: GROUP BY
#     (i, s, d) over 300 rows in morsels of 17 on 1, 3 and 4 workers, the
#     string flat, dictionary and shuffled dictionary: every group has the
#     oracle's COUNT(*) and SUM(v), no group is missing or doubled, and the
#     output key columns are INT32, STRING and DATE32.
#     Catches a NULL in one column merged with a value of another, a string
#     cell hashed by its worker-local id (groups split between workers), and a
#     key column read at another column's cell.
#   * test_the_key_columns_keep_their_order: GROUP BY (d, s, i) gives the same
#     groups with the key columns in that order and of those types.
#   * test_a_null_in_each_column_is_a_group_of_its_own: (0, "", 17),
#     (NULL, "", 17), (0, NULL, 17), (0, "", NULL) and (NULL, NULL, NULL) twice
#     are five groups, the last of two rows, and the empty string is not NULL.
#   * test_decimal_bool_float_and_string_keys_match_the_oracle: GROUP BY
#     (m, b, f, s): the decimal's two cells, the bool and the float's canonical
#     cell beside a string; the decimal keeps precision 30 and scale 4 and the
#     exact unscaled values past INT64.
#   * test_workers_that_number_strings_differently_merge_by_value: three
#     workers meet "a", "b", "c" in different orders beside one integer key;
#     the merged groups are by string value, with the summed SUM(v).
#   * test_a_selection_mask_keeps_only_the_selected_rows: masked-out rows are
#     in no group, and a key value only they hold is no group.
#   * test_no_row_gives_no_group_and_the_declared_columns: a sink fed nothing
#     outputs no row and the declared columns, the decimal's precision and
#     scale included.
#   * test_a_plan_on_the_real_builder_runs_the_composite_row: a resident batch
#     through RealBuilder and run_plan with the (SINK_AGG, COMPOSITE, COLUMNAR)
#     sink gives the oracle's groups on 1 and 3 workers, and the pool is whole
#     again.
#   * test_a_fixed_width_key_of_another_type_than_declared_is_refused: an
#     INT32 column for a declared INT64 key, an INT64 column for a declared
#     DATE32 key, and a DECIMAL(30, 2) column for a declared DECIMAL(30, 4) key
#     are refused by name when rows arrive.
#   * test_a_declared_key_type_no_row_keys_is_refused_when_built: a BINARY key
#     beside a string key is refused naming the type; the same schema without
#     `composite` is refused naming the COMPOSITE row.

from std.collections import Dict
from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from arrow.arrow_types import ArrowType
from arrow.boolean_array import BooleanArray
from arrow.column import Column
from arrow.decimal_array import Decimal128Array
from arrow.primitive_array import PrimitiveArray
from arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from async_api.token import CancellationToken
from byte_buffer.heap_region import HeapRegion
from containers.slab import Slab
from morsel.morsel import Morsel
from morsel.pipeline_execution import PipelineExecution
from parquet.runtime_footer_cache import ParquetMetadataCache
from physical_plan.physical_plan import (
    AggSinkData,
    KEY_DTYPE_COMPOSITE,
    SegmentDescPod,
)
from pipeline_exec.fake_dispatch import InlineDispatch
from pipeline_exec.plan_harness import (
    batch_segment,
    grouped_agg_data,
    with_group_sink,
)
from pipeline_exec.real_builder import RealBuilder
from pipeline_exec.run_plan import run_plan
from pipeline_exec.segment_pool import SegmentPool
from pipeline_exec.sink_string_group_agg import StringGroupAggSink
from pipeline_exec.string_harness import (
    FORM_DICT,
    FORM_FLAT,
    FORM_SHUFFLED,
    string_column,
)
from plan_expr.agg_expr import AGG_COUNT, AGG_SUM, AggExpr
from plan_expr.expr import Expr
from plan_expr.expr_pool import ExprPool
from scalar_arithmetic.decimal_arith import I128


# ---- the row functions ------------------------------------------------------


def _i_null(r: Int) -> Bool:
    return r % 11 == 3


def _i(r: Int) -> Int:
    return r % 5 - 2


def _s_null(r: Int) -> Bool:
    return r % 7 == 2


def _s(r: Int) -> String:
    var c = (r // 3) % 4
    if c == 0:
        return "x"
    if c == 1:
        return ""
    if c == 2:
        return "yy"
    return "été"


def _d_null(r: Int) -> Bool:
    return r % 13 == 6


def _d(r: Int) -> Int:
    return 17 - 400 * ((r // 2) % 3)


def _m_null(r: Int) -> Bool:
    return r % 9 == 4


def _two_to_64() -> I128:
    return I128(4294967296) * I128(4294967296)


def _m_value(c: Int) -> I128:
    if c == 0:
        return _two_to_64()
    if c == 1:
        return I128(-1)
    return _two_to_64() - I128(1)


def _m_class(v: I128) -> Int:
    for c in range(3):
        if v == _m_value(c):
            return c
    return -1


def _b_null(r: Int) -> Bool:
    return r % 8 == 5


def _b(r: Int) -> Bool:
    return r % 2 == 0


def _f_null(r: Int) -> Bool:
    return r % 10 == 7


def _f(r: Int) -> Float64:
    var c = r % 4
    if c == 0:
        return 0.0
    if c == 1:
        return -0.0
    if c == 2:
        # A NaN whose payload differs from row to row.
        return bitcast[DType.float64](UInt64(0x7FF4000000000000) | UInt64(r))
    return 1.5


def _f_text(v: Float64) -> String:
    if v != v:
        return "nan"
    if v == 0.0:
        return "0"
    return String(v)


def _v(r: Int) -> Int:
    return r * 3 - 50


# ---- the key columns as they reach the sink ---------------------------------

comptime COL_I = 0
comptime COL_S = 1
comptime COL_D = 2
comptime COL_M = 3
comptime COL_B = 4
comptime COL_F = 5


def _name(col: Int) -> String:
    if col == COL_I:
        return "i"
    if col == COL_S:
        return "s"
    if col == COL_D:
        return "d"
    if col == COL_M:
        return "m"
    if col == COL_B:
        return "b"
    return "f"


def _field(col: Int) raises -> Field:
    if col == COL_I:
        return Field("i", ArrowType.INT32, True)
    if col == COL_S:
        return Field("s", ArrowType.STRING, True)
    if col == COL_D:
        return Field("d", ArrowType.DATE32, True)
    if col == COL_M:
        return Field.decimal128("m", 30, 4, True)
    if col == COL_B:
        return Field("b", ArrowType.BOOL, True)
    return Field("f", ArrowType.FLOAT64, True)


def _column(col: Int, start: Int, n: Int, form: Int) raises -> Column[HeapRegion]:
    if col == COL_S:
        var values = List[String]()
        var valid = List[Bool]()
        for x in range(n):
            values.append(_s(start + x))
            valid.append(not _s_null(start + x))
        return string_column(values, valid, form, start)
    if col == COL_I or col == COL_D:
        var a = PrimitiveArray[DType.int32].allocate_nullable(n)
        for x in range(n):
            var r = start + x
            if col == COL_I:
                a.set(x, Int32(_i(r)))
                if _i_null(r):
                    a._set_null(x)
            else:
                a.set(x, Int32(_d(r)))
                if _d_null(r):
                    a._set_null(x)
        if col == COL_D:
            return Column.from_primitive_with_arrow_type[DType.int32](
                a^, ArrowType.DATE32
            )
        return Column.from_primitive[DType.int32](a^)
    if col == COL_M:
        var a = Decimal128Array.allocate_nullable(n, 30, 4)
        for x in range(n):
            var r = start + x
            if _m_null(r):
                a.set_null(x)
            else:
                a.set_i128(x, _m_value(r % 3))
        return Column.from_decimal128(a^)
    if col == COL_B:
        var a = BooleanArray.allocate_nullable(n)
        for x in range(n):
            var r = start + x
            if _b_null(r):
                a._set_null(x)
            else:
                a.set(x, _b(r))
        return Column.from_boolean(a^)
    var a = PrimitiveArray[DType.float64].allocate_nullable(n)
    for x in range(n):
        var r = start + x
        if _f_null(r):
            a._set_null(x)
        else:
            a.set(x, _f(r))
    return Column.from_primitive[DType.float64](a^)


def _batch(
    ref cols: List[Int], start: Int, n: Int, form: Int
) raises -> RecordBatch:
    """Rows start .. start + n - 1: the key columns `cols`, then v."""
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    for c in range(len(cols)):
        sb.add_field(_field(cols[c]))
        rb.add_column(_column(cols[c], start, n, form))
    var v = PrimitiveArray[DType.int64].allocate(n)
    for x in range(n):
        v.set(x, Int64(_v(start + x)))
    sb.add_field(Field("v", ArrowType.INT64, False))
    rb.add_column(Column.from_primitive[DType.int64](v^))
    return rb.build(sb.build())


def _data(ref cols: List[Int]) raises -> AggSinkData:
    """GROUP BY `cols` with COUNT(*) and SUM(v); each key column is declared
    in its input type."""
    var keys = Slab[Expr]()
    var sb = SchemaBuilder()
    for c in range(len(cols)):
        keys.append(Expr.col_ref(_name(cols[c])))
        sb.add_field(_field(cols[c]))
    var aggs = Slab[AggExpr]()
    aggs.append(AggExpr(AGG_COUNT, None, None))
    aggs.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("v")), None))
    sb.add_field(Field("n", ArrowType.INT64, False))
    sb.add_field(Field("sv", ArrowType.INT64, True))
    return grouped_agg_data(keys^, aggs^, sb.build())


def _sink(ref cols: List[Int]) raises -> StringGroupAggSink:
    return StringGroupAggSink(
        _data(cols), False, SegmentPool(), 0, composite=True
    )


def _combine_and_take(
    mut sink: StringGroupAggSink, workers: Int
) raises -> RecordBatch:
    var pipeline = PipelineExecution(workers, 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


def _run(
    ref cols: List[Int], rows: Int, morsel: Int, workers: Int, form: Int
) raises -> RecordBatch:
    var sink = _sink(cols)
    sink.resize_worker_state(workers)
    var m = 0
    var start = 0
    while start < rows:
        var n = min(morsel, rows - start)
        sink.consume(m % workers, Morsel(_batch(cols, start, n, form), m, 0))
        m += 1
        start += n
    return _combine_and_take(sink, workers)


# ---- the oracle -------------------------------------------------------------


def _row_part(col: Int, r: Int) -> String:
    if col == COL_I:
        return "N" if _i_null(r) else String(_i(r))
    if col == COL_S:
        return "N" if _s_null(r) else "S:" + _s(r)
    if col == COL_D:
        return "N" if _d_null(r) else String(_d(r))
    if col == COL_M:
        return "N" if _m_null(r) else String(r % 3)
    if col == COL_B:
        return "N" if _b_null(r) else ("T" if _b(r) else "F")
    return "N" if _f_null(r) else _f_text(_f(r))


def _row_key(ref cols: List[Int], r: Int) -> String:
    var key = String("")
    for c in range(len(cols)):
        key += _row_part(cols[c], r) + "|"
    return key^


def _out_part(col: Int, ref out: RecordBatch, k: Int, i: Int) raises -> String:
    ref c = out.column_at(k)
    if c.is_null_at(i):
        return "N"
    if col == COL_I or col == COL_D:
        return String(Int(c.as_primitive[DType.int32]().get(i)))
    if col == COL_S:
        return "S:" + c.as_string().get(i)
    if col == COL_M:
        var cls = _m_class(c.as_decimal128().get_i128(i))
        assert_true(cls >= 0, "a decimal key that no input row holds")
        return String(cls)
    if col == COL_B:
        return "T" if c.as_boolean().get(i) else "F"
    return _f_text(c.as_primitive[DType.float64]().get(i))


@fieldwise_init
struct _Tally(Copyable, Movable):
    var n: Int
    var sum_v: Int


def _check(
    ref out: RecordBatch, ref cols: List[Int], ref rows: List[Int]
) raises:
    """`out` holds one group per distinct key of the rows `rows`, each with
    their COUNT(*) and SUM(v), its key columns in `cols` order and type."""
    var nk = len(cols)
    var index = Dict[String, Int]()
    var tallies = List[_Tally]()
    for x in range(len(rows)):
        var r = rows[x]
        var key = _row_key(cols, r)
        if key not in index:
            index[key] = len(tallies)
            tallies.append(_Tally(0, 0))
        var at = index[key]
        tallies[at].n += 1
        tallies[at].sum_v += _v(r)
    assert_equal(out.num_columns(), nk + 2)
    for k in range(nk):
        var want = _field(cols[k])
        assert_equal(out.schema.field_arrow_type(k), want.arrow_type)
        assert_equal(out.column_at(k).arrow_type, want.arrow_type)
    assert_equal(out.num_rows(), len(tallies), "number of groups")
    var seen = List[Bool](length=len(tallies), fill=False)
    var n = out.column_at(nk).as_primitive[DType.int64]()
    var sv = out.column_at(nk + 1).as_primitive[DType.int64]()
    for i in range(out.num_rows()):
        var key = String("")
        for k in range(nk):
            key += _out_part(cols[k], out, k, i) + "|"
        assert_true(key in index, "a group the oracle does not have: " + key)
        var at = index[key]
        assert_true(not seen[at], "group " + key + " twice")
        seen[at] = True
        assert_equal(Int(n.get(i)), tallies[at].n, "COUNT(*) of " + key)
        assert_equal(Int(sv.get(i)), tallies[at].sum_v, "SUM(v) of " + key)
    for at in range(len(seen)):
        assert_true(seen[at], "a group of the oracle is missing")


def _first(rows: Int) -> List[Int]:
    var out = List[Int]()
    for r in range(rows):
        out.append(r)
    return out^


def _cols(a: Int, b: Int, c: Int = -1, d: Int = -1) -> List[Int]:
    var out = List[Int]()
    out.append(a)
    out.append(b)
    if c >= 0:
        out.append(c)
    if d >= 0:
        out.append(d)
    return out^


def _forms() -> List[Int]:
    var out = List[Int]()
    out.append(FORM_FLAT)
    out.append(FORM_DICT)
    out.append(FORM_SHUFFLED)
    return out^


# ---- the tests --------------------------------------------------------------


def test_int_string_date_keys_match_the_oracle_in_every_string_form() raises:
    var cols = _cols(COL_I, COL_S, COL_D)
    var forms = _forms()
    for f in range(len(forms)):
        for workers in [1, 3, 4]:
            var out = _run(cols, 300, 17, workers, forms[f])
            _check(out, cols, _first(300))


def test_the_key_columns_keep_their_order() raises:
    var cols = _cols(COL_D, COL_S, COL_I)
    var out = _run(cols, 300, 23, 3, FORM_DICT)
    _check(out, cols, _first(300))


def _nulls(
    mut i: List[Bool], mut s: List[Bool], mut d: List[Bool], a: Bool, b: Bool, c: Bool
):
    i.append(a)
    s.append(b)
    d.append(c)


def test_a_null_in_each_column_is_a_group_of_its_own() raises:
    # Six rows: (0, "", 17), (NULL, "", 17), (0, NULL, 17), (0, "", NULL),
    # then (NULL, NULL, NULL) twice; v is the row number plus one.
    var i_null = List[Bool]()
    var s_null = List[Bool]()
    var d_null = List[Bool]()
    _nulls(i_null, s_null, d_null, False, False, False)
    _nulls(i_null, s_null, d_null, True, False, False)
    _nulls(i_null, s_null, d_null, False, True, False)
    _nulls(i_null, s_null, d_null, False, False, True)
    _nulls(i_null, s_null, d_null, True, True, True)
    _nulls(i_null, s_null, d_null, True, True, True)
    var n = len(i_null)
    var values = List[String](length=n, fill=String(""))
    var valid = List[Bool]()
    for x in range(n):
        valid.append(not s_null[x])
    var cols = _cols(COL_I, COL_S, COL_D)
    for form in [FORM_FLAT, FORM_DICT]:
        var ia = PrimitiveArray[DType.int32].allocate_nullable(n)
        var da = PrimitiveArray[DType.int32].allocate_nullable(n)
        var v = PrimitiveArray[DType.int64].allocate(n)
        for x in range(n):
            ia.set(x, 0)
            da.set(x, 17)
            if i_null[x]:
                ia._set_null(x)
            if d_null[x]:
                da._set_null(x)
            v.set(x, Int64(x + 1))
        var sb = SchemaBuilder()
        var rb = RecordBatchBuilder()
        sb.add_field(_field(COL_I))
        rb.add_column(Column.from_primitive[DType.int32](ia^))
        sb.add_field(_field(COL_S))
        rb.add_column(string_column(values, valid, form, 0))
        sb.add_field(_field(COL_D))
        rb.add_column(
            Column.from_primitive_with_arrow_type[DType.int32](
                da^, ArrowType.DATE32
            )
        )
        sb.add_field(Field("v", ArrowType.INT64, False))
        rb.add_column(Column.from_primitive[DType.int64](v^))
        var sink = _sink(cols)
        sink.resize_worker_state(1)
        sink.consume(0, Morsel(rb.build(sb.build()), 0, 0))
        var out = _combine_and_take(sink, 1)
        assert_equal(out.num_rows(), 5)
        var by_key = Dict[String, Int]()
        var cnt = out.column_at(3).as_primitive[DType.int64]()
        var sv = out.column_at(4).as_primitive[DType.int64]()
        for i in range(out.num_rows()):
            var key = String("")
            for k in range(3):
                key += _out_part(cols[k], out, k, i) + "|"
            by_key[key] = i
        assert_equal(Int(sv.get(by_key["0|S:|17|"])), 1)
        assert_equal(Int(sv.get(by_key["N|S:|17|"])), 2)
        assert_equal(Int(sv.get(by_key["0|N|17|"])), 3)
        assert_equal(Int(sv.get(by_key["0|S:|N|"])), 4)
        assert_equal(Int(cnt.get(by_key["N|N|N|"])), 2)
        assert_equal(Int(sv.get(by_key["N|N|N|"])), 5 + 6)


def test_decimal_bool_float_and_string_keys_match_the_oracle() raises:
    var cols = _cols(COL_M, COL_B, COL_F, COL_S)
    var out = _run(cols, 400, 29, 3, FORM_SHUFFLED)
    _check(out, cols, _first(400))
    assert_equal(out.column_at(0).decimal_precision(), 30)
    assert_equal(out.column_at(0).decimal_scale(), 4)


def test_workers_that_number_strings_differently_merge_by_value() raises:
    # Worker 0 meets a, b, c; worker 1 c, b, a; worker 2 b, a. Every row's i
    # is 7, so the groups are the strings.
    var orders = List[List[String]]()
    var o0 = List[String]()
    for x in ["a", "b", "c"]:
        o0.append(String(x))
    var o1 = List[String]()
    for x in ["c", "b", "a", "c"]:
        o1.append(String(x))
    var o2 = List[String]()
    for x in ["b", "a"]:
        o2.append(String(x))
    orders.append(o0^)
    orders.append(o1^)
    orders.append(o2^)
    var cols = _cols(COL_I, COL_S)
    var sink = _sink(cols)
    sink.resize_worker_state(3)
    var row = 0
    for w in range(3):
        ref vals = orders[w]
        var n = len(vals)
        var valid = List[Bool](length=n, fill=True)
        var ia = PrimitiveArray[DType.int32].allocate(n)
        var v = PrimitiveArray[DType.int64].allocate(n)
        for x in range(n):
            ia.set(x, 7)
            v.set(x, Int64(row))
            row += 1
        var sb = SchemaBuilder()
        var rb = RecordBatchBuilder()
        sb.add_field(_field(COL_I))
        rb.add_column(Column.from_primitive[DType.int32](ia^))
        sb.add_field(_field(COL_S))
        rb.add_column(string_column(vals, valid, FORM_DICT, 0))
        sb.add_field(Field("v", ArrowType.INT64, False))
        rb.add_column(Column.from_primitive[DType.int64](v^))
        sink.consume(w, Morsel(rb.build(sb.build()), w, 0))
    var out = _combine_and_take(sink, 3)
    assert_equal(out.num_rows(), 3)
    var cnt = out.column_at(2).as_primitive[DType.int64]()
    var sv = out.column_at(3).as_primitive[DType.int64]()
    for i in range(out.num_rows()):
        assert_equal(Int(out.column_at(0).as_primitive[DType.int32]().get(i)), 7)
        var s = out.column_at(1).as_string().get(i)
        # Rows are numbered 0 .. 8 across the workers in order:
        # a at 0, 5, 8; b at 1, 4, 7; c at 2, 3, 6.
        if s == "a":
            assert_equal(Int(cnt.get(i)), 3)
            assert_equal(Int(sv.get(i)), 0 + 5 + 8)
        elif s == "b":
            assert_equal(Int(cnt.get(i)), 3)
            assert_equal(Int(sv.get(i)), 1 + 4 + 7)
        else:
            assert_equal(s, "c")
            assert_equal(Int(cnt.get(i)), 3)
            assert_equal(Int(sv.get(i)), 2 + 3 + 6)


def test_a_selection_mask_keeps_only_the_selected_rows() raises:
    # Rows 0 .. 99; only rows whose r % 3 != 0 are selected. A key value held
    # only by masked rows would be a group the oracle does not have.
    var cols = _cols(COL_S, COL_I, COL_D)
    var rows = 100
    var keep = List[Int]()
    var sink = _sink(cols)
    sink.resize_worker_state(2)
    var m = 0
    var start = 0
    while start < rows:
        var n = min(31, rows - start)
        var batch = _batch(cols, start, n, FORM_FLAT)
        var mask = BooleanArray.allocate(n)
        for x in range(n):
            var r = start + x
            mask.set(x, r % 3 != 0)
            if r % 3 != 0:
                keep.append(r)
        batch.set_selection_mask(mask^)
        sink.consume(m % 2, Morsel(batch^, m, 0))
        m += 1
        start += n
    var out = _combine_and_take(sink, 2)
    _check(out, cols, keep)


def test_no_row_gives_no_group_and_the_declared_columns() raises:
    var cols = _cols(COL_M, COL_S, COL_D)
    var sink = _sink(cols)
    sink.resize_worker_state(2)
    var out = _combine_and_take(sink, 2)
    assert_equal(out.num_rows(), 0)
    assert_equal(out.num_columns(), 5)
    assert_equal(out.schema.field_arrow_type(0), ArrowType.DECIMAL128)
    assert_equal(out.schema.field_decimal_precision(0), 30)
    assert_equal(out.schema.field_decimal_scale(0), 4)
    assert_equal(out.schema.field_arrow_type(1), ArrowType.STRING)
    assert_equal(out.schema.field_arrow_type(2), ArrowType.DATE32)


def test_a_plan_on_the_real_builder_runs_the_composite_row() raises:
    var cols = _cols(COL_I, COL_S, COL_D)
    for workers in [1, 3]:
        var cache = ParquetMetadataCache()
        var pool = ExprPool()
        var nf = 0
        var builder = RealBuilder[
            origin_of(cache), origin_of(pool), origin_of(nf)
        ](cache, pool)
        var handle = builder.add_resident(_batch(cols, 0, 250, FORM_FLAT))
        var id = builder.add_agg_sink(_data(cols))
        var plan = List[SegmentDescPod]()
        plan.append(
            with_group_sink(
                batch_segment(0, handle, morsel_rows=40),
                id,
                KEY_DTYPE_COMPOSITE,
            )
        )
        var dispatch = InlineDispatch()
        var out = run_plan(
            plan^, builder, dispatch, workers, CancellationToken.new()
        )
        assert_equal(builder.pool_granted(), 0)
        var batch = out.take(0)
        _check(batch, cols, _first(250))


def _one_key_data(declared: Field) raises -> AggSinkData:
    """GROUP BY (s, k) with COUNT(*): s a STRING, k declared as `declared`."""
    var keys = Slab[Expr]()
    keys.append(Expr.col_ref("s"))
    keys.append(Expr.col_ref("k"))
    var aggs = Slab[AggExpr]()
    aggs.append(AggExpr(AGG_COUNT, None, None))
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, True))
    sb.add_field(declared)
    sb.add_field(Field("n", ArrowType.INT64, False))
    return grouped_agg_data(keys^, aggs^, sb.build())


def _s_and(var k: Column[HeapRegion], k_field: Field) raises -> RecordBatch:
    var n = k.length()
    var values = List[String](length=n, fill=String("x"))
    var valid = List[Bool](length=n, fill=True)
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("s", ArrowType.STRING, True))
    rb.add_column(string_column(values, valid, FORM_FLAT, 0))
    sb.add_field(k_field)
    rb.add_column(k^)
    return rb.build(sb.build())


def _refused_on_rows(declared: Field, var k: Column[HeapRegion], k_field: Field, text: String) raises:
    var sink = StringGroupAggSink(
        _one_key_data(declared), False, SegmentPool(), 0, composite=True
    )
    sink.resize_worker_state(1)
    with assert_raises(contains=text):
        sink.consume(0, Morsel(_s_and(k^, k_field), 0, 0))


def test_a_fixed_width_key_of_another_type_than_declared_is_refused() raises:
    var i32 = PrimitiveArray[DType.int32].allocate(3)
    _refused_on_rows(
        Field("k", ArrowType.INT64, True),
        Column.from_primitive[DType.int32](i32^),
        Field("k", ArrowType.INT32, True),
        "group key 1 is a "
        + String(ArrowType.INT32)
        + " column, and the sink declares the key "
        + String(ArrowType.INT64),
    )
    var i64 = PrimitiveArray[DType.int64].allocate(3)
    _refused_on_rows(
        Field("k", ArrowType.DATE32, True),
        Column.from_primitive[DType.int64](i64^),
        Field("k", ArrowType.INT64, True),
        "the DATE32 row keys DATE32",
    )
    var dec = Decimal128Array.allocate_nullable(3, 30, 2)
    _refused_on_rows(
        Field.decimal128("k", 30, 4, True),
        Column.from_decimal128(dec^),
        Field.decimal128("k", 30, 2, True),
        "and the sink declares the key DECIMAL(30, 4)",
    )


def test_a_declared_key_type_no_row_keys_is_refused_when_built() raises:
    with assert_raises(
        contains="the composite-keyed aggregation sink of segment 0 declares"
        " output column 1 (a key) as "
        + String(ArrowType.BINARY)
        + ", which no key row keys"
    ):
        _ = StringGroupAggSink(
            _one_key_data(Field("k", ArrowType.BINARY, True)),
            False,
            SegmentPool(),
            0,
            composite=True,
        )
    with assert_raises(contains="is the COMPOSITE row's"):
        _ = StringGroupAggSink(
            _one_key_data(Field("k", ArrowType.INT64, True)),
            False,
            SegmentPool(),
            0,
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
