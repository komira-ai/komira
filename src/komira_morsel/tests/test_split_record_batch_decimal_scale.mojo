# =============================================================================
# `split_record_batch` MUST NOT DROP A DECIMAL'S SCALE — unit falsifier
# =============================================================================
#
# ★ WHAT THIS IS THE FALSIFIER FOR, and why it is a SEPARATE test from the
# element x type sweep that found the defect.
#
# an internal Bazel target caught a `decimal128(12, 2)` column coming
# back from a FILTERED parquet scan as `decimal128(38, 0)` — the unscaled
# int128 intact and the SCALE gone, so `Decimal('40.00')` reached the caller as
# `Decimal('4000')`. The site was ten emit points in
# `ColumnarMultiConsumerSource.next_morsel` that rebuilt the output Schema from
# a source Field's NAME, ARROW TYPE and NULLABLE — three of `Field`'s slots.
#
# `split_record_batch` is ONE STEP DOWNSTREAM OF THOSE TEN, in the same call
# chain: `_split_and_stash_first` calls it whenever a decoded row group exceeds
# `morsel_rows`. It carried the identical defect in `_clone_schema_builder`,
# and the sweep CANNOT see it — the sweep's fixtures are SIX ROWS and
# `DEFAULT_MORSEL_ROWS` is three orders of magnitude larger, so the split
# branch is never taken there. Fixing the ten and stopping would have produced
# an engine that returns the right decimal for small scans and the wrong one
# for large ones, with a green gate either way.
#
# So the assertion is made where the split is, on a batch built in this file:
# split a `decimal128(12, 2)` column and require every sub-batch's field to
# still say (12, 2).
#
# ⚠ THE ASSERTION IS ON THE PARAMETERS, NOT ON `arrow_type`. `decimal128(12,2)`
# and `decimal128(38,0)` have the SAME `ArrowType.DECIMAL128`, which is exactly
# why every schema check in the pipeline agreed with the defect. A test that
# compared type ids would pass against the bug.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.decimal_array import Decimal128Array
from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_core.arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_core.io.heap_region import HeapRegion
from komira_morsel.morsel import MorselArray, split_record_batch


comptime _PRECISION: Int = 12
comptime _SCALE: Int = 2
comptime _N_ROWS: Int = 7
comptime _MORSEL_ROWS: Int = 3


def _unscaled() -> List[SIMD[DType.int128, 1]]:
    """Seven values at scale 2: 10.25, 20.50, ... — the sweep's own literals.

    Stored unscaled, so 10.25 is 1025. If the scale is dropped the BYTES are
    unchanged and the meaning becomes 1025, which is the whole reason this
    defect is silent.
    """
    var out = List[SIMD[DType.int128, 1]]()
    out.append(SIMD[DType.int128, 1](1025))
    out.append(SIMD[DType.int128, 1](2050))
    out.append(SIMD[DType.int128, 1](3075))
    out.append(SIMD[DType.int128, 1](4000))
    out.append(SIMD[DType.int128, 1](5012))
    out.append(SIMD[DType.int128, 1](6099))
    out.append(SIMD[DType.int128, 1](7100))
    return out^


def _make_int64_column(n: Int) raises -> Column[HeapRegion]:
    comptime elem_size = 8
    var buf = OwnedAlignedBuffer(n * elem_size)
    var ptr = buf.view_typed_ro[DType.int64]()
    for i in range(n):
        ptr[i] = Int64(i)
    buf.set_length(Int64(n * elem_size))
    return Column[HeapRegion](
        arrow_type=ArrowType.INT64,
        data=buf^,
        offsets=None,
        validity=None,
        length=n,
        null_count=0,
        offset=0,
    )


def _make_batch() raises -> RecordBatch:
    """`k: int64, v: decimal128(12, 2)` over seven rows.

    Two columns, not one: the defect's live shape is a scan carrying a column
    the predicate does not name, and a single-column batch would not exercise
    the per-column loop that rebuilt each field.
    """
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(
        Field.decimal128(String("v"), _PRECISION, _SCALE, nullable=False)
    )
    var schema = sb.build()

    var builder = RecordBatchBuilder()
    builder.add_column(_make_int64_column(_N_ROWS))
    var d = Decimal128Array.from_i128_list(_unscaled(), _PRECISION, _SCALE)
    builder.add_column(Column.from_decimal128(d^))
    return builder.build(schema^)


