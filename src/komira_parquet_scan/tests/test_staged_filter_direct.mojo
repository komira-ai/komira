# staged_filter: the planning functions, the masks, and the staged decode on
# a file against the one-shot predicate (definite TRUE of the whole
# conjunction over every row):
#   - conjuncts split left to right; the lead / deferred plan;
#   - definite TRUE drops an UNKNOWN row whose data bit is set;
#   - survivor composition, and its refusal of a mismatched inner mask;
#   - a selective lead: the survivors, their filter columns, the emitted
#     projection (filter columns from the stage, payload decoded for the
#     survivors) in projection order;
#   - a non-selective lead: declined, then handed off to the same mask;
#   - a NULL in a deferred column's conjunct never survives.

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.bitmap import Bitmap
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.record_batch import RecordBatch
from komira_async.ops.waker_sink import NoopSink
from komira_batch_eval.evaluate import evaluate_predicate
from komira_buffer.heap_region import HeapRegion
from komira_fs.local_fs import LocalFs
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet.payload_sel_trace import PAYLOAD_SEL_OFF, PAYLOAD_SEL_VAR_WIDTH
from komira_parquet.staged_filter_trace import (
    reset_staged_filter_counts,
    staged_filter_gather_count,
    staged_filter_sel_count,
)
from komira_parquet_api.metadata import FileMetaData
from komira_parquet_scan.parquet_reader import ParquetReader
from komira_parquet_scan.staged_filter import (
    SelectionPlan,
    compose_survivors,
    definite_true,
    first_deferred_conjunct,
    hconcat_share,
    resolve_conjunct_columns,
    run_staged_filter,
    selection_plan_for,
    split_and_conjuncts,
    staged_emit_batch,
    staged_filter_worthwhile,
    staged_handoff,
)
from komira_plan_expr.expr import BIN_AND, BIN_GE, BIN_GT, BIN_LT, BIN_NE, Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_runtime_paths import test_tmpdir
from komira_test_parquet_file import TestColumn, TestFileLayout, write_parquet_file

comptime _FS = LocalFs[NoopSink]
comptime _ROWS = 40


def _s(r: Int) -> String:
    return "s" + String(r % 4)


def _t(r: Int) -> String:
    return "t" + String(r % 3)


def _n_null(r: Int) -> Bool:
    return r % 5 == 0


def _n(r: Int) -> Int:
    return r % 7 - 2


def _file() raises -> String:
    """Columns a (INT64 = row), s (string, PLAIN), t (string, dictionary),
    n (nullable INT64): one row group of 40 rows."""
    var path = test_tmpdir() + "/staged.parquet"
    var a = List[Int]()
    var s = List[String]()
    var t = List[String]()
    var n = List[Int]()
    var nn = List[Bool]()
    for r in range(_ROWS):
        a.append(r)
        s.append(_s(r))
        t.append(_t(r))
        n.append(_n(r))
        nn.append(_n_null(r))
    var cols = List[TestColumn]()
    cols.append(TestColumn.int64("a", a^))
    cols.append(TestColumn.string("s", s^))
    cols.append(TestColumn.string("t", t^).dict_encoded())
    cols.append(TestColumn.int64("n", n^).with_nulls(nn^))
    write_parquet_file(path, cols, TestFileLayout.single())
    return path^


def _reader() raises -> ParquetReader[_FS]:
    var file = ParquetFileReader[_FS].open(_file())
    var meta = parse_full_metadata(file.metadata_bytes.view_range_ro(0, file.metadata_length))
    return ParquetReader[_FS](_file=file^, _meta=ArcPointer[FileMetaData](meta^))


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _cmp(op: UInt8, col: String, v: Int) -> Expr:
    return Expr.binary(op, Expr.col_ref(col), _lit(v))


def _scmp(op: UInt8, col: String, v: String) -> Expr:
    return Expr.binary(op, Expr.col_ref(col), Expr.literal(ScalarValue.from_string(v)))


def _and3(var x: Expr, var y: Expr, var z: Expr) -> Expr:
    return Expr.binary(BIN_AND, Expr.binary(BIN_AND, x^, y^), z^)


def _one_shot(reader: ParquetReader[_FS], pred: Expr, cols: List[Int]) raises -> BooleanArray:
    """The reference: the whole predicate over every row of `cols`."""
    return definite_true(evaluate_predicate(pred, reader.decode_columns_subset(0, cols, False)))


def _same_mask(a: BooleanArray, b: BooleanArray) raises:
    assert_equal(a.length, b.length)
    for i in range(a.length):
        assert_equal(a.data.test(i), b.data.test(i), "row " + String(i))


