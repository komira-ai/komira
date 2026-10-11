# komira_test_oracle

The plan conformance oracle: seeded datasets in the formats DuckDB writes,
and the expected answers of the ORACLE cases, all produced by the pinned
DuckDB CLI as `sql_oracle` build actions
([tools/build/sql](../../../../tools/build/sql/README.md)), plus the Mojo
check that holds each answer to its HAND twin by value. Test-only; no
Python; nothing komira builds is an input of an oracle.

```sh
./buck2 build //src/tests/helpers/komira_test_oracle:datasets_check
./buck2 build //src/tests/helpers/komira_test_oracle:discipline_check
./buck2 build //src/tests/helpers/komira_test_oracle:komira_test_oracle
```

## The datasets

[`datasets/gen.sql`](datasets/gen.sql) is the generator: `draw(i, s)`, row
`i`'s value of stream `s`, is the splitmix64 finalizer over `(i, s)` in
DuckDB's `UHUGEINT` arithmetic. There is no `random()`, no clock and no
file read, so the rows depend on nothing but the SQL and the pinned DuckDB.
Each column starts with its special values, then holds drawn values with
NULL on every eighth row. One file per dataset builds its table:

| dataset | rows | what it holds |
|---|---|---|
| `types` ([types.sql](datasets/types.sql)) | 256 | the nullable type matrix: `TINYINT` to `BIGINT` and `UTINYINT` to `UBIGINT`, each with its minimum and maximum; `FLOAT` and `DOUBLE` finite (`-0.0`, the least subnormal, the extremes) and, in `f32_special` and `f64_special`, NaN and both infinities; `DECIMAL(9,2)` and `DECIMAL(38,10)` at their extremes and least steps; strings (empty, Unicode up to 4-byte, `\N`, `NaN`, `NULL`, quotes, commas, LF, CR, TAB, backslash); `bin` (valid UTF-8) and `bin_raw` (bytes that are not UTF-8); `DATE` from 0001-01-01 to 9999-12-31; `TIMESTAMP_S`, `TIMESTAMP_MS`, `TIMESTAMP`, `TIMESTAMP_NS` and `TIMESTAMPTZ`, each with its first and last instant; `BOOLEAN`. `id` is the row number. Every other column holds NULLs and values. |
| `nulls` ([nulls.sql](datasets/nulls.sql)) | 5000 | NULL-heavy, for the three-valued logic, aggregation and join shards: `id`, group keys `k` with NULLs, `b1` and `b2` whose first nine rows are every pair of TRUE, FALSE and NULL, `i32`, `v` (quarters, so sums are exact), `s` holding both `''` and NULL, and `all_null` |
| `join_left`, `join_right` ([joins.sql](datasets/joins.sql)) | 40, 30 | a join pair: `id`, key `k` (NULL, 1 twice, and a key the other side lacks: 9 on the left, 10 on the right), string key `k2` (with `''` and NULL), and a value column |

`:datasets` writes each as `<dataset>.parquet` and `<dataset>.csv`
([write.sql](datasets/write.sql)), each a sub-target
(`:datasets[types.parquet]`) for a test's `test_data`:

| format | written by DuckDB as |
|---|---|
| Parquet | snappy, row groups of 2048 rows (this writer's least: it fills a group a vector of 2048 rows at a time), so `nulls` spans three groups and the others one |
| CSV | a header; NULL is an empty unquoted field and the empty string `""`; a BLOB is its escaped text (`\xFF` for a byte that is not printable ASCII) |

What these files carry differently from the tables, as the summary golden
records it: Parquet holds no seconds or milliseconds unit, so `ts_s` and
`ts_ms` read back as `TIMESTAMP` (microseconds), with the same instants; a
`TIMESTAMPTZ` is an instant in UTC with no zone name, in every format.

Not written, and why: ORC, Arrow IPC (file and stream, with or without LZ4
or ZSTD bodies) and JSON Lines. DuckDB's CLI writes none of the first two
without an extension download, which `sql_oracle` refuses; JSON Lines it
could write, but `sql_oracle` declares only `.parquet`, `.csv` and `.tsv`
outputs. No fixture bytes are committed in their place.

Kept apart from the Python datasets this replaces: the ns column starts at
1677-09-22 00:00:00, the first instant this DuckDB's `TIMESTAMP_NS` takes
(1677-09-21 00:12:44 is refused), and ends at int64 max - 1 ns (int64 max is
its infinity); a zoned column has no unit or zone of its own (DuckDB's
`TIMESTAMPTZ` is microseconds in UTC).

`:datasets_check` ([check.sql](datasets/check.sql)) rebuilds the tables in
its own session and requires: every file byte for byte the same as
`:datasets_twin`'s (the same SQL as another action, so another execution);
every file's rows equal to its table (both ways, `EXCEPT ALL`, with
`signbit()` beside each float column, since `-0.0 = 0.0` in SQL), the CSV
read with the table's types and `allow_quoted_nulls = false`; Parquet
snappy, in 2048-row groups, `nulls` in three; the special values above, by
name; and a summary (per column: the Parquet type, rows, values that are not
NULL, min, max, an md5 of every value in id order) byte for byte
[golden/summary.tsv](golden/summary.tsv). A generator change shows there in
review; regenerate the golden from the new `summary.tsv` and say why.

## Expected answers

