# =============================================================================
# Writer Helpers — page-body compression, schema builders, statistics helpers
# =============================================================================
#
# Utility functions the page encoders share: compressing an encoded page
# body with the column's codec, building the flattened schema element list,
# and building the integer Statistics structs.
#
# No file I/O lives here. Writing the finished bytes is the job of the
# writer that owns the output (a later part of this package): its
# finish/close returns the file's metadata and commits nothing, and a sink
# above it decides when the files it staged are committed.
# =============================================================================

from komira_parquet_api.types import (
    CONVERTED_TYPE_UTF8,
    CompressionCodec,
    FieldRepetitionType,
    ParquetType,
)
from komira_parquet_api.metadata import SchemaElement, Statistics
from komira_parquet_codec.compression import compress, compress_bound


def _compress_page_body(
    codec: CompressionCodec,
    var body: List[UInt8],
) raises -> List[UInt8]:
    """Compress an already-encoded page body with the given codec.

    The one body-compress step every page encoder shares, so string and
    numeric pages get the same codec through the same call. The compression
    is applied to the FINAL page body bytes (after the dictionary or plain
    encode and the def-level prefix).

    Returns the body unchanged when `codec == UNCOMPRESSED` or the body is
    empty. Otherwise returns a new List holding the compressed bytes; the
    caller emits a page header whose `compressed_page_size == len(returned)`
    and `uncompressed_page_size == len(original body)`.

    Raises:
        What `komira_parquet_codec.compress` raises: an unsupported codec,
        or the deprecated LZ4 (id 5), which is read but never written.
    """
    var uncompressed_size = len(body)
    if codec == CompressionCodec.UNCOMPRESSED or uncompressed_size == 0:
        return body^

    var bound = compress_bound(codec, uncompressed_size)
    var out = List[UInt8](length=bound, fill=UInt8(0))
    var comp_len = compress(codec, Span(body), Span(out))
    out.resize(comp_len, UInt8(0))
    return out^


# =============================================================================
# Schema builder helpers
# =============================================================================


def make_schema_elements(var column_names: List[String], column_types: List[ParquetType]) raises -> List[SchemaElement]:
    """Build a flattened schema element list: every column REQUIRED, and every
    BYTE_ARRAY column annotated `ConvertedType.UTF8` (i.e. TEXT).

    ⛔ THIS IS A THIN WRAPPER ON PURPOSE, AND THE DELEGATION IS THE FIX.
    Building the element list a second time made it a SECOND spelling of one
    decision, and that copy once stamped no UTF8 on BYTE_ARRAY. BYTE_ARRAY
    with NO annotation IS `binary` in parquet.thrift, so every text column
    written through it read back as opaque bytes, to this engine and to
    pyarrow alike (`Column.as_string: arrow_type is binary, expected string`,
    and no GROUP BY over a string key).
    `tests/test_writer_helpers_direct.mojo` pins the annotation.

    ⛔ AND `binary` IS NOT EXPRESSIBLE HERE, WHICH IS WHY UTF8 IS
    UNCONDITIONAL RATHER THAN A DEFAULT. This signature has no per-column flag;
    a caller that means raw bytes must use `make_schema_elements_nullable`'s
    `column_binary` list. So a BYTE_ARRAY written through THIS helper has
    always MEANT text, and the file now says so.
    """
    # ⚠ THE ARITY CHECK STAYS HERE rather than being inherited: the delegate
    # raises under ITS OWN name, and a caller of this function debugging a
    # length mismatch should not be sent to a function it never called.
    if len(column_names) != len(column_types):
        raise Error(
            "make_schema_elements: column_names length ("
            + String(len(column_names))
            + ") != column_types length ("
            + String(len(column_types))
            + ")"
        )
    var column_nullable = List[Bool]()
    for _ in range(len(column_types)):
        column_nullable.append(False)
    return make_schema_elements_nullable(
        column_names^, column_types, column_nullable^
    )


