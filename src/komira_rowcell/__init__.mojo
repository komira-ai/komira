"""`komira_rowcell` — the typed table-cell value model. A zero-dependency LEAF.

ONE struct (`RowCell`), its six scalar type tags, its typed constructors, and
value equality. Nothing else. It imports NOTHING from this repo — only the Mojo
stdlib — and that is the point of the package.

WHY IT EXISTS: a document-store or key-value CDC source must not depend on a
table-format writer to get a cell. Several consumers need only the cell model:
a provider-agnostic CDC change record carries `List[RowCell]` images, and each
provider client maps its own native value (a document field, an item
attribute) onto a cell.

Putting the cell inside a table-format library would pull that library, its
file-format readers and the query engine behind them into every such
consumer's build closure, so a compile break there would block a CDC client
that never touches a table. Keeping the cell in its own leaf prevents that at
the source: every consumer, the table-format writer included, depends on
`komira_rowcell`, and nobody depends on a table format to get a cell.

Dependency direction (cycle-free, and it must stay this shape): every consumer
-> `komira_rowcell` -> NOTHING.

⚠ The empty `deps` of this library's BUCK target is LOAD-BEARING. Anything
added there re-enters the closure of every CDC provider client and re-opens
exactly the coupling this package closes.
"""

from .row_cell import (
    CELL_T_BOOLEAN,
    CELL_T_INT,
    CELL_T_LONG,
    CELL_T_FLOAT,
    CELL_T_DOUBLE,
    CELL_T_STRING,
    RowCell,
    make_boolean_cell,
    make_int_cell,
    make_long_cell,
    make_float_cell,
    make_double_cell,
    make_string_cell,
    make_null_cell,
    rows_equal,
)
