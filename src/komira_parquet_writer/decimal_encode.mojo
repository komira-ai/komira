# =============================================================================
# Decimal128 -> Parquet DECIMAL as FIXED_LEN_BYTE_ARRAY(16)
# =============================================================================
#
# An Arrow Decimal128 element is a 16-byte little-endian two's-complement
# i128 (the unscaled value). This writer always emits it as
# FIXED_LEN_BYTE_ARRAY(16) holding the same i128 BIG-endian, which
# parquet.thrift allows for every precision 1..38, so no precision decides
# the physical type. The schema element carries type_length 16,
# ConvertedType DECIMAL, precision and scale.
#
# Statistics: min/max are the i128 extremes in the same 16-byte big-endian
# form; DECIMAL's type-defined order is signed numeric order, which is the
# order of the i128s.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.schema import Schema
from komira_buffer.heap_region import HeapRegion
from komira_parquet_api.metadata import SchemaElement, Statistics
from komira_parquet_api.types import (
    CONVERTED_TYPE_DECIMAL,
    CompressionCodec,
    Encoding,
    FieldRepetitionType,
    ParquetType,
)

from .column_page import ColumnPage, _assemble_data_page, _require_no_nulls_when_required
from .writer_encode import _def_levels


comptime _I128 = SIMD[DType.int128, 1]
comptime DECIMAL_FLBA_WIDTH = 16


def decimal128_schema_element(
    var name: String, precision: Int, scale: Int, nullable: Bool
) raises -> SchemaElement:
    """The schema element of a FIXED_LEN_BYTE_ARRAY(16) DECIMAL leaf.

    Raises:
        Error: precision outside [1, 38] or scale outside [0, precision].
            Clamping either would change what every stored value means.
    """
    if precision < 1 or precision > 38:
        raise Error(
            "decimal128_schema_element: column '"
            + name
            + "' precision "
            + String(precision)
            + " is outside [1, 38]"
        )
    if scale < 0 or scale > precision:
        raise Error(
            "decimal128_schema_element: column '"
            + name
            + "' scale "
            + String(scale)
            + " is outside [0, precision "
            + String(precision)
            + "]"
        )
    var rep = FieldRepetitionType.OPTIONAL if nullable else FieldRepetitionType.REQUIRED
    return SchemaElement(
        name=name^,
        type=ParquetType.FIXED_LEN_BYTE_ARRAY,
        type_length=DECIMAL_FLBA_WIDTH,
        repetition_type=rep,
        num_children=0,
        converted_type=CONVERTED_TYPE_DECIMAL,
        scale=scale,
        precision=precision,
    )


def patch_decimal_schema_elements(
    mut elements: List[SchemaElement], schema: Schema
) raises:
    """Rewrite the element of every DECIMAL128 leaf of `schema` to the
    FIXED_LEN_BYTE_ARRAY(16) DECIMAL shape. `elements` is the flattened
    `[root, leaf_0, leaf_1, ...]` list the schema builders return.

    Raises:
        Error: `elements` has fewer leaves than `schema` has columns, or a
            decimal column's precision / scale is invalid.
    """
    var n = schema.num_columns()
    if len(elements) < n + 1:
        raise Error(
            "patch_decimal_schema_elements: "
            + String(len(elements) - 1)
            + " leaf element(s) for "
            + String(n)
            + " column(s)"
        )
    for c in range(n):
        if schema.field_arrow_type(c) != ArrowType.DECIMAL128:
            continue
        elements[c + 1] = decimal128_schema_element(
            schema.field_name(c),
            schema.field_decimal_precision(c),
            schema.field_decimal_scale(c),
            schema.field_nullable(c),
        )


def _i128_to_be16(v: _I128, mut out: List[UInt8]):
    """Append `v` as 16 big-endian two's-complement bytes."""
    for i in range(16):
        out.append(UInt8(Int((v >> _I128(8 * (15 - i))) & _I128(0xFF))))


def _is_valid(arr: Decimal128Array[HeapRegion], i: Int) -> Bool:
    if not arr.validity:
        return True
    return arr.validity.value().test(i)


def encode_decimal128_column_page(
    column_index: Int,
    arr: Decimal128Array[HeapRegion],
    column_name: String,
    nullable: Bool,
    codec: CompressionCodec = CompressionCodec.UNCOMPRESSED,
) raises -> ColumnPage:
    """A Decimal128 column as one PLAIN FIXED_LEN_BYTE_ARRAY(16) data page,
    with min/max statistics over its non-null values.

    Raises:
        Error: a REQUIRED column holding a null, or a page over the i32
            PageHeader ceiling.
    """
    _require_no_nulls_when_required(
        "encode_decimal128_column_page", column_name, nullable, arr.null_count
    )
    var n = arr.length
    var values = List[UInt8](capacity=max((n - arr.null_count) * DECIMAL_FLBA_WIDTH, 1))
    var seen = False
    var lo = _I128(0)
    var hi = _I128(0)
    for i in range(n):
        if arr.null_count > 0 and not _is_valid(arr, i):
            continue
        var v = arr.get_i128(i)
        _i128_to_be16(v, values)
        if not seen:
            lo = v
            hi = v
            seen = True
        else:
            if v < lo:
                lo = v
            if v > hi:
                hi = v

    var stats = Statistics(null_count=arr.null_count)
    if seen:
        var lo_bytes = List[UInt8](capacity=DECIMAL_FLBA_WIDTH)
        var hi_bytes = List[UInt8](capacity=DECIMAL_FLBA_WIDTH)
        _i128_to_be16(lo, lo_bytes)
        _i128_to_be16(hi, hi_bytes)
        stats = Statistics(
            null_count=arr.null_count, min_value=lo_bytes^, max_value=hi_bytes^
        )

    var def_levels = List[UInt8]()
    if nullable:
        def_levels = _def_levels(arr.validity, 0, n, arr.null_count)
    return _assemble_data_page(
        column_index,
        n,
        def_levels,
        values,
        ParquetType.FIXED_LEN_BYTE_ARRAY,
        column_name,
        Encoding.PLAIN,
        nullable,
        codec,
        Optional[Statistics](stats^),
    )
