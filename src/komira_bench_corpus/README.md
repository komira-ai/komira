# komira_bench_corpus

The SQL of three published benchmark suites, as Mojo data, with a content hash of every query and of every suite, so that two people who say "TPC-H query 5" or "ClickBench q28" can show they ran the same text. It holds no data, no engine and no harness: a harness imports it, asks for a suite, and runs each query's text.

**Derived from TPC-H; not a TPC result.** The TPC-H suite follows the TPC-H specification but no run of it is a TPC-H benchmark result and none is comparable to a published one. A report of this suite carries that sentence (`Suite.notice`).

| suite | queries | dataset | text |
|---|---|---|---|
| `tpch` | `q1` .. `q22` | `tpch`: the eight TPC-H tables, 61 columns, with the types of the specification (`DECIMAL(15,2)`, `DATE`) | the specification's text with the validation-run parameters |
| `clickbench` | `q0` .. `q42` | `clickbench`: the `hits` table, 105 columns | the benchmark's query list for DuckDB and ClickHouse |
| `h2o` | `q1` .. `q10` (groupby), `j1` .. `j5` (join) | `h2o_groupby`: table `x`; `h2o_join`: tables `x`, `small`, `medium`, `big` | the benchmark's DuckDB script, with the table name `x` |

```mojo
from komira_bench_corpus import (
    DATASET_H2O_JOIN,
    DATASET_TPCH,
    SUITE_CLICKBENCH,
    SUITE_H2O,
    SUITE_TPCH,
    TPCH_NOTICE,
    dataset,
    dataset_names,
    find_query,
    sha256_hex,
    suite,
    suite_ids,
    suites,
    tpch_q11_at_scale,
)
from std.testing import assert_equal, assert_true

# The suites and their ids.
var ids = suite_ids()
assert_equal(len(ids), 3)
assert_equal(ids[0], SUITE_TPCH)
assert_equal(ids[1], SUITE_CLICKBENCH)
assert_equal(ids[2], SUITE_H2O)
var all_suites = suites()
assert_equal(len(all_suites[0].queries), 22)
assert_equal(len(all_suites[1].queries), 43)
assert_equal(len(all_suites[2].queries), 15)

# One query: its key, the dataset it reads, its text and the hash of the text.
var q6 = find_query("tpch/q6")
assert_equal(q6.key(), "tpch/q6")
assert_equal(q6.dataset, DATASET_TPCH)
assert_true(q6.text.startswith("select\n  sum(l_extendedprice * l_discount)"))
assert_equal(q6.sha256(), sha256_hex(q6.text))
assert_equal(q6.sha256().byte_length(), 64)
assert_equal(suite("tpch").query("q6").sha256(), q6.sha256())
assert_equal(find_query("h2o/j2").dataset, DATASET_H2O_JOIN)

# One suite: its hash covers every id and every text, in order.
var tpch = suite("tpch")
assert_equal(tpch.sha256().byte_length(), 64)
assert_equal(tpch.notice, TPCH_NOTICE)
assert_true(tpch.notice.startswith("Derived from TPC-H; not a TPC result."))
assert_equal(tpch.title, "TPC-H, 22 queries, validation parameters")

# The dataset a suite expects: tables, columns and types, as DDL.
assert_equal(len(dataset_names()), 4)
var hits = dataset("clickbench")
assert_equal(len(hits.table("hits").columns), 105)
assert_equal(hits.table("hits").columns[0].name, "WatchID")
assert_equal(hits.table("hits").columns[0].sql_type, "BIGINT")
assert_true(hits.ddl().startswith("CREATE TABLE hits (\n  WatchID BIGINT,"))
assert_equal(hits.sha256().byte_length(), 64)

# Query 11 holds the fraction of scale factor 1; other scale factors divide it.
assert_equal(tpch_q11_at_scale(1), suite("tpch").query("q11").text)
assert_true(tpch_q11_at_scale(10).find("* 0.0000100000") >= 0)
```

## The text

