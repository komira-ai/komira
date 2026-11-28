# Row sampling: USING SAMPLE, TABLESAMPLE, DataFrame.sample and a repeatable train/test split

Status: design, not built. **EXISTS** marks code on `main`. **PROPOSED** marks something new.
*(inferred)* marks a statement the author deduced rather than read. *(to confirm)* marks a fact the
named slice checks first. No slice is built before the owner approves this document. Tracked by
komira-ai/komira#2340, which blocks rank 64 of the
[common-tasks catalogue](../tasks/catalogue.json), "How do I sample random rows or split train and
test?".

## Questions for the owner

The rest of the document follows these recommendations. Each row is a point where komira answers
differently from DuckDB, pandas or polars, or a name komira would invent.

| # | question | DuckDB / pandas / polars | recommendation |
|---|---|---|---|
| Q1 | Does komira return DuckDB's rows for the same seed? | DuckDB's rows come from its own generator. Its docs say a seed "*only* guarantees that the sample is the same if multi-threading is not enabled". | **No.** komira promises a repeatable sample of its own: the same seed over the same data gives the same rows on every run, at every thread count, on every platform and in every later release. The user docs say so in one sentence (see [What the user sees](#what-the-user-sees)). A sample is a [departure](#7-the-departure-from-duckdb-and-the-libraries) from B21, and the departure is named. |
| Q2 | Which method does `USING SAMPLE 10%` use when the method is not named? | DuckDB uses `system` for a percentage and `reservoir` for a row count. | **`bernoulli` for a percentage, `reservoir` for a row count.** komira has no block sampling. Bernoulli sampling keeps the same expected share of rows with lower variance. A query that writes `(system)` explicitly is refused by name. |
| Q3 | Two invented names: `komira.pl.LazyFrame.sample`, and a split verb. | polars has `sample` on `DataFrame` and `Expr` but not on `LazyFrame`. Neither pandas nor polars has a split verb. scikit-learn has `train_test_split(*arrays, test_size, train_size, random_state, shuffle)`. | **Add both.** `LazyFrame.sample` takes polars `DataFrame.sample`'s exact signature. The split is `komira.train_test_split(frame, *, test_size=None, train_size=None, random_state=None)`, with scikit-learn's name and argument meanings. It takes a frame of either skin and returns `(train, test)`. The verb tables mark both as komira's verbs. |
| Q4 | Is `df.sample(frac=0.2)` an exact count? | pandas returns `round(frac * len(df))` rows. polars returns `int(fraction * height)` rows. Both counts are exact. | **Yes, exact.** It costs a sort of the whole input by sample key ([decision 5](#5-four-sizes-and-the-operators-they-become)). A bernoulli fraction, which streams, stays SQL's `PERCENT`. The frames do not get a second spelling for it. |
| Q5 | Does B21 allow this departure? | B21 allows departures from DuckDB's results "only for Arrow representation limits". | **Amend B21 in the komira section of `AGENTS.md`** to name one more departure: a sample's rows, which komira chooses by its own repeatable rule while matching DuckDB's sample size. The amendment is the owner's to make, and slice 5 does not merge before it. |

## What the user sees

The PROPOSED surface once every slice has landed:

```sql
-- about 10% of the rows of t, the same rows every time for seed 7
SELECT * FROM t USING SAMPLE 10 PERCENT (bernoulli, 7);
SELECT * FROM t USING SAMPLE 10% REPEATABLE (7);
-- exactly 100 rows (fewer if t has fewer)
SELECT * FROM t USING SAMPLE reservoir(100 ROWS) REPEATABLE (7);
-- sample one table of a join, before the join and the WHERE
SELECT * FROM orders TABLESAMPLE 5% REPEATABLE (1) JOIN customers USING (customer_id);
```

```python
import komira
from komira import pl

df = komira.read_parquet("events.parquet")
five = df.sample(n=5, random_state=7)              # exactly 5 rows
fifth = df.sample(frac=0.2, random_state=7)        # exactly round(0.2 * len) rows
train, test = komira.train_test_split(df, test_size=0.2, random_state=7)

lf = pl.scan_parquet("events.parquet")
lf.sample(n=5, seed=7).collect()
lf.sample(fraction=0.2, seed=7).collect()
train, test = komira.train_test_split(lf, test_size=0.2, random_state=7)
```

The sentence the user docs carry, word for word:

> komira's sample is repeatable: with the same seed, over the same files with the same rows in
> each, it returns the same rows on every run, with any number of threads, and in later releases.
> It does not return the rows DuckDB, pandas or polars return for that seed. Without a seed, each
> query or `sample` call picks a new seed, and `explain()` shows the seed it picked.

What does not change: `random()` and `setseed()` stay refused ([decision 8](#8-what-stays-refused)),
and so does every sample form that [Out of scope](#out-of-scope) lists, each by name.

## What exists today

All **EXISTS**, checked on `main`:

- **SQL refuses the clause by name.** `src/sql/sql_parser.mojo` `_refuse_unsupported_clause` raises
  "SQL not supported: TABLESAMPLE / USING SAMPLE (row sampling). Silently scanning every row instead
  would answer a different question, so the sample clause is refused." It runs once, at the end of
  a SELECT body. `tablesample` is in the alias stop-list (`_is_structural_kw`), so `FROM t
  TABLESAMPLE ...` reaches the refusal instead of taking the word as an alias. Tests:
  `src/sql/tests/test_sql_parser_statements.mojo` (`test_unsupported_clause_words_are_named`).
- **The plan has no sample node.** `src/plan_ir/logical_plan.mojo` declares `PLAN_SCAN` (0) to
  `PLAN_STEP` (20). Ids 16 and 17 are retired, and the file says the next tag takes id 21. The plan
  has no expression that hashes (`EXPR_*` 0 to 27 in `src/plan_expr/expr.mojo`), and no scan
  produces a row-position column.
- **The Python skins refuse it.** `python/komira/_refusals.py` holds `.sample() is not supported: it
  picks rows at random, and a plan names no random rows` for `DataFrame` and `Series`, the same
  text as the refusal table in [dataframe_surface_verbs.md](dataframe_surface_verbs.md). `komira.pl`
  has no row, so `lf.sample` raises Python's own `AttributeError`.
- **Random functions are refused.** `src/sql/sql_fn_table.mojo` refuses `random` and `setseed` with
  `_R_NONDET`: a per-row random "would produce a different column for the same query depending on
  batch size and parallelism". `uuid` and `gen_random_uuid` are refused with `_R_UUIDT`, and
  `hash` with `_R_UKEY`, because DuckDB's `hash` returns UBIGINT and its exact bits are DuckDB's.
- **What a design can build on:**
  - **TopN is the same on any worker count.** `PLAN_TOPN` is cut as `SINK_TOPN`
    (`src/pipeline_exec/sink_sort.mojo`). Each worker keeps its smallest `offset + n` rows, ties
    broken by source position, and `combine` merges them. The result equals the full sort's slice
    on any worker count.
  - **`LIMIT` is not.** It shares one atomic budget across workers (`src/pipeline_exec/op_limit.mojo`),
    so which rows survive depends on the schedule.
  - **Stable hashes and entropy exist, in part.** `src/row_format/xxh3.mojo` is an xxh3-64 scalar
    reference for row-block keys. Its header promises cross-version and cross-architecture
    stability for inputs up to 240 bytes. Its seeded entry, `_xxh3_64_dispatch(base, len, seed)`,
    is private. The public `xxh3_64_scalar_bytes` takes no seed, and the header promises seed 0
    only. A seeded public entry, with vectors for nonzero seeds, is new (slice 2). `src/hashing`
    holds `fnv1a_64`, which uses the published constants. `crypto.system_entropy`
    (`src/crypto/src/crypto/rng.mojo`) reads the operating system's random source.
  - **The plan cache sees what the render shows.** `LogicalPlan.structural_hash` is FNV-1a over the
    plan's render (`src/plan_ir/plan_display.mojo`). A field the render leaves out is merged in the
    plan-compile cache, which is a wrong answer, not a slow one.
  - **Filters do not move across unknown nodes.** The optimizer's filter, limit and projection rules
    leave a node they do not know in place and do not move a filter below it
    (`src/optimizer/optimizer_filter.mojo`, `optimizer_misc.mojo`). A node with no cutter arm fails
    at lower with `LOWERING_UNCUTTABLE_NODE`.
- **Rank 64 has no page.** `docs/tasks/catalogue.json` lists it as a `gap` naming
  komira-ai/komira#2340, and `python/docs/tasks/` has no `64-*` directory.

## The decisions

### 1. Rows are chosen by a seeded hash of a stable row identity, not by a random stream

A random stream fails for the reason `_R_NONDET` gives. Each worker draws in claim order, so the
rows a stream picks depend on the number of workers, the morsel size and the schedule. komira
instead gives every row a 64-bit **row identity** `id` that does not depend on how the work was
split. Its sample hash is then

```
H(seed, id) = xxh3_64(seed, le64(id))          (sample hash version 1)
```

`le64` is the little-endian 8-byte encoding. Two rules follow:

- **Bernoulli, share `f`:** keep a row when `H < T`, where `T = floor(f × 2^64)` is computed once
  by the plan's producer and stored in the plan as an integer (`f = 1` drops the sample, and `f =
  0` keeps no row). A row's fate depends only on its own identity, so the answer is the same
  however the rows are split. A bernoulli sample therefore commutes with any filter: filtering then
  sampling keeps the same rows as sampling then filtering.
- **Exact `n`:** keep the `n` rows with the smallest `(H, id)`, with `H` compared unsigned and `id`
  as an `Int64`. This is a TopN, and TopN already gives the same rows on any worker count. Only rows
  whose ids collide tie on both keys (decision 2). TopN then breaks the tie by source position, which
  does not depend on the schedule. So the promise holds up to id collisions, which this document
  accepts.

**The threshold.** `T` is computed exactly. A SQL percentage is a decimal literal `p = a / 10^k`,
and `T = floor(a × 2^64 / (100 × 10^k))` in 128-bit integer arithmetic. The Mojo builder in
`src/sdk` takes a percentage the same way, as a decimal string or an integer numerator and
denominator, never as a float. The frames never write `BERNOULLI` (Q4), so no Python code computes
`T`. Slice 2 holds the vectors for 10%, 12.5%, 0.1%, 0% and 100%.

**The rule is part of the format.** A plan names its `sample_version` (1). Version 1 fixes
everything that decides which rows are kept:

- the hash `H`, `mix` and `fnv1a_64`;
- the identity table of decision 2, with the scan-root rule;
- the encoding of group keys for an aggregate's identity, which is defined for this purpose and
  not borrowed from `src/row_format`, whose encoding may change;
- the outer-join constant;
- the threshold and rounding rules.

A reader refuses a version it does not know, and no release changes what version 1 means. A later
change to any of these is version 2. This is what lets a seeded plan from one release return the
same rows in every later one, as [optimized_plan.md](optimized_plan.md) §9.1 requires of every plan
("on the same pinned data it produces the result it" produced).

- Rejected: a seeded random stream per worker (the answer depends on the schedule, the objection
  `_R_NONDET` already makes).
- Rejected: a hash of the row's column values. Equal rows would share one fate, so two duplicate
  rows would always be kept or dropped together. That is not a sample of rows.
- Rejected: DuckDB's `hash()`. Its docs say "The used hash function may change across DuckDB
  versions", and komira refuses it (`_R_UKEY`).

### 2. The row identity of each relation

The identity is defined over the plan, so it is the same however the engine runs the plan. Each
rule below gives the identity of a node's output rows. "Preserves" means each output row keeps
the identity of the input row it came from. `mix(a, b) = xxh3_64(0, le64(a) ‖ le64(b))`.

| relation | identity |
|---|---|
| scan of files (Parquet, CSV, JSON lines; one file, a list, a glob, a directory, Hive partitions) | `mix(fnv1a_64(rel_path), row)`. `rel_path` is the file's path relative to the scan root (below). `row` is the 0-based position of the row in its file. **Parquet:** the rows of the earlier row groups, read from the footer, plus the offset in the row group. It is the position in the file under every skip the reader makes: row groups pruned by statistics, pages skipped by the page index, rows dropped by a filter fused into the reader. **CSV and JSON lines:** the record number, counted in file order by the reader. A header line does not count. A record the reader skips as malformed does count, so skipping one does not shift the rest. *(to confirm in slice 3: the CSV reader reads the whole file before its first morsel, and the JSON-lines reader reads whole-line chunks in order, so each can number its records serially.)* |
| scan of a resident Arrow table (`komira_register_arrow_stream`) | `mix(0, row)`, the row's position in the stream |
| Iceberg scan | `mix(fnv1a_64(rel_path), pos)`, the data file's path relative to the table location and Iceberg's own row position. Delete files remove rows but do not renumber them. *(to confirm in slice 6)* |
| filter, project, sort, limit, TopN, window (`PARTITION_BY`), partition TopN, cast-to-varchar | preserves |
| a shared subplan (`CSE_REF`) | the identity of its canonical subtree, so every reference agrees |
| inner, cross, semi, anti and as-of join | `mix(left_id, right_id)`. A semi or anti join keeps `left_id`. An as-of join matches at most one right row per left row, so it takes `mix(left_id, right_id)` the same way. |
| outer join, the side with no match | that side's id is the constant `0xFFFF_FFFF_FFFF_FFFF` |
| aggregate, distinct | `xxh3` of the group key's sample-identity encoding (defined for sample version 1, decision 1), which is unique per output row. A global aggregate's one row has `mix(0, 0)`. |
| union of branches | `mix(branch_index, id)` |
| UDF frame function (`MAP_BATCHES`), UDF source (`STEP`), an unbounded (streaming) scan, and every node kind not named in this table, now or later | none. The expansion pass refuses the sample with `SAMPLE_NO_ROW_IDENTITY`, which names the node kind (decision 9). A new node kind gets an identity row here, or it stays refused. |

**The scan root.**

- **A glob or a directory:** the root is the directory it names, the part before the first
  wildcard. Adding a file under that root adds identities and changes none.
- **An explicit list of files:** the root is the longest common directory of the list. Adding a
  file from outside that directory moves the root and changes every identity of the scan, and the
  user docs say so.
- **A single file:** `rel_path` is its file name.

So the same files read through another absolute path, from another machine, or listed in another
order give the same identities.

**Two samples in one query.** Two scans can number their rows alike, for example two single files
with the same file name. If both are sampled with the same seed, they keep the same rows, so the
two samples are correlated. Two things keep the seeds apart:

- **Unseeded samples** each get their own seed (decision 6).
- **Explicit seeds:** a user who writes the same `REPEATABLE (s)` on two tables asks for the same
  seed twice. The SQL docs say to use different seeds there.

Identities can collide, since 64 bits holds about `N² / 2^65` colliding pairs among `N` rows. Two
rows that collide share their fate. The user docs do not mention this.

- Rejected: the file's ordinal in the listing as its identity (adding a file renumbers the files
  after it).
- Rejected: the absolute path (moving the data changes the sample).
- Rejected: the morsel's `partition_id` and the row's offset in the morsel. The Parquet partition
  id is stable (`flat_row_group × 2^20 + unit`), but the offset in a morsel moves with the morsel
  size and with filters fused below the sample.

### 3. One plan node, expanded by the optimizer into nodes that exist

**PROPOSED:** `PLAN_SAMPLE`, a single-child node with payload `SampleData`. It takes the next free
engine tag and `PlanTag` when its slice lands. The numbers are not fixed here.
[optimized_plan_sources.md](optimized_plan_sources.md) already reserves engine tags 21 and 22 (wire
22 and 23) for index lookup and expand, and expr tag 28 for vector distance. So if those land first,
the sample takes engine tag 23 (`PlanTag` 24), and its expression takes expr tag 29.

| field | meaning |
|---|---|
| `size` | one of `ROWS(n)`, `BERNOULLI(threshold)`, `FRACTION_EXACT(fraction, rounding)` (decision 5) |
| `seed` | `UInt64`, always set: an unseeded sample is given a seed by its producer (decision 6) |
| `sample_version` | 1 (decision 1) |
| `complement` | keep the rows the sample drops (the test half of a split). For `ROWS(n)`, that means every row from rank `n` on: a sort of the whole input, not a TopN. |
| `fail_if_short` | for `ROWS(n)`: raise at run time when the input has fewer than `n` rows (the frames); otherwise return them all (SQL) |

Producers (the SQL binder, both Python skins, the Mojo builder in `src/sdk`) write only this node.
A new optimizer pass, `expand_row_samples`, runs as the first step of the optimizer driver
(`src/optimizer/optimizer_driver.mojo`). That is after the caller's `view_resolution_pass` and before
step 1 (`partition_prune_scans`), and the driver's order comment gains the step. The pass rewrites
each `PLAN_SAMPLE` into nodes the engine already runs:

1. It asks each scan below the sample for its row-identity column. This is a new optional `ScanData`
   field, `row_id`, which carries a column name the pass picks so that it clashes with no column of
   the schema.
2. Through each node between the scan and the sample, it carries or builds the identity by
   decision 2's table, adding a projection of `mix(...)` above a join.
3. It replaces the sample:
   - `BERNOULLI` becomes `FILTER(row_sample_keep(seed, T, id))`, or `NOT` of it for the complement.
   - `ROWS(n)` becomes `TOPN([row_sample_key(seed, id), id], n)`. Its complement is the rows from
     `n` on.
   - `FRACTION_EXACT` becomes `SORT([row_sample_key(seed, id), id])` under a count-relative range
     (decision 5).
4. It adds a projection on top that drops the helper columns.

`row_sample_keep` and `row_sample_key` are the two ops of one **PROPOSED** expression kind,
`EXPR_ROW_SAMPLE`. `row_sample_key` returns `H xor 2^63` as `Int64`, so signed order
is `H`'s unsigned order and no unsigned column type is needed. The kind also has a third op, `mix`.

After the expansion, the other rules see a filter or a TopN, and they are already right:

- **A bernoulli filter.** Filter pushdown may move other predicates below it or past it, which is
  correct because the sample commutes with filters (decision 1). The predicate cannot be pushed
  into a Parquet reader, so it stays a fused filter above the scan.
- **A TopN.** No filter moves below it, and that is the semantics an exact `n` needs.
- **Lowering never sees `PLAN_SAMPLE`.** It follows the rule `PLAN_VIEW_REF` follows: a sample node
  that reaches the cutter is a bug, refused as `LOWERING_UNCUTTABLE_NODE`.

The node, not a desugar in each producer, is the choice because the identity rules of decision 2
then live in one place, the Mojo pass. If each producer desugared, the binder and both skins would
each carry the identity rules for joins and aggregates, and they could drift apart. A desugar also
loses the user's words in `explain`. The node renders as `Sample(bernoulli 10%, seed=7)` in the
logical plan, and the optimized plan shows the filter or TopN it became.

**The wire, additive only (B8):**

- **The RAW plan.** `WirePlan` gains the arm `sample`, field 25. Fields 23 and 24 are held for
  `index_lookup` and `expand` (optimized_plan.md §5.2). `PlanTag.SAMPLE` is added (its number as above), and so is a
  `WireSampleNode` message.
- **The OPTIMIZED plan.** It never carries the node. It carries the expansion: the `EXPR_ROW_SAMPLE`
  arm, the scan's `row_id` field and the count-relative range. These are new fields under a new
  `format_version` (§9.2), which slice 2 adds with the first of them. The RAW plan refuses all three
  by name. A producer therefore has one way
  to write a sample, and a plan that does not sample keeps its older `format_version`.

- Rejected: a desugar in each producer, onto a filter of a seeded hash and then a TopN. That needs
  the same expression kind and scan field, and it puts the identity rules in three places.
- Rejected: an engine operator with its own sink. Bernoulli fuses as a filter and exact `n` reuses
  `SINK_TOPN`, which is already deterministic. A new sink would repeat that work.
- Rejected: optional sample fields on `WireScanNode`. That covers `TABLESAMPLE` on a table but not
  `USING SAMPLE` after a join, nor a frame sampled after a filter.

### 4. Where the sample runs

- **`TABLESAMPLE`** follows one table expression in `FROM`: a table, a table function, or a derived
  table with its alias. It samples that relation before joins and `WHERE`, as in DuckDB and
  PostgreSQL. DuckDB's docs call it "essentially equivalent to creating a subquery with the `USING
  SAMPLE` clause", and the binder builds exactly that.
- **`USING SAMPLE`** comes at the end of the SELECT body. It samples "the result of the entire FROM
  clause, after all joins have been resolved" (DuckDB's docs). komira places it above the joins and
  below `WHERE`, `GROUP BY`, window functions, `ORDER BY` and `LIMIT`. *(to confirm in slice 5:
  the DuckDB page says nothing about `WHERE`, so the slice first measures DuckDB on a query whose
  row count depends on the order, and keeps that query as a conformance test.)* For bernoulli the order does not change the rows (decision 1). For an exact `n` it
  does, and the TopN keeps it.
- **In the frames,** the sample applies where the verb stands in the chain:
  `df[df.x > 0].sample(n=5)` samples the filtered rows. The row-order rule of
  [dataframe_surface.md](dataframe_surface.md) §7 carries over. A sample of an ordered frame is
  placed below its sort, so the frame stays ordered, as a filter does. A sample of an unordered
  frame promises no order.

### 5. Four sizes and the operators they become

| spelling | size | rows returned | operator after expansion | memory |
|---|---|---|---|---|
| SQL `p PERCENT`, `p%`, `bernoulli(p%)` | `BERNOULLI` | each row kept with chance `p/100`; about `p/100 × N` | fused filter | none |
| SQL `n ROWS`, a bare `n`, `reservoir(n ROWS)`; `df.sample(n=)`; `lf.sample(n=)` | `ROWS(n)` | exactly `min(n, N)` (SQL); exactly `n` or an error (frames) | `SINK_TOPN`; its complement is a sort | `n` rows per worker; the complement, the whole input |
| `df.sample(frac=)`, `lf.sample(fraction=)` | `FRACTION_EXACT` | exactly `round(f × N)` (pandas: Python's `round`, half to even), `floor(f × N)` (polars) *(to confirm against the pinned pandas 3.0.6 and polars 1.44.2 in slice 7)* | `SINK_SORT` with a range set at `combine` | the whole input, spilled as a sort spills |
| `train_test_split(test_size=t)` | `FRACTION_EXACT`, the split's own rounding | test `ceil(t × N)`, train the rest (scikit-learn's sizes) | as above | as above |
| SQL `reservoir(p%)` | `FRACTION_EXACT` with SQL's rounding (`round`, half away from zero) | exactly that share | as above | as above |

**The rounding is exact.** The fraction is carried in the plan as the IEEE double the user gave.
For pandas, `f × N` is the double product with `N` converted to a double, and it is then rounded
half to even, as Python computes `round(frac * n)`. polars truncates the same product. The SQL
percentage is carried as its decimal literal and rounded in integer arithmetic. The engine applies
the rule the plan names, so the skins never compute `N`.

**The count-relative range.** `FRACTION_EXACT` needs the input's count `N`, which is known only when
the sort's `combine` has every row. So **PROPOSED** `LimitData` gains an optional field
`count_relative`. Its start and end are each a fixed count, `fraction × N` under a named rounding,
or `N`. It is cut only over a sort, as a `SINK_SORT` range resolved at `combine`, and it is admitted
only in the OPTIMIZED plan.

**The split.** `train_test_split(test_size=t)` builds two plans over the same sort of sample keys:

- train is the range `[0, N − ceil(t × N))`;
- test is the range `[N − ceil(t × N), N)`.

So over the same data, the halves are disjoint and together hold every row, whatever `N` is. The
two plans run separately, so the promise holds only while the files do not change between the two
runs. The arguments follow scikit-learn:

- With neither `test_size` nor `train_size` given, `test_size` is 0.25.
- A float is a share in `(0, 1)`.
- An `int` is a count of rows, the end of the range taken as a fixed count.
- With only `train_size` given, train is `floor(train_size × N)` rows, and test is the rest.
- `shuffle=False` and `stratify=` are refused with `UnsupportedOperation`. A plan has no first rows
  to split off, and stratified sampling is out of scope.

A SQL percentage with no method named, or with `bernoulli`, is bernoulli (Q2). DuckDB's
`reservoir(10%)` is an exact share, so it maps to `FRACTION_EXACT`.

### 6. Seeds, unseeded samples and the plan cache

- **The seed is always in the plan.** It is rendered by `plan_display`, so it is part of
  `structural_hash` and of the plan-compile cache key. Two samples that differ only in seed never
  share a cache entry, and the same seed over the same plan does. It is also in the OPTIMIZED
  plan's canonical body and digest.
- **An unseeded sample gets its seed from its producer**, at the moment the user asks for it:
  - **SQL:** for each `sql()` call whose statement holds an unseeded sample, the session draws 64
    bits with `crypto.system_entropy` and hands them to the binder as an input, the statement seed.
    The binder stays pure (no entropy, clock or environment), and a test hands it a fixed value.
    Each unseeded sample clause gets `mix(statement_seed, clause_index)`, where `clause_index` is the
    clause's position in the statement text, so two unseeded samples in one statement are
    independent. A CTE is one relation, so a CTE referenced twice is one clause and gives the same
    rows at both references. Each unseeded statement is a new plan, so it never hits the
    plan-compile cache, and the SQL docs say so. A statement with no unseeded sample draws nothing.
  - **pandas skin:** `df.sample(n=5)` draws its seed when it is called, as pandas draws its rows
    when called. `s = df.sample(5)` is then one fixed sample, and `s.materialize()` twice returns
    the same rows. A second `df.sample(5)` draws again.
  - **polars skin:** `lf.sample(n=5)` behaves the same, drawing when it is called.
- **`explain()` shows the seed** in both skins and in SQL, so any sample can be repeated.
- **Seed ranges.** SQL accepts a non-negative BIGINT, in `REPEATABLE (s)` or `(method, s)`. The
  skins accept an `int` from 0 to `2**64 - 1`. Anything else is refused (decision 9).
- **Why the seed is fixed in the plan, and not drawn when the plan runs.** optimized_plan.md §9.1
  promises the same result for the same plan on the same pinned data. A seed drawn at run time would
  break that promise. `_R_UUIDT` makes the same objection to a random value folded at bind time,
  because the plan would claim to be one query while its answer kept changing. Here the seed is
  part of the plan's identity, so the cache key is honest.

### 7. The departure from DuckDB and the libraries

B21 asks that query results equal DuckDB's for the same SQL. A seeded sample cannot meet that,
because DuckDB's rows come from its own generator and are not repeatable across threads even in
DuckDB. B21 lists no such departure today, so it needs the owner's amendment first (Q5). The
semantics documents ([query_semantics.md](query_semantics.md), as a new section, in slice 5) then
state the departure:

- **What komira promises:** the size, the subset (every sampled row is a row of the input), and
  repeatability. The repeatability is over the same seed and the same files, and it holds across
  runs, thread counts, platforms and later releases.
- **What komira does not promise:** that the rows are DuckDB's.

[dataframe_surface.md](dataframe_surface.md) §8 gets a ruling, marked **differs**, saying the same
for pandas `random_state` and polars `seed`. This is the "departure that section 8 lists" which §6's
no-near-miss rule allows. The conformance tests compare with DuckDB only what DuckDB fixes: the
count of a `reservoir(n ROWS)` sample and that the result is a subset of the input.

### 8. What stays refused

- **`random()` and `setseed()`** stay refused, and `_R_NONDET`'s reasoning still holds. A sample
  does not need them, and a `WHERE random() < 0.1` filter would have no repeatable answer. The
  refusal text gains one sentence pointing to `USING SAMPLE ... REPEATABLE`.
- **`hash()`** stays refused (`_R_UKEY`). `row_sample_key` is not a SQL function, so the plan
  gains no second way to sample.

### 9. Refusals and errors, each by name

**SQL**, with the `SQL not supported:` prefix (`src/sql/README.md`):

- `SYSTEM` or `system(...)`: "komira has no block sampling; write `bernoulli` for a share of
  rows".
- A sample over a relation with no identity in decision 2's table (a UDF frame function or source,
  an unbounded scan, or a node kind the table does not name): `SAMPLE_NO_ROW_IDENTITY`, naming the
  node kind, with the sentence "these rows have no stable identity to sample". The same code reaches
  the frames at the terminal.
- `TABLESAMPLE` on a `LATERAL` item, which is already refused.
- More than one `USING SAMPLE` in one SELECT body.

**SQL syntax errors** (`SQL syntax error`): a percentage outside `[0, 100]`, a negative row count,
and a seed that is negative or does not fit in a BIGINT.

**Python, at the call** (dataframe_surface.md §6):

| call | what it raises |
|---|---|
| `n` and `frac` both given | `ValueError`, pandas' own message |
| `frac > 1` without `replace` | `ValueError`, pandas' own message |
| `replace=True`, `with_replacement=True` | `UnsupportedOperation` |
| `weights=` | `UnsupportedOperation` |
| `random_state=` a `Generator`, `RandomState` or array | `UnsupportedOperation`, saying to pass an `int` |
| `axis=1` | `UnsupportedOperation` |
| polars `shuffle=True` | `UnsupportedOperation`, saying "a plan has no random row order; sort the sample" |
| `train_test_split` with `shuffle=False` or `stratify=` | `UnsupportedOperation` |

`shuffle=None` and `shuffle=False` are accepted. False keeps an ordered frame ordered (decision 4).
pandas `ignore_index` is accepted and does nothing, as `sort_values` does, since a frame has no
index. `n` defaults to 1 when neither `n` nor `frac` is given, as both libraries do.

**At the terminal:** a frame's `n` larger than the input raises `KomiraError` with code
`SAMPLE_LARGER_THAN_INPUT`. pandas raises this at the call, but komira does not know the count
before the plan runs. The ruling of decision 7 lists the difference.

## Out of scope

- Sampling with replacement, weighted sampling, and stratified or per-group sampling.
- `SYSTEM` (block) sampling, and returning DuckDB's rows (Q1, Q2).
- A random row order (`shuffle=True`, `ORDER BY random()`), `random()` and `setseed()`.
- A train/test split in SQL. SQL has no spelling for "the rows a sample drops", and the frames' split
  covers the task. DuckDB users write `WHERE hash(id) % 10 < 8`, which stays refused with `hash`.
- Sampling an unbounded (streaming) scan.
- Estimators that scale a sample's aggregates up to the whole table.
- The other surfaces of the capability matrix (`mojo_polars`, `ts_polars`, Excel). Each can later
  write the same node without changing this design.

## What must always hold?

- **Repeatability.** For a plan with seed `s`, over the same files with the same rows in each, the
  sampled rows are the same on every run, at every worker count and morsel size, on every release
  platform, and in every later release.
- **The size is exact where the spelling says so.** `ROWS(n)` returns `min(n, N)` rows, and
  `FRACTION_EXACT` returns `g(N)` rows, where `g` is the rounding rule the plan names (decision 5).
- **A sample is a subset of its input.** As a multiset, every sampled row is a row of the input.
- **A sample and its complement split the input.** With the same seed and size, a sample and its
  complement are disjoint and together hold every input row.
- **A bernoulli sample commutes with a filter.** `Sample(Filter(X))` and `Filter(Sample(X))` keep
  the same rows, because a filter preserves identity.
- **The seed is in the render.** Plans that differ only in seed have different `structural_hash`
  values.
- **The engine never sees the node.** No `PLAN_SAMPLE` reaches lowering, and no RAW plan carries
  `EXPR_ROW_SAMPLE`, `row_id` or `count_relative`.
- **A sample with no row identity is refused by name.** It never runs over rows in the order they
  happened to arrive.

## How is it tested?

No test draws a random number. Seeds are fixed, an unseeded sample gets its seed from an entropy
source that the test injects, and every check is one of:

1. **Known-answer vectors.**
   - **The hash.** `H`, `mix` and `fnv1a_64` on fixed inputs, held to xxHash's and FNV's published
     vectors.
   - **The recorded results.** For seeds 0, 7 and `2**64 - 1`, over a 1000-row fixture, the ids that
     `BERNOULLI(10%)`, `ROWS(10)` and `FRACTION_EXACT(0.2)` keep are written in the test.
   - **What changing the hash costs.** Changing the hash's bits fails these recorded results, and
     the golden corpus of optimized_plan.md §9.4 then holds them across releases.
2. **Properties on fixed seeds.** Each holds for every seed in a fixed list of 32:
   - exact `n`, and the exact count of each rounding rule;
   - the result is a subset of the input;
   - a sample and its complement are disjoint and together hold the input;
   - bernoulli commutes with a filter.
3. **The same rows however the work is split.** The same plan is run:
   - with 1, 2 and 8 workers, and with three morsel sizes;
   - with a Parquet file written as 1 and as 7 row groups;
   - with row groups pruned by a filter, and pages skipped by the page index;
   - with a malformed CSV record skipped;
   - with the files of a glob listed in two orders. The sampled ids are compared for
   equality. These tests run on the farm like every welded test, and they assert no timing (T10).
4. **Boundary cases:**
   - **Sizes:** `n = 0`; `n = N`; `n > N` (SQL returns every row, and the frames raise
     `SAMPLE_LARGER_THAN_INPUT`); `0%`; `100%`.
   - **Inputs:** an empty input; one row; duplicate rows, which are sampled independently; rows
     that are all NULL.
   - **Seeds:** 0 and `2**64 - 1`.
   - **Joins:** an outer join's unmatched rows.
5. **Refusals,** each by its full message (T13), every row of decision 9. There is one
   `SAMPLE_NO_ROW_IDENTITY` test for each node kind that has no identity, and a census test fails
   when a plan tag has neither an identity row nor a refusal.
6. **Plan identity:**
   - **The seed changes the hash.** Two samples that differ only in seed have different
     `structural_hash` values. This is the shape of `test_same_name_different_params_do_not_share_a_plan_cache_key`.
   - **Each unseeded draw is new.** Two unseeded SQL statements, with entropy injected as two
     different values, give two plans, and `explain` shows each seed.
   - **The wire round trips.** RAW and OPTIMIZED both round trip, and RAW refuses the three
     expansion fields.
7. **Compatibility (B8).** Slice 2, which adds the new `format_version`, names both tests in its
   pull request. Slices 3, 4 and 7, which add a field under that version, extend them:
   - **The new release on old data.** The golden corpus of optimized_plan.md §9.4 holds plans that
     earlier releases emitted, and every one still decodes and runs to its recorded output, since
     none uses the new fields.
   - **The previous release on new data.** A sample plan carries the new `format_version`, so a
     reader of the previous version refuses it with `OPTIMIZED_PLAN_VERSION_UNSUPPORTED` (§9.5). The
     test runs the reader's version check with the previous release's admitted set, held in the
     test. Running the previous release's binary is not done, because T12 forbids fetching it.
   - **The seeded sample plans join the corpus.** That holds their rows in every later release.
8. **The task page.** `//python/docs/tasks:64-sample-random-rows-split-train-test` runs `example.py`
   from the installed wheel and compares its output byte for byte. The output is fixed because
   every sample in it is seeded.

These cases cover each input of the node: each size, each seed range, an empty, short or exact
input, duplicates and NULLs. They cover each relation of decision 2's table, and each way the work
can be split (workers, morsels, row groups, file order). Those are the only inputs that decide
which rows are kept.

## Order of work

Each slice is one pull request. It lands on `main` in this order. Each slice that changes behaviour
starts with tests that fail on `main` and pass after it. Only slice 10 changes the catalogue.

1. **Move xxh3 to `hashing`** (`row_format`, `hashing`):
   - A move with no change in behaviour, so that an expression kernel does not depend on the row
     format *(to confirm the layering in the slice)*. Its existing tests move with it and stay green.
2. **The hash and `EXPR_ROW_SAMPLE`** (`hashing`, `plan_expr`, `plan_proto`, `plan_wire`):
   - A public seeded xxh3 entry, `H`, `mix`, the threshold rule, and the keep and key ops.
   - The expression kind with its render, its evaluation, and its OPTIMIZED-only wire arm.
   - Fails first: the known-answer vectors (nonzero seeds included), the threshold vectors, the
     render-in-hash test, and RAW refusing the arm.
3. **Row identity at the scans** (`plan_ir`, `parquet_scan`, `op_sources`, `pipeline_exec`,
   `plan_wire`):
   - `ScanData.row_id` for Parquet, CSV, JSON lines and resident tables, and the scan-root rule.
   - Fails first: the ids are equal across worker counts, morsel sizes, row-group layouts, pruned
     row groups, skipped pages, a skipped malformed record and file order.
4. **`PLAN_SAMPLE` and `expand_row_samples`** for chains of scans, filters and projections, with
   `BERNOULLI` and `ROWS` (`plan_ir`, `optimizer`, `plan_proto`, `plan_wire`, `sdk`, `tests`):
   - The node, its wire arm and its census rows.
   - The Mojo builder `sample(...)`.
   - The `sample` row of `tests/surface_capability_matrix.bzl`.
   - A sample over a join or an aggregate is refused with `SAMPLE_NO_ROW_IDENTITY` until slice 6.
   - Fails first: the properties on fixed seeds, the same rows on any worker count end to end
     through `run_plan`, the identity census, and the seeded sample plans added to
     the golden corpus ([How is it tested?](#how-is-it-tested) item 7).
5. **SQL `USING SAMPLE` and `TABLESAMPLE`** (`sql`, the libkomira session). It merges only after
   the owner's B21 amendment (Q5):
   - The grammar of decision 4 for `bernoulli` and `reservoir(n ROWS)`, in both seed forms.
     `reservoir(p%)` is refused by name until slice 7.
   - The `system` refusal, the seed input to the binder, and the session's draw.
   - The query_semantics section and the `_R_NONDET` sentence.
   - The check of where DuckDB applies `USING SAMPLE` relative to WHERE.
   - Fails first: parser and binder tests, conformance tests on the count and the subset, and the
     refusal messages.
6. **Identity through joins, aggregates, distinct, union and Iceberg** (`optimizer`):
   - The remaining rows of decision 2's table.
   - Fails first: `USING SAMPLE` after a join, and a sample of a `GROUP BY` result.
7. **`FRACTION_EXACT` and the count-relative range** (`plan_ir`, `lowering`, `pipeline_exec`,
   `plan_wire`):
   - Fails first: exact counts for pandas', polars', SQL's and the split's rounding, including the
     ties at one half, and the two ranges of a split hold the input between them.
   - SQL `reservoir(p%)` is admitted. RAW refuses `count_relative`.
8. **`DataFrame.sample` and `komira.pl` `LazyFrame.sample`** (`python`):
   - Removes the refusal row from `_refusals.py` and from dataframe_surface_verbs.md.
   - Adds the verb rows, the §8 ruling, and the pages `python/docs/dataframe/sample.md` and
     `python/docs/pl/frames.md`.
   - Fails first: node-structure tests, bytes equal to the Mojo builder's, the refusals of
     decision 9, `SAMPLE_LARGER_THAN_INPUT` at the terminal, and end-to-end tests against the
     pinned libraries on count and subset.
9. **`komira.train_test_split`** (`python`), under the name the owner rules (Q3):
   - Fails first: the halves are disjoint and together hold the input, the sizes match
     scikit-learn's for float, `int` and default sizes, the refusals of `shuffle=False` and
     `stratify=`, and both skins give equal bytes.
10. **The catalogue task, rank 64** (`python/docs/tasks`, `docs/tasks`):
   - `python/docs/tasks/64-sample-random-rows-split-train-test/` with `example.py`,
     `expected_output.txt` and `page.md`, using the include markers of
     [docs/tasks/README.md](../tasks/README.md).
   - The example shows SQL `USING SAMPLE` with `REPEATABLE`, `df.sample(n=, random_state=)`,
     `lf.sample(fraction=, seed=)` and `train_test_split`, each seeded, and it prints sorted rows.
   - The rank 64 entry of `catalogue.json` becomes `works` and drops its `issues`.
   - Fails first: the `//python/docs/tasks:64-sample-random-rows-split-train-test` target and
     `//python/docs/tasks:pages`.

Slice 2 needs slice 1. Slice 3 is independent of both. Slice 4 needs slices 2 and 3. Slices 5, 6
and 7 need slice 4. Slice 8 needs slices 4 and 7. Slice 9 needs slice 8. Slice 10 needs slices 5, 8
and 9.

## What are the limits and open questions?

- **The sample is only as stable as the files.** Rewriting a file with its rows in another order
  changes the sample, and so does renaming a file below the scan root. Rewriting a file with the
  same rows in the same order and another row-group layout does not.
- **An exact fraction costs a sort of the whole input.** `FRACTION_EXACT` sorts every row by its
  sample key. A bernoulli share in SQL streams with no memory.
- **The DuckDB check comes first in slice 5.** Whether DuckDB samples before or after `WHERE` is
  measured at the start of slice 5 (decision 4). If DuckDB samples after `WHERE`, `USING SAMPLE`
  moves above the filter, which changes only the exact-`n` form.

## Where is the code?

| what | where |
|---|---|
| the SQL refusal today | `src/sql/sql_parser.mojo` (`_refuse_unsupported_clause`, `_is_structural_kw`) |
| `random`, `setseed`, `hash`, `uuid` refusals | `src/sql/sql_fn_table.mojo` (`_R_NONDET`, `_R_UKEY`, `_R_UUIDT`) |
| plan tags, the render that is the cache key | `src/plan_ir/logical_plan.mojo`, `src/plan_ir/plan_display.mojo` |
| TopN and the sort sink | `src/pipeline_exec/sink_sort.mojo`, `src/op_sort/` |
| the Python refusal today | `python/komira/_refusals.py`, [dataframe_surface_verbs.md](dataframe_surface_verbs.md) |
| the hashes and entropy | `src/row_format/xxh3.mojo`, `src/hashing/`, `src/crypto/src/crypto/rng.mojo` |
| the task framework | [docs/tasks/README.md](../tasks/README.md), `python/docs/tasks/BUCK` |
