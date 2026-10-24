# komira_parquet_writer

A Parquet writer: its encoders and page builders, and `ParquetFileWriter`,
which assembles whole columns into a file and returns the file's bytes. The
package opens no file (where the bytes go is the caller's decision), reads no
Parquet file and does not depend on the reader, `komira_parquet`; its tests
decode what it writes with that reader, through `test_deps`.

- `thrift_writer`: `ThriftCompactWriter`, the Thrift compact protocol
  serializer for the footer (`serialize_file_metadata`), data page headers
  (V1 and V2), the page index (ColumnIndex, OffsetIndex) and the bloom
  filter header. A column chunk's HyperLogLog registers are written into its
  `ColumnMetaData.key_value_metadata` (see `komira_parquet_api.hll_footer`);
  Statistics field 9 is `nan_count`. The footer declares TYPE_ORDER for
  every leaf, an assertion every statistic below keeps.
- `page_size_limit`: the PageHeader size fields are i32. A page body above
  `PARQUET_PAGE_SIZE_MAX` raises `ParquetPageSizeOverflow` instead of
  wrapping. `set_parquet_page_size_limit` lowers the ceiling process-wide
  (a test seam a program sets from its own flag); it can never raise it.
- `stats`: column-chunk statistics for INT32, INT64, DOUBLE and string
  columns: min/max over the non-null values only, null_count, an HLL
  `distinct_count` with its registers; string min/max truncated to 64 bytes.
- `writer_float_stats`: FLOAT / DOUBLE statistics by parquet.thrift's rules:
  NaN never enters min/max, `nan_count` is exact, a zero min is written as
  -0.0 and a zero max as +0.0.
- `dict_encoder`, `dict_encoder_numeric`: dictionary encoding of string and
  of fixed-width numeric columns, in first-seen order, abandoned (`success`
  False, the caller writes PLAIN) when a column is too high-cardinality.
  Numeric keys are the values' exact bits, so the dictionary is lossless
  (-0.0 and +0.0 are two entries).
- `writer_bitpack`: `pack_fixed_width`, the LSB-first fixed-width packer of
  the RLE / bit-packed hybrid and DELTA_BINARY_PACKED.
- `writer_page_index`: `ColumnPageTracker` collects per-page offsets and
  min/max; `serialize_column_index` computes BoundaryOrder in the column's
  type-defined order.
- `writer_helpers`: page-body compression (through `komira_parquet_codec`),
  the flattened schema builders, integer Statistics builders.

- `column_page`: `ColumnPage`, one column chunk's encoded pages (one data
  page, or a dictionary page then a data page) with the sizes, codec,
  encodings and statistics its ColumnMetaData needs, and the DataPage V1
  assembler every page builder uses.
- `writer_encode`: definition levels (offset-aware, so a sliced array's
  levels are its own rows'), and PLAIN pages: fixed-width
  (`encode_plain_column`), BYTE_ARRAY (`encode_string_column_page` and its
  Int64-offset twin, byte-identical), BOOLEAN.
- `writer_delta`: DELTA_BINARY_PACKED for INT32 / INT64, deltas in the
  column type's own wrapping arithmetic (an INT32 miniblock is never wider
  than 32 bits).
- `writer_bss`: BYTE_STREAM_SPLIT for FLOAT / DOUBLE.
- `writer_dict`, `writer_dict_numeric`: dictionary column chunks, None when
  the column is not worth a dictionary (the caller writes another
  encoding). A one-entry dictionary's index stream is an RLE run.
- `decimal_encode`: Decimal128 as FIXED_LEN_BYTE_ARRAY(16), big-endian,
  ConvertedType DECIMAL; an invalid precision or scale is refused.

