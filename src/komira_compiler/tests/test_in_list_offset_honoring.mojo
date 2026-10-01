# =============================================================================
# test_in_list_offset_honoring — IN-list typed kernels must honor `arr.offset`
# =============================================================================
#
# D4 / COL_VIEW_ELIM blocker. REGRESSION GUARD for a
# SILENT-WRONG-ANSWER defect in the three numeric IN-list kernels.
#
# ROOT CAUSE (pre-fix): `_eval_in_list_int64` / `_eval_in_list_int32` /
# `_eval_in_list_float64` in `compiler_eval_in_list.mojo` took their data
# pointer from `arr.data.view_ro` — a view over the WHOLE backing buffer
# from byte 0 — and then read `(data_ptr + idx)[]` for `idx in [0, length)`.
# `arr.offset` was never referenced. Every other PrimitiveArray VALUE accessor
# in the tree (`get` / `set` / `view_ro` / `view_mut` / `slice` /
# `_unsafe_data_ptr` / `_typed_ptr_ro` / `_typed_ptr_mut`) indexes
# `self.offset + i`, so these three violated the array's own contract.
#
# WHY IT WAS LATENT: `Column.as_primitive` REBASES its result to `offset == 0`,
# so at the live call sites `arr.offset` was always 0 and the wrong-base read
# coincided with the right one.
#
# ⚠ CORRECTED — THE ORIGINAL SECOND HALF OF THIS PARAGRAPH IS NOW
# FALSE IN BOTH ITS CLAIMS, and it is corrected rather than deleted because it
# is the reason this file exists. It read: "The D4 lever
# (`COL_VIEW_ELIM_ENABLED`, column.mojo) replaces that copy with a zero-copy Arc
# share that PRESERVES `_offset` ... The moment D4 flips, any non-nullable
# column with `offset > 0` would evaluate IN-list predicates against the WRONG
# ELEMENTS." The share narrows to the WINDOW and rebases to 0
# exactly as the copy does. **D4 flipped ON and this kernel was
# not a blocker for it.**
#
# THE FIX AND THIS FILE BOTH STAND ANYWAY, and must not be reverted on the
# strength of that correction: an `offset > 0` array still reaches these kernels
# from `Column.share_as_primitive` (which carries the offset deliberately) and
# from `PrimitiveArray.slice`. The guarded property is the array's own contract,
# not a property of whichever `as_primitive` arm is compiled.
#
# FAILS ON CURRENT CODE (pre-fix): the fixtures below build a NON-NULLABLE
# PrimitiveArray whose window is `[5, 18)` of a 24-element buffer (`offset == 5`,
# `length == 13` — 1 full bitmap byte + a 5-bit tail, so BOTH kernel loops are
# exercised). The value ladder is chosen so the offset-blind window
# `values[0..13)` and the correct window `values[5..18)` produce DIFFERENT
# membership masks. Pre-fix, every offset case returns the `values[0..13)` mask
# and the per-row assert against the independent closed-form oracle fires.
#
# The `*_offset_zero_control` cases pin that the fix is a NO-OP at `offset == 0`
# (today's live shape) — they pass both pre- and post-fix.
#
# The asserts are written against an INDEPENDENT oracle (membership computed
# in the test from the absolute value ladder), not against whichever pointer
# base the kernel happens to use, so this file is a live guard at BOTH D4
# settings.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.plan.scalar_value import ScalarValue

from komira_compiler.compiler_eval_in_list import (
    _eval_in_list_int64,
    _eval_in_list_int32,
    _eval_in_list_float64,
)


# =============================================================================
# Fixture shape
# =============================================================================
#
# 24 absolute rows; the logical window is [_WIN_START, _WIN_START + _WIN_LEN).
# _WIN_LEN == 13 == 8 + 5 so the kernel's full-byte loop AND its remainder
# tail both run. _WIN_START == 5 is deliberately not a multiple of 8.

comptime _N_TOTAL = 24
comptime _WIN_START = 5
comptime _WIN_LEN = 13


def _ladder_i64(i: Int) -> Int64:
    """Absolute value at row `i`: a strictly increasing ladder, so any two
    distinct windows of it have distinct contents."""
    return Int64(i) * 100


def _ladder_i32(i: Int) -> Int32:
    return Int32(i) * 100


def _ladder_f64(i: Int) -> Float64:
    return Float64(i) * 100.0 + 0.5


