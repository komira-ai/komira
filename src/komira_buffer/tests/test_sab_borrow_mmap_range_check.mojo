# =============================================================================
# test_sab_borrow_mmap_range_check.mojo: the two mmap borrow constructors
# refuse a range outside the mapping in every build mode.
# =============================================================================
#
# `SharedAlignedBuffer.borrow_from_mmap` and `borrow_mmap_erased` build a
# buffer whose pointer is `mapping base + offset`. Nothing is read when the
# buffer is built, so a constructor that only `debug_assert`s the range
# (elided unless assertions are compiled in) returns a buffer that reads
# outside the mapping on first use. Both now raise; each case below pins the
# exact refusal, and the accepted cases pin the edges (a range ending exactly
# at the mapping end, and an empty range at the end).
#
# Branch map of `_check_mmap_borrow_range` (shared by both constructors):
#   offset < 0                       -> test_negative_offset_is_refused
#   length < 0                       -> test_negative_length_is_refused
#   offset > region length           -> test_offset_past_mapping_is_refused
#   length > region length - offset  -> test_range_past_mapping_is_refused
#                                       (incl. an offset + length that wraps)
#   in range                         -> test_in_range_borrows_are_accepted
# =============================================================================

from std.io import FileHandle
from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_buffer.mmap_region import MmapRegion
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_libc.chunked_write import write_chunked
from komira_libc.posix import _read_env


comptime FILE_LEN = 64
comptime PLAIN = "SharedAlignedBuffer.borrow_from_mmap"
comptime ERASED = "SharedAlignedBuffer.borrow_mmap_erased"


def _scratch(name: String) -> String:
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        d = String("/tmp")
    return d + "/komira_test_sab_borrow_range_" + name


def _region(name: String) raises -> ArcPointer[MmapRegion]:
    """A FILE_LEN-byte file whose byte i is i, mapped."""
    var bytes = List[UInt8](capacity=FILE_LEN)
    for i in range(FILE_LEN):
        bytes.append(UInt8(i))
    var path = _scratch(name)
    var h = FileHandle(path, "w")
    write_chunked(h, Span(bytes))
    _ = h^
    return ArcPointer[MmapRegion](MmapRegion.open_readonly(path))


def _plain_error(
    region: ArcPointer[MmapRegion], offset: Int64, length: Int64
) raises -> String:
    """`borrow_from_mmap`'s refusal text, or "" when it returned a buffer."""
    try:
        _ = SharedAlignedBuffer.borrow_from_mmap(
            ArcPointer[MmapRegion](copy=region), offset, length
        )
    except e:
        return String(e)
    return String("")


def _erased_error(
    region: ArcPointer[MmapRegion], offset: Int64, length: Int64
) raises -> String:
    """`borrow_mmap_erased`'s refusal text, or "" when it returned a buffer."""
    try:
        _ = SharedAlignedBuffer.borrow_mmap_erased(
            ArcPointer[MmapRegion](copy=region), offset, length
        )
    except e:
        return String(e)
    return String("")


def _negative(ctx: StringLiteral, offset: Int64, length: Int64) -> String:
    return (
        String(ctx) + ": negative offset/length (offset=" + String(offset)
        + ", length=" + String(length) + ")"
    )


def _outside(ctx: StringLiteral, offset: Int64, length: Int64) -> String:
    return (
        String(ctx) + ": range (offset=" + String(offset) + ", length="
        + String(length) + ") exceeds the mapped region (length="
        + String(FILE_LEN) + ")"
    )


def _expect_both(
    region: ArcPointer[MmapRegion], offset: Int64, length: Int64, negative: Bool
) raises:
    """Both constructors refuse (offset, length) with their own text."""
    if negative:
        assert_equal(
            _plain_error(region, offset, length), _negative(PLAIN, offset, length)
        )
        assert_equal(
            _erased_error(region, offset, length),
            _negative(ERASED, offset, length),
        )
    else:
        assert_equal(
            _plain_error(region, offset, length), _outside(PLAIN, offset, length)
        )
        assert_equal(
            _erased_error(region, offset, length),
            _outside(ERASED, offset, length),
        )


def test_negative_offset_is_refused() raises:
    _expect_both(_region("neg_off.bin"), Int64(-1), Int64(4), True)


def test_negative_length_is_refused() raises:
    _expect_both(_region("neg_len.bin"), Int64(0), Int64(-1), True)


def test_offset_past_mapping_is_refused() raises:
    """Offset one past the end, and an offset so large that offset + length
    wraps to a negative Int64."""
    var region = _region("off_past.bin")
    _expect_both(region, Int64(FILE_LEN + 1), Int64(0), False)
    _expect_both(region, Int64.MAX - 2, Int64(16), False)


def test_range_past_mapping_is_refused() raises:
    """An in-range offset with a length running past the end, and a length
    so large that offset + length wraps."""
    var region = _region("len_past.bin")
    _expect_both(region, Int64(60), Int64(8), False)
    _expect_both(region, Int64(8), Int64.MAX - 2, False)


def test_in_range_borrows_are_accepted() raises:
    """The edges that must still borrow: a range ending exactly at the end
    of the mapping (reads back the file's last bytes), the whole mapping,
    and an empty range at the end."""
    var region = _region("in_range.bin")
    var tail = SharedAlignedBuffer.borrow_from_mmap(
        ArcPointer[MmapRegion](copy=region), Int64(60), Int64(4)
    )
    assert_equal(tail.len(), 4)
    assert_equal(tail.read_u8_at(3), UInt8(63))
    var erased = SharedAlignedBuffer.borrow_mmap_erased(
        ArcPointer[MmapRegion](copy=region), Int64(0), Int64(FILE_LEN)
    )
    assert_equal(erased.len(), FILE_LEN)
    assert_equal(erased.read_u8_at(FILE_LEN - 1), UInt8(FILE_LEN - 1))
    assert_true(erased.has_mmap_keepalive())
    assert_equal(_plain_error(region, Int64(FILE_LEN), Int64(0)), String(""))
    assert_equal(_erased_error(region, Int64(FILE_LEN), Int64(0)), String(""))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