Every page builder takes `nullable`: an OPTIONAL column's page holds
definition levels and the non-null values; a REQUIRED column's page holds
every value, and a REQUIRED column that holds a null is refused (writing
the null slot's bytes would publish a value the column does not have).

The package reads no environment. Its tests are welded into the build.

## Statistics

min/max describe the column's values, so a null slot never enters them,
whatever bytes it holds.

```mojo
from komira_arrow.primitive_array import PrimitiveArray
from komira_parquet_writer import compute_statistics_int64
from std.testing import assert_equal

var col = PrimitiveArray[DType.int64].allocate_nullable(3)
col.set(0, 7)
col.set(1, -1000)
col.set(2, 9)
col._set_null(1)
var stats = compute_statistics_int64(col)
assert_equal(stats.null_count.value(), 1)
assert_equal(Int(stats.min_value.value()[0]), 7)  # little-endian; -1000 is null
assert_equal(Int(stats.max_value.value()[0]), 9)
```

## Dictionary encoding

```mojo
from komira_arrow.string_array import StringArray
from komira_parquet_writer import encode_dict_column
from std.testing import assert_equal, assert_true

var strs: List[String] = ["red", "blue", "red"]
var result = encode_dict_column(StringArray.from_strings(strs))
assert_true(result.success)
assert_equal(result.dictionary.length, 2)
assert_equal(Int(result.indices.get(2)), 0)
```

## The footer

```mojo
from komira_parquet_api import FileMetaData, ParquetType, RowGroup, SchemaElement
from komira_parquet_writer import serialize_file_metadata
from std.testing import assert_true

var schema = List[SchemaElement]()
schema.append(SchemaElement(name="schema", num_children=1))
schema.append(SchemaElement(name="id", type=ParquetType.INT64))
var footer = FileMetaData(
    version=2, schema=schema^, num_rows=0, row_groups=List[RowGroup]()
)
var thrift = serialize_file_metadata(footer)
assert_true(len(thrift) > 0)
```

## A file

`ParquetFileWriter` takes the flattened schema (`make_schema_elements`,
`make_schema_elements_nullable`) and one call per column; a column's
nullability is its schema element's. `close_to_bytes` returns the whole file
and ends the writer.

```mojo
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_parquet_api import CompressionCodec, ParquetType
from komira_parquet_writer import ParquetFileWriter, make_schema_elements
from std.testing import assert_equal

var names: List[String] = ["id", "city"]
var types: List[ParquetType] = [ParquetType.INT64, ParquetType.BYTE_ARRAY]
var writer = ParquetFileWriter.create(
    make_schema_elements(names^, types^), CompressionCodec.SNAPPY
)
writer.write_batch[DType.int64](0, PrimitiveArray[DType.int64].from_list([1, 2, 3]))
var cities: List[String] = ["oslo", "oslo", "rome"]
writer.write_string_batch_dict(1, StringArray.from_strings(cities))
var file = writer.close_to_bytes()
assert_equal(Int(file[0]), 0x50)  # PAR1 at both ends
assert_equal(Int(file[len(file) - 1]), 0x31)
```

## Row groups, the page index, bloom filters, page CRCs

`AdvancedParquetWriter` takes one chunk per column per row group
(`add_column_page_simple`, or `add_column_page` with explicit min and max for
the ColumnIndex), `flush_row_group` closes a row group, and `close_to_bytes`
returns the file. A bloom filter (`set_bloom_filter`, a `komira_dynamic_filter`
`BloomFilter`) is written when `WriterConfig(enable_bloom_filters=True)`. With
`enable_crc` each data page's header carries the standard CRC-32 of the stored
body (not CRC-32C), which `komira_parquet`'s reader checks; dictionary chunks
carry none. The OffsetIndex locates data pages (past a dictionary page), and a
chunk with no min and max gets an OffsetIndex only.

```mojo
from komira_arrow.primitive_array import PrimitiveArray
from komira_parquet_api import ParquetType
from komira_parquet_writer import (
    AdvancedParquetWriter,
    WriterConfig,
    encode_plain_column,
    make_schema_elements,
)
from std.testing import assert_equal

var names: List[String] = ["id"]
var types: List[ParquetType] = [ParquetType.INT64]
var writer = AdvancedParquetWriter.create(
    make_schema_elements(names^, types^), WriterConfig(enable_crc=True)
)
for g in range(2):  # two row groups
    var vals: List[Int64] = [Int64(g * 10), Int64(g * 10 + 1)]
    var ids = PrimitiveArray[DType.int64].from_list(vals)
    writer.add_column_page_simple(encode_plain_column[DType.int64](0, ids, "id"))
    writer.flush_row_group()
var file = writer.close_to_bytes()
assert_equal(Int(file[0]), 0x50)
assert_equal(writer.total_num_rows, 4)
```

## Several arrays as one chunk

A column held as several morsels encodes without an Arrow concat:
`encode_two_primitives` and `encode_two_strings` give the page the
single-array encoder gives for the concatenation (nulls, statistics and codec
included), and `encode_n_primitives` takes any number of REQUIRED arrays as
raw bytes. `writer_multi_batch_stats` folds a column's statistics across
RecordBatches the same way.

```mojo
from komira_arrow.primitive_array import PrimitiveArray
from komira_parquet_writer import encode_plain_column, encode_two_primitives
from std.testing import assert_equal

var a = PrimitiveArray[DType.int64].from_list([1, 2])
var b = PrimitiveArray[DType.int64].from_list([3, 4, 5])
var both = PrimitiveArray[DType.int64].from_list([1, 2, 3, 4, 5])
var two = encode_two_primitives[DType.int64](0, a, b, "n")
var one = encode_plain_column[DType.int64](0, both, "n")
assert_equal(len(two.data), len(one.data))
for i in range(len(one.data)):
    assert_equal(Int(two.data[i]), Int(one.data[i]))
```

## A PLAIN page

```mojo
from komira_arrow.primitive_array import PrimitiveArray
from komira_parquet_api import Encoding
from komira_parquet_writer import encode_plain_column
from std.testing import assert_equal, assert_true

var col = PrimitiveArray[DType.int32].allocate_nullable(3)
col.set(0, 5)
col.set(2, 7)
col._set_null(1)
var page = encode_plain_column[DType.int32](0, col, "n", nullable=True)
assert_equal(page.num_values, 3)  # the null row counts
assert_true(page.encodings[0] == Encoding.RLE)  # definition levels
assert_equal(page.statistics.value().null_count.value(), 1)
var other = PrimitiveArray[DType.int32].allocate_nullable(1)
other._set_null(0)
try:
    _ = encode_plain_column[DType.int32](0, other, "n", nullable=False)
    raise Error("not refused")
except e:
    assert_true("is REQUIRED but holds" in String(e))
```