def _offset_arr_i64(start: Int, length: Int) raises -> PrimitiveArray[DType.int64]:
    """Non-nullable INT64 array whose logical window is [start, start+length)
    of the ladder, carried as `offset == start` (NOT rebased to 0)."""
    var full = PrimitiveArray[DType.int64].allocate(_N_TOTAL)
    var p = full._typed_ptr_mut()
    for i in range(_N_TOTAL):
        (p + i)[] = _ladder_i64(i)
    return full.slice(start, length)


def _offset_arr_i32(start: Int, length: Int) raises -> PrimitiveArray[DType.int32]:
    var full = PrimitiveArray[DType.int32].allocate(_N_TOTAL)
    var p = full._typed_ptr_mut()
    for i in range(_N_TOTAL):
        (p + i)[] = _ladder_i32(i)
    return full.slice(start, length)


def _offset_arr_f64(start: Int, length: Int) raises -> PrimitiveArray[DType.float64]:
    var full = PrimitiveArray[DType.float64].allocate(_N_TOTAL)
    var p = full._typed_ptr_mut()
    for i in range(_N_TOTAL):
        (p + i)[] = _ladder_f64(i)
    return full.slice(start, length)


def _assert_mask_f64(
    got: BooleanArray,
    start: Int,
    length: Int,
    members: List[Float64],
    label: String,
) raises:
    """Assert `got` equals the INDEPENDENT closed-form oracle: row j is True
    iff the ABSOLUTE ladder value at (start + j) is in `members`."""
    assert_equal(got.length, length, label + ": length")
    for j in range(length):
        var v = _ladder_f64(start + j)
        var want = False
        for m in range(len(members)):
            if v == members[m]:
                want = True
        assert_true(
            got.get(j) == want,
            label
            + ": row "
            + String(j)
            + " (abs row "
            + String(start + j)
            + ", val "
            + String(v)
            + ", want "
            + String(want)
            + ", got "
            + String(got.get(j))
            + ")",
        )


def _assert_mask_i64(
    got: BooleanArray,
    start: Int,
    length: Int,
    members: List[Int64],
    label: String,
) raises:
    assert_equal(got.length, length, label + ": length")
    for j in range(length):
        var v = _ladder_i64(start + j)
        var want = False
        for m in range(len(members)):
            if v == members[m]:
                want = True
        assert_true(
            got.get(j) == want,
            label
            + ": row "
            + String(j)
            + " (abs row "
            + String(start + j)
            + ", val "
            + String(v)
            + ", want "
            + String(want)
            + ", got "
            + String(got.get(j))
            + ")",
        )


# =============================================================================
# 1. INT64 kernel — offset > 0
# =============================================================================
#   Members {700, 900, 1200} hit ABSOLUTE rows 7, 9, 12 -> window rows 2, 4, 7.
#   Offset-blind (pre-fix) reads values[0..13) -> window rows 7, 9, 12. Disjoint.


def test_int64_in_list_honors_offset() raises:
    var arr = _offset_arr_i64(_WIN_START, _WIN_LEN)
    assert_equal(arr.offset, _WIN_START, "fixture must carry offset > 0")
    assert_equal(arr.length, _WIN_LEN, "fixture window length")

    var members = List[ScalarValue]()
    members.append(ScalarValue.from_int64(Int64(700)))
    members.append(ScalarValue.from_int64(Int64(900)))
    members.append(ScalarValue.from_int64(Int64(1200)))

    var mask = _eval_in_list_int64(arr, members, ArrowType.INT64)
    var oracle: List[Int64] = [700, 900, 1200]
    _assert_mask_i64(
        mask, _WIN_START, _WIN_LEN, oracle, String("INT64 IN-list @ offset 5")
    )


def test_int64_in_list_offset_zero_control() raises:
    """Control: at offset == 0 the kernel was already correct; the fix must
    not change it. Passes both pre- and post-fix."""
    var arr = _offset_arr_i64(0, _WIN_LEN)
    assert_equal(arr.offset, 0, "control fixture offset")

    var members = List[ScalarValue]()
    members.append(ScalarValue.from_int64(Int64(700)))
    members.append(ScalarValue.from_int64(Int64(900)))
    members.append(ScalarValue.from_int64(Int64(1200)))

    var mask = _eval_in_list_int64(arr, members, ArrowType.INT64)
    var oracle: List[Int64] = [700, 900, 1200]
    _assert_mask_i64(
        mask, 0, _WIN_LEN, oracle, String("INT64 IN-list @ offset 0 (control)")
    )


