# The Mojo SDK: one entry library a stranger can install

Status: design, not built. **EXISTS** names code on `main`. **PROPOSED** is new. Statements the
author deduced rather than read are marked *(inferred)*. The choices only the owner can make are
collected under [Decisions for the owner](#decisions-for-the-owner).

## What problem does this solve?

A Python user runs `pip install komira` and gets SQL over their files, and the TypeScript package
offers the same over the Node addon ([python_package.md](python_package.md),
[typescript_package.md](typescript_package.md)). A Mojo user has nothing equivalent. **EXISTS:**
- 66 Mojo libraries are packages on mopm, the registry the release publishes to: the `PACKAGES` of
  [release/readme_e2e/packages.bzl](../../release/readme_e2e/packages.bzl).
- The other 197 are not: the rows of [release/UNPUBLISHED.md](../../release/UNPUBLISHED.md).
- None of the 66 is an engine, so no library a stranger can install reads a file and runs a query.
- `sdk_exec` comes closest: SQL over Parquet, CSV and local Iceberg, run in-process
  ([src/sdk_exec/README.md](../../src/sdk_exec/README.md)). It is unpublished, and so is most of
  what it is built on. Its own surface is the engine's: `EngineContext` with public fields such as
  the worker runtime, and a refusal value instead of an error.
- No Mojo library has a public `Session` type. `src/sdk` is the plan-building half of a Mojo SDK,
  and its `__init__.mojo` exports nothing.
- Python and Node do not import Mojo libraries. They reach the engine through the C calls of
  `libkomira` (`src/so`, [libkomira_run_abi.md](libkomira_run_abi.md)).

This document says what the Mojo SDK is: up to three surfaces, each with what it is, who it is for
and what it rests on. The first is one page of code. The document also computes exactly what must be
published for them and sets the order of the work. It adds no code and publishes nothing.

Fixed before this design, and not reopened here:
- **One engine route.** SQL and plans share one route from the optimizer down, in `sdk_exec`
  ([libkomira_run_abi.md](libkomira_run_abi.md), "SQL and plans share one route from the optimizer
  down"). The Mojo SDK calls that route; it adds no second engine path.
- **Sources are values.** Every SDK binds a table name to a source value with `add_sql_binding`.
  Mojo spells it `session.add_sql_binding(name, source)`, as Python does
  ([credentials_and_writes.md](credentials_and_writes.md), decision 12). The owner prefers one
  `files` source to a reader name per format.
- **The Mojo rules** of [AGENTS.md](../../AGENTS.md) and
  [mojo_safety_and_idioms.md](mojo_safety_and_idioms.md) hold for every new line.

## The three surfaces

The Mojo SDK can be up to three surfaces. They differ in what the user writes and in how much of the
engine's route the user's code skips.

| | A. The session | B. The physical-plan builder (untyped) | C. The typed SDK |
|---|---|---|---|
| what the user writes | files and SQL text; reads rows back | the physical plan itself: pipelines, their operators and the sink that ends each, with schemas as run-time values | a program whose schema is a compile-time value, run by operators specialised for it |
| who it is for | anyone who would write SQL, the same users as Python and Node; the examples the owner's three-language gate needs | Mojo authors who want a plan run exactly as written: no binder, no optimizer, no lowering | Mojo authors who know their schema when they compile and want the compiler to check columns and specialise the operators |
| what it rests on | `sdk_exec.run_sql`: parse, bind, optimize, lower, execute, the route Python and Node take (§1) | the executor door `sdk_exec.engine_execute.run_lowered_plan_with` and the physical IR of `physical_plan` and `lowering.lowered_plan`, behind a builder of its own (§2) | the typed operator tables (`op_agg_stage`, `op_sort`'s `Stage_Sort`, `op_window`'s top-n stages) and the compile-time schema descriptor (`plan_expr.typed_schema`, `sdk.auto_schema`); its front end is not in this repository (§3) |
| libraries to publish | the 56 of §4, then `sdk_exec` and `komira` | none beyond A's: B is a module of the same package (§2) | its own set, larger than A's (§3) |
| recommended | first | second | later, with a design of its own |

The order is decision D6. A comes first because the examples gate needs it and because B and C need
every library A publishes anyway. B comes second because it adds no library and mostly needs a check
at the executor's door (§2). C comes later because its front end has to be designed and written
first.

## 1. Surface A: the session, and the page a stranger writes

**PROPOSED.** The whole program:

```mojo
from komira import Session, files

def main() raises:
    var session = Session()
    session.add_sql_binding("trips", files("trips.parquet"))
    var result = session.sql(
        "SELECT city, count(*) AS trips FROM trips GROUP BY city ORDER BY city"
    )
    print(result)
```

The setup around it, on Linux x86_64 or macOS on Apple silicon:

```sh
mopm init --name hello
# in the mopm.toml that init wrote, set: [toolchain] mojo = "1.1.0"
mopm add komira-ai/komira
mopm sync
mopm build main.mojo -o main --prefix .mopm/.pixi/envs/default
./main
```

`print(result)` writes the result as a table between `+---+` rules: column names, a row of short
type names, one line per row (at most 20), then a line with the row count (`N rows`, with
`(showing 20, ... M more rows)` when rows were cut). The printer is `sdk`'s `format_table`, which
**EXISTS** ([src/sdk/table_display.mojo](../../src/sdk/table_display.mojo)). The exact text a
release prints is whatever its README e2e runs (§7). This document invents no output.

Three lines in the setup are sourced, not invented:
- The `mopm init`, `[toolchain] mojo` and `mopm add komira-ai/<name>` lines are what the release's
  `prod-add` job does as a user ([docs/ci.md](../ci.md), "prod-add").
- `mopm sync` installs the compiler through pixi ([src/bench/README.md](../../src/bench/README.md)).
- The `mopm build ... --prefix .mopm/.pixi/envs/default` line is that README's own way to build
  an installed source.

*(inferred)* Building the user's own `main.mojo` the same way works too, since nothing in a package
is specific to `bench`.

### The surface

The package is `komira-ai/komira`, imported as `komira`. It has four names.

| name | what it is | built on (**EXISTS**) |
|---|---|---|
| `Session(threads: Optional[Int] = None, memory_limit: Optional[Int] = None) raises` | one engine. It is `Movable`, not `Copyable`, and dropping it stops its workers | `EngineContext(EngineOptions(worker_count=threads, memory_budget_bytes=memory_limit))`, after `compression.codec_libraries.probe_codec_libraries()` |
| `session.add_sql_binding(name: String, source: Files) raises` | `name` reads `source` in later `sql` calls; binding a name again replaces it | `sdk_exec.engine_catalog.register_parquet(ctx, name, path)` |
| `session.sql(query: String) raises -> Result` | runs one statement and raises on any refusal | `sdk_exec.engine_sql.run_sql(ctx, query)` |
| `files(location: String) raises -> Files` | a source value: a Parquet file, a glob or a directory; it does no I/O | **PROPOSED**, a `String` held as a value |
| `Result` | the answer: `num_rows()`, `num_columns()`, `column_names()`, `batch()` (a `ref [self] RecordBatch`), and it is `Writable` for `print` | the batch of `SqlOutcome.batches`, with its selection applied by `column_kernels`' `materialize_selection_if_present`, as `arrow_result` applies it |

The parts of that table, each sourced:
- `register_parquet` accepts a file, a glob or a directory
  ([src/sdk_exec/engine_catalog.mojo](../../src/sdk_exec/engine_catalog.mojo)).
- `run_sql` uses `LocalOnlyScanFs`, which reads local files only. A run appends one batch to
  `SqlOutcome.batches` ([src/sdk_exec/engine_plan.mojo](../../src/sdk_exec/engine_plan.mojo)).
- `RecordBatch` is `Movable` and not `Copyable` (`src/arrow/record_batch.mojo`). That is why
  `Result` lends its batch by `ref` and does not copy it.

The behaviour:
- **Errors.**
  - `sql` raises an `Error` whose text is `<step>: <reason>`. For a parse error the text ends
    ` at line <L>, column <C>`.
  - The step and reason are `SqlRefusal.step` and `SqlRefusal.reason`, and the position is
    `SqlRefusal.position`.
  - This is the text libkomira's last error holds for the same refusal, and the text Python's and
    Node's error messages carry ([libkomira_run_abi.md](libkomira_run_abi.md), "`<step>: <reason>`").
  - The reason begins with its named code where the engine names one (`SQL_SYNTAX_ERROR`,
    `PARQUET_GLOB_NO_MATCH`, `ENGINE_OPTIONS_INVALID`, ...), so a test or a user can match on it.
  - Whether a typed error replaces the text is decision D3.
- **Options.** `threads` and `memory_limit` have the meaning of Python's `Session(threads=...,
  memory_limit=...)`: absent means the host profile's own value, and below 1 is refused with
  `ENGINE_OPTIONS_INVALID`. Nothing reads an environment variable (rule S2;
  `engine_options.mojo` reads none either).
- **`files`.**
  - An empty location is refused.
  - A location that starts with a URL scheme (`<scheme>://`) is refused with `STORAGE_URL_REFUSED`,
    the code the C calls already use for a URL they cannot serve. Remote files are slice 7.
  - A relative path is made absolute against the working directory when `files` is called, as
    Python's `komira.files` does (`python/komira/_sources.py`).
  - `files` names Parquet, as Python's `files` does today. Choosing the format from the extension
    comes later and is the same step for every SDK ([credentials_and_writes.md](credentials_and_writes.md),
    "infers the format from the extension").
- **Threads.** `sql` and `add_sql_binding` take `mut self`, so the compiler keeps a session to one
  caller at a time. That is the C ABI's "one thread at a time" per handle, held by the type instead
  of by a lock. Two sessions share nothing (`engine_context.mojo`: "two contexts share nothing").
- **What is not there.** There is no `register_parquet` (the owner prefers one `files` source) and
  no `read_csv`, `read_parquet` or other reader per format. There are no frames, no remote stores,
  no credentials, no cancel or progress, and no write call: `COPY ... TO` in SQL already writes a
  local file. `sql` has no per-call `bindings` argument yet: credentials_and_writes.md (decision
  12) gives Mojo `session.sql(query, bindings)` with a `Dict[String, Source]`, which is a later,
  additive overload. Each of these is a later slice (§9), added beside the four names without
  changing them.

Two cases outside the session rules:
- **Missing codec libraries.** A missing system codec library (libzstd, libz, liblz4) is an error
  from `Session()`, not an abort in the middle of a query. That is why `Session` calls
  `probe_codec_libraries()` first, as libkomira does before each run
  ([libkomira_run_abi.md](libkomira_run_abi.md), §8). `run_sql` itself does not probe.
- **Faults in the engine.** A fault the engine treats as fatal still ends the process. It does so
  in libkomira's callers too ([libkomira_run_abi.md](libkomira_run_abi.md), §8, the fail-fast
  list).