def make_schema_elements_nullable(
    var column_names: List[String],
    column_types: List[ParquetType],
    column_nullable: List[Bool],
    column_binary: Optional[List[Bool]] = None,
) raises -> List[SchemaElement]:
    """Build a flattened schema element list with per-column nullability.

    Args:
        column_names: Names for each leaf column.
        column_types: Parquet physical type for each leaf column.
        column_nullable: Whether each column is OPTIONAL (True) or REQUIRED (False).
        column_binary: Optional per-column flag: for a BYTE_ARRAY
            column, True means write it as RAW BINARY (NO UTF8 ConvertedType)
            so a reader treats the bytes opaquely — required for a TRUE binary
            key column carrying embedded `0x00` / high bytes (a composite
            secondary-index `__key`). False (the default for every column when
            this list is omitted) stamps ConvertedType.UTF8 on a BYTE_ARRAY
            column (a STRING column).

    Returns:
        A list of SchemaElements: root group + one leaf per column.

    Raises:
        Error if the lists have different lengths.
    """
    if len(column_names) != len(column_types):
        raise Error(
            "make_schema_elements_nullable: column_names length ("
            + String(len(column_names))
            + ") != column_types length ("
            + String(len(column_types))
            + ")"
        )
    if len(column_names) != len(column_nullable):
        raise Error(
            "make_schema_elements_nullable: column_names length ("
            + String(len(column_names))
            + ") != column_nullable length ("
            + String(len(column_nullable))
            + ")"
        )
    if column_binary and len(column_binary.value()) != len(column_names):
        raise Error(
            "make_schema_elements_nullable: column_names length ("
            + String(len(column_names))
            + ") != column_binary length ("
            + String(len(column_binary.value()))
            + ")"
        )

    var elements = List[SchemaElement]()

    # Root element: group node named "schema"
    elements.append(SchemaElement(
        name=String("schema"),
        num_children=len(column_names),
    ))

    # Leaf elements: one per column
    for i in range(len(column_names)):
        var rep_type = FieldRepetitionType.OPTIONAL if column_nullable[i] else FieldRepetitionType.REQUIRED
        # Parquet ConvertedType.UTF8 = 0 — needed for BYTE_ARRAY to be
        # recognized as a string column by readers like pyarrow. A
        # column flagged binary suppresses UTF8 so a TRUE binary key
        # (embedded 0x00 / high bytes) is written as raw BINARY.
        var conv_type: Optional[Int] = None
        var is_binary = False
        if column_binary:
            is_binary = column_binary.value()[i]
        if column_types[i] == ParquetType.BYTE_ARRAY and not is_binary:
            conv_type = CONVERTED_TYPE_UTF8
        elements.append(SchemaElement(
            name=column_names[i],
            type=column_types[i],
            repetition_type=rep_type,
            converted_type=conv_type,
        ))

    return elements^


# =============================================================================
# Statistics helpers
# =============================================================================


def make_int64_statistics(
    min_val: Int64,
    max_val: Int64,
    null_count: Int = 0,
    distinct_count: Optional[Int] = None,
    var hll_registers: Optional[List[UInt8]] = None,
) -> Statistics:
    """Create Statistics for an Int64 column with min/max values.

    `distinct_count` is optional and intended for callers that have
    already computed a HyperLogLog estimate over the column. When
    omitted (None), the resulting Statistics will not emit field 4.

    `hll_registers` is the optional 4096-byte HLL precision-12 register
    state that backs the `distinct_count` estimate. When present the footer
    writer stores it in the chunk's key-value metadata (`hll_footer`), so
    cross-row-group readers can merge sketches via `HyperLogLog.merge`
    instead of summing scalar `distinct_count`.
    """
    var min_bytes = _encode_le_int64(min_val)
    var max_bytes = _encode_le_int64(max_val)
    return Statistics(
        null_count=null_count,
        distinct_count=distinct_count,
        min_value=min_bytes^,
        max_value=max_bytes^,
        hll_registers=hll_registers^,
    )


def make_int32_statistics(
    min_val: Int32,
    max_val: Int32,
    null_count: Int = 0,
    distinct_count: Optional[Int] = None,
    var hll_registers: Optional[List[UInt8]] = None,
) -> Statistics:
    """Create Statistics for an Int32 column with min/max values.

    `distinct_count` is optional and intended for callers that have
    already computed a HyperLogLog estimate over the column. When
    omitted (None), the resulting Statistics will not emit field 4.

    `hll_registers` is the optional 4096-byte HLL precision-12 register
    state that backs the `distinct_count` estimate. When present the footer
    writer stores it in the chunk's key-value metadata (`hll_footer`).
    """
    var min_bytes = _encode_le_int32(min_val)
    var max_bytes = _encode_le_int32(max_val)
    return Statistics(
        null_count=null_count,
        distinct_count=distinct_count,
        min_value=min_bytes^,
        max_value=max_bytes^,
        hll_registers=hll_registers^,
    )


def _encode_le_int64(value: Int64) -> List[UInt8]:
    """Encode an Int64 value as 8 little-endian bytes."""
    var bytes = List[UInt8]()
    var v = UInt64(value)
    for _ in range(8):
        bytes.append(UInt8(v & 0xFF))
        v = v >> 8
    return bytes^


def _encode_le_int32(value: Int32) -> List[UInt8]:
    """Encode an Int32 value as 4 little-endian bytes."""
    var bytes = List[UInt8]()
    var v = UInt32(value)
    for _ in range(4):
        bytes.append(UInt8(v & 0xFF))
        v = v >> 8
    return bytes^
