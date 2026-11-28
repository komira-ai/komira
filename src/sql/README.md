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
kinds (`TVF_PARQUET`, `TVF_CSV`, `TVF_JSON`, `TVF_AVRO`, `TVF_ICEBERG`), `TvfOptions` (the
`all_varchar`, `header`, `delim` and `hive_partitioning` options of a `read_*` call,
the `allow_moved_paths` and `snapshot_from_id` options of `iceberg_scan`,
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
`SELECT`, `UNION ALL`, `UNION`, `INTERSECT`, `EXCEPT`), a `COPY ... TO` or a `CREATE TABLE ... AS`. Every
subquery body (scalar, `[NOT] EXISTS`, `[NOT] IN (SELECT ...)`, a derived
table, a set-operation branch) is parked in the statement's flat `subqueries`
table, and the expression node holds its index. Input the grammar has no
production for raises an `Error` that names it (`SQL syntax error` or
`SQL not supported`) instead of being read as something else. The ON of an
INNER (or bare) `JOIN` is folded into WHERE; a RIGHT or FULL join later in
the same FROM is therefore refused by name (`INNER_ON_BEFORE_OUTER_REFUSAL`),
because the folded predicate would drop the rows that join pads with NULL. A
LEFT, SEMI or ANTI join after it keeps the same answer and is parsed.

`SUBSTRING(s FROM start [FOR length])`, the standard form TPC-H Q22 writes,
parses as the call `substring(s, start[, length])`, as DuckDB reads it.

A `COPY ... TO` with no `FORMAT` takes its format from the destination's
extension, as DuckDB does (`sql.sql_copy_format`): `.parquet`, `.csv`, and
`.json`, `.jsonl` or `.ndjson`, after one `.gz` or `.zst` suffix is removed.
Any other extension is refused with `COPY_FORMAT_NOT_INFERRED` instead of
being written as Parquet. With no `COMPRESSION`, Parquet is snappy and CSV and
JSON take gzip from `.gz`, zstd from `.zst`, and none otherwise.

The parser recurses once per nested construct on the caller's thread, so it
refuses a statement nested deeper than `MAX_SQL_NESTING` (100) levels with
`SQL syntax error: the statement nests deeper than 100 levels`
(`sql.sql_nesting`) instead of exhausting the stack. DuckDB allows 1000; a
level here takes about 25 to 35 KB of stack (measured on linux-x86_64), so 1000
would not fit in the 8 MiB a host's query thread has. One level is one
parenthesised expression, function call, CASE, prefix `NOT`, `+`, `-` or `@`,
`IN ( ... )` list, subquery or derived table; chains a loop builds
(`a + b + c`, `a AND b`, an IN list's items, a UNION chain) are not levels.

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
`sql_bind_fn_args`, `sql_bind_fn_nested`, `sql_bind_timestamp`,
`sql_bind_civil`) lowers one `SqlExpr` to a plan `Expr` against a schema and a
`BindScope`. `sql_bind_expr` binds literals, columns, operators, `CASE` and a
scalar subquery by index into the bodies the caller bound first;
`sql_bind_call` resolves a function call through `sql_fn_table` (a declared
UDF fills in for a name no row lowers) and enforces the arity of each row that
does not check its own; the other five hold the desugars: `CAST` and
`DECIMAL` literals, the argument-shape functions (`greatest`, `coalesce`,
`date_part`, `left`, `substring` and the like), the nested-value and
date-arithmetic functions, `TIMESTAMP` literals and `make_timestamp`, and the
calendar-parts functions.

