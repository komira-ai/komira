# =============================================================================
# test_gather_narrow_widths_core -- the 2-byte / 1-byte arms of the CORE
# fixed-width gathers
# =============================================================================
#
# WHAT IS UNDER TEST. Three fixed-width gather sites live in
# `komira_core/helpers` and have typed-store arms:
#
#   * `compiler_join_assembly.emit_gather_column_projected`, NULL-AWARE arm
#     (a `-1` index keeps the pre-zeroed destination slot)
#   * the same function's NON-NULLABLE arm
#   * `compiler_helpers._gather_batch`, reached by `gather_batch`
#
# Widths 8 and 4 had typed-store arms from the start; widths 2 and 1 have them
# too, and a per-row byte copy remains only for the 16- and 32-byte types
# (DECIMAL128, DECIMAL256, INTERVAL_MONTH_DAY_NANO), which is what §D asserts.
#
# ⛔ WHY THE COUNTERS AND NOT ONLY THE VALUES. A typed 2-byte store and a 2-byte
# copy produce BYTE-IDENTICAL output, so no value assertion anywhere can see the
# arm stop applying. `gather_width_counter.mojo` exists for exactly that, and it
# is asserted in BOTH directions here: `narrow_fallback == 0` beside a POSITIVE
# `wide_fallback` on a run that also drives a width the arms do not serve.
# Without the second half, `== 0` is equally satisfied by deleting the fallback
# and by a fixture that gathers nothing.
#
# ⚠ THE PARALLEL TWIN IS NOT HERE. `_GatherFixedWidthWork.process` (the
# `_parallel_fixedwidth_gather` chunk worker) needs `has_pool=True` and a live
# dispatcher, which a `komira_core` test cannot start. It is covered by the
# narrow-widths test in `komira_engine_dispatch`, where a
# `PerCoreAsyncRuntime` is available. Stated rather than left implicit so a
# reader does not conclude the parallel arm is unguarded.
#
# ⛔⛔ THE MUTATIONS -- EACH APPLIED AND RUN, NOT PREDICTED. Every line below
# is a recorded outcome of building and running this test with the mutation
# in place:
#
#   m5  In `emit_gather_column_projected`'s NULL-AWARE arm, disable
#       `elif elem_size == 2 or elem_size == 1:` so width 2 falls back.
#       -> RED, §B: `gather_narrow_fallback_colrows()` came back **97**
#          (the case's row count) against the asserted 0. ⭐ §A's and §B's
#          per-element VALUE assertions stayed GREEN -- the copy is also
#          correct, which is exactly why the counter is not optional.
#          3 passed, 1 failed.
#
#   m6  In that same arm, drop the `if idx2 != -1:` guard on the store.
#       -> RED by **SIGSEGV (exit 139)**, not by an assertion, and that is the
#          finding: at column offset 0 a `-1` index makes the typed store read
#          `src2[-1]`, i.e. BEFORE the buffer. The guard is not a nicety that
#          preserves the zero fill -- it is what keeps the narrow arms in
#          bounds, and it is the reason the null-aware arm keeps a per-row
#          branch the non-nullable arm does not need.
#
#   m7  In `_gather_batch`'s width-1 arm, change `DType.int8` to `DType.int16`.
#       -> RED, §A: **-78** against the oracle's **-89**.
#          ⭐ The mutation the COUNTER CANNOT CATCH: `gather_narrow_typed` is
#          unchanged and every counter assertion passed. Values and counters are
#          both load-bearing and neither subsumes the other.
#
# Cases
#   A  `gather_batch` over INT16 and INT8 columns -- values + counters.
#   B  `emit_gather_column_projected`, NULL-AWARE arm, `-1` sentinels honoured.
#   C  `emit_gather_column_projected`, NON-NULLABLE arm.
#   D  the anti-vacuity twin: a 16-byte column still takes the per-row copy.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_column_kernels.compiler_helpers import gather_batch
from komira_join_assembly.compiler_join_assembly import (
    emit_gather_column_projected,
)
from komira_counters.gather_width_counter import (
    gather_narrow_fallback_colrows,
    gather_narrow_typed_colrows,
    gather_wide_fallback_colrows,
    gather_width_has_typed_arm,
    reset_gather_width_counters,
)
from komira_buffer.heap_region import HeapRegion


comptime _N16: Int = 300
comptime _N8: Int = 200
"""⛔ 200, NOT 300, AND THE REASON IS THE ORACLE'S. An `int8` holds 256 distinct
values, so a 300-row fixture must repeat one, and a repeated value is a hole in
the permutation check: a kernel reading `idx[i] + 256` would return the right
byte. 200 rows of `-100 + i` are all distinct."""


