# =============================================================================
# Metadata Parser — full Thrift metadata parser for Parquet files
# =============================================================================
#
# Contains parse_full_metadata() and its helper functions for parsing the
# complete FileMetaData from the Thrift-encoded footer, including schema
# elements, row groups, column chunks, and statistics. The lighter parses
# that stop early (num_rows and the schema; num_rows alone) are in
# `footer_header`.
# =============================================================================

from komira_parquet_api.types import (
    ParquetType,
    Encoding,
    CompressionCodec,
    FieldRepetitionType,
)
from komira_parquet_api.metadata import (
    Statistics,
    SchemaElement,
    ColumnMetaData,
    ColumnChunk,
    RowGroup,
    FileMetaData,
    KeyValue,
)
from komira_parquet_api.hll_footer import (
    hll_registers_from_key_values,
    statistics_field_9_is_nan_count,
)
from .thrift_compact import ThriftCompactReader
from komira_buffer.byte_view import ByteView


# =============================================================================
# Full Thrift Metadata Parser
# =============================================================================


def parse_full_metadata[
    mut: Bool, //, origin: Origin[mut=mut]
](view: ByteView[origin]) raises -> FileMetaData:
    """Parse the complete FileMetaData from Thrift Compact Protocol bytes.

    Parameters:
        mut: Whether the source view's origin permits mutation (inferred).
        origin: Origin the view is tied to.

    Args:
        view: Origin-tied view over the Thrift-encoded metadata bytes.

    Returns:
        A fully populated FileMetaData.

    Raises:
        Error if the metadata is malformed.
    """
    var reader = ThriftCompactReader[origin](view)

    var version = 0
    var num_rows = 0
    var schema = List[SchemaElement]()
    var row_groups = List[RowGroup]()
    var created_by = Optional[String](None)
    var key_value_metadata = Optional[List[KeyValue]](None)

    while reader.pos < reader.data_len:
        var field = reader._read_field_header()
        var field_id = field[0]
        var wire_type = field[1]

        if wire_type == 0:
            break  # STOP

        if field_id == 1 and wire_type == 5:
            # version: i32 (zigzag)
            version = reader._read_zigzag()

        elif field_id == 2 and wire_type == 9:
            # schema: list<SchemaElement>
            var list_header = reader._read_byte()
            var list_size = (list_header >> 4) & 0x0F
            if list_size == 15:
                list_size = reader._read_varint()
            # Reject an element count the remaining bytes cannot contain,
            # before the append loop below turns it into unbounded heap growth.
            list_size = reader._checked_list_size(list_size)

            for _ in range(list_size):
                var elem = _parse_schema_element(reader)
                schema.append(elem^)

        elif field_id == 3 and wire_type == 6:
            # num_rows: i64 (zigzag)
            num_rows = reader._read_zigzag()

        elif field_id == 4 and wire_type == 9:
            # row_groups: list<RowGroup>
            var list_header = reader._read_byte()
            var list_size = (list_header >> 4) & 0x0F
            if list_size == 15:
                list_size = reader._read_varint()
            # Reject an element count the remaining bytes cannot contain,
            # before the append loop below turns it into unbounded heap growth.
            list_size = reader._checked_list_size(list_size)

            for _ in range(list_size):
                var rg = _parse_row_group(reader)
                row_groups.append(rg^)

        elif field_id == 5 and wire_type == 9:
            # key_value_metadata: list<KeyValue>
            #
            # Everything a writer puts in the footer's key-value metadata
            # (`ARROW:schema`, pandas metadata, a user's own key) is read
            # into `FileMetaData.key_value_metadata`.
            var kv_header = reader._read_byte()
            var kv_size = (kv_header >> 4) & 0x0F
            if kv_size == 15:
                kv_size = reader._read_varint()
            # As for schema / row_groups above: reject an element count the
            # remaining bytes cannot contain before the append loop turns it
            # into unbounded heap growth.
            kv_size = reader._checked_list_size(kv_size)
            var kvs = List[KeyValue]()
            for _ in range(kv_size):
                kvs.append(_parse_key_value(reader))
            if len(kvs) > 0:
                key_value_metadata = kvs^

        elif field_id == 6 and wire_type == 8:
            # created_by: string (binary)
            var str_len = reader._read_varint()
            if str_len > 0 and str_len <= reader.data_len - reader.pos:
                # Safe scalar byte-append — no wildcard-origin cast,
                # no memcpy pointer laundering. Per-byte reads go through
                # the origin-tied view. `created_by` is typically ~20
                # bytes; perf is not sensitive here.
                var bytes = List[UInt8](capacity=str_len + 1)
                for i in range(str_len):
                    bytes.append(reader.byte_at(reader.pos + i))
                bytes.append(0)
                reader.pos += str_len
                created_by = String(unsafe_from_utf8_ptr=bytes.unsafe_ptr())
            else:
                # An empty string, or a length past the end: the walk stops at
                # the end of the bytes, and `pos` is never moved past it.
                reader.pos += min(str_len, reader.data_len - reader.pos)
        else:
            reader._skip_field(wire_type)

    return FileMetaData(
        version=version,
        schema=schema^,
        num_rows=num_rows,
        row_groups=row_groups^,
        key_value_metadata=key_value_metadata^,
        created_by=created_by^,
    )


