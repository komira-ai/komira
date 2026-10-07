# Surface capability matrix

komira is reached through surfaces: the pandas-shaped and polars-shaped
frontends, SQL, the polars-shaped Mojo and TypeScript APIs, and Excel. Its
**product coverage** is every capability of the plan exercised through every
surface by an end-to-end test of that surface, checked against an independent
oracle. The **surface capability matrix** tracks it: one cell per
(surface, capability), filled by the test target that exercises the
capability through that surface. The goal is every cell filled: **100%**.
It is not line or branch coverage, which are separate metrics, and it is not
[README API coverage](readme_api_coverage.md), which counts public symbols.

The lint is [`surface_capability_matrix`](../tools/build/lint/surface_capability_matrix.bzl)
(its action, [`surface_capability_matrix.sh`](../tools/build/lint/surface_capability_matrix.sh),
states the same rules), declared once in the root [`BUCK`](../BUCK) as
`//:surface_capability_matrix`. Its ledger is
[`tests/surface_capability_matrix.bzl`](../tests/surface_capability_matrix.bzl).
It is a validation that runs on the farm like the other lints; its tests are
[test 53](../tools/build/tests/lint_tests.md#53-the-surface-capability-matrix).

```sh
./buck2 build //:surface_capability_matrix                               # the census; fails only on a malformed or lying ledger
./buck2 build '//:surface_capability_matrix[report]' --show-full-output   # the human summary
./buck2 build '//:surface_capability_matrix[matrix]' --show-full-output   # one TSV row per cell
```

## The ledger

[`tests/surface_capability_matrix.bzl`](../tests/surface_capability_matrix.bzl)
holds four lists:

- `SURFACES`: `pandas`, `polars`, `sql`, `mojo_polars`, `ts_polars`, `excel`.
- `CAPABILITIES`: `(name, grounding, meaning)`, the vocabulary, named by
  meaning in the plan (below).
- `NOT_CAPABILITIES`: `(identifiers, reason)`, the plan constants of the
  grounding families that are no capability, each with why.
- `MATRIX`: `(surface, capability, test target, note)`, one row per pair. The
  target is a label (`komira//src/tests/e2e/<surface>_e2e:<name>`) or `-`
  when no test exercises the capability yet.

The ledger is Starlark, not a TSV, so the build graph resolves every target a
row names: the macro makes each one a dependency of the lint, so a target that
does not exist fails the build before any action runs. A rule cannot read a
file at load time, and a query attribute takes labels, not a file, so a TSV
could not reach the graph.

## The capabilities

A capability is named by what the plan expresses, not by any surface's
spelling, so a capability that no surface can express shows up as an empty
row. Each is **grounded**: its grounding names the plan constants that
express it, which the lint requires a grounding file to declare (as
`comptime <ID>: UInt8` at column 0). The grounding files, and the
identifier prefixes (families) of each, are named in the root
[`BUCK`](../BUCK): `src/komira_plan_ir/logical_plan.mojo` (`PLAN_`, the plan
node tags; `SOURCE_`, the source kinds; `JOIN_`, the join kinds),
`src/komira_plan_expr/fs_descriptor_pod.mojo` (`FS_SCHEME_`, the remote
prefixes), `src/komira_plan_expr/udf_data.mojo` (`UDF_KIND_`) and
`src/komira_plan_expr/expr.mojo` (no family: read for the expression tags
named below). Every constant of a family must be named by a capability or a
`NOT_CAPABILITIES` row, so a new plan node, join kind or source kind fails
the build until it is classified. A `contract` capability is a promise every
surface makes that no plan node expresses.

| Capability | Grounding | Meaning |
|---|---|---|
| `scan_parquet` | `PLAN_SCAN`, `SOURCE_PARQUET` | read Parquet files |
| `scan_csv` | `PLAN_SCAN`, `SOURCE_CSV` | read CSV files |
| `scan_jsonl` | `PLAN_SCAN`, `SOURCE_NDJSON`, `SOURCE_JSON` | read JSON Lines files (the row and the columnar decode of the same bytes) |
| `scan_orc` | `PLAN_SCAN`, `SOURCE_ORC` | read ORC files |
| `scan_avro` | `PLAN_SCAN`, `SOURCE_AVRO` | read Avro object container files |
| `scan_arrow_ipc` | `PLAN_SCAN`, `SOURCE_ARROW` | read Arrow IPC files |
| `scan_in_memory` | `PLAN_SCAN`, `SOURCE_IN_MEMORY` | query a table the caller holds in memory |
| `scan_s3` | `PLAN_SCAN`, `FS_SCHEME_S3` | read from an s3:// prefix |
| `scan_gs` | `PLAN_SCAN`, `FS_SCHEME_GCS` | read from a gs:// prefix |
| `scan_az` | `PLAN_SCAN`, `FS_SCHEME_AZURE` | read from an az:// prefix |
| `filter` | `PLAN_FILTER` | keep the rows a predicate holds for |
| `project` | `PLAN_PROJECT` | select, reorder and rename columns |
| `computed_column` | `PLAN_PROJECT`, `EXPR_BINARY_OP` | add or replace a column computed from an expression |
| `join_inner` | `PLAN_JOIN`, `JOIN_INNER` | inner join |
| `join_left` | `PLAN_JOIN`, `JOIN_LEFT` | left outer join |
| `join_right` | `PLAN_JOIN`, `JOIN_RIGHT` | right outer join |
| `join_full` | `PLAN_JOIN`, `JOIN_FULL` | full outer join |
| `join_semi` | `PLAN_JOIN`, `JOIN_SEMI` | semi join: left rows with a match |
| `join_anti` | `PLAN_JOIN`, `JOIN_ANTI` | anti join: left rows with no match |
| `join_cross` | `PLAN_JOIN`, `JOIN_CROSS` | cross join |
| `join_asof` | `PLAN_ASOF_JOIN` | as-of join: the nearest right row by an ordered key |
| `aggregate` | `PLAN_AGGREGATE` | aggregates over the whole input (no group keys) |
| `group_by` | `PLAN_AGGREGATE` | aggregates per group of key values |
| `window` | `PLAN_PARTITION_BY`, `EXPR_WINDOW_FN` | window functions over partitions, every row kept |
| `sort` | `PLAN_SORT` | order the rows |
| `topn` | `PLAN_TOPN` | the first n rows of an order |
| `topn_per_group` | `PLAN_PARTITION_TOPN` | the first k rows of an order within each group |
| `limit` | `PLAN_LIMIT` | the first n rows, with an offset |
| `distinct` | `PLAN_DISTINCT` | drop duplicate rows, or rows duplicate on some columns |
| `union` | `PLAN_UNION` | concatenate inputs of one schema (union all) |
| `subquery` | `EXPR_CORRELATED_SUBQUERY` | a subquery inside an expression, correlated or not |
| `udf_map` | `UDF_KIND_MAP` | a user function computing a column |
| `udf_filter` | `UDF_KIND_FILTER` | a user function as a filter predicate |
| `udf_agg` | `UDF_KIND_AGG` | a user aggregate function |
| `null_semantics` | contract | NULL in comparisons, logic, joins, aggregates and ordering, as the surface documents |
| `errors` | contract | an invalid query or a failed read raises to the caller in the surface's own error form |
| `output_dtypes` | contract | results arrive in the surface's own types, every column type converted |
| `output_nan_null` | contract | NaN and NULL stay distinct in results, as the surface represents them |

The constants that are no capability:

| Identifiers | Why |
|---|---|
| `PLAN_VIEW_REF` | a registered view is replaced by its plan before optimization; the plan it expands to is what the capabilities cover |
| `PLAN_CSE_REF` | made only by the optimizer's common-subexpression rewrite; no surface builds it |
| `PLAN_CAST_TO_VARCHAR` | inserted above a text sink by a rewrite; no surface builds it |
| `SOURCE_BINDING` | the open arm: a source kind named by its binding, not by this enum; a kind gets a capability when a surface reaches it |
| `SOURCE_KIND_COLUMNAR`, `SOURCE_KIND_ROW`, `SOURCE_KIND_UNSET` | the layout a source format derives, which picks a reader; not something a query asks for |
| `JOIN_ALGO_AUTO`, `JOIN_ALGO_HASH`, `JOIN_ALGO_SORT_MERGE` | the join algorithm, a physical choice with the same result |
| `FS_SCHEME_FILE` | a local path, which every scan_* capability's test reads |

## The rules

A missing cell (`-`) is never a finding: the census counts and lists it. The
build fails on:

- **A lying row**: a target that does not exist (Buck2 refuses the graph:
  "Unknown target", or a package that does not exist); a target outside its
  surface's own package, `src/tests/e2e/<surface>_e2e` of the komira cell
  (the package Buck2 puts the target in, however the label is spelt); a
  target that is no test: it has no `ExternalRunnerTestInfo` (what every test
  rule gives, `mojo_test` among them) and is not a `mojo_library` whose
  `test_srcs` weld a test.
- **A malformed ledger**: an unknown surface or capability in a row; a second
  row for a pair; a pair with no row; a row with an empty surface,
  capability or target; a surface or capability name that is not
  `[a-z][a-z0-9_]*` or is listed twice; a capability with no meaning; a
  `NOT_CAPABILITIES` row with no reason.
- **An ungrounded vocabulary**: a grounding identifier no grounding file
  declares; a constant of a grounding family that no capability and no
  `NOT_CAPABILITIES` row names.
- **The ratchet**: fewer filled cells than `floor` (the root `BUCK`, today
  0). The floor only rises: the change that fills cells raises it to the new
  count, so a later change cannot empty a cell or lose its test unnoticed.
  More filled cells than the floor is not a finding (two changes that each
  fill a cell can merge in either order); the report prints the floor.

A label that is not a label at all (`foo`) fails when the root `BUCK` is
read, naming the attribute.

## Filling a cell

1. Create the surface's e2e package, `src/tests/e2e/<surface>_e2e/`, if it
   does not exist (its row in the module map,
   [docs/architecture.md](architecture.md), comes with it: `//:src_layout`
   requires one).
2. Add a test target that exercises the capability **end to end** through
   the surface (the surface's own API in, the surface's own result types
   out) and checks the result against an **independent oracle**: a reference
   implementation or expected values computed outside komira, never komira's
   own output. A `mojo_test`, a `mojo_library` whose `test_srcs` hold the
   test, or any other test rule. Its `visibility` must include
   `//:surface_capability_matrix` (or be `PUBLIC`), since the lint depends on
   it, and it must be compatible with Linux x86-64, the platform the lint
   is configured for.
3. Replace the cell's `-` in `MATRIX` with the target's label and say in the
   note what it checks; one target may fill several cells.
4. Raise `floor` in `//:surface_capability_matrix` to the new number of
   filled cells, and refresh the census below.

The lint proves the target exists, lives in the surface's package and is a
test; whether it exercises what its row claims is for review. The target's
own build (or `buck2 test`) is what runs it: the lint only analyses it.

## Census

The census of 2026-10-07: `./buck2 build '//:surface_capability_matrix[report]'`
on the farm over the tree of that day. A dated snapshot: rebuild `[report]`
for today's numbers.

**Totals.** 6 surfaces x 38 capabilities = 228 cells;
**0 filled (0.0%)**; 228 missing; floor 0. No surface e2e package
exists yet (`src/tests/e2e/<surface>_e2e`), so every cell is `-`. That is
the starting point.

| Surface | Filled | Cells | % |
|---|---:|---:|---:|
| `pandas` | 0 | 38 | 0.0% |
| `polars` | 0 | 38 | 0.0% |
| `sql` | 0 | 38 | 0.0% |
| `mojo_polars` | 0 | 38 | 0.0% |
| `ts_polars` | 0 | 38 | 0.0% |
| `excel` | 0 | 38 | 0.0% |

Every cell, `yes` when filled and `-` when missing:

| Capability | `pandas` | `polars` | `sql` | `mojo_polars` | `ts_polars` | `excel` |
|---|---|---|---|---|---|---|
| `scan_parquet` | - | - | - | - | - | - |
| `scan_csv` | - | - | - | - | - | - |
| `scan_jsonl` | - | - | - | - | - | - |
| `scan_orc` | - | - | - | - | - | - |
| `scan_avro` | - | - | - | - | - | - |
| `scan_arrow_ipc` | - | - | - | - | - | - |
| `scan_in_memory` | - | - | - | - | - | - |
| `scan_s3` | - | - | - | - | - | - |
| `scan_gs` | - | - | - | - | - | - |
| `scan_az` | - | - | - | - | - | - |
| `filter` | - | - | - | - | - | - |
| `project` | - | - | - | - | - | - |
| `computed_column` | - | - | - | - | - | - |
| `join_inner` | - | - | - | - | - | - |
| `join_left` | - | - | - | - | - | - |
| `join_right` | - | - | - | - | - | - |
| `join_full` | - | - | - | - | - | - |
| `join_semi` | - | - | - | - | - | - |
| `join_anti` | - | - | - | - | - | - |
| `join_cross` | - | - | - | - | - | - |
| `join_asof` | - | - | - | - | - | - |
| `aggregate` | - | - | - | - | - | - |
| `group_by` | - | - | - | - | - | - |
| `window` | - | - | - | - | - | - |
| `sort` | - | - | - | - | - | - |
| `topn` | - | - | - | - | - | - |
| `topn_per_group` | - | - | - | - | - | - |
| `limit` | - | - | - | - | - | - |
| `distinct` | - | - | - | - | - | - |
| `union` | - | - | - | - | - | - |
| `subquery` | - | - | - | - | - | - |
| `udf_map` | - | - | - | - | - | - |
| `udf_filter` | - | - | - | - | - | - |
| `udf_agg` | - | - | - | - | - | - |
| `null_semantics` | - | - | - | - | - | - |
| `errors` | - | - | - | - | - | - |
| `output_dtypes` | - | - | - | - | - | - |
| `output_nan_null` | - | - | - | - | - | - |

## Tests

[Test 53](../tools/build/tests/lint_tests.md#53-the-surface-capability-matrix):
`tests//functional/surface_capability_matrix:ok` analyses a planted matrix
whose census must equal its expected `[matrix]` and `[report]` byte for
byte, three cells filled by real `mojo_library` and `mojo_test` targets in
planted `pandas_e2e` and `polars_e2e` packages (one named by a cell-relative
label), with grounding files holding near misses (an `Int` constant, a
commented-out one, an indented one). Each target of
`tests//negative/surface_capability_matrix` must fail naming its planted
defect: a target that does not exist, a repeated pair, an unknown capability,
an unknown surface, a target in another surface's package, a target outside
`src/tests/e2e`, a target that is no test, a pair with no row, an empty
field, a capability grounded in no declared constant, a family constant no
capability names, a repeated capability, fewer filled cells than the floor,
and no surface. Each of these mutants of the lint turns a test red: dropping
the package check, the test check, the duplicate check, the unknown
capability or surface check, the missing-pair check, the grounding check, the
family check, the vocabulary duplicate check, the floor or the empty check;
reading an indented `comptime`, or a constant of any type; taking the
package from the label's text instead of the graph; calling every target a
test; not making the named targets dependencies; and a wrong percentage.

## Limits

- Whether a test exercises its capability, and against an independent
  oracle, is review's call: the lint checks where the target is and that it
  is a test, not what it asserts.
- Every cell weighs the same: a surface's percentage counts a remote prefix
  like a join kind.
- The vocabulary is as fine as the plan constants: one capability per join
  kind and source kind, one for all of an aggregate's functions and one for
  every expression of a computed column.
- `union` is the plan's union of inputs of one schema; a surface's set
  operations may lower otherwise (the plan builds `PLAN_UNION` for multi-file
  scans today).