def test_split_preserves_decimal_precision_and_scale() raises:
    """Every sub-batch of a split still says `decimal128(12, 2)`."""
    var batch = _make_batch()

    # PREMISE. If the batch this test built does not itself carry (12, 2),
    # every assertion below is vacuous — the same reason the sweep checks its
    # fixtures against pyarrow before comparing anything to the engine.
    assert_equal(batch.schema.field_decimal_precision(1), _PRECISION)
    assert_equal(batch.schema.field_decimal_scale(1), _SCALE)
    assert_equal(batch.num_rows(), _N_ROWS)

    var morsels = split_record_batch(batch^, _MORSEL_ROWS)
    var n = len(morsels)
    # 7 rows at 3 per morsel = 3 sub-batches, and the split must actually have
    # happened: a helper that returned the batch whole would satisfy every
    # parameter assertion below while testing nothing.
    assert_equal(n, 3)

    var rows_seen = 0
    for m in range(n):
        ref sub = morsels[m].batch
        rows_seen += sub.num_rows()
        assert_equal(sub.num_columns(), 2)
        assert_equal(sub.schema.field_name(1), String("v"))
        assert_true(sub.schema.field_arrow_type(1) == ArrowType.DECIMAL128)
        # ★ THE TWO SLOTS THE DEFECT ERASED.
        assert_equal(sub.schema.field_decimal_precision(1), _PRECISION)
        assert_equal(sub.schema.field_decimal_scale(1), _SCALE)
    assert_equal(rows_seen, _N_ROWS)


# =============================================================================
# ⛔ THE ARM ABOVE IS NON-NULLABLE, AND THAT IS THE HOLE IT LEFT.
#    ()
# =============================================================================
#
# `split_record_batch` takes the ZERO-COPY `Column.slice` path for a column
# that `supports_zero_copy_slice() and not _validity`, and DECIMAL128 is on
# that whitelist. So `_make_batch`'s non-nullable column never reaches
# `_slice_column` at all — every assertion above is made about the Arc reslice,
# and the COPY slice beside it was asserted by nothing.
#
# That copy arm ended in `_slice_fixed_width(col, start, length, 8, at)` — a
# CONSTANT 8 where the type's width is 16 — so the sub-batch's data buffer was
# `length * 8` bytes under a Column claiming `length` DECIMAL128 rows. Every
# read of a row past the halfway point runs PAST THE ALLOCATION.
#
# ⚠ THE PARAMETERS WERE RIGHT THE WHOLE TIME. `_clone_schema_builder` carries
# (p, s) faithfully, so the arm above stays GREEN against this defect: the
# sub-batch says `decimal128(12, 2)` and its VALUES are garbage. That is why
# this arm asserts the unscaled int128s and the null positions, and not the
# schema.
#
# MEASURED end-to-end before the fix, `an internal Bazel target
# _and_anti_values`: an ANTI join over this exact fixture shape returned
# `[30.75, 0.00, NULL, <uninitialised>]` for `[30.75, 40.00, NULL, 60.99]`,
# and the fourth value DIFFERED BETWEEN PROCESSES.


def _make_nullable_decimal_batch() raises -> RecordBatch:
    """`k: int64, v: decimal128(12, 2) NULLABLE` over seven rows.

    NULLABLE is the whole point: it is what diverts `v` off the zero-copy
    reslice and onto `_slice_column`'s width ladder. Nulls at rows 1 and 4 —
    a null at BOTH ends of the interesting range, so a morsel boundary cannot
    make the null pattern trivially right.
    """
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(
        Field.decimal128(String("v"), _PRECISION, _SCALE, nullable=True)
    )
    var schema = sb.build()

    var vals = _unscaled()
    var d = Decimal128Array.allocate_nullable(_N_ROWS, _PRECISION, _SCALE)
    for i in range(_N_ROWS):
        d.set_i128(i, vals[i])
    d.set_null(1)
    d.set_null(4)

    var builder = RecordBatchBuilder()
    builder.add_column(_make_int64_column(_N_ROWS))
    builder.add_column(Column.from_decimal128(d^))
    return builder.build(schema^)


def _assert_nullable_split_values(morsel_rows: Int) raises:
    """Split at `morsel_rows` and require EVERY VALUE to survive."""
    var vals = _unscaled()
    var batch = _make_nullable_decimal_batch()

    # PREMISE 1 — the fixture really is nullable, so the copy arm really is
    # the one under test. A non-nullable column here would re-test the Arc
    # reslice the arm above already covers and report it as new coverage.
    assert_true(
        batch.column_at(1).has_validity_buffer(),
        "fixture premise: `v` must carry a validity bitmap",
    )
    assert_equal(batch.schema.field_decimal_precision(1), _PRECISION)
    assert_equal(batch.schema.field_decimal_scale(1), _SCALE)

    var morsels = split_record_batch(batch^, morsel_rows)
    var n = len(morsels)
    var row = 0
    for m in range(n):
        ref sub = morsels[m].batch
        # The COLUMN's own (p, s), not the schema's — `Column.as_decimal128`
        # reads this one and REFUSES a column carrying zeros.
        var dcol = sub.column_at(1).as_decimal128()
        assert_equal(dcol.scale, _SCALE, "sub-batch column keeps scale")
        assert_equal(
            dcol.precision, _PRECISION, "sub-batch column keeps precision"
        )
        for i in range(sub.num_rows()):
            if row == 1 or row == 4:
                assert_true(
                    dcol.is_null(i), "row " + String(row) + " must be NULL"
                )
            else:
                assert_true(
                    not dcol.is_null(i),
                    "row " + String(row) + " must NOT be NULL",
                )
                assert_true(
                    dcol.get_i128(i) == vals[row],
                    "row "
                    + String(row)
                    + " unscaled value survives the split: want "
                    + String(Int(vals[row]))
                    + " got "
                    + String(Int(dcol.get_low(i))),
                )
            row += 1
    assert_equal(row, _N_ROWS, "every source row appears in exactly one morsel")


