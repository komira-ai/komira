# =============================================================================
# G4 SITE SEVEN — THE ONE THAT NEVER RAISED. `morsel._slice_column` SILENTLY
# RETURNS THE WRONG ROWS FOR A BIT-PACKED BOOL COLUMN.
# =============================================================================
#
# ⚠ THIS SITE IS INVISIBLE TO A `git grep 'element_size('`, WHICH IS WHY TWO
# WAVES OF THIS CAMPAIGN MISSED IT. `komira_morsel/morsel._slice_column` does
# NOT call the canonical width oracle at all — it carries its OWN hand-written
# width ladder (INT8/UINT8 -> 1, INT16/UINT16/FLOAT16 -> 2, ...) with STRING /
# BINARY / DICTIONARY arms, and an `else` that reads:
#
#     check_fixed_width_dispatch("morsel._slice_column", arrow_type, length)
#     return _slice_fixed_width(col, start, length, 8, arrow_type)
#
# `check_fixed_width_dispatch` refuses `carries_offsets(at) or
# carries_children(at)`. **BOOL IS NEITHER.** So a bool column walks straight
# through the guard into a hardcoded 8-BYTES-PER-ROW slab copy of a buffer
# holding `(n + 7) >> 3` bytes.
#
# ⇒ EVERY OTHER SITE IN THIS CLASS IS IN THE *RAISE* REGIME TODAY (since
# `` made `arrow_fixed_byte_width` refuse). THIS ONE IS STILL IN THE
# *OVER-READ* REGIME — the pre-`` behaviour, preserved intact because
# it never routed through the oracle. It does not fail loudly. It returns
# WRONG DATA.
#
# THE FALSIFIER BELOW IS THE `start > 0` MORSEL. At `start == 0` the copy is a
# 64x over-read whose FIRST `(n+7)>>3` bytes happen to be the correct bitmap,
# so the values come back right and the bug hides — that is exactly why
# `test_g4_bool_carried_gather_and_filter`'s single-morsel splits pass. At
# `start == 16` the copy reads from BYTE `16 * 8 = 128` of a 5-byte bitmap:
# rows 128..  of a 40-row column. The bug is a silent wrong answer for every
# multi-morsel scan of a table carrying a bool column.
#
# ⚠ REACHABILITY IS NOT HYPOTHETICAL. `split_record_batch` takes the zero-copy
# `Column.slice` path only when `supports_zero_copy_slice() and not _validity`,
# and BOOL is deliberately NOT on that whitelist (it is bit-packed — the
# whitelist's own comment says so). So EVERY bool column in a multi-morsel
# split lands in `_slice_column`, non-nullable ones included.
#
# The comment at the `else` arm has said *"Still wrong for BOOL; callers that
# need intra-RG splitting on BOOL must extend this dispatch. BOOL is not
# exercised by current benchmarks"* since the arm was written. A known defect
# guarded by a comment is guarded by nothing; this file is the guard.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_morsel.morsel import split_record_batch


def _expected_flag(i: Int) -> Bool:
    """Period 3 — differs in every byte, so no byte-granular copy agrees."""
    return i % 3 == 0


def _make_id_flag_batch(n: Int) raises -> RecordBatch:
    var ids = List[Scalar[DType.int64]]()
    for i in range(n):
        ids.append(Scalar[DType.int64](i))
    var id_arr = PrimitiveArray[DType.int64].from_list(ids^)

    var flags = BooleanArray.allocate(n)
    for i in range(n):
        flags.set(i, _expected_flag(i))

    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("flag", ArrowType.BOOL, False))

    var builder = RecordBatchBuilder()
    builder.add_column(Column.from_primitive[DType.int64](id_arr^))
    builder.add_column(Column.from_boolean(flags))
    var schema = sb.build()
    return builder.build(schema^)


def test_multi_morsel_split_carries_a_bool_column() raises:
    """40 rows split into 3 morsels of 16 — morsels 1 and 2 start past row 0.

    The INT64 column is checked alongside deliberately: it takes the SAME
    `_slice_column` dispatcher through a correct 8-byte arm, so if it is right
    and the bool is wrong, the defect is the width, not the split.
    """
    comptime N = 40
    comptime M = 16
    var batch = _make_id_flag_batch(N)
    var morsels = split_record_batch(batch^, M)
    assert_equal(len(morsels), 3)

    for m in range(3):
        var start = m * M
        var rows = min(M, N - start)
        ref mor = morsels[m]
        assert_equal(mor.num_rows(), rows)

        var ids = mor.batch.column_at(0).as_primitive[DType.int64]()
        var flags = mor.batch.column_at(1).as_boolean()
        for r in range(rows):
            var src = start + r
            assert_equal(Int(ids.get(r)), src)
            assert_equal(
                flags.get(r),
                _expected_flag(src),
                "morsel "
                + String(m)
                + " row "
                + String(r)
                + ": a bit-packed BOOL column was sliced at 8 BYTES per row"
                " (source row "
                + String(src)
                + ")",
            )


def test_single_morsel_split_bool_is_the_shape_that_HID_this() raises:
    """`start == 0` — the shape that passes even with the defect present.

    Landed deliberately next to the falsifier: it is the reason two waves of
    this campaign read the multi-morsel path as covered. At offset 0 the 64x
    over-read's first `(n+7)>>3` bytes ARE the bitmap, so the values are right
    and only the read length is wrong.
    """
    comptime N = 24
    var batch = _make_id_flag_batch(N)
    var morsels = split_record_batch(batch^, N)
    assert_equal(len(morsels), 1)

    ref mor = morsels[0]
    var flags = mor.batch.column_at(1).as_boolean()
    for r in range(N):
        assert_equal(flags.get(r), _expected_flag(r))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
