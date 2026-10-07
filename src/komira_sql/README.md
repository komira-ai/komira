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

`komira_sql.sql_tvf_bind` gives the `read_csv`, `read_json` and `read_avro`
table functions their schema at bind time and builds their scan leaf. A CSV
schema is inferred from a bounded prefix with the call's `delimiter` and
`has_header` (`all_varchar` then types every column STRING); a JSONL schema is
inferred from a newline-snapped 256 KiB prefix; an Avro schema is read from the
OCF container header. A `.gz`, `.zst` or `.lz4` CSV or JSONL file is
decompressed whole first (`komira_parquet_codec.text_decompress`). An inference
that finds no column raises an `Error` naming the file. `tvf_relation_scan`
returns a lazy row-oriented scan whose source carries the dialect and the
file's mtime, so two dialects of one file are two different sources.

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
