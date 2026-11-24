# komira_sql_conformance

The SQL conformance corpus: cases, each one SELECT over tables its corpus
builds in SQL, with the answer the pinned DuckDB
([third_party/duckdb](../../../../third_party/duckdb/README.md)) gives
committed beside it. Komira's answer to a query is DuckDB's answer
(AGENTS.md, B21); these are the answers a SQL end-to-end suite holds the
engine to. Each case is run again by the pinned DuckDB as a `sql_oracle`
build action ([tools/build/sql](../../../../tools/build/sql/README.md)), and
the action fails unless its answer equals the committed one byte for byte.
Test-only data: the corpora are SQL and TSV, and nothing komira builds is an
input except by the function coverage test below. Two corpora are run through komira: pipeline_exec's
`tests/test_sink_float_agg_duckdb.mojo` holds the ungrouped aggregation
sink to the answers of `agg_float_ungrouped`, and sdk_exec's
`tests/test_run_sql_topn.mojo` holds `run_sql` to the answers of each
`order_by_limit` case with a LIMIT or an OFFSET.

```sh
./buck2 build //src/tests/conformance/komira_sql_conformance:corpus
./buck2 build //src/tests/conformance/komira_sql_conformance:join_shapes
./buck2 build //src/tests/conformance/komira_sql_conformance:join_shapes/inner_basic
./buck2 build //src/tests/conformance/komira_sql_conformance:compare_check
```

## Layout

| path | what it holds |
|---|---|
| `cases/<corpus>/tables.sql` | the corpus's tables: `CREATE TABLE` with every column's type, then its rows |
| `cases/<corpus>/<case>.sql` | one case: its row order line, comment lines, one SELECT (no `;`) |
| `cases/<corpus>/<case>.tsv` | the committed answer |
| `sql/answer.sql` | runs a case and writes its answer, `answer.tsv` |
| `sql/check.sql` | holds `answer.tsv` to the committed answer |
| `sql/compare.sql` | `first_difference(got, want)`: where two answers first differ |
| `sql/compare_check.sql` | `first_difference` over planted pairs |

`:<corpus>/<case>` runs one case, `:<corpus>` every case of a corpus,
`:corpus` every case; `:<corpus>_answers` is a corpus's answers as one
directory, `<case>.tsv` each.

## A case

The first line of a case names the order its answer's rows are written in:

- `-- order: query`: the query's own ORDER BY decides it, and the order is
  part of the claim (the ORDER BY, LIMIT and OFFSET cases);
- `-- order: rows`: the answer is a multiset. The runner writes it as
  `FROM (<case>) ORDER BY COLUMNS(*)::VARCHAR ASC NULLS FIRST`: sorted by
  the text of each column in turn, so two answers with the same rows are
  the same bytes. It sorts on the text, not the values: this DuckDB writes a
  DOUBLE it sorted on from its sort key, which holds no -0.0 (`SELECT f FROM
  t ORDER BY f` answers `0.0` for a row holding `-0.0`), and a corpus that
  tells -0.0 from 0.0 would lose it.

A case reads only its corpus's tables; `tables.sql` runs first, in the same
in-memory session. A DOUBLE in a table is a quoted literal cast to DOUBLE
(`'-0.0'::DOUBLE`, `'nan'::DOUBLE`): an unquoted `-0.0` parses as a DECIMAL,
which has no sign of zero.

## The answers

`sql/answer.sql` writes a case's answer with

```sql
COPY (FROM query(<the case, ordered as its first line says>))
TO 'answer.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
```

