# =============================================================================
# `resolve_numeric_dict_to_flat` MUST REBASE VALIDITY FOR A NONZERO `_offset`
# =============================================================================
#
# ★ THE DEFECT. The method's VALUES are windowed — `dict_code_at(r)` adds
# `_offset` — so its validity must be windowed too. A raw byte copy from BIT 0
# of the shared bitmap would, on a column with `_offset != 0`, pair row `r`'s
# VALUE with row `r - _offset`'s NULL BIT.
#
# ⚠ WHY IT MATTERS. `split_record_batch` diverts nullable columns to the copy
# slice, so a nonzero-offset nullable dictionary rarely reaches this method.
# Nothing in the method's contract says so, and the composite join's
# numeric-dict key extract depends on this method's validity output to decide
# `NULL never matches`. A validity bug here is one caller away from a wrong
# join answer.
#
# ⛔ WHAT MAKES THIS TEST NON-VACUOUS, and what quietly would not:
#
#   1. THE NULL PATTERN MUST DIFFER BETWEEN THE WINDOW AND THE PREFIX. If the
#      whole column's bits happen to agree at `[0, n)` and `[offset, offset+n)`
#      the raw copy is accidentally right. The fixture below is NULL at exactly
#      one index inside the window and at a DIFFERENT one before it, so both the
#      false-NULL and the false-VALID direction are exercised.
#   2. THE SLICE MUST BE ZERO-COPY. `Column.slice` raises for layouts that do
#      not honour `_offset`; the test asserts `_offset` really came out nonzero
#      rather than trusting that the slice was a view.
#   3. THE VALUES MUST BE CHECKED TOO. A "rebase" that also moved the values
#      would make the nulls line up while corrupting the column; the values are
#      asserted against the dictionary independently.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray


comptime I32 = DType.int32
comptime I64 = DType.int64

# 8 rows, sliced to `[3, 8)`. NULL at row 1 (BEFORE the window) and row 5
# (INSIDE it) — see guard 1. A raw bit-0 copy hands the 5-row result the bits of
# rows 0..4, so window row 2 (column row 5, the real NULL) comes out VALID and
# window row 1 (column row 4) comes out NULL. Both directions, one fixture.
comptime _N: Int = 8
comptime _SLICE_START: Int = 3
comptime _SLICE_LEN: Int = 5
comptime _NULL_BEFORE: Int = 1
comptime _NULL_INSIDE: Int = 5


def _nullable_codes() raises -> PrimitiveArray[I32]:
    """Codes `[0, 1, 2, 0, 1, 2, 0, 1]`, NULL at `_NULL_BEFORE` and
    `_NULL_INSIDE`. The code under a cleared bit is written anyway — the flat
    path reads it regardless of validity, exactly as the join kernels do."""
    var arr = PrimitiveArray[I32].allocate_nullable(_N)
    var p = arr._typed_ptr_mut()
    for i in range(_N):
        p.store[width=1](i, Int32(i % 3))
    arr._set_null(_NULL_BEFORE)
    arr._set_null(_NULL_INSIDE)
    return arr^


def _dict() raises -> List[Int64]:
    var d = List[Int64]()
    d.append(Int64(100))
    d.append(Int64(200))
    d.append(Int64(300))
    return d^


def test_numeric_dict_flat_rebases_validity_for_nonzero_offset() raises:
    var col = Column.from_numeric_dict[I32, I64](_nullable_codes(), _dict())
    assert_true(col.is_numeric_dict(), "fixture: numeric dict column")
    assert_equal(col.length(), _N, "fixture: 8 rows")

    var sliced = col.slice(_SLICE_START, _SLICE_LEN)
    # Guard 2: prove the slice is a VIEW carrying `_offset`, not a copy that
    # already rebased. If `Column.slice` ever starts copying dictionaries, this
    # test stops covering the rebase and says so instead of passing vacuously.
    assert_equal(
        sliced._offset,
        _SLICE_START,
        (
            "fixture: Column.slice no longer produces a nonzero _offset for a"
            " DICTIONARY column -- this test no longer exercises the rebase"
        ),
    )
    assert_equal(sliced.length(), _SLICE_LEN, "fixture: 5-row window")

    var flat = sliced.resolve_numeric_dict_to_flat()
    assert_false(flat.is_numeric_dict(), "flat result is not a dict")
    assert_equal(flat.arrow_type, ArrowType.INT64, "flat result is INT64")
    assert_equal(flat._offset, 0, "flat result is rebased to offset 0")

    var pa = flat.as_primitive[I64]()
    for w in range(_SLICE_LEN):
        var src_row = _SLICE_START + w
        # Guard 3: values, independently of nulls.
        assert_equal(
            pa.get(w),
            _dict()[src_row % 3],
            "flat value at window row " + String(w),
        )
        var want_null = src_row == _NULL_INSIDE
        assert_equal(
            pa.is_null(w),
            want_null,
            (
                "validity at window row "
                + String(w)
                + " (column row "
                + String(src_row)
                + ") -- a bit-0 copy would read column row "
                + String(w)
                + " instead"
            ),
        )
    _ = pa


def test_numeric_dict_flat_zero_offset_is_unchanged() raises:
    """The control. `_offset == 0` is the shape every live caller passes today,
    and the rebase must be a no-op on it — otherwise the fix is a new defect on
    the only path that was ever exercised."""
    var col = Column.from_numeric_dict[I32, I64](_nullable_codes(), _dict())
    var flat = col.resolve_numeric_dict_to_flat()
    var pa = flat.as_primitive[I64]()
    assert_equal(pa.length, _N, "control: all 8 rows")
    for i in range(_N):
        assert_equal(pa.get(i), _dict()[i % 3], "control value at row " + String(i))
        assert_equal(
            pa.is_null(i),
            i == _NULL_BEFORE or i == _NULL_INSIDE,
            "control validity at row " + String(i),
        )
    _ = pa


def main() raises:
    var suite = TestSuite()
    suite.test[test_numeric_dict_flat_rebases_validity_for_nonzero_offset]()
    suite.test[test_numeric_dict_flat_zero_offset_is_unchanged]()
    suite^.run()
