# Direct tests of `gather_dict.mojo`, part 2: what the two dictionary gathers
# refuse. Each refusal is a raise with its own message, before the gather
# writes an output slot it did not size (a `num_selected` that is not the
# intervals' total, def levels shorter than the walk) or returns rows it does
# not have (intervals past the last page). Pages are encoded as in
# test_gather_dict_direct: one bit-width byte, then a bit-packed run.
from std.testing import TestSuite, assert_true

from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_parquet_api.types import Encoding, ParquetType

from komira_parquet.dictionary import DictionaryDecoder
from komira_parquet.gather_common import _PageDefLevels, _PageExtent
from komira_parquet.gather_dict import (
    _gather_dict_encoded,
    _gather_dict_encoded_nullable,
)
from komira_parquet.selection_vector import SelectionInterval


def _le(mut out: List[UInt8], v: Int, width: Int):
    for k in range(width):
        out.append(UInt8((v >> (8 * k)) & 0xFF))


def _index_page(codes: List[Int]) -> List[UInt8]:
    """Bit width 4, one bit-packed run of up to 8 codes (one group)."""
    var page: List[UInt8] = [UInt8(4), UInt8(3)]
    for g in range(4):
        var lo = codes[2 * g] if 2 * g < len(codes) else 0
        var hi = codes[2 * g + 1] if 2 * g + 1 < len(codes) else 0
        page.append(UInt8(lo | (hi << 4)))
    return page^


def _buf(bytes: List[UInt8]) -> SharedAlignedBuffer[HeapRegion]:
    var buf = OwnedAlignedBuffer(max(len(bytes), 1))
    for i in range(len(bytes)):
        buf.set_typed[UInt8](i, bytes[i])
    buf.set_length(Int64(len(bytes)))
    return SharedAlignedBuffer.from_owned(buf^)


def _int32_dict() raises -> DictionaryDecoder:
    var page = List[UInt8]()
    for i in range(4):
        _le(page, 10 + i, 4)
    var d = DictionaryDecoder()
    d.init_dict_int32(Span(page), 4)
    return d^


def _int64_dict() raises -> DictionaryDecoder:
    var page = List[UInt8]()
    for i in range(4):
        _le(page, 10 + i, 8)
    var d = DictionaryDecoder()
    d.init_dict_int64(Span(page), 4)
    return d^


def _ivls(pairs: List[Int]) -> List[SelectionInterval]:
    var out = List[SelectionInterval]()
    for i in range(0, len(pairs), 2):
        out.append(SelectionInterval(UInt32(pairs[i]), UInt32(pairs[i + 1])))
    return out^


struct _Case(Movable):
    """One gather call, non-null and nullable, over `page_rows` pages."""

    var pages: Slab[SharedAlignedBuffer[HeapRegion]]
    var extents: List[_PageExtent]
    var dl: Slab[_PageDefLevels]

    def __init__(out self, page_rows: List[Int]):
        self.pages = Slab[SharedAlignedBuffer[HeapRegion]]()
        self.extents = List[_PageExtent]()
        self.dl = Slab[_PageDefLevels]()
        for p in range(len(page_rows)):
            var codes = List[Int]()
            var defs = List[UInt8]()
            for r in range(max(page_rows[p], 0)):
                codes.append(r % 4)
                defs.append(UInt8(1))
            self.pages.append(_buf(_index_page(codes)))
            self.extents.append(
                _PageExtent(page_rows[p], Encoding.RLE_DICTIONARY)
            )
            self.dl.append(_PageDefLevels(defs^, page_rows[p]))


def _non_null_raises(
    want: String,
    ptype: ParquetType,
    d: DictionaryDecoder,
    c: _Case,
    intervals: List[SelectionInterval],
    num_selected: Int,
    preserve: Bool = False,
) raises:
    var raised = False
    try:
        _ = _gather_dict_encoded(
            ptype, d, c.pages, Span(c.extents), Span(intervals), num_selected,
            preserve,
        )
    except e:
        raised = True
        assert_true(want in String(e), "expected '" + want + "' in: " + String(e))
    assert_true(raised, "no raise; expected: " + want)


def _nullable_raises(
    want: String,
    ptype: ParquetType,
    d: DictionaryDecoder,
    c: _Case,
    intervals: List[SelectionInterval],
    num_selected: Int,
    preserve: Bool = False,
) raises:
    var raised = False
    try:
        _ = _gather_dict_encoded_nullable(
            ptype, d, c.pages, Span(c.extents), c.dl, Span(intervals),
            num_selected, preserve,
        )
    except e:
        raised = True
        assert_true(want in String(e), "expected '" + want + "' in: " + String(e))
    assert_true(raised, "no raise; expected: " + want)


def test_preserve_dict_is_refused() raises:
    var d = _int32_dict()
    var c = _Case([4])
    var iv = _ivls([0, 4])
    _non_null_raises(
        "_gather_dict_encoded: preserve_dict=True is not supported",
        ParquetType.INT32, d, c, iv, 4, True,
    )
    _nullable_raises(
        "_gather_dict_encoded_nullable: preserve_dict=True is not supported",
        ParquetType.INT32, d, c, iv, 4, True,
    )


def test_parallel_list_mismatches_are_refused() raises:
    var d = _int32_dict()
    var iv = _ivls([0, 2])
    var c = _Case([2, 2])
    _ = c.pages.pop()
    _non_null_raises(
        "gather dict: page_buffers/page_extents length mismatch: 1 vs 2",
        ParquetType.INT32, d, c, iv, 2,
    )
    _nullable_raises(
        "gather dict nullable: page_buffers/page_extents length mismatch: 1 vs 2",
        ParquetType.INT32, d, c, iv, 2,
    )
    var c2 = _Case([2, 2])
    _ = c2.dl.pop()
    _nullable_raises(
        "page_buffers/page_def_levels length mismatch: 2 vs 1",
        ParquetType.INT32, d, c2, iv, 2,
    )


