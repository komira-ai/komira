# =============================================================================
# SharedAlignedBuffer and CopyableSharedAlignedBuffer: the constructors and
# methods no other test of this package reaches. Each checks which bytes
# the result sees (aliasing where the method shares, a copy where it
# copies), its length, and the mmap keepalive where one can be carried.
# =============================================================================

from std.memory import ArcPointer
from std.os import remove, rmdir
from std.os.path import exists
from std.tempfile import mkdtemp
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_buffer.copyable_shared_aligned_buffer import (
    CopyableSharedAlignedBuffer,
    take_heap_buffer,
)
from komira_buffer.heap_region import HeapRegion
from komira_buffer.mmap_region import MmapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import (
    SharedAlignedBuffer,
    bridge_oab_to_sab,
)


def _heap(n: Int) -> SharedAlignedBuffer[HeapRegion]:
    """An n-byte heap buffer holding 0x40, 0x41, ..."""
    var o = OwnedAlignedBuffer(capacity=n)
    for i in range(n):
        o.write_u8_at(i, UInt8(0x40 + i))
    return SharedAlignedBuffer[HeapRegion].from_owned(o^)


def _erased_mmap() raises -> SharedAlignedBuffer[HeapRegion]:
    """A buffer carrying an mmap keepalive (over an empty region: the
    keepalive is what is under test, not the bytes)."""
    var arc = ArcPointer[MmapRegion](MmapRegion())
    return SharedAlignedBuffer.borrow_mmap_erased(arc^, 0, 0)


def test_bridge_oab_to_sab_moves_the_bytes() raises:
    """The bridge keeps the owned buffer's length (not its capacity), its
    bytes and its alignment."""
    var o = OwnedAlignedBuffer(capacity=100)
    for i in range(100):
        o.write_u8_at(i, UInt8(i + 1))
    o.set_length(10)
    var s = bridge_oab_to_sab[HeapRegion](o^)
    assert_equal(s.len(), 10)
    assert_true(s.is_aligned())
    assert_true(s.is_owned())
    for i in range(10):
        assert_equal(s.read_u8_at(i), UInt8(i + 1))


def test_from_borrowed_view_aliases_the_view() raises:
    """The buffer reads the view's bytes in place: its length is the
    view's, and a write to the source shows through it."""
    var src = OwnedAlignedBuffer(capacity=16)
    for i in range(16):
        src.write_u8_at(i, UInt8(0x60 + i))
    var s = SharedAlignedBuffer[HeapRegion].from_borrowed_view(
        src.view_ro().sub(4, 5)
    )
    assert_equal(s.len(), 5)
    assert_equal(s.read_u8_at(0), UInt8(0x64))
    assert_equal(s.read_u8_at(4), UInt8(0x68))
    assert_false(s.has_mmap_keepalive())
    src.write_u8_at(4, UInt8(0x01))
    assert_equal(s.read_u8_at(0), UInt8(0x01))
    _ = src^


def test_share_and_share_as_alias_the_same_bytes() raises:
    """share() and share_as[HeapRegion]() see the same bytes as the source
    (a write through one is read through the others) and its length."""
    var a = _heap(8)
    var b = a.share()
    var c = a.share_as[HeapRegion]()
    assert_equal(b.len(), 8)
    assert_equal(c.len(), 8)
    a.write_u8_at(3, UInt8(0xAA))
    assert_equal(b.read_u8_at(3), UInt8(0xAA))
    assert_equal(c.read_u8_at(3), UInt8(0xAA))
    assert_equal(c.read_u8_at(7), UInt8(0x47))
    assert_false(b.has_mmap_keepalive())
    assert_false(c.has_mmap_keepalive())


def test_share_and_share_as_keep_the_mmap_keepalive() raises:
    """A share of an mmap-borrowed buffer carries the keepalive too, and the
    source keeps its own."""
    var a = _erased_mmap()
    assert_true(a.has_mmap_keepalive())
    var b = a.share()
    var c = a.share_as[HeapRegion]()
    assert_true(b.has_mmap_keepalive())
    assert_true(c.has_mmap_keepalive())
    assert_true(b.is_mmap_backed())
    assert_true(a.has_mmap_keepalive())


def _shares_of_a_dropped_source() -> Tuple[
    SharedAlignedBuffer[HeapRegion], SharedAlignedBuffer[HeapRegion]
]:
    var a = _heap(32)
    var b = a.share()
    var c = a.share_as[HeapRegion]()
    _ = a^
    return (b^, c^)