def _parse_time_unit[
    mut: Bool, //, origin: Origin[mut=mut]
](mut reader: ThriftCompactReader[origin]) raises -> Int:
    """Parse a thrift `TimeUnit` union and return the unit tag.

    `TimeUnit` is a union of three empty structs:
        union TimeUnit { 1: MILLIS; 2: MICROS; 3: NANOS }
    The set union member is encoded as a single struct-typed field whose
    field-id IS the unit tag (the member's value is an empty struct).
    Returns 1 (MILLIS), 2 (MICROS), or 3 (NANOS); 0 if unrecognized.
    """
    var saved = reader.prev_field_id
    reader.prev_field_id = 0
    var unit = 0
    while reader.pos < reader.data_len:
        var field = reader._read_field_header()
        var fid = field[0]
        var wt = field[1]
        if wt == 0:
            break  # STOP
        # The union member's value is an empty struct (wt == 12). Its field-id
        # is the unit tag. Skip the (empty) struct body either way.
        if fid == 1 or fid == 2 or fid == 3:
            unit = fid
        reader._skip_field(wt)
    reader.prev_field_id = saved
    return unit


def _parse_timestamp_logical[
    mut: Bool, //, origin: Origin[mut=mut]
](mut reader: ThriftCompactReader[origin]) raises -> Tuple[Int, Bool]:
    """Parse a thrift `TimestampType` struct.

        struct TimestampType { 1: bool isAdjustedToUTC; 2: TimeUnit unit }

    Returns (unit_tag, is_adjusted_to_utc). unit_tag is 1/2/3 (MILLIS/MICROS/
    NANOS) or 0 if absent.  In thrift compact, a bool field encodes its value
    in the field-header wire type itself (wt == 1 -> true, wt == 2 -> false),
    with no separate value byte.
    """
    var saved = reader.prev_field_id
    reader.prev_field_id = 0
    var unit = 0
    var is_utc = False
    while reader.pos < reader.data_len:
        var field = reader._read_field_header()
        var fid = field[0]
        var wt = field[1]
        if wt == 0:
            break  # STOP
        if fid == 1 and (wt == 1 or wt == 2):
            # isAdjustedToUTC: compact-bool rides the wire type (1=true).
            is_utc = wt == 1
        elif fid == 2 and wt == 12:
            unit = _parse_time_unit(reader)
        else:
            reader._skip_field(wt)
    reader.prev_field_id = saved
    return (unit, is_utc)


