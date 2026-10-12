# =============================================================================
# test_orc_sub_message_bound.mojo — every footer sub-message parser reads its
# tags, varints, fixed64s and LEN fields inside its own [start, end), never
# from the sibling field that follows it in the parent message.
# =============================================================================
#
# Each `parse(bytes, start, end)` / `_parse_*` loop in footer.mojo walks one
# sub-message. A read that starts inside the sub-message and runs past `end`
# must raise a MALFORMED error. Before komira-ai/komira#1259 the primitives
# were bounded only by `len(bytes)`, so such a read consumed the parent's next
# field and the inner message decoded it as its own value.
#
# Every case below places the overrun on a SIBLING FIELD INSIDE THE PARENT,
# not past the end of the buffer, and parses through the parent. That is the
# only input that tells "bounded by the sub-message end" from "bounded by the
# buffer end": a buffer-end overrun raised before the fix too. Before the fix
# every B and S case decoded and the parent then re-parsed the sibling as a
# valid field, so none raised; each docstring says what it decoded. G1 and G2
# guard the fix (no off-by-one, no clamping) and passed before it.
#
# Coverage (one case per loop; B4 and S1b add a tag and a LEN shape):
#   B1  StripeInformation (Footer.stripes): varint into Footer.numberOfRows.
#   B2  OrcRawType (Footer.types): varint into Footer.numberOfRows.
#   B3  OrcStripeStatistics (Metadata.stripeStats): LEN into the next entry.
#   B4  OrcColumnStatistics (RowIndexEntry.statistics): varint into the
#       entry's next positions field.
#   B4b OrcRowIndexEntry, the issue's own shape: varint 0x80 at the message
#       end with 0x01 the byte after it.
#   B5  _parse_int_statistics: varint into ColumnStatistics.hasNull.
#   B6  _parse_double_statistics: fixed64 into four hasNull fields.
#   B7  _parse_string_statistics: LEN into ColumnStatistics.hasNull.
#   B8  OrcRowIndexEntry (RowIndex.entry): varint into the next entry.
#   B9  OrcBloomFilterEntry (BloomFilterIndex): varint into the next entry.
#   S1  OrcStream (StripeFooter.streams): varint into StripeFooter.columns.
#   S1b OrcStream: a two-byte tag straddling the stream end.
#   S2  OrcColumnEncoding (StripeFooter.columns): varint into the timezone.
#   G1  Well-formed nested messages ending exactly at their ends still decode.
#   G2  A sub-message range outside the buffer is refused, not clamped.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_orc import (
    Footer,
    Metadata,
    OrcBloomFilterIndex,
    OrcColumnStatistics,
    OrcRowIndex,
    OrcRowIndexEntry,
    StripeFooter,
)


def _assert_malformed(err: Error) raises:
    var msg = String(err)
    assert_true(
        "MALFORMED" in msg,
        String("expected a MALFORMED refusal, got: ") + msg,
    )


def _bytes(var v: List[Int]) -> List[UInt8]:
    var out = List[UInt8]()
    for x in v:
        out.append(UInt8(x))
    return out^


def test_stripe_information() raises:
    """B1: stripe payload [0x08]; 0x30 0x07 is Footer.numberOfRows = 7.
    Before the fix: stripes[0].offset == 48 (the sibling's tag byte)."""
    var b = _bytes([0x1A, 0x01, 0x08, 0x30, 0x07])
    var raised = False
    try:
        var f = Footer.parse(Span(b))
        print("B1 decoded offset:", f.stripes[0].offset)
    except err:
        _assert_malformed(err)
        raised = True
    assert_true(raised, "StripeInformation read past its end")


def test_raw_type() raises:
    """B2: type payload [0x08]; 0x30 0x07 is Footer.numberOfRows = 7.
    Before the fix: types[0].kind == 48."""
    var b = _bytes([0x22, 0x01, 0x08, 0x30, 0x07])
    var raised = False
    try:
        var f = Footer.parse(Span(b))
        print("B2 decoded kind:", f.types[0].kind)
    except err:
        _assert_malformed(err)
        raised = True
    assert_true(raised, "OrcRawType read past its end")


def test_stripe_statistics() raises:
    """B3: StripeStatistics payload [0x0A 0x02] declares a 2-byte colStats
    that runs over the next Metadata entry [0x0A 0x00]. Before the fix:
    per_stripe_stats[0].col_stats had 1 entry built from the sibling."""
    var b = _bytes([0x0A, 0x02, 0x0A, 0x02, 0x0A, 0x00])
    var raised = False
    try:
        var m = Metadata.parse(Span(b))
        print("B3 decoded col_stats:", len(m.per_stripe_stats[0].col_stats))
    except err:
        _assert_malformed(err)
        raised = True
    assert_true(raised, "OrcStripeStatistics read past its end")


