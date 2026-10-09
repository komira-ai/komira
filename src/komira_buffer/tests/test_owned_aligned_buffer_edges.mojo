# =============================================================================
# OwnedAlignedBuffer at its edges: the empty buffer, the no-op reserve, a
# reserve with nothing to keep, zero, free, and the memory-advice paths
# that issue no syscall; ByteView.fill and copy_to at their boundaries; and
# hugepage_span on an allocation whose end overflows the address space.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_buffer.byte_view import ByteView
from komira_buffer.hugepage_span import (
    ADVICE_HUGEPAGE,
    ADVICE_POPULATE,
    HUGEPAGE_BYTES,
    HUGEPAGE_MIN_ALLOC_BYTES,
    hugepage_span,
)
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer


def _fill(mut buf: OwnedAlignedBuffer, v: UInt8):
    buf.set_length(Int64(buf.capacity()))
    for i in range(buf.capacity()):
        buf.write_u8_at(i, v)


def test_empty_buffers() raises:
    """Capacity 0 and a negative capacity give the empty buffer: capacity 0,
    length 0, nothing owned, vacuously aligned, an empty view, no hint span
    and an advice call that does nothing and returns 0. Capacity 1 is not
    empty: one usable byte padded to 64."""
    for cap in [0, -5]:
        var b = OwnedAlignedBuffer(capacity=cap)
        assert_equal(b.capacity(), 0)
        assert_equal(b.len(), 0)
        assert_false(b.is_owned())
        assert_true(b.is_aligned())
        assert_equal(b.as_view().len(), 0)
        assert_true(b.memory_hint_span().is_empty())
        assert_equal(b.apply_memory_hint(ADVICE_HUGEPAGE | ADVICE_POPULATE), 0)
        b.zero()
        assert_equal(b.capacity(), 0)

    var one = OwnedAlignedBuffer(capacity=1)
    assert_equal(one.capacity(), 64)
    assert_equal(one.len(), 1)
    assert_true(one.is_owned())
    assert_true(one.is_aligned())


def test_free_leaves_the_empty_buffer() raises:
    """free() drops the bytes: capacity and length 0, not owned, vacuously
    aligned; the buffer can grow again with reserve."""
    var b = OwnedAlignedBuffer(capacity=200)
    _fill(b, 0x5A)
    b.free()
    assert_equal(b.capacity(), 0)
    assert_equal(b.len(), 0)
    assert_false(b.is_owned())
    assert_true(b.is_aligned())
    assert_equal(b.as_view().len(), 0)
    b.reserve(10)
    assert_equal(b.capacity(), 64)
    assert_equal(b.len(), 0)
    assert_true(b.is_aligned())


def test_reserve_within_capacity_is_a_no_op() raises:
    """reserve(n) for n up to the capacity keeps capacity, length and every
    byte (it must not reallocate, shrink or re-zero)."""
    var b = OwnedAlignedBuffer(capacity=128)
    _fill(b, 0x77)
    b.set_length(10)
    b.reserve(64)
    assert_equal(b.capacity(), 128)
    b.reserve(128)
    assert_equal(b.capacity(), 128)
    assert_equal(b.len(), 10)
    b.set_length(128)
    for i in range(128):
        assert_equal(b.read_u8_at(i), UInt8(0x77))


def test_reserve_with_nothing_to_keep_zeroes_everything() raises:
    """A grow from length 0 copies nothing and zeroes the whole new
    capacity, including the bytes the old buffer had written."""
    var b = OwnedAlignedBuffer(capacity=64)
    _fill(b, 0xEE)
    b.set_length(0)
    b.reserve(300)
    assert_equal(b.capacity(), 320)
    assert_equal(b.len(), 0)
    b.set_length(320)
    for i in range(320):
        assert_equal(b.read_u8_at(i), UInt8(0), "byte " + String(i))


def test_zero_clears_the_whole_capacity() raises:
    """zero() clears every byte up to the capacity, not only the length."""
    var b = OwnedAlignedBuffer(capacity=100)
    _fill(b, 0xAB)
    b.set_length(3)
    b.zero()
    assert_equal(b.len(), 3)
    b.set_length(128)
    for i in range(128):
        assert_equal(b.read_u8_at(i), UInt8(0), "byte " + String(i))


def test_as_view_covers_the_length() raises:
    """as_view spans [0, length) of the buffer's own bytes."""
    var b = OwnedAlignedBuffer(capacity=16)
    for i in range(16):
        b.write_u8_at(i, UInt8(i + 1))
    b.set_length(5)
    var v = b.as_view()
    assert_equal(v.len(), 5)
    assert_equal(v.read_u8_at(0), UInt8(1))
    assert_equal(v.read_u8_at(4), UInt8(5))


