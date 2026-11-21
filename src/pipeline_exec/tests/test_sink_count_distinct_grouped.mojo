# =============================================================================
# COUNT(DISTINCT x) and SELECT DISTINCT in the grouped aggregation sinks
# =============================================================================
#
# The tests hand `GroupAggSink` (fixed-width keys) and `StringGroupAggSink`
# (string keys) morsels directly, a different worker for each, so every worker
# holds entries of its own when `combine` merges them. The expected answers
# come from loops over the rows written here from the row number or from the
# lists the test built, never from the engine. What they prove:
#
#   * test_an_int64_key_counts_distinct_values_per_group: per group, the
#     distinct non-NULL values; a NULL key group; a group whose values are all
#     NULL counts 0 and still has its row; the same value in two groups counts
#     in each; the same (group, value) on two workers counts once; SUM and
#     COUNT(*) beside it are over every row, not every distinct row.
#   * test_distinct_integer_decimal_and_repeated_values_match_the_oracle_on_any_worker_count:
#     a 600-row table of 11 keys and NULL, the distinct
#     INT32 values (repeated), INT64 values and DECIMAL values per key, on one
#     to five workers and dealt in order and in reverse.
#   * test_a_string_key_counts_distinct_values_per_group_in_every_form: the same
#     over string keys, with a string argument, in the flat, dictionary and
#     rotated-dictionary forms of the columns, in both orientations; NULL and
#     the empty string are two groups.
#   * test_select_distinct_over_an_int64_key_is_one_row_per_key: no aggregate:
#     one row per distinct key, one NULL row, the same on any dealing.
#   * test_select_distinct_over_two_fixed_width_keys_is_one_row_per_pair: INT64
#     and INT32 keys with NULLs.
#   * test_select_distinct_over_a_string_key_is_one_row_per_string: NULL and
#     the empty string are two rows, in every form and orientation.
#   * test_select_distinct_over_two_string_keys_is_one_row_per_pair.
#   * test_select_distinct_over_no_row_is_no_row_with_the_declared_columns: for
#     both sinks.

from std.collections import Dict
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_true,
)

from arrow.arrow_types import ArrowType
from arrow.column_builder import ColumnBuilder
from arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from containers.slab import Slab
from morsel.morsel import Morsel
from morsel.pipeline_execution import PipelineExecution
from physical_plan.physical_plan import (
    AggSinkData,
    KEY_DTYPE_I64,
)
from pipeline_exec.group_harness import (
    d_null,
    group_batch,
    k1_null,
    k1_value,
    k2_null,
    k2_value,
    v_null,
    v_value,
)
from pipeline_exec.plan_harness import grouped_agg_data
from pipeline_exec.segment_pool import SegmentPool
from pipeline_exec.sink_group_agg import GroupAggSink
from pipeline_exec.sink_string_group_agg import StringGroupAggSink
from pipeline_exec.string_harness import (
    FORM_DICT,
    FORM_FLAT,
    FORM_SHUFFLED,
    key_batch,
    s1_null,
    s1_value,
    s2_null,
    s2_value,
    string_batch,
)
from plan_expr.agg_expr import (
    AGG_COUNT,
    AGG_COUNT_DISTINCT,
    AGG_SUM,
    AggExpr,
)
from plan_expr.expr import Expr

comptime NUL: Int = -999999
"""In a list of test values: this row is NULL."""


def _cd(col: String) -> AggExpr:
    return AggExpr(AGG_COUNT_DISTINCT, Optional(Expr.col_ref(col)), None)


def _agg(func: UInt8, col: String) -> AggExpr:
    return AggExpr(func, Optional(Expr.col_ref(col)), None)


def _count_star() -> AggExpr:
    return AggExpr(AGG_COUNT, None, None)


def _key_exprs(name: String) -> Slab[Expr]:
    var keys = Slab[Expr]()
    keys.append(Expr.col_ref(name))
    return keys^


