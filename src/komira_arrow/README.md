# komira_arrow

Arrow-compatible columnar types: arrays of every kind, Column, Schema, RecordBatch, Table, bitmap, builders, typed views, selection vectors.

A typed array (`PrimitiveArray[dtype]`, `StringArray`, `BooleanArray`, and
the others) holds one column in the Arrow memory layout: a values buffer, an
offsets buffer for variable-length types, and a validity bitmap when the
column can hold nulls. A `Column` is the type-erased form the engine passes
around: its `arrow_type` says which layout its buffers hold. A
`RecordBatch` is a `Schema` plus one column per field, all of the same
length.

The package has no top-level re-exports; import from the module that
defines a type (`komira_arrow.column_builder`, `komira_arrow.schema`, and so
on).

Every example below runs as a test when the package is built, so it cannot
go stale.

## Building a column with nulls

`ColumnBuilder` appends values and nulls; the validity bitmap is allocated on
the first `append_null`. `materialize` consumes the builder and returns a
`Column`. `Column.slice` is zero-copy for fixed-width layouts and honours
the window's offset in `is_null_at`; `as_primitive` copies the window out as
a typed array.

```mojo
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column_builder import ColumnBuilder
from std.testing import assert_equal, assert_false, assert_true

var b = ColumnBuilder[DType.int64].with_capacity(4)
b.append(Int64(10))
b.append_null()
b.append(Int64(30))
b.append(Int64(40))
var col = b^.materialize()

assert_equal(col.arrow_type, ArrowType.INT64)
assert_equal(col.length(), 4)
assert_equal(col.null_count(), 1)
assert_true(col.is_null_at(1))
assert_false(col.is_null_at(2))

var values = col.as_primitive[DType.int64]()
assert_equal(values.get(0), Int64(10))
assert_equal(values.get(3), Int64(40))

var window = col.slice(1, 2)  # rows 1 and 2: the null and 30
assert_equal(window.length(), 2)
assert_equal(window.null_count(), 1)
assert_true(window.is_null_at(0))
assert_equal(window.as_primitive[DType.int64]().get(1), Int64(30))
```

## A record batch

`Schema.from_fields_<n>` and `RecordBatch.from_columns_<n>` build a batch of
primitive columns; the batch refuses columns that do not match the schema.
Columns are found by position or by name.

```mojo
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, Schema
from komira_arrow.string_array import StringArray
from std.testing import assert_equal, assert_true

var ids: List[Int64] = [1, 2, 3]
var scores: List[Int64] = [70, 85, 92]
var batch = RecordBatch.from_columns_2(
    Schema.from_fields_2(
        Field("id", DType.int64, nullable=False),
        Field("score", DType.int64, nullable=False),
    ),
    PrimitiveArray[DType.int64].from_list(ids),
    PrimitiveArray[DType.int64].from_list(scores),
)
assert_equal(batch.num_rows(), 3)
assert_equal(batch.num_columns(), 2)
assert_equal(batch.column_by_name("score"), 1)
assert_equal(batch.column_value(1, 2), Int64(92))

# Two fields and one column: refused.
var refused = False
try:
    _ = RecordBatch.from_columns_1(
        Schema.from_fields_2(
            Field("id", DType.int64, nullable=False),
            Field("score", DType.int64, nullable=False),
        ),
        PrimitiveArray[DType.int64].from_list(ids),
    )
except:
    refused = True
assert_true(refused)

# A string array: one offsets buffer and one data buffer of UTF-8 bytes.
var colours: List[String] = ["red", "", "green"]
var strings = StringArray.from_strings(colours)
assert_equal(len(strings), 3)
assert_equal(strings.get(2), "green")
assert_equal(strings.get_length(1), 0)
assert_equal(strings.data_length, 8)
```
