# =============================================================================
# The light footer parses: parse_metadata_header_and_schema (num_rows, the
# schema and the ARROW:schema value) and parse_metadata_num_rows_only.
#
# What each test proves:
#   * the header parse stops as soon as both num_rows and the schema are read
#     (bytes_consumed is the offset just past them, not the footer's end), a
#     0-row file included, and `early_exit=False` walks the whole footer with
#     the same result;
#   * a writer that puts row_groups first gets the full walk, not a wrong
#     answer;
#   * the backward ARROW:schema search finds the value, reports its cost as
#     the tail distance (or the whole footer when absent), and returns ""
#     for every near miss: no 0x0C length byte before the key, a key that
#     differs in its last byte, a value of the wrong type, an empty value, a
#     value longer than the footer (a length near Int.MAX included, whose
#     `pos + len` bound wrapped and aborted the process), a header cut off by
#     the end of the bytes;
#   * the 32-byte pre-filter skips windows with no 'A' and falls back to the
#     byte-by-byte check where one holds an 'A' (the answer is the same);
#   * the num_rows-only parse stops at field 3 and never searches.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_buffer.byte_view import ByteView
from komira_parquet.footer_header import (
    find_arrow_schema_value,
    find_arrow_schema_value_counted,
    parse_metadata_header_and_schema,
    parse_metadata_num_rows_only,
)


def _view[
    mut: Bool, //, o: Origin[mut=mut]
](data: Span[UInt8, o]) -> ByteView[o]:
    return ByteView[o](data.unsafe_ptr(), len(data))


def _uleb(mut out: List[UInt8], v: Int):
    var x = UInt64(v)
    while x >= 0x80:
        out.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    out.append(UInt8(x))


def _fh(mut out: List[UInt8], delta: Int, wire_type: Int):
    out.append(UInt8((delta << 4) | wire_type))


def _zz(mut out: List[UInt8], v: Int):
    _uleb(out, (v << 1) ^ (v >> 63))


def _text(mut out: List[UInt8], s: String):
    _uleb(out, s.byte_length())
    for b in s.as_bytes():
        out.append(b)


def _schema(mut out: List[UInt8], delta: Int):
    """Field `prev + delta`: a list of two SchemaElements (root, "id")."""
    _fh(out, delta, 9)
    out.append(0x2C)
    _fh(out, 4, 8)  # root: name
    _text(out, "schema")
    _fh(out, 1, 5)  # num_children 1
    _zz(out, 1)
    out.append(0x00)
    _fh(out, 4, 8)  # name "id"
    _text(out, "id")
    out.append(0x00)


def _row_groups(mut out: List[UInt8], delta: Int):
    """Field `prev + delta`: a list of 20 row groups with a few fields each,
    long enough that walking it is visible in bytes_consumed."""
    _fh(out, delta, 9)
    out.append(0xFC)
    _uleb(out, 20)
    for _ in range(20):
        _fh(out, 2, 6)
        _zz(out, 4096)
        _fh(out, 1, 6)
        _zz(out, 100)
        out.append(0x00)


def _kv(mut out: List[UInt8], delta: Int, key: String, value: String):
    """Field `prev + delta`: key_value_metadata with one pair."""
    _fh(out, delta, 9)
    out.append(0x1C)
    _fh(out, 1, 8)
    _text(out, key)
    _fh(out, 1, 8)
    _text(out, value)
    out.append(0x00)


def _footer(num_rows: Int, key: String, value: String) -> Tuple[List[UInt8], Int]:
    """A footer in field-id order; also returns the offset just past num_rows."""
    var out = List[UInt8]()
    _fh(out, 1, 5)
    _zz(out, 2)
    _schema(out, 1)
    _fh(out, 1, 6)
    _zz(out, num_rows)
    var after = len(out)
    _row_groups(out, 1)
    _kv(out, 1, key, value)
    _fh(out, 1, 8)
    _text(out, "komira test")
    out.append(0x00)
    return (out^, after)


