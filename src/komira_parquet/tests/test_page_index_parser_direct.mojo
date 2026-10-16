# page_index_parser on hand-encoded Thrift Compact blobs (field headers
# written here from parquet.thrift):
#   - a ColumnIndex: null pages, LE Int64 bounds, boundary order, null
#     counts, an unknown field skipped; a page whose min or max is shorter
#     than 8 bytes marks only that page as without bounds (the others keep
#     theirs);
#   - an OffsetIndex: page locations, the optional field 2 skipped;
#   - refusals: parallel lists of different lengths, null counts of another
#     length, a binary running past the blob, a list count the bytes cannot
#     hold, a truncated blob, a PageLocation missing a field, first rows that
#     do not ascend, a list<bool> of another element type.

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_buffer.byte_view import ByteView
from komira_parquet.page_index_parser import parse_column_index_int64, parse_offset_index


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


def _zz(mut out: List[UInt8], v: Int):
    _uleb(out, (v << 1) ^ (v >> 63))


def _list(mut out: List[UInt8], header: Int, elem: Int, n: Int):
    out.append(UInt8(header))
    if n < 15:
        out.append(UInt8((n << 4) | elem))
    else:
        out.append(UInt8(0xF0 | elem))
        _uleb(out, n)


def _i64_bin(mut out: List[UInt8], v: Int, width: Int = 8):
    _uleb(out, width)
    for k in range(width):
        out.append(UInt8((v >> (8 * k)) & 0xFF))


def _column_index(
    null_pages: List[Bool],
    mins: List[Int],
    maxs: List[Int],
    min_width: List[Int],
    n_counts: Int = -1,
) -> List[UInt8]:
    """null_pages, min_values (page i `min_width[i]` bytes), max_values,
    boundary order 1, null counts, and an unknown field 9 (an i32)."""
    var b = List[UInt8]()
    _list(b, 0x19, 1, len(null_pages))
    for i in range(len(null_pages)):
        b.append(UInt8(1) if null_pages[i] else UInt8(2))
    _list(b, 0x19, 8, len(mins))
    for i in range(len(mins)):
        _i64_bin(b, mins[i], min_width[i])
    _list(b, 0x19, 8, len(maxs))
    for i in range(len(maxs)):
        _i64_bin(b, maxs[i])
    b.append(0x15)  # 4: boundary_order
    _zz(b, 1)
    var nc = len(null_pages) if n_counts < 0 else n_counts
    _list(b, 0x19, 6, nc)  # 5: null_counts
    for i in range(nc):
        _zz(b, i)
    b.append(0x45)  # 9: unknown i32
    _zz(b, 77)
    b.append(0x00)
    return b^


def test_a_column_index() raises:
    var blob = _column_index(
        [False, True, False], [-5, 0, 1 << 40], [7, 0, (1 << 40) + 9], [8, 8, 8]
    )
    var ci = parse_column_index_int64(_view(Span(blob)))
    assert_equal(ci.num_pages, 3)
    assert_false(ci.null_pages[0])
    assert_true(ci.null_pages[1])
    assert_equal(Int(ci.min_values_int64[0]), -5)
    assert_equal(Int(ci.max_values_int64[2]), (1 << 40) + 9)
    assert_equal(Int(ci.boundary_order.value), 1)
    assert_equal(ci.null_counts.value()[2], 2)
    assert_true(ci.page_has_bounds(0) and ci.page_has_bounds(2))


def test_a_page_without_bounds_is_marked_alone() raises:
    # Page 1's min is written empty: only page 1 loses its bounds.
    var blob = _column_index([False, False, False], [1, 0, 30], [9, 50, 39], [8, 0, 8])
    var ci = parse_column_index_int64(_view(Span(blob)))
    assert_true(ci.page_has_bounds(0))
    assert_false(ci.page_has_bounds(1))
    assert_true(ci.page_has_bounds(2))
    assert_true(ci.has_int64_stats())


def _offset_index(locs: List[Int], extra_field_2: Bool) -> List[UInt8]:
    """page_locations from flat (offset, size, first_row) triples."""
    var b = List[UInt8]()
    _list(b, 0x19, 12, len(locs) // 3)
    for i in range(len(locs) // 3):
        b.append(0x16)
        _zz(b, locs[3 * i])
        b.append(0x15)
        _zz(b, locs[3 * i + 1])
        b.append(0x16)
        _zz(b, locs[3 * i + 2])
        b.append(0x00)
    if extra_field_2:
        _list(b, 0x19, 6, 1)
        _zz(b, 123)
    b.append(0x00)
    return b^


def test_an_offset_index() raises:
    var blob = _offset_index([4, 30, 0, 34, 31, 10, 65, 20, 20], True)
    var oi = parse_offset_index(_view(Span(blob)))
    assert_equal(oi.num_pages, 3)
    assert_equal(oi.offsets[1], 34)
    assert_equal(oi.compressed_sizes[2], 20)
    assert_equal(oi.first_row_indices[2], 20)


def test_refusals() raises:
    var short_max = List[UInt8]()
    _list(short_max, 0x19, 1, 2)
    short_max.append(2)
    short_max.append(2)
    _list(short_max, 0x19, 8, 2)
    _i64_bin(short_max, 1)
    _i64_bin(short_max, 2)
    _list(short_max, 0x19, 8, 1)
    _i64_bin(short_max, 3)
    short_max.append(0)
    with assert_raises(contains="parallel-array length mismatch"):
        _ = parse_column_index_int64(_view(Span(short_max)))

    var counts = _column_index([False, False], [1, 2], [3, 4], [8, 8], n_counts=1)
    with assert_raises(contains="null counts for 2 pages"):
        _ = parse_column_index_int64(_view(Span(counts)))

    var past = List[UInt8]()
    _list(past, 0x29, 8, 1)  # 2: min_values with one 200-byte binary
    _uleb(past, 200)
    past.append(1)
    with assert_raises(contains="runs past the end"):
        _ = parse_column_index_int64(_view(Span(past)))

    var huge = List[UInt8]()
    _list(huge, 0x19, 1, 1_000_000)
    with assert_raises(contains="bytes remain"):
        _ = parse_column_index_int64(_view(Span(huge)))

    var full = _column_index([False], [1], [2], [8])
    var cut = List[UInt8]()
    for i in range(len(full) - 6):
        cut.append(full[i])
    with assert_raises():
        _ = parse_column_index_int64(_view(Span(cut)))

    var bad_elem = List[UInt8]()
    _list(bad_elem, 0x19, 5, 1)
    bad_elem.append(1)
    with assert_raises(contains="list<bool> element type"):
        _ = parse_column_index_int64(_view(Span(bad_elem)))

    var no_size = List[UInt8]()
    _list(no_size, 0x19, 12, 1)
    no_size.append(0x16)
    _zz(no_size, 4)
    no_size.append(0x26)  # skips field 2: field 3 first_row
    _zz(no_size, 0)
    no_size.append(0x00)
    no_size.append(0x00)
    with assert_raises(contains="PageLocation without"):
        _ = parse_offset_index(_view(Span(no_size)))

    var backwards = _offset_index([4, 10, 5, 14, 10, 0], False)
    with assert_raises(contains="do not ascend"):
        _ = parse_offset_index(_view(Span(backwards)))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
