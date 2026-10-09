# =============================================================================
# Tests for the decode-gather: PLAIN fixed-width, non-null
# =============================================================================
#
# Covers:
#   - _gather_plain_fixed_width[dtype]: Int32 / Int64 / Float32 / Float64
#     with varied SelectionInterval shapes (all-select, partial, empty,
#     intervals spanning page boundaries, multi-page, intervals at page
#     edges), and a page buffer / extent count mismatch refused.
# =============================================================================

from std.memory import unsafe_memcpy
from std.sys import size_of
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.column import Column
from komira_arrow.arrow_types import ArrowType
from komira_collections.slab import Slab
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion

from komira_parquet.gather import (
    _PageExtent,
    _gather_plain_fixed_width,
)
from komira_parquet.selection_vector import SelectionInterval
from komira_parquet_api.types import (
    Encoding,
    ParquetType,
)


# ---------------------------------------------------------------------------
# Helpers: build page buffers for _gather_plain_fixed_width tests
# ---------------------------------------------------------------------------


def _build_int32_page(values: List[Int32]) -> SharedAlignedBuffer[HeapRegion]:
    """Build a PLAIN-encoded Int32 page buffer from a Python-style list."""
    var n = len(values)
    var byte_count = n * 4
    var buf = OwnedAlignedBuffer(max(byte_count, 1))
    var ptr = buf.view_typed_mut[DType.int32]()
    for i in range(n):
        ptr[i] = values[i]
    buf.set_length(Int64(byte_count))

    return SharedAlignedBuffer.from_owned(buf^)


def _build_int64_page(values: List[Int64]) -> SharedAlignedBuffer[HeapRegion]:
    var n = len(values)
    var byte_count = n * 8
    var buf = OwnedAlignedBuffer(max(byte_count, 1))
    var ptr = buf.view_typed_mut[DType.int64]()
    for i in range(n):
        ptr[i] = values[i]
    buf.set_length(Int64(byte_count))

    return SharedAlignedBuffer.from_owned(buf^)


def _build_float32_page(values: List[Float32]) -> SharedAlignedBuffer[HeapRegion]:
    var n = len(values)
    var byte_count = n * 4
    var buf = OwnedAlignedBuffer(max(byte_count, 1))
    var ptr = buf.view_typed_mut[DType.float32]()
    for i in range(n):
        ptr[i] = values[i]
    buf.set_length(Int64(byte_count))

    return SharedAlignedBuffer.from_owned(buf^)


def _build_float64_page(values: List[Float64]) -> SharedAlignedBuffer[HeapRegion]:
    var n = len(values)
    var byte_count = n * 8
    var buf = OwnedAlignedBuffer(max(byte_count, 1))
    var ptr = buf.view_typed_mut[DType.float64]()
    for i in range(n):
        ptr[i] = values[i]
    buf.set_length(Int64(byte_count))

    return SharedAlignedBuffer.from_owned(buf^)


def _arr_to_list_int32(arr: PrimitiveArray[DType.int32]) -> List[Int32]:
    var out = List[Int32]()
    var ptr = arr._typed_ptr_ro()
    for i in range(arr.length):
        out.append(ptr[i])
    return out^


def _arr_to_list_int64(arr: PrimitiveArray[DType.int64]) -> List[Int64]:
    var out = List[Int64]()
    var ptr = arr._typed_ptr_ro()
    for i in range(arr.length):
        out.append(ptr[i])
    return out^


def _arr_to_list_float32(arr: PrimitiveArray[DType.float32]) -> List[Float32]:
    var out = List[Float32]()
    var ptr = arr._typed_ptr_ro()
    for i in range(arr.length):
        out.append(ptr[i])
    return out^


def _arr_to_list_float64(arr: PrimitiveArray[DType.float64]) -> List[Float64]:
    var out = List[Float64]()
    var ptr = arr._typed_ptr_ro()
    for i in range(arr.length):
        out.append(ptr[i])
    return out^


# ---------------------------------------------------------------------------
# Inner gather tests — _gather_plain_fixed_width
# ---------------------------------------------------------------------------


