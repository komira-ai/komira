# =============================================================================
# test_orc_write_int_sum_overflow.mojo — IntegerStatistics.sum on int64 overflow.
# =============================================================================
#
# Reference behaviour (Apache ORC Java, IntegerStatisticsImpl): the writer adds
# each value to `sum` with Math.addExact; the first ArithmeticException sets an
# `overflow` flag and summing stops. A merge ORs the flags first
# (`overflow |= other.overflow`) and, if still clear, adds the other sum with
# addExact, which can itself set the flag. Serialization writes field 3 (sum)
# only when the flag is clear. So the flag trips on ANY intermediate overflow,
# even when the final sum would fit, and once set it stays set through every
# merge (row-index entry, stripe, file).
#
# Every assertion here is on the protobuf bytes the writer produced
# (NONE codec), re-parsed field by field: a stats line is rendered as
# "n=<numberOfValues> min=<f1> max=<f2> sum=<f3 | absent>" and compared with
# full string equality.
#
# What each test proves, and the defect it catches:
#   * positive / negative overflow: [MAX, 1] and [MIN, -1] write no sum at
#     stripe and file level. Catches a wrapping sum (MIN / MAX written).
#   * intermediate overflow: [MAX, 1, MIN, 2] (final sum 2 would fit) and
#     [MAX, 1, -1] omit the sum; [MIN, MAX, 1, 2] (no step overflows) writes
#     sum 2. Catches a writer that checks only the final value, or a wider
#     accumulator narrowed at the end.
#   * exact boundaries: [MAX-3, 1, 2] writes sum MAX and [MIN+3, -1, -2]
#     writes sum MIN. Catches an off-by-one overflow test.
#   * merge, one stripe overflowed (stride 2): [MAX, 1, 5, 6] and
#     [5, 6, MAX, 1] — the overflowed stripe has no sum, the other has 11,
#     the file has none, in either order. Catches a merge that drops the
#     flag of either side.
#   * merge overflows only at file level: [MAX, 0, 1, 0] — stripe sums MAX
#     and 1 are written, the file sum is absent. Catches an unchecked merge.
#   * row-index entries: one stripe of two strides [MAX, 1, 5, 6] — entry 0
#     has no sum, entry 1 has 11, stripe and file have none.
#   * nullable column: [MAX, null, 1, null, 5, 6] with stride 4 runs the
#     null-guarded accumulation loops (stripe stats in `_emit_integer`,
#     row-index stats in `_compute_chunk_stats`), which are separate code
#     from the all-valid loops above. Entry 0 (MAX, 1) has no sum, entry 1
#     (5, 6) has 11, stripe and file have none; lines carry hasNull.
#     Catches a wrapping add on the nullable paths only.
# =============================================================================

from std.testing import assert_equal

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_core.arrow.schema import SchemaBuilder, Field

from komira_orc import (
    OrcWriterOptions,
    write_orc_bytes,
    OrcFileTail,
    StripeFooter,
    pb_read_tag,
    pb_read_varint,
    pb_read_len_field,
    pb_skip_field,
    zigzag_decode,
    PB_WIRE_VARINT,
    PB_WIRE_LEN,
    ORC_COMPRESSION_NONE,
    ORC_STREAM_ROW_INDEX,
)


comptime MAX = Int64.MAX
comptime MIN = Int64.MIN


def _batch(vals: List[Int64]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.INT64, False))
    var a = PrimitiveArray[DType.int64].allocate(len(vals))
    for i in range(len(vals)):
        a.set(i, vals[i])
    var builder = RecordBatchBuilder.with_capacity(1)
    builder.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](a^, ArrowType.INT64)
    )
    return builder.build(sb.build())


def _write(vals: List[Int64], stride: Int) raises -> List[UInt8]:
    """One stripe per `stride` rows, no row index."""
    return write_orc_bytes(
        _batch(vals), OrcWriterOptions(ORC_COMPRESSION_NONE, stride, String("UTC"))
    )


