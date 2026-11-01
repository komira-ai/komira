# komira_bench_corpus

The SQL of two published benchmark suites, as Mojo data, with a content hash of every query and of every suite, so that two people who say "TPC-H query 5" or "h2o groupby q3" can show they ran the same text. It holds no data, no engine and no harness: a harness imports it, asks for a suite, and runs each query's text.

**ClickBench is not shipped here.** Its query text is published under CC BY-NC-SA 4.0, so komira will not carry it. It will be fetched at run time from `ClickHouse/ClickBench`, pinned by commit and sha256 and refused on a mismatch. That is separate work and is not part of this package yet.

The TPC-H suite follows the TPC-H specification. Its fair-use statement is: **"derived from TPC-H; not comparable to published TPC-H results"**. No number made with it is called a TPC-H result. A report of this suite carries that sentence (`Suite.notice`).

| suite | queries | dataset | text |
|---|---|---|---|
| `tpch` | `q1` .. `q22` | `tpch`: the eight TPC-H tables, 61 columns, with the types of the specification (`DECIMAL(15,2)`, `DATE`) | the specification's text with the validation-run parameters |
| `h2o` | `q1` .. `q10` (groupby), `j1` .. `j5` (join) | `h2o_groupby`: table `x`; `h2o_join`: tables `x`, `small`, `medium`, `big` | the benchmark's DuckDB script, with the table name `x` |

