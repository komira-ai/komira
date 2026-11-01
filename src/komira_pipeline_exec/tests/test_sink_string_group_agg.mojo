# =============================================================================
# The string-keyed grouped aggregation sink, fed morsels directly
# =============================================================================
#
# The tests hand the sink morsels, a different worker for each, so every
# worker's table is non-empty when `combine` merges them. The expected answers
# come from a plain loop over the rows with a `Dict` from the key's text to a
# running tally, written here from the row number alone (`string_harness` says
# what each cell of row r holds), never from the engine. Each case runs in the
# DICT_ENCODED and the COLUMNAR orientation and with the key as a flat STRING
# column, as a dictionary and as a dictionary that is rotated differently in
# every morsel and holds unused entries and a second copy of a string. What
# they prove:
#
#   * One string key and two, with NULLs and the empty string among the values:
#     every group has the oracle's COUNT(*), COUNT, SUM, MIN, MAX, AVG (bit for
#     bit) and DECIMAL SUM, and the number of groups is the oracle's.
#   * The same answer for one to five workers and for the rows dealt in order
#     and in reverse.
#   * NULL and the empty string are two groups, in every form.
#   * Two codes of one dictionary that hold the same string are one group.
#   * Two workers that number the same strings differently (the same value with
#     another code in each dictionary and another id in each worker's table)
#     merge to one group per string, with the sums of both.
#   * A dictionary entry that no selected row uses (a mask removes every row of
#     one value, and the dictionary holds entries no row has) is no group.
#   * A DECIMAL(38,0) value of 10^38 - 1 under one key in each of two workers is
#     refused by the merge, and the same values under two different keys are
#     not.
#   * No row: no group, and the declared columns.
#   * What the sink refuses by name: a declared key type that is not STRING, no
#     group-by expression, a miscounted output schema, a key column that is not
#     a string, a numeric dictionary, a code outside its dictionary.

