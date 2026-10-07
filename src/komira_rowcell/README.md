# komira_rowcell

`RowCell`, one typed table cell: a tagged value over six scalar kinds
(boolean, 32-bit int, 64-bit long, float, double, string) or a typed NULL,
with value equality. The kind is `type_tag`, one of the `CELL_T_*` constants;
the ordinals are internal, so name the constant, never the number. Integral
kinds are held as `Int64` (`as_long`), floating kinds widened to `Float64`
(`as_double`), strings as `String` (`as_string`).

Build cells with the typed constructors (`make_boolean_cell`, `make_int_cell`,
`make_long_cell`, `make_float_cell`, `make_double_cell`, `make_string_cell`,
`make_null_cell(type_tag)`). `RowCell.equals` compares the active value of two
cells of the same kind; cells of different kinds are never equal, and a NULL
equals only a NULL of the same kind. `rows_equal` compares two rows cell by
cell. The package depends on nothing but the Mojo standard library: it does not
encode, decode or type-check cells against any table format's schema.

## Examples

Typed constructors and the value each kind keeps:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_rowcell import CELL_T_DOUBLE, CELL_T_INT, CELL_T_STRING
from komira_rowcell import make_boolean_cell, make_double_cell, make_int_cell, make_string_cell

var flag = make_boolean_cell(True)
assert_equal(flag.as_long(), 1)

var count = make_int_cell(Int32(-7))
assert_equal(count.type_tag, CELL_T_INT)
assert_equal(count.as_long(), -7)

var price = make_double_cell(9.5)
assert_equal(price.type_tag, CELL_T_DOUBLE)
assert_equal(price.as_double(), 9.5)

var name = make_string_cell("pen")
assert_equal(name.type_tag, CELL_T_STRING)
assert_equal(name.as_string(), "pen")
assert_true(not name.is_null())
```

Equality is by kind and value: an int and a long holding 5 differ, and a NULL
matches only a NULL of its own kind:

<!-- mojo-hidden from std.testing import assert_true -->
```mojo
from komira_rowcell import CELL_T_LONG, CELL_T_STRING
from komira_rowcell import make_int_cell, make_long_cell, make_null_cell, make_string_cell

assert_true(make_long_cell(5).equals(make_long_cell(5)))
assert_true(not make_int_cell(5).equals(make_long_cell(5)))
assert_true(not make_string_cell("a").equals(make_string_cell("b")))

var null_long = make_null_cell(CELL_T_LONG)
assert_true(null_long.is_null())
assert_true(null_long.equals(make_null_cell(CELL_T_LONG)))
assert_true(not null_long.equals(make_null_cell(CELL_T_STRING)))
assert_true(not null_long.equals(make_long_cell(0)))
```

Rows compare cell by cell, and rows of different lengths never match:

<!-- mojo-hidden from std.testing import assert_true -->
```mojo
from komira_rowcell import RowCell, make_long_cell, make_string_cell, rows_equal

var a: List[RowCell] = [make_long_cell(1), make_string_cell("x")]
var b: List[RowCell] = [make_long_cell(1), make_string_cell("x")]
var c: List[RowCell] = [make_long_cell(1), make_string_cell("y")]
var short: List[RowCell] = [make_long_cell(1)]
assert_true(rows_equal(a, b))
assert_true(not rows_equal(a, c))
assert_true(not rows_equal(a, short))
```