def _dirty_heap(n: Int, cap: Int):
    """Allocate n buffers of `cap` bytes, fill every byte with 0xFF, and
    free them all, so later allocations of that size are likely to reuse
    dirty blocks."""
    var keep = List[OwnedAlignedBuffer]()
    for _ in range(n):
        var junk = OwnedAlignedBuffer(capacity=cap)
        _fill(junk, 0xFF)
        keep.append(junk^)
    for i in range(n):
        keep[i].free()


def test_advice_on_a_small_buffer_does_nothing() raises:
    """Under HUGEPAGE_MIN_ALLOC_BYTES the advice is skipped: the constructor
    still pads and zeroes the tail, and apply_memory_hint finds no span and
    returns 0. (The size gate at the constructor's call is repeated inside
    hugepage_span, so skipping the call has no other observable effect.)"""
    # Reused blocks were filled with 0xFF: a zero tail is this
    # constructor's doing, not a fresh page's.
    _dirty_heap(32, 4000)
    var bufs = List[OwnedAlignedBuffer]()
    for _ in range(32):
        bufs.append(
            OwnedAlignedBuffer(
                capacity=4000, memory_advice=ADVICE_HUGEPAGE | ADVICE_POPULATE
            )
        )
    for k in range(32):
        assert_equal(bufs[k].capacity(), 4032)
        assert_equal(bufs[k].len(), 4000)
        assert_true(bufs[k].is_aligned())
        bufs[k].set_length(4032)
        for i in range(4000, 4032):
            assert_equal(
                bufs[k].read_u8_at(i),
                UInt8(0),
                "buffer " + String(k) + " tail byte " + String(i),
            )
    assert_true(bufs[0].memory_hint_span().is_empty())
    assert_equal(bufs[0].apply_memory_hint(ADVICE_HUGEPAGE), 0)
    assert_equal(bufs[0].apply_memory_hint(ADVICE_POPULATE), 0)


def test_hugepage_span_end_past_the_address_space() raises:
    """An allocation large enough to qualify whose end wraps past the top of
    the address space has no aligned interior to advise: empty, offset and
    length both 0."""
    var top = Int.MAX - 4 * 1024 * 1024
    var s = hugepage_span(top, HUGEPAGE_MIN_ALLOC_BYTES)
    assert_equal(s.offset, 0)
    assert_equal(s.length, 0)
    assert_true(s.is_empty())
    # One huge page lower the end does not wrap and the span is not empty.
    var lower = top - HUGEPAGE_MIN_ALLOC_BYTES - HUGEPAGE_BYTES
    assert_false(hugepage_span(lower, HUGEPAGE_MIN_ALLOC_BYTES).is_empty())


def test_byte_view_fill_boundaries() raises:
    """fill on an empty view writes nothing; on a one-byte view it writes
    that byte and not its neighbour."""
    var b = OwnedAlignedBuffer(capacity=2)
    b.write_u8_at(0, UInt8(0x11))
    b.write_u8_at(1, UInt8(0x22))
    var whole = b.view_mut()
    whole.sub(1, 0).fill(UInt8(0x99))
    assert_equal(b.read_u8_at(0), UInt8(0x11))
    assert_equal(b.read_u8_at(1), UInt8(0x22))
    var w2 = b.view_mut()
    w2.sub(0, 1).fill(UInt8(0x99))
    assert_equal(b.read_u8_at(0), UInt8(0x99))
    assert_equal(b.read_u8_at(1), UInt8(0x22))


def test_byte_view_copy_to_appends_the_range() raises:
    """copy_to(dest, start, n) appends bytes [start, start + n) after what
    dest holds; n == 0 appends nothing."""
    var b = OwnedAlignedBuffer(capacity=6)
    for i in range(6):
        b.write_u8_at(i, UInt8(0x30 + i))
    var v = b.view_ro()
    var dest = List[UInt8]()
    dest.append(0x01)
    v.copy_to(dest, 2, 3)
    assert_equal(dest, [UInt8(0x01), UInt8(0x32), UInt8(0x33), UInt8(0x34)])
    v.copy_to(dest, 5, 0)
    assert_equal(len(dest), 4)
    v.copy_to(dest, 5, 1)
    assert_equal(dest[4], UInt8(0x35))


def main() raises:
    var s = TestSuite()
    s.test[test_empty_buffers]()
    s.test[test_free_leaves_the_empty_buffer]()
    s.test[test_reserve_within_capacity_is_a_no_op]()
    s.test[test_reserve_with_nothing_to_keep_zeroes_everything]()
    s.test[test_zero_clears_the_whole_capacity]()
    s.test[test_as_view_covers_the_length]()
    s.test[test_advice_on_a_small_buffer_does_nothing]()
    s.test[test_hugepage_span_end_past_the_address_space]()
    s.test[test_byte_view_fill_boundaries]()
    s.test[test_byte_view_copy_to_appends_the_range]()
    s^.run()