def test_column_statistics() raises:
    """B4: statistics payload [0x08]; 0x08 0x05 is the entry's next
    positions field. Before the fix: number_of_values == 8."""
    var b = _bytes([0x12, 0x01, 0x08, 0x08, 0x05])
    var raised = False
    try:
        var e = OrcRowIndexEntry.parse(Span(b), 0, 5)
        print("B4 decoded number_of_values:", e.statistics.number_of_values)
    except err:
        _assert_malformed(err)
        raised = True
    assert_true(raised, "OrcColumnStatistics read past its end")


def test_row_index_entry_issue_shape() raises:
    """B4b: entry [0x08 0x80] with 0x01 after it. Before the fix:
    positions == [128]."""
    var b = _bytes([0x08, 0x80, 0x01])
    var raised = False
    try:
        var e = OrcRowIndexEntry.parse(Span(b), 0, 2)
        print("B4b decoded position:", e.positions[0])
    except err:
        _assert_malformed(err)
        raised = True
    assert_true(raised, "OrcRowIndexEntry read past its end (issue shape)")


def test_int_statistics() raises:
    """B5: intStatistics payload [0x08]; 0x50 0x01 is hasNull = true.
    Before the fix: has_int and int_min == 40 (zigzag of 0x50)."""
    var b = _bytes([0x12, 0x01, 0x08, 0x50, 0x01])
    var raised = False
    try:
        var s = OrcColumnStatistics.parse(Span(b), 0, 5)
        print("B5 decoded int_min:", s.int_min)
    except err:
        _assert_malformed(err)
        raised = True
    assert_true(raised, "_parse_int_statistics read past its end")


def test_double_statistics() raises:
    """B6: doubleStatistics payload [0x09] (field 1, fixed64); the next 8
    bytes are four hasNull fields. Before the fix: has_double, with dbl_min
    the bit pattern of those 8 bytes."""
    var b = _bytes(
        [0x1A, 0x01, 0x09, 0x50, 0x01, 0x50, 0x01, 0x50, 0x01, 0x50, 0x01]
    )
    var raised = False
    try:
        var s = OrcColumnStatistics.parse(Span(b), 0, 11)
        print("B6 decoded dbl_min:", s.dbl_min)
    except err:
        _assert_malformed(err)
        raised = True
    assert_true(raised, "_parse_double_statistics read past its end")


def test_string_statistics() raises:
    """B7: stringStatistics payload [0x0A 0x02] (minimum, 2 bytes); the 2
    bytes are 0x50 0x01, hasNull = true. Before the fix: str_min == "P\\x01".
    """
    var b = _bytes([0x22, 0x02, 0x0A, 0x02, 0x50, 0x01])
    var raised = False
    try:
        var s = OrcColumnStatistics.parse(Span(b), 0, 6)
        print("B7 decoded str_min bytes:", s.str_min.byte_length())
    except err:
        _assert_malformed(err)
        raised = True
    assert_true(raised, "_parse_string_statistics read past its end")


def test_row_index_entry() raises:
    """B8: entry payload [0x08]; 0x0A 0x00 is the next (empty) entry.
    Before the fix: entries[0].positions == [10]."""
    var b = _bytes([0x0A, 0x01, 0x08, 0x0A, 0x00])
    var raised = False
    try:
        var ri = OrcRowIndex.parse(Span(b))
        print("B8 decoded position:", ri.entries[0].positions[0])
    except err:
        _assert_malformed(err)
        raised = True
    assert_true(raised, "OrcRowIndexEntry read past its end")


def test_bloom_filter_entry() raises:
    """B9: bloom payload [0x08]; 0x0A 0x00 is the next (empty) bloom.
    Before the fix: entries[0].num_hash_functions == 10."""
    var b = _bytes([0x0A, 0x01, 0x08, 0x0A, 0x00])
    var raised = False
    try:
        var bi = OrcBloomFilterIndex.parse(Span(b))
        print("B9 decoded hashes:", bi.entries[0].num_hash_functions)
    except err:
        _assert_malformed(err)
        raised = True
    assert_true(raised, "OrcBloomFilterEntry read past its end")


def test_stream() raises:
    """S1: stream payload [0x18] (length tag); 0x12 0x00 is an empty
    StripeFooter.columns entry. Before the fix: streams[0].length == 18."""
    var b = _bytes([0x0A, 0x01, 0x18, 0x12, 0x00])
    var raised = False
    try:
        var sf = StripeFooter.parse(Span(b))
        print("S1 decoded length:", sf.streams[0].length)
    except err:
        _assert_malformed(err)
        raised = True
    assert_true(raised, "OrcStream read past its end")


