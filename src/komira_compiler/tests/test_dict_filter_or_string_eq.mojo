# =============================================================================
# Regression test: dict_filter_eval_bool_mask + OR composition for string EQ
# =============================================================================
#
# Guards TPC-H Q12's filter shape on dictionary-encoded string columns:
#     BIN_OR(l_shipmode == "MAIL", l_shipmode == "SHIP")
#
# The dict-aware filter (`dict_filter_eval_bool_mask`) composed via `eval_or`
# must produce the same rows as the dense path. A lifetime hazard in that
# kernel (a laundered address + wildcard origin) once made the composition
# return every row; the kernel now uses origin-tied views only.
#
# This test locks the dict-aware OR'd-EQ behavior so the underlying fix
# cannot silently regress when subsequent migrations touch
# `dict_filter.mojo` or `compiler_eval_predicate.mojo`. It exercises:
#
#   1. The dict-aware path directly (`dict_filter_eval_bool_mask` per
#      EQ side, `eval_or` to compose).
#   2. The integration path via `_eval_predicate` on a synthesized
#      DICTIONARY-typed `Column` and `RecordBatch`.
#
# Both paths assert per-row equality against a SCALAR reference computed
# by resolving each row to its dictionary string and checking membership
# in the OR set. The bug shape ("Q12 returns 7 groups
# instead of 2") would surface as `actual_true == num_rows` (all rows
# pass); the explicit `assert_true(actual_true < num_rows)` guards that
# specific failure mode.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.dictionary_array import StringDictionaryArray
from komira_core.arrow.column import Column
from komira_core.arrow.schema import Schema, Field, SchemaBuilder, RecordBatch, RecordBatchBuilder
from komira_core.arrow.arrow_types import ArrowType
from komira_core.eval.dict_filter import DictFilterOp, dict_filter_eval_bool_mask
from komira_core.eval.arithmetic import eval_or
from komira_compiler.compiler_eval_predicate import _eval_predicate
from komira_core.plan.col_expr import col, lit
from komira_core.plan.expr import Expr, BIN_OR, BIN_EQ


# Q12-shape dictionary values. Mirrors TPC-H l_shipmode cardinality.
def _shipmodes() -> List[String]:
    """Q12-shape 7-entry dictionary. Built each call (cheap; len=7)."""
    var out: List[String] = [
        String("AIR"),
        String("MAIL"),
        String("SHIP"),
        String("RAIL"),
        String("FOB"),
        String("REG AIR"),
        String("TRUCK"),
    ]
    return out^


def _shipmode_at(i: Int) -> String:
    """Return shipmode at index i (cycles modulo 7)."""
    var modes = _shipmodes()
    return modes[i % 7]


def _build_q12_shape_dict_array(num_rows: Int) raises -> StringDictionaryArray:
    """Build a StringDictionaryArray with Q12-shape (7 distinct shipmodes).

    Indices cycle through [0, 7) so every dictionary entry is exercised
    multiple times, ensuring the per-row scan in
    `_build_bool_mask_from_dict_match_buf` traverses many independent
    dict-index lookups.
    """
    var dict_strs = _shipmodes()
    var dict_arr = StringArray.from_strings(dict_strs)

    var indices = PrimitiveArray[DType.int32].allocate(num_rows)
    var idx_ptr = indices._typed_ptr_mut()
    for i in range(num_rows):
        (idx_ptr + i)[] = Scalar[DType.int32](i % 7)

    return StringDictionaryArray.from_parts(indices^, dict_arr^)


def _expected_or_eq_mask(num_rows: Int, a: String, b: String) -> List[Bool]:
    """Build the reference per-row truth array for `col == a OR col == b`."""
    var out = List[Bool]()
    for i in range(num_rows):
        var s = _shipmode_at(i)
        out.append(s == a or s == b)
    return out^