### Why `komira`, and why a new library

- **The name.** `komira` is the name the stranger already knows from `pip install komira` and the
  npm package. mopm makes a package `<name>` into `komira-ai/<name>`, imported as `<name>`
  ([packages.bzl](../../release/readme_e2e/packages.bzl)). Mojo's standard library lives under
  `std.`, so a top-level `komira` collides with nothing. No `src/komira` exists, and `komira` is not
  yet claimed on the prod registry (`release/prod_claimed_names.txt`). Decision D1.
- **Not `sdk_exec` itself.** Its public surface is the engine's: `EngineContext`'s public fields
  hold the catalog, the footer cache and the `async_rt` worker runtime, and it has 25 modules
  (`ls src/sdk_exec/*.mojo | wc -l`) to import by name. Making that the public promise would freeze engine internals. `komira` keeps
  them in a private field (`_ctx: EngineContext`), so `sdk_exec` can change underneath.
- **Not `sdk`.** `sdk` builds plans and executes nothing ([docs/architecture.md](../architecture.md)).
  A frame API belongs there later, not a session.
- **Not a new engine.** Every call is one `sdk_exec` call, so the SDK holds no engine logic of its
  own. That makes it the smallest surface that is still honest about what runs.

### A Mojo frame API, later

This design does not include a frame API. One would rest on what **EXISTS**:
- `sdk`'s plan builders (its `dataframe_*` modules and `col`);
- `sdk_exec.engine_plan.run_plan(ctx, plan)`, the plan door, which runs a built `LogicalPlan`
  through the same route from the optimizer down with no SQL front end;
- `plan_wire` for a plan that must cross a process.

Python's two frame surfaces ([dataframe_surface.md](dataframe_surface.md)) are the reference for
its names. It would be one more name on `Session` that takes a frame, and changes none of the four.
Its closure is the same as this one's, since `sdk` is already in it (§4).

## 2. Surface B: the physical-plan builder

**PROPOSED.** The user's code writes the physical plan: the pipelines, the operators inside each one,
and the sink that ends each pipeline. The plan goes to the executor as written. There is no binder,
no optimizer and no lowering, so nothing reorders, pushes down, fuses or chooses a sink for the user.
Schemas are run-time values: the plan reads them from the sources when it is submitted.

### What exists to build on

All of this is **EXISTS** and public:
- **The physical IR** (`src/physical_plan/physical_plan.mojo`, IR version 21). A plan is a list of
  `SegmentDescPod`, one per pipeline. Each holds a source (`SourceSpecPod`, for example
  `SourceSpecPod.parquet(path, projection, pushed_filter, spec_is_total, fs)`), a chain of
  `MorselOp` (`filter`, `project`, `limit`, `join_probe`), and a sink tag (`SINK_AGG`,
  `SINK_COLLECT`, `SINK_SORT`, `SINK_TOPN`, `SINK_HASH_BUILD`, ...). The sink also has a key type tag,
  an orientation, an order key and its dependencies with their edge tags.
- **The plan as lowering emits it.** `LoweredPlan(segments, params, result_seg_id)`
  (`src/lowering/lowered_plan.mojo`). Its `ParamTable` holds each sink's data by index. For example
  `AggSinkData(group_by_exprs, agg_exprs, output_schema, ...)` (`src/physical_plan/sink_data.mojo`).
- **Expressions.** `Expr` is an owned tree with factories (`Expr.col_ref(name)`, `Expr.col_idx(i)`,
  `Expr.literal(ScalarValue...)`, `Expr.binary(op, l, r)`). `AggExpr(func, child, alias)` holds an
  aggregate (`src/plan_expr`).
- **The executor door.** `run_lowered_plan_with(ctx, lowered, opener) raises -> RecordBatch`
  (`src/sdk_exec/engine_execute.mojo`). It feeds the `ParamTable` to the segment builder in index
  order and runs the segments on the context's workers.
- **A precedent.** `src/pipeline_exec/tests/test_group_agg_plan.mojo` builds a scan, filter and
  grouped-aggregate plan by hand. `src/pipeline_exec/plan_harness.mojo` has its helpers, which are
  test support.

None of those public signatures takes or returns a pointer (§5).

### What the user writes, for one real pipeline

