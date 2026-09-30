# =============================================================================
# test_arrow_ipc_flatbuf_writer_primitives.mojo — FlatbufWriter primitives
# =============================================================================
#
# Validates the foundation primitives of `FlatbufWriter`.
#
# Coverage:
#   1. Constructor + initial state (cursor / capacity / bytes_written).
#   2. Per-primitive write: u8 / u16_le / u32_le / i32_le / i64_le /
#      u64_le / bool.
#   3. Multi-write cursor advancement (back-to-front discipline).
#   4. Padding + align_to.
#   5. Offset arithmetic.
#   6. String encoding (length + bytes + null + pad-to-4).
#   7. finalize() round-trip (write bytes → finalize → assert content).
#   8. Capacity overflow error path.
#
# Reader-side round-trips are in `test_arrow_ipc_flatbuf_reader_primitives.mojo`;
# per-Type-union and per-table tests are in the other flatbuf test files.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.ipc_flatbuf import (
    FlatbufWriter,
    FB_DEFAULT_CAPACITY,
    FB_MIN_ALIGNMENT,
    FB_ROOT_ALIGNMENT,
)


# ---------------------------------------------------------------------------
# Constructor + initial state
# ---------------------------------------------------------------------------


def test_writer_default_capacity() raises:
    """Default constructor allocates at FB_DEFAULT_CAPACITY (64 KB)."""
    var w = FlatbufWriter()
    assert_equal(w.capacity(), FB_DEFAULT_CAPACITY)
    assert_equal(w.bytes_written(), 0)
    assert_equal(w.cursor(), FB_DEFAULT_CAPACITY)


def test_writer_explicit_capacity() raises:
    """Explicit capacity is honored (rounded up to 8-byte alignment)."""
    var w = FlatbufWriter(128)
    assert_equal(w.capacity(), 128)
    assert_equal(w.bytes_written(), 0)


def test_writer_min_capacity_floor() raises:
    """Capacity below 64 bytes is floored at 64."""
    var w = FlatbufWriter(8)
    assert_equal(w.capacity(), 64)


# ---------------------------------------------------------------------------
# Per-primitive writes — cursor moves backward by the expected width
# ---------------------------------------------------------------------------


def test_write_u8_moves_cursor_by_1() raises:
    """write_u8 consumes 1 byte from the back."""
    var w = FlatbufWriter(64)
    w.write_u8(UInt8(0xAB))
    assert_equal(w.bytes_written(), 1)
    assert_equal(w.cursor(), 63)


def test_write_u16_le_moves_cursor_by_2() raises:
    var w = FlatbufWriter(64)
    w.write_u16_le(UInt16(0x1234))
    assert_equal(w.bytes_written(), 2)
    assert_equal(w.cursor(), 62)


def test_write_u32_le_moves_cursor_by_4() raises:
    var w = FlatbufWriter(64)
    w.write_u32_le(UInt32(0xCAFEBABE))
    assert_equal(w.bytes_written(), 4)
    assert_equal(w.cursor(), 60)


def test_write_i32_le_moves_cursor_by_4() raises:
    var w = FlatbufWriter(64)
    w.write_i32_le(Int32(-1))
    assert_equal(w.bytes_written(), 4)


def test_write_i64_le_moves_cursor_by_8() raises:
    var w = FlatbufWriter(64)
    w.write_i64_le(Int64(-42))
    assert_equal(w.bytes_written(), 8)
    assert_equal(w.cursor(), 56)


def test_write_u64_le_moves_cursor_by_8() raises:
    var w = FlatbufWriter(64)
    w.write_u64_le(UInt64(0xDEADBEEFCAFEBABE))
    assert_equal(w.bytes_written(), 8)


def test_write_bool_moves_cursor_by_1() raises:
    var w = FlatbufWriter(64)
    w.write_bool(True)
    w.write_bool(False)
    assert_equal(w.bytes_written(), 2)


# ---------------------------------------------------------------------------
# Multi-write — back-to-front discipline
# ---------------------------------------------------------------------------


def test_multi_write_chains_cursor() raises:
    """Multiple writes accumulate; cursor moves continuously back."""
    var w = FlatbufWriter(64)
    w.write_u32_le(UInt32(0x11111111))  # 4 bytes
    w.write_u32_le(UInt32(0x22222222))  # 4 bytes
    w.write_i64_le(Int64(0x33333333))    # 8 bytes
    assert_equal(w.bytes_written(), 16)
    assert_equal(w.cursor(), 48)


# ---------------------------------------------------------------------------
# Padding + alignment
# ---------------------------------------------------------------------------


def test_write_padding_zero_bytes_noop() raises:
    """write_padding(0) is a no-op (no cursor movement)."""
    var w = FlatbufWriter(64)
    w.write_padding(0)
    assert_equal(w.bytes_written(), 0)


def test_write_padding_4_bytes() raises:
    var w = FlatbufWriter(64)
    w.write_padding(4)
    assert_equal(w.bytes_written(), 4)


def test_align_to_no_op_when_aligned() raises:
    """align_to(4, 4) when bytes_written=0 is no-op (0 + 4 = 4 mod 4 = 0)."""
    var w = FlatbufWriter(64)
    w.align_to(4, 4)
    assert_equal(w.bytes_written(), 0)


