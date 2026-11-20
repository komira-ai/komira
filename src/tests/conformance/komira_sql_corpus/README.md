# komira_sql_corpus

The SQL conformance corpus: cases, each one SELECT over tables its corpus
builds in SQL, with the answer the pinned DuckDB
([third_party/duckdb](../../../../third_party/duckdb/README.md)) gives
committed beside it. Komira's answer to a query is DuckDB's answer
(AGENTS.md, B21); these are the answers a SQL end-to-end suite holds the
engine to. Each case is run again by the pinned DuckDB as a `sql_oracle`
build action ([tools/build/sql](../../../../tools/build/sql/README.md)), and
the action fails unless its answer equals the committed one byte for byte.
Test-only data: nothing here is Mojo or Python, nothing komira builds is an
input, and nothing runs komira on these cases yet.

```sh
./buck2 build //src/tests/conformance/komira_sql_corpus:corpus
./buck2 build //src/tests/conformance/komira_sql_corpus:join_shapes
./buck2 build //src/tests/conformance/komira_sql_corpus:join_shapes/inner_basic
./buck2 build //src/tests/conformance/komira_sql_corpus:compare_check
```

## Layout

| path | what it holds |
|---|---|
| `cases/<corpus>/tables.sql` | the corpus's tables: `CREATE TABLE` with every column's type, then its rows |
| `cases/<corpus>/<case>.sql` | one case: its row order line, comment lines, one SELECT (no `;`) |
| `cases/<corpus>/<case>.tsv` | the committed answer |
| `sql/run.sql` | the case runner |
| `sql/compare.sql` | `first_difference(got, want)`: where two answers first differ |
| `sql/compare_check.sql` | `first_difference` over planted pairs |

`:<corpus>/<case>` runs one case, `:<corpus>` every case of a corpus (its
answers, as `<case>.tsv`), `:corpus` every case.

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

`sql/run.sql` writes a case's answer with

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

Then `answer.tsv` must equal the committed `<case>.tsv` byte for byte, or the
action fails with where they first differ:

```
corpus case: answer.tsv differs from the committed expected.tsv, line 2: got "1", want "2"
```

## Regenerating

After a DuckDB bump, or to add a case, write the answers without comparing
them, then copy them over the committed ones and review the diff:

```sh
./buck2 build //src/tests/conformance/komira_sql_corpus:<corpus> -c komira_sql_corpus.write=true --show-output
```

## The corpora

Counts are of the case files (`ls cases/<corpus>/*.sql`, less
`tables.sql`); 6197 in all, 2217 of them `order: query`.

| corpus | cases | what it probes |
|---|---|---|
| `join_shapes` | 57 | INNER, LEFT, RIGHT, FULL, CROSS and NATURAL joins, ON and USING: keys with orphans, duplicates and a NULL on both sides, an empty side, DOUBLE keys with NaN and -0.0, string keys, a two-column key, a repeated column name |
| `set_operations` | 45 | UNION, INTERSECT, EXCEPT, each with and without ALL, over duplicates and NULLs, widened key types |
| `subquery_cte` | 45 | scalar, IN, EXISTS and correlated subqueries, CTEs (with and without reuse) |
| `window_frames`, `range_frames` | 91, 119 | window aggregates over ROWS frames, and RANGE frames by offset over integers, floats, NULL and tied keys, both directions |
| `order_by_limit` | 49 | ORDER BY direction and NULL placement, several keys, LIMIT and OFFSET (zero, past the end), ties in a group |
| `predicates_three_valued`, `conditional_exprs` | 147, 90 | AND, OR, NOT, comparisons, IN, BETWEEN, LIKE and IS NULL over NULLs; CASE, COALESCE, NULLIF, IF in SELECT, WHERE, GROUP BY, aggregates and ORDER BY |
| `null_pattern_n<rows>`, `null_adversarial_n<rows>` | 882, 2100 | filters, aggregates and sorts over a table of `<rows>` rows (5 to 257, either side of 8, 16, 32, 64, 128, 192 and 256) whose text column mixes NULLs and empty strings |
| `aggregate_modifiers`, `aggregate_names`, `agg_exact_floats` | 55, 31, 17 | DISTINCT and FILTER on aggregates, grouping forms; median, quantiles and the other aggregate names with their output names; float aggregates over 50000 rows of dyadic rationals, whose sums are exact in any order |
| `scalar_fn`, `string_domain` | 293, 52 | the scalar functions (math, string, date part) over a row each of edge inputs; string functions over Unicode, combining marks, NUL and empty strings |
| `numeric_domain`, `numeric_envelope` | 103, 42 | arithmetic over every integer width signed and unsigned, FLOAT and DOUBLE, at their extremes (the rows that overflow are left out); comparisons and promotion across types |
| `cast_boundaries`, `temporal_domain` | 108, 96 | CAST between types at their boundaries; date and timestamp parts, truncation and arithmetic, at the ends of months, leap years and before year 1 |
| `fn_positions`, `fn_postagg_positions` | 136, 57 | the same function in each place a query can hold it: SELECT, WHERE, GROUP BY, HAVING, ORDER BY, over an aggregate, in a CTE |
| `cross_<type>` (18 corpora) | 1488 | one query shape per operator (filter, project, aggregate, group, sort, distinct, join) over a column of each type an Arrow file carries: integers, floats, DECIMAL(12,2), strings, dictionary strings, BOOLEAN, BLOB, DATE and the timestamp units |
| `surface_limits`, `ops_controls`, `bind_controls` | 27, 32, 35 | queries at the limits of the SQL surface (repeated runs, an aggregate over an aggregate, NaN and infinity, a reserved word as a column); small controls of common operations; the repaired twin of each query DuckDB refuses at bind time |

Dates: no table holds a date from 2025 up to 2026-08-31; the cases built
on dates in that window had them moved to the same day of another year
(2024, 2028 and 2029, or 2015), so a year-valued answer reads that year.

What was not brought over, and why: cases whose DuckDB answer is an error
(an overflow, a domain error, a bind or parse error: about 300) are not
here, since a case's answer is a table; a case for each is a follow-up
that needs an error answer in this format. Nor are queries whose rows
depend on how DuckDB breaks a tie (ROWS frames over tied keys), queries that
call functions DuckDB does not have, and records that were not DuckDB's
answers (another engine's refusals, Excel's rules).

## Tests

| target | what it proves | the defect it catches |
|---|---|---|
| `:corpus` | every case's answer, run again by the pinned DuckDB, equals its committed answer byte for byte | a committed answer DuckDB does not give; a DuckDB bump that changes an answer; a case or table edited without its answer |
| `:compare_check` | `first_difference` over planted pairs (equal, a changed cell, a changed header, a missing or an extra row, a missing or an extra final LF, a CR, an empty cell for `""`, nothing written, `-0.0` for `0.0`), each against the exact report it must give | a comparison that misses a difference or reports the wrong line |
| `tests//negative/sql_oracle:corpus_answer_differs`, `:corpus_unordered` (the self-test scenario `sql_oracle`) | the runner fails a case whose committed answer is wrong, and a case whose first line names no row order, each with its message | a runner that stopped comparing, or ran a case with no row order |
