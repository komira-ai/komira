# Surface capability matrix

komira is reached through surfaces: the pandas-shaped and polars-shaped
frontends, SQL, the polars-shaped Mojo and TypeScript APIs, and Excel. Excel is
a surface of its own, built on top of the TypeScript SDK: it uses that SDK and
maps the engine's errors to Excel's own values, so its tests exercise Excel's
layer and, through it, the TypeScript SDK. The `ts_polars` column covers the
TypeScript SDK itself, so the two columns are filled independently. komira's
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
express it, which the lint requires a grounding file to declare at column 0,
as `comptime <ID>: UInt8 = <n>` or `comptime <ID> = UInt8(<n>)`. The
grounding files, and the identifier prefixes (families) of each, are named
in the root [`BUCK`](../BUCK): `src/komira_plan_ir/logical_plan.mojo`
(`PLAN_`, the plan node tags; `SOURCE_`, the source kinds; `JOIN_`, the join
kinds), `src/komira_plan_expr/expr.mojo` (`EXPR_`, the expression kinds),
`src/komira_plan_expr/fs_descriptor_pod.mojo` (`FS_SCHEME_`, the remote
prefixes), `src/komira_plan_expr/udf_data.mojo` (`UDF_KIND_`) and
`src/komira_arrow/write_target.mojo` (`WFMT_`, the formats a result is
written in). Every constant of a family must be named by a capability or a
`NOT_CAPABILITIES` row, so a new plan node, expression kind, join kind,
source kind or write format fails the build until it is classified. A
family constant declared in another form (`comptime PLAN_X = 17`) is a
finding too, never skipped; one with another type annotation
(`comptime PLAN_TAG_COUNT: Int = 16`) is no tag. A `contract` capability is
a promise every surface makes that no plan node expresses.

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
| `project` | `PLAN_PROJECT`, `EXPR_COL_REF`, `EXPR_COL_IDX`, `EXPR_ALIAS` | select, reorder and rename columns |
| `computed_column` | `PLAN_PROJECT`, `EXPR_LITERAL`, `EXPR_BINARY_OP`, `EXPR_UNARY_OP` | add or replace a column computed from literals, arithmetic, comparison and logic |
| `cast` | `EXPR_CAST` | convert a value to another type |
| `case_when` | `EXPR_WHEN` | a conditional expression (CASE WHEN, when/then/otherwise) |
| `in_list` | `EXPR_IN_LIST` | membership of a value in a list of values |
| `between` | `EXPR_BETWEEN` | a value within a closed range |
| `string_functions` | `EXPR_STRING_OP`, `EXPR_STRING_FN`, `EXPR_STRING_FN_N`, `EXPR_SUBSTRING` | string functions: case, trim, length, substring, concat, replace, pad, position |
| `regexp` | `EXPR_REGEXP` | regular-expression match, extract, replace and split |
| `temporal_extract` | `EXPR_EXTRACT` | extract a date or time field, or truncate to a period |
| `math_functions` | `EXPR_MATH_FN`, `EXPR_MATH_FN2` | math functions of one or two arguments |
| `nested_access` | `EXPR_STRUCT_FIELD`, `EXPR_STRUCT_FIELD_IDX`, `EXPR_MAP_GET` | a struct field or a map value by key |
| `json_extract` | `EXPR_JSON_EXTRACT` | a path extracted from a JSON column |
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
| `sort` | `PLAN_SORT`, `EXPR_SORT_KEY` | order the rows, NULLs first or last |
| `topn` | `PLAN_TOPN` | the first n rows of an order |
| `topn_per_group` | `PLAN_PARTITION_TOPN` | the first k rows of an order within each group |
| `limit` | `PLAN_LIMIT` | the first n rows, with an offset |
| `distinct` | `PLAN_DISTINCT` | drop duplicate rows, or rows duplicate on some columns |
| `union` | `PLAN_UNION` | concatenate inputs of one schema (union all) |
| `subquery` | `EXPR_CORRELATED_SUBQUERY` | a subquery inside an expression, correlated or not |
| `view` | `PLAN_VIEW_REF` | register a named view and query it |
| `udf_map` | `UDF_KIND_MAP`, `EXPR_UDF_CALL` | a user function computing a column, alone or inside an expression |
| `udf_filter` | `UDF_KIND_FILTER` | a user function as a filter predicate |
| `udf_agg` | `UDF_KIND_AGG` | a user aggregate function |
| `write_parquet` | `WFMT_PARQUET` | write a result as Parquet |
| `write_csv` | `WFMT_CSV` | write a result as CSV |
| `write_jsonl` | `WFMT_JSONL` | write a result as JSON Lines |
| `null_semantics` | contract | NULL in comparisons, logic, joins, aggregates and ordering, as the surface documents |
| `errors` | contract | an invalid query or a failed read raises to the caller in the surface's own error form |
| `output_dtypes` | contract | results arrive in the surface's own types, every column type converted |
| `output_nan_null` | contract | NaN and NULL stay distinct in results, as the surface represents them |