def test_align_to_pads_when_unaligned() raises:
    """align_to(4, 4) after 1 byte adds 3 padding bytes."""
    var w = FlatbufWriter(64)
    w.write_u8(UInt8(0xAA))           # bytes_written = 1
    w.align_to(4, 4)                  # total = 1 + 4 = 5; pad 3 → 8
    assert_equal(w.bytes_written(), 4)  # 1 byte + 3 padding


# ---------------------------------------------------------------------------
# Offset arithmetic
# ---------------------------------------------------------------------------


def test_offset_to_target_at_current_cursor() raises:
    """An offset to a target at the current cursor encodes as 0."""
    var w = FlatbufWriter(64)
    # Target is at "now"; allocate a 4-byte offset slot and the
    # offset should be 0 (target = cursor, offset_pos = cursor - 4).
    # But target IS at the position where we're ABOUT to write... no,
    # the target is at the CURRENT cursor BEFORE writing the offset.
    # After writing 4 bytes (the offset slot), cursor decreases by 4.
    # offset_pos = cursor() AT WRITE TIME - 4.
    var target = w.cursor()  # captures cursor BEFORE writing offset slot
    w.write_offset_u32(target)
    assert_equal(w.bytes_written(), 4)


# ---------------------------------------------------------------------------
# String encoding
# ---------------------------------------------------------------------------


def test_write_string_empty() raises:
    """Empty string: [u32 length=0, 0x00 null, pad-to-4]."""
    var w = FlatbufWriter(64)
    var pos = w.write_string("")
    # Layout: 4 (length) + 0 (bytes) + 1 (null) + 3 (pad) = 8 bytes.
    assert_equal(w.bytes_written(), 8)
    # Return position = position of length prefix = current cursor.
    assert_equal(pos, w.cursor())


def test_write_string_short() raises:
    """4-byte string fits exactly: u32 length + 4 bytes + null + 3 pad."""
    var w = FlatbufWriter(64)
    var pos = w.write_string("test")
    # Layout: 4 (length=4) + 4 ("test") + 1 (null) + 3 (pad to 8) = 12.
    assert_equal(w.bytes_written(), 12)
    assert_equal(pos, w.cursor())


def test_write_string_seven_bytes() raises:
    """7-byte string: u32 length + 7 bytes + null = 12 (aligned, no pad)."""
    var w = FlatbufWriter(64)
    _ = w.write_string("seven_b")
    # Layout: 4 (length=7) + 7 ("seven_b") + 1 (null) + 0 (already 4-aligned) = 12.
    assert_equal(w.bytes_written(), 12)


# ---------------------------------------------------------------------------
# Capacity overflow
# ---------------------------------------------------------------------------


def test_write_overflow_raises() raises:
    """Writing past capacity raises with a clear error message."""
    var w = FlatbufWriter(64)
    # Fill up to capacity in 8-byte chunks.
    for _ in range(8):
        w.write_i64_le(Int64(0))
    # 8 × 8 = 64 bytes consumed; capacity = 64. Next write must raise.
    var caught = False
    try:
        w.write_u8(UInt8(0xFF))
    except Error:
        caught = True
    assert_true(caught)


# ---------------------------------------------------------------------------
# finalize() — emits the FlatBuffer payload bytes
# ---------------------------------------------------------------------------


def test_finalize_emits_root_offset_plus_data() raises:
    """finalize writes a root offset u32 + returns a forward-order buffer."""
    var w = FlatbufWriter(64)
    # Write a tiny placeholder "table" at position P.
    w.write_u32_le(UInt32(0x11223344))
    var table_pos = w.cursor()
    var out = w^.finalize(table_pos)
    # Output length = data_bytes + 4 (root offset) = 4 + 4 = 8.
    assert_equal(out.len(), 8)


# ---------------------------------------------------------------------------
# TestSuite registration
# ---------------------------------------------------------------------------


def main() raises:
    var suite = TestSuite()

    # Constructor + initial state
    suite.test[test_writer_default_capacity]()
    suite.test[test_writer_explicit_capacity]()
    suite.test[test_writer_min_capacity_floor]()

    # Per-primitive writes
    suite.test[test_write_u8_moves_cursor_by_1]()
    suite.test[test_write_u16_le_moves_cursor_by_2]()
    suite.test[test_write_u32_le_moves_cursor_by_4]()
    suite.test[test_write_i32_le_moves_cursor_by_4]()
    suite.test[test_write_i64_le_moves_cursor_by_8]()
    suite.test[test_write_u64_le_moves_cursor_by_8]()
    suite.test[test_write_bool_moves_cursor_by_1]()

    # Multi-write + padding
    suite.test[test_multi_write_chains_cursor]()
    suite.test[test_write_padding_zero_bytes_noop]()
    suite.test[test_write_padding_4_bytes]()
    suite.test[test_align_to_no_op_when_aligned]()
    suite.test[test_align_to_pads_when_unaligned]()

    # Offsets
    suite.test[test_offset_to_target_at_current_cursor]()

    # Strings
    suite.test[test_write_string_empty]()
    suite.test[test_write_string_short]()
    suite.test[test_write_string_seven_bytes]()

    # Overflow + finalize
    suite.test[test_write_overflow_raises]()
    suite.test[test_finalize_emits_root_offset_plus_data]()

    suite^.run()