from std.collections import Dict
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_collections.slab import Slab
from komira_column_kernels.compiler_helpers import copy_batch, copy_column
from komira_morsel.morsel import Morsel
from komira_morsel.pipeline_execution import PipelineExecution
from komira_physical_plan.physical_plan import AggSinkData
from komira_pipeline_exec.group_harness import (
    d_null,
    d_unscaled,
    v_null,
    v_value,
)
from komira_pipeline_exec.plan_harness import grouped_agg_data
from komira_pipeline_exec.segment_pool import SegmentPool
from komira_pipeline_exec.sink_string_group_agg import StringGroupAggSink
from komira_pipeline_exec.string_harness import (
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


def _schema(nk: Int) raises -> Schema:
    var sb = SchemaBuilder()
    for k in range(nk):
        sb.add_field(Field("key" + String(k), ArrowType.STRING, True))
    sb.add_field(Field("cs", ArrowType.INT64, False))
    sb.add_field(Field("cv", ArrowType.INT64, False))
    sb.add_field(Field("sv", ArrowType.INT64, True))
    sb.add_field(Field("mn", ArrowType.INT64, True))
    sb.add_field(Field("mx", ArrowType.INT64, True))
    sb.add_field(Field("av", ArrowType.FLOAT64, True))
    sb.add_field(Field.decimal128("sd", 38, 2, True))
    return sb.build()


def _data(two: Bool) raises -> AggSinkData:
    var keys = Slab[Expr]()
    keys.append(Expr.col_ref("s1"))
    if two:
        keys.append(Expr.col_ref("s2"))
    return grouped_agg_data(keys^, _aggs(), _schema(2 if two else 1))


def _sink(two: Bool, dict_encoded: Bool) raises -> StringGroupAggSink:
    return StringGroupAggSink(_data(two), dict_encoded, SegmentPool(), 0)


def _combine_and_take(
    mut sink: StringGroupAggSink, workers: Int
) raises -> RecordBatch:
    var pipeline = PipelineExecution(workers, 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


def _run_rows(
    rows: Int,
    morsel: Int,
    workers: Int,
    reverse: Bool,
    two: Bool,
    form: Int,
    dict_encoded: Bool,
) raises -> RecordBatch:
    """Rows 0 .. rows - 1 in morsels of `morsel`, morsel m going to worker
    m % workers (or workers - 1 - m % workers when `reverse`)."""
    var sink = _sink(two, dict_encoded)
    sink.resize_worker_state(workers)
    var m = 0
    var start = 0
    while start < rows:
        var n = min(morsel, rows - start)
        var w = m % workers
        if reverse:
            w = workers - 1 - w
        sink.consume(w, Morsel(string_batch(start, n, form), m, 0))
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


def _part(null: Bool, value: String) -> String:
    """A key part as text: NULL and the empty string differ."""
    if null:
        return "NULL"
    return "S:" + value


def _key_text(r: Int, two: Bool) -> String:
    var s = _part(s1_null(r), s1_value(r))
    if two:
        s += "|" + _part(s2_null(r), s2_value(r))
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


def _out_key(ref out: RecordBatch, i: Int, nk: Int) raises -> String:
    var key = String("")
    for k in range(nk):
        if k > 0:
            key += "|"
        if out.column_at(k).is_null_at(i):
            key += "NULL"
        else:
            key += "S:" + out.column_at(k).as_string().get(i)
    return key^


def _check(ref out: RecordBatch, rows: Int, two: Bool) raises:
    var want = _Oracle(rows, two)
    var nk = 2 if two else 1
    assert_equal(out.num_rows(), len(want.tallies), "number of groups")
    assert_equal(out.num_columns(), nk + 7)
    for k in range(nk):
        assert_equal(out.schema.field_arrow_type(k), ArrowType.STRING)
    var seen = List[Bool](length=len(want.tallies), fill=False)
    for i in range(out.num_rows()):
        var key = _out_key(out, i, nk)
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
            assert_true(sd.get_i128(i) == I128(t.sum_d), "SUM(d) of " + key)
    for at in range(len(seen)):
        assert_true(seen[at], "a group of the oracle is missing")


def _forms() -> List[Int]:
    var out = List[Int]()
    out.append(FORM_FLAT)
    out.append(FORM_DICT)
    out.append(FORM_SHUFFLED)
    return out^


def test_one_string_key_matches_the_oracle_in_every_form_and_orientation() raises:
    var oracle = _Oracle(500, False)
    assert_true("NULL" in oracle.index, "the table has no NULL key")
    assert_true("S:" in oracle.index, "the table has no empty-string key")
    assert_equal(len(oracle.tallies), 7)
    for form in _forms():
        for dict_encoded in [False, True]:
            _check(
                _run_rows(500, 37, 4, False, False, form, dict_encoded),
                500,
                False,
            )


def test_two_string_keys_match_the_oracle_in_every_form_and_orientation() raises:
    var oracle = _Oracle(900, True)
    assert_true("NULL|NULL" in oracle.index and "S:|S:" in oracle.index)
    assert_true(len(oracle.tallies) > 30, "too few groups to mean much")
    for form in _forms():
        for dict_encoded in [False, True]:
            _check(
                _run_rows(900, 41, 4, False, True, form, dict_encoded),
                900,
                True,
            )


def test_any_worker_count_and_dealing_gives_the_same_groups() raises:
    for workers in range(1, 6):
        for dict_encoded in [False, True]:
            _check(
                _run_rows(600, 29, workers, False, True, FORM_SHUFFLED, dict_encoded),
                600,
                True,
            )
            _check(
                _run_rows(600, 29, workers, True, True, FORM_SHUFFLED, dict_encoded),
                600,
                True,
            )


def _counts(ref out: RecordBatch, nk: Int) raises -> Dict[String, Int]:
    var got = Dict[String, Int]()
    for i in range(out.num_rows()):
        var key = _out_key(out, i, nk)
        assert_true(key not in got, "group " + key + " twice")
        got[key] = Int(out.column_at(nk).as_primitive[DType.int64]().get(i))
    return got^


def test_null_and_the_empty_string_are_two_groups() raises:
    var values = List[String]()
    var valid = List[Bool]()
    # NULL, "", NULL, "", "", "a": groups NULL 2, "" 3, "a" 1.
    for v in ["", "", "", "", "", "a"]:
        values.append(String(v))
    for ok in [False, True, False, True, True, True]:
        valid.append(ok)
    for form in _forms():
        for dict_encoded in [False, True]:
            var sink = StringGroupAggSink(
                _data(False), dict_encoded, SegmentPool(), 0
            )
            sink.resize_worker_state(2)
            sink.consume(0, Morsel(_with_d(key_batch(values, valid, form)), 0, 0))
            var out = _combine_and_take(sink, 2)
            var got = _counts(out, 1)
            assert_equal(len(got), 3)
            assert_equal(got["NULL"], 2)
            assert_equal(got["S:"], 3)
            assert_equal(got["S:a"], 1)


def _with_d(var batch: RecordBatch) raises -> RecordBatch:
    """`batch` (a key `s1` and `v`) with a DECIMAL column `d` of nothing but
    zeros appended, for the sink's aggregate list."""
    var n = batch.num_rows()
    var d = Decimal128Array.allocate_nullable(n, 20, 2)
    for i in range(n):
        d.set_i128(i, I128(0))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    for c in range(batch.num_columns()):
        sb.add_field(batch.schema.field_at(c))
        rb.add_column(copy_column(batch, c))
    sb.add_field(Field.decimal128("d", 20, 2, True))
    rb.add_column(Column.from_decimal128(d^))
    return rb.build(sb.build())


def test_two_codes_of_one_dictionary_holding_one_string_are_one_group() raises:
    # Dictionary ["a", "b", "a"]: codes 0 and 2 are the same string.
    var entries = List[String]()
    for e in ["a", "b", "a"]:
        entries.append(String(e))
    var codes = PrimitiveArray[DType.int32].allocate(6)
    var want = [0, 2, 1, 2, 0, 2]
    for i in range(6):
        codes.set(i, Int32(want[i]))
    var v = PrimitiveArray[DType.int64].allocate(6)
    for i in range(6):
        v.set(i, Int64(i + 1))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field.dictionary("s1", ArrowType.INT32, False))
    rb.add_column(
        Column.from_dictionary(
            StringDictionaryArray.from_parts(codes^, StringArray.from_strings(entries))
        )
    )
    sb.add_field(Field("v", ArrowType.INT64, False))
    rb.add_column(Column.from_primitive[DType.int64](v^))
    var batch = _with_d(rb.build(sb.build()))
    for dict_encoded in [False, True]:
        var sink = _sink(False, dict_encoded)
        sink.resize_worker_state(1)
        sink.consume(0, Morsel(copy_batch(batch), 0, 0))
        var out = _combine_and_take(sink, 1)
        var got = _counts(out, 1)
        assert_equal(len(got), 2)
        assert_equal(got["S:a"], 5)
        assert_equal(got["S:b"], 1)


def test_workers_that_number_the_same_strings_differently_merge_by_value() raises:
    # Worker 0 meets a, b, c in that order; worker 1 meets c, b, a. Whatever
    # ids their tables give, a merge by id would pair a with c.
    var w0 = List[String]()
    var w1 = List[String]()
    var w2 = List[String]()
    for v in ["a", "b", "c", "a", "a"]:
        w0.append(String(v))
    for v in ["c", "b", "a", "c", "c", "c"]:
        w1.append(String(v))
    for v in ["b", "d"]:
        w2.append(String(v))
    var all_valid5 = List[Bool](length=5, fill=True)
    var all_valid6 = List[Bool](length=6, fill=True)
    var all_valid2 = List[Bool](length=2, fill=True)
    for form in [FORM_DICT, FORM_SHUFFLED]:
        for dict_encoded in [False, True]:
            var sink = _sink(False, dict_encoded)
            sink.resize_worker_state(4)  # worker 3 holds nothing
            sink.consume(0, Morsel(_with_d(key_batch(w0, all_valid5, form, 0)), 0, 0))
            sink.consume(1, Morsel(_with_d(key_batch(w1, all_valid6, form, 1)), 1, 0))
            sink.consume(2, Morsel(_with_d(key_batch(w2, all_valid2, form, 2)), 2, 0))
            var out = _combine_and_take(sink, 4)
            var got = _counts(out, 1)
            assert_equal(len(got), 4)
            assert_equal(got["S:a"], 4)
            assert_equal(got["S:b"], 3)
            assert_equal(got["S:c"], 5)
            assert_equal(got["S:d"], 1)
            # SUM(v) is the merged one: a is row 1, 4, 5 of w0 (1 + 4 + 5) and
            # row 3 of w1 (3).
            for i in range(out.num_rows()):
                if _out_key(out, i, 1) == "S:a":
                    var sv = out.column_at(3).as_primitive[DType.int64]()
                    assert_equal(Int(sv.get(i)), 1 + 4 + 5 + 3)


def _masked(var batch: RecordBatch, ref keep: List[Bool]) raises -> RecordBatch:
    var mask = BooleanArray.allocate(len(keep))
    for i in range(len(keep)):
        mask.set(i, keep[i])
    batch.set_selection_mask(mask^)
    return batch^


def test_an_entry_no_selected_row_uses_is_not_a_group() raises:
    # Every row of "b" is masked out; the dictionary also holds two entries
    # no row has (FORM_SHUFFLED) and "b" itself.
    var values = List[String]()
    var keep = List[Bool]()
    for v in ["a", "b", "c", "b", "a", "c", "b", "a"]:
        values.append(String(v))
        keep.append(String(v) != "b")
    var valid = List[Bool](length=8, fill=True)
    for form in [FORM_DICT, FORM_SHUFFLED]:
        for dict_encoded in [False, True]:
            var sink = _sink(False, dict_encoded)
            sink.resize_worker_state(2)
            sink.consume(
                0,
                Morsel(_masked(_with_d(key_batch(values, valid, form, 1)), keep), 0, 0),
            )
            sink.consume(
                1,
                Morsel(_masked(_with_d(key_batch(values, valid, form, 2)), keep), 1, 0),
            )
            var out = _combine_and_take(sink, 2)
            var got = _counts(out, 1)
            assert_equal(len(got), 2)
            assert_equal(got["S:a"], 6)
            assert_equal(got["S:c"], 4)
            assert_true("S:b" not in got)
            for key in got.keys():
                assert_true(
                    not key.startswith("S:unused"), "an unused entry is a group"
                )


def _nines_batch(keys: List[String], form: Int) raises -> RecordBatch:
    var nines = I128(1)
    for _ in range(38):
        nines = nines * I128(10)
    nines = nines - I128(1)
    var d = Decimal128Array.allocate_nullable(len(keys), 38, 0)
    for i in range(len(keys)):
        d.set_i128(i, nines)
    var valid = List[Bool](length=len(keys), fill=True)
    var kb = key_batch(keys, valid, form)
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(kb.schema.field_at(0))
    rb.add_column(copy_column(kb, 0))
    sb.add_field(Field.decimal128("d", 38, 0, True))
    rb.add_column(Column.from_decimal128(d^))
    return rb.build(sb.build())


def _nines_sink(dict_encoded: Bool) raises -> StringGroupAggSink:
    var keys = Slab[Expr]()
    keys.append(Expr.col_ref("s1"))
    var aggs = Slab[AggExpr]()
    aggs.append(_agg(AGG_SUM, "d"))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.STRING, False))
    sb.add_field(Field.decimal128("s", 38, 0, True))
    return StringGroupAggSink(
        grouped_agg_data(keys^, aggs^, sb.build()),
        dict_encoded,
        SegmentPool(),
        0,
    )