def _val16(i: Int) -> Int16:
    """Distinct for every `i` under 1024; straddles zero so a sign-extension
    slip on the load shows up rather than cancelling."""
    return Int16(-30000 + (i * 37) % 60000)


def _val8(i: Int) -> Int8:
    return Int8(-100 + i % 200)


def _col16(n: Int) raises -> Column[HeapRegion]:
    var buf = OwnedAlignedBuffer(n * 2)
    buf.set_length(Int64(n * 2))
    for i in range(n):
        buf.set_typed[Scalar[DType.int16]](i, _val16(i))
    return Column[HeapRegion](
        arrow_type=ArrowType.INT16,
        data=buf^,
        offsets=Optional[OwnedAlignedBuffer](None),
        validity=Optional[Bitmap[HeapRegion]](None),
        length=n,
        null_count=0,
        offset=0,
    )


def _col8(n: Int) raises -> Column[HeapRegion]:
    var buf = OwnedAlignedBuffer(n)
    buf.set_length(Int64(n))
    for i in range(n):
        buf.set_typed[Scalar[DType.int8]](i, _val8(i))
    return Column[HeapRegion](
        arrow_type=ArrowType.INT8,
        data=buf^,
        offsets=Optional[OwnedAlignedBuffer](None),
        validity=Optional[Bitmap[HeapRegion]](None),
        length=n,
        null_count=0,
        offset=0,
    )


def _col_dec128(n: Int) raises -> Column[HeapRegion]:
    """A 16-byte-per-element column. §D's fixture: a width the typed arms do NOT
    serve, so the surviving per-row copy can be observed running."""
    var buf = OwnedAlignedBuffer(n * 16)
    buf.set_length(Int64(n * 16))
    for i in range(n * 2):
        buf.set_typed[Scalar[DType.int64]](i, Int64(i))
    return Column[HeapRegion](
        arrow_type=ArrowType.DECIMAL128,
        data=buf^,
        offsets=Optional[OwnedAlignedBuffer](None),
        validity=Optional[Bitmap[HeapRegion]](None),
        length=n,
        null_count=0,
        offset=0,
    )


def _scramble(j: Int, n: Int) -> Int:
    """⛔ NOT the identity: an identity index would let a kernel that dropped the
    index load entirely pass every value assertion in this file. 37 is coprime
    with both fixture sizes, so this is a permutation of `[0, n)`."""
    return (j * 37 + 11) % n


def _idx(count: Int, n: Int) -> List[Int]:
    var out = List[Int]()
    for j in range(count):
        out.append(_scramble(j, n))
    return out^


def _one_col_batch(var col: Column[HeapRegion], at: ArrowType) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("v"), at, False))
    var bb = RecordBatchBuilder()
    bb.add_column(col^)
    return bb.build(sb.build())


# =============================================================================
# A -- `gather_batch` (compiler_helpers._gather_batch) at widths 2 and 1
# =============================================================================


def test_a_gather_batch_narrow_widths() raises:
    var count = 137
    reset_gather_width_counters()

    var b16 = _one_col_batch(_col16(_N16), ArrowType.INT16)
    var i16 = _idx(count, _N16)
    var out16 = gather_batch(b16, i16)
    assert_equal(out16.num_rows(), count, "§A INT16 row count")
    ref c16 = out16.column_at(0)
    for i in range(count):
        assert_equal(
            Int(c16._data.get_typed[Scalar[DType.int16]](i)),
            Int(_val16(i16[i])),
            "§A INT16 element",
        )

    var b8 = _one_col_batch(_col8(_N8), ArrowType.INT8)
    var i8 = _idx(count, _N8)
    var out8 = gather_batch(b8, i8)
    assert_equal(out8.num_rows(), count, "§A INT8 row count")
    ref c8 = out8.column_at(0)
    for i in range(count):
        assert_equal(
            Int(c8._data.get_typed[Scalar[DType.int8]](i)),
            Int(_val8(i8[i])),
            "§A INT8 element",
        )

    # ⭐ THE INVARIANT: a width WITH a typed arm must not reach the per-row copy.
    assert_equal(
        gather_narrow_fallback_colrows(),
        0,
        "§A a narrow width fell into the per-row byte copy -- the regression"
        " this change exists to prevent, and no value assertion can see it",
    )
    assert_equal(
        gather_narrow_typed_colrows(),
        2 * count,
        "§A both gathers must be served by the typed narrow arms",
    )


# =============================================================================
# B -- `emit_gather_column_projected`, NULL-AWARE arm
# =============================================================================


