# =============================================================================
# Page Header Parser — Thrift Compact Protocol page header parsing
# =============================================================================
#
# Contains the PageHeaderResult struct and _parse_page_header(),
# _parse_data_page_header(), _parse_dict_page_header() and
# _parse_data_page_header_v2() for parsing Parquet page headers.
# =============================================================================

from komira_parquet_api.types import PageType, Encoding
from komira_parquet_api.metadata import PageHeader
from .thrift_compact import ThriftCompactReader
from komira_buffer.byte_view import ByteView


# =============================================================================
# Page header parser (Thrift Compact Protocol)
# =============================================================================


struct PageHeaderResult(Movable):
    """Result of parsing a page header: the header and bytes consumed.

    Fields:
        header: The parsed PageHeader.
        bytes_consumed: Number of bytes consumed from the input.
    """

    var header: PageHeader
    var bytes_consumed: Int

    def __init__(out self, var header: PageHeader, bytes_consumed: Int):
        self.header = header^
        self.bytes_consumed = bytes_consumed


def _parse_page_header[
    mut: Bool, //, o: Origin[mut=mut]
](data: Span[UInt8, o]) raises -> PageHeaderResult:
    """Parse a Parquet PageHeader from Thrift Compact Protocol bytes.

    Returns (PageHeader, bytes_consumed).

    The PageHeader Thrift structure:
        field 1: type (PageType, i32)
        field 2: uncompressed_page_size (i32)
        field 3: compressed_page_size (i32)
        field 5: data_page_header (struct with num_values, encoding, etc.)
        field 7: dictionary_page_header (struct with num_values, encoding)
        field 8: data_page_header_v2 (struct)

    Args:
        data: The bytes from the start of the page header to the end of the
              available input. All thrift field access routes through the
              reader's bounds-checked helpers, so a header that runs past
              the end of `data` raises.

    Returns:
        Tuple of (parsed PageHeader, bytes consumed).

    Raises:
        Error if the header is malformed.
    """
    # SAFETY: the pointer and length are the Span's own, so the view covers
    # exactly `data`. The Span's origin `o` flows through ByteView[o] into
    # ThriftCompactReader, so the reader's lifetime is tied to the input.
    var view = ByteView[o](data.unsafe_ptr(), len(data))
    var reader = ThriftCompactReader(view)

    var page_type = PageType.DATA_PAGE
    var uncompressed_size = 0
    var compressed_size = 0
    var num_values = 0
    var encoding = Encoding.PLAIN
    var def_enc = Encoding.RLE
    var rep_enc = Encoding.RLE
    # None => page header had no `crc` field (optional per Parquet Thrift
    # spec).
    var crc_value = Optional[UInt32](None)
    # V2-specific fields (zero for V1 / dict pages, populated on V2 pages).
    # `def_levels_byte_length` and `rep_levels_byte_length` are consumed
    # by the column decoder to split the uncompressed level
    # bytes from the compressed values bytes; `is_compressed` controls
    # whether the values portion is decompressed.
    var num_nulls = 0
    var num_rows = 0
    var def_levels_byte_length = 0
    var rep_levels_byte_length = 0
    var is_compressed = True

    while reader.pos < reader.data_len:
        var field = reader._read_field_header()
        var fid = field[0]
        var wt = field[1]

        if wt == 0:
            break

        if fid == 1 and wt == 5:
            page_type = PageType(reader._read_zigzag())
        elif fid == 2 and wt == 5:
            uncompressed_size = reader._read_zigzag()
        elif fid == 3 and wt == 5:
            compressed_size = reader._read_zigzag()
        elif fid == 4 and wt == 5:
            # crc: optional i32 (zigzag), kept as its unsigned 32-bit value.
            crc_value = UInt32(reader._read_zigzag() & 0xFFFFFFFF)
        elif fid == 5 and wt == 12:
            # DataPageHeader
            var dph = _parse_data_page_header(reader)
            num_values = dph[0]
            encoding = Encoding(dph[1])
        elif fid == 7 and wt == 12:
            # DictionaryPageHeader (field 7 per Parquet Thrift spec)
            var dph = _parse_dict_page_header(reader)
            num_values = dph[0]
            encoding = Encoding(dph[1])
        elif fid == 8 and wt == 12:
            # DataPageHeaderV2 (field 8 per Parquet Thrift spec). Parse
            # every field so the column decoder can split
            # [rep_levels | def_levels | values] correctly — the level
            # sections are uncompressed and the values section follows
            # the `is_compressed` flag.
            var v2 = _parse_data_page_header_v2(reader)
            num_values = v2[0]
            num_nulls = v2[1]
            num_rows = v2[2]
            encoding = Encoding(v2[3])
            def_levels_byte_length = v2[4]
            rep_levels_byte_length = v2[5]
            is_compressed = v2[6] != 0
        else:
            reader._skip_field(wt)

    # =====================================================================
    # Validation at construction.
    #
    # Every page loop that consumes this header (the column decoder, the
    # gather paths, the nested decoder, the morsel reader) relies on these
    # checks, so no consumer can observe an internally-inconsistent
    # PageHeader. The cost is one branch bundle per PAGE (not per value /
    # per row), so it is off every hot loop. Without them, the sizes below
    # would feed memcpy / decompress / alloc unchecked.
    # =====================================================================
    if uncompressed_size < 0 or compressed_size < 0:
        raise Error(
            "parquet: corrupt page header: negative page size"
            " (compressed_page_size="
            + String(compressed_size)
            + ", uncompressed_page_size="
            + String(uncompressed_size)
            + ")"
        )
    if num_values < 0:
        raise Error(
            "parquet: corrupt page header: negative num_values "
            + String(num_values)
        )
    if page_type == PageType.DATA_PAGE_V2:
        # DataPageHeaderV2 layout is [rep_levels | def_levels | values].
        # BOTH page sizes count the (always-uncompressed) level sections,
        # so `rep + def` must fit inside each. Without this the consumer
        # computes `values_len = page_size - levels_total` and hands a
        # NEGATIVE length to the codec, where it is reinterpreted as a
        # ~2^64 size_t capacity — an unbounded heap WRITE of
        # codec-expanded input. It also makes `page_data + levels_total` an
        # unbounded pointer offset and the level memcpy overflow its
        # `uncompressed_page_size`-sized dest.
        if def_levels_byte_length < 0 or rep_levels_byte_length < 0:
            raise Error(
                "parquet: corrupt DataPageHeaderV2: negative level length"
                " (def_levels_byte_length="
                + String(def_levels_byte_length)
                + ", rep_levels_byte_length="
                + String(rep_levels_byte_length)
                + ")"
            )
        var levels_total = def_levels_byte_length + rep_levels_byte_length
        if levels_total > compressed_size or levels_total > uncompressed_size:
            raise Error(
                "parquet: corrupt DataPageHeaderV2: level bytes "
                + String(levels_total)
                + " exceed the page body (compressed_page_size="
                + String(compressed_size)
                + ", uncompressed_page_size="
                + String(uncompressed_size)
                + ")"
            )
        if num_nulls < 0 or num_rows < 0:
            raise Error(
                "parquet: corrupt DataPageHeaderV2: negative num_nulls/"
                "num_rows (num_nulls="
                + String(num_nulls)
                + ", num_rows="
                + String(num_rows)
                + ")"
            )
        if num_nulls > num_values:
            raise Error(
                "parquet: corrupt DataPageHeaderV2: num_nulls "
                + String(num_nulls)
                + " exceeds num_values "
                + String(num_values)
            )

    var hdr = PageHeader(
        type=page_type,
        uncompressed_page_size=uncompressed_size,
        compressed_page_size=compressed_size,
        num_values=num_values,
        encoding=encoding,
        definition_level_encoding=def_enc,
        repetition_level_encoding=rep_enc,
        crc=crc_value,
        num_nulls=num_nulls,
        num_rows=num_rows,
        def_levels_byte_length=def_levels_byte_length,
        rep_levels_byte_length=rep_levels_byte_length,
        is_compressed=is_compressed,
    )
    return PageHeaderResult(hdr^, reader.pos)


