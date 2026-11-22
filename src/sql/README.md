# sql

The analytical SQL front end: a tokenizer, a parser and a binder. `sql.sql_token` lexes a
SQL string into a flat `List[Token]` that ends in `TK_EOF`: unquoted
identifiers are lower-folded (keywords and function names are ordinary
identifiers that the parser classifies by text), a single-quoted literal keeps
its bytes with `''` read as one quote, and an integer past `Int64.MAX` keeps
its decimal digits in `Token.text`. Bad input raises an `Error` that starts
with `SQL syntax error` (or `SQL not supported` for an operator this dialect
does not have), never a crash.

`sql.sql_ast` holds the nodes the parser builds and the binder lowers
to a plan: `SqlExpr` (a move-only expression tree that carries aggregate
calls inline, with `contains_aggregate()` and a deep `copy()`), the FROM
relations, joins, `SelectStmt` and the top-level `SqlStatement`, and the
name tables that say which identifiers the grammar claims
(`sql_agg_code`, `sql_call_is_aggregate`, `sql_name_claimed_by_grammar`).

`sql.sql_tvf_options` holds what the nodes share about table functions: the reader
kinds (`TVF_PARQUET`, `TVF_CSV`, `TVF_JSON`, `TVF_AVRO`), `TvfOptions` (the
`all_varchar`, `header`, `delim` and `hive_partitioning` options of a `read_*` call
and the `HIVE_PARTITIONING_*` modes), and the extension rules of the
`FROM '<path>'` replacement scan (`_replacement_scan_kind`, `_file_stem`).
`sql_ast` and `sql_parser` import them back, so the old import paths still work.

`sql.sql_fn_table` is the scalar-function table the binder reads: one
row per SQL function name (aliases share their row). `sql_scalar_fn_spec(name)`
returns a `SqlFnSpec` that says which expression node the name lowers to (its
kind and op) and its inclusive arity, or that the name is a real DuckDB
function this engine refuses (`FNK_REFUSED`, with the reason the binder
raises), or that no row has it (`FNK_NONE`). `lowers_to_a_node` is True only
for rows that become an expression, so a refused name may still be declared
as a user function. `sql_date_part_unit`, `sql_date_part_desugar` and
`sql_date_trunc_unit` are the separate `date_part` specifier and `date_trunc`
period tables; the function names and the specifier names are different sets.

`sql.sql_parser` is a hand-written recursive-descent parser:
`parse_sql(tokenize(sql))` returns a `SqlStatement`, a query (`WITH`,
`SELECT`, `UNION ALL`), a `COPY ... TO` or a `CREATE TABLE ... AS`. Every
subquery body (scalar, `[NOT] EXISTS`, `[NOT] IN (SELECT ...)`, a derived
table, a `UNION ALL` branch) is parked in the statement's flat `subqueries`
table, and the expression node holds its index. Input the grammar has no
production for raises an `Error` that names it (`SQL syntax error` or
`SQL not supported`) instead of being read as something else. The ON of an
INNER (or bare) `JOIN` is folded into WHERE; a RIGHT or FULL join later in
the same FROM is therefore refused by name (`INNER_ON_BEFORE_OUTER_REFUSAL`),
because the folded predicate would drop the rows that join pads with NULL. A
LEFT, SEMI or ANTI join after it keeps the same answer and is parsed.

`sql.sql_catalog` holds the tables and user functions a query may
name. `SqlCatalog` registers an in-memory `Table` or `RecordBatch`
(`add_in_memory`) or a parquet path with its schema (`add_parquet`, which
opens no file), resolves names case-insensitively (`has`, `schema_of`,
`table_of`) and builds the scan node of a table (`build_scan`).
`sql.sql_udf_catalog` is the name-to-UDF lookup it carries:
`SqlUdfCatalog.declare` exposes an already-registered scalar UDF under its own
name, refuses a name the grammar or a lowering builtin already claims, and
replaces an earlier declaration of the same name.

`sql.sql_tvf_bind` gives the `read_csv`, `read_json` and `read_avro`
table functions their schema at bind time and builds their scan leaf. A CSV
schema is inferred from a bounded prefix with the call's `delimiter` and
`has_header` (`all_varchar` then types every column STRING); a JSONL schema is
inferred from a newline-snapped 256 KiB prefix; an Avro schema is read from the
OCF container header. A `.gz`, `.zst` or `.lz4` CSV or JSONL file is
decompressed whole first (`parquet_codec.text_decompress`). An inference
that finds no column raises an `Error` naming the file. `tvf_relation_scan`
returns a lazy row-oriented scan whose source carries the dialect and the
file's mtime, so two dialects of one file are two different sources.

