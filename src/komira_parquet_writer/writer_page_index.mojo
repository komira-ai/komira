# =============================================================================
# Parquet Page Index Writer — tracks per-page stats during write
# =============================================================================
#
# During a write, each column's data pages accumulate per-page min/max
# statistics and file offset information. After all column data is written,
# ColumnIndex and OffsetIndex structures are serialized as Thrift blobs and
# appended to the file (between column data and the footer).
#
# The page index enables fine-grained predicate pushdown within row groups:
# readers can skip individual data pages whose value ranges don't overlap
# the filter predicate, instead of scanning the entire column chunk.
#
# File layout with page indexes:
#   [PAR1 magic (4 bytes)]
#   [column data pages]
#   [bloom filter data (optional)]
#   [ColumnIndex for each column]    <-- page index section
#   [OffsetIndex for each column]    <-- page index section
#   [Thrift-encoded FileMetaData footer]
#   [footer length (4 bytes, LE)]
#   [PAR1 magic (4 bytes)]
#
# The footer's ColumnChunk entries record the byte offset and length of
# each column's ColumnIndex and OffsetIndex.
#
# BoundaryOrder is computed in the column's TYPE-DEFINED order, the order
# the footer declares for every leaf (`column_orders`, TYPE_ORDER): signed
# for INT32 / INT64, numeric for FLOAT / DOUBLE, unsigned bytewise for
# BYTE_ARRAY and FIXED_LEN_BYTE_ARRAY. Page min/max values are PLAIN bytes,
# which for the numeric types are little-endian, so a bytewise compare of
# them is not their order (1 is `01 00 00 00`, 256 is `00 01 00 00`); a
# reader that trusts a wrong ASCENDING binary-searches into the wrong pages.
# parquet.thrift: ASCENDING / DESCENDING mean BOTH min_values and max_values
# are sorted in that direction, so both lists are checked.
#
# Reference: Parquet spec "Page Index".
# =============================================================================

from std.memory import bitcast

from komira_parquet_api.types import BoundaryOrder, ParquetType
from .thrift_writer import ThriftCompactWriter


# =============================================================================
# PageBoundary — statistics for one data page
# =============================================================================


struct PageBoundary(Movable, Copyable):
    """Per-page statistics collected during write.

    Each time a data page is written, a PageBoundary is recorded with
    the page's file offset, compressed size, first row index, and
    min/max values as raw bytes.

    Fields:
        offset: File byte offset where this page starts.
        compressed_page_size: Total compressed size of the page on disk
            (includes page header + page body).
        first_row_index: 0-based index of the first row in this page.
        min_value: Minimum value in this page as raw bytes.
        max_value: Maximum value in this page as raw bytes.
        null_count: Number of null values in this page.
        is_null_page: True if this page contains only null values.
    """

    var offset: Int
    var compressed_page_size: Int
    var first_row_index: Int
    var min_value: List[UInt8]
    var max_value: List[UInt8]
    var null_count: Int
    var is_null_page: Bool

    def __init__(
        out self,
        offset: Int,
        compressed_page_size: Int,
        first_row_index: Int,
        var min_value: List[UInt8],
        var max_value: List[UInt8],
        null_count: Int = 0,
        is_null_page: Bool = False,
    ):
        self.offset = offset
        self.compressed_page_size = compressed_page_size
        self.first_row_index = first_row_index
        self.min_value = min_value^
        self.max_value = max_value^
        self.null_count = null_count
        self.is_null_page = is_null_page


# =============================================================================
# ColumnPageTracker — accumulates page boundaries for one column
# =============================================================================


