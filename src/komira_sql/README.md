# komira_sql

The analytical SQL front end's first layers. `komira_sql.sql_token` lexes a
SQL string into a flat `List[Token]` that ends in `TK_EOF`: unquoted
identifiers are lower-folded (keywords and function names are ordinary
identifiers that the parser classifies by text), a single-quoted literal keeps
its bytes with `''` read as one quote, and an integer past `Int64.MAX` keeps
its decimal digits in `Token.text`. Bad input raises an `Error` that starts
with `SQL syntax error` (or `SQL not supported` for an operator this dialect
does not have), never a crash.

`komira_sql.sql_ast` holds the nodes the parser builds and the binder lowers
to a plan: `SqlExpr` (a move-only expression tree that carries aggregate
calls inline, with `contains_aggregate()` and a deep `copy()`), the FROM
relations, joins, `SelectStmt` and the top-level `SqlStatement`, and the
name tables that say which identifiers the grammar claims
(`sql_agg_code`, `sql_call_is_aggregate`, `sql_name_claimed_by_grammar`).

`komira_sql.sql_fn_table` is the scalar-function table the binder reads: one
row per SQL function name (aliases share their row). `sql_scalar_fn_spec(name)`
returns a `SqlFnSpec` that says which expression node the name lowers to (its
kind and op) and its inclusive arity, or that the name is a real DuckDB
function this engine refuses (`FNK_REFUSED`, with the reason the binder
raises), or that no row has it (`FNK_NONE`). `lowers_to_a_node` is True only
for rows that become an expression, so a refused name may still be declared
as a user function. `sql_date_part_unit`, `sql_date_part_desugar` and
`sql_date_trunc_unit` are the separate `date_part` specifier and `date_trunc`
period tables; the function names and the specifier names are different sets.

## Examples

Lexing a statement:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_sql.sql_token import tokenize, TK_LE, TK_EOF

var toks = tokenize("SELECT Price FROM t WHERE qty <= 10")
assert_equal(toks[1].text, "price")  # lower-folded
assert_equal(Int(toks[6].kind), Int(TK_LE))
assert_equal(toks[7].int_val, Int64(10))
assert_equal(Int(toks[8].kind), Int(TK_EOF))
```

An expression that holds an aggregate below its top node:

<!-- mojo-hidden from std.testing import assert_true, assert_false -->
```mojo
from komira_sql.sql_ast import SqlExpr, SXAGG_SUM, SXOP_ADD

var e = SqlExpr.binary(
    SXOP_ADD, SqlExpr.int_lit(1), SqlExpr.agg(SXAGG_SUM, SqlExpr.column("x"))
)
assert_false(e.is_aggregate())
assert_true(e.contains_aggregate())
assert_true(e.copy().contains_aggregate())
```

Looking up a function name:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_sql.sql_fn_table import sql_scalar_fn_spec, FNK_STRING_FN, FNK_REFUSED, FNK_NONE

var up = sql_scalar_fn_spec("ucase")  # an alias of upper
assert_equal(Int(up.kind), Int(FNK_STRING_FN))
assert_equal(up.min_args, 1)
assert_true(up.lowers_to_a_node)
var nx = sql_scalar_fn_spec("nextafter")
assert_equal(Int(nx.kind), Int(FNK_REFUSED))
assert_true(nx.reason.startswith("SQL not supported"))
assert_false(nx.lowers_to_a_node)
assert_equal(Int(sql_scalar_fn_spec("no_such_fn").kind), Int(FNK_NONE))
```