The expression binder (`sql_bind_expr`, `sql_bind_call`, `sql_bind_cast`,
`sql_bind_fn_args`, `sql_bind_fn_nested`, `sql_bind_timestamp`) lowers one
`SqlExpr` to a plan `Expr` against a schema and a `BindScope`. `sql_bind_expr`
binds literals, columns, operators, `CASE` and a scalar subquery by index into
the bodies the caller bound first; `sql_bind_call` resolves a function call
through `sql_fn_table` (a declared UDF fills in for a name no row lowers) and
enforces the arity of each row that does not check its own; the other four hold the desugars: `CAST` and
`DECIMAL` literals, the argument-shape functions (`greatest`, `coalesce`,
`date_part`, `left`, `substring` and the like), the nested-value and
date-arithmetic functions, and `TIMESTAMP` literals and `make_timestamp`. A
shape the engine cannot answer exactly raises an `Error` that names it:
`SQL not supported` for an unsupported shape, `SQL bind error` for malformed
input (an arity mismatch, a DECIMAL that does not fit), `SQL internal` for a
table row the binder has no arm for.

The aggregate, window and ORDER BY binders sit on top of the expression binder.
`sql_bind_agg_expr` binds an aggregate call (`count`, `sum`, `avg`, `min`,
`max`, `DISTINCT` forms and the statistical family) and hoists each aggregate
inside a larger expression into a hidden output, one accumulator per distinct
aggregate; an aggregate inside an aggregate, or in a position that cannot hold
one, is refused. `sql_bind_aggregate` plans a `GROUP BY` and `HAVING` (keys by
ordinal, alias or expression) and the plain projection. `sql_bind_window_order`
binds window functions with their `PARTITION BY` and `ORDER BY`, and the
statement-level `ORDER BY` (column, ordinal, output alias or expression, with
explicit `NULLS FIRST` / `NULLS LAST`).

`sql.sql_binder` turns a parsed statement into a plan:
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
(the `ParquetSource` a `read_parquet('path')` relation scans, which may be
several files and carry Hive partition columns after the data columns, and
per-file null counts that let a NOT IN drop its run-time NULL checks) come
from the `SqlParquetFooters` the caller passes (`sql.sql_bind_parquet`), so no
parquet file is opened while binding; `NoParquetFooters` serves a statement
with no `read_parquet` relation. `read_parquet('path', hive_partitioning =
true|false)` sets the mode the reader resolves the path under (no option is
auto-detect); a column counts as NULL-free only when every file of the
relation records no NULL and it is not a partition column.
`SqlCatalog.add_parquet_source` registers such a resolved source as a table. A `read_csv`, `read_json` or `read_avro`
relation gets its schema from `sql_tvf_bind`, which reads the file. The
binder's code is split over the `sql_bind_*` modules (the FROM scope,
operators, functions, casts and timestamps, subqueries, aggregates and
GROUP BY, output names, windows and ORDER BY, joins, parquet facts).

`UNION ALL` (`sql.sql_bind_union`) binds the chain `a UNION ALL b UNION ALL c`
to one `PLAN_UNION` node with one child per branch, also as the body of a
derived table (`FROM (a UNION ALL b) u`). Each column takes DuckDB's common
type over the branches, folded left to right: the wider of two integers of one
signedness; a signed with an unsigned integer the signed type of twice the
unsigned width (an unsigned 64-bit one with a signed integer is refused, since
DuckDB's HUGEINT has no Arrow type); an integer or decimal with a float the
float; two decimals the larger scale with the larger integer digits (refused
above 38 digits); an integer with a decimal the decimal that holds the integer;
two zone-less timestamps the finer unit. A pair with no such rule (a string with
a number, a date with a timestamp, ...) raises `SQL not supported: UNION ALL
column <i> (<name>)` naming both types. The union's names are the first
branch's, and a column is nullable when any branch's is. A branch whose names or
types differ from the union's gets one projection that casts and renames its
columns; a branch needing that projection with two columns of one name is
refused. Bare integer literals of every branch are INT32 when they fit, so
`SELECT 1 UNION ALL SELECT 5000000000` is INT64. `ORDER BY`, `LIMIT` and
`OFFSET` after the last branch apply to the whole union: the parser rewrites the
query to `SELECT * FROM (<union>) ORDER BY ... LIMIT ...`, so the sort and the
row window bind above the union node. On any other branch they are a
`SQL syntax error` naming the clause.

`sql.sql_frontend` is the text entry over the three steps.
`statement_from_sql(sql, catalog, footers)` tokenizes, parses and binds in one
call and returns the `BoundStatement` (a query, a COPY or a CREATE TABLE AS).
`plan_from_sql(sql, catalog, footers)` returns a query's `LogicalPlan`, whose
`output_schema` is the result's schema (names, Arrow types and nullability, as
the binder derives them), and refuses a COPY or CREATE TABLE AS with an
`Error` starting `STATEMENT_NOT_A_QUERY`; `query_plan(bound)` is that refusal
over a statement already bound, which `sdk_exec`'s `run_sql` uses too. Every
other failure is the tokenizer's, parser's or binder's own `Error`, unchanged.
Nothing is optimized, lowered or run.