def _combine_and_take(mut sink: GroupAggSink, workers: Int) raises -> RecordBatch:
    var pipeline = PipelineExecution(workers, 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


def _combine_and_take_s(
    mut sink: StringGroupAggSink, workers: Int
) raises -> RecordBatch:
    var pipeline = PipelineExecution(workers, 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


def _i64_at(ref out: RecordBatch, col: Int, row: Int) raises -> Int:
    assert_equal(out.schema.field_arrow_type(col), ArrowType.INT64)
    return Int(out.column_at(col).as_primitive[DType.int64]().get(row))


def _count_at(ref out: RecordBatch, col: Int, row: Int) raises -> Int:
    """A count column's value, which is never NULL."""
    assert_false(out.column_at(col).is_null_at(row))
    return _i64_at(out, col, row)


# --- an INT64 key with three nullable INT64 columns --------------------------


def _kvw_batch(
    keys: List[Int], vals: List[Int], ws: List[Int], lo: Int, hi: Int
) raises -> RecordBatch:
    """Rows `lo` to `hi - 1` of the key `k`, and the values `v` and `w`."""
    var k = ColumnBuilder[DType.int64].with_capacity(hi - lo)
    var v = ColumnBuilder[DType.int64].with_capacity(hi - lo)
    var w = ColumnBuilder[DType.int64].with_capacity(hi - lo)
    for r in range(lo, hi):
        if keys[r] == NUL:
            k.append_null()
        else:
            k.append(Int64(keys[r]))
        if vals[r] == NUL:
            v.append_null()
        else:
            v.append(Int64(vals[r]))
        if ws[r] == NUL:
            w.append_null()
        else:
            w.append(Int64(ws[r]))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    rb.add_column(k^.materialize())
    sb.add_field(Field("v", ArrowType.INT64, True))
    rb.add_column(v^.materialize())
    sb.add_field(Field("w", ArrowType.INT64, True))
    rb.add_column(w^.materialize())
    return rb.build(sb.build())


def _kv_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    sb.add_field(Field("cdv", ArrowType.INT64, False))
    sb.add_field(Field("sumv", ArrowType.INT64, True))
    sb.add_field(Field("cs", ArrowType.INT64, False))
    sb.add_field(Field("cdw", ArrowType.INT64, False))
    return sb.build()


def _kv_data() raises -> AggSinkData:
    var aggs = Slab[AggExpr]()
    aggs.append(_cd("v"))
    aggs.append(_agg(AGG_SUM, "v"))
    aggs.append(_count_star())
    aggs.append(_cd("w"))
    return grouped_agg_data(_key_exprs("k"), aggs^, _kv_schema())


def _distinct_of(vals: List[Int], rows: List[Int]) -> Int:
    """The distinct values of `vals` at `rows` that are not NUL."""
    var seen = List[Int]()
    for i in range(len(rows)):
        var v = vals[rows[i]]
        if v == NUL:
            continue
        var found = False
        for j in range(len(seen)):
            if seen[j] == v:
                found = True
        if not found:
            seen.append(v)
    return len(seen)


def _rows_of(keys: List[Int], key: Int) -> List[Int]:
    var out = List[Int]()
    for r in range(len(keys)):
        if keys[r] == key:
            out.append(r)
    return out^


def _keys_of(keys: List[Int]) -> List[Int]:
    """The distinct keys of `keys`, NUL (the NULL key) among them."""
    var out = List[Int]()
    for r in range(len(keys)):
        var found = False
        for j in range(len(out)):
            if out[j] == keys[r]:
                found = True
        if not found:
            out.append(keys[r])
    return out^


def _key_at(ref out: RecordBatch, row: Int) raises -> Int:
    if out.column_at(0).is_null_at(row):
        return NUL
    return _i64_at(out, 0, row)


struct _Dealt(Movable):
    """The rows a test has handed the sink, for the oracle."""

    var keys: List[Int]
    var vals: List[Int]
    var ws: List[Int]

    def __init__(out self):
        self.keys = List[Int]()
        self.vals = List[Int]()
        self.ws = List[Int]()


def _deal(
    sink: GroupAggSink,
    w: Int,
    idx: Int,
    keys: List[Int],
    vals: List[Int],
    ws: List[Int],
    lo: Int,
    hi: Int,
    mut dealt: _Dealt,
) raises:
    sink.consume(w, Morsel(_kvw_batch(keys, vals, ws, lo, hi), idx, 0))
    for r in range(lo, hi):
        dealt.keys.append(keys[r])
        dealt.vals.append(vals[r])
        dealt.ws.append(ws[r])


def test_an_int64_key_counts_distinct_values_per_group() raises:
    #            0   1   2    3   4    5    6    7    8    9   10  11
    var keys = List[Int](1, 2, NUL, 1, 2, NUL, 3, 1, 3, 2, NUL, 1)
    var vals = List[Int](10, 10, 10, 10, NUL, 20, NUL, 30, NUL, 10, 20, 10)
    var ws = List[Int](5, 5, 6, 5, 7, 7, NUL, 6, NUL, 5, 6, 5)
    var sink = GroupAggSink(_kv_data(), KEY_DTYPE_I64, SegmentPool(), 0)
    sink.resize_worker_state(3)
    var dealt = _Dealt()
    _deal(sink, 0, 0, keys, vals, ws, 0, 4, dealt)
    _deal(sink, 1, 1, keys, vals, ws, 4, 8, dealt)
    _deal(sink, 2, 2, keys, vals, ws, 8, 12, dealt)
    # Rows 0 to 5 again on worker 2: their (group, value) entries are held by
    # two or three workers.
    _deal(sink, 2, 3, keys, vals, ws, 0, 6, dealt)
    var out = _combine_and_take(sink, 3)
    var groups = _keys_of(dealt.keys)
    assert_equal(len(groups), 4)
    assert_equal(out.num_rows(), len(groups))
    var seen = List[Int]()
    for i in range(out.num_rows()):
        var key = _key_at(out, i)
        for j in range(len(seen)):
            assert_true(seen[j] != key, "a group twice")
        seen.append(key)
        var rows = _rows_of(dealt.keys, key)
        assert_equal(_count_at(out, 1, i), _distinct_of(dealt.vals, rows))
        assert_equal(_count_at(out, 4, i), _distinct_of(dealt.ws, rows))
        assert_equal(_count_at(out, 3, i), len(rows))
        var non_null = 0
        var total = 0
        for j in range(len(rows)):
            if dealt.vals[rows[j]] != NUL:
                non_null += 1
                total += dealt.vals[rows[j]]
        assert_equal(out.column_at(2).is_null_at(i), non_null == 0)
        if non_null > 0:
            assert_equal(_i64_at(out, 2, i), total)
        # The cases of the data, by key: 1 holds 10 and 30, 2 holds 10 only,
        # the NULL key holds 10 and 20, 3 holds only NULL.
        if key == 1:
            assert_equal(_count_at(out, 1, i), 2)
        elif key == 2:
            assert_equal(_count_at(out, 1, i), 1)
        elif key == NUL:
            assert_equal(_count_at(out, 1, i), 2)
        else:
            assert_equal(key, 3)
            assert_equal(_count_at(out, 1, i), 0)
            assert_equal(_count_at(out, 4, i), 0)
    assert_equal(len(seen), 4)


# --- the harness table: 11 keys and NULL, repeated and distinct values -------


def _g2_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("k1", ArrowType.INT64, True))
    sb.add_field(Field("cdk2", ArrowType.INT64, False))
    sb.add_field(Field("cdv", ArrowType.INT64, False))
    sb.add_field(Field("sumv", ArrowType.INT64, True))
    sb.add_field(Field("cdd", ArrowType.INT64, False))
    sb.add_field(Field("cdid", ArrowType.INT64, False))
    return sb.build()


def _g2_data() raises -> AggSinkData:
    var aggs = Slab[AggExpr]()
    aggs.append(_cd("k2"))
    aggs.append(_cd("v"))
    aggs.append(_agg(AGG_SUM, "v"))
    aggs.append(_cd("d"))
    aggs.append(_cd("id"))
    return grouped_agg_data(_key_exprs("k1"), aggs^, _g2_schema())


def _run_g2(
    rows: Int, morsel: Int, workers: Int, reverse: Bool
) raises -> RecordBatch:
    var sink = GroupAggSink(_g2_data(), KEY_DTYPE_I64, SegmentPool(), 0)
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


def _check_g2(ref out: RecordBatch, rows: Int) raises:
    # Slot 11 is the NULL key. k2 takes three values (or NULL); v, d and id
    # are different in every row, so their distinct counts are row counts.
    var seen_k2 = List[Bool](length=12 * 3, fill=False)
    var n_v = List[Int](length=12, fill=0)
    var sum_v = List[Int](length=12, fill=0)
    var n_d = List[Int](length=12, fill=0)
    var n_id = List[Int](length=12, fill=0)
    for r in range(rows):
        var g = 11 if k1_null(r) else k1_value(r)
        if not k2_null(r):
            seen_k2[g * 3 + k2_value(r)] = True
        if not v_null(r):
            n_v[g] += 1
            sum_v[g] += v_value(r)
        if not d_null(r):
            n_d[g] += 1
        n_id[g] += 1
    var groups = 0
    for g in range(12):
        if n_id[g] > 0:
            groups += 1
    assert_equal(out.num_rows(), groups)
    var seen = List[Bool](length=12, fill=False)
    for i in range(out.num_rows()):
        var g = 11 if out.column_at(0).is_null_at(i) else _i64_at(out, 0, i)
        assert_false(seen[g], "a group twice")
        seen[g] = True
        var want_k2 = 0
        for k in range(3):
            if seen_k2[g * 3 + k]:
                want_k2 += 1
        assert_equal(_count_at(out, 1, i), want_k2, "k2 of group " + String(g))
        assert_equal(_count_at(out, 2, i), n_v[g], "v of group " + String(g))
        assert_equal(_count_at(out, 4, i), n_d[g], "d of group " + String(g))
        assert_equal(_count_at(out, 5, i), n_id[g], "id of group " + String(g))
        assert_equal(out.column_at(3).is_null_at(i), n_v[g] == 0)
        if n_v[g] > 0:
            assert_equal(_i64_at(out, 3, i), sum_v[g])


def test_distinct_integer_decimal_and_repeated_values_match_the_oracle_on_any_worker_count() raises:
    for workers in range(1, 6):
        _check_g2(_run_g2(600, 37, workers, False), 600)
        _check_g2(_run_g2(600, 37, workers, True), 600)


# --- a string key ------------------------------------------------------------


def _g3_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("key", ArrowType.STRING, True))
    sb.add_field(Field("cds2", ArrowType.INT64, False))
    sb.add_field(Field("cdv", ArrowType.INT64, False))
    sb.add_field(Field("sumv", ArrowType.INT64, True))
    sb.add_field(Field("cdd", ArrowType.INT64, False))
    sb.add_field(Field("cs", ArrowType.INT64, False))
    return sb.build()


