# `count_data_pages` (data_page_count): the data pages of a chunk, V1 and V2,
# not its dictionary or index pages, and a chunk whose last page runs past the
# chunk's end counts only the pages before it.
#
# Headers are Thrift Compact page headers (parquet.thrift).
from std.testing import TestSuite, assert_equal

from komira_parquet.data_page_count import count_data_pages

comptime _PLAIN = 0


def _le(mut out: List[UInt8], v: Int, width: Int):
    for k in range(width):
        out.append(UInt8((v >> (8 * k)) & 0xFF))


def _uleb(mut out: List[UInt8], v: Int):
    var x = v
    while True:
        var b = x & 0x7F
        x >>= 7
        if x != 0:
            out.append(UInt8(b | 0x80))
        else:
            out.append(UInt8(b))
            return


def _i32(mut out: List[UInt8], v: Int):
    out.append(UInt8((1 << 4) | 5))
    _uleb(out, (v << 1) ^ (v >> 63))


def _header(
    page_type: Int,
    uncomp: Int,
    comp: Int,
    nv: Int,
    enc: Int,
    def_len: Int = 0,
    rep_len: Int = 0,
    is_compressed: Bool = True,
) -> List[UInt8]:
    var h = List[UInt8]()
    _i32(h, page_type)
    _i32(h, uncomp)
    _i32(h, comp)
    if page_type == 0:
        h.append(UInt8((2 << 4) | 12))
        _i32(h, nv)
        _i32(h, enc)
        _i32(h, 3)
        _i32(h, 3)
        h.append(UInt8(0))
    elif page_type == 2:
        h.append(UInt8((4 << 4) | 12))
        _i32(h, nv)
        _i32(h, enc)
        h.append(UInt8(0))
    elif page_type == 3:
        h.append(UInt8((5 << 4) | 12))
        _i32(h, nv)
        _i32(h, 0)
        _i32(h, nv)
        _i32(h, enc)
        _i32(h, def_len)
        _i32(h, rep_len)
        h.append(UInt8((1 << 4) | (1 if is_compressed else 2)))
        h.append(UInt8(0))
    h.append(UInt8(0))
    return h^



def _page(mut chunk: List[UInt8], page_type: Int, size: Int, nv: Int = 1):
    chunk.extend(_header(page_type, size, size, nv, _PLAIN))
    chunk.extend(List[UInt8](length=size, fill=UInt8(0)))


def test_only_data_pages_are_counted() raises:
    var chunk = List[UInt8]()
    _page(chunk, 2, 4)  # dictionary page
    _page(chunk, 0, 5)  # data page
    _page(chunk, 1, 3)  # index page
    _page(chunk, 3, 6)  # data page v2
    _page(chunk, 0, 0)
    assert_equal(count_data_pages(Span(chunk)), 3)


def test_a_chunk_with_no_pages_has_no_data_pages() raises:
    assert_equal(count_data_pages(Span(List[UInt8]())), 0)


def test_a_last_page_that_runs_past_the_chunk_is_not_counted() raises:
    var chunk = List[UInt8]()
    _page(chunk, 0, 5)
    _page(chunk, 0, 7)
    # Cut into the second page's body.
    chunk.resize(len(chunk) - 3, UInt8(0))
    assert_equal(count_data_pages(Span(chunk)), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