## INTERVAL literals

`INTERVAL '<n>' <unit>` (also `INTERVAL <n> <unit>`) parses to an `SX_INTERVAL`
node holding a signed count (magnitude at most 10^9) and a unit. The units
accepted are YEAR, MONTH, WEEK and DAY, singular or plural. The binder folds
`<constant DATE> + INTERVAL`, `<constant DATE> - INTERVAL` and
`INTERVAL + <constant DATE>` into a `date32` literal while binding
(`sql_bind_interval`), in the WHERE, correlated-subquery, aggregate and
select-list binders alike, so `date '1998-12-01' - interval '90' day` and
the nine intervals in the TPC-H queries bind: Q1 `- interval '90' day`;
Q4, Q10 and Q15 `+ interval '3' month`; Q14 `+ interval '1' month`; Q5, Q6,
Q12 and Q20 `+ interval '1' year`. The plan has no INTERVAL
type and no INTERVAL value ever reaches it. Chains fold left to right
(`date '1994-01-01' + interval '1' year - interval '1' day`).

Month and year arithmetic clamps the day to the end of the target month, as
PostgreSQL and DuckDB do: 31 Jan + 1 month is 28 Feb (29 in a leap year),
29 Feb + 1 year is 28 Feb, 31 Mar - 1 month is 29 Feb in a leap year. A year
is 12 months, a week 7 days. A clamped day is not restored by the next step
of a chain (31 Jan + 1 month + 1 month is 29 Mar in 2024). A result outside
years 1 to 9999 is refused.

Refused by name: a unit outside the accepted four (QUARTER, HOUR, MINUTE,
SECOND, MILLISECOND, and the rest), a unit written inside the string
(`'3 month'`), a non-integer or oversize count, a missing unit, a non-constant
DATE operand (`col + interval '1' day`; the interval is folded at bind time,
so a column cannot take it), a TIMESTAMP or string operand, and an INTERVAL
anywhere else (a projection, a comparison, `INTERVAL - DATE`, `INTERVAL * n`,
`INTERVAL + INTERVAL`). Because the fold happens in the expression binder, ORDER BY and GROUP BY see
a constant expression like `1 + 1`, which they already accept, and not a bare
date literal, which ORDER BY refuses as a constant key. A count
may be signed and unquoted (`interval -3 day`). One difference from DuckDB: its `DATE + INTERVAL` is
a TIMESTAMP, here the result stays a DATE; a comparison against a DATE column
gives the same rows.

## Examples

Lexing a statement:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from sql.sql_token import tokenize, TK_LE, TK_EOF

var toks = tokenize("SELECT Price FROM t WHERE qty <= 10")
assert_equal(toks[1].text, "price")  # lower-folded
assert_equal(Int(toks[6].kind), Int(TK_LE))
assert_equal(toks[7].int_val, Int64(10))
assert_equal(Int(toks[8].kind), Int(TK_EOF))
```

An expression that holds an aggregate below its top node:

<!-- mojo-hidden from std.testing import assert_true, assert_false -->
```mojo
from sql.sql_ast import SqlExpr, SXAGG_SUM, SXOP_ADD

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
from sql.sql_fn_table import sql_scalar_fn_spec, FNK_STRING_FN, FNK_REFUSED, FNK_NONE

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
from sql.sql_token import tokenize
from sql.sql_parser import parse_sql
from sql.sql_ast import STMT_QUERY, JK_LEFT

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
from arrow.arrow_types import ArrowType
from arrow.schema import Field, SchemaBuilder
from sql.sql_catalog import SqlCatalog

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
from arrow.arrow_types import ArrowType
from arrow.schema import Field, SchemaBuilder
from sql.sql_token import tokenize
from sql.sql_parser import parse_sql
from sql.sql_catalog import SqlCatalog
from sql.sql_bind_parquet import NoParquetFooters
from sql.sql_binder import bind_statement

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