struct ColumnPageTracker(Movable, Copyable):
    """Accumulates per-page boundaries for a single column during write.

    After all pages are written, call serialize_column_index() and
    serialize_offset_index() to produce the Thrift-encoded blobs.

    Fields:
        physical_type: The column's Parquet physical type; it fixes the order
            BoundaryOrder is computed in.
        pages: List of per-page boundary records.
    """

    var physical_type: ParquetType
    var pages: List[PageBoundary]

    def __init__(out self, physical_type: ParquetType):
        self.physical_type = physical_type
        self.pages = List[PageBoundary]()

    def add_page(
        mut self,
        offset: Int,
        compressed_page_size: Int,
        first_row_index: Int,
        var min_value: List[UInt8],
        var max_value: List[UInt8],
        null_count: Int = 0,
        is_null_page: Bool = False,
    ):
        """Record a page boundary.

        Args:
            offset: File byte offset of the page.
            compressed_page_size: Compressed size in bytes (header + body).
            first_row_index: First row number in this page.
            min_value: Min value as raw bytes.
            max_value: Max value as raw bytes.
            null_count: Number of nulls in this page.
            is_null_page: True if the page is entirely null.
        """
        self.pages.append(PageBoundary(
            offset,
            compressed_page_size,
            first_row_index,
            min_value^,
            max_value^,
            null_count,
            is_null_page,
        ))


# =============================================================================
# Boundary order detection
# =============================================================================


def _detect_boundary_order(
    pages: List[PageBoundary], physical_type: ParquetType
) -> Int:
    """Whether the pages' min AND max values are both ascending or descending.

    Compares consecutive non-null pages in the column's type-defined order
    (`_compare_values`). ASCENDING when no min and no max ever decreases,
    DESCENDING when none ever increases (equal values satisfy both),
    UNORDERED otherwise, and for a type whose order is not implemented
    (BOOLEAN, INT96), which claims nothing a reader could act on.

    Args:
        pages: The list of page boundaries.
        physical_type: The column's physical type.

    Returns:
        BoundaryOrder enum value (0=UNORDERED, 1=ASCENDING, 2=DESCENDING).
    """
    if not _has_type_order(physical_type):
        return Int(BoundaryOrder.UNORDERED.value)
    if len(pages) <= 1:
        return Int(BoundaryOrder.ASCENDING.value)

    var ascending = True
    var descending = True

    var prev_idx = -1
    for i in range(len(pages)):
        if pages[i].is_null_page:
            continue
        if prev_idx < 0:
            prev_idx = i
            continue

        var cmp_min = _compare_values(
            physical_type, pages[prev_idx].min_value, pages[i].min_value
        )
        var cmp_max = _compare_values(
            physical_type, pages[prev_idx].max_value, pages[i].max_value
        )
        if cmp_min > 0 or cmp_max > 0:
            ascending = False
        if cmp_min < 0 or cmp_max < 0:
            descending = False

        if not ascending and not descending:
            return Int(BoundaryOrder.UNORDERED.value)

        prev_idx = i

    if ascending:
        return Int(BoundaryOrder.ASCENDING.value)
    if descending:
        return Int(BoundaryOrder.DESCENDING.value)
    return Int(BoundaryOrder.UNORDERED.value)


@always_inline
def _has_type_order(physical_type: ParquetType) -> Bool:
    """Whether `_compare_values` implements this type's defined order."""
    return (
        physical_type == ParquetType.INT32
        or physical_type == ParquetType.INT64
        or physical_type == ParquetType.FLOAT
        or physical_type == ParquetType.DOUBLE
        or physical_type == ParquetType.BYTE_ARRAY
        or physical_type == ParquetType.FIXED_LEN_BYTE_ARRAY
    )


@always_inline
def _le_u64(b: List[UInt8]) -> UInt64:
    """The little-endian unsigned value of up to 8 bytes."""
    var v = UInt64(0)
    for i in range(min(len(b), 8)):
        v = v | (UInt64(b[i]) << UInt64(8 * i))
    return v