def _one(k: String) -> List[String]:
    var out = List[String]()
    out.append(k)
    return out^


def test_a_group_summed_over_two_workers_overflows_only_in_the_merge() raises:
    for form in _forms():
        for dict_encoded in [False, True]:
            var sink = _nines_sink(dict_encoded)
            sink.resize_worker_state(2)
            # Each worker folds one value under "x": no fold sees an overflow.
            sink.consume(0, Morsel(_nines_batch(_one("x"), form), 0, 0))
            sink.consume(1, Morsel(_nines_batch(_one("x"), form), 1, 0))
            with assert_raises(contains="left the 128-bit range"):
                _ = _combine_and_take(sink, 2)


def test_the_same_values_under_different_strings_do_not_overflow() raises:
    for form in _forms():
        for dict_encoded in [False, True]:
            var sink = _nines_sink(dict_encoded)
            sink.resize_worker_state(2)
            sink.consume(0, Morsel(_nines_batch(_one("x"), form), 0, 0))
            sink.consume(1, Morsel(_nines_batch(_one("y"), form), 1, 0))
            var out = _combine_and_take(sink, 2)
            assert_equal(out.num_rows(), 2)
            var sums = out.column_at(1).as_decimal128()
            assert_true(sums.get_i128(0) == sums.get_i128(1))