```mojo
from komira_bench_corpus import (
    DATASET_H2O_JOIN,
    DATASET_TPCH,
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
assert_equal(len(ids), 2)
assert_equal(ids[0], SUITE_TPCH)
assert_equal(ids[1], SUITE_H2O)
var all_suites = suites()
assert_equal(len(all_suites[0].queries), 22)
assert_equal(len(all_suites[1].queries), 15)

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
assert_equal(tpch.notice, "derived from TPC-H; not comparable to published TPC-H results")
assert_equal(tpch.title, "TPC-H, 22 queries, validation parameters")

# The dataset a suite expects: tables, columns and types, as DDL.
assert_equal(len(dataset_names()), 3)
var x = dataset("h2o_groupby")
assert_equal(x.table("x").columns[0].name, "id1")
assert_equal(x.sha256().byte_length(), 64)

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

Against the DuckDB copy of the specification's queries (`extension/tpch/dbgen/queries`, the text that DuckDB's `tpch` extension ships), nine queries differ in more than layout, because DuckDB folds the date arithmetic into literals: q1 (`date '1998-12-01' - interval '90' day` for `date '1998-09-02'`), q4, q5, q6, q10, q12, q14, q15 and q20 (`date 'D' + interval 'N' month|year` for the folded end date); q6 also writes `0.06 - 0.01` and `0.06 + 0.01` where DuckDB writes `0.05` and `0.07`. q15 also names its `with` clause `revenue0` (the specification's view name) and groups by `l_suppkey` where DuckDB names it `revenue` and groups by the alias. Every folded date was recomputed and agrees. The other queries (q2, q3, q7, q8, q9, q11, q13, q16 to q19, q21, q22) differ from that copy only in letter case and the placement of spaces and line breaks.

Query 1 is the specification's with the interval written `interval '90' day` where the specification writes `day (3)` (the precision of the interval field is dropped).

### h2o

The groupby queries read one table `x`; the join queries read `x` and one of `small`, `medium`, `big`. The benchmark names its tables per data size (`G1_1e7_1e2_0_0`, `J1_1e7_NA_0_0` and so on); this corpus names them `x`, `small`, `medium` and `big` and leaves the size to the data. Against the upstream DuckDB script (which writes its keywords in capitals) seven queries differ in form only, and the hashes pin these bytes: q6 writes `median(v3)` where the script writes `quantile_cont(v3, 0.5)` (the same function); q7 writes `max(v1) - min(v2)` where the script writes `max(v1)-min(v2)` (spaces around the minus); q8 is laid out on several lines and names its subquery with `as sub_query` where the script writes `sub_query`; and j1, j2, j4 and j5 write `inner join` where the script writes `join` (the same join). Every query also writes its keywords in lower case.

### Checked against the sources

Every query was compared mechanically with the upstream file named above after normalising whitespace (and, for TPC-H, the date arithmetic that the DuckDB copy of the specification's queries folds into literals; every folded date was recomputed and agrees). The only differences are the ones this section lists. The h2o column types match the data generators.

## Cost of a lookup

`suites()`, `suite()` and `find_query()` build the queries on each call and copy the text; a lookup copies the matching `Query`. For 80 short statements that is cheap, but a harness that loops over every key should call `suites()` once and walk the result instead of calling `find_query()` per key.

## The digest

`sha256.mojo` is a small SHA-256 inside the package, on purpose: the package has no dependencies, so a harness can take it without taking `komira_crypto`. `tests/test_sha256.mojo` checks it against the published vectors and, at every length up to 200 bytes and at 100 000 bytes, against `komira_crypto`.

## TPC notice

The TPC-H queries (`tpch.mojo`) are copied from the TPC Benchmark(TM) H Standard Specification, Revision 3.0.1, dated 28 April 2022. Copyright (c) 1993 - 2022 Transaction Processing Performance Council. TPC Benchmark, TPC-H, QppH, QthH and QphH are trademarks of the Transaction Processing Performance Council. This copying is by permission of the Transaction Processing Performance Council. The wording is that of the specification's cover page (the copyright line, the title, the revision) and of its legal notice on page 4 (the trademark sentence and the condition that the copyright notice, the title and the date appear and that notice is given that copying is by permission of the TPC); the revision date is from the specification's change log.

## Licence notes

This package is Apache-2.0 like the rest of komira, but the query text is not komira's own work, and each suite keeps the terms it was published under. The terms below were read from the upstream sources (the TPC-H specification revision 3.0.1, and the `LICENSE` file at the root of each benchmark repository):

- **TPC-H.** TPC-H is a benchmark of the Transaction Processing Performance Council, which owns the specification and the trademarks (TPC Benchmark, TPC-H, QphH). The specification's copyright statement grants permission to copy and distribute its material to any party without fee when the primary purpose is to disseminate TPC material, the TPC copyright notice, the title of the publication and its date appear, and notice is given that copying is by permission of the TPC; it asks for the TPC's written permission to incorporate TPC material in a non-TPC document. The queries here are the specification's queries (TPC Benchmark H Standard Specification, Revision 3.0.1) with the validation-run parameters. A result produced with them must not be called a TPC-H result or compared with published TPC-H results, and must say it is derived from TPC-H; the fair-use sentence above ("derived from TPC-H; not comparable to published TPC-H results") is that statement. TPC's own tools (`dbgen`, `qgen`) are not used or included.
- **ClickBench.** Not shipped. The benchmark's `LICENSE` is CC BY-NC-SA 4.0 (non-commercial, share-alike); its text will be fetched at run time from `ClickHouse/ClickBench`, pinned by commit and sha256 and refused on a mismatch, instead of being copied here.
- **h2o.** The h2o database-like ops benchmark is published by H2O.ai (repository `h2oai/db-benchmark`) under the Mozilla Public License 2.0 (`LICENSE` file at the repository root). The groupby and join query text is reproduced from its `duckdb/groupby-duckdb.R` and `duckdb/join-duckdb.R`, with the table names changed, and `h2o.mojo` is therefore offered under the MPL-2.0 for that text (its header carries the MPL notice). The column types come from the benchmark's data generators `_data/groupby-datagen.R` and `_data/join-datagen.R`.

Datasets are not part of the package and are never downloaded by it: each suite's data comes from its owner, under the owner's terms.

## What it does not do

- It runs nothing and reads no file: a query's text is a value, and what executes it is the caller's.
- It holds no expected results. A harness that checks answers keeps its own.
- It does not generate or download data, and names no download location.
- It does not rewrite SQL for a dialect: the text is the benchmark's, and an engine that cannot run a query says so.

## Tests

`tests/test_sha256.mojo` (the digest against the published vectors and, at every length up to 200 bytes, against `komira_crypto`), `tests/test_text.mojo` (the ids of each suite, the shape of the text, every word of every query against its dataset's names, the TPC-H parameters), `tests/test_api.mojo` (lookups and their refusals, the hash functions, query 11 at a scale factor, the DDL) and `tests/test_drift.mojo` (every query, suite and dataset digest pinned; suite pins are keyed `suite/<id>` and dataset pins `dataset/<name>` because a suite and a dataset are both called `tpch`).