def test_share_survives_the_source() raises:
    """The shared region outlives the buffer it was shared from."""
    var t = _shares_of_a_dropped_source()
    for i in range(32):
        assert_equal(t[0].read_u8_at(i), UInt8(0x40 + i))
        assert_equal(t[1].read_u8_at(i), UInt8(0x40 + i))


def test_from_byte_view_derives_offset_and_length() raises:
    """from_byte_view over a slice of an Arc'd region records the slice's
    offset from the region's base and its length, and reads its bytes."""
    var bytes = List[UInt8]()
    for i in range(12):
        bytes.append(UInt8(0x20 + i))
    var arc = ArcPointer[HeapRegion](HeapRegion(bytes^))
    var keep = ArcPointer[HeapRegion](copy=arc)
    var view = keep[].as_view().sub(3, 4)
    var s = SharedAlignedBuffer.from_byte_view(arc^, view)
    assert_equal(s.len(), 4)
    assert_equal(s.length(), Int64(4))
    assert_equal(s._offset, Int64(3))
    assert_equal(s.read_u8_at(0), UInt8(0x23))
    assert_equal(s.read_u8_at(3), UInt8(0x26))


def test_as_view_covers_the_window() raises:
    """as_view spans the buffer's own window: a sub-range share's view starts
    at the window, not at the region's base."""
    var a = _heap(10)
    var w = a.share_range_as[HeapRegion](2, 5)
    var v = w.as_view()
    assert_equal(v.len(), 5)
    assert_equal(v.read_u8_at(0), UInt8(0x42))
    assert_equal(v.read_u8_at(4), UInt8(0x46))
    assert_equal(a.as_view().len(), 10)


def test_realign_to_copies_into_aligned_storage() raises:
    """realign_to[64] of a window at an odd offset gives a 64-aligned copy
    of its bytes: equal content, own storage (later writes to the source do
    not show), and an empty buffer realigns to an empty one."""
    var a = _heap(40)
    var w = a.share_range_as[HeapRegion](1, 20)
    assert_false(w.is_aligned_to[64]())
    var r = w.realign_to[64]()
    assert_true(r.is_aligned_to[64]())
    assert_true(r.is_aligned())
    assert_equal(r.len(), 20)
    for i in range(20):
        assert_equal(r.read_u8_at(i), UInt8(0x41 + i))
    a.write_u8_at(1, UInt8(0x00))
    assert_equal(r.read_u8_at(0), UInt8(0x41))

    var empty = SharedAlignedBuffer[HeapRegion].heap_owned(0)
    assert_true(empty.is_aligned_to[64]())
    var re = empty.realign_to[64]()
    assert_equal(re.len(), 0)


def test_set_length_both_overloads() raises:
    """set_length(Int) and set_length(Int64) set the logical length the
    readers and views use."""
    var a = _heap(16)
    a.set_length(5)
    assert_equal(a.len(), 5)
    assert_equal(a.capacity(), 5)
    assert_equal(a.as_view().len(), 5)
    a.set_length(Int64(9))
    assert_equal(a.length(), Int64(9))
    assert_equal(a.read_u8_at(8), UInt8(0x48))


def test_zero_clears_only_the_window() raises:
    """zero() clears the buffer's own window of a shared region; bytes of
    the region outside it are untouched. An empty buffer zeroes nothing."""
    var a = _heap(8)
    var w = a.share_range_as[HeapRegion](2, 3)
    w.zero()
    assert_equal(a.read_u8_at(1), UInt8(0x41))
    assert_equal(a.read_u8_at(2), UInt8(0))
    assert_equal(a.read_u8_at(4), UInt8(0))
    assert_equal(a.read_u8_at(5), UInt8(0x45))
    var e = SharedAlignedBuffer[HeapRegion].heap_owned(0)
    e.zero()
    assert_equal(e.len(), 0)


def test_reserve() raises:
    """reserve(n) for n up to the length keeps the same bytes; a larger n
    gives this buffer n bytes of fresh 64-aligned storage, drops its mmap
    keepalive, and leaves another sharer of the old bytes reading them."""
    var a = _heap(8)
    var other = a.share()
    a.reserve(8)
    assert_equal(a.len(), 8)
    a.write_u8_at(0, UInt8(0x11))
    assert_equal(other.read_u8_at(0), UInt8(0x11))

    a.reserve(100)
    assert_equal(a.len(), 100)
    assert_true(a.is_aligned())
    a.write_u8_at(0, UInt8(0x22))
    assert_equal(other.read_u8_at(0), UInt8(0x11))
    assert_equal(other.read_u8_at(7), UInt8(0x47))

    var m = _erased_mmap()
    m.reserve(16)
    assert_equal(m.len(), 16)
    assert_false(m.has_mmap_keepalive())


