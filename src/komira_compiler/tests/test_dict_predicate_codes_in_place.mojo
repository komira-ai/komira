# =============================================================================
# `col <op> 'lit'` over a STRING DICTIONARY column reads
# the codes IN PLACE, builds its mask branch-free, and treats a NULL row as NULL
# =============================================================================
#
# `compiler_eval_predicate._eval_predicate`'s DICTIONARY arm used to call
# `Column.as_dictionary` (a COPY of the whole code buffer per batch) and then
# `dict_filter_eval_bool_mask`, whose mask loop decides every row behind two
# branches — and returned that raw verdict for NULL rows too, the only
# comparison arm in the ladder that skipped `kleene_cmp_finalize_scalar`. Under
# the kept-codes grouped-CD collect that arm runs on every row group of cbq10.
#
# WHAT THIS FILE KILLS:
#   §1  any verdict difference from the old kernel on NON-NULL rows, for all
#       six operators, over a dictionary whose entries are unordered, one of
#       which is EMPTY and one of which is never referenced, across a row
#       count that is not a multiple of 8 (the tail byte);
#   §2  a window read from the buffer start instead of `_offset` (a zero-copy
#       `Column.slice`);
#   §3  ⛔ THE BUG: a NULL row whose placeholder code points at an entry that
#       satisfies the predicate came back TRUE. SQL: `NULL <> ''` is NULL, and
#       a filter keeps only TRUE rows.

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.bitmap import Bitmap
from komira_core.arrow.column import Column
from komira_core.arrow.dictionary_array import StringDictionaryArray
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from komira_core.arrow.string_array import StringArray
from komira_core.eval.dict_filter import DictFilterOp, dict_filter_eval_bool_mask
from komira_core.io.heap_region import HeapRegion
from komira_core.plan.expr import (
    BIN_EQ, BIN_GE, BIN_GT, BIN_LE, BIN_LT, BIN_NE, Expr,
)
from komira_core.plan.scalar_value import ScalarValue
from komira_compiler.compiler_eval_predicate import _eval_predicate


comptime _N: Int = 1_003  # NOT a multiple of 8: the tail byte is exercised


def _dict_values() -> List[String]:
    var out: List[String] = [
        String("iPhone"), String(""), String("Galaxy"), String("never"),
        String("iPad"), String("Äpfel"), String("Pixel"),
    ]
    return out^


def _code(r: Int) -> Int32:
    var c = (r * 5 + r // 7) % 7
    if c == 3:
        c = 4  # entry 3 ("never") is never referenced by a row
    return Int32(c)


def _is_null(r: Int) -> Bool:
    return r % 11 == 4


def _column(nullable: Bool) raises -> Column[HeapRegion]:
    var codes = List[Int32](capacity=_N)
    for r in range(_N):
        # A NULL row carries code 0 ("iPhone"), which satisfies `<> ''`.
        codes.append(Int32(0) if (nullable and _is_null(r)) else _code(r))
    var idx = PrimitiveArray[DType.int32].from_list(codes)
    if nullable:
        var vbm = Bitmap.create_all_valid(_N)
        var nc = 0
        for r in range(_N):
            if _is_null(r):
                vbm.clear(r)
                nc += 1
        idx.validity = Optional[Bitmap[HeapRegion]](vbm^)
        idx.null_count = nc
    var sda = StringDictionaryArray.from_parts(
        idx^, StringArray.from_strings(_dict_values())
    )
    return Column.from_dictionary(sda)


def _batch(var c: Column[HeapRegion]) raises -> RecordBatch:
    var b = RecordBatchBuilder.with_capacity(1)
    var nullable = c.null_count() > 0
    b.add_column(c^)
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.DICTIONARY, nullable))
    return b.build(sb.build())


def _pred(op: UInt8, v: String) -> Expr:
    return Expr.binary(
        op, Expr.col_ref(String("k")), Expr.literal(ScalarValue.from_string(v))
    )


def _dict_op(op: UInt8) -> DictFilterOp:
    if op == BIN_EQ:
        return DictFilterOp.EQ
    elif op == BIN_NE:
        return DictFilterOp.NE
    elif op == BIN_GT:
        return DictFilterOp.GT
    elif op == BIN_LT:
        return DictFilterOp.LT
    elif op == BIN_GE:
        return DictFilterOp.GE
    return DictFilterOp.LE


def _ops() -> List[UInt8]:
    var out: List[UInt8] = [BIN_EQ, BIN_NE, BIN_GT, BIN_LT, BIN_GE, BIN_LE]
    return out^


def test_in_place_kernel_equals_the_copying_kernel() raises:
    """§1: every operator, two literals (one EMPTY), non-null rows."""
    var c = _column(False)
    var old_arr = c.as_dictionary()
    var batch = _batch(c^)
    var lits: List[String] = [String(""), String("iPad")]
    for li in range(len(lits)):
        for oi in range(len(_ops())):
            var op = _ops()[oi]
            var want = dict_filter_eval_bool_mask(old_arr, _dict_op(op), lits[li])
            var got = _eval_predicate(_pred(op, lits[li]), batch)
            assert_equal(got.length, _N, "length")
            for r in range(_N):
                if got.get(r) != want.get(r):
                    raise Error(
                        "op " + String(Int(op)) + " lit '" + lits[li]
                        + "' row " + String(r) + ": in-place differs"
                    )


def test_window_honours_the_column_offset() raises:
    """§2: a zero-copy slice; the verdict for window row r is the verdict for
    parent row start + r."""
    var start = 37
    var length = 500
    var parent = _column(False)
    var win = parent.slice(start, length)
    assert_equal(win._offset, start, "fixture: the slice carries _offset")
    var batch = _batch(win^)
    var got = _eval_predicate(_pred(BIN_EQ, String("iPad")), batch)
    var vals = _dict_values()
    for r in range(length):
        var want = vals[Int(_code(start + r))] == "iPad"
        assert_equal(got.get(r), want, "window row " + String(r))


def test_a_null_row_is_never_kept() raises:
    """§3 — THE BUG. Every NULL row's code is 0 ("iPhone"), which satisfies
    `k <> ''`; the old arm answered TRUE for it."""
    var batch = _batch(_column(True))
    var got = _eval_predicate(_pred(BIN_NE, String("")), batch)
    var vals = _dict_values()
    var nulls = 0
    for r in range(_N):
        if _is_null(r):
            nulls += 1
            assert_false(got.get(r), "NULL row " + String(r) + " must not be TRUE")
        else:
            assert_equal(
                got.get(r), vals[Int(_code(r))] != "", "row " + String(r)
            )
    assert_true(nulls > 50, "VACUITY: the fixture must carry NULL rows")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
