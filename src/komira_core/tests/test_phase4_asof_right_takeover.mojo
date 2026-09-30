# =============================================================================
# SINK_ASOF_JOIN right side: move-out via `Slab.replace` + `Optional.take()`
# =============================================================================
#
# What this test asserts:
#   The asof-join sink pulls its right-side batch out of the sink-output
#   slab with the same `Slab.replace(idx, None)` move-out primitive that
#   resolving a sink-output source uses. Both call sites use the same
#   primitive (they differ only in which slot index is read), so this test
#   validates the primitive in isolation: replace the Optional in slot N
#   with None, and get back the inner RecordBatch with its buffer pointer
#   intact.
#
# Why no end-to-end asof drive here:
#   Each asof segment's right side is referenced exactly once, by that asof
#   segment, so a single-consumer move-out preserves the read-by-reference
#   semantics (the sink consumes the batch by value and sorts it in place).
#   The end-to-end asof pipeline is exercised by the engine's asof-join
#   tests; this test isolates the primitive.
#
# Note on the discriminating invariant:
#   Buffer-pointer equality across `Slab.replace` is what proves "no deep
#   copy": the MmapAlignedBuffer's `_ptr` survives the move-out.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.schema import (
    Field,
    RecordBatch,
    Schema,
    SchemaBuilder,
)

from komira_core.collections.slab import Slab


# =============================================================================
# Helpers
# =============================================================================


def _build_int64_batch(var values: List[Int64]) raises -> RecordBatch:
    """Build a single-column INT64 RecordBatch."""
    var n = len(values)
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        (p + i)[] = values[i]
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.INT64, False))
    return RecordBatch.from_columns_1(sb.build(), arr^)


def _data_ptr_addr(ref batch: RecordBatch) -> Int:
    """Read the MmapAlignedBuffer's _ptr address out of column 0."""
    var col_ptr = batch._columns._unsafe_ptr() + 0
    return Int(col_ptr[]._data.view_typed_ro[DType.uint8]())


# =============================================================================
# Tests
# =============================================================================


def test_slab_replace_preserves_buffer_address() raises:
    """`Slab.replace(idx, None)` moves the Optional out of the slot
    byte-for-byte; the inner RecordBatch's MmapAlignedBuffer `_ptr`
    survives.

    Both the SOURCE_SINK_OUTPUT resolve and the SINK_ASOF_JOIN
    right-pull rely on this primitive. A `copy_batch(...)` of the slot
    would produce a NEW buffer pointer; `Slab.replace + Optional.take`
    preserves it.
    """
    var vs: List[Int64] = []
    for i in range(96):
        vs.append(Int64(3 * i + 1))
    var b1 = _build_int64_batch(vs^)
    var addr_before = _data_ptr_addr(b1)

    var slab = Slab[Optional[RecordBatch]].create(3)
    for _ in range(3):
        slab.append(Optional[RecordBatch](None))
    slab.set(2, Optional[RecordBatch](b1^))

    # Pre-replace: slot 2 populated.
    assert_true(slab[2].__bool__(), "slot 2 populated pre-replace")

    # Replace the slot with None; recover the previous occupant.
    var taken_opt = slab.replace(2, Optional[RecordBatch](None))
    assert_true(taken_opt.__bool__(), "taken Optional must be Some")

    # Slot 2 now empty.
    assert_false(slab[2].__bool__(), "slot 2 None post-replace")

    # Buffer pointer survives byte-for-byte.
    var taken_batch = taken_opt.take()
    var addr_after = _data_ptr_addr(taken_batch)
    assert_equal(
        addr_before, addr_after,
        "Slab.replace must move the inner batch's buffer (no deep copy)",
    )

    # Sanity: row count + a few values preserved.
    assert_equal(taken_batch.num_rows(), 96, "row count preserved")
    var data_ptr = (taken_batch._columns._unsafe_ptr() + 0)[]._data.view_typed_ro[DType.uint8]()
    var typed_ptr = data_ptr.bitcast[Scalar[DType.int64]]()
    assert_equal(Int((typed_ptr + 0)[]), 1, "row[0] = 3 * 0 + 1")
    assert_equal(Int((typed_ptr + 95)[]), 286, "row[95] = 3 * 95 + 1")


def test_slab_replace_other_slots_untouched() raises:
    """`Slab.replace(idx, None)` MUST NOT disturb other slots."""
    var b0 = _build_int64_batch([Int64(10), Int64(20)])
    var b1 = _build_int64_batch([Int64(30), Int64(40)])
    var b2 = _build_int64_batch([Int64(50), Int64(60)])
    var addr0 = _data_ptr_addr(b0)
    var addr2 = _data_ptr_addr(b2)

    var slab = Slab[Optional[RecordBatch]].create(3)
    slab.append(Optional[RecordBatch](b0^))
    slab.append(Optional[RecordBatch](b1^))
    slab.append(Optional[RecordBatch](b2^))

    # Take slot 1 only.
    var taken = slab.replace(1, Optional[RecordBatch](None))
    assert_true(taken.__bool__(), "slot 1 take returned Some")

    # Slots 0 and 2 still populated and unchanged.
    assert_true(slab[0].__bool__(), "slot 0 still populated")
    assert_true(slab[2].__bool__(), "slot 2 still populated")
    assert_false(slab[1].__bool__(), "slot 1 drained")

    # Slot 0 buffer pointer unchanged.
    var addr0_after = Int(slab[0].value()._columns._unsafe_ptr()[]._data.view_typed_ro[DType.uint8]())
    var addr2_after = Int(slab[2].value()._columns._unsafe_ptr()[]._data.view_typed_ro[DType.uint8]())
    assert_equal(addr0, addr0_after, "slot 0 buffer pointer unchanged")
    assert_equal(addr2, addr2_after, "slot 2 buffer pointer unchanged")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