def test_no_row_gives_no_group_and_the_declared_columns() raises:
    for dict_encoded in [False, True]:
        var sink = _sink(True, dict_encoded)
        sink.resize_worker_state(3)
        var out = _combine_and_take(sink, 3)
        assert_equal(out.num_rows(), 0)
        assert_equal(out.num_columns(), 9)
        assert_equal(out.schema.field_arrow_type(1), ArrowType.STRING)
        # A morsel whose mask keeps nothing is no row either.
        var sink2 = _sink(False, dict_encoded)
        sink2.resize_worker_state(1)
        var values = List[String]()
        values.append("a")
        values.append("b")
        var valid = List[Bool](length=2, fill=True)
        var keep = List[Bool](length=2, fill=False)
        sink2.consume(
            0,
            Morsel(_masked(_with_d(key_batch(values, valid, FORM_DICT)), keep), 0, 0),
        )
        assert_equal(_combine_and_take(sink2, 1).num_rows(), 0)


def _sink_declared(key_type: ArrowType, with_keys: Bool) raises -> StringGroupAggSink:
    var keys = Slab[Expr]()
    if with_keys:
        keys.append(Expr.col_ref("s1"))
    var aggs = Slab[AggExpr]()
    aggs.append(AggExpr(AGG_COUNT, None, None))
    var sb = SchemaBuilder()
    if with_keys:
        sb.add_field(Field("k", key_type, True))
    sb.add_field(Field("n", ArrowType.INT64, False))
    return StringGroupAggSink(
        grouped_agg_data(keys^, aggs^, sb.build()), True, SegmentPool(), 0
    )


