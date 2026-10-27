# =============================================================================
# test_thsplc_wire_layout.mojo: the THSPLC byte layout, pinned.
# =============================================================================
#
# A round trip is self-consistent: an encoder and a decoder that agree on a
# wrong layout still round-trip. This test reads the encoded bytes directly
# and compares them with the layout documented in thsplc.mojo, so a change to
# the descriptor fields, the region alignment or the body end fails here.
#
# Fixture: a nullable INT64 column (5 rows, NULL at rows 1 and 3) and a STRING
# column (5 rows, 7 value bytes). Expected layout:
#
#   header 96 B, two descriptors 96 B           -> first region at 192
#   column 0: validity 1 B + values 40 B        -> region 192, ends at 233
#   column 1: offsets 24 B + values 7 B         -> region 240 (8-aligned),
#                                                  ends at 271
#   body end padded to 272; body_length = 272 - 96 = 176; trailing magic at
#   272..279; total length 280.
#
# What each assertion catches: a wrong validity_len / offsets_len / values_len
# in a descriptor, a region that is not 8-aligned, a body end that is not
# padded to 8 (so a misplaced trailing magic), a non-zero pad byte (an
# irreproducible image), and a validity bitmap written at the wrong place.
# =============================================================================

from std.testing import assert_equal, TestSuite

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_collections.slab import Slab

from komira_engine_runtime.spill.thsplc import THSPLCEncoder


comptime D0: Int = 96
comptime D1: Int = 144


def _fixture_chunk() raises -> SharedAlignedBuffer[HeapRegion]:
    var vals = List[Scalar[DType.int64]]()
    for i in range(5):
        vals.append(Int64(10 + i))
    var n = 5
    var buf = OwnedAlignedBuffer(n * 8)
    var p = buf.view_typed_ro[DType.int64]()
    for i in range(n):
        p[i] = vals[i]
    buf.set_length(Int64(n * 8))
    var bm = Bitmap.create_all_valid(n)
    bm.clear(1)
    bm.clear(3)
    var nullable = PrimitiveArray[DType.int64](buf^, n, Optional(bm^), 2, 0)

    var strs = List[String]()
    strs.append("ab")
    strs.append("")
    strs.append("cde")
    strs.append("f")
    strs.append("g")

    var cols = Slab[Column[HeapRegion]].create(2)
    cols.append(Column.from_primitive[DType.int64](nullable^))
    cols.append(Column.from_string(StringArray.from_strings(strs)))
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("s", ArrowType.STRING, False))
    var batch = RecordBatch.from_typed_columns_slab(sb.build(), cols^)
    return THSPLCEncoder.encode(batch^)


def test_header_and_total_length() raises:
    var c = _fixture_chunk()
    assert_equal(c.len(), 280)
    assert_equal(Int(c.read_u32_le_at(12)), 2)  # n_cols
    assert_equal(Int(c.read_u64_le_at(16)), 176)  # body_length
    assert_equal(Int(c.read_u64_le_at(24)), 5)  # row_count
    assert_equal(Int(c.read_u32_le_at(44)), 96)  # descriptors_byte_len


def test_column_zero_descriptor() raises:
    var c = _fixture_chunk()
    assert_equal(Int(c.read_u32_le_at(D0 + 4)), 1)  # has_validity only
    assert_equal(Int(c.read_u64_le_at(D0 + 8)), 5)  # length
    assert_equal(Int(c.read_u64_le_at(D0 + 16)), 2)  # null_count
    assert_equal(Int(c.read_u64_le_at(D0 + 24)), 192)  # region_offset
    assert_equal(Int(c.read_u32_le_at(D0 + 32)), 1)  # validity_len
    assert_equal(Int(c.read_u32_le_at(D0 + 36)), 0)  # offsets_len
    assert_equal(Int(c.read_u64_le_at(D0 + 40)), 40)  # values_len


def test_column_one_descriptor() raises:
    var c = _fixture_chunk()
    assert_equal(Int(c.read_u32_le_at(D1 + 4)), 2)  # has_offsets only
    assert_equal(Int(c.read_u64_le_at(D1 + 8)), 5)
    assert_equal(Int(c.read_u64_le_at(D1 + 24)), 240)  # 8-aligned from 233
    assert_equal(Int(c.read_u32_le_at(D1 + 32)), 0)
    assert_equal(Int(c.read_u32_le_at(D1 + 36)), 24)  # (5 + 1) * 4
    assert_equal(Int(c.read_u64_le_at(D1 + 40)), 7)


def test_region_contents_and_padding() raises:
    var c = _fixture_chunk()
    # Validity bits: rows 0, 2, 4 valid -> 0b10101.
    assert_equal(Int(c.read_u8_at(192)), 0x15)
    # First value of column 0 follows the validity byte.
    assert_equal(Int(c.read_i64_le_at(193)), 10)
    # Pad bytes between the column regions (233..239) and the body tail (271).
    for i in range(233, 240):
        assert_equal(Int(c.read_u8_at(i)), 0)
    assert_equal(Int(c.read_u8_at(271)), 0)
    # Offsets of column 1 start at 240: 0, 2, 2, 5, 6, 7.
    assert_equal(Int(c.read_i32_le_at(240)), 0)
    assert_equal(Int(c.read_i32_le_at(244)), 2)
    assert_equal(Int(c.read_i32_le_at(260)), 7)
    # String bytes follow the offsets.
    assert_equal(Int(c.read_u8_at(264)), Int(ord("a")))


def test_trailing_magic_position() raises:
    var c = _fixture_chunk()
    var magic = List[Int]()
    magic.append(0x54)
    magic.append(0x48)
    magic.append(0x53)
    magic.append(0x50)
    magic.append(0x4C)
    magic.append(0x43)
    magic.append(0x01)
    magic.append(0x00)
    for i in range(8):
        assert_equal(Int(c.read_u8_at(272 + i)), magic[i])


def main() raises:
    var suite = TestSuite()
    suite.test[test_header_and_total_length]()
    suite.test[test_column_zero_descriptor]()
    suite.test[test_column_one_descriptor]()
    suite.test[test_region_contents_and_padding]()
    suite.test[test_trailing_magic_position]()
    suite^.run()