def test_or_eq_mail_or_ship_small() raises:
    """Q12's exact predicate at small N — pure dict-aware path.

    Indices [0..7) cycle; positions 1, 8, 15, ... map to "MAIL", positions
    2, 9, 16, ... map to "SHIP". Result must match SCALAR truth per-row.
    """
    var num_rows = 35  # 5 full cycles → exactly 5 MAIL + 5 SHIP rows
    var arr = _build_q12_shape_dict_array(num_rows)

    var mail_mask = dict_filter_eval_bool_mask(arr, DictFilterOp.EQ, "MAIL")
    var ship_mask = dict_filter_eval_bool_mask(arr, DictFilterOp.EQ, "SHIP")
    var or_mask = eval_or(mail_mask, ship_mask)

    var expected = _expected_or_eq_mask(num_rows, "MAIL", "SHIP")
    assert_equal(or_mask.length, num_rows)

    var actual_count = 0
    var expected_count = 0
    for i in range(num_rows):
        var got = or_mask.get(i)
        var want = expected[i]
        if got:
            actual_count += 1
        if want:
            expected_count += 1
        assert_equal(got, want)

    # Sanity: 35 rows / 7 dict entries = 5 of each → 5 MAIL + 5 SHIP = 10
    assert_equal(expected_count, 10)
    assert_equal(actual_count, 10)


def test_or_eq_mail_or_ship_large_multibyte() raises:
    """Same predicate, length stretches the byte-packed inner loop.

    `_build_bool_mask_from_dict_match_buf` packs 8 rows per byte and has a
    separate trailing-bits branch for `num_rows & 7 != 0`. 1003 = 125
    full bytes + 3 trailing bits exercises both code paths.
    """
    var num_rows = 1003
    var arr = _build_q12_shape_dict_array(num_rows)

    var mail_mask = dict_filter_eval_bool_mask(arr, DictFilterOp.EQ, "MAIL")
    var ship_mask = dict_filter_eval_bool_mask(arr, DictFilterOp.EQ, "SHIP")
    var or_mask = eval_or(mail_mask, ship_mask)

    var expected = _expected_or_eq_mask(num_rows, "MAIL", "SHIP")
    assert_equal(or_mask.length, num_rows)

    for i in range(num_rows):
        # Fail loudly with the row index so a regression points at the offset.
        if or_mask.get(i) != expected[i]:
            print(
                "ROW MISMATCH at row=", i,
                " dict_idx=", i % 7,
                " val='", _shipmode_at(i),
                "' got=", or_mask.get(i),
                " want=", expected[i],
            )
        assert_equal(or_mask.get(i), expected[i])


def test_or_eq_per_side_unaffected() raises:
    """Each EQ side, taken alone, must agree with the SCALAR reference.

    If a single-side EQ already disagrees with the reference, the OR can't
    be right either. Splitting the assertion lets the bisect bisect: if
    this test fails but the OR test fails too, the bug is per-side; if
    only the OR test fails, the bug is in the OR composition or the
    boolean-array layout `eval_or` consumes.
    """
    var num_rows = 100
    var arr = _build_q12_shape_dict_array(num_rows)

    var mail_mask = dict_filter_eval_bool_mask(arr, DictFilterOp.EQ, "MAIL")
    assert_equal(mail_mask.length, num_rows)
    for i in range(num_rows):
        var want = (_shipmode_at(i) == String("MAIL"))
        assert_equal(mail_mask.get(i), want)

    var ship_mask = dict_filter_eval_bool_mask(arr, DictFilterOp.EQ, "SHIP")
    assert_equal(ship_mask.length, num_rows)
    for i in range(num_rows):
        var want = (_shipmode_at(i) == String("SHIP"))
        assert_equal(ship_mask.get(i), want)