def test_gather_int32_single_page_select_all() raises:
    """Single page, one interval covering all rows: output == input."""
    var values: List[Int32] = [Int32(10), Int32(20), Int32(30), Int32(40)]
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(_build_int32_page(values))
    var extents = List[_PageExtent]()
    extents.append(_PageExtent(4, Encoding.PLAIN))
    var intervals = List[SelectionInterval]()
    intervals.append(SelectionInterval(UInt32(0), UInt32(4)))

    var arr = _gather_plain_fixed_width[DType.int32](
        pages, Span(extents), Span(intervals), 4,
    )
    assert_equal(arr.length, 4)
    var got = _arr_to_list_int32(arr)
    assert_equal(Int(got[0]), 10)
    assert_equal(Int(got[1]), 20)
    assert_equal(Int(got[2]), 30)
    assert_equal(Int(got[3]), 40)


def test_gather_int64_skip_then_select() raises:
    """Single page, skip=2 select=3 from a 6-row page."""
    var values: List[Int64] = [
        Int64(100), Int64(200), Int64(300), Int64(400), Int64(500), Int64(600),
    ]
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(_build_int64_page(values))
    var extents = List[_PageExtent]()
    extents.append(_PageExtent(6, Encoding.PLAIN))
    var intervals = List[SelectionInterval]()
    intervals.append(SelectionInterval(UInt32(2), UInt32(3)))

    var arr = _gather_plain_fixed_width[DType.int64](
        pages, Span(extents), Span(intervals), 3,
    )
    assert_equal(arr.length, 3)
    var got = _arr_to_list_int64(arr)
    assert_equal(Int(got[0]), 300)
    assert_equal(Int(got[1]), 400)
    assert_equal(Int(got[2]), 500)


def test_gather_float32_multiple_intervals_same_page() raises:
    """Multiple disjoint intervals within one page."""
    var values: List[Float32] = [
        Float32(1.0), Float32(2.0), Float32(3.0), Float32(4.0),
        Float32(5.0), Float32(6.0), Float32(7.0), Float32(8.0),
    ]
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(_build_float32_page(values))
    var extents = List[_PageExtent]()
    extents.append(_PageExtent(8, Encoding.PLAIN))
    # Select rows 0, 3-4, 7: (skip=0,select=1), (skip=2,select=2), (skip=2,select=1).
    var intervals = List[SelectionInterval]()
    intervals.append(SelectionInterval(UInt32(0), UInt32(1)))
    intervals.append(SelectionInterval(UInt32(2), UInt32(2)))
    intervals.append(SelectionInterval(UInt32(2), UInt32(1)))

    var arr = _gather_plain_fixed_width[DType.float32](
        pages, Span(extents), Span(intervals), 4,
    )
    assert_equal(arr.length, 4)
    var got = _arr_to_list_float32(arr)
    assert_equal(Float32(got[0]), Float32(1.0))
    assert_equal(Float32(got[1]), Float32(4.0))
    assert_equal(Float32(got[2]), Float32(5.0))
    assert_equal(Float32(got[3]), Float32(8.0))


def test_gather_float64_cross_page_boundary() raises:
    """Interval spans two pages — verifies the page-advance code path."""
    var p1: List[Float64] = [Float64(1.5), Float64(2.5), Float64(3.5)]
    var p2: List[Float64] = [Float64(4.5), Float64(5.5), Float64(6.5)]
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(_build_float64_page(p1))
    pages.append(_build_float64_page(p2))
    var extents = List[_PageExtent]()
    extents.append(_PageExtent(3, Encoding.PLAIN))
    extents.append(_PageExtent(3, Encoding.PLAIN))
    # skip=1, select=4: rows 1-4 span pages (rows 1-2 in page0, rows 3-4 in page1).
    var intervals = List[SelectionInterval]()
    intervals.append(SelectionInterval(UInt32(1), UInt32(4)))

    var arr = _gather_plain_fixed_width[DType.float64](
        pages, Span(extents), Span(intervals), 4,
    )
    var got = _arr_to_list_float64(arr)
    assert_equal(Float64(got[0]), Float64(2.5))
    assert_equal(Float64(got[1]), Float64(3.5))
    assert_equal(Float64(got[2]), Float64(4.5))
    assert_equal(Float64(got[3]), Float64(5.5))