def _parse_logical_type[
    mut: Bool, //, origin: Origin[mut=mut]
](mut reader: ThriftCompactReader[origin]) raises -> Tuple[Int, Bool, Int]:
    """Parse a thrift `LogicalType` union (SchemaElement field 10).

    Covers the TIMESTAMP member (union field 8), plus the four members that
    annotate a BYTE_ARRAY as TEXT rather than as raw bytes.

        union LogicalType {
            1: StringType STRING   4: EnumType ENUM
            8: TimestampType TIMESTAMP
            12: JsonType JSON     13: BsonType BSON
            ...
        }

    The modern LogicalType union is the SAME statement as the deprecated
    ConvertedType field, so the third return value is the
    ConvertedType-EQUIVALENT of whichever text member was seen (UTF8=0 /
    ENUM=4 / JSON=19 / BSON=20, parquet.thrift's values), or -1 for none.
    `_parse_schema_element` backfills `converted_type` with it when field 6 is
    absent. Normalising HERE keeps the string/binary decision a one-integer
    question for every decoder. Most writers emit field 6 as well, so this
    serves a writer that emits only the modern spelling -- and the failure it
    prevents is a STRING column read back as BINARY.

    Returns (unit_tag, is_adjusted_to_utc, converted_equivalent); unit_tag 0
    when the element is not a LogicalType TIMESTAMP.
    """
    var saved = reader.prev_field_id
    reader.prev_field_id = 0
    var unit = 0
    var is_utc = False
    var conv_equiv = -1
    while reader.pos < reader.data_len:
        var field = reader._read_field_header()
        var fid = field[0]
        var wt = field[1]
        if wt == 0:
            break  # STOP
        if fid == 8 and wt == 12:
            var ts = _parse_timestamp_logical(reader)
            unit = ts[0]
            is_utc = ts[1]
        elif fid == 1 and wt == 12:
            conv_equiv = 0  # ConvertedType.UTF8
            reader._skip_field(wt)
        elif fid == 4 and wt == 12:
            conv_equiv = 4  # ConvertedType.ENUM
            reader._skip_field(wt)
        elif fid == 12 and wt == 12:
            conv_equiv = 19  # ConvertedType.JSON
            reader._skip_field(wt)
        elif fid == 13 and wt == 12:
            conv_equiv = 20  # ConvertedType.BSON
            reader._skip_field(wt)
        else:
            reader._skip_field(wt)
    reader.prev_field_id = saved
    return (unit, is_utc, conv_equiv)


def _parse_key_value[
    mut: Bool, //, origin: Origin[mut=mut]
](mut reader: ThriftCompactReader[origin]) raises -> KeyValue:
    """Parse one thrift `KeyValue` (FileMetaData field 5 element).

        struct KeyValue { 1: required string key, 2: optional string value }

    The value may be large and is copied: `ARROW:schema` is a base64
    flatbuffer and runs to a few KB on a wide schema.
    """
    var saved = reader.prev_field_id
    reader.prev_field_id = 0
    var key = String("")
    var value = Optional[String](None)
    while reader.pos < reader.data_len:
        var field = reader._read_field_header()
        var fid = field[0]
        var wt = field[1]
        if wt == 0:
            break  # STOP
        if (fid == 1 or fid == 2) and wt == 8:
            var str_len = reader._read_varint()
            var text = String("")
            if str_len > 0 and str_len <= reader.data_len - reader.pos:
                # Safe scalar byte-append -- no wildcard-origin cast, no
                # memcpy pointer laundering. Same idiom as `created_by`.
                var bytes = List[UInt8](capacity=str_len + 1)
                for i in range(str_len):
                    bytes.append(reader.byte_at(reader.pos + i))
                bytes.append(0)
                reader.pos += str_len
                text = String(unsafe_from_utf8_ptr=bytes.unsafe_ptr())
            else:
                # An empty string, or a length past the end: the walk stops at
                # the end of the bytes, and `pos` is never moved past it.
                reader.pos += min(str_len, reader.data_len - reader.pos)
            if fid == 1:
                key = text^
            else:
                value = text^
        else:
            reader._skip_field(wt)
    reader.prev_field_id = saved
    return KeyValue(key^, value^)