def _len_fields(
    bs: Span[UInt8, _], start: Int, end: Int, field: Int
) raises -> List[Tuple[Int, Int]]:
    """(start, end) of each length-delimited occurrence of `field`."""
    var out = List[Tuple[Int, Int]]()
    var pos = start
    while pos < end:
        var tag = pb_read_tag(bs, pos)
        pos = tag.new_pos
        if tag.field_number == field and tag.wire_type == PB_WIRE_LEN:
            var f = pb_read_len_field(bs, pos)
            out.append((f.payload_start, f.payload_end))
            pos = f.new_pos
        else:
            pos = pb_skip_field(bs, pos, tag.wire_type)
    return out^


def _render(
    bs: Span[UInt8, _], start: Int, end: Int, with_has_null: Bool = False
) raises -> String:
    """A ColumnStatistics message as "n=.. min=.. max=.. sum=..|absent",
    followed by " hasNull=<f10 | absent>" when `with_has_null`."""
    var n = -1
    var hn = String("absent")
    var has_int = False
    var mn = String("absent")
    var mx = String("absent")
    var sm = String("absent")
    var pos = start
    while pos < end:
        var tag = pb_read_tag(bs, pos)
        pos = tag.new_pos
        if tag.field_number == 1 and tag.wire_type == PB_WIRE_VARINT:
            var v = pb_read_varint(bs, pos)
            n = Int(v.value)
            pos = v.new_pos
        elif tag.field_number == 10 and tag.wire_type == PB_WIRE_VARINT:
            var v = pb_read_varint(bs, pos)
            hn = String(v.value)
            pos = v.new_pos
        elif tag.field_number == 2 and tag.wire_type == PB_WIRE_LEN:
            var f = pb_read_len_field(bs, pos)
            has_int = True
            var p = f.payload_start
            while p < f.payload_end:
                var t = pb_read_tag(bs, p)
                p = t.new_pos
                if t.wire_type != PB_WIRE_VARINT:
                    raise Error("IntegerStatistics: non-varint field")
                var v = pb_read_varint(bs, p)
                p = v.new_pos
                var d = String(zigzag_decode(v.value))
                if t.field_number == 1:
                    mn = d
                elif t.field_number == 2:
                    mx = d
                elif t.field_number == 3:
                    sm = d
            pos = f.new_pos
        else:
            pos = pb_skip_field(bs, pos, tag.wire_type)
    var suffix = String(" hasNull=") + hn if with_has_null else String("")
    if not has_int:
        return String("n=") + String(n) + " no-intStatistics" + suffix
    return (
        String("n=") + String(n) + " min=" + mn + " max=" + mx + " sum=" + sm
        + suffix
    )


def _stripe_lines(
    bytes: List[UInt8], with_has_null: Bool = False
) raises -> List[String]:
    """Column 1's stats in each Metadata.stripeStats entry, in stripe order."""
    var bs = Span(bytes)
    var tail = OrcFileTail.parse(bs)
    var out = List[String]()
    var stripes = _len_fields(bs, tail.metadata_start, tail.metadata_end, 1)
    for s in range(len(stripes)):
        var cols = _len_fields(bs, stripes[s][0], stripes[s][1], 1)
        out.append(_render(bs, cols[1][0], cols[1][1], with_has_null))
    return out^


def _file_line(bytes: List[UInt8], with_has_null: Bool = False) raises -> String:
    """Column 1's stats in Footer.statistics (field 7)."""
    var bs = Span(bytes)
    var tail = OrcFileTail.parse(bs)
    var cols = _len_fields(bs, tail.footer_start, tail.footer_end, 7)
    return _render(bs, cols[1][0], cols[1][1], with_has_null)