def _parse_data_page_header[
    mut: Bool, //, origin: Origin[mut=mut]
](mut reader: ThriftCompactReader[origin]) raises -> Tuple[Int, Int]:
    """Parse DataPageHeader fields. Returns (num_values, encoding_value)."""
    var saved = reader.prev_field_id
    reader.prev_field_id = 0

    var num_values = 0
    var encoding_val = 0

    while reader.pos < reader.data_len:
        var field = reader._read_field_header()
        var fid = field[0]
        var wt = field[1]

        if wt == 0:
            break

        if fid == 1 and wt == 5:
            num_values = reader._read_zigzag()
        elif fid == 2 and wt == 5:
            encoding_val = reader._read_zigzag()
        else:
            reader._skip_field(wt)

    reader.prev_field_id = saved
    return (num_values, encoding_val)


def _parse_dict_page_header[
    mut: Bool, //, origin: Origin[mut=mut]
](mut reader: ThriftCompactReader[origin]) raises -> Tuple[Int, Int]:
    """Parse DictionaryPageHeader fields. Returns (num_values, encoding_value)."""
    var saved = reader.prev_field_id
    reader.prev_field_id = 0

    var num_values = 0
    var encoding_val = 0  # PLAIN for dict page

    while reader.pos < reader.data_len:
        var field = reader._read_field_header()
        var fid = field[0]
        var wt = field[1]

        if wt == 0:
            break

        if fid == 1 and wt == 5:
            num_values = reader._read_zigzag()
        elif fid == 2 and wt == 5:
            encoding_val = reader._read_zigzag()
        else:
            reader._skip_field(wt)

    reader.prev_field_id = saved
    return (num_values, encoding_val)


