# `expr`

The typed expression vocabulary, above `udf` and `kernels`.

- The `ExprX` trait family (`ExprXBool`, `ExprXI64`, `ExprXF64`, `ExprXF32`,
  `ExprXI32`, `ExprXString`) in `expr_x`, and the unified chunk traits in
  `expr_traits_unified`.
- The `Stage[Program]` IR in `stage_program`, with `typed_projects` and
  `typed_udf_sugar`.
- `runtime_expr_bool`, `composite_key` and `expr_sortable_key`.

The row-mode executor that implements these traits is `eval`. There are
no root re-exports; import each name from its module.

## Example

A two-column GROUP BY key built from a string and an integer: equal keys are
equal and hash alike, and a different key differs. The hash is FNV-1a 64, so
the one-column key `"a"` has a known value.

```mojo
from std.testing import assert_equal, assert_true, assert_false
from expr.composite_key import (
    ColumnValue,
    KeyValue1,
    KeyValue2,
    hash_key_value1,
    hash_key_value2,
    eq_key_value2,
)

var a = KeyValue2(ColumnValue(String("x")), ColumnValue(Int64(1)))
var b = KeyValue2(ColumnValue(String("x")), ColumnValue(Int64(1)))
var c = KeyValue2(ColumnValue(String("x")), ColumnValue(Int64(2)))
assert_true(eq_key_value2(a, b))
assert_equal(hash_key_value2(a), hash_key_value2(b))
assert_false(eq_key_value2(a, c))
assert_true(hash_key_value2(a) != hash_key_value2(c))
assert_equal(a.c1.as_i64(), Int64(1))
assert_equal(
    hash_key_value1(KeyValue1(ColumnValue(String("a")))),
    UInt64(0xAF63DC4C8601EC8C),
)
```