One local Parquet file, scanned, filtered, grouped and aggregated, then printed. In SQL this is
`SELECT city, count(*) AS trips, sum(fare) AS total FROM 'trips.parquet' WHERE fare > 10 GROUP BY city`.
*(PROPOSED; the spelling of list arguments follows whatever the pinned compiler accepts for lists of
the SDK's `Expr`.)*

```mojo
from komira import Session
from komira.physical import PhysicalPlan, parquet, col, lit, count_rows, sum_of

def main() raises:
    var session = Session()
    var plan = PhysicalPlan()
    # One pipeline: a Parquet scan, a filter, and a hash aggregate, the sink that ends it.
    var trips = plan.pipeline(parquet("trips.parquet", columns=["city", "fare"]))
    plan.filter(trips, col("fare") > lit(10.0))
    plan.hash_aggregate(trips, keys=[col("city")],
                        aggregates=[count_rows("trips"), sum_of(col("fare"), "total")])
    plan.set_result(trips)
    print(session.schema_of(plan, trips))   # the pipeline's output schema, a run-time value
    var result = session.run(plan^)          # check the plan, then run it as written
    print(result)
```

Each call maps to the IR, and the builder fills the fields the user does not choose:

| builder call | what it emits |
|---|---|
| `plan.pipeline(parquet(path, columns))` | a `SegmentDescPod` with `SOURCE_PARQUET` and `SourceSpecPod.parquet(path, columns, None, spec_is_total=True)`; its id is its position. The IR says the flag is derived and never declared, so the builder makes it true by what it accepts: one local file (a glob or a directory is listed into `SourceSpecPod.parquet_files` first) |
| `plan.filter(p, e)`, `plan.project(p, exprs, names)`, `plan.limit(p, n)` | `MorselOp.filter`, `MorselOp.project` and `MorselOp.limit` appended to that pipeline |
| `plan.hash_aggregate(p, keys, aggregates)` | sink `SINK_AGG`, with the key type tag taken from the key's type in the run-time schema (`KEY_DTYPE_STRING` here, `KEY_DTYPE_COMPOSITE` for several keys) and always `SINK_ORIENT_COLUMNAR`; lowering may pick `SINK_ORIENT_DICT_ENCODED` from footer facts, which the builder does not read. The `AggSinkData` is appended to `params.agg`, and its `output_schema` comes from the input schema and the aggregate list. `ORDER_ROW_RANGE` is set when a sum or mean is over a float, so the answer does not depend on the worker count |
| no sink named | `SINK_COLLECT` |
| `plan.pipeline(output_of(p))` | `SourceSpecPod.from_sink_output(p)`, with `p` in the new pipeline's `deps` and the waiting edge `EDGE_E3_PUBLISH_WAIT` |
| later: `sort`, `top_n`, `hash_join(build=p1, probe=p2, ...)` | `SINK_SORT`, `SINK_TOPN`, and `SINK_HASH_BUILD` on `p1` with `MorselOp.join_probe` on `p2` |
| `session.run(plan)` | reads each source's schema, checks the whole plan (below), builds the `LoweredPlan`, and calls `run_lowered_plan_with(ctx, lowered, LocalOnlyScanFs())` |

The user chooses the shape: how the plan is cut into pipelines, where a filter runs, which sink ends
each pipeline, and which side of a join is built. That is what B has and A does not. The builder
chooses only what follows from those choices.

### What lowering guarantees today, and how B checks it instead

`lower` builds most invariants by construction. The executor checks part of the rest:
- `check_plan` (`src/pipeline_exec/plan_check.mojo`) runs before any pipeline does.
- `RealBuilder` checks each pipeline as it builds it, after earlier pipelines have already run.
- A few things nothing checks.

A hand-built plan could break any of them, so B's rule is a check at submit, before any pipeline
runs. A broken plan is refused by name and never crashes. The table shows what the executor does
today with a broken plan and what B does.

| invariant | today, for a plan `lower` did not build | B |
|---|---|---|
| IR version, ids equal positions, deps in range and acyclic, edge tags with a policy, the order key only on `SINK_AGG` | named, before any pipeline runs (`check_plan`) | by construction, and `check_plan` still runs |
| the Parquet spec is total | a named refusal at build | by construction (one file, or a listed set) |
| a sink's data index is in range for its sink kind | named, but late (at that pipeline's build) | by construction: the builder assigns the indices and feeds them in order |
| the sink's (kind, key type, orientation) is one the executor serves | named, late. The capability table (`lowering.sink_capability.admit_plan`) is checked only inside `lower`, and `pipeline_exec` does not import it | checked at submit: `PHYSICAL_PLAN_SINK_UNSERVED` |
| a join probe's build pipeline ends in `SINK_HASH_BUILD` | **not checked**: the probe takes whatever the build pipeline published | by construction (`hash_join` names both sides) |
| the result pipeline is published and is the plan's only root | partly: a missing result is named; a stray root is not checked | checked at submit: `PHYSICAL_PLAN_RESULT_NOT_ROOT` |
| a column named in an expression exists in the rows that reach it | named, but at the first morsel, inside a worker | checked at submit against the run-time schema: `PHYSICAL_PLAN_COLUMN_UNKNOWN` |
| a column given by position is in range | **unchecked in a release build**: `Slab.__getitem__` is a `debug_assert` only, so an out-of-range ordinal reads out of bounds | B's expressions name columns by name and never by position |
| expression types fit (a filter is boolean, a sum is over a number) | partly: aggregate output types at sink build (`check_declared_type`), the rest when a kernel meets the data | checked at submit: `PHYSICAL_PLAN_TYPE_MISMATCH` |
| a sink's `output_schema` agrees with what the sink produces (names, types, nullability) | partly: `check_declared_type`, and a NULL in a non-nullable column at run time | by construction: the builder derives it |
| no logical plan or correlated subquery inside an expression | checked only inside `lower` (the purity gate). The evaluator returns NULL for that tag, so the result would be wrong | by construction: B's expression vocabulary has no subquery |
| a float sum gives the same answer at any worker count | not checked; lowering sets `ORDER_ROW_RANGE` | by construction (the table above) |

Two changes make this hold, both **PROPOSED**:
- **In the executor.** The sink capability table moves from `lowering` to `physical_plan`, and
  `check_plan` runs it for every plan before any pipeline runs. `check_plan` and `run_plan` take
  only the segments, and the result segment's id lives in `LoweredPlan`, which `pipeline_exec`
  does not depend on. So the check that the result pipeline exists and is the plan's only root
  goes in `run_lowered_plan_with` in `sdk_exec`, before it calls `run_plan`. Today a missing
  result is named only after the whole run (`out.take(lowered.result_seg_id)`). A lowered plan
  passes both checks, and the table becomes the one list `lowering` and the executor share.
- **In `komira.physical`.** The checks that need schemas: column names, types and output schemas.
  The builder holds the flowing schema of each pipeline when the plan is submitted, so it can run
  them.

Each refusal is a `raises` with the text `<code>: <what>`, which names the pipeline, the operator and
the column. That is the same form as A's errors.

### What is stable enough to expose, and what is not

The physical IR is not stable, and the design documents say so:
- [lowering_and_pipeline.md](lowering_and_pipeline.md) §2.2 calls it the interim IR and lists six
  changes still to come: `parquet_spec_is_total` goes, the `ParamTable` indices become inline sink
  parameters, `cancel_slot` and `error_slot` go, logical subtrees become pipeline references, a wire
  form replaces the version door, and each pipeline gets a memory budget. Every one of them breaks
  a plan written against today's fields.
- The version door is an exact match. A producer and the executor must be the same build.
- The IR changes about weekly. Commits since 2026-10-01 (`git log --since=2026-10-01 --oneline --
  <dir> | wc -l`): `physical_plan` 12, `lowering` 25, `pipeline_exec` 23.

So:
- **Exposed.** The builder's own vocabulary:
  - `PhysicalPlan` and `PipelineId` (an id, not an `Int`);
  - the sources: `parquet` now, and CSV and JSON with surface A's;
  - the operators `filter`, `project` and `limit`;
  - the sinks `hash_aggregate` and collect, then `sort`, `top_n` and `hash_join`;
  - the expressions: `col`, `lit`, comparisons, arithmetic, `and`, `or`, `not`, `is_null`;
  - the aggregates `count_rows`, `count`, `sum_of`, `min_of`, `max_of`, `mean_of`;
  - `Schema` and `RecordBatch` from `arrow`.

  These words name what the executor does: a pipeline ends at the sink that breaks it,
  lowering_and_pipeline.md §2.3. They outlast any one layout of the IR *(inferred)*.