def _row_index_lines(
    bytes: List[UInt8], with_has_null: Bool = False
) raises -> List[String]:
    """Column 1's RowIndexEntry.statistics in stripe 0's ROW_INDEX stream.
    Streams lie back to back from the stripe offset in stripe-footer order."""
    var bs = Span(bytes)
    var tail = OrcFileTail.parse(bs)
    ref si = tail.footer.stripes[0]
    var fstart = si.offset + si.index_length + si.data_length
    var sf = StripeFooter.parse(bs[fstart : fstart + si.footer_length])
    var off = si.offset
    var out = List[String]()
    for k in range(len(sf.streams)):
        if sf.streams[k].column == 1 and sf.streams[k].kind == ORC_STREAM_ROW_INDEX:
            var end = off + sf.streams[k].length
            var entries = _len_fields(bs, off, end, 1)
            for e in range(len(entries)):
                var st = _len_fields(bs, entries[e][0], entries[e][1], 2)
                out.append(_render(bs, st[0][0], st[0][1], with_has_null))
            return out^
        off += sf.streams[k].length
    raise Error("no ROW_INDEX stream for column 1")


def _l(*vals: Int64) -> List[Int64]:
    var out = List[Int64]()
    for i in range(len(vals)):
        out.append(vals[i])
    return out^


def _check_single_stripe(vals: List[Int64], want: String, label: String) raises:
    var bytes = _write(vals, 10000)
    var stripes = _stripe_lines(bytes)
    assert_equal(len(stripes), 1, label + ": stripe count")
    assert_equal(stripes[0], want, label + ": stripe stats")
    assert_equal(_file_line(bytes), want, label + ": file stats")


def test_positive_overflow_omits_sum() raises:
    _check_single_stripe(
        _l(MAX, 1),
        "n=2 min=1 max=9223372036854775807 sum=absent",
        "[MAX, 1]",
    )


def test_negative_overflow_omits_sum() raises:
    _check_single_stripe(
        _l(MIN, -1),
        "n=2 min=-9223372036854775808 max=-1 sum=absent",
        "[MIN, -1]",
    )


def test_intermediate_overflow_omits_sum() raises:
    # MAX + 1 overflows at row 1; the final sum (2) would fit. Java flags it.
    _check_single_stripe(
        _l(MAX, 1, MIN, 2),
        "n=4 min=-9223372036854775808 max=9223372036854775807 sum=absent",
        "[MAX, 1, MIN, 2]",
    )
    # MAX + 1 overflows; the final sum (MAX) would fit.
    _check_single_stripe(
        _l(MAX, 1, -1),
        "n=3 min=-1 max=9223372036854775807 sum=absent",
        "[MAX, 1, -1]",
    )
    # No running sum overflows: MIN + MAX = -1, then 0, then 2.
    _check_single_stripe(
        _l(MIN, MAX, 1, 2),
        "n=4 min=-9223372036854775808 max=9223372036854775807 sum=2",
        "[MIN, MAX, 1, 2]",
    )


def test_exact_boundaries_keep_sum() raises:
    _check_single_stripe(
        _l(MAX - 3, 1, 2),
        "n=3 min=1 max=9223372036854775804 sum=9223372036854775807",
        "[MAX-3, 1, 2]",
    )
    _check_single_stripe(
        _l(MIN + 3, -1, -2),
        "n=3 min=-9223372036854775805 max=-1 sum=-9223372036854775808",
        "[MIN+3, -1, -2]",
    )
    _check_single_stripe(
        _l(10, 3, 100, -7, 50), "n=5 min=-7 max=100 sum=156", "small"
    )


def test_merge_with_one_overflowed_stripe() raises:
    var a = _write(_l(MAX, 1, 5, 6), 2)
    var sa = _stripe_lines(a)
    assert_equal(len(sa), 2, "overflow first: stripe count")
    assert_equal(
        sa[0], "n=2 min=1 max=9223372036854775807 sum=absent",
        "overflow first: stripe 0",
    )
    assert_equal(sa[1], "n=2 min=5 max=6 sum=11", "overflow first: stripe 1")
    assert_equal(
        _file_line(a), "n=4 min=1 max=9223372036854775807 sum=absent",
        "overflow first: file",
    )

    var b = _write(_l(5, 6, MAX, 1), 2)
    var sb = _stripe_lines(b)
    assert_equal(len(sb), 2, "overflow second: stripe count")
    assert_equal(sb[0], "n=2 min=5 max=6 sum=11", "overflow second: stripe 0")
    assert_equal(
        sb[1], "n=2 min=1 max=9223372036854775807 sum=absent",
        "overflow second: stripe 1",
    )
    assert_equal(
        _file_line(b), "n=4 min=1 max=9223372036854775807 sum=absent",
        "overflow second: file",
    )


