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

`komira_sql.sql_parser` is a hand-written recursive-descent parser:
`parse_sql(tokenize(sql))` returns a `SqlStatement`, a query (`WITH`,
`SELECT`, `UNION ALL`), a `COPY ... TO` or a `CREATE TABLE ... AS`. Every
subquery body (scalar, `[NOT] EXISTS`, `[NOT] IN (SELECT ...)`, a derived
table, a `UNION ALL` branch) is parked in the statement's flat `subqueries`
table, and the expression node holds its index. Input the grammar has no
production for raises an `Error` that names it (`SQL syntax error` or
`SQL not supported`) instead of being read as something else.

`komira_sql.sql_catalog` holds the tables and user functions a query may
name. `SqlCatalog` registers an in-memory `Table` or `RecordBatch`
(`add_in_memory`) or a parquet path with its schema (`add_parquet`, which
opens no file), resolves names case-insensitively (`has`, `schema_of`,
`table_of`) and builds the scan node of a table (`build_scan`).
`komira_sql.sql_udf_catalog` is the name-to-UDF lookup it carries:
`SqlUdfCatalog.declare` exposes an already-registered scalar UDF under its own
name, refuses a name the grammar or a lowering builtin already claims, and
replaces an earlier declaration of the same name.

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

`komira_sql.sql_binder` turns a parsed statement into a plan:
`bind_statement(stmt, catalog, footers)` returns a `BoundStatement` whose
`take_plan()` is the `LogicalPlan` of the query (or of a COPY or CREATE TABLE
AS source), with the statement kind and a COPY's destination or a CTAS's
table name. It resolves names case-insensitively against the catalog, the
`WITH` definitions and derived tables; binds scalar and aggregate
expressions, GROUP BY and HAVING, joins (inner, outer, NATURAL / USING, semi,
anti), subqueries (scalar, `[NOT] EXISTS`, `[NOT] IN`, the last NULL-aware),
window functions, ORDER BY, LIMIT / OFFSET, DISTINCT and UNION ALL; and
raises an `Error` starting `SQL bind error` or `SQL not supported`, naming
the construct, for what it does not bind. The parquet facts a binding needs
(the schema of a `read_parquet('path')` relation, and per-column null counts
that let a NOT IN drop its run-time NULL checks) come from the
`SqlParquetFooters` the caller passes (`komira_sql.sql_bind_parquet`), so no
parquet file is opened while binding; `NoParquetFooters` serves a statement
with no `read_parquet` relation. A `read_csv`, `read_json` or `read_avro`
relation gets its schema from `sql_tvf_bind`, which reads the file. The
binder's code is split over the `sql_bind_*` modules (the FROM scope,
operators, functions, casts and timestamps, subqueries, aggregates and
GROUP BY, output names, windows and ORDER BY, joins, parquet facts).

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

Parsing a query:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_sql.sql_token import tokenize
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_ast import STMT_QUERY, JK_LEFT

var st = parse_sql(tokenize(
    "SELECT o.k, sum(i.v) FROM orders o LEFT JOIN items i ON o.k = i.k"
    " GROUP BY o.k LIMIT 10"
))
assert_equal(Int(st.kind), Int(STMT_QUERY))
assert_equal(st.query.from_tables[0].rel_alias, "o")
assert_equal(Int(st.query.joins[0].kind), Int(JK_LEFT))
assert_true(Bool(st.query.joins[0].on_pred))
assert_equal(st.query.limit.value(), 10)
```

Registering a table and resolving it:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, SchemaBuilder
from komira_sql.sql_catalog import SqlCatalog

var sb = SchemaBuilder()
sb.add_field(Field(String("k"), ArrowType.INT64, False))
var cat = SqlCatalog()
cat.add_parquet(String("Orders"), String("orders.parquet"), sb.build())
assert_true(cat.has(String("ORDERS")))
assert_false(cat.has(String("items")))
var scan = cat.build_scan(String("orders"))
assert_equal(scan.output_schema.field_name(0), "k")
assert_equal(cat.udfs.num_declared(), 0)
```

Binding a query to a plan:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, SchemaBuilder
from komira_sql.sql_token import tokenize
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_bind_parquet import NoParquetFooters
from komira_sql.sql_binder import bind_statement

var tsb = SchemaBuilder()
tsb.add_field(Field(String("k"), ArrowType.INT64, False))
tsb.add_field(Field(String("v"), ArrowType.FLOAT64, True))
var tcat = SqlCatalog()
tcat.add_parquet(String("t"), String("t.parquet"), tsb.build())
var bound = bind_statement(
    parse_sql(tokenize("SELECT k, sum(v) AS total FROM t GROUP BY k")),
    tcat,
    NoParquetFooters(),
)
var plan = bound.take_plan()
assert_equal(plan.output_schema.field_name(0), "k")
assert_equal(plan.output_schema.field_name(1), "total")
```
