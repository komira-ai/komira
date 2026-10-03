# =============================================================================
# ⛔⛔ THE ROW-FORMAT SORT BUFFER MUST NOT ERASE A NULL INTO ITS PAYLOAD VALUE.
# =============================================================================
#
# `RowSortBuffer` stores ONE 8-byte I64 cell per key and payload column and NO
# validity: `feed_batch` copies the data buffer (`write_i64_batch`),
# `_populate_arrow_row_lists` encodes every key as NON-NULL, and
# `emit_to_record_batch` builds every output column with no validity bitmap. So
# a NULL in a key or payload column that reached it would not be mis-placed, it
# would be ERASED — emitted as whatever payload sat in its slot, ordered as that
# value. A DType check alone does not prevent that; the buffer must refuse.
#
# THE CONTRACT THIS FILE HOLDS THE BUFFER TO — deliberately NOT "it raises":
#   a NULL-bearing batch is EITHER refused by name, OR sorted with the NULL
#   KEPT (validity on the emitted column, the row placed by the engine's derived
#   policy). The buffer today takes the refusal branch; a row format that carries
#   validity would satisfy the second branch without editing this file. What
#   neither branch admits is erasure: the NULL coming back as a number.
#
# ⚠ THE NULL SLOT'S PAYLOAD IS THE TYPE MAXIMUM (key) / a sentinel (payload),
#   never zero: a parquet decode writes 0 under a NULL, and over non-negative
#   data a zero lands where an ascending NULLS-FIRST order would put the NULL
#   anyway — the payload coincidence that hid this class for months.
#
# §1 CONTROLS (green before AND after): a column that CARRIES a validity bitmap
#    but holds ZERO NULLs is served — the refusal is about the DATA, not the
#    declared nullability, or it would refuse every pyarrow-written parquet
#    column (they are all OPTIONAL). And the plain non-nullable case.
# §2 THE DEFECT (red before): a NULL in the key; a NULL in a payload.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_core.arrow.schema import Field, SchemaBuilder
from komira_core.collections.batch_view import BatchView
from komira_core.io.heap_region import HeapRegion

from komira_row_format.row_sort import RowSortBuffer, SORT_ASC
from komira_row_format.row_block import (
    RowLayout,
    ColDescriptor,
    COL_FIXED,
    DT_I64,
)


comptime _N = 5
comptime _NULL_ROW = 1


def _desc(off: Int) -> ColDescriptor:
    return ColDescriptor(
        kind=COL_FIXED,
        dtype_tag=DT_I64,
        fixed_width=UInt16(8),
        offset_in_row=UInt16(off),
    )


def _layout() raises -> RowLayout:
    """One I64 key + one I64 payload."""
    var l = RowLayout()
    l.add_key_col(_desc(0))
    l.add_payload_col(_desc(8))
    l.set_fixed_row_stride(16)
    return l^


def _col(
    imm vals: List[Int64], has_bitmap: Bool, null_row: Int, null_payload: Int64
) raises -> Column[HeapRegion]:
    """`has_bitmap` gives the column a validity buffer; `null_row >= 0` then
    clears that row's bit and writes `null_payload` into its slot."""
    var a: PrimitiveArray[DType.int64]
    if has_bitmap:
        a = PrimitiveArray[DType.int64].allocate_nullable(len(vals))
    else:
        a = PrimitiveArray[DType.int64].allocate(len(vals))
    for i in range(len(vals)):
        a.set(i, vals[i])
    if null_row >= 0:
        a.set(null_row, null_payload)
        a._set_null(null_row)
    return Column.from_primitive[DType.int64](a^)


def _keys() -> List[Int64]:
    var l = List[Int64]()
    l.append(Int64(50)); l.append(Int64(10)); l.append(Int64(30))
    l.append(Int64(20)); l.append(Int64(40))
    return l^


def _pays() -> List[Int64]:
    var l = List[Int64]()
    l.append(Int64(500)); l.append(Int64(100)); l.append(Int64(300))
    l.append(Int64(200)); l.append(Int64(400))
    return l^


