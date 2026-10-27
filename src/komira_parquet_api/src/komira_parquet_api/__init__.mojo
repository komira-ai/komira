"""`komira_parquet_api`: the Parquet format's types and footer metadata.

The Thrift enums of the Parquet spec (`types`), the structs a file footer
decodes into (`metadata`), and where a column chunk's HyperLogLog registers
live in a footer (`hll_footer`), as plain values with no file I/O, no codec and no
dependency beyond the Mojo standard library. A Parquet reader fills these
structs, a writer serializes them, and code that only inspects a footer
(statistics, schema, row-group sizes) needs nothing else.
"""

from .types import (
    PageType,
    Encoding,
    CompressionCodec,
    ParquetType,
    FieldRepetitionType,
    BoundaryOrder,
)
from .metadata import (
    KeyValue,
    Statistics,
    SchemaElement,
    PageHeader,
    ColumnMetaData,
    ColumnChunk,
    SortingColumn,
    RowGroup,
    FileMetaData,
)
from .types import (
    CONVERTED_TYPE_BSON,
    CONVERTED_TYPE_DATE,
    CONVERTED_TYPE_DECIMAL,
    CONVERTED_TYPE_ENUM,
    CONVERTED_TYPE_INT_8,
    CONVERTED_TYPE_INT_16,
    CONVERTED_TYPE_JSON,
    CONVERTED_TYPE_UINT_8,
    CONVERTED_TYPE_UINT_16,
    CONVERTED_TYPE_UINT_32,
    CONVERTED_TYPE_UINT_64,
    CONVERTED_TYPE_UTF8,
)
from .hll_footer import (
    HLL_MAX_REGISTER,
    HLL_REGISTER_COUNT,
    HLL_REGISTERS_KEY,
    STATISTICS_NAN_COUNT_FIELD_ID,
    THRIFT_COMPACT_TYPE_I64,
    hll_registers_from_key_values,
    hll_registers_to_key_value,
    statistics_field_9_is_nan_count,
)
