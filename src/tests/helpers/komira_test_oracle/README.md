# komira_test_oracle

The shared Python of the plan conformance oracle: test-only, run with the
hermetic Python ([tools/build/python](../../../../tools/build/python/README.md),
pins in [third_party/python](../../../../third_party/python/README.md)). It
holds the datasets (seeded tables built in Python and written in every format
the suite scans, so that every scan of one table has one expected answer
whatever the format, and no input is written by komira) and the expected
answers of the ORACLE cases (DuckDB runs each case's SQL over those tables,
and the result is written as the canonical result text of the Mojo harness
`komira_plan_harness`).

```sh
./buck2 build komira//src/tests/helpers/komira_test_oracle:test_datasets
./buck2 build komira//src/tests/helpers/komira_test_oracle:test_render
./buck2 build komira//src/tests/helpers/komira_test_oracle:test_expected
```

## The datasets

[`datasets.py`](datasets.py) builds each table from a fixed seed
(`random.Random` with a constant integer) and constant special values: no
clock, no file read. [`gen_datasets.py`](gen_datasets.py) is a
`python_oracle` script ([Oracles](../../../../tools/build/python/README.md#oracles)):
the target `:datasets` runs it twice on the farm and exists only if both
runs wrote the same bytes. Every input it has is a checked-in file or the
pinned pyarrow wheel; the rule refuses, at analysis, an input built by any
target outside `third_party/`.

| dataset | rows | what it holds |
|---|---|---|
| `types` | 256 | the nullable type matrix: `int8` to `int64` and `uint8` to `uint64` (each with its minimum and maximum); `float32` and `float64` finite (`-0.0`, the least subnormal, the extremes) and, in `f32_special` and `f64_special`, NaN and both infinities; `decimal128(9,2)` and `decimal128(38,10)` at their extremes; strings (empty, Unicode up to 4-byte, `\N`, `NaN`, `NULL`, quotes, commas, newlines, CR, TAB, backslash, NUL); `bin` (valid UTF-8) and `bin_raw` (bytes that are not UTF-8); `date32` from 0001-01-01 to 9999-12-31; timestamps in `s`, `ms`, `us` and `ns`, each naive and zoned (`UTC` for `s` and `ms`, `+05:30` for `us` and `ns`); `bool`. Every column holds NULLs and values. |
| `nulls` | 1000 | NULL-heavy, for the three-valued logic, aggregation and join shards: `id` (not nullable), group keys `k` with NULLs, `b1` and `b2` whose first nine rows are every pair of true, false and NULL, `i32`, `v` (quarters, so sums are exact), `s` holding both `""` and NULL, and `all_null` |
| `join_left`, `join_right` | 40, 30 | a join pair: `id`, key `k` (NULL, a duplicated key, and a key the other side lacks: 9 on the left, 10 on the right), string key `k2` (with `""` and NULL), and a value column |

The output directory holds, per dataset, `<dataset>.schema` and one file per
format, and `index.tsv`: one line per data file with its dataset, format, row
count and the columns it holds. Each file is a sub-target of `:datasets`
(`:datasets[types.parquet]`), for a Mojo library's `test_data` or a
`py_test`'s `$(location ...)`.

| format | file | written by |
|---|---|---|
| Parquet | `.parquet` | pyarrow, snappy, row groups of 100 rows |
| ORC | `.orc` | pyarrow |
| CSV | `.csv` | [`formats.py`](formats.py): NULL is an empty unquoted field, every string and binary value is quoted, so `""` is the empty string |
| JSON Lines | `.jsonl` | [`formats.py`](formats.py): decimals, dates and timestamps are strings |
| Arrow IPC file | `.arrow`, `.lz4.arrow`, `.zstd.arrow` | pyarrow, bodies uncompressed, LZ4 frame, ZSTD; batches of 100 rows |
| Arrow IPC stream | `.arrows`, `.lz4.arrows`, `.zstd.arrows` | as the file format |

A format's file holds the columns it carries exactly; the others are left
out of that file only, each for a reason recorded in `datasets.py` and seen
with the pinned pyarrow on the farm. `nulls` and the join pair are whole in
every format.

| format | leaves out of `types` | because |
|---|---|---|
| ORC | `u8` to `u64`; every timestamp but `ts_ns` | ORC has no unsigned type; pyarrow reads every ORC timestamp back as `timestamp[ns]` (another unit, and instants before 1677 out of range), and an ORC instant holds no zone name, so `ts_ns_tz` comes back with `tz=UTC` |
| Parquet | `ts_s`, `ts_s_tz` | Parquet has no seconds unit: pyarrow writes milliseconds and reads back `timestamp[ms]` |
| JSON Lines | `f32_special`, `f64_special`, `bin_raw` | JSON has no NaN or infinity, and a JSON string is text, not bytes |

The `ns` timestamps start at the first whole second of the int64 range
(1677-09-21 00:12:44), not at -2^63 ns: pyarrow's CSV and JSON parsers
refuse that instant.

### The schema sidecar

`<dataset>.schema` is one line: the schema line of the canonical result text
of the Mojo harness `komira_plan_harness`, one `<name>:<type>` entry per
column, `?` when nullable, separated by TAB, as its `type_text.mojo` spells
an entry and its `escape.mojo` escapes a name. Types are spelt as
plan_vocabulary's ArrowType without `ARROW_TYPE_`, in lower case, with
`decimal128(<p>,<s>)` and `timestamp_<unit>(<zone>)`. Names and zones are
escaped alike: a backslash, TAB, LF, CR and other control bytes take their
escapes, each of `: , < > [ ] { } ( )` a backslash, and so does a `#` that
comes first (`+05\:30`, `\#a\{b\}`). The spelling lives in
[`schema_text.py`](schema_text.py) alone, and only flat types are spelt: no
dataset has a nested column, and a nested type is refused rather than spelt
by code nothing exercises.

## Expected answers

An ORACLE case is `oracle/<shard>/<case>.sql`: one SELECT after a header of
`--` lines ([`oracle_case.py`](oracle_case.py)): `-- order:` (`total`,
`none` or `keys=<c1>,<c2>`, required), `-- float:` (`ulps=<n>` or
`rel=<x>`, default `ulps=0`) and `-- not null:` (the columns declared not
nullable; every other column is nullable). DuckDB's result types carry no
nullability, so the declaration is hand-derived from the query semantics
document's type table, and a declared column that holds a NULL is refused.

[`gen_expected.py`](gen_expected.py) is the `python_oracle` `:expected`. It
hands DuckDB (the pinned wheel, 1.5.6) every dataset of `datasets.py` and
every HAND twin input of [`twin_inputs.py`](twin_inputs.py) as a pyarrow
table built in Python, never a file read back, runs with `threads = 1` and
`TimeZone = 'UTC'`, and writes `expect/<shard>/<case>.tsv` (a sub-target
`:expected[expect/<shard>/<case>.tsv]`) with, after the policy lines,
`# GENERATED by gen_expected.py (duckdb <version>, pyarrow <version>) from oracle/<shard>/<case>.sql`.
Before it runs a query it holds that same text to
[`sql_discipline.py`](sql_discipline.py), on DuckDB's own parse of it
(`json_serialize_sql`): every ORDER BY key states ASC or DESC and NULLS
FIRST or NULLS LAST (the query's, a window's OVER clause's, and a function's
own argument ordering, `first_value(x ORDER BY y) OVER (...)`, which DuckDB
keeps apart in `arg_orders`), every literal is the operand of a CAST (a
literal that is itself a LIMIT or OFFSET count aside, not one inside a
subquery computing it), no clock or random function and no `USING SAMPLE`
or `TABLESAMPLE`, one SELECT. DuckDB's
default placement is NULLS LAST, as the plan's is, so a key that leaves it
unstated, or a literal left uncast, computes the same rows today: only this
check notices.

[`render.py`](render.py) writes a pyarrow table as the harness's text, flat
types only (bool, the integers, float16/32/64, string and large_string,
binary, large_binary and fixed_size_binary, decimal128 and decimal256, the
dates, times, timestamps and durations as their stored integers, null),
cell for cell as `render.mojo` does, with one difference the format allows:
a NaN is written bare (`NaN`, which matches any NaN), the harness's
expected-side default, because the bits of a computed NaN depend on the
machine. A float's decimal half is what Mojo's float writer prints, the
shortest round-trip digits in Python's `repr` layout. The schema line is
[`schema_text.py`](schema_text.py)'s. [`canon.py`](canon.py) reads the text
back: it refuses what `parse.mojo` refuses, checks each cell against its
column's type, and compares two files as `compare.mojo` does.

Every case here is the twin of a HAND case of komira_plan_conformance (the
same plan over the same input) and its expectation must equal the HAND one:
a check on the oracle SQL, the HAND derivation and the query semantics
document at once. `twins/hand/` holds copies of those HAND expectations and
`twins/inputs/` copies of their JSON Lines inputs; the copies are compared by
`:test_expected`, not tied to the originals by a build edge, so a change to
a HAND case is copied here by hand.

| shard | cases |
|---|---|
| `filter_3vl` | `and_or_truth_table`, `not_truth_table`, `filter_not_and`, `compare_null_literal`, `compare_null_value`, `filter_ne_drops_null` |
| `agg_grouping` | `count_star_vs_count_col`, `sum_all_null_group_is_null`, `min_max_all_null_group`, `empty_input_no_keys`, `empty_input_with_keys` |
| `sort_topn_limit` | `asc_nulls_first`, `desc_nulls_last`, `multi_key_mixed`, `neg_zero_ties_zero`, `topn_two_keys`, `limit_over_sort` |

What the twins found: DuckDB 1.5.6 returns a float sort key with `-0.0`
turned into `0.0` (`ORDER BY f` gives the row whose `f` is `-0.0` the value
`0.0`), while a sort keeps its input's values. `neg_zero_ties_zero` sorts on
`f + 0.0`, which orders as `f` does (it maps only `-0.0`, to the `0.0` it
ties with) and leaves `f` untouched. A sort on a float column with `-0.0` in
it needs the same key.

## Tests

| target | what it proves | the defect it catches |
|---|---|---|
| `:datasets` | `gen_datasets.py` writes the same bytes in two runs, and writes exactly the files `outs` declares | a seed that is not fixed (a clock, a process id, a hash order); a dataset or format added to one of `datasets.py` and the BUCK file but not the other |
| `:test_datasets` | in a process of its own, rebuilds every table from its seeds and, for every dataset and format: the file, taken as the format, container and codec its name says (a table written out in the test, not read from `formats.py`), decodes with pyarrow to the table's columns (names in order, types with their parameters, nullability where the format keeps it, row count, and values: NULL positions equal, floats by their bits, so NaN, `-0.0` and `0.0` are told apart); each sidecar equals the line written out by hand in the test; each format leaves out exactly the columns listed by hand; the tables hold the special values (every integer and float extreme, the least decimal step at each scale, the first and last instant of every timestamp column), NULL pairs and join keys listed by hand; LZ4 and ZSTD IPC bodies hold frames of their codec; Parquet row groups and IPC batches are of 100 rows | a writer that turns NULL into a value (the CSV empty string), loses `-0.0` or a NaN, drops a type parameter or a column, or ignores its codec; one format's bytes under another's name; formats that disagree; a wrong unit scale in the generator; a sidecar that drifts from the harness's spelling; a generator change that drops the special values a shard relies on |
| `:expected` | each ORACLE case's query passes `sql_discipline.py` and DuckDB's answer renders; two runs write the same bytes; exactly the declared files are written | an ORDER BY key with no stated NULL placement or direction, an uncast literal, a clock or random function, a sample; a query DuckDB refuses; a not-null declaration a NULL contradicts; an answer that differs between two runs on one worker (an unseeded draw, a clock, a hash order in the generator). Not a row order the query leaves open (no ORDER BY, or ties under one): with `threads = 1` both runs execute the same plan in the same order, so such an order is the same twice and no test here sees it |
| `:test_sql_discipline` | `sql_discipline.py` refuses a query that breaks one rule, naming where DuckDB's parse keeps the offence, and accepts the ORDER BY and literal queries with the rule kept: ORDER BY keys of the query, an OVER clause, an aggregate and a window function's `arg_orders`; uncast literals, the LIMIT and OFFSET counts, a literal in a subquery computing a count; random(), now(), `USING SAMPLE` and `TABLESAMPLE`; two statements, a non-SELECT | a check that reads `orders` but not `arg_orders`; a LIMIT exemption inherited by the subquery below it; a random rule that looks only at function calls; a check that refuses for the wrong reason or refuses a kept rule |
| `:test_render` | `render.py`'s text of a table of every flat type (a value, a NULL and a value per column) equals cells spelt by hand; float decimals equal CPython's `repr` over 3000 seeded doubles and Mojo's own float32 and float64 vectors; the header and escaped names; slices and chunks; `canon.py` refuses each malformed file it is fed and normalizes hand floats; compare under total, none and keys; every dataset renders, parses and is a fixed point | a NULL written as anything but `\N` (the empty cell is a string's value); a float without its bits, a NaN with bits, a non-shortest decimal; a wrong escape, decimal scale or temporal conversion; a parser that accepts a cell of the wrong type |
| `:test_expected` | every case has one generated file and one HAND twin; each file parses, is in canonical form, carries its `.sql`'s policy and the `GENERATED` line with the pinned versions; each equals its HAND twin under the HAND policy; each twin input equals its JSON Lines copy | an oracle answer that differs from the hand derivation (or the reverse); a float written without bits; a file whose policy drifts from its case; a twin input that drifts from the corpus's dataset |

What none of it catches: the independence check reads the oracle's declared
inputs only. A script that opens an absolute path on the worker is not
stopped ([Oracles](../../../../tools/build/python/README.md#oracles)); review
holds `gen_datasets.py` and `gen_expected.py` to reading nothing but their data directory. The two runs of one action see
the same worker, so a dependence on the worker (its time zone, its CPU
count) shows up only as a difference between workers.

What these files will turn red in komira's own readers, though the files are
right (pyarrow reads them as the tables):

- komira_csv decides NULL after stripping a cell's quotes
  (`is_null_cell` in [`string_column_simd.mojo`](../../../komira_csv/string_column_simd.mojo),
  quotes skipped in [`csv_scanner_phase1.mojo`](../../../komira_csv/csv_scanner_phase1.mojo)),
  so it reads the quoted empty string `""` as NULL, and under its default
  null strings (`""`, `NULL`, `NA`, `NaN`, `null`) also the quoted strings
  `"NULL"`, `"NaN"` and `"null"` that `types.str` holds. A CSV scan of
  `types`, `nulls` and the join pair is red on those cells until the reader
  is fixed.
- komira_jsonl materializes no binary, unsigned or timestamp column, so a
  JSON Lines scan of those `types` columns is red until it does.

The mutants each test was seen red against are in the pull request that
added it.