def test_free() raises:
    """free() leaves this buffer empty and unowned with no keepalive; a
    sharer still reads the bytes."""
    var a = _heap(8)
    var other = a.share()
    a.free()
    assert_equal(a.len(), 0)
    assert_false(a.is_owned())
    assert_true(a.is_aligned())
    assert_equal(other.read_u8_at(7), UInt8(0x47))
    var m = _erased_mmap()
    m.free()
    assert_false(m.has_mmap_keepalive())


def test_mmap_borrowed_buffer_is_not_owned() raises:
    """A non-empty buffer over mapped file bytes, carried by the keepalive
    cookie, reads the file and is mmap-backed, not owned."""
    var dir = mkdtemp()
    var path = dir + "/m.bin"
    try:
        with open(path, "w") as f:
            f.write("mapped bytes")
        var arc = ArcPointer[MmapRegion](MmapRegion.open_readonly(path))
        var s = SharedAlignedBuffer.borrow_mmap_erased(arc^, 7, 5)
        assert_equal(s.len(), 5)
        assert_equal(s.read_u8_at(0), UInt8(ord("b")))
        assert_true(s.has_mmap_keepalive())
        assert_true(s.is_mmap_backed())
        assert_false(s.is_owned())
        assert_true(_heap(1).is_owned())
    finally:
        if exists(path):
            remove(path)
        rmdir(dir)


def test_empty_window_alignment_is_its_pointer() raises:
    """A zero-length window keeps its pointer: at an odd offset it is not
    64-aligned; only an empty buffer with no pointer is vacuously aligned."""
    var a = _heap(8)
    var odd = a.share_range_as[HeapRegion](1, 0)
    assert_equal(odd.len(), 0)
    assert_false(odd.is_aligned())
    var at_start = a.share_range_as[HeapRegion](0, 0)
    assert_true(at_start.is_aligned())
    var e = SharedAlignedBuffer[HeapRegion].heap_owned(0)
    assert_true(e.is_aligned())


def test_copyable_sized_constructor() raises:
    """CopyableSharedAlignedBuffer(size) has length `size` (0 for a negative
    size) and 64-aligned storage."""
    var c = CopyableSharedAlignedBuffer[HeapRegion](10)
    assert_equal(c.length(), 10)
    assert_true(c.is_aligned())
    var z = CopyableSharedAlignedBuffer[HeapRegion](-3)
    assert_equal(z.length(), 0)


def test_copyable_copy_and_take() raises:
    """A copy of a heap buffer shares its bytes and carries no keepalive;
    take_heap_buffer moves the buffer out and leaves the wrapper empty."""
    var src = CopyableSharedAlignedBuffer[HeapRegion](_heap(8))
    var dst = CopyableSharedAlignedBuffer[HeapRegion](copy=src)
    assert_false(dst.has_mmap_keepalive())
    assert_equal(dst.length(), 8)
    src.set_typed[UInt8](2, UInt8(0x99))
    var taken = take_heap_buffer(dst)
    assert_equal(dst.length(), 0)
    assert_equal(taken.len(), 8)
    assert_equal(taken.read_u8_at(2), UInt8(0x99))
    assert_equal(taken.read_u8_at(7), UInt8(0x47))


def main() raises:
    var s = TestSuite()
    s.test[test_bridge_oab_to_sab_moves_the_bytes]()
    s.test[test_from_borrowed_view_aliases_the_view]()
    s.test[test_share_and_share_as_alias_the_same_bytes]()
    s.test[test_share_and_share_as_keep_the_mmap_keepalive]()
    s.test[test_share_survives_the_source]()
    s.test[test_from_byte_view_derives_offset_and_length]()
    s.test[test_as_view_covers_the_window]()
    s.test[test_realign_to_copies_into_aligned_storage]()
    s.test[test_set_length_both_overloads]()
    s.test[test_zero_clears_only_the_window]()
    s.test[test_reserve]()
    s.test[test_free]()
    s.test[test_mmap_borrowed_buffer_is_not_owned]()
    s.test[test_empty_window_alignment_is_its_pointer]()
    s.test[test_copyable_sized_constructor]()
    s.test[test_copyable_copy_and_take]()
    s^.run()