def _parse_schema_element[
    mut: Bool, //, origin: Origin[mut=mut]
](mut reader: ThriftCompactReader[origin]) raises -> SchemaElement:
    """Parse a single SchemaElement from a Thrift struct in a list."""
    var saved = reader.prev_field_id
    reader.prev_field_id = 0

    var name = String("")
    var ptype = Optional[ParquetType](None)
    var type_length = Optional[Int](None)
    var rep_type = Optional[FieldRepetitionType](None)
    var num_children = 0
    var converted_type = Optional[Int](None)
    var scale = Optional[Int](None)
    var precision = Optional[Int](None)
    var ts_unit = Optional[Int](None)
    var ts_is_utc = Optional[Bool](None)

    while reader.pos < reader.data_len:
        var field = reader._read_field_header()
        var fid = field[0]
        var wt = field[1]

        if wt == 0:
            break  # STOP

        if fid == 1 and wt == 5:
            ptype = ParquetType(reader._read_zigzag())
        elif fid == 2 and wt == 5:
            type_length = reader._read_zigzag()
        elif fid == 3 and wt == 5:
            rep_type = FieldRepetitionType(reader._read_zigzag())
        elif fid == 4 and wt == 8:
            var str_len = reader._read_varint()
            if str_len > 0 and str_len <= reader.data_len - reader.pos:
                # Safe scalar byte-append — no wildcard-origin cast.
                # Schema element names are short (few dozen bytes); perf
                # is not sensitive.
                var bytes = List[UInt8](capacity=str_len + 1)
                for i in range(str_len):
                    bytes.append(reader.byte_at(reader.pos + i))
                bytes.append(0)
                reader.pos += str_len
                name = String(unsafe_from_utf8_ptr=bytes.unsafe_ptr())
            else:
                # An empty string, or a length past the end: the walk stops at
                # the end of the bytes, and `pos` is never moved past it.
                reader.pos += min(str_len, reader.data_len - reader.pos)
        elif fid == 5 and wt == 5:
            num_children = reader._read_zigzag()
        elif fid == 6 and wt == 5:
            converted_type = reader._read_zigzag()
        elif fid == 7 and wt == 5:
            scale = reader._read_zigzag()
        elif fid == 8 and wt == 5:
            precision = reader._read_zigzag()
        elif fid == 10 and wt == 12:
            # logicalType: LogicalType union (modern annotation): the
            # TIMESTAMP member and the four text members.
            var lt = _parse_logical_type(reader)
            if lt[0] != 0:
                ts_unit = lt[0]
                ts_is_utc = lt[1]
            # Backfill the deprecated ConvertedType from the modern union
            # when field 6 is ABSENT.
            # Never OVERRIDE an explicit field 6 -- where both are present
            # they say the same thing, and trusting the one the writer chose
            # to emit first keeps this a pure widening.
            if lt[2] >= 0 and not converted_type:
                converted_type = lt[2]
        else:
            reader._skip_field(wt)

    reader.prev_field_id = saved
    return SchemaElement(
        name=name,
        type=ptype^,
        type_length=type_length^,
        repetition_type=rep_type^,
        num_children=num_children,
        converted_type=converted_type^,
        scale=scale^,
        precision=precision^,
        logical_timestamp_unit=ts_unit^,
        logical_timestamp_is_utc=ts_is_utc^,
    )


def _parse_row_group[
    mut: Bool, //, origin: Origin[mut=mut]
](mut reader: ThriftCompactReader[origin]) raises -> RowGroup:
    """Parse a RowGroup from a Thrift struct in a list."""
    var saved = reader.prev_field_id
    reader.prev_field_id = 0

    var columns = List[ColumnChunk]()
    var total_byte_size = 0
    var num_rows = 0

    while reader.pos < reader.data_len:
        var field = reader._read_field_header()
        var fid = field[0]
        var wt = field[1]

        if wt == 0:
            break

        if fid == 1 and wt == 9:
            # columns: list<ColumnChunk>
            var list_hdr = reader._read_byte()
            var list_size = (list_hdr >> 4) & 0x0F
            if list_size == 15:
                list_size = reader._read_varint()
            # Reject an element count the remaining bytes cannot contain,
            # before the append loop below turns it into unbounded heap growth.
            list_size = reader._checked_list_size(list_size)
            for _ in range(list_size):
                var cc = _parse_column_chunk(reader)
                columns.append(cc^)
        elif fid == 2 and wt == 6:
            total_byte_size = reader._read_zigzag()
        elif fid == 3 and wt == 6:
            num_rows = reader._read_zigzag()
        else:
            reader._skip_field(wt)

    reader.prev_field_id = saved
    return RowGroup(
        columns=columns^,
        total_byte_size=total_byte_size,
        num_rows=num_rows,
    )