- **Not exposed.** `SegmentDescPod`, `SourceSpecPod`, `MorselOp`, `ParamTable`, sink indices, edge
  tags, `ir_version`, key type and orientation tags, order keys, morsel sizes, the estimates and the
  slots. The builder writes them. When the IR changes, the change updates the builder and its welded
  tests in the same pull request, because `komira` is built in this repository. A user's program
  does not change.

One design statement bears on B. lowering_and_pipeline.md (§2.2, "Exit condition") says no consumer
of the interim IR exists outside `pipeline_exec`, and nothing serializes a `LoweredPlan`, until the
self-contained IR lands. B adds a second producer, in the same process and the same build, and
nothing serializes its plans. This document reads that as allowed. If the owner reads the exit
condition as also closing the IR to a second producer, B waits for the self-contained IR (decision
D6).

### Which libraries B needs

**B lives in the same package**, as the module `komira.physical`, over the same `Session`. Every
library it imports is already in A's closure of 86:
- `physical_plan`, `plan_expr`, `plan_ir`;
- `lowering`, for `LoweredPlan` and `ParamTable`;
- `pipeline_exec`, for `LocalOnlyScanFs`;
- `parquet_footers`, for the schema of a source;
- `sdk_exec` and `arrow`.

So B adds no library to publish (§4). The one change outside `komira` is the executor check above,
in `physical_plan` and `pipeline_exec`.

**A separate package without the SQL front end is possible, but not recommended now.** The executor
alone is smaller. Computed the same way as §4:
- `pipeline_exec`'s closure is 69 libraries, 45 of them unpublished, with no `sql`, `optimizer` or
  `lowering`;
- `lowering`'s is 21.

The door B uses needs `EngineContext`, though, which holds the SQL catalog (`sql`) and the footer
cache (`parquet_footers`, whose closure has `sql` and `lowering`). A package without them needs an
execution context outside `sdk_exec`. Since A publishes every library B needs anyway, that split
saves nothing on the road this document sets *(inferred)*.

### How B is tested

The tests are the same kind as A's (§7, §8):
- **The README example.** The README of `komira` gains the plan above, writing its Parquet file
  first with surface A's `COPY`. It asserts the rows, so the README e2e runs it against the installed
  packages.
- **Welded tests.**
  - The same query through A and through B gives the same rows.
  - Each submit refusal of the table above is asserted by its exact message: an unknown column, a
    filter that is not boolean, a sum over a string, an unserved sink, a result pipeline that is
    not the root, and a pipeline that reads the output of a pipeline that does not exist.
  - Under the executor change, a hand-made `LoweredPlan` with an unserved sink and one with a stray
    root are refused before any pipeline runs.

## 3. Surface C: the typed SDK

A typed program has a schema that is a compile-time value. A column is named by type parameters,
so a missing column is a compile error. The compiler specialises each operator for the program's
key and aggregate types. [lowering_and_pipeline.md](lowering_and_pipeline.md) §4.1 names this as
the shape the typed operator tables are for, and explains why a run-time plan cannot use them.

What **EXISTS**:
- the operator tables `op_agg_stage`'s `HashAggTable[KB, *Aggs]`, `op_sort`'s `Stage_Sort`, and
  `op_window`'s top-n stages;
- the `ExprX` traits and the `Stage[Program]` vocabulary in `expr`;
- the compile-time schema descriptor in `plan_expr.typed_schema`;
- `sdk.auto_schema`'s `derive_schema[T]()`, which makes a descriptor from a Mojo struct.