The constants that are no capability:

| Identifiers | Why |
|---|---|
| `PLAN_CSE_REF` | made only by the optimizer's common-subexpression rewrite; no surface builds it |
| `PLAN_CAST_TO_VARCHAR` | inserted above a text sink by a rewrite; no surface builds it |
| `EXPR_AGG_FN` | an aggregate inside an expression, made and consumed by the optimizer's scalar-broadcast rewrite; a surface's aggregates are the aggregate and group_by capabilities |
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
  exactly, not a subpackage and not a longer name (the package Buck2 puts the
  target in, however the label is spelt); a target whose default outputs a
  target of another package made (an `alias` forwards its actual target's
  providers, so an alias in the surface's package standing for a test
  elsewhere is refused); a target that is no test: it has no
  `ExternalRunnerTestInfo` (what every test rule gives, `mojo_test` among
  them) and is not a `mojo_library` whose `test_srcs` weld a test (a library
  with no `test_srcs` is no test); a test that already fills another cell of
  the same surface, however spelt (each filled cell names a test of its
  own).
- **A malformed ledger**: an unknown surface or capability in a row; a second
  row for a pair; a pair with no row; a row with an empty surface,
  capability or target; a surface or capability name that is not
  `[a-z][a-z0-9_]*` or is listed twice; a capability with no meaning; a
  `NOT_CAPABILITIES` row with no reason.
- **An ungrounded vocabulary**: a grounding identifier no grounding file
  declares; a constant of a grounding family that no capability and no
  `NOT_CAPABILITIES` row names, or that is declared in a form the lint
  cannot read.
- **The floor**: fewer filled cells than `floor` (the root `BUCK`, today
  0), so a change that empties a cell or loses its test fails. That the
  floor only rises is a **review rule**, not something the lint enforces: the
  change that fills cells raises it to the new count, and review refuses a
  change that lowers it. More filled cells than the floor is not a finding
  (two changes that each fill a cell can merge in either order); the report
  prints the floor.
