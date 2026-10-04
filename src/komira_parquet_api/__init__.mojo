"""`komira_parquet_api`: the Parquet format's types and footer metadata.

The Thrift enums of the Parquet spec (`types`) and the structs a file footer
decodes into (`metadata`), as plain values with no file I/O, no codec and no
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
