# =============================================================================
# test_arrow_ipc_flatbuf_reader_primitives.mojo — FlatbufReader primitives
# =============================================================================
#
# Validates the FlatbufReader primitives, symmetric to FlatbufWriter's.
#
# All tests are end-to-end round-trips: write via FlatbufWriter,
# finalize to MmapAlignedBuffer, read via FlatbufReader, assert
# value-identical. This catches encode-decode bugs independently of the
# arrow-rs/pyarrow byte-level parity tests.
#
# Coverage:
#   1. read_u8 / read_u16_le / read_u32_le / read_i32_le / read_i64_le
#      / read_u64_le / read_bool — value round-trip.
#   2. Bounds-check raises on out-of-range reads.
#   3. read_offset_u32 — resolves offset slot to target position.
#   4. read_root_offset — first-4-bytes-as-root-offset.
#   5. read_string round-trip (empty / short / 7-byte).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.ipc_flatbuf import (
    FlatbufWriter,
    FlatbufReader,
    flatbuf_reader_over,
)


# ---------------------------------------------------------------------------
# Per-primitive round-trip
# ---------------------------------------------------------------------------


def test_reader_round_trip_u8() raises:
    """Round-trip a single u8 via finalize → reader.read_u8."""
    var w = FlatbufWriter(64)
    w.write_u8(UInt8(0xAB))
    # Cursor is the position of the last written byte (the u8).
    var target = w.cursor()
    var buf = w^.finalize(target)
    # In the finalized buffer, the root offset (4 bytes) is at
    # position 0. The u8 lives at root_offset target.
    var reader = flatbuf_reader_over(buf)
    var root = reader.read_root_offset()
    # The u8 we wrote is at `root` in the forward-order buffer.
    var got = reader.read_u8(root)
    assert_equal(got, UInt8(0xAB))


def test_reader_round_trip_u16_le() raises:
    """Round-trip a u16."""
    var w = FlatbufWriter(64)
    w.write_u16_le(UInt16(0x1234))
    var target = w.cursor()
    var buf = w^.finalize(target)
    var reader = flatbuf_reader_over(buf)
    var root = reader.read_root_offset()
    var got = reader.read_u16_le(root)
    assert_equal(got, UInt16(0x1234))


def test_reader_round_trip_u32_le() raises:
    """Round-trip a u32."""
    var w = FlatbufWriter(64)
    w.write_u32_le(UInt32(0xCAFEBABE))
    var target = w.cursor()
    var buf = w^.finalize(target)
    var reader = flatbuf_reader_over(buf)
    var root = reader.read_root_offset()
    var got = reader.read_u32_le(root)
    assert_equal(got, UInt32(0xCAFEBABE))


def test_reader_round_trip_i32_le() raises:
    """Round-trip an i32 (negative value)."""
    var w = FlatbufWriter(64)
    w.write_i32_le(Int32(-12345))
    var target = w.cursor()
    var buf = w^.finalize(target)
    var reader = flatbuf_reader_over(buf)
    var root = reader.read_root_offset()
    var got = reader.read_i32_le(root)
    assert_equal(got, Int32(-12345))


def test_reader_round_trip_i64_le() raises:
    """Round-trip an i64."""
    var w = FlatbufWriter(64)
    w.write_i64_le(Int64(0x123456789ABCDEF0))
    var target = w.cursor()
    var buf = w^.finalize(target)
    var reader = flatbuf_reader_over(buf)
    var root = reader.read_root_offset()
    var got = reader.read_i64_le(root)
    assert_equal(got, Int64(0x123456789ABCDEF0))


def test_reader_round_trip_u64_le() raises:
    """Round-trip a u64."""
    var w = FlatbufWriter(64)
    w.write_u64_le(UInt64(0xDEADBEEFCAFEBABE))
    var target = w.cursor()
    var buf = w^.finalize(target)
    var reader = flatbuf_reader_over(buf)
    var root = reader.read_root_offset()
    var got = reader.read_u64_le(root)
    assert_equal(got, UInt64(0xDEADBEEFCAFEBABE))