def _batch(
    key_bitmap: Bool, key_null: Int, pay_bitmap: Bool, pay_null: Int
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, key_bitmap))
    sb.add_field(Field("p", ArrowType.INT64, pay_bitmap))
    var b = RecordBatchBuilder()
    b.add_column(_col(_keys(), key_bitmap, key_null, Int64.MAX))
    b.add_column(_col(_pays(), pay_bitmap, pay_null, Int64(-777)))
    return b.build(sb.build())


def _one(i: Int) -> List[Int]:
    var l = List[Int]()
    l.append(i)
    return l^


def _names(s: String) -> List[String]:
    var l = List[String]()
    l.append(s)
    return l^


def _feed_and_emit(imm rb: RecordBatch) raises -> RecordBatch:
    """Feed one batch, finalize ASC, emit. Raises whatever the buffer raises."""
    var layout = _layout()
    var buf = RowSortBuffer(8, layout.fixed_row_stride)
    buf.add_key_direction(SORT_ASC)
    buf.feed_batch(BatchView(rb), _one(0), _one(1), layout)
    buf.finalize_sort(layout)
    var out = buf.emit_to_record_batch(layout, _names("k"), _names("p"))
    assert_true(out, "emit returned Some for a non-empty buffer")
    return out.take()


def _assert_refused_or_kept(
    imm rb: RecordBatch, col: Int, want_null_at: Int, what: String
) raises:
    """THE CONTRACT: refused by name, OR the NULL kept at `want_null_at` of the
    emitted column `col`. Anything else — the pre-fix behaviour — is the NULL
    ERASED into a number."""
    var refused = False
    var msg = String("")
    var kept = False
    var got = String("")
    try:
        var out = _feed_and_emit(rb)
        ref c = out.column_at(col)
        kept = c.is_null_at(want_null_at)
        if not kept:
            got = String(Int(c.as_primitive[DType.int64]().get(want_null_at)))
    except e:
        refused = True
        msg = String(e)
    if refused:
        assert_true(
            "NULL" in msg,
            what + ": refused, but not BY NAME — the message must say the"
            " column holds a NULL; got: " + msg,
        )
        return
    assert_true(
        kept,
        what
        + ": the NULL was ERASED — the buffer ACCEPTED a NULL-bearing batch"
        " and emitted output row "
        + String(want_null_at)
        + " as the number "
        + got
        + " with no validity. A row format that stores one I64 cell and no"
        " validity must refuse a NULL, not answer with its payload",
    )


# =============================================================================
# §1 CONTROLS — served before and after.
# =============================================================================


def test_control_a_validity_bitmap_with_zero_nulls_is_served() raises:
    """Declared nullable, holds no NULL: must be SORTED, not refused."""
    var out = _feed_and_emit(_batch(True, -1, True, -1))
    var k = out.column_as_primitive_int64(0)
    var p = out.column_as_primitive_int64(1)
    for i in range(_N):
        assert_equal(Int(k.get(i)), (i + 1) * 10, "key[" + String(i) + "]")
        assert_equal(Int(p.get(i)), (i + 1) * 100, "pay[" + String(i) + "]")


def test_control_non_nullable_is_served() raises:
    var out = _feed_and_emit(_batch(False, -1, False, -1))
    var k = out.column_as_primitive_int64(0)
    assert_equal(Int(k.get(0)), 10, "key[0]")
    assert_equal(Int(k.get(4)), 50, "key[4]")


# =============================================================================
# §2 THE DEFECT — red before the fix.
# =============================================================================


def test_a_null_key_is_refused_or_kept() raises:
    """Row 1 (key 10) is NULL with `Int64.MAX` in its slot. Under the derived
    policy (NULLS LAST) a kept NULL is the LAST output row; the pre-fix buffer
    sorted it as MAX — also last — and emitted it as the number MAX with no
    validity, which is why the assertion reads validity and not position."""
    _assert_refused_or_kept(
        _batch(True, _NULL_ROW, False, -1), 0, _N - 1, "NULL key"
    )


def test_a_null_payload_is_refused_or_kept() raises:
    """Row 1's PAYLOAD is NULL (key 10 sorts first). A kept NULL is output row
    0 of the payload column; the pre-fix buffer emitted `-777`."""
    _assert_refused_or_kept(
        _batch(False, -1, True, _NULL_ROW), 1, 0, "NULL payload"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
