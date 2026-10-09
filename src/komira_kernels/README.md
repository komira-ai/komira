# komira_kernels

Expression kernels of the query engine: the code that evaluates a
`komira_plan_expr` expression over Arrow columns from `komira_arrow`. The
package root exports nothing; import from the modules. The main ones:

- `expr_interpreter`: `interpret_expr` evaluates an `Expr` for one row given
  as a `RowContext` (column name to value), returning an `EvalScalar` that is
  an integer, float, boolean, string or NULL. It covers column references,
  literals, arithmetic, comparisons, `AND`/`OR`/`NOT`, `IS [NOT] NULL`, a few
  numeric unary functions, casts and aliases; mixed integer and float
  arithmetic is done in float; a missing column reads as NULL; other
  expression kinds evaluate to NULL. It is the slow fallback the engine uses
  for shapes no specialised kernel covers.
- `temporal_extract`: year, quarter, month, day, hour, minute, second, ISO
  week, day of week or year and `date_trunc` over `DATE32` (days since
  1970-01-01) and timestamp columns; NULL rows stay NULL.
- `cast_to_varchar_kernels`: casts between strings and integer, float,
  boolean, dictionary and null columns, with a strict mode that raises on a
  value that does not parse and a `try_mode` that yields NULL for it.
- `sel_kernels`, `match_fn`, `binary_fn`, `hash_fn` and their `builtin_*`
  conformers: compile-time specialised comparison, arithmetic and hash loops
  over columns and selection vectors; `kleene` and `comparison_kleene`:
  three-valued (`TRUE`/`FALSE`/`NULL`) logic for filters; `join_key_envelope`:
  which column types may form a composite hash-join key; `simd_of` and
  `eval_chunks`: SIMD chunk types the kernels share; `runtime_expr` and
  `expr_kernel_templates`: the expression shapes the specialised kernels are
  chosen for.

It does not plan or optimise queries, and it reads no files.

## Examples

Evaluate an expression for one row:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_plan_expr.expr import Expr, BIN_AND, BIN_GT, BIN_MUL, BIN_SUB, UN_IS_NULL
from komira_plan_expr.scalar_value import ScalarValue
from komira_kernels.expr_interpreter import EVAL_KIND_BOOL, EVAL_KIND_FLOAT, RowContext, interpret_expr

var row = RowContext.empty()
row.set_float("price", 100.0)
row.set_float("discount", 0.25)
row.set_int("qty", 30)

# price * (1 - discount)
var net = Expr.binary(
    BIN_MUL,
    Expr.col_ref("price"),
    Expr.binary(BIN_SUB, Expr.literal(ScalarValue.from_float(1.0)), Expr.col_ref("discount")),
)
var r = interpret_expr(net, row)
assert_equal(r.kind, EVAL_KIND_FLOAT)
assert_equal(r.float_val, 75.0)

# qty > 25 AND note IS NULL; "note" is not in the row, so it reads as NULL.
var check = Expr.binary(
    BIN_AND,
    Expr.binary(BIN_GT, Expr.col_ref("qty"), Expr.literal(ScalarValue.from_int64(25))),
    Expr.unary(UN_IS_NULL, Expr.col_ref("note")),
)
var b = interpret_expr(check, row)
assert_equal(b.kind, EVAL_KIND_BOOL)
assert_true(b.bool_val)
```

Date parts of a `DATE32` column, and a string column cast to integers:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_kernels.cast_to_varchar_kernels import cast_int64_to_string, cast_string_to_int64
from komira_kernels.temporal_extract import date_trunc_date32, extract_day_date32, extract_month_date32, extract_quarter_date32, extract_year_date32, parse_trunc_unit

# 2026-11-04 and 2028-02-29, as days since 1970-01-01.
var days = List[Scalar[DType.int32]]()
days.append(20761)
days.append(21243)
var dates = PrimitiveArray[DType.int32].from_list(days)
var years = extract_year_date32(dates)
var months = extract_month_date32(dates)
var day_of_month = extract_day_date32(dates)
assert_equal(years.get(0), 2026)
assert_equal(months.get(0), 11)
assert_equal(day_of_month.get(0), 4)
assert_equal(extract_quarter_date32(dates).get(0), 4)
assert_equal(years.get(1), 2028)
assert_equal(months.get(1), 2)
assert_equal(day_of_month.get(1), 29)
var month_start = date_trunc_date32(dates, parse_trunc_unit("month"))
assert_equal(month_start.get(0), 20758)  # 2026-11-01

var text = List[String]()
text.append("42")
text.append("-7")
text.append("seven")
var strings = StringArray.from_strings(text)
var ints = cast_string_to_int64(strings, try_mode=True)
assert_equal(ints.get(0), 42)
assert_equal(ints.get(1), -7)
assert_true(ints.is_null(2))  # does not parse: NULL in try mode

var strict_refused = False
try:
    _ = cast_string_to_int64(strings)
except:
    strict_refused = True
assert_true(strict_refused)  # and an error in strict mode

var back = cast_int64_to_string(ints)
assert_equal(back.get(0), "42")
assert_equal(back.get(1), "-7")
assert_true(back.is_null(2))
```