# =============================================================================
# 2. INT32 kernel — offset > 0
# =============================================================================


def test_int32_in_list_honors_offset() raises:
    var arr = _offset_arr_i32(_WIN_START, _WIN_LEN)
    assert_equal(arr.offset, _WIN_START, "fixture must carry offset > 0")

    var members = List[ScalarValue]()
    members.append(ScalarValue.from_int(600))
    members.append(ScalarValue.from_int(1100))
    members.append(ScalarValue.from_int(1700))

    var mask = _eval_in_list_int32(arr, members, ArrowType.INT32)
    var oracle: List[Int64] = [600, 1100, 1700]
    _assert_mask_i64(
        mask, _WIN_START, _WIN_LEN, oracle, String("INT32 IN-list @ offset 5")
    )


def test_int32_in_list_offset_zero_control() raises:
    var arr = _offset_arr_i32(0, _WIN_LEN)
    assert_equal(arr.offset, 0, "control fixture offset")

    var members = List[ScalarValue]()
    members.append(ScalarValue.from_int(600))
    members.append(ScalarValue.from_int(1100))

    var mask = _eval_in_list_int32(arr, members, ArrowType.INT32)
    var oracle: List[Int64] = [600, 1100]
    _assert_mask_i64(
        mask, 0, _WIN_LEN, oracle, String("INT32 IN-list @ offset 0 (control)")
    )


# =============================================================================
# 3. DATE32 — routes to the INT32 kernel (the temporally-STAMPED shape)
# =============================================================================
#   Same physical kernel, temporal literal field. Guards that the offset fix
#   holds on the DATE32 dispatch arm too (`_eval_in_list` routes DATE32 /
#   TIME32_* to `_eval_in_list_int32`).


def test_date32_in_list_honors_offset() raises:
    var arr = _offset_arr_i32(_WIN_START, _WIN_LEN)
    assert_equal(arr.offset, _WIN_START, "fixture must carry offset > 0")

    var members = List[ScalarValue]()
    members.append(ScalarValue.date32(Int32(800)))
    members.append(ScalarValue.date32(Int32(1300)))

    var mask = _eval_in_list_int32(arr, members, ArrowType.DATE32)
    var oracle: List[Int64] = [800, 1300]
    _assert_mask_i64(
        mask, _WIN_START, _WIN_LEN, oracle, String("DATE32 IN-list @ offset 5")
    )


# =============================================================================
# 4. FLOAT64 kernel — offset > 0
# =============================================================================


def test_float64_in_list_honors_offset() raises:
    var arr = _offset_arr_f64(_WIN_START, _WIN_LEN)
    assert_equal(arr.offset, _WIN_START, "fixture must carry offset > 0")

    var members = List[ScalarValue]()
    members.append(ScalarValue.from_float(700.5))
    members.append(ScalarValue.from_float(900.5))
    members.append(ScalarValue.from_float(1200.5))

    var mask = _eval_in_list_float64(arr, members)
    var oracle: List[Float64] = [700.5, 900.5, 1200.5]
    _assert_mask_f64(
        mask, _WIN_START, _WIN_LEN, oracle, String("FLOAT64 IN-list @ offset 5")
    )


def test_float64_in_list_offset_zero_control() raises:
    var arr = _offset_arr_f64(0, _WIN_LEN)
    assert_equal(arr.offset, 0, "control fixture offset")

    var members = List[ScalarValue]()
    members.append(ScalarValue.from_float(700.5))
    members.append(ScalarValue.from_float(900.5))

    var mask = _eval_in_list_float64(arr, members)
    var oracle: List[Float64] = [700.5, 900.5]
    _assert_mask_f64(
        mask, 0, _WIN_LEN, oracle, String("FLOAT64 IN-list @ offset 0 (control)")
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_int64_in_list_honors_offset]()
    suite.test[test_int64_in_list_offset_zero_control]()
    suite.test[test_int32_in_list_honors_offset]()
    suite.test[test_int32_in_list_offset_zero_control]()
    suite.test[test_date32_in_list_honors_offset]()
    suite.test[test_float64_in_list_honors_offset]()
    suite.test[test_float64_in_list_offset_zero_control]()
    suite^.run()