def test_gather_int32_multi_page_per_interval() raises:
    """Three pages, multiple intervals that touch all three."""
    var p1: List[Int32] = [Int32(0), Int32(1), Int32(2), Int32(3)]
    var p2: List[Int32] = [Int32(4), Int32(5), Int32(6), Int32(7)]
    var p3: List[Int32] = [Int32(8), Int32(9), Int32(10), Int32(11)]
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(_build_int32_page(p1))
    pages.append(_build_int32_page(p2))
    pages.append(_build_int32_page(p3))
    var extents = List[_PageExtent]()
    extents.append(_PageExtent(4, Encoding.PLAIN))
    extents.append(_PageExtent(4, Encoding.PLAIN))
    extents.append(_PageExtent(4, Encoding.PLAIN))
    # Select rows: 1, 3-4, 6, 9-10 (absolute).
    # Intervals (skip, select):
    #   (1,1) -> row 1
    #   (1,2) -> rows 3,4
    #   (1,1) -> row 6
    #   (2,2) -> rows 9,10
    var intervals = List[SelectionInterval]()
    intervals.append(SelectionInterval(UInt32(1), UInt32(1)))
    intervals.append(SelectionInterval(UInt32(1), UInt32(2)))
    intervals.append(SelectionInterval(UInt32(1), UInt32(1)))
    intervals.append(SelectionInterval(UInt32(2), UInt32(2)))

    var arr = _gather_plain_fixed_width[DType.int32](
        pages, Span(extents), Span(intervals), 6,
    )
    var got = _arr_to_list_int32(arr)
    assert_equal(Int(got[0]), 1)
    assert_equal(Int(got[1]), 3)
    assert_equal(Int(got[2]), 4)
    assert_equal(Int(got[3]), 6)
    assert_equal(Int(got[4]), 9)
    assert_equal(Int(got[5]), 10)


def test_gather_int32_empty_intervals() raises:
    """Zero intervals -> zero-length output (num_selected == 0)."""
    var values: List[Int32] = [Int32(1), Int32(2), Int32(3)]
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(_build_int32_page(values))
    var extents = List[_PageExtent]()
    extents.append(_PageExtent(3, Encoding.PLAIN))
    var intervals = List[SelectionInterval]()

    var arr = _gather_plain_fixed_width[DType.int32](
        pages, Span(extents), Span(intervals), 0,
    )
    assert_equal(arr.length, 0)


def test_gather_int32_single_row_at_page_boundary() raises:
    """One interval of length 1 landing exactly on the last row of page 0."""
    var p1: List[Int32] = [Int32(100), Int32(200), Int32(300)]
    var p2: List[Int32] = [Int32(400), Int32(500)]
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(_build_int32_page(p1))
    pages.append(_build_int32_page(p2))
    var extents = List[_PageExtent]()
    extents.append(_PageExtent(3, Encoding.PLAIN))
    extents.append(_PageExtent(2, Encoding.PLAIN))
    # Row 2 is the last row of page 0.
    var intervals = List[SelectionInterval]()
    intervals.append(SelectionInterval(UInt32(2), UInt32(1)))

    var arr = _gather_plain_fixed_width[DType.int32](
        pages, Span(extents), Span(intervals), 1,
    )
    var got = _arr_to_list_int32(arr)
    assert_equal(Int(got[0]), 300)


def test_gather_int32_first_and_last_rows_only() raises:
    """Two intervals: first row of page 0 and last row of page 2."""
    var p1: List[Int32] = [Int32(10), Int32(20)]
    var p2: List[Int32] = [Int32(30), Int32(40)]
    var p3: List[Int32] = [Int32(50), Int32(60)]
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(_build_int32_page(p1))
    pages.append(_build_int32_page(p2))
    pages.append(_build_int32_page(p3))
    var extents = List[_PageExtent]()
    extents.append(_PageExtent(2, Encoding.PLAIN))
    extents.append(_PageExtent(2, Encoding.PLAIN))
    extents.append(_PageExtent(2, Encoding.PLAIN))
    # (0,1) -> row 0; (4,1) -> row 5
    var intervals = List[SelectionInterval]()
    intervals.append(SelectionInterval(UInt32(0), UInt32(1)))
    intervals.append(SelectionInterval(UInt32(4), UInt32(1)))

    var arr = _gather_plain_fixed_width[DType.int32](
        pages, Span(extents), Span(intervals), 2,
    )
    var got = _arr_to_list_int32(arr)
    assert_equal(Int(got[0]), 10)
    assert_equal(Int(got[1]), 60)


def test_gather_int64_length_mismatch_raises() raises:
    """Page buffers and extents length mismatch -> Error."""
    var values: List[Int64] = [Int64(1), Int64(2)]
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(_build_int64_page(values))
    var extents = List[_PageExtent]()  # empty -- mismatch
    var intervals = List[SelectionInterval]()
    intervals.append(SelectionInterval(UInt32(0), UInt32(2)))

    var raised = False
    try:
        _ = _gather_plain_fixed_width[DType.int64](
            pages, Span(extents), Span(intervals), 2,
        )
    except:
        raised = True
    assert_true(raised)



def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