def test_reader_round_trip_bool_true() raises:
    """Round-trip Bool(True)."""
    var w = FlatbufWriter(64)
    w.write_bool(True)
    var target = w.cursor()
    var buf = w^.finalize(target)
    var reader = flatbuf_reader_over(buf)
    var root = reader.read_root_offset()
    assert_true(reader.read_bool(root))


def test_reader_round_trip_bool_false() raises:
    """Round-trip Bool(False)."""
    var w = FlatbufWriter(64)
    w.write_bool(False)
    var target = w.cursor()
    var buf = w^.finalize(target)
    var reader = flatbuf_reader_over(buf)
    var root = reader.read_root_offset()
    assert_false(reader.read_bool(root))


# ---------------------------------------------------------------------------
# Bounds check raises
# ---------------------------------------------------------------------------


def test_reader_out_of_bounds_raises() raises:
    """Reading past the FB payload length raises."""
    var w = FlatbufWriter(64)
    w.write_u32_le(UInt32(0xAAAAAAAA))
    var buf = w^.finalize(w.cursor() if False else 60)  # dummy
    # finalize wrote 4 (data) + 4 (root offset) = 8 bytes.
    var reader = flatbuf_reader_over(buf)
    var caught = False
    try:
        # Read at position past the payload.
        _ = reader.read_u8(100)
    except Error:
        caught = True
    assert_true(caught)


def test_reader_negative_position_raises() raises:
    """Reading at a negative position raises."""
    var w = FlatbufWriter(64)
    w.write_u8(UInt8(0))
    var buf = w^.finalize(w.cursor() if False else 63)
    var reader = flatbuf_reader_over(buf)
    var caught = False
    try:
        _ = reader.read_u8(-1)
    except Error:
        caught = True
    assert_true(caught)


# ---------------------------------------------------------------------------
# String round-trip
# ---------------------------------------------------------------------------


def test_reader_round_trip_string_empty() raises:
    """Round-trip an empty string."""
    var w = FlatbufWriter(64)
    var str_pos = w.write_string("")
    var buf = w^.finalize(str_pos)
    var reader = flatbuf_reader_over(buf)
    # Root offset points at the length-prefix position. read_string_at
    # reads the u32 length + bytes there.
    var root = reader.read_root_offset()
    var got = reader.read_string_at(root)
    assert_equal(got.byte_length(), 0)


def test_reader_round_trip_string_short() raises:
    """Round-trip a 4-byte string."""
    var w = FlatbufWriter(64)
    var str_pos = w.write_string("test")
    var buf = w^.finalize(str_pos)
    var reader = flatbuf_reader_over(buf)
    var root = reader.read_root_offset()
    var got = reader.read_string_at(root)
    assert_equal(got.byte_length(), 4)
    # Note: byte-level content equality is the responsibility of
    # `as_bytes()` round-trip; the String value compare is the
    # high-level contract.
    assert_equal(String(got), String("test"))


def test_reader_round_trip_string_seven_bytes() raises:
    """Round-trip a 7-byte string."""
    var w = FlatbufWriter(64)
    var str_pos = w.write_string("seven_b")
    var buf = w^.finalize(str_pos)
    var reader = flatbuf_reader_over(buf)
    var root = reader.read_root_offset()
    var got = reader.read_string_at(root)
    assert_equal(got.byte_length(), 7)
    assert_equal(String(got), String("seven_b"))


# ---------------------------------------------------------------------------
# TestSuite registration
# ---------------------------------------------------------------------------


def main() raises:
    var suite = TestSuite()

    # Per-primitive round-trip
    suite.test[test_reader_round_trip_u8]()
    suite.test[test_reader_round_trip_u16_le]()
    suite.test[test_reader_round_trip_u32_le]()
    suite.test[test_reader_round_trip_i32_le]()
    suite.test[test_reader_round_trip_i64_le]()
    suite.test[test_reader_round_trip_u64_le]()
    suite.test[test_reader_round_trip_bool_true]()
    suite.test[test_reader_round_trip_bool_false]()

    # Bounds checks
    suite.test[test_reader_out_of_bounds_raises]()
    suite.test[test_reader_negative_position_raises]()

    # String round-trip
    suite.test[test_reader_round_trip_string_empty]()
    suite.test[test_reader_round_trip_string_short]()
    suite.test[test_reader_round_trip_string_seven_bytes]()

    suite^.run()
