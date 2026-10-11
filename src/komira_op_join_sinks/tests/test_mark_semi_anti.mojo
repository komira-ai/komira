# `MarkSemiAntiProbeOp` and `FinalizedHashIndex`: a SEMI / ANTI join that
# builds its LEFT side, streams its RIGHT side through the marking operator,
# and reads the LEFT survivors from the matched flags.
#
#   * The answer, row by row, on a LEFT side with duplicate keys, a NULL key
#     whose slot holds 0, the key 0, INT64_MAX and a negative key, against a
#     RIGHT side with a NULL key whose slot holds a LEFT key (9): SEMI keeps
#     the LEFT rows whose key some RIGHT row has, each once; ANTI keeps the
#     rest, the NULL-key row included; the RIGHT NULL marks nothing (DuckDB's
#     answer). Every chain-entry layout of the table (fused or split, with or
#     without build_indices, payload-inline) and the bloom on and off give it.
#     A walk that stopped at the first match would miss row 2 (the second 5).
#   * Two workers' operators sharing one index, each over its own RIGHT
#     morsel, mark the union.
#   * A RIGHT row the morsel's selection mask excludes marks nothing. Without
#     that check (thorium's operator had none) the masked-out key 5 marks
#     LEFT rows 0 and 2 and SEMI returns them.
#   * A brute-force nested loop over 2,000 LEFT and 9,000 RIGHT rows with
#     NULLs on both sides agrees with the marked answer for SEMI and ANTI.
#   * `execute` empties the morsel and returns NEED_MORE_INPUT; an empty
#     LEFT side and an empty RIGHT morsel mark nothing.
#   * The index refuses a table and batch with different row counts; an
#     out-of-range flag read is an error.
#   * A FLOAT64 RIGHT key is refused (the single-key probe reads INT64 keys).

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false, assert_raises

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_buffer.heap_region import HeapRegion
from komira_morsel.morsel import Morsel

from komira_op_join_build.join import HashJoinBuilder

from komira_op_join_sinks.finalized_hash_index import FinalizedHashIndex
from komira_op_join_sinks.mark_semi_anti import MarkSemiAntiProbeOp


comptime NULL: Int64 = -999
"""An INT64 entry written as NULL; `null_slot` is what its slot holds."""