What does not exist is its front end: a typed frame, typed columns, and the driver that runs a typed
program from a source to a sink. The port left them out on purpose ("Typed execution path not
kept", [port_audit/sdk_group.md](port_audit/sdk_group.md)). No test runs a typed program end to end.
The tests drive one typed operator at a time by hand.

C is later, with a design of its own. It needs the front end written, and it runs on the typed
tables, not on the physical plan A and B share. It would publish its own libraries (`eval`, `op_agg_stage`
and `op_join_stage` among them) beyond A's; `expr`, `op_sort` and `op_window` are already in A's
closure. `op_typed_source_api` is not part of C: its
"typed" means a source whose file system is a type, not a schema.

## 4. The exact closure

### How it was computed

From the BUCK graph, not estimated:
- `./buck2 uquery "deps(//src/sdk_exec:sdk_exec)" --output-attribute deps --output-format json`
  (a query, not a build).
- Then the `deps` attribute was walked transitively from `//src/sdk_exec:sdk_exec`. Only Mojo
  library targets were kept (`mojo_library`, and `mojo_adopted_library` with the deps of its
  `:lib`).
- Test dependencies are left out, because `test_deps` never reach a package.
- For each library the result was matched to `PACKAGES` (published) and to the row of
  `release/UNPUBLISHED.md` (not published, with its reason).

The result:

| | libraries |
|---|---|
| `sdk_exec`'s closure | **93** |
| published (in `PACKAGES`) | 32 |
| not published | 61 |
| of the 61: depends on an unpublished library | 36 |
| of the 61: no README example | 17 |
| of the 61: native dependency pending | 6: `async_rt`, `fs`, `http_core`, `objectstore`, `parquet_codec`, `scan_source` |
| of the 61: none (ready now) | 2: `arrow`, `secret_store` |

Three facts about the graph:
- **The declared `deps` are incomplete.** `sdk_exec`'s own `deps` list 87 of the 93. The other 6
  (`decimal_literal`, `iceberg`, `op_agg_hash`, `op_fused_kernels`, `op_join_build`, `rowcell`) are
  reached only through its dependencies. Rule M11 asks for the full closure. Slice 0 adds the 4 of them that
  stay in the recommended closure (`iceberg` and `rowcell` leave it).
- **The ledger's import lists can be shorter.** For several libraries the "imports" in
  UNPUBLISHED.md (each library's own imports) name fewer libraries than its BUCK `deps` (which hold
  the full closure). Two examples:
  - `sdk`: the ledger names 8, and BUCK adds `agg`, `arrow_ipc`, `expr`, `kernels`, `op_agg_state`,
    `parquet_codec` and `plan_stats`;
  - `pipeline_exec`: BUCK adds 10.

  The order below follows BUCK, so it never publishes a library before something it builds with.
  Some libraries could go a wave earlier by their imports alone.
- **Iceberg brings in the whole HTTP stack.** One module of `sdk_exec`, `engine_iceberg.mojo`
  (`register_iceberg_table`), imports `iceberg_catalog`. That alone brings in `http_client`,
  `http_core` (with s2n-tls), `net` and `iceberg`. No other module of `sdk_exec` imports any of
  them. SQL's `iceberg_scan('<path>')` does not need them: `engine_lower.mojo` imports `iceberg_scan`,
  which stays.

### The recommended closure: without `engine_iceberg`

**PROPOSED** (decision D2): slice 0 moves `engine_iceberg.mojo` into a library of its own,
`sdk_exec_iceberg`.
- `src/so/bindings.mojo`, its one user outside `sdk_exec`, imports it from there.
- Its README moves with it.
- It takes a row in UNPUBLISHED.md ("depends on an unpublished library": `iceberg_catalog`,
  `sdk_exec`).

The same walk over the imports of `sdk_exec`'s other modules then gives:

| | libraries |
|---|---|
| closure | **86**, plus `sdk_exec` |
| published | 30 (`rowcell` and `uuid` leave the closure) |
| to publish | **56**, then `sdk_exec`, then `komira`: **58 packages** |
| of the 56: depends on an unpublished library | 33 |
| of the 56: no README example | 16 |
| of the 56: native dependency pending | 5: `async_rt`, `fs`, `objectstore`, `parquet_codec`, `scan_source` |
| of the 56: none | 2: `arrow`, `secret_store` |
| left for slice 8 (Iceberg catalogs) | `http_client`, `http_core`, `iceberg`, `iceberg_catalog`, `net`, `sdk_exec_iceberg` |

The split matters most for `http_core`. It is the one native library with no path in a single pull
request: s2n-tls built on komira's renamed aws-lc (`komira_s2n_*` called by `external_call`) would
become a new `native_library`, and its renaming build runs on linux-x86_64 only today. Leaving it out
of the first slice keeps the hardest native step off the road to the first query.

### Published already (30 of the 86)

`async_api`, `atomic_alias`, `awslc`, `byte_buffer`, `clock`, `compression`, `containers`, `counters`,
`crypto`, `dynamic_filter`, `encoding`, `fork_join`, `hashing`, `host_probe`, `json`, `libc`, `log`,
`lz4`, `metrics`, `name_registry`, `parquet_api`, `plan_proto`, `proto_codec`, `protobuf`,
`scalar_arithmetic`, `simd_ops`, `spsc_ring`, `sync`, `trace`, `zlib`.

`sdk_exec`'s `deps` also name `runtime_paths` (published) through the alias
`//tools/build/mojo/runtime_paths`. No source of `sdk_exec` outside `tests/` imports it, so it is a
test dependency. The walk does not count it, and a package lists it under `[dev-dependencies]`, as
`log` does.

### The 56, in publishing order

The wave of a library is one more than the highest wave among its unpublished BUCK `deps`. Wave 1
needs only published libraries. Libraries in the same wave do not depend on each other, so they can
go in one pull request or in several. Earlier moves have put five to nine libraries in one pull
request (komira-ai/komira#2006 moved nine).

The columns:
- "reason today" is UNPUBLISHED.md's reason.
- "coverage" is the line coverage in the library's own `coverage_census.tsv`, measured by the census
  of 2026-10-10 (`csv`'s of 2026-10-27). "not measured" means the library has no census file. These
  numbers are old. The pull request's check measures again, and rule T1 holds every touched package
  to 99% line and 99% branch.
- "unpublished deps" counts the library's BUCK `deps` among the 56.
- "work before or in its pull request" lists the work. "claim the name" means a maintainer claims
  `komira-ai/<name>` on the prod registry first, a step outside the repository
  (`release/prod_claimed_names.txt`). The release refuses a member whose name is not claimed.

| wave | library | reason today | coverage | unpublished deps | work before or in its pull request |
|---|---|---|---|---|---|
| 1 | `arrow` | none | 67.8% | 0 | tests to reach 99% line and branch |
| 1 | `phase_timers` | no README example | not measured | 0 | write a README `mojo` example; measure coverage; reach 99% if short; claim the name |
| 1 | `secret_store` | none | 100.0% | 0 |  |
| 2 | `arrow_ipc` | depends on an unpublished library | 86.1% | 1 | tests to reach 99% line and branch |
| 2 | `column_format` | depends on an unpublished library | 77.6% | 1 | tests to reach 99% line and branch |
| 2 | `exec_types` | no README example | 47.3% | 1 | write a README `mojo` example; tests to reach 99% line and branch; claim the name |
| 2 | `plan_expr` | depends on an unpublished library | 54.4% | 1 | tests to reach 99% line and branch |
| 2 | `secret_registry` | depends on an unpublished library | 98.5% | 1 | tests to reach 99% line and branch |
| 3 | `column_kernels` | depends on an unpublished library | 67.0% | 2 | tests to reach 99% line and branch |
| 3 | `decimal_literal` | no README example | not measured | 1 | write a README `mojo` example; measure coverage; reach 99% if short; claim the name |
| 3 | `json_index` | no README example | 100.0% | 2 | write a README `mojo` example; claim the name |
| 3 | `parquet_codec` | native dependency pending | 96.0% | 2 | package the vendored Brotli decoder as a static archive with a `native_library`, as snappy is; tests to reach 99% line and branch; claim the name |
| 3 | `plan_stats` | depends on an unpublished library | 57.6% | 2 | tests to reach 99% line and branch |
| 3 | `udf` | no README example | 17.5% | 2 | write a README `mojo` example; tests to reach 99% line and branch; claim the name |
| 4 | `agg` | no README example | 92.4% | 2 | write a README `mojo` example; tests to reach 99% line and branch; claim the name |
| 4 | `kernels` | depends on an unpublished library | 52.7% | 4 | tests to reach 99% line and branch; claim the name |
| 4 | `parquet_writer` | depends on an unpublished library | not measured | 3 | measure coverage; reach 99% if short; claim the name |
| 4 | `scan_source` | native dependency pending | 63.2% | 4 | package its own C (`native/komira_scan_source_inmem_id.c`) as a static archive; tests to reach 99% line and branch; claim the name |
| 5 | `expr` | no README example | 100.0% | 4 | write a README `mojo` example; claim the name |
| 5 | `plan_ir` | depends on an unpublished library | 88.5% | 4 | tests to reach 99% line and branch; claim the name |
| 5 | `row_format` | depends on an unpublished library | 96.3% | 3 | tests to reach 99% line and branch; claim the name |
| 6 | `agg_api` | no README example | 28.7% | 4 | write a README `mojo` example; tests to reach 99% line and branch; claim the name |
| 6 | `batch_eval` | no README example | not measured | 6 | write a README `mojo` example; measure coverage; reach 99% if short; claim the name |
| 6 | `join_assembly` | depends on an unpublished library | 64.7% | 4 | tests to reach 99% line and branch; claim the name |
| 6 | `physical_plan` | depends on an unpublished library | 97.2% | 5 | tests to reach 99% line and branch; claim the name |
| 6 | `plan_wire` | depends on an unpublished library | 99.7% | 5 | claim the name |
| 7 | `async_rt` | native dependency pending | 86.2% | 3 | package its own C (`reactor/_posix_shim.c` and the `_sched_labels.inc` it includes) as a static archive; tests to reach 99% line and branch; claim the name |
| 7 | `host_profile` | depends on an unpublished library | not measured | 2 | measure coverage; reach 99% if short; claim the name |
| 7 | `morsel` | depends on an unpublished library | 96.2% | 9 | tests to reach 99% line and branch; claim the name |
| 7 | `op_agg_state` | depends on an unpublished library | 99.9% | 7 | claim the name |
| 8 | `fs` | native dependency pending | 98.8% | 3 | package its own C (`_fs_shim.c`) as a static archive; tests to reach 99% line and branch; claim the name |
| 8 | `jsonl` | depends on an unpublished library | 99.6% | 6 | claim the name |
| 8 | `lowering` | no README example | not measured | 7 | write a README `mojo` example; measure coverage; reach 99% if short; claim the name |
| 8 | `op_agg_hash` | no README example | not measured | 7 | write a README `mojo` example; measure coverage; reach 99% if short; claim the name |
| 8 | `op_sources` | no README example | not measured | 7 | write a README `mojo` example; measure coverage; reach 99% if short; claim the name |
| 8 | `operator_api` | no README example | not measured | 11 | write a README `mojo` example; measure coverage; reach 99% if short; claim the name |
| 9 | `avro` | depends on an unpublished library | 99.3% | 4 | claim the name |
| 9 | `csv` | depends on an unpublished library | 83.2% | 6 | tests to reach 99% line and branch; claim the name |
| 9 | `objectstore` | native dependency pending | 83.6% | 2 | package its own C (`_objectstore_shim.c`) as a static archive; tests to reach 99% line and branch; claim the name |
| 9 | `parquet` | depends on an unpublished library | 99.9% | 7 | claim the name |
| 9 | `scan_planning` | depends on an unpublished library | 75.2% | 3 | tests to reach 99% line and branch; claim the name |
| 10 | `iceberg_scan` | depends on an unpublished library | not measured | 16 | measure coverage; reach 99% if short; claim the name |
| 10 | `optimizer` | no README example | 100.0% | 11 | write a README `mojo` example; claim the name |
| 10 | `sdk` | depends on an unpublished library | 99.0% | 15 | claim the name |
| 10 | `shuffle` | depends on an unpublished library | 85.8% | 1 | tests to reach 99% line and branch; claim the name |
| 10 | `sql` | depends on an unpublished library | 99.9% | 18 | claim the name |
| 11 | `engine_runtime` | no README example | not measured | 12 | write a README `mojo` example; measure coverage; reach 99% if short; claim the name |
| 11 | `parquet_footers` | depends on an unpublished library | not measured | 23 | measure coverage; reach 99% if short; claim the name |
| 12 | `op_join_build` | depends on an unpublished library | not measured | 6 | measure coverage; reach 99% if short; claim the name |
| 12 | `op_sort` | depends on an unpublished library | not measured | 10 | measure coverage; reach 99% if short; claim the name |
| 12 | `parquet_scan` | depends on an unpublished library | not measured | 15 | measure coverage; reach 99% if short; claim the name |
| 13 | `op_fused_kernels` | depends on an unpublished library | not measured | 9 | measure coverage; reach 99% if short; claim the name |
| 13 | `op_spill_rows` | depends on an unpublished library | not measured | 19 | measure coverage; reach 99% if short; claim the name |
| 13 | `op_window` | no README example | not measured | 12 | write a README `mojo` example; measure coverage; reach 99% if short; claim the name |
| 14 | `op_join_probe` | depends on an unpublished library | not measured | 16 | measure coverage; reach 99% if short; claim the name |
| 15 | `pipeline_exec` | depends on an unpublished library | not measured | 37 | measure coverage; reach 99% if short; claim the name |
| 16 | `sdk_exec` | depends on an unpublished library | not measured | 56 | measure coverage; reach 99% if short; claim the name |
| 17 | `komira` | new | new | 57 | the package of §1 with its README example; claim the name |

### What each kind of row takes

- **One pull request each, nothing before it except its wave.** These need only their place in the
  order and a claimed name: `secret_store`, `plan_wire`, `op_agg_state`, `jsonl`, `avro`, `parquet`,
  `sdk`, `sql`. The rest of a "depends" row's work is the move itself. That move is what the
  `mopm_migrate` tool does: the layout `src/<name>/src/<name>/`, then `mopm.toml`,
  `mopm-toolchain.toml`, `mopm.lock`, `buildrules.mojo.bzl` and its lock, `coverage_floor.txt`, the
  `PACKAGES` and `mopm_native_ids.bzl` rows, the UNPUBLISHED.md row deleted with its count, and the
  dependents' rows rewritten ([tools/build/mopm_migrate/README.md](../../tools/build/mopm_migrate/README.md),
  [release/UNPUBLISHED.md](../../release/UNPUBLISHED.md)).
- **A README example to write (16).** The release refuses a package whose README holds no `mojo`
  example. Most of these are engine internals (`lowering`, `op_window`, `engine_runtime`, ...), so
  the example shows the library's own public call on a small input, as the published packages'
  READMEs do. It can be written in the same pull request as the move.
- **Coverage first (25 below 99% by the old census, 20 not measured, 11 at or above 99%).** T1 holds a touched package
  to 99%, and a move touches every file. *(inferred)* This is the largest part of the work: `arrow`
  (67.8% of 7,042 lines), `column_kernels` (67.0% of 7,061) and `udf` (17.5% of 674) are the
  biggest gaps. The real numbers come from each pull request's check.
- **Native code to package (5).** `mopm_migrate` refuses a library that owns C or links one, so
  each of the five is moved by hand, after the published precedents. Each one's C must also build
  for macOS, since the pull request check builds every package's library for darwin-arm64
  (AGENTS.md, "The macOS part of the pull request check").

  | library | wave | native code | route (precedent) | libraries of the 56 that wait for it |
  |---|---|---|---|---|
  | `parquet_codec` | 3 | none of its own; it links the vendored Brotli decoder (`//third_party/brotli:brotlidec`, symbols renamed `komira_brotli_*`) | the vendored library as a static archive with buildrules' `native_library`, as `compression` did for snappy (komira-ai/komira#2034); decision D4 | 8 |
  | `scan_source` | 4 | `native/komira_scan_source_inmem_id.c`, 16 lines, one counter | own C as a `[native.<id>] kind = "static"` archive (`libc`, `log`, `metrics`, `async_api`) | 37 |
  | `async_rt` | 7 | `reactor/_posix_shim.c`, 3,280 lines, which includes `reactor/_sched_labels.inc`; it already branches on `__APPLE__` and `__linux__` | the same, with the `.inc` file shipped beside the C *(inferred: no published static native has a header to carry yet)* | 24 |
  | `fs` | 8 | `_fs_shim.c`, 676 lines | the same | 20 |
  | `objectstore` | 9 | `_objectstore_shim.c`, 374 lines; it calls `fs`'s shim symbols | the same, with `fs` as a dependency | 10 |

  The last column counts the libraries whose BUCK closure holds the native library, and `sdk_exec`
  and `komira` wait for all five. Each is one pull request *(inferred)*. `async_rt` is the largest
  C, and `scan_source` holds back the most libraries.
- **Names to claim (50 of the 58).** Already claimed: `arrow`, `arrow_ipc`, `column_format`,
  `column_kernels`, `plan_expr`, `plan_stats`, `secret_registry`, `secret_store`. The other 50,
  `komira` among them, need the owner's step on the registry ahead of their pull requests. That step
  is the owner's, not this repository's.

*(inferred)* The lower bound is 15 publishing pull requests (one per wave of the 56), then `sdk_exec`
and `komira`. Five of them carry a native move. The coverage and README work comes before or within
them. Libraries of one wave that are ready can share a pull request, and a library that needs tests
first goes in a later one of the same wave.

## 5. The Mojo rules, and what a user's build needs

How `komira` obeys the rules:
- **M1, no pointer type in a public API.** None of the four names takes or returns a pointer.
  - `Session` holds its `EngineContext` in a private field.
  - `Result` lends its batch as `ref [self] RecordBatch`.
  - `Files` holds a `String`.
  - Surface B's `komira.physical` exposes only its own values (`PhysicalPlan`, `PipelineId`, its
    `Expr` and aggregates) and `arrow`'s `Schema` and `RecordBatch`. The IR it emits is pointer-free
    in its public fields too (`physical_plan.mojo`'s header: inert data, no `UnsafePointer`), and
    `Expr` keeps its `OwnedPointer` children in private fields.
  - The `sdk_exec` calls it wraps take and return values. A search of `engine_*.mojo`,
    `arrow_result.mojo`, `run_control.mojo` and `sdk/table_display.mojo` for `UnsafePointer`,
    `OpaquePointer` and the wildcard origins finds none.
- **M3 to M10.** `komira` has no `UnsafePointer`, no wildcard origin, no FFI and no slab. Native
  code stays in the five owners above, each behind its own pointer-free functions (M9). `//:pointer_lint`
  runs over it like every library under `src/`.
- **M11, packaging is `.mojoc`.**
  - `komira` is a `mojo_package` from its first commit, so its library is a `.mojoc` and its
    package is a `.conda` with `mopm.toml`.
  - Its BUCK `deps` are the whole closure: `sdk_exec` and its 86.
  - Its `mopm.toml` `[dependencies]` names only what it imports: `sdk_exec`, `sdk` (for
    `format_table`), `arrow`, `column_kernels` and `compression`. With surface B it also names
    `physical_plan`, `plan_expr`, `plan_ir`, `lowering`, `pipeline_exec` and `parquet_footers`, all
    already in the closure. mopm resolves the rest from each
    package's own dependencies (`>=0.1,<0.2` per dependency, [docs/ci.md](../ci.md)).
- **M15, T6, T18.** Every file stays under 1,000 lines, every test file is in `test_srcs`, and every
  public name appears in a README example.

A user's build needs:

| | what | where it is fixed |
|---|---|---|
| Mojo | `1.1.0`, the one Mojo every package is built for | `MOJO` in [packages.bzl](../../release/readme_e2e/packages.bzl), `mojo = ["1.1.0"]` in each `mopm.toml` |
| mopm | a mopm with pixi on `PATH`; the repository builds and tests with mopm 0.0.138 | `MOPM` in packages.bzl, `mopm-toolchain.toml` |
| the project | `mopm init`, `[toolchain] mojo = "1.1.0"` (init writes mopm's own default, and `mopm add` resolves the newest build for the project's Mojo), `mopm add komira-ai/komira`, `mopm sync` | the `prod-add` job ([docs/ci.md](../ci.md)) |
| platform | Linux on x86_64 or macOS on arm64. No linux-arm64 package exists for any library yet | [docs/releases.md](../releases.md) |
| host | *(inferred)* what the Python wheel needs on Linux: glibc 2.35 or newer and an x86-64-v3 CPU, since both are built by the same toolchain for the same target CPU | [docs/install.md](../install.md), [mojo_rules_and_toolchain.md](mojo_rules_and_toolchain.md) |
| system libraries | `compression` opens libzstd, libbz2 and liblzma, and `zlib` and `lz4` open libz and liblz4, at run time. Each package declares them as `[native-dependencies]`, so `mopm sync` installs them from conda-forge | those packages' `mopm.toml`, `tools/build/package/system_libs.bzl` |

A user adds one package, `komira-ai/komira`, and nothing else: its dependencies come with it.
The natives are static archives inside the packages, which `mopm build` links
([tools/build/readme_e2e/README.md](../../tools/build/readme_e2e/README.md), "link").

## 6. The relation to the C ABI

The route from the optimizer down is the same for all three languages:

```
Python Session.sql ──┐
                     ├── komira_sql_stream ── so.sql_result ── sdk_exec.run_sql_with ──┐
Node   Session.sql ──┘                                                                  │
                                                                                        ├── parse, bind,
Mojo   Session.sql ────────────────────────────────────────── sdk_exec.run_sql ─────────┘   then run_plan_batch:
                                                                                            optimize, lower, execute
```

- **Python and Node.** `komira_sql_stream` calls `so`'s `sql_result`. That function probes the codec
  libraries, builds the object-store opener from the session's credentials, and calls `run_sql_with`.
  Then `arrow_result` and `build_record_batch_stream` hand the batch across as an Arrow C stream
  ([libkomira_run_abi.md](libkomira_run_abi.md)).
- **Mojo.** `komira.Session.sql` calls `run_sql` in the same process, with no C call in between.
  `run_sql` is `run_sql_with(..., LocalOnlyScanFs())`. From `run_plan_batch` down, optimize, lower
  and execute are the same code.

What differs for a Mojo caller:

| | Python and Node (libkomira) | Mojo (`komira`) |
|---|---|---|
| the result | an Arrow C stream that crosses the C boundary; `arrow_result` refuses a column the export cannot carry | the `RecordBatch` itself, no export, so no such refusal |
| errors | a status code, then `komira_last_error`, `_code` and `_step`; the binding raises its own error type | `raises` with the same `<step>: <reason>` text |
| input checks | the C layer bounds text at 64 MiB and checks NUL bytes and UTF-8 | a Mojo `String`, so those checks do not apply; the engine's own limits (parse depth, plan bytes) still do |
| options | `komira_ctx_new_with_options`: two integers | `Session(threads, memory_limit)`, the same two; `EngineOptions.spill_directory` is a later, additive argument |
| threads | one thread per handle at a time; Python adds a lock, Node a session thread | the compiler holds it (`mut self`) |
| cancel and progress | a run handle (`komira_run_new`, ABI 1.6) | `RunControl`, which **EXISTS** in `sdk_exec`; a later `sql` overload |
| remote stores and credentials | `so`'s bindings and credentials | not in the first slices (slice 7) |
| native code | one `libkomira.so` linked on its native owners, loaded by the binding | static archives in each package, linked into the user's program by `mopm build` |
| abort containment | libkomira probes codec libraries before each run; a fail-fast abort still ends the host | `Session()` probes once; a fail-fast abort ends the program |

The SDK adds no C call and changes no libkomira behaviour. A plan built in Mojo later (the frame
API) would take the plan door, `run_plan`, which is libkomira's `komira_plan_stream` door too.

Surface B has no C counterpart. libkomira has two doors, SQL text and a logical plan, and both go
through the optimizer and lowering. B enters below them, at `run_lowered_plan_with`. From there
down it is the same executor and the same segment builder as every other route. B never crosses a
process or a build, so the physical IR needs no wire form for it.

## 7. How a Mojo example is tested as a stranger runs it

Two tests run every README example of `komira`, and both run in the pull request check.

1. **The welded README gate (EXISTS for every library).** Each `mojo` fence of the README is cut
   into a program, compiled against the library's `.mojoc` and its closure in the build, and run.
   The library's package exists only once these pass ([tools/build/mojo/README.md](../../tools/build/mojo/README.md)).
2. **The README e2e against the installed packages (EXISTS: `//release/readme_e2e/verify:<name>`).**
   It is what a stranger does, run offline
   ([tools/build/readme_e2e/README.md](../../tools/build/readme_e2e/README.md)):
   - it makes an empty project (`mopm.toml` with a name and version, `[toolchain] mojo` and an empty
     `[dependencies]`);
   - it runs `mopm add komira-ai/komira@=<version> --overlay <staged set>`, the same `.conda` files
     the release uploads. `--registry` points at a loopback server that serves only the registry's
     configuration and refuses every other request, so a package outside the staged set fails the
     run;
   - it checks each locked file against the staged one byte for byte;
   - it unpacks the prefix and links the static archives mopm names;
   - it compiles each README example with the pinned Mojo with only the installed prefix on the path,
     and runs it through the welded tests' runner (`gate mojo`) with an empty `share/` directory of
     its test root as the working directory.

   `//release/readme_e2e/verify:all` is in `//ci:pr`. When `komira` has a `mopm.toml` it is a member
   of `PACKAGES`, and `//:readme_e2e_complete` refuses the tree until it is covered, so its e2e
   cannot be left out.

What the tool gives an example, and what the example does:
- **No data files.** The e2e gives an example no files, so the README example writes its own Parquet
  file first, with SQL, into that working directory *(inferred: the runner's test root is a directory
  it made, so writable; the welded README gate already runs `sdk_exec`'s `COPY` examples)*.
  `COPY (SELECT ...) TO 'trips.parquet'` already **EXISTS** in `run_sql`, and `sdk_exec`'s README
  uses it. This is the rule for every documentation example: "the example writes
  its own sample data into its working directory, so a page hides no input"
  ([documentation_tests.md](documentation_tests.md)). No change to the e2e tool is needed.
- **No output comparison.** The e2e judges an example by its exit status, and an example asserts in
  its own code (`std.testing`). So the example asserts the rows it reads back (the row count and
  each value) and also prints the table. Comparing printed output exactly waits for
  documentation_tests.md's `expected_output.txt` for READMEs. When that exists the printed table is
  compared too, and it becomes the text the page of §1 shows.

The example of slice 1, *(PROPOSED)*:

````markdown
<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira import Session, files

var session = Session()
_ = session.sql("COPY (SELECT 'Lisbon' AS city UNION ALL SELECT 'Oslo' UNION ALL SELECT 'Oslo') TO 'trips.parquet'")
session.add_sql_binding("trips", files("trips.parquet"))
var result = session.sql("SELECT city, count(*) AS trips FROM trips GROUP BY city ORDER BY city")
assert_equal(result.num_rows(), 2)
print(result)
```
````

The release adds one more check. *(PROPOSED)* `komira` joins the list of packages the `prod-add`
job adds from the prod registry after each release ([docs/ci.md](../ci.md), "prod-add"). Every
release then also proves that the real registry serves `komira-ai/komira` and its closure to
`mopm add` and `mopm sync`. That job runs in the release workflow, not in the pull request check
(rule B9).

## 8. Tests of the library itself

The welded tests in `src/komira/tests/`, each in `test_srcs` (T6), cover the following.

The happy path:
- one session, one binding, one query, over a Parquet file the test writes with `COPY`;
- a glob and a directory of two files;
- binding a name again replaces it;
- two sessions in one process share nothing;
- `Result` over zero rows, and over more than 20 rows (the printer's "more rows" line).

Refusals, each asserted by the exact message:
- a parse error (step `parse`, with the line and column);
- an unknown table (`bind`);
- a missing file;
- a glob that matches nothing (`PARQUET_GLOB_NO_MATCH`);
- `files("")`;
- `files("s3://...")` (`STORAGE_URL_REFUSED`);
- `Session(threads=0)` and `Session(memory_limit=0)` (`ENGINE_OPTIONS_INVALID`).

That list covers each branch of the four names: each argument's refusal, each step `sql` can fail
at, and each way a binding can fail. Everything beneath those branches is `sdk_exec`'s, already
tested there.

## 9. Slices, in order

| slice | what lands | ends with |
|---|---|---|
| 0 | one pull request: `engine_iceberg.mojo` moves to `sdk_exec_iceberg` (decision D2), `src/so` imports it from there, and `sdk_exec`'s `deps` drop `iceberg_catalog` and gain the 4 libraries of the 86 they lack, `decimal_literal`, `op_agg_hash`, `op_fused_kernels` and `op_join_build` (M11). No behaviour changes | `sdk_exec`'s closure is the 86 of §4 |
| 1 | the 56 in the order of §4, then `sdk_exec`, then `komira` with the surface of §1, its tests (§8) and its README example (§7) | **the stranger-shaped test**: `//release/readme_e2e/verify:komira` installs `komira-ai/komira` and its closure from the staged set into an empty project, compiles the README example against the installed packages only, and runs one query over one local Parquet file; then `prod-add` does `mopm add komira-ai/komira` from the prod registry on the next release |
| 2 | A: the Mojo examples of the task pages ([docs/tasks/](../tasks/README.md)): the SQL-only tasks written in Mojo, each run from the installed packages like the README e2e | the owner's gate for the three languages, for the tasks SQL can show |
| 3 | B: the executor's own checks: the sink capability table moves to `physical_plan` and `check_plan` refuses an unserved sink, and `run_lowered_plan_with` refuses a missing result or a stray root, both before any pipeline runs (§2) | a hand-made `LoweredPlan` with either fault refused by name |
| 4 | B: `komira.physical`: `PhysicalPlan`, `parquet`, `filter`, `project`, `limit`, `hash_aggregate`, collect, the expressions and aggregates, the checks at submit, and `session.run` (§2). No new library to publish | the README example of §2 run by the README e2e against the installed packages; the same query through A and B gives the same rows |
| 5 | B: `sort`, `top_n`, `output_of` and `hash_join` | a two-pipeline join plan run as written |
| 6 | A: `files` chooses the format from the extension (CSV, newline-delimited JSON), in step with Python ([credentials_and_writes.md](credentials_and_writes.md)) | CSV and JSON over the same four names |
| 7 | A: remote files and credentials: `files("s3://...", credential=...)`, the Mojo credential values and an opener over `objectstore_s3`, `gcs` and `azure_blob`. This brings in `http_core`, whose s2n-tls must first be a `native_library` (the hard native) | `run_sql_with` with an opener, the same as `so`'s |
| 8 | A: Iceberg catalogs: `sdk_exec_iceberg`, `iceberg_catalog` and the HTTP stack published, and the `iceberg` source of credentials_and_writes.md | a catalog table bound by name |
| 9 | a Mojo frame API: its own design, over `sdk`'s plan builders and `run_plan` (§1) | — |
| 10 | C: the typed SDK, its own design first: the front end over the typed operator tables (§3) | — |

Slice 1 has many pull requests and is the bulk of the work (§4, "What each kind of row takes"). It
is the one slice whose order the dependency graph fixes. The order after it is decision D6. Slice 4
needs slice 3, and slice 5 needs slice 4. Slice 2, the gate's examples, needs only slice 1, and
slices 6 to 8 can go in any order after it.

## Decisions for the owner

- **D1. The package name.** Recommended: `komira` (`komira-ai/komira`, `from komira import ...`),
  the name strangers know from PyPI and npm. The other choice is `komira_sdk`, which avoids a Mojo
  module named like the product but reads twice.
- **D2. Iceberg catalogs out of the first slice.** Recommended: move `engine_iceberg.mojo` to its
  own library (slice 0). This takes `http_core` (s2n-tls) and four more libraries off the road to
  the first query. The other choice keeps `sdk_exec` whole and publishes 61 plus 2 packages,
  `http_core`'s s2n-tls `native_library` among them, before any query runs. SQL's `iceberg_scan('<path>')`
  keeps working under either choice.
- **D3. The error a Mojo caller catches.** Recommended for the first release: `Error` whose text is
  libkomira's `<step>: <reason>`, the same in every language, with the named code at the start of
  the reason. The other choice is a typed `KomiraError` with `step` and `code` fields. No function in
  `src/` declares a typed raise today, and every library under `komira` raises `Error`, so a typed
  error would be the first and would need the pinned compiler's typed raises proven first. A typed
  error changes `sql`'s signature, so it is chosen before the first release or not at all.
- **D4. Brotli for `parquet_codec`.** Recommended: the vendored decoder as a static archive
  (`native_library`), as snappy is. It keeps the README's "neither library is needed at run time"
  and the renamed `komira_brotli_*` symbols the Mojo code calls. The other choice is conda-forge's
  `libbrotlidec`, opened at run time like libzstd. That changes the Mojo calls to a run-time load,
  and `mopm_migrate` refuses every dependent of a package with `[native-dependencies]` *(read in its
  README)*. The 8 libraries of the 56 above `parquet_codec`, then `sdk_exec` and `komira`, would all
  be moved by hand.
- **D5. The names on the prod registry.** 50 of the 58 names are not claimed (§4). Claiming a name
  is a registry step only the owner can take, ahead of each package's pull request.
- **D6. Which surfaces, and in what order.** Recommended: A first, B second, C later.
  - **A** is the gate's examples, and every library it publishes is one B and C need too.
  - **B** adds no library. It needs the executor's own checks (slice 3) and its builder (slice 4),
    and it reads lowering_and_pipeline.md's exit condition as closing the interim IR to a second
    consumer, not to a second producer in the same build (§2).
  - **C** needs a front end that the port left out, and it gets its own design.

  The other choices:
  - B before A's task pages (slice 2), if hand-written plans matter more than the gate.
  - B only after the self-contained IR, if the exit condition also closes the IR to a second
    producer.
  - No C at all.

## What this design does not change

- No libkomira call, no wire format and no Python or TypeScript behaviour.
- No published package changes. Publishing goes on as it does today: every push to main publishes
  each member of `PACKAGES` ([docs/releases.md](../releases.md)).
- Two documents disagree with the code they describe, and this design leaves them as they are:
  - [native_packaging.md](native_packaging.md) plans one shared library per native owner. The
    published natives are static archives in their packages, the route §4 follows.
  - Python's documented module-level `sql` and `register_parquet` are not exported
    ([python_package.md](python_package.md)).

  Each is for its own document's owner to settle.
