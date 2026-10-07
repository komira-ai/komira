# komira_test_oracle

The shared Python of the plan conformance oracle: test-only, run with the
hermetic Python ([tools/build/python](../../../../tools/build/python/README.md),
pins in [third_party/python](../../../../third_party/python/README.md)). Today
it holds the datasets: seeded tables built in Python and written in every
format the suite scans, so that every scan of one table has one expected
answer whatever the format, and no input is written by komira.

```sh
./buck2 build komira//src/tests/helpers/komira_test_oracle:test_datasets
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
| ORC | `u8` to `u64`, every timestamp | ORC has no unsigned type; pyarrow's ORC writer reads `/usr/share/zoneinfo` for any timestamp, and the farm's workers have none |
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

## Tests

| target | what it proves | the defect it catches |
|---|---|---|
| `:datasets` | `gen_datasets.py` writes the same bytes in two runs, and writes exactly the files `outs` declares | a seed that is not fixed (a clock, a process id, a hash order); a dataset or format added to one of `datasets.py` and the BUCK file but not the other |
| `:test_datasets` | in a process of its own, rebuilds every table from its seeds and, for every dataset and format: the file, taken as the format, container and codec its name says (a table written out in the test, not read from `formats.py`), decodes with pyarrow to the table's columns (names in order, types with their parameters, nullability where the format keeps it, row count, and values: NULL positions equal, floats by their bits, so NaN, `-0.0` and `0.0` are told apart); each sidecar equals the line written out by hand in the test; each format leaves out exactly the columns listed by hand; the tables hold the special values (every integer and float extreme, the least decimal step at each scale, the first and last instant of every timestamp column), NULL pairs and join keys listed by hand; LZ4 and ZSTD IPC bodies hold frames of their codec; Parquet row groups and IPC batches are of 100 rows | a writer that turns NULL into a value (the CSV empty string), loses `-0.0` or a NaN, drops a type parameter or a column, or ignores its codec; one format's bytes under another's name; formats that disagree; a wrong unit scale in the generator; a sidecar that drifts from the harness's spelling; a generator change that drops the special values a shard relies on |

What none of it catches: the independence check reads the oracle's declared
inputs only. A script that opens an absolute path on the worker is not
stopped ([Oracles](../../../../tools/build/python/README.md#oracles)); review
holds `gen_datasets.py` to reading nothing. The two runs of one action see
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