def test_what_the_sink_refuses_when_it_is_built() raises:
    with assert_raises(contains="declares output column 0 (a key) as"):
        _ = _sink_declared(ArrowType.INT64, True)
    with assert_raises(contains="a key of another type beside a string key"):
        _ = _sink_declared(ArrowType.DICTIONARY, True)
    with assert_raises(contains="has no group-by expression"):
        _ = _sink_declared(ArrowType.STRING, False)
    with assert_raises(contains="declares 1 output columns for 1 keys and 2"):
        var keys = Slab[Expr]()
        keys.append(Expr.col_ref("s1"))
        var aggs = Slab[AggExpr]()
        aggs.append(AggExpr(AGG_COUNT, None, None))
        aggs.append(AggExpr(AGG_COUNT, None, None))
        var sb = SchemaBuilder()
        sb.add_field(Field("k", ArrowType.STRING, True))
        _ = StringGroupAggSink(
            grouped_agg_data(keys^, aggs^, sb.build()), False, SegmentPool(), 0
        )


def test_a_key_column_that_is_no_string_is_refused_by_name() raises:
    var ints = StringGroupAggSink(
        _int_key_data(), True, SegmentPool(), 0
    )
    ints.resize_worker_state(1)
    var v = PrimitiveArray[DType.int64].allocate(3)
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("s1", ArrowType.INT64, False))
    rb.add_column(Column.from_primitive[DType.int64](v^))
    with assert_raises(contains="the string rows key STRING and string DICTIONARY"):
        ints.consume(0, Morsel(rb.build(sb.build()), 0, 0))


