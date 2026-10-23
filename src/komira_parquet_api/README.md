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

Every example below runs as a test when the package is built, so it cannot
go stale.

## The enums

Each enum is a `UInt8` whose value is the spec's, and prints the spec's name.

```mojo
from komira_parquet_api import CompressionCodec, Encoding, ParquetType
from std.testing import assert_equal, assert_false

assert_equal(ParquetType.INT64.byte_width().value(), 8)
assert_false(Bool(ParquetType.BYTE_ARRAY.byte_width()))  # variable length: no width
assert_equal(String(CompressionCodec.ZSTD), "ZSTD")
assert_equal(CompressionCodec.ZSTD.value, UInt8(6))
assert_equal(String(Encoding(8)), "RLE_DICTIONARY")
```

## Footer metadata

A footer's schema is flattened depth first: the root group names how many
children follow it.

```mojo
from komira_parquet_api import CONVERTED_TYPE_UTF8, FieldRepetitionType, FileMetaData, KeyValue
from komira_parquet_api import ParquetType, RowGroup, SchemaElement
from std.testing import assert_equal

var schema = List[SchemaElement]()
schema.append(SchemaElement(name="schema", num_children=2))
schema.append(SchemaElement(name="id", type=ParquetType.INT64, repetition_type=FieldRepetitionType.REQUIRED))
schema.append(
    SchemaElement(
        name="name",
        type=ParquetType.BYTE_ARRAY,
        repetition_type=FieldRepetitionType.OPTIONAL,
        converted_type=CONVERTED_TYPE_UTF8,
    )
)
var kvs = List[KeyValue]()
kvs.append(KeyValue("writer.version", String("1.0")))

var footer = FileMetaData(
    version=2,
    schema=schema^,
    num_rows=0,
    row_groups=List[RowGroup](),
    key_value_metadata=kvs^,
)
assert_equal(footer.schema[0].num_children, 2)
assert_equal(String(footer.schema[2].repetition_type.value()), "OPTIONAL")
assert_equal(footer.schema[2].converted_type.value(), CONVERTED_TYPE_UTF8)
assert_equal(footer.key_value_metadata.value()[0].value.value(), "1.0")
```

Every type and ConvertedType constant is re-exported from the package root.
The tests are welded into the build: the package cannot be built while one of
them fails. Every enum value and ConvertedType constant is checked against
`parquet.thrift`, read from the parquet-format release archive
`//third_party/parquet-format` pins by sha256, so no expected value is
written by hand.

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_parquet_api`, version 0.1.0
(`mopm.toml`). The library is `src/komira_parquet_api/` (`types.mojo`, `metadata.mojo`, `hll_footer.mojo` and the
`__init__.mojo` that re-exports them), its tests are `tests/`. The package has no dependencies, no native archive and
calls no foreign function. Two of its tests read files, which the `test_data` argument of `mojo_package` in `BUCK`
stages in the test's working directory: `parquet.thrift` at `format/` for `test_values_match_parquet_thrift`, and every
library source at `lib/` for `test_no_env_reads`. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, where the library and its tests are |
| `mopm.lock` | what `mopm lock` writes (with no registry reachable); the package has no dependencies, so it pins the toolchain only |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `coverage_floor.txt` | `lines NN.NN`: the least line coverage `:coverage` may measure; `:coverage_floor` fails when it falls below, and above it passes and prints a hint to raise the figure |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above; `buildrules mojo check` fails when they are stale |

`:lib` is the library file and exists only once every test of `tests/` has passed. After any change to a source,
a test, `mopm.toml`, `mopm.lock` or `mopm-toolchain.toml`, run `buildrules mojo sync`, commit what it
writes, and build `komira//src/komira_parquet_api:lib` on the farm. (The sync writes the toolchain pins,
`mojo_pins.bzl` and `mopm_pins.bzl`, to the directory the `[cells] toolchains` line of `.buckconfig` names:
`tools/build/cells/toolchains/` here.) A test file that `buildrules mojo sync` has not listed is not
run: run the sync after adding one.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package
(`mojo-komira_parquet_api-0.1.0-mojo1.0.0_0.conda`), which therefore exists only once the tests have passed.
Publishing it (`mopm publish`) uploads, so it is a step of a CI job that takes that file, not a build action.

`:komira_parquet_api` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`). It also compiles and runs
the README's examples above (`[tests][readme]`) against `:lib`, which `:lib` does not do; the tests are not run again.