def _parse_column_chunk[
    mut: Bool, //, origin: Origin[mut=mut]
](mut reader: ThriftCompactReader[origin]) raises -> ColumnChunk:
    """Parse a ColumnChunk from a Thrift struct in a list.

    Per the Apache Parquet thrift spec, ColumnChunk has these fields:
        1: file_path (optional string)
        2: file_offset (required i64)
        3: meta_data (optional ColumnMetaData)
        4: offset_index_offset (optional i64)
        5: offset_index_length (optional i32)
        6: column_index_offset (optional i64)
        7: column_index_length (optional i32)
        8: crypto_metadata (skipped)
        9: encrypted_column_metadata (skipped)

    Fields 4-7 carry the page-index pointer payload that lets the reader
    fetch + parse the per-page min/max stats.
    """
    var saved = reader.prev_field_id
    reader.prev_field_id = 0

    var file_offset = 0
    var meta = Optional[ColumnMetaData](None)
    var col_idx_offset = Optional[Int](None)
    var col_idx_length = Optional[Int](None)
    var off_idx_offset = Optional[Int](None)
    var off_idx_length = Optional[Int](None)

    while reader.pos < reader.data_len:
        var field = reader._read_field_header()
        var fid = field[0]
        var wt = field[1]

        if wt == 0:
            break

        if fid == 2 and wt == 6:
            file_offset = reader._read_zigzag()
        elif fid == 3 and wt == 12:
            meta = _parse_column_metadata(reader)
        elif fid == 4 and wt == 6:
            # offset_index_offset (i64 zigzag).
            off_idx_offset = reader._read_zigzag()
        elif fid == 5 and (wt == 5 or wt == 6):
            # offset_index_length (i32 zigzag); accept i64 for tolerance.
            off_idx_length = reader._read_zigzag()
        elif fid == 6 and wt == 6:
            # column_index_offset (i64 zigzag).
            col_idx_offset = reader._read_zigzag()
        elif fid == 7 and (wt == 5 or wt == 6):
            # column_index_length (i32 zigzag); accept i64 for tolerance.
            col_idx_length = reader._read_zigzag()
        else:
            reader._skip_field(wt)

    reader.prev_field_id = saved

    if not meta:
        raise Error("parquet: ColumnChunk missing meta_data")

    # `meta.take()`, not `meta.value().copy()`: `meta` is dead after this
    # return, so a copy would deep-copy the chunk's encodings, path and
    # statistics bytes once per column chunk for nothing.
    return ColumnChunk(
        file_offset=file_offset,
        meta_data=meta.take(),
        column_index_offset=col_idx_offset^,
        column_index_length=col_idx_length^,
        offset_index_offset=off_idx_offset^,
        offset_index_length=off_idx_length^,
    )