def test_num_selected_must_be_the_intervals_total() raises:
    """One more or one fewer than the 3 rows the intervals select is refused
    before any slot is written (one fewer would write past the buffers)."""
    var d = _int32_dict()
    var c = _Case([6])
    var iv = _ivls([0, 2, 1, 1])
    for n in range(2, 5, 2):
        _non_null_raises(
            "gather dict: the selection intervals select 3 rows, not"
            " num_selected = " + String(n),
            ParquetType.INT32, d, c, iv, n,
        )
        _nullable_raises(
            "gather dict nullable: the selection intervals select 3 rows, not"
            " num_selected = " + String(n),
            ParquetType.INT32, d, c, iv, n,
        )


def test_intervals_past_the_last_page_are_refused() raises:
    """A select that runs off the end of the last page (the walk leaves the
    pages after its first row), a skip past every page (the walk stops at
    the top of its loop) and a select with no pages at all: each returns
    fewer rows than selected, which is refused."""
    var d = _int32_dict()
    var c = _Case([3])
    _non_null_raises(
        "overrun the column's pages: 1 of 3 selected rows exist",
        ParquetType.INT32, d, c, _ivls([2, 3]), 3,
    )
    _nullable_raises(
        "overrun the column's pages: 1 of 3 selected rows exist",
        ParquetType.INT32, d, c, _ivls([2, 3]), 3,
    )
    _non_null_raises(
        "overrun the column's pages: 0 of 1 selected rows exist",
        ParquetType.INT32, d, c, _ivls([5, 1]), 1,
    )
    _nullable_raises(
        "overrun the column's pages: 0 of 1 selected rows exist",
        ParquetType.INT32, d, c, _ivls([5, 1]), 1,
    )
    var empty = _Case(List[Int]())
    _non_null_raises(
        "overrun the column's pages: 0 of 2 selected rows exist",
        ParquetType.INT32, d, empty, _ivls([0, 2]), 2,
    )
    _nullable_raises(
        "overrun the column's pages: 0 of 2 selected rows exist",
        ParquetType.INT32, d, empty, _ivls([0, 2]), 2,
    )


def test_negative_page_count_is_refused() raises:
    var d = _int32_dict()
    var c = _Case([-2])
    _non_null_raises(
        "a page declares a negative value count -2",
        ParquetType.INT32, d, c, List[SelectionInterval](), 0,
    )
    _nullable_raises(
        "a page declares a negative value count -2",
        ParquetType.INT32, d, c, List[SelectionInterval](), 0,
    )


def test_def_levels_shorter_than_the_walk_are_refused() raises:
    """The page says 4 rows, its def levels hold 2: reading row 2 or 3 would
    index past them."""
    var d = _int32_dict()
    var c = _Case([4])
    _ = c.dl.pop()
    c.dl.append(_PageDefLevels([UInt8(1), UInt8(1)], 2))
    _nullable_raises(
        "gather dict nullable: page 0 carries 2 def levels, the walk needs row 3",
        ParquetType.INT32, d, c, _ivls([1, 3]), 3,
    )
    # Rows inside the def levels are gathered.
    var col = _gather_dict_encoded_nullable(
        ParquetType.INT32, d, c.pages, Span(c.extents), c.dl,
        Span(_ivls([0, 2])), 2, False,
    )
    assert_true(col.length() == 2)


def test_a_dictionary_of_another_type_is_refused() raises:
    """Each type's gather needs that type's dictionary loaded: an INT64
    dictionary for INT32, an INT32 one for the others."""
    var d32 = _int32_dict()
    var d64 = _int64_dict()
    var c = _Case([4])
    var iv = _ivls([0, 4])
    var types: List[ParquetType] = [
        ParquetType.INT32,
        ParquetType.INT64,
        ParquetType.FLOAT,
        ParquetType.DOUBLE,
        ParquetType.BYTE_ARRAY,
    ]
    var names: List[String] = ["INT32", "INT64", "FLOAT", "DOUBLE", "BYTE_ARRAY"]
    for t in range(len(types)):
        var msg = names[t] + " dict not initialized"
        if t == 0:
            _non_null_raises(
                "_gather_dict_encoded: " + msg, types[t], d64, c, iv, 4
            )
            _nullable_raises(
                "_gather_dict_encoded_nullable: " + msg, types[t], d64, c, iv, 4
            )
        else:
            _non_null_raises(
                "_gather_dict_encoded: " + msg, types[t], d32, c, iv, 4
            )
            _nullable_raises(
                "_gather_dict_encoded_nullable: " + msg, types[t], d32, c, iv, 4
            )


def test_unsupported_physical_types_are_refused() raises:
    var d = _int32_dict()
    var c = _Case([4])
    var iv = _ivls([0, 4])
    var types: List[ParquetType] = [
        ParquetType.BOOLEAN,
        ParquetType.INT96,
        ParquetType.FIXED_LEN_BYTE_ARRAY,
    ]
    for t in range(len(types)):
        _non_null_raises(
            "_gather_dict_encoded: unsupported physical type", types[t], d, c,
            iv, 4,
        )
        _nullable_raises(
            "_gather_dict_encoded_nullable: unsupported physical type",
            types[t], d, c, iv, 4,
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
