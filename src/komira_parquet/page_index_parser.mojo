# =============================================================================
# page_index_parser — Thrift Compact ColumnIndex and OffsetIndex
# =============================================================================
#
# Parses the two page-index structs of parquet.thrift into `page_index`'s
# values:
#
#   struct PageLocation { 1: i64 offset; 2: i32 compressed_page_size;
#                         3: i64 first_row_index }
#   struct OffsetIndex  { 1: list<PageLocation> page_locations;
#                         2: optional list<i64> unencoded_byte_array_data_bytes }
#   struct ColumnIndex  { 1: list<bool> null_pages; 2: list<binary> min_values;
#                         3: list<binary> max_values; 4: BoundaryOrder;
#                         5: optional list<i64> null_counts; 6, 7: histograms }
#
# `parse_column_index_int64` reads each min/max binary as a little-endian
# Int64 (the pruner gates on INT64 columns before it calls this). A binary
# shorter than 8 bytes (an all-null page, or a writer that left the bound
# out) gives a 0 placeholder and marks that page as having no bounds.
# Unknown fields are skipped. Every length and list count is checked
# against the bytes left, so a malformed blob raises.
# =============================================================================

from komira_buffer.byte_view import ByteView
from komira_parquet_api.types import BoundaryOrder

from .page_index import ColumnIndex, OffsetIndex
from .thrift_compact import ThriftCompactReader


def _list_size[
    mut: Bool, //, origin: Origin[mut=mut]
](mut reader: ThriftCompactReader[origin]) raises -> Tuple[Int, Int]:
    """A list header: (element count, element type), the count checked
    against the bytes left (every element here takes at least one)."""
    var hdr = reader._read_byte()
    var size = (hdr >> 4) & 0x0F
    if size == 15:
        size = reader._read_varint()
    return (reader._checked_list_size(size), hdr & 0x0F)


def _parse_bool_list_into[
    mut: Bool, //, origin: Origin[mut=mut]
](mut reader: ThriftCompactReader[origin], mut out: List[Bool]) raises:
    """A list<bool>: one byte per element, 1 for true (2, or 0 from some
    writers, for false)."""
    var h = _list_size(reader)
    if h[1] != 1 and h[1] != 2:
        raise Error(
            "page_index_parser: unexpected list<bool> element type "
            + String(h[1])
        )
    for _ in range(h[0]):
        out.append(reader._read_byte() == 1)


def _parse_i64_list_into[
    mut: Bool, //, origin: Origin[mut=mut]
](mut reader: ThriftCompactReader[origin], mut out: List[Int]) raises:
    """A list<i64> (or list<i32>) of zigzag varints."""
    var h = _list_size(reader)
    for _ in range(h[0]):
        out.append(reader._read_zigzag())


def _parse_binary_list_as_int64_into[
    mut: Bool, //, origin: Origin[mut=mut]
](
    mut reader: ThriftCompactReader[origin],
    mut out: List[Int64],
    mut real: List[Bool],
) raises:
    """A list<binary>, each element read as a little-endian Int64 from its
    first 8 bytes; a shorter element gives 0 and `real` False."""
    var h = _list_size(reader)
    for _ in range(h[0]):
        var n = reader._read_varint()
        if n >= 8 and n <= reader.data_len - reader.pos:
            out.append(reader.load_i64_le_at(reader.pos))
            real.append(True)
        else:
            out.append(Int64(0))
            real.append(False)
        reader._advance(n)