def test_header_parse_stops_after_schema_and_num_rows() raises:
    var f = _footer(500, "ARROW:schema", "QUJD")
    var footer = f[0].copy()
    var h = parse_metadata_header_and_schema(_view(Span(footer)))
    assert_equal(h.num_rows, 500)
    assert_equal(len(h.schema_elements), 2)
    assert_equal(h.schema_elements[1].name, "id")
    assert_equal(h.bytes_consumed, f[1])
    assert_equal(h.arrow_schema_value, "QUJD")
    # The search's cost is folded in: the key sits near the tail.
    var scan = find_arrow_schema_value_counted(_view(Span(footer)))
    assert_equal(h.bytes_examined, f[1] + scan.bytes_examined)
    assert_true(scan.bytes_examined < len(footer) // 2)


def test_header_parse_without_early_exit_walks_the_whole_footer() raises:
    var f = _footer(500, "other", "x")
    var footer = f[0].copy()
    var h = parse_metadata_header_and_schema(_view(Span(footer)), early_exit=False)
    assert_equal(h.num_rows, 500)
    assert_equal(len(h.schema_elements), 2)
    assert_equal(h.bytes_consumed, len(footer))
    assert_equal(h.arrow_schema_value, "")
    # No key: the search examined the whole footer.
    assert_equal(h.bytes_examined, len(footer) + len(footer))


def test_a_zero_row_file_still_stops_early() raises:
    var f = _footer(0, "other", "x")
    var footer = f[0].copy()
    var h = parse_metadata_header_and_schema(_view(Span(footer)))
    assert_equal(h.num_rows, 0)
    assert_equal(h.bytes_consumed, f[1])


def test_row_groups_first_gets_the_full_walk() raises:
    # row_groups (field 4) first; then fields 2 and 3, whose ids are below
    # 4, in the long header form.
    var out = List[UInt8]()
    _row_groups(out, 4)
    out.append(0x09)  # field id 2, list, long form
    _zz(out, 2)
    var tail = List[UInt8]()
    _schema(tail, 1)
    for i in range(1, len(tail)):
        out.append(tail[i])
    out.append(0x06)  # field id 3, i64, long form
    _zz(out, 3)
    _zz(out, 9)
    out.append(0x00)
    var h = parse_metadata_header_and_schema(_view(Span(out)))
    assert_equal(h.num_rows, 9)
    assert_equal(len(h.schema_elements), 2)
    assert_equal(h.bytes_consumed, len(out) - 1)


def test_header_parse_stop_and_end_of_bytes() raises:
    # STOP before num_rows: the schema alone, num_rows 0.
    var out = List[UInt8]()
    _schema(out, 2)
    out.append(0x00)
    out.append(0x16)  # never read
    var h = parse_metadata_header_and_schema(_view(Span(out)))
    assert_equal(len(h.schema_elements), 2)
    assert_equal(h.num_rows, 0)
    assert_equal(h.bytes_consumed, len(out) - 1)
    # The bytes end with no STOP and no schema: the walk ends there.
    var bare = List[UInt8]()
    _fh(bare, 3, 6)
    _zz(bare, 4)
    var h2 = parse_metadata_header_and_schema(_view(Span(bare)))
    assert_equal(h2.num_rows, 4)
    assert_equal(len(h2.schema_elements), 0)
    assert_equal(h2.bytes_consumed, len(bare))


def test_header_parse_refuses_a_schema_count_the_bytes_cannot_hold() raises:
    var out = List[UInt8]()
    _fh(out, 2, 9)
    out.append(0xFC)
    _uleb(out, 500)
    var raised = False
    try:
        _ = parse_metadata_header_and_schema(_view(Span(out)))
    except e:
        raised = String(e).find("list declares 500") >= 0
    assert_true(raised)


def test_a_wrong_wire_type_for_schema_or_num_rows_is_skipped() raises:
    var out = List[UInt8]()
    _fh(out, 2, 5)  # field 2 as an i32
    _zz(out, 1)
    _fh(out, 1, 5)  # field 3 as an i32
    _zz(out, 7)
    out.append(0x00)
    var h = parse_metadata_header_and_schema(_view(Span(out)))
    assert_equal(h.num_rows, 0)
    assert_equal(len(h.schema_elements), 0)


# ---- the ARROW:schema search -------------------------------------------------------


def _key_bytes(mut out: List[UInt8]):
    for b in String("ARROW:schema").as_bytes():
        out.append(b)


def test_search_absent_short_and_padded_inputs() raises:
    var tiny: List[UInt8] = [0x0C, 0x41]
    var s = find_arrow_schema_value_counted(_view(Span(tiny)))
    assert_equal(s.value, "")
    assert_equal(s.bytes_examined, 2)
    var empty = List[UInt8]()
    assert_equal(find_arrow_schema_value_counted(_view(Span(empty))).bytes_examined, 0)
    # 300 bytes with no 'A': every 32-byte window is skipped whole.
    var plain = List[UInt8](length=300, fill=0x0C)
    var s2 = find_arrow_schema_value_counted(_view(Span(plain)))
    assert_equal(s2.value, "")
    assert_equal(s2.bytes_examined, 300)
    # 300 bytes of 'A': no window is skipped; the byte check finds no key.
    var dense = List[UInt8](length=300, fill=0x41)
    assert_equal(find_arrow_schema_value_counted(_view(Span(dense))).value, "")


def _with_value(lead: Int, value_header: List[UInt8], trail: Int) -> List[UInt8]:
    """`lead` filler bytes, 0x0C + the key, the value bytes, `trail` filler."""
    var out = List[UInt8](length=lead, fill=0x00)
    out.append(0x0C)
    _key_bytes(out)
    for i in range(len(value_header)):
        out.append(value_header[i])
    for _ in range(trail):
        out.append(0x00)
    return out^


def test_search_finds_the_value_near_the_start_and_far_from_it() raises:
    var value = List[UInt8]()
    _fh(value, 1, 8)
    _text(value, "c2NoZW1h")
    # Key at offset 1: the scan's position is below 32, so only the
    # byte-by-byte check runs there.
    var near = _with_value(0, value, 1)
    var s = find_arrow_schema_value_counted(_view(Span(near)))
    assert_equal(s.value, "c2NoZW1h")
    assert_equal(s.bytes_examined, len(near) - 1)
    # Key behind 200 filler bytes and before 100 more.
    var far = _with_value(200, value, 100)
    var s2 = find_arrow_schema_value_counted(_view(Span(far)))
    assert_equal(s2.value, "c2NoZW1h")
    assert_equal(s2.bytes_examined, len(far) - 201)
    assert_equal(find_arrow_schema_value(_view(Span(far))), "c2NoZW1h")


def test_search_near_misses_return_empty() raises:
    # No 0x0C before the key.
    var value = List[UInt8]()
    _fh(value, 1, 8)
    _text(value, "dg==")
    var no_len = _with_value(40, value, 40)
    no_len[40] = 0x0D
    assert_equal(find_arrow_schema_value(_view(Span(no_len))), "")
    # The key's last byte differs.
    var off_by_one = _with_value(40, value, 40)
    off_by_one[52] = 0x62
    assert_equal(find_arrow_schema_value(_view(Span(off_by_one))), "")
    # The value is an i32, not binary.
    var wrong_type = List[UInt8]()
    _fh(wrong_type, 1, 5)
    _zz(wrong_type, 3)
    assert_equal(find_arrow_schema_value(_view(Span(_with_value(40, wrong_type, 40)))), "")
    # An empty value.
    var empty = List[UInt8]()
    _fh(empty, 1, 8)
    _uleb(empty, 0)
    assert_equal(find_arrow_schema_value(_view(Span(_with_value(40, empty, 40)))), "")
    # A value longer than the footer.
    var long_value = List[UInt8]()
    _fh(long_value, 1, 8)
    _uleb(long_value, 4000)
    assert_equal(find_arrow_schema_value(_view(Span(_with_value(40, long_value, 40)))), "")
    # A long-form header whose field id is cut off by the end of the bytes:
    # the reader raises inside, and the search reports "" without raising.
    var cut: List[UInt8] = [0x08]
    assert_equal(find_arrow_schema_value(_view(Span(_with_value(40, cut, 0)))), "")


def test_a_near_miss_after_the_key_does_not_hide_an_earlier_key() raises:
    # The search runs backward: a later fake key with no valid value is passed
    # over, and the real one before it is found.
    var good = List[UInt8]()
    _fh(good, 1, 8)
    _text(good, "UkVBTA==")
    var out = _with_value(10, good, 10)
    out.append(0x0C)
    _key_bytes(out)
    _fh(out, 1, 5)
    _zz(out, 1)
    out.append(0x00)
    var s = find_arrow_schema_value_counted(_view(Span(out)))
    assert_equal(s.value, "UkVBTA==")
    assert_equal(s.bytes_examined, len(out) - 11)


# ---- num_rows alone ---------------------------------------------------------------


def test_num_rows_only_stops_at_field_3() raises:
    var f = _footer(321, "ARROW:schema", "QUJD")
    var footer = f[0].copy()
    var n = parse_metadata_num_rows_only(_view(Span(footer)))
    assert_equal(n.num_rows, 321)
    assert_equal(n.bytes_examined, f[1])


def test_num_rows_only_stop_end_and_wrong_type() raises:
    var out = List[UInt8]()
    _fh(out, 3, 5)  # field 3 as an i32: skipped
    _zz(out, 5)
    out.append(0x00)
    out.append(0x16)
    var n = parse_metadata_num_rows_only(_view(Span(out)))
    assert_equal(n.num_rows, 0)
    assert_equal(n.bytes_examined, len(out) - 1)
    var empty = List[UInt8]()
    var n2 = parse_metadata_num_rows_only(_view(Span(empty)))
    assert_equal(n2.num_rows, 0)
    assert_equal(n2.bytes_examined, 0)


def test_arrow_schema_value_length_near_int_max_is_absent() raises:
    # A value length of Int.MAX - 1 wrapped `pos + len` negative and passed
    # the bound, and the copy's allocation aborted the process inside a
    # search documented never to raise. Now the value is absent.
    var b = List[UInt8]()
    b.append(0x00)
    b.append(0x0C)
    for c in "ARROW:schema".as_bytes():
        b.append(c)
    b.append(0x18)  # field 2 (value), binary
    _uleb(b, Int.MAX - 1)
    for _ in range(4):
        b.append(0x00)
    assert_equal(find_arrow_schema_value(_view(Span(b))), "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