`sql_bind_civil` serves `make_date(y, m, d)`, `last_day(x)` and the
six-argument `make_timestamp(y, m, d, h, mi, s)` as DuckDB answers them,
from a day count of the parts (Hinnant's days-from-civil on INT64, with the
year shifted so every division is a floor) and DuckDB's own validity rules.
When every argument is a number literal the call folds at bind to a DATE or
TIMESTAMP literal, and an invalid one is refused at bind with DuckDB's message
(`Conversion Error: Date out of range: 2024-13-1`). Over columns, a row whose
arguments are invalid fails the query at execution with
`i64_from_str: no digits in 'make_date: Date out of range'` (or the
`last_day` / `make_timestamp` equivalent: `Date out of range`, `Time out of
range`, `Date and time not in timestamp range`): the error names the function
and what was out of range but not the values, where DuckDB's message carries
the values. A row with a NULL argument is NULL and never fails. `last_day` of
DuckDB's infinite DATE or TIMESTAMP is NULL, as in DuckDB. Refused by name:
`make_date`'s one-argument overloads, a DOUBLE or DECIMAL `make_date` argument
(DuckDB refuses those too), a VARCHAR argument (DuckDB casts a string
literal), and `last_day` of a TIMESTAMP WITH TIME ZONE. A call over columns is
a tree of `CASE` nodes, and a `WHERE` filter refuses at execution a predicate
that holds one, with a message naming the `CASE` node, not the function
(`batch_eval/predicate_null_scope.mojo`); a call of constants is a literal and
filters. Two departures from DuckDB follow from raising outside a `CASE` arm
and from folding at bind, and both fail the query rather than answer a wrong
value: invalid constant arguments are refused at bind even where the call sits
in a branch or a filter that DuckDB would not evaluate, and a call over columns
inside a user's `CASE`, `COALESCE` or `IF` fails on an invalid row even when
that row takes another branch (a `CASE` arm is evaluated over every row of the
batch). A
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
binds window functions with their `PARTITION BY` and `ORDER BY` (each window
order key may carry `NULLS FIRST` / `NULLS LAST`; an unwritten one is the
derived default), and the statement-level `ORDER BY` (column, ordinal, output
alias or expression, with explicit `NULLS FIRST` / `NULLS LAST`).

