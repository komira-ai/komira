# =============================================================================
# RecordBatch -> Parquet schema: physical types, nullability, annotations
# =============================================================================
#
# The schema elements a file of Arrow batches declares, derived once and used
# by every row group:
#
#   * the Parquet physical type of each Arrow type, which MUST be the layout
#     the page encoder emits for the same column (the encoder keys on the
#     column's Arrow type, this map on the schema field's; a divergence
#     writes a file whose schema says one width while its pages carry
#     another);
#   * OPTIONAL or REQUIRED per column (the page encoders write definition
#     levels exactly for OPTIONAL columns);
#   * DECIMAL128 as FIXED_LEN_BYTE_ARRAY(16) with its DECIMAL annotation, and
#     DATE32 with ConvertedType DATE.
#
# What is not written is refused here, before any page is encoded: a type with
# no encoder (BINARY, nested types, small or unsigned integers, ...) raises
# instead of being declared as INT64 and failing, or worse succeeding, later.
# TIMESTAMP, DATE64, TIME and DURATION columns are written as their INT64
# or INT32 storage with NO logical-type annotation (the footer carries no unit
# or time zone for them): the values are right and a reader sees integers.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema
from komira_parquet_api.metadata import SchemaElement
from komira_parquet_api.types import CONVERTED_TYPE_DATE, ParquetType

from .decimal_encode import patch_decimal_schema_elements
from .writer_helpers import make_schema_elements_nullable


def arrow_type_to_parquet_type(at: ArrowType) raises -> ParquetType:
    """The Parquet physical type a column of Arrow type `at` is written as.

    INT32 and the INT32-backed temporal types (DATE32, TIME32_*) are INT32;
    INT64 and the INT64-backed ones (DATE64, TIME64_*, TIMESTAMP*,
    DURATION_*) are INT64; FLOAT32 FLOAT; FLOAT64 DOUBLE; STRING,
    LARGE_STRING and DICTIONARY (of strings) BYTE_ARRAY; BOOL BOOLEAN;
    DECIMAL128 FIXED_LEN_BYTE_ARRAY.

    Raises:
        Error: `at` has no writer (unsigned and narrow integers, BINARY,
            nested types, ...).
    """
    if (
        at == ArrowType.INT32
        or at == ArrowType.DATE32
        or at == ArrowType.TIME32_S
        or at == ArrowType.TIME32_MS
    ):
        return ParquetType.INT32
    if (
        at == ArrowType.INT64
        or at == ArrowType.DATE64
        or at == ArrowType.TIME64_US
        or at == ArrowType.TIME64_NS
        or at.is_timestamp()
        or at.is_duration()
    ):
        return ParquetType.INT64
    if at == ArrowType.FLOAT32:
        return ParquetType.FLOAT
    if at == ArrowType.FLOAT64:
        return ParquetType.DOUBLE
    if (
        at == ArrowType.STRING
        or at == ArrowType.LARGE_STRING
        or at == ArrowType.DICTIONARY
    ):
        return ParquetType.BYTE_ARRAY
    if at == ArrowType.BOOL:
        return ParquetType.BOOLEAN
    if at == ArrowType.DECIMAL128:
        return ParquetType.FIXED_LEN_BYTE_ARRAY
    raise Error(
        "parquet writer: no encoding for Arrow type " + String(at)
    )


def patch_date32_schema_elements(
    mut elements: List[SchemaElement], schema: Schema
) raises:
    """Stamp ConvertedType DATE on every leaf whose Arrow type is DATE32.

    Without it a date column reads back as a bare INT32: the day counts
    survive and the type does not. `elements` is `[root, leaf_0, ...]`, so
    leaf `c` is `elements[c + 1]`. Only DATE32: a TIMESTAMP needs the modern
    LogicalType union (unit and UTC flag), which `converted_type` cannot
    express and this writer does not emit, and guessing a unit would write
    timestamps wrong by a factor of 1000.
    """
    for c in range(schema.num_columns()):
        if schema.field_arrow_type(c) != ArrowType.DATE32:
            continue
        if c + 1 >= len(elements):
            raise Error(
                "patch_date32_schema_elements: "
                + String(len(elements) - 1)
                + " leaf element(s) for "
                + String(schema.num_columns())
                + " column(s)"
            )
        elements[c + 1].converted_type = Int(CONVERTED_TYPE_DATE)


def schema_elements_for(
    schema: Schema, column_nullable: List[Bool]
) raises -> List[SchemaElement]:
    """The flattened Parquet schema (root, then one leaf per column) of
    `schema`, column `c` OPTIONAL when `column_nullable[c]`.

    Raises:
        Error: a column's Arrow type has no writer, a decimal's precision or
            scale is invalid, or `column_nullable` has the wrong length.
    """
    var names = List[String]()
    var types = List[ParquetType]()
    for c in range(schema.num_columns()):
        names.append(schema.field_name(c))
        types.append(arrow_type_to_parquet_type(schema.field_arrow_type(c)))
    var elements = make_schema_elements_nullable(
        names^, types^, column_nullable.copy()
    )
    patch_decimal_schema_elements(elements, schema)
    patch_date32_schema_elements(elements, schema)
    return elements^