def test_stream_tag_straddle() raises:
    """S1b: stream payload [0x80], the first byte of a two-byte tag whose
    second byte is the sibling's 0x12. Before the fix: tag field 288 was
    read and skipped, and the stream decoded with all fields 0."""
    var b = _bytes([0x0A, 0x01, 0x80, 0x12, 0x00])
    var raised = False
    try:
        var sf = StripeFooter.parse(Span(b))
        print("S1b decoded streams:", len(sf.streams))
    except err:
        _assert_malformed(err)
        raised = True
    assert_true(raised, "OrcStream tag read past its end")


def test_column_encoding() raises:
    """S2: encoding payload [0x10] (dictionarySize tag); 0x1A 0x00 is an
    empty writerTimezone. Before the fix: columns[0].dictionary_size == 26.
    """
    var b = _bytes([0x12, 0x01, 0x10, 0x1A, 0x00])
    var raised = False
    try:
        var sf = StripeFooter.parse(Span(b))
        print("S2 decoded dictionary_size:", sf.columns[0].dictionary_size)
    except err:
        _assert_malformed(err)
        raised = True
    assert_true(raised, "OrcColumnEncoding read past its end")


def test_well_formed_nested_still_decodes() raises:
    """G1: each nested field ends exactly at its message end; the bound is
    the end itself, not one byte short of it."""
    # ColumnStatistics { intStatistics { min = -1, max = 2 }, hasNull }.
    var s_bytes = _bytes([0x12, 0x04, 0x08, 0x01, 0x10, 0x04, 0x50, 0x01])
    var s = OrcColumnStatistics.parse(Span(s_bytes), 0, 8)
    assert_true(s.has_int)
    assert_equal(s.int_min, Int64(-1))
    assert_equal(s.int_max, Int64(2))
    assert_true(s.has_null)

    # StripeFooter { streams { kind 1, column 2, length 300 }, timezone "Z" }.
    var f_bytes = _bytes(
        [0x0A, 0x07, 0x08, 0x01, 0x10, 0x02, 0x18, 0xAC, 0x02, 0x1A, 0x01, 0x5A]
    )
    var sf = StripeFooter.parse(Span(f_bytes))
    assert_equal(len(sf.streams), 1)
    assert_equal(sf.streams[0].kind, 1)
    assert_equal(sf.streams[0].column, 2)
    assert_equal(sf.streams[0].length, 300)
    assert_equal(sf.writer_timezone, "Z")


def test_range_outside_buffer_refused() raises:
    """G2: a caller-supplied end past the buffer is refused, not clamped."""
    var b = _bytes([0x08, 0x05])
    var raised = False
    try:
        _ = OrcRowIndexEntry.parse(Span(b), 0, 3)
    except err:
        _assert_malformed(err)
        raised = True
    assert_true(raised, "sub-message end past the buffer accepted")


def main() raises:
    # Each case runs even when an earlier one fails, so a red run names
    # every loop that still reads past its end.
    var failed = 0
    try:
        test_stripe_information()
    except err:
        print("FAIL B1 StripeInformation:", err)
        failed += 1
    try:
        test_raw_type()
    except err:
        print("FAIL B2 OrcRawType:", err)
        failed += 1
    try:
        test_stripe_statistics()
    except err:
        print("FAIL B3 OrcStripeStatistics:", err)
        failed += 1
    try:
        test_column_statistics()
    except err:
        print("FAIL B4 OrcColumnStatistics:", err)
        failed += 1
    try:
        test_row_index_entry_issue_shape()
    except err:
        print("FAIL B4b OrcRowIndexEntry issue shape:", err)
        failed += 1
    try:
        test_int_statistics()
    except err:
        print("FAIL B5 _parse_int_statistics:", err)
        failed += 1
    try:
        test_double_statistics()
    except err:
        print("FAIL B6 _parse_double_statistics:", err)
        failed += 1
    try:
        test_string_statistics()
    except err:
        print("FAIL B7 _parse_string_statistics:", err)
        failed += 1
    try:
        test_row_index_entry()
    except err:
        print("FAIL B8 OrcRowIndexEntry:", err)
        failed += 1
    try:
        test_bloom_filter_entry()
    except err:
        print("FAIL B9 OrcBloomFilterEntry:", err)
        failed += 1
    try:
        test_stream()
    except err:
        print("FAIL S1 OrcStream:", err)
        failed += 1
    try:
        test_stream_tag_straddle()
    except err:
        print("FAIL S1b OrcStream tag:", err)
        failed += 1
    try:
        test_column_encoding()
    except err:
        print("FAIL S2 OrcColumnEncoding:", err)
        failed += 1
    try:
        test_well_formed_nested_still_decodes()
    except err:
        print("FAIL G1 well-formed nested:", err)
        failed += 1
    try:
        test_range_outside_buffer_refused()
    except err:
        print("FAIL G2 range outside buffer:", err)
        failed += 1
    if failed != 0:
        raise Error(String(failed) + " sub-message bound case(s) failed")
    print("test_orc_sub_message_bound: ALL PASS")