An ORACLE case is `oracle/<shard>/<case>.sql`: comment lines, then one
SELECT. Each is the twin of a HAND case of
[komira_plan_conformance](../../conformance/komira_plan_conformance/README.md)
and reads the same rows: [sql/tables.sql](sql/tables.sql) loads the
corpus's own JSON Lines files with the schemas the corpus declares
(`twins/sort_rows.jsonl` here for `sort_topn_limit`, a shard the corpus does
not hold yet). The target `:<shard>/<case>` runs
[sql/run.sql](sql/run.sql): the case is held to the discipline, then run,
and its answer written with

```sql
COPY (FROM query(<the case's text>)) TO 'expected.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
```

How DuckDB spells each value there (`:spellings`, read back by
`test_duckdb_spellings`): NULL an empty unquoted cell, the empty string
`""`, a cell holding a TAB, LF, CR or `"` quoted with `"` doubled; integers
and decimals as digits (a decimal with exactly its scale's digits); a float
as its shortest round-trip decimal (`0.1`, `-0.0`, `1e+300`, `1.5e-07`),
`nan` or `-nan`, `inf` or `-inf`; booleans `true`/`false`.

### The oracle discipline

[sql/discipline.sql](sql/discipline.sql) defines `oracle_offences(q)`,
which reads the case on DuckDB's own parse of it (`json_serialize_sql`),
and `run.sql` fails the case's action, before it writes anything, when it
lists one:

- the case is one SELECT;
- its outermost query has an ORDER BY, so the file's row order is the
  query's and never the order DuckDB happened to produce;
- every ORDER BY key anywhere (the query's, a subquery's or CTE's, a
  window's OVER clause, an aggregate's own) states ASC or DESC and NULLS
  FIRST or NULLS LAST, so no answer reads `default_order` or
  `default_null_order`;
- an aggregate whose answer depends on the order rows reach it (`first`,
  `last`, `any_value`, `list`, `string_agg`, the `arg_min`/`arg_max`
  family, `mode`, the approximate quantiles and top-k) has an ORDER BY of
  its own, plain or in its OVER clause, and so does a window function that
  reads positions (`row_number`, `ntile`, `lead`, `lag`, `first_value`,
  `last_value`, `nth_value`, `fill`);
- `json_group_array`, `json_group_object` and `json_group_structure`
  (macros over `string_agg` with no ORDER BY) are refused;
- no call reads the clock, a random draw or the session, wherever it
  stands (a select list, a filter, an ORDER BY key, FROM): every scalar or
  aggregate the pinned DuckDB marks VOLATILE or CONSISTENT_WITHIN_QUERY
  (`random`, `setseed`, `uuid`, `gen_random_uuid`, `now`, `today`,
  `get_current_timestamp`, `nextval`...), ICU's clock readers, the
  session's settings and variables, the functions that parse or plan SQL
  text or answer with the running DuckDB (`json_serialize_plan`,
  `version`...), the built-in macros over any of these (`ago`...), any
  function named `duckdb_*` or `pragma_*`, the table functions that run SQL
  text (`query`, `query_table`, `json_execute_serialized_sql`), and `age`
  with one argument;
- no SQL value keyword: `current_date`, `current_timestamp`, `localtime`,
  `current_user` and the rest of the names DuckDB's binder turns into a
  clock or session call parse as column references, so a column reference
  whose last name is one of them is refused, quoted or qualified (more than
  DuckDB would refuse: an oracle table's column must not have such a name);
- no `USING SAMPLE` or `TABLESAMPLE`.

`threads = 1` and `TimeZone = 'UTC'` are the `sql_oracle` rule's own,
set before any SQL runs and locked.

`:discipline_check` ([sql/discipline_check.sql](sql/discipline_check.sql))
holds `oracle_offences` to planted cases, one per rule and arm (and cases
it must accept), each against the exact offences it must list, and one
planted case per entry of each of the discipline's name lists, generated
from a copy of the lists it holds itself (the lists must equal the copies),
so deleting an entry fails it; its output `discipline.tsv` lists them. The runner's own call of the discipline is
proved by two planted cases in `tests//negative/sql_oracle`
(`discipline_unplaced`, `discipline_unordered`), which the self-test
scenario `sql_oracle` requires to fail with the discipline's message.

Rules of the Python discipline this does not carry: every literal the
operand of a CAST, FROM limited to the registered tables and CTEs (the
`sql_oracle` action's `allowed_paths` still confines file reads to the
case's inputs), COLLATE, list-sort direction, and the run of each case
over every reordering of its tables' rows with a tie check per ORDER BY.
The HAND twin comparison (below) does not stand in for the tie check: a
tie DuckDB resolved by accident fails it only when the twin's policy
compares rows in order, not when it compares the tied rows as a multiset.

## The twin check

`komira_test_oracle` (Mojo) is the check, its tests welded:

| test | what it proves | the defect it catches |
|---|---|---|
| `test_twins` | every `:<shard>/<case>` answer, read by value under its HAND twin's schema and policy (komira_plan_harness's `duckdb_tsv`, then `compare_canon`), equals the twin; no answer lacks a twin, no twin an answer | a wrong HAND file, a wrong oracle query, a DuckDB that answers otherwise |
| `test_twin_checks` | the check fed planted defects | a check that compares text (`1.50` against `1.5`), misses a wrong cell, a missing row, NULL for a value, `-0.0` for `0.0`, ignores the twin's order policy, or misses an unpaired name |
| `test_duckdb_spellings` | the reader against bytes the pinned DuckDB wrote (`:spellings`) | a reader built on a transcription of DuckDB's output; a DuckDB bump that changes a spelling |

The mutants each test was seen red against are in the pull request that
added it.