`sql.sql_binder` turns a parsed statement into a plan:
`bind_statement(stmt, catalog, footers)` returns a `BoundStatement` whose
`take_plan()` is the `LogicalPlan` of the query (or of a COPY or CREATE TABLE
AS source), with the statement kind and a COPY's destination or a CTAS's
table name. It resolves names case-insensitively against the catalog, the
`WITH` definitions and derived tables; binds scalar and aggregate
expressions, GROUP BY and HAVING, joins (inner, outer, NATURAL / USING, semi,
anti), subqueries (scalar, also in a HAVING and in the SELECT list of a
grouped query; a correlated scalar in a WHERE or the SELECT list of an
ungrouped query, see below; `[NOT] EXISTS`; `[NOT] IN`, NULL-aware, its body
either one table projecting one bare column or, uncorrelated, any query of
one column),
window functions, ORDER BY, LIMIT / OFFSET, DISTINCT, UNION ALL, UNION,
INTERSECT and EXCEPT; and
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
`SqlCatalog.add_parquet_source` registers such a resolved source as a table.
An `iceberg_scan('path' [, allow_moved_paths = true] [, snapshot_from_id = N])`
relation is resolved the same way, by the reader's `iceberg_relation(path,
allow_moved_paths, snapshot_id)`, which returns the `SourceVariant` the relation
scans (its own schema is the relation's schema); a reader that does not
override that method refuses with `SQL bind error: iceberg_scan('<path>') needs
a binder that reads Iceberg tables`. `parquet_footers.ParquetFooters` reads
Iceberg tables. Every other DuckDB `iceberg_scan` option (`version`,
`version_name_format`, `mode`, `metadata_compression_codec`,
`skip_schema_inference`, `snapshot_from_timestamp`) is refused by name, as is
any CSV, JSON or Parquet option on `iceberg_scan`, and both Iceberg options on
the other readers. `SqlCatalog.add_source` registers any resolved
`SourceVariant` as a table under its own schema (an Iceberg table). A `read_csv`, `read_json` or `read_avro`
relation gets its schema from `sql_tvf_bind`, which reads the file. The
binder's code is split over the `sql_bind_*` modules (the FROM scope,
operators, functions, casts and timestamps, subqueries, correlated scalar
subqueries, aggregates and
GROUP BY, output names, windows and ORDER BY, joins, parquet facts).

A correlated scalar subquery (`sql.sql_bind_corr_scalar`), one whose WHERE
names a column of the statement around it, as TPC-H Q2, Q17 and Q20 do, binds
grouped by its correlation keys: `(SELECT f(aggs) FROM R WHERE p AND r = o)`
is the group `o` of `SELECT r, aggs FROM R WHERE p GROUP BY r`, and over no
row its value is `f` with every count 0 and every other aggregate NULL, as in
DuckDB. The optimizer's `flatten_dependent_joins` makes it a LEFT join of the
outer rows with that grouped body. Its WHERE may name outer columns only in
`inner_column = outer_column` conjuncts, and its body must aggregate (sum,
count, min, max, avg) over a FROM of comma or CROSS joins with no GROUP BY,
HAVING, DISTINCT, ORDER BY, LIMIT or OFFSET; any other shape, an outer column
in its SELECT list, and a correlated scalar in a HAVING or a grouped SELECT
list are refused with `SQL not supported: a correlated scalar subquery ...`
naming it. One under a CASE or a function call binds as an uncorrelated body.

`UNION ALL` (`sql.sql_bind_set_op`, with the common types of
`sql.sql_bind_union`) binds the chain `a UNION ALL b UNION ALL c`
to one `PLAN_UNION` node with one child per branch, also as the body of a
derived table (`FROM (a UNION ALL b) u`). Each column takes DuckDB's common
type over the branches, folded left to right: the wider of two integers of one
signedness; a signed with an unsigned integer the signed type of twice the
unsigned width (an unsigned 64-bit one with a signed integer is refused, since
DuckDB's HUGEINT has no Arrow type); an integer or decimal with a float the
float; two decimals the larger scale with the larger integer digits (refused
above 38 digits); an integer with a decimal the decimal that holds the integer;
two zone-less timestamps the finer unit; an INTEGER or BIGINT with a VARCHAR the
VARCHAR (the integer cast to its plain decimal spelling, so 3 and `'3'` are one
value). A pair with no such rule (a string with any other type, a date with a
timestamp, ...) raises `SQL not supported: UNION ALL column <i> (<name>)`
naming both types. The union's names are the first
branch's, and a column is nullable when any branch's is. A branch whose names or
types differ from the union's gets one projection that casts and renames its
columns; a branch needing that projection with two columns of one name is
refused. Bare integer literals of every branch are INT32 when they fit, so
`SELECT 1 UNION ALL SELECT 5000000000` is INT64. `ORDER BY`, `LIMIT` and
`OFFSET` after the last branch apply to the whole union: the parser rewrites the
query to `SELECT * FROM (<union>) ORDER BY ... LIMIT ...`, so the sort and the
row window bind above the union node. On any other branch they are a
`SQL syntax error` naming the clause and the operator after it. A CTE body may
hold a chain of any set operator; ORDER BY, LIMIT or OFFSET after its last
branch is refused by name (`SQL not supported: <clause> after the last branch
of a set operation in a WITH body`), because the rewrite's derived table would
bind after the CTE.

`UNION` and `UNION DISTINCT` (`sql.sql_bind_set_op`) are the deduplicating
union: the union of the branches, with the same common column types and names
as UNION ALL, under a `PLAN_DISTINCT` over every column, so whole rows compare
with NULLs equal, every NaN is one value, and 0.0 and -0.0 are one value, as in
SELECT DISTINCT. A UNION takes everything to its left as its left input:
`a UNION ALL b UNION c` is one distinct over `union(a, b, c)`, while
`a UNION b UNION ALL c` keeps `c`'s rows, duplicates included, outside the
distinct of `a UNION b`. Errors name `UNION` and the branch numbers. Two result
columns of one name are refused, since the distinct names its columns.

`INTERSECT` and `EXCEPT` (`sql.sql_bind_set_op`) are the set forms: whole rows compared with NULLs equal, each result
row once. `INTERSECT DISTINCT` and `EXCEPT DISTINCT` spell the same;
`INTERSECT ALL` and `EXCEPT ALL` are refused by name. A chain takes DuckDB's
precedence: INTERSECT binds tighter than UNION, UNION ALL and EXCEPT, and each
level folds left to right, so `a UNION ALL b INTERSECT c EXCEPT d` is
`(a UNION ALL (b INTERSECT c)) EXCEPT d`; adjacent UNION ALL inputs stay one
union node. The two inputs of an INTERSECT or EXCEPT take the common column
types and the left input's names as UNION ALL's branches do (errors name the
operator and the branch numbers as the query spells them), and the pair binds
to plan nodes the engine already runs: a two-child union whose children add a
constant side column `#set_side` (0 left, 1 right), an aggregation grouped by
every column with `MIN` and `MAX` of the side, a filter (INTERSECT: min 0 and
max 1; EXCEPT: max 0) and a projection back to the columns. Two result columns
of one name are refused, since the grouping names its columns, and so is a
column named as one of the helper columns (`#set_side`, `#set_lo`, `#set_hi`),
which only a file's column can be.