def _int_key_data() raises -> AggSinkData:
    var keys = Slab[Expr]()
    keys.append(Expr.col_ref("s1"))
    var aggs = Slab[AggExpr]()
    aggs.append(AggExpr(AGG_COUNT, None, None))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.STRING, True))
    sb.add_field(Field("n", ArrowType.INT64, False))
    return grouped_agg_data(keys^, aggs^, sb.build())


def test_a_numeric_dictionary_and_a_code_outside_the_dictionary_are_refused() raises:
    # A numeric dictionary: INT64 values in a dictionary column.
    var codes = PrimitiveArray[DType.int32].allocate(2)
    codes.set(0, 0)
    codes.set(1, 1)
    var nums = List[Int64]()
    nums.append(10)
    nums.append(20)
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field.dictionary("s1", ArrowType.INT32, False))
    rb.add_column(Column.from_numeric_dict[DType.int32, DType.int64](codes^, nums^))
    var sink = StringGroupAggSink(_int_key_data(), True, SegmentPool(), 0)
    sink.resize_worker_state(1)
    with assert_raises(contains="is a numeric dictionary column"):
        sink.consume(0, Morsel(rb.build(sb.build()), 0, 0))
    # A code 7 in a dictionary of two.
    for dict_encoded in [False, True]:
        var sink2 = StringGroupAggSink(
            _int_key_data(), dict_encoded, SegmentPool(), 0
        )
        sink2.resize_worker_state(1)
        with assert_raises(contains="found dictionary code 7 at row 1 of a dictionary of 2"):
            sink2.consume(0, Morsel(_bad_code_batch(), 0, 0))


def _bad_code_batch() raises -> RecordBatch:
    var entries = List[String]()
    entries.append("a")
    entries.append("b")
    var bad = PrimitiveArray[DType.int32].allocate(3)
    bad.set(0, 0)
    bad.set(1, 7)
    bad.set(2, 1)
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field.dictionary("s1", ArrowType.INT32, False))
    rb.add_column(
        Column.from_dictionary(
            StringDictionaryArray.from_parts(bad^, StringArray.from_strings(entries))
        )
    )
    return rb.build(sb.build())


def main() raises:
    var suite = TestSuite()
    suite.test[test_one_string_key_matches_the_oracle_in_every_form_and_orientation]()
    suite.test[test_two_string_keys_match_the_oracle_in_every_form_and_orientation]()
    suite.test[test_any_worker_count_and_dealing_gives_the_same_groups]()
    suite.test[test_null_and_the_empty_string_are_two_groups]()
    suite.test[test_two_codes_of_one_dictionary_holding_one_string_are_one_group]()
    suite.test[test_workers_that_number_the_same_strings_differently_merge_by_value]()
    suite.test[test_an_entry_no_selected_row_uses_is_not_a_group]()
    suite.test[test_a_group_summed_over_two_workers_overflows_only_in_the_merge]()
    suite.test[test_the_same_values_under_different_strings_do_not_overflow]()
    suite.test[test_no_row_gives_no_group_and_the_declared_columns]()
    suite.test[test_what_the_sink_refuses_when_it_is_built]()
    suite.test[test_a_key_column_that_is_no_string_is_refused_by_name]()
    suite.test[test_a_numeric_dictionary_and_a_code_outside_the_dictionary_are_refused]()
    suite^.run()