- One statement per query: no terminating semicolon, no trailing newline, no comment, no tab, no carriage return. Every parameter is substituted. A harness that pipes the text to a command-line client adds its own terminator.
- `Query.sha256()` is the SHA-256 of exactly the bytes of `text`, as 64 lowercase hex digits, so `printf %s "$text" | sha256sum` reproduces it.
- `Suite.sha256()` is the SHA-256 of one line per query, in the suite's order: `<suite>/<id> <query sha256>` and a newline. An edit to a query, a reordering, a removed or an added query changes it. It does not cover the suite's title or notice.
- `Dataset.ddl()` is one `CREATE TABLE` statement per table, one column per line, tables separated by a blank line; `Dataset.sha256()` is the SHA-256 of that text.
- `tests/test_drift.mojo` writes every one of these digests down. An edit to the corpus fails the build until the pinned digest is changed in the same commit, so a change of the text a published number was measured on is deliberate and visible in review.

### TPC-H

The text is the specification's, with the parameters of its validation run (query 1 interval 90 days, query 2 size 15 and type `BRASS` in region `EUROPE`, query 3 segment `BUILDING` and date 1995-03-15, and so on to query 22's seven country codes), against the standard schema: dates are `DATE`, money is `DECIMAL(15,2)`, no column is derived. Three changes of form, none of meaning:

- query 15 reads a `with` clause where the specification creates and drops a view, so that every query is one statement;
- the row limits the specification states in prose (queries 2, 3, 10, 18, 21) are `limit` clauses;
- query 11's fraction is the specification's 0.0001 divided by the scale factor; the text holds it for scale factor 1, and `tpch_q11_at_scale(sf)` gives the text for another whole scale factor (the fraction to ten decimals, truncated).

### ClickBench

The query list is the benchmark's, numbered from 0, over the `hits` table with the logical types of the benchmark's DuckDB table (`EventDate` is a `DATE`, `EventTime` a `TIMESTAMP`, the strings are `VARCHAR`). The file `hits.parquet` stores a date as a day count and a time as an integer, and its strings as bytes: presenting the table with these names and types is the loader's business, and the dataset here says what the queries expect.

### h2o

The groupby queries read one table `x`; the join queries read `x` and one of `small`, `medium`, `big`. The benchmark names its tables per data size (`G1_1e7_1e2_0_0`, `J1_1e7_NA_0_0` and so on); this corpus names them `x`, `small`, `medium` and `big` and leaves the size to the data.

## Licence notes

This package is Apache-2.0 like the rest of komira, but the query text is not komira's own work, and each suite keeps the terms it was published under:

- **TPC-H.** TPC-H is a benchmark of the Transaction Processing Performance Council, which owns the specification and the trademark. The queries here are derived from the specification under the TPC's fair-use terms: a result produced with them must not be called a TPC-H result or compared with published TPC-H results, and must say it is derived from TPC-H. The sentence above is that statement. TPC's own tools (`dbgen`, `qgen`) are not used or included.
- **ClickBench.** ClickBench is published by ClickHouse, Inc. under the MIT licence. The query list is reproduced from it, and the copyright and permission notice of the ClickBench repository applies to that text.
- **h2o.** The h2o database-like ops benchmark is published by H2O.ai under the Mozilla Public Licence 2.0. Only query text (one statement per query) is reproduced, with the table names changed; the licence of the benchmark repository applies to that text.

Datasets are not part of the package and are never downloaded by it: each suite's data comes from its owner, under the owner's terms.

## What it does not do

- It runs nothing and reads no file: a query's text is a value, and what executes it is the caller's.
- It holds no expected results. A harness that checks answers keeps its own.
- It does not generate or download data, and names no download location.
- It does not rewrite SQL for a dialect: the text is the benchmark's, and an engine that cannot run a query says so.

## Tests

`tests/test_sha256.mojo` (the digest against the published vectors and, at every length up to 200 bytes, against `komira_crypto`), `tests/test_text.mojo` (the ids of each suite, the shape of the text, every word of every query against its dataset's names, the TPC-H parameters, the ClickBench special texts), `tests/test_api.mojo` (lookups and their refusals, the hash functions, query 11 at a scale factor, the DDL) and `tests/test_drift.mojo` (every query, suite and dataset digest pinned).