def _g3_data() raises -> AggSinkData:
    var aggs = Slab[AggExpr]()
    aggs.append(_cd("s2"))
    aggs.append(_cd("v"))
    aggs.append(_agg(AGG_SUM, "v"))
    aggs.append(_cd("d"))
    aggs.append(_count_star())
    return grouped_agg_data(_key_exprs("s1"), aggs^, _g3_schema())


def _part(null: Bool, value: String) -> String:
    """A key part as text: NULL and the empty string differ."""
    if null:
        return "NULL"
    return "S:" + value


def _out_text(ref out: RecordBatch, col: Int, row: Int) raises -> String:
    if out.column_at(col).is_null_at(row):
        return "NULL"
    return "S:" + out.column_at(col).as_string().get(row)


def _run_strings(
    rows: Int, morsel: Int, workers: Int, form: Int, dict_encoded: Bool
) raises -> RecordBatch:
    var sink = StringGroupAggSink(_g3_data(), dict_encoded, SegmentPool(), 0)
    sink.resize_worker_state(workers)
    var m = 0
    var start = 0
    while start < rows:
        var n = min(morsel, rows - start)
        sink.consume(
            m % workers, Morsel(string_batch(start, n, form), m, 0)
        )
        m += 1
        start += n
    return _combine_and_take_s(sink, workers)


