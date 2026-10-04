# komira_parquet_api

The Parquet format's types and footer metadata, as plain Mojo values.

- `types`: the Thrift enums of the Parquet spec. `PageType`, `Encoding`,
  `CompressionCodec`, `ParquetType` (the physical type), `FieldRepetitionType`
  and `BoundaryOrder`, each a `UInt8` with named constants whose values are the
  spec's, and a `write_to` that prints the spec's name.
- `metadata`: the footer structs. `FileMetaData` holds the flattened schema
  (`SchemaElement`), the row groups (`RowGroup` -> `ColumnChunk` ->
  `ColumnMetaData` -> `Statistics`) and the key-value metadata (`KeyValue`);
  `PageHeader` and `SortingColumn` complete the set.

The package reads no file, decodes no byte and depends on nothing but the
Mojo standard library. A Parquet reader fills these structs from a footer, a
writer serializes them into one, and code that only inspects metadata (a
pruner, a statistics consumer, a schema printer) depends on this package
alone.

```mojo
from komira_parquet_api import CompressionCodec, ParquetType

print(ParquetType.INT64.byte_width().value())  # 8
print(CompressionCodec.ZSTD)                   # ZSTD
```

Every name is re-exported from the package root. The tests are welded into
the build: the package cannot be built while one of them fails.
