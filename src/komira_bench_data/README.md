# komira_bench_data

The datasets of the komira benchmarks. A benchmark is only worth publishing if anyone can tell which bytes it ran on, so this package pins a dataset down to files, sizes and checksums, checks a directory of files against that, writes a lock that names the exact dataset a run used, and generates the h2o-style tables from a seed.

Nothing here ships data. A package is a compiled library, so no dataset is in it, none is committed to a repository, and this package downloads nothing. Datasets live in a cache directory that the caller names (an argument; no environment variable is read).

## Modules

| module | holds |
| --- | --- |
| `manifest` | `DatasetManifest` and `DatasetFile`: a dataset at a scale and its files, each with an expected size, sha256 and row count; the manifest of every supported dataset (`tpch_manifest`, `clickbench_manifest`, `h2o_groupby_manifest`, `h2o_join_manifest`, `supported_manifests`, `find_manifest`) |
| `verify` | `verify_dataset` checks a cache directory against a manifest and returns a `VerifyReport` of `FileCheck`s; `sha256_of_file` streams a file in 4 MiB chunks |
| `lock` | `DatasetLock`, `lock_from_report`, `encode_lock`, `decode_lock`, `write_lock_file`, `read_lock_file` |
| `draw` | the generators' number source: `draw`, `draw_range`, `draw_score` and `Bijection`, pure functions of seed, column and row |
| `h2o_groupby`, `h2o_join` | the tables as Arrow batches for any row range (`h2o_groupby_batch`, `h2o_join_batch`) |
| `h2o_files` | the tables as Parquet bytes and as files (`h2o_groupby_parquet`, `h2o_join_parquet`, `generate_h2o_groupby_files`, `generate_h2o_join_files`, `write_new_file`) |

## What a manifest records

Each file of a dataset has a path relative to the cache directory and three expectations: its size in bytes, its sha256 and its row count. Any of them can be unrecorded (`UNRECORDED_BYTES`, `UNRECORDED_ROWS`, an empty sha256). A value is filled in only where it is known for certain; every other value is recorded from the first verified run, and the verifier reports what it observed so that there is something to record.

| dataset and scale | files | recorded today |
| --- | --- | --- |
| `tpch` `sf1`, `sf10`, `sf100` | `tpch/sf<N>/<table>.parquet`, eight tables | row counts from the specification's cardinalities (lineitem at sf1 only) |
| `clickbench` `full` | `clickbench/hits.parquet` | size and row count |
| `h2o_groupby` `n<rows>_k<groups>_seed<seed>` | `h2o/groupby_<scale>.parquet` | row count |
| `h2o_join` `n<rows>_seed<seed>` | `h2o/join_<scale>_{x,small,medium,big}.parquet` | row counts |

No sha256 is recorded yet, so a first verification reports every file as `UNRECORDED` with the size and sha256 it observed.

```mojo
from std.testing import assert_equal, assert_false
from komira_bench_data import find_manifest

var tpch = find_manifest("tpch", "sf1")
assert_equal(len(tpch.files), 8)
assert_equal(tpch.files[7].path, "tpch/sf1/lineitem.parquet")
assert_equal(tpch.files[7].expected_rows, 6_001_215)
assert_false(tpch.files[7].has_sha256())

var hits = find_manifest("clickbench", "full")
assert_equal(hits.files[0].expected_bytes, 14_779_976_446)
assert_equal(hits.files[0].expected_rows, 99_997_497)
```

## Supplying TPC-H and ClickBench

The package generates no TPC-H data and downloads nothing. Put the files where the manifest says, under the cache directory you pass:

- TPC-H: one Parquet file per table, named as in the table above, with the generator's native column types (decimals as decimals, dates as dates). The eight tables are `region`, `nation`, `supplier`, `customer`, `part`, `partsupp`, `orders` and `lineitem`.
- ClickBench: the single-file `hits` table as `clickbench/hits.parquet`, unmodified (105 columns, 99,997,497 rows).

Then verify. A TPC-H generator, a download step and a command that records the first checksums are not part of this package yet.

## Verifying

`verify_dataset(manifest, cache_dir)` checks every file of the manifest under `cache_dir` and gives each one a status:

| status | meaning |
| --- | --- |
| `VERIFIED` | size and sha256 are recorded and both match |
| `UNRECORDED` | present, everything recorded matches, but the size or sha256 is not recorded yet; the observed values are in the check |
| `MISSING` | no regular file at the path (a directory counts as missing) |
| `SIZE_MISMATCH` | the size differs from the recorded one; the file is not hashed, so a truncated download is refused without reading it |
| `SHA_MISMATCH` | the sizes agree and the sha256 differs |