def _parse_column_metadata[
    mut: Bool, //, origin: Origin[mut=mut]
](mut reader: ThriftCompactReader[origin]) raises -> ColumnMetaData:
    """Parse ColumnMetaData from a Thrift struct."""
    var saved = reader.prev_field_id
    reader.prev_field_id = 0

    var ptype = ParquetType.INT32
    var encodings = List[Encoding]()
    var path_in_schema = List[String]()
    var codec = CompressionCodec.UNCOMPRESSED
    var num_values = 0
    var total_uncompressed_size = 0
    var total_compressed_size = 0
    var data_page_offset = 0
    var index_page_offset = Optional[Int](None)
    var dictionary_page_offset = Optional[Int](None)
    var statistics = Optional[Statistics](None)
    # Fields 14 + 15, optional per parquet.thrift ColumnMetaData: the
    # byte range of the column chunk's bloom filter.
    var bloom_filter_offset = Optional[Int](None)
    var bloom_filter_length = Optional[Int](None)
    # Field 8: the column chunk's own key-value metadata, where this
    # project's writers put the chunk's HLL registers (`hll_footer`).
    var key_value_metadata = Optional[List[KeyValue]](None)

    while reader.pos < reader.data_len:
        var field = reader._read_field_header()
        var fid = field[0]
        var wt = field[1]

        if wt == 0:
            break

        if fid == 1 and wt == 5:
            ptype = ParquetType(reader._read_zigzag())
        elif fid == 2 and wt == 9:
            # encodings: list<Encoding>
            var list_hdr = reader._read_byte()
            var list_size = (list_hdr >> 4) & 0x0F
            if list_size == 15:
                list_size = reader._read_varint()
            # Reject an element count the remaining bytes cannot contain,
            # before the append loop below turns it into unbounded heap growth.
            list_size = reader._checked_list_size(list_size)
            var elem_type = list_hdr & 0x0F
            for _ in range(list_size):
                if elem_type == 5:
                    encodings.append(Encoding(reader._read_zigzag()))
                else:
                    reader._skip_field(elem_type)
        elif fid == 3 and wt == 9:
            # path_in_schema: list<string>
            var list_hdr = reader._read_byte()
            var list_size = (list_hdr >> 4) & 0x0F
            if list_size == 15:
                list_size = reader._read_varint()
            # Reject an element count the remaining bytes cannot contain,
            # before the append loop below turns it into unbounded heap growth.
            list_size = reader._checked_list_size(list_size)
            for _ in range(list_size):
                var str_len = reader._read_varint()
                if str_len > 0 and str_len <= reader.data_len - reader.pos:
                    # Safe scalar byte-append — no wildcard-origin cast.
                    # Column path segments are short identifiers; not
                    # perf-sensitive.
                    var bytes = List[UInt8](capacity=str_len + 1)
                    for i in range(str_len):
                        bytes.append(reader.byte_at(reader.pos + i))
                    bytes.append(0)
                    reader.pos += str_len
                    path_in_schema.append(
                        String(unsafe_from_utf8_ptr=bytes.unsafe_ptr())
                    )
                else:
                    # An empty string, or a length past the end: the walk stops at
                    # the end of the bytes, and `pos` is never moved past it.
                    reader.pos += min(str_len, reader.data_len - reader.pos)
        elif fid == 4 and wt == 5:
            codec = CompressionCodec(reader._read_zigzag())
        elif fid == 5 and wt == 6:
            num_values = reader._read_zigzag()
        elif fid == 6 and wt == 6:
            total_uncompressed_size = reader._read_zigzag()
        elif fid == 7 and wt == 6:
            total_compressed_size = reader._read_zigzag()
        elif fid == 8 and wt == 9:
            # key_value_metadata: list<KeyValue>
            var kv_hdr = reader._read_byte()
            var kv_size = (kv_hdr >> 4) & 0x0F
            if kv_size == 15:
                kv_size = reader._read_varint()
            kv_size = reader._checked_list_size(kv_size)
            var kvs = List[KeyValue]()
            for _ in range(kv_size):
                kvs.append(_parse_key_value(reader))
            key_value_metadata = kvs^
        elif fid == 9 and wt == 6:
            data_page_offset = reader._read_zigzag()
        elif fid == 10 and wt == 6:
            index_page_offset = reader._read_zigzag()
        elif fid == 11 and wt == 6:
            dictionary_page_offset = reader._read_zigzag()
        elif fid == 12 and wt == 12:
            # statistics: Statistics (struct)
            statistics = _parse_statistics(reader)
        elif fid == 14 and wt == 6:
            # bloom_filter_offset: i64 (optional). Wire-type 6 = i64
            # zigzag varint per Thrift Compact spec.
            bloom_filter_offset = reader._read_zigzag()
        elif fid == 15 and (wt == 5 or wt == 6):
            # bloom_filter_length: i32 (optional), wire-type 5 (i32
            # zigzag). Accept wire-type 6 (i64 zigzag) as well, for
            # writers that widen it.
            bloom_filter_length = reader._read_zigzag()
        else:
            reader._skip_field(wt)

    reader.prev_field_id = saved
    # The chunk's HLL registers travel in its key-value metadata
    # (`hll_footer`), never in Statistics field 9. A damaged sketch is
    # dropped: the chunk then has none, and a reader falls back to
    # `distinct_count`.
    if statistics and key_value_metadata:
        try:
            statistics.value().hll_registers = hll_registers_from_key_values(
                key_value_metadata.value()
            )
        except:
            pass
    return ColumnMetaData(
        type=ptype,
        encodings=encodings^,
        path_in_schema=path_in_schema^,
        codec=codec,
        num_values=num_values,
        total_uncompressed_size=total_uncompressed_size,
        total_compressed_size=total_compressed_size,
        data_page_offset=data_page_offset,
        index_page_offset=index_page_offset^,
        dictionary_page_offset=dictionary_page_offset^,
        statistics=statistics^,
        bloom_filter_offset=bloom_filter_offset^,
        bloom_filter_length=bloom_filter_length^,
        key_value_metadata=key_value_metadata^,
    )