- **A test incompatible with Linux x86-64**, the platform the lint is
  configured for: Buck2 refuses the lint that depends on it ("does not pass
  compatibility check ... because its transitive dep ..."), even when the
  lint is reached by a pattern (`//...`, `//:`), so the lint cannot drop out
  of a build silently. Test 53 pins this with a package-pattern build.

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
   note what it checks. Each filled cell of a surface names a test of its
   own: one target filling two cells of a surface is a finding.
4. Raise `floor` in `//:surface_capability_matrix` to the new number of
   filled cells (review holds this), and refresh the census below.

The lint proves the target exists, lives in the surface's package and is a
test; whether it exercises what its row claims is for review. The target's
own build (or `buck2 test`) is what runs it: the lint only analyses it.

## Census

The census of 2026-10-07: `./buck2 build '//:surface_capability_matrix[report]'`
on the farm over the tree of that day. A dated snapshot, written by hand from
`[report]`: the lint's `[report]` and `[matrix]` are the source of truth, so
rebuild them for today's numbers.

**Totals.** 6 surfaces x 52 capabilities = 312 cells;
**0 filled (0.0%)**; 312 missing; floor 0. No surface e2e package
exists yet (`src/tests/e2e/<surface>_e2e`), so every cell is `-`. That is
the starting point.

| Surface | Filled | Cells | % |
|---|---:|---:|---:|
| `pandas` | 0 | 52 | 0.0% |
| `polars` | 0 | 52 | 0.0% |
| `sql` | 0 | 52 | 0.0% |
| `mojo_polars` | 0 | 52 | 0.0% |
| `ts_polars` | 0 | 52 | 0.0% |
| `excel` | 0 | 52 | 0.0% |

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
| `cast` | - | - | - | - | - | - |
| `case_when` | - | - | - | - | - | - |
| `in_list` | - | - | - | - | - | - |
| `between` | - | - | - | - | - | - |
| `string_functions` | - | - | - | - | - | - |
| `regexp` | - | - | - | - | - | - |
| `temporal_extract` | - | - | - | - | - | - |
| `math_functions` | - | - | - | - | - | - |
| `nested_access` | - | - | - | - | - | - |
| `json_extract` | - | - | - | - | - | - |
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
| `view` | - | - | - | - | - | - |
| `udf_map` | - | - | - | - | - | - |
| `udf_filter` | - | - | - | - | - | - |
| `udf_agg` | - | - | - | - | - | - |
| `write_parquet` | - | - | - | - | - | - |
| `write_csv` | - | - | - | - | - | - |
| `write_jsonl` | - | - | - | - | - | - |
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
commented-out one, an indented one) and an unannotated
`comptime PLAN_UNTYPED = UInt8(16)` that must be read. Each target of
`tests//negative/surface_capability_matrix` must fail naming its planted
defect: a target that does not exist, a repeated pair, an unknown capability,
an unknown surface, a target in another surface's package, a test outside
`src/tests/e2e`, a test in a package whose name starts with the surface's, a
test in a subpackage of it, an alias in the surface's package of a test
elsewhere, a target that is no test (a file; a `mojo_library` with no
`test_srcs`), one test filling two cells of a surface, a family constant in a
form the lint cannot read, a pair with no row, an empty field, a capability
re-grounded in a constant no file declares, a family constant no capability
names, a repeated capability, fewer filled cells than the floor, and no
surface; five of them must yield exactly one finding. The negative
`incompatible`, alone in its package, is built by a package pattern and must
fail naming the incompatible test. Each of these mutants of the lint turns a
test red: dropping the package check, the test check, the duplicate check,
the unknown capability or surface check, the missing-pair check, the
grounding check, the family check, the vocabulary duplicate check, the floor
or the empty check; matching the package by prefix; dropping the alias
(output maker) check, or taking the maker from the label; counting a library
with no `test_srcs` as a test; dropping the one-test-per-cell check, or
keying it on the label's spelling; not reading the unannotated form, or
skipping a form it cannot read; reading an indented `comptime`, or a
constant of any type; taking the package from the label's text instead of
the graph; calling every target a test; not making the named targets
dependencies; and a wrong percentage. The planted e2e targets build too
(`tests//functional/...` builds them; `test_mac` is skipped there as
incompatible).

## Limits

- Whether a test exercises its capability, and against an independent
  oracle, is review's call: the lint checks where the target is and that it
  is a test, not what it asserts.
- Every cell weighs the same: a surface's percentage counts a remote prefix
  like a join kind.
- The vocabulary is as fine as the plan constants: one capability per join
  kind, source kind and write format, one for all of an aggregate's
  functions, one per expression kind or group of them.
- The alias check reads where a target's default outputs were made; a test
  whose default outputs are all source files (no maker) is placed by its
  own label only.
- `union` is the plan's union of inputs of one schema; a surface's set
  operations may lower otherwise (the plan builds `PLAN_UNION` for multi-file
  scans today).
