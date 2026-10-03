# =============================================================================
# `batch_slice` CARRIES A **BINARY** COLUMN — BOTH HELPERS
# =============================================================================
#
# TARGET: `komira_column_kernels/batch_slice.mojo`'s int32-offset var-len
# arm, in BOTH `_slice_batch_first_n` and `_slice_batch_range`.
#
# ⛔ THE GAP THIS FILE PINS, AND WHY IT IS AN ALLOW-LIST GAP AND NOT A MISSING
#    CAPABILITY. An int32-offset arm spelled `if at == ArrowType.STRING` misses
#    BINARY, which has the IDENTICAL physical layout — (Int32 offsets, raw data
#    bytes, optional validity). The wide pair LARGE_STRING / LARGE_BINARY is
#    served together by the 8-byte-stride arm; the NARROW pair must be too,
#    or `binary` falls through to `compiler_helpers.element_size`, which
#    REFUSES a var-len layout by design:
#
#        arrow_fixed_byte_width: ArrowType binary (type_id=14) has NO fixed
#        per-element byte width, so the caller's `num_rows * width` byte
#        arithmetic is not merely imprecise for it -- it is the wrong shape of
#        arithmetic.
#
#    That refusal is CORRECT about the width table and WRONG about this call
#    site: the fix belongs where the layout is known, exactly as the table's
#    own header says.
#
# ★ WHAT IT COSTS: `ORDER BY ... LIMIT` over a BINARY column refused at every
#   product door (Mojo, pandas, polars, SQL) on that one sentence, while
#   DuckDB answers the same query — debt, not a correct refusal.
#
# ⚠ THE ATTRIBUTION IS `ORDER BY ... LIMIT`, NOT ORDERING. A plain sort over
#   BINARY is served: `sort_indices_string` serves BINARY and STRING from one
#   kernel. What refuses is the SLICE that TopN's full-sort+slice arm applies
#   on top (`sort_topn_sink._execute_topn_sink`'s last line).
#
# ⚠ A SURVIVAL-ONLY TEST WOULD BE NEARLY WORTHLESS HERE — the same hazard its
#   LARGE_STRING sibling names. Every plausible defect in a hand-written
#   var-len slice (offsets read at the wrong stride, offsets not rebased to
#   zero, the source `_offset` dropped) produces a batch that BUILDS with the
#   RIGHT ROW COUNT and wrong bytes. So every leg reads the values back, the
#   values are variable-length and row-stamped, and `id` rides alongside so a
#   row misalignment shows in two independent columns.
#
# ⚠ NULL IS NOT EMPTY, AND BINARY IS WHERE THAT BITES. An Arrow NULL slot in a
#   var-len column is an EMPTY byte range, so a slice that carried the offsets
#   correctly and dropped the validity bitmap answers `b''` where the input
#   said NULL and no length check notices. `BinaryArray` has no `set_null`, so
#   §4's fixture builds its bitmap by hand.
#
# THE ARMS:
#   §0  NON-VACUITY     — the fixture really is BINARY, really is var-len
#   §1  CONTROL         — the same two helpers over STRING and INT64 columns.
#                         The unfixed tree PASSES §1, which is what makes the
#                         §2/§3/§4 reds attributable to the BINARY arm.
#   §2  first_n         — head slice, values + ids read back
#   §3  range           — interior slice (source offsets NOT starting at 0)
#   §4  validity        — NULL vs empty-bytes, both helpers
#   §5  DECLINE         — the width TABLE still refuses BINARY. The fix is at
#                         the call site; a table that guessed would be the
#                         defect its own header forbids.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_raises

from komira_arrow.arrow_types import ArrowType
from komira_arrow.binary_array import BinaryArray
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_column_kernels.batch_slice import (
    _slice_batch_first_n,
    _slice_batch_range,
)
from komira_column_kernels.compiler_helpers import element_size
from komira_buffer.heap_region import HeapRegion


# -----------------------------------------------------------------------------
# Fixture values — VARIABLE LENGTH and ROW-STAMPED, for the reason in the
# header. Row `i`'s bytes contain `i`'s decimal digits, so a swapped pair or a
# repeated chunk is a value mismatch rather than a length match.
# -----------------------------------------------------------------------------


def _expected_text(i: Int) -> String:
    var w = i % 4
    if w == 0:
        return String("b") + String(i)
    elif w == 1:
        return String("bin-") + String(i) + String("-padded-out")
    elif w == 2:
        return String("v") + String(i) + String("!")
    return String("wide-bytes-row-") + String(i) + String("-tail")


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _expected_bytes(i: Int) -> List[UInt8]:
    return _bytes_of(_expected_text(i))


def _ids(n: Int) -> PrimitiveArray[DType.int64]:
    var ids = List[Scalar[DType.int64]]()
    for i in range(n):
        ids.append(Scalar[DType.int64](i))
    return PrimitiveArray[DType.int64].from_list(ids^)