def _check_g3(ref out: RecordBatch, rows: Int) raises:
    var index = Dict[String, Int]()
    var s2_seen = List[List[String]]()
    var n_v = List[Int]()
    var sum_v = List[Int]()
    var n_d = List[Int]()
    var n_rows = List[Int]()
    for r in range(rows):
        var key = _part(s1_null(r), s1_value(r))
        if key not in index:
            index[key] = len(n_rows)
            s2_seen.append(List[String]())
            n_v.append(0)
            sum_v.append(0)
            n_d.append(0)
            n_rows.append(0)
        var g = index[key]
        n_rows[g] += 1
        if not s2_null(r):
            var found = False
            for j in range(len(s2_seen[g])):
                if s2_seen[g][j] == s2_value(r):
                    found = True
            if not found:
                s2_seen[g].append(s2_value(r))
        if not v_null(r):
            n_v[g] += 1
            sum_v[g] += v_value(r)
        if not d_null(r):
            n_d[g] += 1
    assert_true("NULL" in index and "S:" in index)
    assert_equal(out.num_rows(), len(n_rows))
    var seen = List[Bool](length=len(n_rows), fill=False)
    for i in range(out.num_rows()):
        var key = _out_text(out, 0, i)
        assert_true(key in index, "unexpected group " + key)
        var g = index[key]
        assert_false(seen[g], "group " + key + " twice")
        seen[g] = True
        assert_equal(_count_at(out, 1, i), len(s2_seen[g]), "s2 of " + key)
        assert_equal(_count_at(out, 2, i), n_v[g], "v of " + key)
        assert_equal(_count_at(out, 4, i), n_d[g], "d of " + key)
        assert_equal(_count_at(out, 5, i), n_rows[g], "COUNT(*) of " + key)
        assert_equal(out.column_at(3).is_null_at(i), n_v[g] == 0)
        if n_v[g] > 0:
            assert_equal(_i64_at(out, 3, i), sum_v[g], "SUM of " + key)