def _parse_statistics[
    mut: Bool, //, origin: Origin[mut=mut]
](mut reader: ThriftCompactReader[origin]) raises -> Statistics:
    """Parse Statistics from a Thrift struct (field 12 of ColumnMetaData)."""
    var saved = reader.prev_field_id
    reader.prev_field_id = 0

    var null_count = Optional[Int](None)
    var distinct_count = Optional[Int](None)
    var min_value = Optional[List[UInt8]](None)
    var max_value = Optional[List[UInt8]](None)
    var is_min_value_exact = True
    var is_max_value_exact = True
    # Field 9 is parquet.thrift's `nan_count` (an i64). The HLL registers
    # are not a Statistics field; `_parse_column_metadata` reads them from
    # the chunk's key-value metadata.
    var nan_count = Optional[Int](None)

    while reader.pos < reader.data_len:
        var field = reader._read_field_header()
        var fid = field[0]
        var wt = field[1]

        if wt == 0:
            break

        if fid == 1 and wt == 8:
            # legacy max (binary) -- skip
            var bin_len = reader._read_varint()
            reader.pos += bin_len
        elif fid == 2 and wt == 8:
            # legacy min (binary) -- skip
            var bin_len = reader._read_varint()
            reader.pos += bin_len
        elif fid == 3 and wt == 6:
            null_count = reader._read_zigzag()
        elif fid == 4 and wt == 6:
            distinct_count = reader._read_zigzag()
        elif fid == 5 and wt == 8:
            # max_value (binary) — fast bulk-copy via pre-sized List.
            # See ThriftCompactReader._read_binary_to_list.
            var bin_len = reader._read_varint()
            max_value = reader._read_binary_to_list(bin_len)
        elif fid == 6 and wt == 8:
            # min_value (binary)
            var bin_len = reader._read_varint()
            min_value = reader._read_binary_to_list(bin_len)
        elif fid == 7 and (wt == 1 or wt == 2):
            is_max_value_exact = (wt == 1)
        elif fid == 8 and (wt == 1 or wt == 2):
            is_min_value_exact = (wt == 1)
        elif fid == 9 and statistics_field_9_is_nan_count(UInt8(wt)):
            # nan_count: i64 (optional). A field 9 of any other wire type
            # is skipped.
            nan_count = reader._read_zigzag()
        else:
            reader._skip_field(wt)

    reader.prev_field_id = saved
    return Statistics(
        null_count=null_count^,
        distinct_count=distinct_count^,
        min_value=min_value^,
        max_value=max_value^,
        is_min_value_exact=is_min_value_exact,
        is_max_value_exact=is_max_value_exact,
        nan_count=nan_count^,
    )