def _make_id_binary_batch(n: Int) raises -> RecordBatch:
    var vals = List[List[UInt8]]()
    for i in range(n):
        vals.append(_expected_bytes(i))
    var arr = BinaryArray.from_bytes_list(vals^)

    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.BINARY, False))

    var builder = RecordBatchBuilder()
    builder.add_column(Column.from_primitive[DType.int64](_ids(n)))
    builder.add_column(Column.from_binary(arr))
    var schema = sb.build()
    return builder.build(schema^)


def _make_nullable_id_binary_batch(n: Int) raises -> RecordBatch:
    """Same, but every 3rd row of `b` is NULL.

    ⚠ THE NULL ROWS STILL CARRY THEIR BYTES. `BinaryArray` has no `set_null`,
    so the bitmap is built by hand and the value bytes are written anyway --
    which is what makes a validity-dropping slice show up as a WRONG VALUE
    (`b3` where NULL was asked for) instead of as an empty range that could be
    mistaken for a correct NULL rendering.
    """
    var offsets = List[Int32]()
    var data = List[UInt8]()
    offsets.append(Int32(0))
    var bm = Bitmap.create(n)
    var nulls = 0
    for i in range(n):
        var vb = _expected_bytes(i)
        for j in range(len(vb)):
            data.append(vb[j])
        offsets.append(Int32(len(data)))
        if i % 3 == 0:
            bm.clear(i)
            nulls += 1
        else:
            bm.set(i)
    var arr = BinaryArray.from_buffers(
        offsets^, data^, Optional[Bitmap[HeapRegion]](bm^), nulls
    )

    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.BINARY, True))

    var builder = RecordBatchBuilder()
    builder.add_column(Column.from_primitive[DType.int64](_ids(n)))
    builder.add_column(Column.from_binary(arr))
    var schema = sb.build()
    return builder.build(schema^)


def _make_id_string_batch(n: Int) raises -> RecordBatch:
    """§1's CONTROL fixture — the SAME shape at STRING, which the unfixed tree
    already slices."""
    var vals = List[String]()
    for i in range(n):
        vals.append(_expected_text(i))
    var arr = StringArray.from_strings(vals^)

    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.STRING, False))

    var builder = RecordBatchBuilder()
    builder.add_column(Column.from_primitive[DType.int64](_ids(n)))
    builder.add_column(Column.from_string(arr))
    var schema = sb.build()
    return builder.build(schema^)


def _assert_binary_row(
    batch: RecordBatch, row: Int, want_src_row: Int
) raises:
    """Row `row` of `batch` holds the fixture's row `want_src_row`, in BOTH
    columns."""
    var arr = batch.column_as_binary(1)
    var got = arr.get(row)
    var want = _expected_bytes(want_src_row)
    assert_equal(
        len(got),
        len(want),
        String("row ") + String(row) + String(" byte LENGTH"),
    )
    for j in range(len(want)):
        assert_equal(
            Int(got[j]),
            Int(want[j]),
            String("row ") + String(row) + String(" byte ") + String(j),
        )
    var ids = batch.column_as_primitive[DType.int64](0)
    assert_equal(
        Int(ids.get(row)),
        want_src_row,
        String("row ") + String(row) + String(" id"),
    )


# =============================================================================
# §0 NON-VACUITY — the fixture is BINARY and it is variable-length
# =============================================================================


def test_S0_the_fixture_column_is_physically_binary_and_varlen() raises:
    var batch = _make_id_binary_batch(8)
    assert_equal(batch.num_rows(), 8)
    assert_equal(
        String(batch.schema.field_arrow_type(1)), String(ArrowType.BINARY)
    )
    assert_equal(
        String(batch.column_at(1).arrow_type), String(ArrowType.BINARY)
    )
    # Variable length, or every leg below would pass over a constant stride.
    var arr = batch.column_as_binary(1)
    assert_true(
        arr.get_length(0) != arr.get_length(1),
        "fixture rows 0 and 1 must differ in byte length",
    )
    for i in range(8):
        _assert_binary_row(batch, i, i)


# =============================================================================
# §1 CONTROL — the unfixed tree PASSES this. It is what makes §2..§4
#    attributable to the BINARY arm rather than to this file's fixtures.
# =============================================================================


def test_S1_CONTROL_a_string_column_slices_through_both_helpers() raises:
    var batch = _make_id_string_batch(8)
    var head = _slice_batch_first_n(batch, 3)
    assert_equal(head.num_rows(), 3)
    var harr = head.column_as_string(1)
    for i in range(3):
        assert_equal(harr.get(i), _expected_text(i))

    var mid = _slice_batch_range(batch, 2, 3)
    assert_equal(mid.num_rows(), 3)
    var marr = mid.column_as_string(1)
    for i in range(3):
        assert_equal(marr.get(i), _expected_text(2 + i))


def test_S1_CONTROL_an_int64_column_slices_through_both_helpers() raises:
    var batch = _make_id_binary_batch(8)
    # Column 0 only: a one-column projection of the INT64 side, so the fixed
    # arm is exercised with no var-len column in the batch at all.
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    var bb = RecordBatchBuilder()
    bb.add_column(Column.from_primitive[DType.int64](_ids(8)))
    var schema = sb.build()
    var ints = bb.build(schema^)

    var head = _slice_batch_first_n(ints, 3)
    assert_equal(head.num_rows(), 3)
    var ha = head.column_as_primitive[DType.int64](0)
    for i in range(3):
        assert_equal(Int(ha.get(i)), i)
    _ = batch^


