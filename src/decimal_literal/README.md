# decimal_literal

DECIMAL literals the way DuckDB reads and folds them. One module,
`decimal_literal`, imported by name:

- `decimal_from_literal_text(text)`: the `ScalarValue` of a literal such as
  `0.06`, `-0.5` or `100.00`. Its precision is the number of digits, the
  leading zero included, and its scale the digits after the point, so `0.06` is
  DECIMAL(3, 2) and `0.060` is DECIMAL(4, 3). A literal past 38 digits has no
  DECIMAL type here (DuckDB reads it as a DOUBLE) and gives `None`.
- `decimal_fold_binary(op, a, b)`: `a + b`, `a - b` or `a * b` for two literals
  of which at least one is a DECIMAL and the other a DECIMAL or an integer.
  An integer literal is DECIMAL(10, 0) when it fits INT32 and DECIMAL(19, 0)
  otherwise. `+` and `-` have scale max(s1, s2) and precision
  max(p1 - s1, p2 - s2) + max(s1, s2) + 1; `*` has scale s1 + s2 and precision
  p1 + p2. A result that needs more than 38 digits gives `None`: the node is
  left for the runtime, as DuckDB leaves it to a DOUBLE.
- `decimal_negate(a)`: the negation of a DECIMAL literal, same type.

The types are the ones DuckDB prints for `typeof(<expr>)`; the SQL conformance
package `komira_decimal_compare_conformance` holds DuckDB's own answers.

## Reading and folding literals

`decimal_from_literal_text` types a literal from its text, and
`decimal_fold_binary` folds `+`, `-` and `*` with DuckDB's result precision and
scale. A literal with more than 38 digits has no type and gives `None`.

```mojo
from decimal_literal.decimal_literal import (
    decimal_fold_binary,
    decimal_from_literal_text,
    decimal_negate,
)
from plan_expr.expr import BIN_ADD, BIN_MUL
from plan_expr.scalar_value import ScalarValue
from scalar_arithmetic.decimal_arith import I128
from std.testing import assert_equal, assert_false, assert_true

# 0.06 is 6 at scale 2, DECIMAL(3, 2).
var a = decimal_from_literal_text("0.06")
var b = decimal_from_literal_text("0.01")
assert_true(Bool(a))
assert_true(Bool(b))
assert_equal(
    String(a.value()), String(ScalarValue.decimal128_i128(I128(6), 3, 2))
)

# 0.06 + 0.01 is 0.07, DECIMAL(4, 2).
var sum = decimal_fold_binary(BIN_ADD, a.value(), b.value())
assert_true(Bool(sum))
assert_equal(
    String(sum.value()), String(ScalarValue.decimal128_i128(I128(7), 4, 2))
)

# 0.06 * 0.01 is 0.0006, DECIMAL(6, 4).
var product = decimal_fold_binary(BIN_MUL, a.value(), b.value())
assert_true(Bool(product))
assert_equal(
    String(product.value()),
    String(ScalarValue.decimal128_i128(I128(6), 6, 4)),
)

# Negation keeps the type.
var neg = decimal_negate(a.value())
assert_true(Bool(neg))
assert_equal(
    String(neg.value()), String(ScalarValue.decimal128_i128(I128(-6), 3, 2))
)

# 39 digits is past DECIMAL(38), and a text without a point is no decimal.
var too_wide = decimal_from_literal_text(
    "0.99999999999999999999999999999999999999"
)
assert_false(Bool(too_wide))
assert_false(Bool(decimal_from_literal_text("12")))
```