def test_b_projected_gather_null_aware_narrow_widths() raises:
    var count = 97
    var idx = _idx(count, _N16)
    # ⭐ `-1` SENTINELS. The null-aware arm must LEAVE the pre-zeroed slot alone
    # for these, which is why the per-row `!= -1` branch survives in the narrow
    # arms. m6 in the header deletes that branch.
    idx[3] = -1
    idx[40] = -1
    idx[count - 1] = -1

    reset_gather_width_counters()
    var batch = _one_col_batch(_col16(_N16), ArrowType.INT16)
    var builder = RecordBatchBuilder()
    var sb = SchemaBuilder()
    emit_gather_column_projected(
        batch, 0, String("v"), True, idx, count, builder, sb
    )
    var out = builder.build(sb.build())
    ref col = out.column_at(0)
    assert_equal(out.num_rows(), count, "§B row count")

    # ⛔ ASSERTED FIRST. `_validity.value()` on an absent Optional is a trap, not
    # a failed assertion, so "the gather produced no bitmap at all" would abort
    # the case rather than red it with a readable message.
    assert_true(
        col._validity.__bool__(),
        "§B the null-aware arm must emit a validity bitmap",
    )
    var nulls = 0
    for i in range(count):
        if idx[i] == -1:
            nulls += 1
            assert_false(
                col._validity.value().test(i),
                "§B a -1 index must produce a NULL row",
            )
            assert_equal(
                Int(col._data.get_typed[Scalar[DType.int16]](i)),
                0,
                "§B a -1 slot must keep its zero fill",
            )
        else:
            assert_true(
                col._validity.value().test(i),
                "§B a real index must be valid",
            )
            assert_equal(
                Int(col._data.get_typed[Scalar[DType.int16]](i)),
                Int(_val16(idx[i])),
                "§B element",
            )
    assert_equal(nulls, 3, "§B fixture must actually contain -1 sentinels")

    assert_equal(
        gather_narrow_fallback_colrows(), 0, "§B narrow fallback must be 0"
    )
    assert_equal(
        gather_narrow_typed_colrows(),
        count,
        "§B the null-aware narrow arm must have served the whole column",
    )


# =============================================================================
# C -- `emit_gather_column_projected`, NON-NULLABLE arm, width 1
# =============================================================================


def test_c_projected_gather_non_nullable_width_1() raises:
    var count = 111
    var idx = _idx(count, _N8)
    reset_gather_width_counters()
    var batch = _one_col_batch(_col8(_N8), ArrowType.INT8)
    var builder = RecordBatchBuilder()
    var sb = SchemaBuilder()
    emit_gather_column_projected(
        batch, 0, String("v"), False, idx, count, builder, sb
    )
    var out = builder.build(sb.build())
    ref col = out.column_at(0)
    for i in range(count):
        assert_equal(
            Int(col._data.get_typed[Scalar[DType.int8]](i)),
            Int(_val8(idx[i])),
            "§C element",
        )
    assert_equal(
        gather_narrow_fallback_colrows(), 0, "§C narrow fallback must be 0"
    )
    assert_equal(
        gather_narrow_typed_colrows(), count, "§C the width-1 arm must fire"
    )


# =============================================================================
# D -- THE ANTI-VACUITY TWIN. §A/§B/§C's `== 0` is also satisfied by a DELETED
#      fallback. This drives a width the arms do not serve.
# =============================================================================


def test_d_wide_widths_still_take_the_per_row_copy() raises:
    var count = 61
    reset_gather_width_counters()
    var batch = _one_col_batch(_col_dec128(_N16), ArrowType.DECIMAL128)
    var idx = _idx(count, _N16)
    var out = gather_batch(batch, idx)
    assert_equal(out.num_rows(), count, "§D row count")

    assert_false(
        gather_width_has_typed_arm(16),
        "§D fixture assumption: width 16 must have NO typed arm, or this case"
        " measures the wrong thing",
    )
    assert_equal(
        gather_wide_fallback_colrows(),
        count,
        "§D the per-row byte copy must SURVIVE for the 16- and 32-byte types."
        " If this is 0 the fallback was deleted, and §A/§B/§C's"
        " `narrow_fallback == 0` proves nothing",
    )
    assert_equal(
        gather_narrow_fallback_colrows(),
        0,
        "§D a width-16 gather must not be classified as narrow",
    )
    assert_equal(
        gather_narrow_typed_colrows(),
        0,
        "§D a width-16 gather must not report a typed narrow arm",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_gather_batch_narrow_widths]()
    suite.test[test_b_projected_gather_null_aware_narrow_widths]()
    suite.test[test_c_projected_gather_non_nullable_width_1]()
    suite.test[test_d_wide_widths_still_take_the_per_row_copy]()
    suite^.run()