def parse_column_index_int64[
    mut: Bool, //, origin: Origin[mut=mut]
](view: ByteView[origin]) raises -> ColumnIndex:
    """A ColumnIndex blob, its min/max read as Int64.

    Raises:
        Error if the blob is malformed, or its per-page lists differ in
        length.
    """
    var reader = ThriftCompactReader[origin](view)
    var null_pages = List[Bool]()
    var mins = List[Int64]()
    var maxs = List[Int64]()
    var min_real = List[Bool]()
    var max_real = List[Bool]()
    var boundary_order = BoundaryOrder.UNORDERED
    var null_counts = Optional[List[Int]](None)
    while reader.pos < reader.data_len:
        var field = reader._read_field_header()
        var fid = field[0]
        var wt = field[1]
        if wt == 0:
            break
        if fid == 1 and wt == 9:
            _parse_bool_list_into(reader, null_pages)
        elif fid == 2 and wt == 9:
            _parse_binary_list_as_int64_into(reader, mins, min_real)
        elif fid == 3 and wt == 9:
            _parse_binary_list_as_int64_into(reader, maxs, max_real)
        elif fid == 4 and wt == 5:
            boundary_order = BoundaryOrder(UInt8(reader._read_zigzag()))
        elif fid == 5 and wt == 9:
            var ncs = List[Int]()
            _parse_i64_list_into(reader, ncs)
            null_counts = ncs^
        else:
            reader._skip_field(wt)

    var num_pages = len(null_pages)
    # A writer that left null_pages out: every page holds a value.
    if num_pages == 0 and len(mins) > 0:
        num_pages = len(mins)
        for _ in range(num_pages):
            null_pages.append(False)
    if len(mins) != num_pages or len(maxs) != num_pages:
        raise Error(
            "page_index_parser: ColumnIndex parallel-array length mismatch"
            " (null_pages="
            + String(num_pages)
            + " min="
            + String(len(mins))
            + " max="
            + String(len(maxs))
            + ")"
        )
    if null_counts and len(null_counts.value()) != num_pages:
        raise Error(
            "page_index_parser: ColumnIndex has "
            + String(len(null_counts.value()))
            + " null counts for "
            + String(num_pages)
            + " pages"
        )
    var has_bounds = List[Bool](capacity=num_pages)
    for i in range(num_pages):
        has_bounds.append(min_real[i] and max_real[i])
    return ColumnIndex(
        null_pages=null_pages^,
        min_values_int64=mins^,
        max_values_int64=maxs^,
        num_pages=num_pages,
        boundary_order=boundary_order,
        null_counts=null_counts^,
        has_bounds=has_bounds^,
    )


def _parse_page_location[
    mut: Bool, //, origin: Origin[mut=mut]
](mut reader: ThriftCompactReader[origin]) raises -> Tuple[Int, Int, Int]:
    """One PageLocation: (offset, compressed_page_size, first_row_index).

    Raises:
        Error if the struct ends before its STOP byte or lacks a field.
    """
    var saved = reader.prev_field_id
    reader.prev_field_id = 0
    var offset = -1
    var size = -1
    var first_row = -1
    while True:
        var field = reader._read_field_header()
        var fid = field[0]
        var wt = field[1]
        if wt == 0:
            break
        if fid == 1 and wt == 6:
            offset = reader._read_zigzag()
        elif fid == 2 and (wt == 5 or wt == 6):
            size = reader._read_zigzag()
        elif fid == 3 and wt == 6:
            first_row = reader._read_zigzag()
        else:
            reader._skip_field(wt)
    reader.prev_field_id = saved
    if offset < 0 or size < 0 or first_row < 0:
        raise Error(
            "page_index_parser: a PageLocation without a valid offset,"
            " size and first row"
        )
    return (offset, size, first_row)


def parse_offset_index[
    mut: Bool, //, origin: Origin[mut=mut]
](view: ByteView[origin]) raises -> OffsetIndex:
    """An OffsetIndex blob.

    Raises:
        Error if the blob is malformed, a location lacks a field, or the
        first rows do not ascend.
    """
    var reader = ThriftCompactReader[origin](view)
    var offsets = List[Int]()
    var sizes = List[Int]()
    var firsts = List[Int]()
    while reader.pos < reader.data_len:
        var field = reader._read_field_header()
        var fid = field[0]
        var wt = field[1]
        if wt == 0:
            break
        if fid == 1 and wt == 9:
            var h = _list_size(reader)
            for _ in range(h[0]):
                var pl = _parse_page_location(reader)
                if len(firsts) > 0 and pl[2] < firsts[len(firsts) - 1]:
                    raise Error(
                        "page_index_parser: OffsetIndex first rows do not"
                        " ascend"
                    )
                offsets.append(pl[0])
                sizes.append(pl[1])
                firsts.append(pl[2])
        else:
            reader._skip_field(wt)
    return OffsetIndex(
        offsets=offsets^,
        compressed_sizes=sizes^,
        first_row_indices=firsts^,
        num_pages=len(offsets),
    )
