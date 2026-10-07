# =============================================================================
# test_orc_write_statistics.mojo — ORC writer per-file + per-stripe statistics.
# =============================================================================
#
# Acceptance: the writer emits Footer.statistics (per-file, field 7) +
# Metadata.stripeStats (per-stripe). This test re-parses the NONE-codec Footer
# bytes via the exported protobuf primitives and asserts the file-level
# IntegerStatistics min/max/sum + ColumnStatistics numberOfValues/hasNull are
# present and correct for an integer column.
#
# ColumnStatistics: 1 numberOfValues (uint64) 2 IntegerStatistics 10 hasNull.
# IntegerStatistics: 1 minimum 2 maximum 3 sum (ALL sint64 -> zigzag).
# Footer: field 7 = repeated ColumnStatistics (root + each column, in node order).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema, SchemaBuilder, Field

from komira_orc import (
    OrcWriterOptions,
    write_orc_bytes,
    OrcFileTail,
    PostScript,
    pb_read_tag,
    pb_read_varint,
    pb_read_len_field,
    zigzag_decode,
    PB_WIRE_VARINT,
    PB_WIRE_LEN,
    ORC_COMPRESSION_NONE,
)


def _build_batch() raises -> RecordBatch:
    var n = 5
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.INT64, True))
    var a = PrimitiveArray[DType.int64].allocate(n)
    a.set(0, Int64(10)); a.set(1, Int64(3)); a.set(2, Int64(100))
    a.set(3, Int64(-7)); a.set(4, Int64(50))
    var builder = RecordBatchBuilder.with_capacity(1)
    builder.add_column(Column.from_primitive_with_arrow_type[DType.int64](a^, ArrowType.INT64))
    return builder.build(sb.build())


@fieldwise_init
struct _IntStat(Copyable, Movable):
    var num_values: Int
    var has_null: Bool
    var minimum: Int64
    var maximum: Int64
    var sum: Int64
    var found_int: Bool


def _parse_integer_statistics(
    bytes: Span[UInt8, _], start: Int, end: Int
) raises -> _IntStat:
    var mn: Int64 = 0
    var mx: Int64 = 0
    var sm: Int64 = 0
    var pos = start
    while pos < end:
        var tag = pb_read_tag(bytes, pos)
        pos = tag.new_pos
        var v = pb_read_varint(bytes, pos)
        pos = v.new_pos
        if tag.field_number == 1:
            mn = zigzag_decode(v.value)
        elif tag.field_number == 2:
            mx = zigzag_decode(v.value)
        elif tag.field_number == 3:
            sm = zigzag_decode(v.value)
    return _IntStat(0, False, mn, mx, sm, True)


def _parse_column_statistics(
    bytes: Span[UInt8, _], start: Int, end: Int
) raises -> _IntStat:
    var num_values = 0
    var has_null = False
    var mn: Int64 = 0
    var mx: Int64 = 0
    var sm: Int64 = 0
    var found_int = False
    var pos = start
    while pos < end:
        var tag = pb_read_tag(bytes, pos)
        pos = tag.new_pos
        if tag.field_number == 1 and tag.wire_type == PB_WIRE_VARINT:
            var v = pb_read_varint(bytes, pos)
            num_values = Int(v.value)
            pos = v.new_pos
        elif tag.field_number == 2 and tag.wire_type == PB_WIRE_LEN:
            var f = pb_read_len_field(bytes, pos)
            var ist = _parse_integer_statistics(bytes, f.payload_start, f.payload_end)
            mn = ist.minimum; mx = ist.maximum; sm = ist.sum
            found_int = True
            pos = f.new_pos
        elif tag.field_number == 10 and tag.wire_type == PB_WIRE_VARINT:
            var v = pb_read_varint(bytes, pos)
            has_null = v.value != 0
            pos = v.new_pos
        else:
            # skip
            if tag.wire_type == PB_WIRE_VARINT:
                var v = pb_read_varint(bytes, pos)
                pos = v.new_pos
            elif tag.wire_type == PB_WIRE_LEN:
                var f = pb_read_len_field(bytes, pos)
                pos = f.new_pos
            else:
                raise Error("unexpected wire type in ColumnStatistics")
    return _IntStat(num_values, has_null, mn, mx, sm, found_int)


def _footer_column_stats(bytes: List[UInt8]) raises -> List[_IntStat]:
    """Re-parse a NONE-codec ORC file's Footer field 7 (repeated
    ColumnStatistics) into a list of parsed stats (root first, then columns)."""
    var n = len(bytes)
    var ps_len = Int(bytes[n - 1])
    var ps_start = n - 1 - ps_len
    var ps = PostScript.parse(Span(bytes)[ps_start : n - 1])
    var footer_end = ps_start
    var footer_start = footer_end - ps.footer_length

    var out = List[_IntStat]()
    var pos = footer_start
    var span = Span(bytes)
    while pos < footer_end:
        var tag = pb_read_tag(span, pos)
        pos = tag.new_pos
        if tag.field_number == 7 and tag.wire_type == PB_WIRE_LEN:
            var f = pb_read_len_field(span, pos)
            out.append(_parse_column_statistics(span, f.payload_start, f.payload_end))
            pos = f.new_pos
        elif tag.wire_type == PB_WIRE_VARINT:
            var v = pb_read_varint(span, pos)
            pos = v.new_pos
        elif tag.wire_type == PB_WIRE_LEN:
            var f = pb_read_len_field(span, pos)
            pos = f.new_pos
        else:
            raise Error("unexpected wire type in Footer")
    return out^


def test_orc_write_statistics_file_level() raises:
    var rb = _build_batch()
    var opts = OrcWriterOptions(ORC_COMPRESSION_NONE, 10000, String("UTC"))
    var bytes = write_orc_bytes(rb, opts)

    var stats = _footer_column_stats(bytes)
    # node 0 = root struct, node 1 = the int64 column.
    assert_true(len(stats) >= 2, "at least root + 1 column stats")
    var col = stats[1].copy()
    assert_true(col.found_int, "column 1 has IntegerStatistics")
    assert_equal(col.num_values, 5, "numberOfValues = 5")
    assert_equal(Int(col.minimum), -7, "min = -7")
    assert_equal(Int(col.maximum), 100, "max = 100")
    assert_equal(Int(col.sum), 156, "sum = 10+3+100-7+50 = 156")
    assert_true(not col.has_null, "no nulls")


def test_orc_write_statistics_per_stripe_present() raises:
    # Multi-stripe (stride=2 over 5 rows => 3 stripes). The Metadata blob
    # carries one StripeStatistics per stripe; we assert the file decodes back
    # (the per-stripe stats are emitted; the reader does not surface them, so
    # the strongest self-contained check is that the Metadata length is
    # non-zero in the PostScript).
    var rb = _build_batch()
    var opts = OrcWriterOptions(ORC_COMPRESSION_NONE, 2, String("UTC"))
    var bytes = write_orc_bytes(rb, opts)
    var n = len(bytes)
    var ps_len = Int(bytes[n - 1])
    var ps_start = n - 1 - ps_len
    var ps = PostScript.parse(Span(bytes)[ps_start : n - 1])
    assert_true(ps.metadata_length > 0, "Metadata (stripe stats) blob present")
    var tail = OrcFileTail.parse(Span(bytes))
    assert_true(tail.num_stripes() >= 3, ">= 3 stripes for stride=2/5rows")


def main() raises:
    test_orc_write_statistics_file_level()
    test_orc_write_statistics_per_stripe_present()
    print("test_orc_write_statistics: ALL PASS")
