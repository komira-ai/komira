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
- `hll_footer`: where a column chunk's HyperLogLog registers
  (`Statistics.hll_registers`, not part of the Parquet format) live in a
  footer. They travel in the chunk's `ColumnMetaData.key_value_metadata`
  under `HLL_REGISTERS_KEY`, one base64-alphabet character per register
  (`hll_registers_to_key_value`, `hll_registers_from_key_values`).
  Statistics field 9 is the spec's `nan_count`: a reader decodes it only
  when its Thrift compact type is i64 (`statistics_field_9_is_nan_count`)
  and never takes it as registers.

The `types` module also names the ConvertedType values
(`CONVERTED_TYPE_DECIMAL`, `CONVERTED_TYPE_UTF8`, ...) that
`SchemaElement.converted_type` is compared against.

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

Every type and ConvertedType constant is re-exported from the package root.
The tests are welded into the build: the package cannot be built while one of
them fails. Every enum value and ConvertedType constant is checked against
`parquet.thrift`, read from the parquet-format release archive
`//third_party/parquet-format` pins by sha256, so no expected value is
written by hand.