def _parse_data_page_header_v2[
    mut: Bool, //, origin: Origin[mut=mut]
](
    mut reader: ThriftCompactReader[origin],
) raises -> Tuple[Int, Int, Int, Int, Int, Int, Int]:
    """Parse DataPageHeaderV2 fields from Thrift Compact Protocol.

    DataPageHeaderV2 Thrift fields (parquet.thrift):
        field 1: num_values (i32)
        field 2: num_nulls (i32)
        field 3: num_rows (i32)
        field 4: encoding (i32, Encoding enum)
        field 5: def_levels_byte_length (i32)
        field 6: rep_levels_byte_length (i32)
        field 7: is_compressed (bool, default true — Thrift Compact
                 encodes bool values in the wire-type nibble itself,
                 so wire_type == 1 means true and wire_type == 2
                 means false; no extra payload bytes follow.)

    Returns a 7-tuple instead of a struct; the caller unpacks it
    directly into the enclosing `PageHeader`. `is_compressed` is
    returned as `1`/`0` (not Bool) so the tuple holds one element
    type; the caller converts with `v2[6] != 0`.

    Returns:
        (num_values, num_nulls, num_rows, encoding_val,
         def_levels_byte_length, rep_levels_byte_length,
         is_compressed_int)
    """
    var saved = reader.prev_field_id
    reader.prev_field_id = 0

    var num_values = 0
    var num_nulls = 0
    var num_rows = 0
    var encoding_val = 0
    var def_levels_byte_length = 0
    var rep_levels_byte_length = 0
    var is_compressed_int = 1  # Default: true (per Parquet Thrift spec).

    while reader.pos < reader.data_len:
        var field = reader._read_field_header()
        var fid = field[0]
        var wt = field[1]

        if wt == 0:
            break

        if fid == 1 and wt == 5:
            num_values = reader._read_zigzag()
        elif fid == 2 and wt == 5:
            num_nulls = reader._read_zigzag()
        elif fid == 3 and wt == 5:
            num_rows = reader._read_zigzag()
        elif fid == 4 and wt == 5:
            encoding_val = reader._read_zigzag()
        elif fid == 5 and wt == 5:
            def_levels_byte_length = reader._read_zigzag()
        elif fid == 6 and wt == 5:
            rep_levels_byte_length = reader._read_zigzag()
        elif fid == 7 and (wt == 1 or wt == 2):
            # Thrift Compact boolean: the value lives in the wire type.
            # wire_type == 1 => true, wire_type == 2 => false.
            is_compressed_int = 1 if wt == 1 else 0
        else:
            reader._skip_field(wt)

    reader.prev_field_id = saved
    return (
        num_values,
        num_nulls,
        num_rows,
        encoding_val,
        def_levels_byte_length,
        rep_levels_byte_length,
        is_compressed_int,
    )