def _compare_values(
    physical_type: ParquetType, a: List[UInt8], b: List[UInt8]
) -> Int:
    """Compare two PLAIN-encoded values in the type-defined order.

    INT32 / INT64: signed little-endian integers. FLOAT / DOUBLE: IEEE-754
    values (the statistics never hold a NaN, and -0.0 equals +0.0). Every
    other type: unsigned lexicographic bytes. A value of the wrong width for
    its numeric type falls back to the bytewise compare.

    Returns:
        -1 if a < b, 0 if a == b, 1 if a > b.
    """
    if physical_type == ParquetType.INT32 and len(a) == 4 and len(b) == 4:
        var x = bitcast[DType.int32, 1](UInt32(_le_u64(a)))
        var y = bitcast[DType.int32, 1](UInt32(_le_u64(b)))
        return -1 if x < y else (1 if x > y else 0)
    if physical_type == ParquetType.INT64 and len(a) == 8 and len(b) == 8:
        var x = bitcast[DType.int64, 1](_le_u64(a))
        var y = bitcast[DType.int64, 1](_le_u64(b))
        return -1 if x < y else (1 if x > y else 0)
    if physical_type == ParquetType.FLOAT and len(a) == 4 and len(b) == 4:
        var x = bitcast[DType.float32, 1](UInt32(_le_u64(a)))
        var y = bitcast[DType.float32, 1](UInt32(_le_u64(b)))
        return -1 if x < y else (1 if x > y else 0)
    if physical_type == ParquetType.DOUBLE and len(a) == 8 and len(b) == 8:
        var x = bitcast[DType.float64, 1](_le_u64(a))
        var y = bitcast[DType.float64, 1](_le_u64(b))
        return -1 if x < y else (1 if x > y else 0)
    return _compare_bytes(a, b)


@always_inline
def _compare_bytes(a: List[UInt8], b: List[UInt8]) -> Int:
    """Unsigned lexicographic comparison of two byte lists.

    Returns:
        -1 if a < b, 0 if a == b, 1 if a > b.
    """
    var min_len = len(a) if len(a) < len(b) else len(b)
    for i in range(min_len):
        if a[i] < b[i]:
            return -1
        if a[i] > b[i]:
            return 1
    if len(a) < len(b):
        return -1
    if len(a) > len(b):
        return 1
    return 0


# =============================================================================
# Serialization — produce Thrift-encoded ColumnIndex and OffsetIndex
# =============================================================================


def serialize_column_index(tracker: ColumnPageTracker) -> List[UInt8]:
    """Serialize a ColumnIndex from accumulated page boundaries.

    Produces a Thrift Compact Protocol blob suitable for writing to the
    Parquet file between column data and the footer.

    Args:
        tracker: The column's accumulated page boundaries.

    Returns:
        Thrift-encoded ColumnIndex bytes.
    """
    var num_pages = len(tracker.pages)
    if num_pages == 0:
        return List[UInt8]()

    var null_pages = List[Bool](capacity=num_pages)
    var min_values = List[List[UInt8]](capacity=num_pages)
    var max_values = List[List[UInt8]](capacity=num_pages)
    var null_counts = List[Int](capacity=num_pages)

    for i in range(num_pages):
        null_pages.append(tracker.pages[i].is_null_page)
        min_values.append(tracker.pages[i].min_value.copy())
        max_values.append(tracker.pages[i].max_value.copy())
        null_counts.append(tracker.pages[i].null_count)

    var boundary_order = _detect_boundary_order(
        tracker.pages, tracker.physical_type
    )

    var w = ThriftCompactWriter()
    w.write_column_index(
        null_pages,
        min_values,
        max_values,
        boundary_order,
        null_counts^,
    )
    return w.take_bytes()


def serialize_offset_index(tracker: ColumnPageTracker) -> List[UInt8]:
    """Serialize an OffsetIndex from accumulated page boundaries.

    Produces a Thrift Compact Protocol blob suitable for writing to the
    Parquet file between column data and the footer.

    Args:
        tracker: The column's accumulated page boundaries.

    Returns:
        Thrift-encoded OffsetIndex bytes.
    """
    var num_pages = len(tracker.pages)
    if num_pages == 0:
        return List[UInt8]()

    var offsets = List[Int](capacity=num_pages)
    var compressed_sizes = List[Int](capacity=num_pages)
    var first_row_indices = List[Int](capacity=num_pages)

    for i in range(num_pages):
        offsets.append(tracker.pages[i].offset)
        compressed_sizes.append(tracker.pages[i].compressed_page_size)
        first_row_indices.append(tracker.pages[i].first_row_index)

    var w = ThriftCompactWriter()
    w.write_offset_index(offsets, compressed_sizes, first_row_indices)
    return w.take_bytes()