def test_or_eq_no_match_one_match() raises:
    """OR of a side with zero matches and a side with some matches.

    Q12's filter has both sides matching some rows. This variant covers
    `eval_or` of (all-zeros, some-bits-set), which is also the result
    when the bool-mask trailing-bit handling sets phantom bits beyond
    `length`.
    """
    var num_rows = 51  # 6 full bytes + 3 trailing bits
    var arr = _build_q12_shape_dict_array(num_rows)

    # Left side: a value not in the dictionary → all zeros.
    var none_mask = dict_filter_eval_bool_mask(arr, DictFilterOp.EQ, "BICYCLE")
    # Right side: matches the AIR rows (dict index 0).
    var air_mask = dict_filter_eval_bool_mask(arr, DictFilterOp.EQ, "AIR")

    var or_mask = eval_or(none_mask, air_mask)
    assert_equal(or_mask.length, num_rows)

    var expected = _expected_or_eq_mask(num_rows, "BICYCLE", "AIR")
    for i in range(num_rows):
        assert_equal(or_mask.get(i), expected[i])


def test_or_eq_via_eval_predicate_on_dict_column() raises:
    """End-to-end: build a RecordBatch with a DICTIONARY-typed Column and
    drive `_eval_predicate(BIN_OR(col == "MAIL", col == "SHIP"), batch)`.

    This is the EXACT path Q12 takes after the fixture re-encode. The
    direct unit test of `dict_filter_eval_bool_mask` cannot catch a bug
    that lives in the integration: short-circuit OR evaluation, the
    Column->StringDictionaryArray reconstruction, schema/column type
    reconciliation, or the BoolMask -> downstream operator handoff.

    The repro mirrors the reported failure: "Q12 returns 7 groups
    instead of 2 with DICTIONARY columns" — i.e. the OR'd EQ filter
    erroneously passes ALL rows through. We check that the count of True
    bits in the resulting mask matches the SCALAR reference.
    """
    var num_rows = 200  # 25 full bytes, no trailing
    var dict_arr = _build_q12_shape_dict_array(num_rows)

    # Build the DICTIONARY-typed Column.
    var dict_col = Column.from_dictionary(dict_arr)

    # Schema declares STRING; RecordBatchBuilder reconciles to DICTIONARY
    # to match the column's actual physical type (matches the parquet
    # reader path: BYTE_ARRAY schema field, dict-encoded column).
    var sb = SchemaBuilder()
    sb.add_field(Field("shipmode", ArrowType.STRING, False))
    var b = RecordBatchBuilder()
    b.add_column(dict_col^)
    var batch = b.build(sb.build())

    # Sanity: the reconciler should have recognized the DICTIONARY column.
    assert_equal(batch.column_at(0).arrow_type, ArrowType.DICTIONARY)

    # Q12's exact predicate.
    var pred = Expr.binary(
        BIN_OR,
        col("shipmode") == "MAIL",
        col("shipmode") == "SHIP",
    )

    var mask = _eval_predicate(pred, batch)
    assert_equal(mask.length, num_rows)

    # Reference: 200 rows / 7 dict entries = 28 full + 4 leftover (positions
    # 0-3 → AIR, MAIL, SHIP, RAIL). MAIL = positions where i%7 == 1, SHIP =
    # positions where i%7 == 2. For 200 rows: i%7==1 occurs 29 times (rows
    # 1, 8, ..., 197), i%7==2 occurs 29 times (rows 2, 9, ..., 198) → 58
    # total. The bug returns ~num_rows (all matches) instead of ~58.
    var actual_true = mask.true_count()
    var expected = _expected_or_eq_mask(num_rows, "MAIL", "SHIP")
    var expected_true = 0
    for i in range(num_rows):
        if expected[i]:
            expected_true += 1

    # Per-row equality (the load-bearing assertion).
    for i in range(num_rows):
        if mask.get(i) != expected[i]:
            print(
                "EVAL_PREDICATE MISMATCH at row=", i,
                " dict_idx=", i % 7,
                " val='", _shipmode_at(i),
                "' got=", mask.get(i),
                " want=", expected[i],
            )
        assert_equal(mask.get(i), expected[i])

    assert_equal(actual_true, expected_true)
    # Sanity: must NOT match all rows. The Q12 bug surfaced as "all rows
    # match"; this guards against that specific failure.
    assert_true(actual_true < num_rows, "OR filter must not pass all rows")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