def _i64(vals: List[Int64], null_slot: Int64 = 0) -> Column[HeapRegion]:
    var has_null = False
    for v in vals:
        if v == NULL:
            has_null = True
    if not has_null:
        return Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(vals))
    var arr = PrimitiveArray[DType.int64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        arr._typed_ptr_mut()[i] = null_slot if vals[i] == NULL else vals[i]
        if vals[i] == NULL:
            arr._set_null(i)
    return Column.from_primitive[DType.int64](arr^)


def _batch(k: String, keys: List[Int64], null_slot: Int64 = 0) raises -> RecordBatch:
    """Key column `k`, then `row` = 0, 1, 2, ..."""
    var rows = List[Int64]()
    for i in range(len(keys)):
        rows.append(Int64(i))
    var sb = SchemaBuilder()
    sb.add_field(Field(k, ArrowType.INT64, True))
    sb.add_field(Field("row", ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(_i64(keys, null_slot))
    rb.add_column(_i64(rows))
    return rb.build(sb.build())


def _left_keys() -> List[Int64]:
    return [5, 7, 5, NULL, 0, 9, Int64.MAX, -3]


def _right_keys() -> List[Int64]:
    """The NULL's slot holds 9 (see `_right`)."""
    return [5, NULL, 0, 100, 5, Int64.MAX, 0]


def _right() raises -> RecordBatch:
    return _batch("rk", _right_keys(), null_slot=9)


def _index(
    var left: RecordBatch,
    nobi: Bool = True,
    fused: Bool = True,
    pay: Bool = False,
    bloom: Bool = True,
) raises -> ArcPointer[FinalizedHashIndex]:
    var keys = left.column_at(0).as_primitive[DType.int64]()
    var b: HashJoinBuilder
    if pay:
        var pv = List[Int64]()
        for i in range(left.num_rows()):
            pv.append(Int64(i * 11))
        b = HashJoinBuilder.build(keys, build_bloom=bloom, pay_values=pv^, pay_build_col=1)
    else:
        b = HashJoinBuilder.build(keys, build_bloom=bloom, nobi=nobi, fused=fused)
    return ArcPointer[FinalizedHashIndex](FinalizedHashIndex(b^, left^))


def _mark(idx: ArcPointer[FinalizedHashIndex], var right: RecordBatch) raises:
    var op = MarkSemiAntiProbeOp(ArcPointer[FinalizedHashIndex](copy=idx), "rk")
    var m = Morsel(right^, 0, 0, 0)
    assert_true(op.execute(m).is_need_more_input(), "one call")
    assert_equal(m.batch.num_rows(), 0, "the morsel is emptied")


def _assert(got: List[Int], want: List[Int], what: String) raises:
    assert_equal(len(got), len(want), what + ": rows")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": row " + String(i))


def _check_answer(idx: ArcPointer[FinalizedHashIndex], what: String) raises:
    # SEMI: keys 5 (rows 0, 2), 0 (row 4), INT64_MAX (row 6).
    _assert(idx[].collect_marked_indices(True), [0, 2, 4, 6], what + " SEMI")
    # ANTI: 7, the NULL key, 9 (the RIGHT NULL's slot), -3.
    _assert(idx[].collect_marked_indices(False), [1, 3, 5, 7], what + " ANTI")


def test_every_layout_gives_the_answer() raises:
    for nobi in [True, False]:
        for fused in [True, False]:
            for bloom in [True, False]:
                var idx = _index(_batch("lk", _left_keys()), nobi, fused, bloom=bloom)
                _mark(idx, _right())
                _check_answer(
                    idx,
                    "nobi=" + String(nobi) + " fused=" + String(fused)
                    + " bloom=" + String(bloom),
                )
    var idx = _index(_batch("lk", _left_keys()), pay=True)
    assert_true(idx[].builder.pay_inline(), "fixture: payload-inline table")
    _mark(idx, _right())
    _check_answer(idx, "payload-inline")


def test_two_workers_mark_the_union() raises:
    var idx = _index(_batch("lk", _left_keys()))
    var a = MarkSemiAntiProbeOp(ArcPointer[FinalizedHashIndex](copy=idx), "rk")
    var b = MarkSemiAntiProbeOp(ArcPointer[FinalizedHashIndex](copy=idx), "rk")
    var m1 = Morsel(_batch("rk", [5, 100], null_slot=9), 0, 0, 0)
    var m2 = Morsel(_batch("rk", [NULL, 0, Int64.MAX], null_slot=9), 1, 1, 0)
    _ = a.execute(m1)
    _ = b.execute(m2)
    _check_answer(idx, "two workers")


def test_selection_mask_excludes_rows() raises:
    var idx = _index(_batch("lk", _left_keys()))
    var right = _batch("rk", [5, 9])
    var mask = BooleanArray.allocate(2)
    mask.set(0, False)
    mask.set(1, True)
    right.set_selection_mask(mask^)
    _mark(idx, right^)
    _assert(idx[].collect_marked_indices(True), [5], "only key 9 marks")


def test_against_nested_loop() raises:
    var lk = List[Int64]()
    for i in range(2_000):
        lk.append(NULL if i % 53 == 0 else Int64((i * 31) % 997 - 400))
    var rk = List[Int64]()
    for i in range(9_000):
        rk.append(NULL if i % 41 == 0 else Int64(2 * ((i * 7) % 1_300) - 1_300))
    # Nested loop: a LEFT row matches iff its key is not NULL and some
    # non-NULL RIGHT key equals it.
    var want_semi = List[Int]()
    var want_anti = List[Int]()
    for l in range(len(lk)):
        var hit = False
        if lk[l] != NULL:
            for r in range(len(rk)):
                if rk[r] != NULL and rk[r] == lk[l]:
                    hit = True
                    break
        if hit:
            want_semi.append(l)
        else:
            want_anti.append(l)
    assert_true(len(want_semi) > 100 and len(want_anti) > 100, "fixture: both sides")
    var idx = _index(_batch("lk", lk))
    # Three morsels through three operators.
    for part in range(3):
        var chunk = List[Int64]()
        for r in range(part * 3_000, (part + 1) * 3_000):
            chunk.append(rk[r])
        _mark(idx, _batch("rk", chunk, null_slot=lk[1]))
    _assert(idx[].collect_marked_indices(True), want_semi, "SEMI vs nested loop")
    _assert(idx[].collect_marked_indices(False), want_anti, "ANTI vs nested loop")


def test_empty_sides() raises:
    var idx = _index(_batch("lk", List[Int64]()))
    _mark(idx, _right())
    assert_equal(len(idx[].collect_marked_indices(True)), 0, "empty LEFT: no SEMI rows")
    assert_equal(len(idx[].collect_marked_indices(False)), 0, "empty LEFT: no ANTI rows")
    var idx2 = _index(_batch("lk", _left_keys()))
    _mark(idx2, _batch("rk", List[Int64]()))
    assert_equal(len(idx2[].collect_marked_indices(True)), 0, "empty RIGHT: nothing marked")


def test_index_checks() raises:
    var keys = PrimitiveArray[DType.int64].from_list([1, 2, 3])
    with assert_raises(contains="build rows"):
        _ = FinalizedHashIndex(HashJoinBuilder.build(keys), _batch("lk", [1, 2]))
    var idx = FinalizedHashIndex(HashJoinBuilder.build(keys), _batch("lk", [1, 2, 3]))
    assert_equal(idx.num_rows(), 3)
    idx.mark_matched(1)
    idx.mark_matched(-1)
    idx.mark_matched(3)
    assert_false(idx.is_matched(0))
    assert_true(idx.is_matched(1))
    with assert_raises(contains="out of range"):
        _ = idx.is_matched(3)


def test_float_right_key_is_refused() raises:
    var idx = _index(_batch("lk", _left_keys()))
    var op = MarkSemiAntiProbeOp(ArcPointer[FinalizedHashIndex](copy=idx), "rk")
    var sb = SchemaBuilder()
    sb.add_field(Field("rk", ArrowType.FLOAT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_primitive[DType.float64](PrimitiveArray[DType.float64].from_list([5.0]))
    )
    var m = Morsel(rb.build(sb.build()), 0, 0, 0)
    with assert_raises():
        _ = op.execute(m)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