`report.is_verified()` is true only when every file is `VERIFIED`; `report.is_usable()` also accepts `UNRECORDED`. A symbolic link inside the cache directory is followed. The verifier does not read Parquet footers, so it does not check row counts: those are in the manifest and the lock for the reader of a result.

```text
var manifest = find_manifest("clickbench", "full")
var report = verify_dataset(manifest, cache_dir)   # cache_dir comes from a flag
print(report.render())
```

## The lock

A lock records, for one dataset at one scale, every file's observed size and sha256 and the manifest's row count, and ends with a fingerprint: the sha256 of every line above it. A result that names the fingerprint names exactly those bytes. `lock_from_report` refuses a report with a missing, truncated or altered file, so no lock describes files that failed. `write_lock_file` writes `<cache_dir>/data.lock` and never replaces an existing one. `decode_lock` is strict: an edited byte, a missing or extra line, a repeated path or a path that leaves the directory is an error.

```text
komira-bench-data-lock/1
dataset tpch
scale sf1
generator -
file tpch/sf1/region.parquet 1000 <64 hex characters> 5
file tpch/sf1/lineitem.parquet 2000 <64 hex characters> -
fingerprint <64 hex characters>
```

```mojo
from std.testing import assert_equal, assert_raises
from komira_bench_data import DatasetLock, LockEntry, decode_lock, encode_lock

var sha = String("0123456789abcdef") * 4
var entries = List[LockEntry]()
entries.append(LockEntry(String("tpch/sf1/region.parquet"), 1000, sha, 5))
var lock = DatasetLock(String("tpch"), String("sf1"), String(), entries^)
var text = encode_lock(lock)
assert_equal(decode_lock(text).fingerprint(), lock.fingerprint())

with assert_raises(contains="fingerprint does not match"):
    _ = decode_lock(text.replace(" 1000 ", " 1001 "))
```

## The h2o-style generator

`h2o_groupby_parquet(rows, groups, seed)` and `h2o_join_parquet(table, rows, seed)` write the tables of the h2o db-benchmark's group-by and join data as Parquet bytes, with `komira_parquet_writer`. They have the columns and value ranges of that benchmark's files, and they are not its random stream (that is an R script): every value is a pure function of the seed, the column and the row number (SplitMix64's mixer), so the same seed and sizes give the same table on every machine and a row does not depend on the batch it is built in.

The same seed, row count, group count, codec and batch size give the same Parquet bytes. The batch size (`batch_rows`, 1,048,576 by default) is part of that identity: the writer chooses its encodings per row group and writes several batches that fit one row group without joining them first, so another batch size gives the same table in other bytes. A generator change that alters what is written for a seed is a new `H2O_GENERATOR_VERSION`, which the manifest and the lock carry.

```mojo
from std.testing import assert_equal, assert_true
from komira_bench_data import H2O_DEFAULT_SEED, h2o_groupby_parquet

var first = h2o_groupby_parquet(2000, 10, H2O_DEFAULT_SEED)
var second = h2o_groupby_parquet(2000, 10, H2O_DEFAULT_SEED)
assert_equal(len(first), len(second))
for i in range(len(first)):
    assert_equal(first[i], second[i])
assert_equal(first[0], UInt8(ord("P")))
```

`generate_h2o_groupby_files(cache_dir, rows, groups, seed)` and `generate_h2o_join_files(cache_dir, rows, seed)` write the files where the manifest says and return the manifest. They never replace a file: a dataset that is already there is verified, not regenerated.

The group-by table has `id1` and `id2` (strings `id001`..`id<k>`), `id3` (a string with ten digits, `rows // k` values), `id4` and `id5` (integers 1..k), `id6` (an integer 1..`rows // k`), `v1` and `v2` (integers 1..5) and `v3` (a double from 0 to 100 with six decimals). The join tables are `x` (N rows), `small` (N // 1,000,000 rows), `medium` (N // 1,000) and `big` (N rows), at least one row each; every key of `x` has a partner in the other three, and the key a table is unique on is spread over its rows by a seeded one-to-one map.

## Limits

- Row counts are carried, not checked: the verifier checks bytes and checksums.
- A cache directory is trusted as far as its files go: a symbolic link is followed.
- The package reads no environment and no configuration file; the cache directory is always an argument.