def test_a_string_key_counts_distinct_values_per_group_in_every_form() raises:
    var forms = List[Int](FORM_FLAT, FORM_DICT, FORM_SHUFFLED)
    for f in range(len(forms)):
        for orient in range(2):
            _check_g3(
                _run_strings(500, 37, 4, forms[f], orient == 1), 500
            )
    # One worker holds everything, and five split it.
    _check_g3(_run_strings(500, 500, 1, FORM_SHUFFLED, True), 500)
    _check_g3(_run_strings(500, 23, 5, FORM_SHUFFLED, False), 500)


# --- SELECT DISTINCT: keys and no aggregate ----------------------------------


def _key_only_data(
    names: List[String], types: List[ArrowType]
) raises -> AggSinkData:
    var keys = Slab[Expr]()
    var sb = SchemaBuilder()
    for i in range(len(names)):
        keys.append(Expr.col_ref(names[i]))
        sb.add_field(Field("key" + String(i), types[i], True))
    return grouped_agg_data(keys^, Slab[AggExpr](), sb.build())


def test_select_distinct_over_an_int64_key_is_one_row_per_key() raises:
    var keys = List[Int](NUL, 1, 2, 1, NUL, 3, 2, NUL, 7, 3)
    var vals = List[Int](0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    var names = List[String]("k")
    var types = List[ArrowType](ArrowType.INT64)
    for reverse in range(2):
        var sink = GroupAggSink(
            _key_only_data(names, types), KEY_DTYPE_I64, SegmentPool(), 0
        )
        sink.resize_worker_state(3)
        # Rows in morsels of three, a key met by several workers.
        for m in range(4):
            var lo = 3 * m
            var hi = min(lo + 3, len(keys))
            var w = m % 3 if reverse == 0 else 2 - m % 3
            sink.consume(
                w, Morsel(_kvw_batch(keys, vals, vals, lo, hi), m, 0)
            )
        var out = _combine_and_take(sink, 3)
        assert_equal(out.num_columns(), 1)
        # NULL, 1, 2, 3 and 7.
        assert_equal(out.num_rows(), 5)
        var seen = List[Int]()
        var nulls = 0
        for i in range(out.num_rows()):
            var key = _key_at(out, i)
            if key == NUL:
                nulls += 1
            for j in range(len(seen)):
                assert_true(seen[j] != key, "a key twice")
            seen.append(key)
        assert_equal(nulls, 1)
        assert_equal(len(seen), len(_keys_of(keys)))
        for j in range(len(seen)):
            assert_true(len(_rows_of(keys, seen[j])) > 0)


def test_select_distinct_over_two_fixed_width_keys_is_one_row_per_pair() raises:
    var names = List[String]("k1", "k2")
    var types = List[ArrowType](ArrowType.INT64, ArrowType.INT32)
    var sink = GroupAggSink(
        _key_only_data(names, types), KEY_DTYPE_I64, SegmentPool(), 0
    )
    sink.resize_worker_state(4)
    var rows = 300
    var start = 0
    var m = 0
    while start < rows:
        var n = min(29, rows - start)
        sink.consume(m % 4, Morsel(group_batch(start, n), m, 0))
        m += 1
        start += n
    var out = _combine_and_take(sink, 4)
    var want = Dict[String, Bool]()
    for r in range(rows):
        var a = String("N") if k1_null(r) else String(k1_value(r))
        var b = String("N") if k2_null(r) else String(k2_value(r))
        want[a + "|" + b] = True
    assert_true("N|N" in want, "the table has no NULL pair")
    assert_equal(out.num_rows(), len(want))
    var got = Dict[String, Bool]()
    for i in range(out.num_rows()):
        var a = String("N")
        if not out.column_at(0).is_null_at(i):
            a = String(_i64_at(out, 0, i))
        var b = String("N")
        if not out.column_at(1).is_null_at(i):
            b = String(Int(out.column_at(1).as_primitive[DType.int32]().get(i)))
        var key = a + "|" + b
        assert_true(key in want, "unexpected row " + key)
        assert_true(key not in got, "row " + key + " twice")
        got[key] = True


def test_select_distinct_over_a_string_key_is_one_row_per_string() raises:
    var values = List[String]("a", "", "a", "", "", "b", "", "a", "")
    var valid = List[Bool](True, False, True, True, False, True, True, True, False)
    # a, NULL, a, "", NULL, b, "", a, NULL: the rows a, NULL, "" and b.
    var forms = List[Int](FORM_FLAT, FORM_DICT, FORM_SHUFFLED)
    for f in range(len(forms)):
        for orient in range(2):
            var names = List[String]("s1")
            var types = List[ArrowType](ArrowType.STRING)
            var sink = StringGroupAggSink(
                _key_only_data(names, types), orient == 1, SegmentPool(), 0
            )
            sink.resize_worker_state(2)
            sink.consume(
                0, Morsel(key_batch(values, valid, forms[f], 0), 0, 0)
            )
            sink.consume(
                1, Morsel(key_batch(values, valid, forms[f], 1), 1, 0)
            )
            var out = _combine_and_take_s(sink, 2)
            assert_equal(out.num_columns(), 1)
            assert_equal(out.num_rows(), 4)
            var got = Dict[String, Bool]()
            for i in range(out.num_rows()):
                var key = _out_text(out, 0, i)
                assert_true(key not in got, "row " + key + " twice")
                got[key] = True
            assert_true("NULL" in got)
            assert_true("S:" in got)
            assert_true("S:a" in got)
            assert_true("S:b" in got)


def test_select_distinct_over_two_string_keys_is_one_row_per_pair() raises:
    var names = List[String]("s1", "s2")
    var types = List[ArrowType](ArrowType.STRING, ArrowType.STRING)
    var rows = 300
    var want = Dict[String, Bool]()
    for r in range(rows):
        want[
            _part(s1_null(r), s1_value(r))
            + "|"
            + _part(s2_null(r), s2_value(r))
        ] = True
    assert_true("NULL|NULL" in want and "S:|S:" in want)
    var forms = List[Int](FORM_FLAT, FORM_SHUFFLED)
    for f in range(len(forms)):
        for orient in range(2):
            var sink = StringGroupAggSink(
                _key_only_data(names, types), orient == 1, SegmentPool(), 0
            )
            sink.resize_worker_state(3)
            var start = 0
            var m = 0
            while start < rows:
                var n = min(31, rows - start)
                sink.consume(
                    m % 3, Morsel(string_batch(start, n, forms[f]), m, 0)
                )
                m += 1
                start += n
            var out = _combine_and_take_s(sink, 3)
            assert_equal(out.num_rows(), len(want))
            var got = Dict[String, Bool]()
            for i in range(out.num_rows()):
                var key = _out_text(out, 0, i) + "|" + _out_text(out, 1, i)
                assert_true(key in want, "unexpected row " + key)
                assert_true(key not in got, "row " + key + " twice")
                got[key] = True


def test_select_distinct_over_no_row_is_no_row_with_the_declared_columns() raises:
    var names = List[String]("k")
    var types = List[ArrowType](ArrowType.INT64)
    var fixed = GroupAggSink(
        _key_only_data(names, types), KEY_DTYPE_I64, SegmentPool(), 0
    )
    fixed.resize_worker_state(2)
    var out = _combine_and_take(fixed, 2)
    assert_equal(out.num_rows(), 0)
    assert_equal(out.num_columns(), 1)
    assert_equal(out.schema.field_arrow_type(0), ArrowType.INT64)
    var snames = List[String]("s1")
    var stypes = List[ArrowType](ArrowType.STRING)
    var strs = StringGroupAggSink(
        _key_only_data(snames, stypes), False, SegmentPool(), 0
    )
    strs.resize_worker_state(2)
    var sout = _combine_and_take_s(strs, 2)
    assert_equal(sout.num_rows(), 0)
    assert_equal(sout.num_columns(), 1)
    assert_equal(sout.schema.field_arrow_type(0), ArrowType.STRING)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