def test_split_keeps_left_to_right_order() raises:
    var e = Expr.binary(
        BIN_AND, _cmp(BIN_GT, "a", 1), Expr.binary(BIN_AND, _cmp(BIN_GT, "b", 2), _cmp(BIN_GT, "c", 3))
    )
    var out = List[Expr]()
    split_and_conjuncts(e, out)
    assert_equal(len(out), 3)
    assert_equal(out[0].binary_left_ref().col_ref_name(), "a")
    assert_equal(out[2].binary_left_ref().col_ref_name(), "c")
    var single = List[Expr]()
    split_and_conjuncts(_cmp(BIN_GT, "a", 1), single)
    assert_equal(len(single), 1)


def test_the_lead_and_the_first_deferred_conjunct() raises:
    var plan = SelectionPlan([2])
    var cols: List[List[Int]] = [[0], [0, 1], [2], [3]]
    # Conjunct 1 only adds column 1, which does not pay: the lead runs to 2.
    assert_equal(first_deferred_conjunct(cols, plan), 2)
    assert_true(staged_filter_worthwhile(cols, plan))
    # A paying column already read by the first conjunct defers nothing.
    var early: List[List[Int]] = [[2], [2]]
    assert_equal(first_deferred_conjunct(early, plan), -1)
    # A first conjunct with no column, or a single conjunct: nothing to stage.
    var nocol: List[List[Int]] = [List[Int](), [2]]
    assert_false(staged_filter_worthwhile(nocol, plan))
    var one: List[List[Int]] = [[2]]
    assert_false(staged_filter_worthwhile(one, plan))


def test_definite_true_drops_unknown_with_a_set_data_bit() raises:
    var m = BooleanArray.allocate(3)
    m.data.set(0)
    m.data.set(1)
    var valid = Bitmap.create(3)
    valid.set(0)
    valid.set(2)
    m.validity = Optional[Bitmap[HeapRegion]](valid^)
    m.null_count = 1
    var d = definite_true(m^)
    assert_true(d.data.test(0))
    assert_false(d.data.test(1))
    assert_false(d.data.test(2))
    assert_equal(d.true_count(), 1)


def test_compose_survivors() raises:
    var outer = BooleanArray.allocate(6)
    outer.data.set(1)
    outer.data.set(3)
    outer.data.set(4)
    var inner = BooleanArray.allocate(3)
    inner.data.set(0)
    inner.data.set(2)
    var c = compose_survivors(outer, inner)
    assert_equal(c.true_count(), 2)
    assert_true(c.data.test(1))
    assert_false(c.data.test(3))
    assert_true(c.data.test(4))
    with assert_raises(contains="inner mask has 2 rows"):
        _ = compose_survivors(outer, BooleanArray.allocate(2))


def test_hconcat_refuses_different_row_counts() raises:
    var reader = _reader()
    var a = reader.decode_columns_subset(0, [0], False)
    var b = RecordBatch.count_only(3)
    with assert_raises(contains="row counts differ"):
        _ = hconcat_share(a, b)


def test_a_selective_lead_stages_and_emits() raises:
    reset_staged_filter_counts()
    var reader = _reader()
    # a < 6 AND s <> 's0' AND n > 0: the lead (a) keeps 6 of 40 rows.
    var pred = _and3(_cmp(BIN_LT, "a", 6), _scmp(BIN_NE, "s", "s0"), _cmp(BIN_GT, "n", 0))
    var conjuncts = List[Expr]()
    split_and_conjuncts(pred, conjuncts)
    var conjunct_cols = List[List[Int]]()
    var all_cols = List[Int]()
    assert_true(resolve_conjunct_columns(reader, conjuncts, conjunct_cols, all_cols))
    assert_equal(len(all_cols), 3)
    var plan = selection_plan_for(reader, 0, all_cols, False, False)
    assert_equal(len(plan.pays), 1)  # s, the PLAIN string column
    assert_equal(plan.pays[0], 1)
    assert_true(staged_filter_worthwhile(conjunct_cols, plan))
    var res = run_staged_filter(reader, 0, conjuncts, conjunct_cols, plan, False)
    assert_false(res.declined)
    var want = _one_shot(reader, pred, [0, 1, 3])
    assert_equal(res.rows, want.true_count())
    _same_mask(res.alive.value(), want)
    # s was read for the lead's survivors only; n by full decode and gather.
    assert_equal(staged_filter_sel_count(), 1)
    assert_equal(staged_filter_gather_count(), 1)
    # The survivors (a = 1, 2, 3 with n = r % 7 - 2 > 0 and not null, s <> s0):
    # a=3 (n=1, s3). Rows 1 and 2 have n <= 0; row 5 has a >= 6... and row 0
    # is null.
    var proj: List[Int] = [2, 0]  # t (payload), a (filter)
    var out = staged_emit_batch(reader, 0, res, proj, PAYLOAD_SEL_VAR_WIDTH, False)
    assert_equal(out.num_rows(), want.true_count())
    assert_equal(out.schema.field_name(0), "t")
    assert_equal(out.schema.field_name(1), "a")
    var k = 0
    for r in range(_ROWS):
        if want.data.test(r):
            assert_equal(Int(out.column_at(1).as_primitive[DType.int64]().get(k)), r)
            assert_equal(out.column_at(0).as_string().get(k), _t(r))
            k += 1
    assert_equal(k, 1)