so a header line, then one line per row, TAB between cells, in DuckDB's CSV
spellings (komira_test_oracle's
[README](../../helpers/komira_test_oracle/README.md#expected-answers) lists
them): NULL is an empty unquoted cell and the empty string `""`; a row whose
one cell is NULL is an empty line; a cell holding a TAB, LF, CR or `"` is
quoted; a float is its shortest round-trip decimal, `nan`, `inf` or `-inf`.
COPY writes a column name the answer repeats with a suffix: `SELECT * FROM K
JOIN M ON K.k = M.k` has the header `k a k_1 b`.

Then (`sql/check.sql`) `answer.tsv` must equal the committed `<case>.tsv` byte for byte, or the
action fails with where they first differ:

```
corpus case: answer.tsv differs from the committed expected.tsv, line 2: got "1", want "2"
```

## Regenerating

After a DuckDB bump, or to add a case, write the answers without comparing
them, then copy them over the committed ones and review the diff:

```sh
./buck2 build //src/tests/conformance/komira_sql_conformance:<corpus>_answers -c komira_sql_conformance.write=true --show-output
```

## The corpora

Counts are of the case files (`ls cases/<corpus>/*.sql`, less
`tables.sql`); 6273 in all, 2283 of them `order: query`.

| corpus | cases | what it probes |
|---|---|---|
| `join_shapes` | 57 | INNER, LEFT, RIGHT, FULL, CROSS and NATURAL joins, ON and USING: keys with orphans, duplicates and a NULL on both sides, an empty side, DOUBLE keys with NaN and -0.0, string keys, a two-column key, a repeated column name |
| `set_operations` | 45 | UNION, INTERSECT, EXCEPT, each with and without ALL, over duplicates and NULLs, widened key types |
| `union_all` | 28 | UNION ALL: the common type of two or three branches (integers of each width signed and unsigned, FLOAT, DOUBLE, DECIMAL, timestamp units), recorded with `typeof`; NULLs in one branch, an empty branch, a second branch with other column names, ORDER BY and LIMIT after the last branch, aggregates under and over a union, integer literals |
| `subquery_cte` | 45 | scalar, IN, EXISTS and correlated subqueries, CTEs (with and without reuse) |
| `window_frames`, `range_frames` | 91, 119 | window aggregates over ROWS frames, and RANGE frames by offset over integers, floats, NULL and tied keys, both directions |
| `order_by_limit` | 75 | ORDER BY direction and NULL placement, several keys, LIMIT and OFFSET (zero, past the end), ties in a group; `topn_*`: LIMIT with and without OFFSET over BIGINT, DOUBLE (NaN, inf) and text keys with ties at the cut and NULLS FIRST or LAST in both directions, total orders carrying `k`, and a 20000-row table `U` |
| `predicates_three_valued`, `conditional_exprs` | 147, 90 | AND, OR, NOT, comparisons, IN, BETWEEN, LIKE and IS NULL over NULLs; CASE, COALESCE, NULLIF, IF in SELECT, WHERE, GROUP BY, aggregates and ORDER BY |
| `null_pattern_n<rows>`, `null_adversarial_n<rows>` | 882, 2100 | filters, aggregates and sorts over a table of `<rows>` rows (5 to 257, either side of 8, 16, 32, 64, 128, 192 and 256) whose text column mixes NULLs and empty strings |
| `aggregate_modifiers`, `aggregate_names`, `agg_exact_floats` | 55, 31, 17 | DISTINCT and FILTER on aggregates, grouping forms; median, quantiles and the other aggregate names with their output names; float aggregates over 50000 rows of dyadic rationals, whose sums are exact in any order |
| `agg_float_ungrouped` | 22 | SUM, AVG, MIN, MAX, COUNT and COUNT(*) of a DOUBLE and a FLOAT column with no GROUP BY: 4096 rows of non-dyadic values with NULLs, and small sets holding NaN (first, among values, only), +inf, -inf, both infinities, a sum past the double range, only NULLs, no row, and -0.0 |
| `scalar_fn`, `string_domain` | 293, 52 | the scalar functions (math, string, date part) over a row each of edge inputs; string functions over Unicode, combining marks, NUL and empty strings |
| `numeric_domain`, `numeric_envelope` | 103, 42 | arithmetic over every integer width signed and unsigned, FLOAT and DOUBLE, at their extremes (the rows that overflow are left out); comparisons and promotion across types |
| `cast_boundaries`, `temporal_domain` | 108, 96 | CAST between types at their boundaries; date and timestamp parts, truncation and arithmetic, at the ends of months, leap years and before year 1 |
| `fn_positions`, `fn_postagg_positions` | 136, 57 | the same function in each place a query can hold it: SELECT, WHERE, GROUP BY, HAVING, ORDER BY, over an aggregate, in a CTE |
| `cross_<type>` (18 corpora) | 1488 | one query shape per operator (filter, project, aggregate, group, sort, distinct, join) over a column of each type an Arrow file carries: integers, floats, DECIMAL(12,2), strings, dictionary strings, BOOLEAN, BLOB, DATE and the timestamp units |
| `surface_limits`, `ops_controls`, `bind_controls` | 27, 32, 35 | queries at the limits of the SQL surface (repeated runs, an aggregate over an aggregate, NaN and infinity, a reserved word as a column); small controls of common operations; the repaired twin of each query DuckDB refuses at bind time |

Dates: no table holds a date from 2025 or 2026; where a case needed one, it
was moved to the same day of 2024, 2028 or 2029, or 2015, and a
year-valued answer reads that year.

Not here: a case whose DuckDB answer is an error (an overflow, a domain
error, a bind or parse error), since a case's answer is a table; a case
whose rows depend on how DuckDB breaks a tie or the order it scans rows (a
ROWS frame orders by a key and then `k`, a LIMIT has an ORDER BY); and a
query calling a function DuckDB does not have.

## Tests

| target | what it proves | the defect it catches |
|---|---|---|
| `:corpus` | every case's answer, run again by the pinned DuckDB, equals its committed answer byte for byte | a committed answer DuckDB does not give; a DuckDB bump that changes an answer; a case or table edited without its answer |
| `:compare_check` | `first_difference` over planted pairs (equal, a changed cell, a changed header, a missing or an extra row, a missing or an extra final LF, a CR, an empty cell for `""`, nothing written, `-0.0` for `0.0`), each against the exact report it must give | a comparison that misses a difference or reports the wrong line |
| `tests//negative/sql_oracle:corpus_answer_differs`, `:corpus_unordered` (the self-test scenario `sql_oracle`) | the runner fails a case whose committed answer is wrong, and a case whose first line names no row order, each with its message | a runner that stopped comparing, or ran a case with no row order |

## Function coverage

`function_coverage.tsv` says, for every name of `sql.sql_fn_table`'s scalar
function table and for a list of common analysis functions, what running it
measured. A count of the table's lines or rows says none of this: a row can
bind and never run, or run and answer another value than DuckDB.
`tests/test_function_coverage.mojo` writes the table by running the
`scalar_fn` cases through `run_sql` over the corpus's table T (written as
Parquet by the pinned DuckDB, `:scalar_fn_t`) and fails unless the text equals
the committed file; the failure message holds the measured table, which is
what to copy over the file after a change. Its rows come from the source text
of `sql_scalar_fn_spec`, so a row added to the table is a line here.