def test_merge_overflows_at_file_level_only() raises:
    var bytes = _write(_l(MAX, 0, 1, 0), 2)
    var s = _stripe_lines(bytes)
    assert_equal(len(s), 2, "file-only overflow: stripe count")
    assert_equal(
        s[0], "n=2 min=0 max=9223372036854775807 sum=9223372036854775807",
        "file-only overflow: stripe 0",
    )
    assert_equal(s[1], "n=2 min=0 max=1 sum=1", "file-only overflow: stripe 1")
    assert_equal(
        _file_line(bytes), "n=4 min=0 max=9223372036854775807 sum=absent",
        "file-only overflow: file",
    )


def test_row_index_entries() raises:
    # One stripe of 4 rows, two strides of 2, ROW_INDEX on.
    var opts = OrcWriterOptions(ORC_COMPRESSION_NONE, 2, String("UTC"), 4, True)
    var bytes = write_orc_bytes(_batch(_l(MAX, 1, 5, 6)), opts)
    var ri = _row_index_lines(bytes)
    assert_equal(len(ri), 2, "row index: entry count")
    assert_equal(
        ri[0], "n=2 min=1 max=9223372036854775807 sum=absent",
        "row index: entry 0",
    )
    assert_equal(ri[1], "n=2 min=5 max=6 sum=11", "row index: entry 1")
    var s = _stripe_lines(bytes)
    assert_equal(len(s), 1, "row index: stripe count")
    assert_equal(
        s[0], "n=4 min=1 max=9223372036854775807 sum=absent",
        "row index: stripe",
    )
    assert_equal(
        _file_line(bytes), "n=4 min=1 max=9223372036854775807 sum=absent",
        "row index: file",
    )


def test_nullable_column() raises:
    # Rows: MAX, null, 1, null, 5, 6. Stride 4, one stripe of 6 rows, so
    # stride 0 = [MAX, null, 1, null] and stride 1 = [5, 6].
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.INT64, True))
    var a = PrimitiveArray[DType.int64].allocate_nullable(6)
    a.set(0, MAX)
    a._set_null(1)
    a.set(2, Int64(1))
    a._set_null(3)
    a.set(4, Int64(5))
    a.set(5, Int64(6))
    assert_equal(a.null_count, 2, "nullable: null_count")
    var builder = RecordBatchBuilder.with_capacity(1)
    builder.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](a^, ArrowType.INT64)
    )
    var batch = builder.build(sb.build())
    var opts = OrcWriterOptions(ORC_COMPRESSION_NONE, 4, String("UTC"), 6, True)
    var bytes = write_orc_bytes(batch, opts)
    var ri = _row_index_lines(bytes, True)
    assert_equal(len(ri), 2, "nullable: entry count")
    assert_equal(
        ri[0], "n=2 min=1 max=9223372036854775807 sum=absent hasNull=1",
        "nullable: row index entry 0",
    )
    assert_equal(
        ri[1], "n=2 min=5 max=6 sum=11 hasNull=0",
        "nullable: row index entry 1",
    )
    var s = _stripe_lines(bytes, True)
    assert_equal(len(s), 1, "nullable: stripe count")
    assert_equal(
        s[0], "n=4 min=1 max=9223372036854775807 sum=absent hasNull=1",
        "nullable: stripe",
    )
    assert_equal(
        _file_line(bytes, True),
        "n=4 min=1 max=9223372036854775807 sum=absent hasNull=1",
        "nullable: file",
    )


def main() raises:
    test_positive_overflow_omits_sum()
    test_negative_overflow_omits_sum()
    test_intermediate_overflow_omits_sum()
    test_exact_boundaries_keep_sum()
    test_merge_with_one_overflowed_stripe()
    test_merge_overflows_at_file_level_only()
    test_row_index_entries()
    test_nullable_column()
    print("test_orc_write_int_sum_overflow: ALL PASS")