def test_a_non_selective_lead_declines_and_hands_off() raises:
    var reader = _reader()
    # a >= 0 AND s <> 's1' AND n > 0: the lead keeps every row.
    var pred = _and3(_cmp(BIN_GE, "a", 0), _scmp(BIN_NE, "s", "s1"), _cmp(BIN_GT, "n", 0))
    var conjuncts = List[Expr]()
    split_and_conjuncts(pred, conjuncts)
    var conjunct_cols = List[List[Int]]()
    var all_cols = List[Int]()
    assert_true(resolve_conjunct_columns(reader, conjuncts, conjunct_cols, all_cols))
    var plan = selection_plan_for(reader, 0, all_cols, False, False)
    var res = run_staged_filter(reader, 0, conjuncts, conjunct_cols, plan, False)
    assert_true(res.declined)
    assert_equal(res.next_conjunct, 1)
    var out_batch: Optional[RecordBatch] = None
    var out_mask: Optional[BooleanArray] = None
    staged_handoff(reader, 0, res, all_cols, conjuncts, False, out_batch, out_mask)
    var want = _one_shot(reader, pred, all_cols)
    _same_mask(out_mask.value(), want)
    ref b = out_batch.value()
    assert_equal(b.num_rows(), _ROWS)
    assert_equal(b.num_columns(), 3)
    assert_equal(b.schema.field_name(0), "a")
    assert_equal(b.schema.field_name(2), "n")


def test_nothing_survives_and_unresolved_names() raises:
    var reader = _reader()
    var pred = Expr.binary(BIN_AND, _cmp(BIN_LT, "a", 0), _scmp(BIN_NE, "s", "x"))
    var conjuncts = List[Expr]()
    split_and_conjuncts(pred, conjuncts)
    var conjunct_cols = List[List[Int]]()
    var all_cols = List[Int]()
    assert_true(resolve_conjunct_columns(reader, conjuncts, conjunct_cols, all_cols))
    var res = run_staged_filter(reader, 0, conjuncts, conjunct_cols, SelectionPlan([1]), False)
    assert_equal(res.rows, 0)
    assert_false(res.batch.__bool__())
    var bad = List[Expr]()
    bad.append(_cmp(BIN_GT, "missing", 1))
    var bc = List[List[Int]]()
    var ba = List[Int]()
    assert_false(resolve_conjunct_columns(reader, bad, bc, ba))


def test_nulls_in_a_deferred_conjunct_never_survive() raises:
    var reader = _reader()
    # a < 12 AND s <> 'zz' AND n > -9: every non-null n passes, so exactly
    # the null rows among a < 12 (rows 0, 5, 10) must be dropped.
    var pred = _and3(_cmp(BIN_LT, "a", 12), _scmp(BIN_NE, "s", "zz"), _cmp(BIN_GT, "n", -9))
    var conjuncts = List[Expr]()
    split_and_conjuncts(pred, conjuncts)
    var conjunct_cols = List[List[Int]]()
    var all_cols = List[Int]()
    assert_true(resolve_conjunct_columns(reader, conjuncts, conjunct_cols, all_cols))
    var plan = selection_plan_for(reader, 0, all_cols, False, False)
    var res = run_staged_filter(reader, 0, conjuncts, conjunct_cols, plan, False)
    assert_equal(res.rows, 9)
    ref alive = res.alive.value()
    for r in range(_ROWS):
        assert_equal(alive.data.test(r), r < 12 and not _n_null(r), "row " + String(r))
    var out = staged_emit_batch(reader, 0, res, [3], PAYLOAD_SEL_OFF, False)
    assert_equal(out.column_at(0).null_count(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