Columns: `name`; `row`, the lowering kind of the name's row (`FNK_*`),
`NO_ROW` when the table has none; `detail`, a refusal's reason family;
`common`, `yes` for a name on the common-analysis list; `cases`, how many
`scalar_fn` cases call the name; `outcome`:

| outcome | what it measured |
|---|---|
| `equal:n` | n cases ran and their rows are DuckDB's committed answer (same values, same row order when the case has ORDER BY); floats compared bit for bit |
| `equal_within_4_ulps:n` | n cases ran and differ from DuckDB only in floats, by at most 4 ulps |
| `differs:n` | n cases ran and an answer differs from DuckDB's |
| `refused_<step>:n` | n cases ended at that `run_sql` step (parse, bind, optimize, lower, execute) with a refusal: at bind the name does not bind, at a later step it bound and could not run |
| `batches_n` | the case ran but answered n result batches, not one |
| `unreadable:n` | n cases ran and answered one batch, and the comparison could not read the answer (a type the answer parser does not read, such as a list or a timestamp): the function executes, its values are not yet compared |
| `no_case` | the row lowers, and no case calls the name: bound by the table, never run by this measurement |
| `probe:refused_bind` | a refusal row or a name with no row: `SELECT name(k) FROM T` is refused at bind, as the table says |
| `probe:ok` | the same probe ran: a name the table refuses, or has no row for, that nevertheless executes |
| `internal` | a row keyed by a constant (`cast`, `try_cast`, the `IN` position form), not a function a user types |

A case's column names are not compared (the header of DuckDB's answer is
replaced by the engine's own): the table measures values and types, not how a
column is named.

### What the committed table says

Counts of the names in `function_coverage.tsv` (731 names), each from
`awk -F'\t' 'NR>2 { ... }'` over the `row` and `outcome` columns:

| names | what was measured |
|---|---|
| 120 | lowering rows whose cases all ran and equal DuckDB's answers |
| 4 | lowering rows that run and differ from DuckDB only in floats, within 4 ulps (`cos`, `exp`, `log`, `log10`) |
| 10 | lowering rows that run but whose answer the comparison cannot read yet: `date_trunc` and `datetrunc` (timestamp results), `string_split`, `str_split`, `split`, `string_to_array` and the four `regexp` / `string_split_regex` spellings (list results) |
| 4 | lowering rows refused at bind by every case that calls them: `date_diff`, `datediff`, `date_sub`, `datesub` (the table binds the row; the cases' calls do not bind; the reason is not recorded in this table) |
| 50 | lowering rows no `scalar_fn` case calls, so only the binder has seen them: among the common ones `abs`, `round`, `sign`, `trunc`, `floor`, `ceil`, `sqrt`, `pow`, `power`, `year`, `month`, `day`, `week`, `second`, `coalesce`, `nullif`, `ifnull`, `greatest`, `least`, `isnan`, `json_extract`, `json_extract_string`, `make_timestamp` (cases for some of them exist in other corpora, such as `fn_positions`, and are not run here) |
| 3 | rows keyed by a constant (`internal`) |
| 538 | refusal rows; every one is refused at bind by `SELECT name(k) FROM T` |
| 2 | common names with no row at all (`initcap`, `current_timestamp`), refused at bind |

So the rows that execute and are checked against DuckDB are 124 of the 189
lowering-row names (the first two lines); 14 execute or bind without a
verified answer; 50 are unmeasured. The gap list of common analysis
functions is the `common = yes` lines whose `row` is `FNK_REFUSED` or
`NO_ROW`: for example `split_part`, `strftime`, `strptime`, `epoch`, `age`,
`current_date`, `now`, `dayname`, `monthname`, `make_date`, `to_timestamp`,
`random`, `gcd`, `lcm`, `list_*` and `array_length`, `date_add`, `typeof`,
`position`, `format` and `printf`, `chr`, `initcap`, `current_timestamp`;
each carries its reason family in `detail`. The 50 unmeasured names are the
next measurement: a `scalar_fn` case each, with DuckDB's committed answer.