`sql.sql_position` holds `SqlPosition`, a place in a text, and imports nothing,
so `sdk_exec.engine_plan` carries one without the front end;
`sql.sql_parse_text` says where a text stopped parsing. `tokenize(sql, starts)`
also appends each token's start byte (the EOF token's being the text's byte
length); `parse_sql_text(text, stopped_at)` is `parse_sql(tokenize(text))` that,
before it raises the tokenizer's or parser's own `Error` unchanged, sets
`stopped_at` (a `SqlPosition`, `line` and `column` from 1, the column counting
characters) to the start of the token the tokenizer was lexing or the parser was
looking at; `position_of(text, offset)` is that mapping from a byte offset.

`sql.sql_frontend` is the text entry over the three steps.
`statement_from_sql(sql, catalog, footers)` tokenizes, parses and binds in one
call and returns the `BoundStatement` (a query, a COPY or a CREATE TABLE AS).
`plan_from_sql(sql, catalog, footers)` returns a query's `LogicalPlan`, whose
`output_schema` is the result's schema (names, Arrow types and nullability, as
the binder derives them), and refuses a COPY or CREATE TABLE AS with an
`Error` starting `STATEMENT_NOT_A_QUERY`; `query_plan(bound)` is that refusal
over a statement already bound (`sdk_exec`'s `run_sql` runs a COPY itself). Every
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

The format a COPY takes from its destination:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from arrow.write_target import WCOMP_GZIP, WFMT_CSV, WFMT_PARQUET
from sql.sql_copy_format import copy_codec_from_path, copy_format_from_path

assert_equal(Int(copy_format_from_path("out/sales.parquet")), Int(WFMT_PARQUET))
assert_equal(Int(copy_format_from_path("rows.csv.gz")), Int(WFMT_CSV))
assert_equal(Int(copy_codec_from_path(WFMT_CSV, "rows.csv.gz")), Int(WCOMP_GZIP))
```

A statement nested one level past the limit is refused by the parser:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from sql.sql_nesting import MAX_SQL_NESTING
from sql.sql_parser import parse_sql
from sql.sql_token import tokenize

var deep = String("SELECT ")
for _ in range(MAX_SQL_NESTING + 1):
    deep += "("
deep += "1"
for _ in range(MAX_SQL_NESTING + 1):
    deep += ")"
var refused = String("")
try:
    _ = parse_sql(tokenize(deep))
except e:
    refused = String(e)
assert_equal(refused, "SQL syntax error: the statement nests deeper than 100 levels")
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