def test_split_nullable_decimal_preserves_values_multi_morsel() raises:
    """7 rows at 3/morsel — three sub-batches, none of them truncated."""
    _assert_nullable_split_values(_MORSEL_ROWS)


def test_split_nullable_decimal_preserves_values_single_morsel() raises:
    """⚠ ONE MORSEL IS NOT THE TRIVIAL CASE HERE.

    A single morsel still takes the COPY arm (the divert is on `_validity`,
    not on the morsel count), and the truncation is a function of the ROW
    COUNT, not of the split — so `DEFAULT_MORSEL_ROWS` over a six-row fixture,
    which is exactly what the cross-surface corpus writes, reds too. Without
    this arm a reader could believe the defect needed a multi-morsel split.
    """
    _assert_nullable_split_values(_N_ROWS * 4)


# =============================================================================
# ⛔ A VALUE ASSERTION CANNOT PROVE AN OUT-OF-BOUNDS READ IS GONE.
#    THIS ARM ASSERTS THE ALLOCATION ITSELF.
#    ()
# =============================================================================
#
# The two arms above compare the values that come back. That is the right
# assertion for a TRUNCATION, and it is NOT sufficient for the defect this
# actually was: `_slice_fixed_width(col, start, length, 8, at)` sized the
# sub-batch's data buffer at `length * 8` bytes for a type whose every read is
# 16 bytes wide, so rows past the halfway point were read PAST THE END OF THE
# ALLOCATION. What an over-read returns is a fact about whatever the allocator
# happened to place next, not about the bug — the fourth ANTI value was
# observed as three different numbers in three processes — so a value
# comparison can go GREEN over a read that is still out of bounds and merely
# landed somewhere harmless that day.
#
# This arm makes the statement that does not depend on the day: a Column
# TAGGED `DECIMAL128` and claiming `n` rows must own at least `n * 16` bytes
# of data buffer. It fails deterministically at `n * 8` regardless of what
# follows the allocation, and it fails in the SAME DIRECTION for every other
# width the constant got wrong.
#
# ⚠ THE 16 IS WRITTEN OUT, NOT ASKED OF `arrow_fixed_byte_width`. The fix
# under test IS "ask the table", so an oracle that also asks the table would
# agree with a table that is wrong. The independent statement is the literal.


comptime _DECIMAL128_BYTES: Int = 16


def _assert_nullable_split_allocation(morsel_rows: Int) raises:
    """Split at `morsel_rows`; require `n * 16` bytes of data buffer."""
    var batch = _make_nullable_decimal_batch()
    assert_true(
        batch.column_at(1).has_validity_buffer(),
        "fixture premise: `v` must carry a validity bitmap",
    )

    var morsels = split_record_batch(batch^, morsel_rows)
    var n = len(morsels)
    var rows_seen = 0
    for m in range(n):
        ref sub = morsels[m].batch
        var rows = sub.num_rows()
        var have = sub.column_at(1)._data.len()
        var need = rows * _DECIMAL128_BYTES
        assert_true(
            have >= need,
            "sub-batch "
            + String(m)
            + " claims "
            + String(rows)
            + " DECIMAL128 rows but owns only "
            + String(have)
            + " bytes of data buffer; a 16-byte-wide read of its last row"
            + " runs past the end. Need at least "
            + String(need),
        )
        rows_seen += rows
    assert_equal(rows_seen, _N_ROWS, "every source row appears in one morsel")


def test_split_nullable_decimal_allocation_covers_every_row_multi_morsel() raises:
    """7 rows at 3/morsel — every sub-batch owns 16 bytes per row it claims."""
    _assert_nullable_split_allocation(_MORSEL_ROWS)


def test_split_nullable_decimal_allocation_covers_every_row_single_morsel() raises:
    """One morsel still takes the copy arm, so it is still under-allocated."""
    _assert_nullable_split_allocation(_N_ROWS * 4)


def main() raises:
    var suite = TestSuite()
    suite.test[test_split_preserves_decimal_precision_and_scale]()
    suite.test[test_split_nullable_decimal_preserves_values_multi_morsel]()
    suite.test[test_split_nullable_decimal_preserves_values_single_morsel]()
    suite.test[
        test_split_nullable_decimal_allocation_covers_every_row_multi_morsel
    ]()
    suite.test[
        test_split_nullable_decimal_allocation_covers_every_row_single_morsel
    ]()
    suite^.run()