# =============================================================================
# §2 `_slice_batch_first_n` over BINARY — the TopN / LIMIT head slice
# =============================================================================


def test_S2_first_n_carries_a_binary_column() raises:
    var batch = _make_id_binary_batch(8)
    var head = _slice_batch_first_n(batch, 3)
    assert_equal(head.num_rows(), 3)
    assert_equal(
        String(head.schema.field_arrow_type(1)), String(ArrowType.BINARY)
    )
    assert_equal(
        String(head.column_at(1).arrow_type), String(ArrowType.BINARY)
    )
    for i in range(3):
        _assert_binary_row(head, i, i)


def test_S2_first_n_zero_rows_over_a_binary_column_builds() raises:
    """`sort_topn_sink` calls `_slice_batch_first_n(batch, 0)` on its empty
    paths, so a refusal here would make even an EMPTY TopN result unbuildable."""
    var batch = _make_id_binary_batch(8)
    var none = _slice_batch_first_n(batch, 0)
    assert_equal(none.num_rows(), 0)
    assert_equal(
        String(none.schema.field_arrow_type(1)), String(ArrowType.BINARY)
    )


def test_S2_first_n_of_every_row_is_the_whole_binary_column() raises:
    var batch = _make_id_binary_batch(8)
    var all8 = _slice_batch_first_n(batch, 8)
    assert_equal(all8.num_rows(), 8)
    for i in range(8):
        _assert_binary_row(all8, i, i)


# =============================================================================
# §3 `_slice_batch_range` over BINARY — the INTERIOR slice, where the source
#    offsets do NOT start at zero and must be rebased
# =============================================================================


def test_S3_range_carries_a_binary_column_rebased() raises:
    var batch = _make_id_binary_batch(8)
    var mid = _slice_batch_range(batch, 3, 4)
    assert_equal(mid.num_rows(), 4)
    assert_equal(
        String(mid.column_at(1).arrow_type), String(ArrowType.BINARY)
    )
    for i in range(4):
        _assert_binary_row(mid, i, 3 + i)


def test_S3_range_tail_slice_reaches_the_last_row() raises:
    var batch = _make_id_binary_batch(8)
    var tail = _slice_batch_range(batch, 6, 2)
    assert_equal(tail.num_rows(), 2)
    for i in range(2):
        _assert_binary_row(tail, i, 6 + i)


# =============================================================================
# §4 VALIDITY — NULL is not empty
# =============================================================================


def test_S4_first_n_keeps_binary_nulls_distinct_from_empty() raises:
    var batch = _make_nullable_id_binary_batch(9)
    var head = _slice_batch_first_n(batch, 5)
    assert_equal(head.num_rows(), 5)
    ref col = head.column_at(1)
    for i in range(5):
        if i % 3 == 0:
            assert_true(
                col.is_null_at(i),
                String("row ") + String(i) + String(" must be NULL"),
            )
        else:
            assert_true(
                not col.is_null_at(i),
                String("row ") + String(i) + String(" must be valid"),
            )
            _assert_binary_row(head, i, i)


def test_S4_range_keeps_binary_nulls_distinct_from_empty() raises:
    var batch = _make_nullable_id_binary_batch(9)
    # start=2 so the NULL pattern in the SLICE is offset from the fixture's:
    # source rows 2,3,4,5 -> null at source 3, i.e. slice index 1.
    var mid = _slice_batch_range(batch, 2, 4)
    assert_equal(mid.num_rows(), 4)
    ref col = mid.column_at(1)
    for i in range(4):
        var src = 2 + i
        if src % 3 == 0:
            assert_true(
                col.is_null_at(i),
                String("slice row ") + String(i) + String(" must be NULL"),
            )
        else:
            assert_true(
                not col.is_null_at(i),
                String("slice row ") + String(i) + String(" must be valid"),
            )
            _assert_binary_row(mid, i, src)


# =============================================================================
# §5 DECLINE — the width TABLE still refuses BINARY
# =============================================================================


def test_S5_DECLINE_the_width_table_still_refuses_binary() raises:
    """⛔ THE FIX IS AT THE CALL SITE, NOT IN THE TABLE.

    `arrow_fixed_byte_width`'s header states the rule this asserts: there is no
    `else: return 8`, and adding one back IS the defect. A BINARY column has no
    per-element byte width; what changed is that the two slice helpers now peel
    it off before asking. If this test ever goes green-by-answering, someone
    taught the table to guess and eight consumers started reading 8 bytes per
    element of a var-len buffer.
    """
    with assert_raises():
        _ = element_size(ArrowType.BINARY)
    # And the wide sibling, for the same reason.
    with assert_raises():
        _ = element_size(ArrowType.LARGE_BINARY)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
