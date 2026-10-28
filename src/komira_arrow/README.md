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

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_arrow`, version 0.1.0
(`mopm.toml`). The library is `src/komira_arrow/`, its tests are `tests/`. It depends on six packages, sibling
directories (`[dependencies]` of `mopm.toml`): `komira_atomic_alias`, `komira_buffer`, `komira_collections`,
`komira_compression`, `komira_counters` and `komira_simd`, each as `{ path = "../<name>", version = "0.1" }`. The
`.conda` of this package records `mojo-<name> >=0.1,<0.2` for each of them as a dependency and holds none of their
files: installing `komira_arrow` installs them with it. `komira_buffer` depends on `komira_host`, `komira_libc` and
`komira_simd`, and `komira_libc` links a C shim of its own; a dependent's link takes it from the closure, and this
package owns no C. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependencies and where the library and its tests are |
| `mopm.lock` | the toolchain pins and the path dependencies, as `mopm lock` writes them (no registry is reached: every dependency is a sibling) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifests of the siblings; `buildrules mojo check` fails when they are stale |

`:lib` is the library file, built from the `:lib` of the siblings, and exists only once every test of `tests/` has
passed. After any change to a source, a test, a manifest of this package or of a sibling, run `buildrules mojo sync`
with the package and its siblings staged, commit what it writes, and build `komira//src/komira_arrow:lib` on the
farm.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package
(`mojo-komira_arrow-0.1.0-mojo1.0.0_0.conda`), packed with the manifests of the path dependencies beside its own
(`members`), which therefore exists only once the tests have passed. Publishing it (`mopm publish`) uploads, so it is
a step of a CI job that takes that file, not a build action.