Text to a plan and its result schema, and the statement kind of a write:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from arrow.arrow_types import ArrowType
from arrow.schema import Field, SchemaBuilder
from sql.sql_ast import STMT_COPY
from sql.sql_catalog import SqlCatalog
from sql.sql_bind_parquet import NoParquetFooters
from sql.sql_frontend import plan_from_sql, statement_from_sql

var fsb = SchemaBuilder()
fsb.add_field(Field(String("k"), ArrowType.INT64, False))
fsb.add_field(Field(String("v"), ArrowType.FLOAT64, True))
var fcat = SqlCatalog()
fcat.add_parquet(String("t"), String("t.parquet"), fsb.build())
var plan = plan_from_sql(
    "SELECT k, avg(v) AS mean_v FROM t GROUP BY k", fcat, NoParquetFooters()
)
assert_equal(plan.output_schema.field_name(1), "mean_v")
assert_true(plan.output_schema.field_arrow_type(1) == ArrowType.FLOAT64)
var copy = statement_from_sql(
    "COPY (SELECT k FROM t) TO 'out.csv' (FORMAT csv)", fcat, NoParquetFooters()
)
assert_equal(Int(copy.kind), Int(STMT_COPY))
```

A multi-file parquet relation, built in memory (no file is opened), registered in
a catalog and read back through its schema: the files' columns, then the Hive
partition columns.

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from arrow.arrow_types import ArrowType
from arrow.schema import Field, SchemaBuilder
from scan_source.parquet_source import ParquetSource
from sql.sql_catalog import SqlCatalog, catalog_relation_schema
from sql.sql_bind_parquet import parquet_relation_schema

var psb = SchemaBuilder()
psb.add_field(Field(String("v"), ArrowType.INT64, False))
var pcols = List[Field]()
pcols.append(Field(String("year"), ArrowType.INT64, False))
var pvals = List[List[String]]()
var row0 = List[String]()
row0.append(String("2028"))
var row1 = List[String]()
row1.append(String("2029"))
pvals.append(row0^)
pvals.append(row1^)
var ppaths = List[String]()
ppaths.append(String("y=2028/a.parquet"))
ppaths.append(String("y=2029/b.parquet"))
var psrc = ParquetSource.partitioned(ppaths^, psb.build(), pcols^, pvals^)

var rel_schema = catalog_relation_schema(psrc)
assert_equal(rel_schema.num_columns(), 2)
assert_equal(rel_schema.field_name(0), "v")
assert_equal(rel_schema.field_name(1), "year")
assert_equal(parquet_relation_schema(psrc).field_name(1), "year")

var pcat = SqlCatalog()
pcat.add_parquet_source(String("Events"), psrc^)
assert_true(pcat.has(String("events")))
assert_equal(pcat.schema_of(String("EVENTS")).field_name(1), "year")
assert_false(pcat.has(String("other")))
```

The resolved relations the binder keeps, by path and `hive_partitioning` mode:
the same path under two modes is two entries, and a path never recorded raises.

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from arrow.arrow_types import ArrowType
from arrow.schema import Field, SchemaBuilder
from scan_source.parquet_source import ParquetSource
from sql.sql_bind_parquet import ParquetFacts
from sql.sql_tvf_options import HIVE_PARTITIONING_AUTO, HIVE_PARTITIONING_OFF

var fsb2 = SchemaBuilder()
fsb2.add_field(Field(String("v"), ArrowType.INT64, False))
var facts = ParquetFacts()
assert_false(facts.has_relation(String("d/*.parquet"), HIVE_PARTITIONING_AUTO))
facts.add_relation(
    String("d/*.parquet"),
    HIVE_PARTITIONING_AUTO,
    ParquetSource(String("d/a.parquet"), fsb2.build()),
)
assert_true(facts.has_relation(String("d/*.parquet"), HIVE_PARTITIONING_AUTO))
assert_false(facts.has_relation(String("d/*.parquet"), HIVE_PARTITIONING_OFF))
var got = facts.source_of(String("d/*.parquet"), HIVE_PARTITIONING_AUTO)
assert_equal(got.path, "d/a.parquet")

var refused = False
try:
    _ = facts.source_of(String("d/*.parquet"), HIVE_PARTITIONING_OFF)
except e:
    refused = True
    assert_equal(
        String(e),
        "SQL bind error: no parquet footer was read for 'd/*.parquet'",
    )
assert_true(refused)
```
