# Design: a breaker whose output schema is decided by the data

Status: design, not built. Nothing in this document exists in the code yet; every "today" names the file it
rests on. No komira code was built or run to write it. Statements about pandas, polars and Spark cite their
source files at a named release tag (pandas `v3.0.6`, polars `py-1.44.2`, the versions komira's skins
implement, [third_party/python/README.md](../../third_party/python/README.md); Spark `v4.0.0`), read from
the projects' repositories, and their documentation pages by URL. The only program run was DuckDB 1.1.3,
and each behaviour observed with it says so; that version is older than the pinned oracle (1.5.6,
[third_party/duckdb/README.md](../../third_party/duckdb/README.md)), and the slice that builds each
behaviour checks it against the pinned oracle (section 8).

The owner chose the approach (way 2 of section 7) before this document was written. This document
defines it, and the owner rules on the document before any slice is built.

## 1. The problem

A **pipeline breaker** is an operator that must see every input row before it emits one: a sort, an
aggregate, a distinct, a window, the build side of a join
([lowering_and_pipeline.md](lowering_and_pipeline.md), "breaker" in the cut table;
`src/lowering/cut_walk.mojo`). Every breaker komira has today still has an output schema that is known
when the plan is built. An aggregate's columns are its group keys followed by its measures, and their
types follow from the input's types (`LogicalPlan.aggregate`, `src/plan_ir/logical_plan.mojo`;
`src/plan_ir/schema_propagation.mojo`, header). The data decides the rows, never the columns.

A pivot whose values are not listed is a different kind of operator. In
`df.pivot_table(index="region", columns="product", values="amount")`, or in DuckDB's
`PIVOT sales ON product USING sum(amount)`, there is one output column per distinct value of `product`.
The output **schema** is the set of distinct values in the data, and it is unknown until the data is
read. Everything after the pivot needs that schema:

- resolving a name such as `pivoted["pen"]`;
- type checking (`pivoted["pen"] > 5` is only meaningful if `pen` exists);
- optimising (a filter cannot be pushed, and a projection cannot be pruned, over a column list nobody
  knows);
- lowering to operators with fixed layouts: a segment's sink parameters, its morsel sizing and its
  operators' expressions are all fixed by the plan's schemas at lower time
  (`src/lowering/lower.mojo`, `src/physical_plan/sink_data.mojo`).

komira refuses every such verb today:

- the pandas-shaped `DataFrame.pivot`, `pivot_table`, `unstack` (and `stack`, `melt`, `transpose`), and
  the module functions `komira.pivot_table`, `crosstab` and `get_dummies`, raise
  `AttributeError: ... is not supported yet: the plan has no node for it`
  (`python/komira/_refusals.py:62`, `:102`;
  [dataframe_surface_verbs.md](dataframe_surface_verbs.md), "The refusal tables");
- SQL `PIVOT` and `UNPIVOT`, in every form, listed values or not, are refused at the parser:
  `SQL not supported: PIVOT (reshaping a relation between long and wide form).`
  (`src/sql/sql_parser.mojo:1027`, tested at `src/sql/tests/test_sql_parser_statements.mojo:565`);
- the task pages show the workaround a user writes today, one `sum(CASE WHEN product = 'pen' ...)` per
  column, with the values spelled out by hand
  ([python/docs/tasks/51-make-pivot-table/page.md](../../python/docs/tasks/51-make-pivot-table/page.md),
  [53](../../python/docs/tasks/53-reshape-long-data-wide/page.md),
  [54](../../python/docs/tasks/54-cross-tabulate-two-columns/page.md)).

The SQL form with the values listed (`PIVOT (sum(amount) FOR product IN ('pen', 'ink'))`) is an ordinary
aggregate over `CASE` measures. It needs no new kind of operator, but it does not run today either: the
parser refuses the word `PIVOT` before it looks at the `IN` list.

## 2. The concept: a schema-deciding breaker

**Definition.** A *schema-deciding breaker* is an operator whose output column set (the names, their
number and their order) is a function of the **values** of its input, not only of its input's schema
and its own parameters. Like every breaker it must read its whole input before it emits a row. Unlike
every breaker komira has, the plan above it cannot be bound until it has.

**Its types are known, its names are not.** In every operation of this kind komira serves, the type of
each decided column is fixed by the plan: the measure's result type (nullable, because a cell may have
no rows) for a pivot, and the indicator type for `get_dummies`. Only the names and their number come
from the data. Section 3.4 uses this.

### 2.1 Which operations are of this kind

| operation | library and version read | of this kind? | why |
|---|---|---|---|
| `DataFrame.pivot_table(values, index, columns, aggfunc, ...)` | pandas 3.0.6, `pandas/core/frame.py` | **yes** | one column per distinct value of `columns`; pandas has no argument that lists them |
| `DataFrame.pivot(*, columns, index, values)` | pandas 3.0.6 | **yes** | as `pivot_table`, with one value per cell; a duplicate (index, column) pair is an error |
| `pandas.crosstab(index, columns, ...)` | pandas 3.0.6, `pandas/core/reshape/pivot.py` | **yes** | a `pivot_table` with `aggfunc=len` and `fill_value=0` when `values` is absent (`pivot.py:1103`) |
| `DataFrame.unstack(level=-1, fill_value=None, sort=True)` | pandas 3.0.6 | **yes**, but out of scope | the values of an index level become columns; komira frames have no index (section 9) |
| `pandas.get_dummies(data, prefix, prefix_sep, dummy_na, columns, sparse, drop_first, dtype)` | pandas 3.0.6, `pandas/core/reshape/encoding.py` | **yes** | one indicator column per distinct value; the rows are kept, not grouped |
| `Series.str.get_dummies`, `Series.str.split(expand=True)`, `DataFrame.transpose` / `T`, `json_normalize` | pandas 3.0.6 | yes, out of scope | section 9 |
| `LazyFrame.pivot(on, on_columns, *, index, values, aggregate_function, maintain_order, separator, column_naming)` | polars 1.44.2, `py-polars/src/polars/lazyframe/frame.py:8505` | **no** | `on_columns` is a required argument: the lazy frame is told the values, so the schema is static. The polars user guide says why: "A Polars `LazyFrame` always need to know the schema of a computation statically (before collecting the query)" ([docs.pola.rs, pivot](https://docs.pola.rs/user-guide/transformations/pivot/)) |
| `DataFrame.pivot` with `on_columns` omitted, `DataFrame.to_dummies` | polars 1.44.2 | yes, but not reachable | eager `DataFrame` methods; `komira.pl` has no eager frame ([dataframe_surface.md](dataframe_surface.md) section 1) |
| `PIVOT t ON c USING agg(x) GROUP BY g` (no `IN`) | DuckDB, [PIVOT statement](https://duckdb.org/docs/stable/sql/statements/pivot) | **yes** | "DuckDB will find the distinct values in each `ON` clause column and create one new column for all combinations" |
| `PIVOT t ON c IN (...) USING ...`, and the standard `FROM t PIVOT (agg FOR c IN (...))` | DuckDB; Spark [PIVOT clause](https://spark.apache.org/docs/latest/sql-ref-syntax-qry-select-pivot.html) | **no** | the values are listed; an ordinary aggregate |
| `df.groupBy(g).pivot(c)` (no values) | Spark 4.0.0 | **yes** | Spark collects the distinct values with a separate job before planning the rest (section 7.1) |
| `df.groupBy(g).pivot(c, values)` | Spark 4.0.0 | **no** | values listed |
| reading a CSV or JSON file whose schema is inferred, a Parquet file whose schema is in its footer | komira, DuckDB, polars, Spark | **no** | the data decides the schema, but at the **source**, before the plan exists: komira's readers read the footer or infer from a bounded prefix when they are called (`komira_parquet_schema`, `komira_csv_binding`, `komira_json_binding`; [dataframe_surface.md](dataframe_surface.md) section 2, "The schema is known at every step"). No operator inside a plan waits on it |
| `SELECT *` over such a source | all | **no** | the star expands at bind, against the schema the source declared |
| aggregate, sort, distinct, window, top-n, join build | all | no | ordinary breakers: schema known at build |
| `melt` / `unpivot` / `UNPIVOT`, `explode`, `value_counts`, `groupby().size()` | all | no | their columns are fixed by their arguments; the data decides only the rows |

A further test of the definition is a join whose output columns depend on data: no engine read for this
document has one, and the definition excludes it unless its column set depends on values.

### 2.2 How the operation is decomposed

Every operation of this kind komira serves splits into three parts, and only the middle one is new:

1. **the long form** `L`: an ordinary relation with a known schema. For a pivot it is the aggregate
   `GROUP BY index ∪ on` of the measures; for `crosstab` the count; for `get_dummies` the input rows
   themselves.
2. **the decision** `D`: the sorted list of distinct values of the `on` columns in `L`, bounded by a
   cap (section 4.5). `D` fixes the output schema.
3. **the reshape** `W(L, D)`: an ordinary operator once `D` is known. For a pivot it is an aggregate of
   `L` grouped by `index` with one measure per value `d` of `D` and measure, whose value is the cell of
   `d`, or the measure's `fill` when that cell has no row in `L` (section 3.1 says which frontend fills
   what); for `get_dummies` a projection of one `CASE` per value.

So the breaker is: run the plan below it to `L`, hold `L`, compute `D`, and then bind the rest of the plan
with `W(L, D)` as its source. The engine never runs a reshape operator with an unknown layout.

## 3. The logical plan

### 3.1 The node

A new plan node, `PLAN_WIDEN` (engine tag 21: tags 16 and 17 are retired and 18 to 20 are taken,
`src/plan_ir/logical_plan.mojo:162-197`), with one payload, `WidenData`:

| field | meaning |
|---|---|
| `child` | the input relation, bound, with its schema |
| `on: List[String]` | the columns whose values become output columns (one or more) |
| `index: List[String]` | the row key columns; empty for `get_dummies`, whose rows are the input's rows |
| `measures: List[AggExpr]` | one aggregate per value column and function (`sum(amount)`); empty for `get_dummies`. They are the frontend's own aggregates, so the pandas-shaped `sum` is `coalesce(sum(x), 0)` and a cell whose values are all NULL is 0, as in pandas (ruling 10 of [dataframe_surface.md](dataframe_surface.md)), while SQL's `sum` is DuckDB's |
| `separator`, `prefixes` | the naming rule's separator (empty means the rule's default: `_` for `DUCKDB`, pandas' `prefix_sep` default for `PANDAS_DUMMIES`) and `get_dummies`' prefixes, one per `on` column |
| `kind` | `AGGREGATE` (a pivot table, `crosstab`, DuckDB `PIVOT`), `UNIQUE` (pandas `pivot`: a second row for one cell is an error), `INDICATOR` (`get_dummies`) |
| `naming` | the rule that turns a value (and a measure) into a column name, one per frontend (section 3.5) |
| `fill: List[Optional[Literal]]` | per measure, the value of a cell with no row in `L`; absent means NULL. pandas' `pivot_table` and `pivot` fill nothing unless `fill_value=` is given (a missing cell is NaN even for `aggfunc="count"`); `crosstab` fills 0 (`pivot.py:1103`); the SQL binder fills each measure with its aggregate's empty-input value, so a `count` cell is 0 and a `sum` cell NULL, as DuckDB 1.1.3 answered |
| `pandas_dropna: Bool` | pandas' `dropna=True`, which does three things in `pivot_table` (`pivot.py`, `__internal_pivot_table`): rows whose `index` or `on` key is NULL are dropped before grouping, long-form rows whose measures are all NULL are dropped (`agged.dropna(how="all")`), and columns that are all NULL are dropped. The node does the first two in `L`, before `D` is decided; after them no decided column can be all NULL, so the third follows |
| `indicator_type` | the Arrow type of an indicator column (`get_dummies`' `dtype`, bool by default, `encoding.py:272`) |
| `max_columns: Int` | the cap on decided columns (section 4.5); 0 means the default, 10,000 |

The SDK builds the node and nothing else: it never runs engine work to build it. The node's own
parameters are bound at build: `on`, `index` and every measure's columns must exist in `child`, and a
missing one is refused at the verb that names it, as every verb does today
([dataframe_surface.md](dataframe_surface.md) section 6).

### 3.2 The plan above the node is unbound

Everything above a `PLAN_WIDEN` is **unbound**:

- Its expressions name columns by name (`EXPR_COL_REF`). A positional reference (`EXPR_COL_IDX`) is
  refused above the node, because positions mean nothing before the column list exists.
- It carries no output schema. The rule "every node has a schema" becomes: **every bound node has a
  schema; a node is bound unless a `PLAN_WIDEN` is below it.** A subtree that holds no `PLAN_WIDEN`
  (the other side of a join above the pivot, for example) stays bound and keeps its schema.
- In memory, the node's `output_schema` holds the part it knows, the `index` columns, and is marked
  undecided. The one type of the decided columns, when there is one (section 3.4), is derived from the
  measures or `indicator_type` and is not stored.
  On the wire the node carries no `output_schema`: the known part is derived from its child and `index`.

Construction already tolerates this. `LogicalPlan`'s construction-time inference never raises: a column
missing from a schema becomes a NULL placeholder, and "the plan VALIDATOR owns the 'no such column'
diagnostic" (`_infer_expr_field`, `src/plan_ir/logical_plan.mojo`; `PlanColRefFields`,
`src/plan_expr/expr_walk.mojo`). The design makes the placeholder explicit rather than relying on it: an
unbound node is a distinct state, not a node with a wrong schema, and binding (section 4.3) re-runs
every factory with the decided schema.

### 3.3 The wire

`plan.proto` changes additively (rule B8):

```proto
// plan.proto, new. A schema-deciding breaker (schema_deciding_breaker.md).
message WireWidenNode {
  WirePlan              child          = 1;
  repeated string       on             = 2;
  repeated string       index          = 3;
  repeated WireAggExpr  measures       = 4;
  WidenKindWire         kind           = 5;  // UNSPECIFIED refused
  WidenNamingWire       naming         = 6;  // UNSPECIFIED refused
  string                separator      = 7;  // naming's separator; empty = the rule's default
  repeated string       prefixes       = 8;  // get_dummies' prefix, one per `on` column
  repeated WireFill     fill           = 9;  // one per measure; an unset literal = NULL
  bool                  pandas_dropna  = 10;
  WireField             indicator_type = 11; // INDICATOR only
  uint32                max_columns    = 12; // 0 = the default, 10,000
}

// plan.proto, new. The fill of one measure's empty cells.
message WireFill {
  WireScalar value = 1;  // absent = NULL; WireScalar is plan.proto's literal value
}

// WirePlan's oneof node, appended after `step = 22`:
//     WireWidenNode widen = 23;
```

- **Where the unbound part lives.** In the same `WirePlan` tree, so one envelope still holds one plan and
  `komira_plan_render` renders it whole. A `WirePlan` node whose subtree holds a `widen` arm carries **no**
  `output_schema`; one that carries it is refused by name (`PLAN_WIRE_UNBOUND_SCHEMA_PRESENT`), because
  the decoder cannot check a schema it cannot derive. Every other node keeps today's rule: the decoder
  rebuilds it through its factory and refuses a divergent schema (`PLAN_WIRE_OUTPUT_SCHEMA_DIVERGED`,
  `src/plan_wire/plan_wire_codec.mojo:835`, `_check_output_schema` at `:3698`).
- **The context comes from the tree, not from a flag.** The decoder learns that a node is unbound from the
  `widen` arm below it, as [optimized_plan.md](optimized_plan.md) section 3 takes the RAW or OPTIMIZED
  context from the enclosing message and never from a flag a producer could set wrongly.
- **No version bump.** The arm and its message are new and optional, so the change is additive (rule B8),
  and `format_version` stays where it is (the accepted set is `{4, 5}` today,
  `plan_wire_supported_versions`, `src/plan_wire/plan_wire_codec.mojo`). `write_target` needed a bump because an
  older reader skips it and silently returns rows (`plan.proto:1877`); an older reader cannot skip a
  `widen` arm silently, because the arm is the node: it decodes a `WirePlan` with no `node` arm set and
  refuses it (`PLAN_WIRE_MALFORMED`, "a WirePlan with NO `node` arm set", `plan_wire_codec.mojo`). `kind`
  and `naming` refuse their `UNSPECIFIED` value, the rule for an enum whose value is needed
  ([optimized_plan.md](optimized_plan.md) section 9.2).
- **An optimized plan never holds the node.** An `OptimizedPlan` body is decoded in the OPTIMIZED context,
  where every node is rebuilt and its `output_schema` checked ([optimized_plan.md](optimized_plan.md)
  section 3), so it cannot hold an unbound node: section 6 runs the two halves as two optimized plans. An
  OPTIMIZED body with a `widen` arm is refused (`OPTIMIZED_FIELD_UNSUPPORTED`, which exists,
  `src/plan_wire/plan_wire_optimized.mojo`).

### 3.4 What a frame above the node knows

The skins derive every node's schema in Python today, by the engine's rules, so that `columns` and
`dtypes` run nothing (`python/komira/_plan/_field.py`, header). Above a `PLAN_WIDEN` a skin knows:

- the `index` columns, by name and type;
- that the decided columns all have the type `T` when the node has one measure (or is an indicator);
- the names the continuation adds, renames or drops by name.

So a verb above the node is checked as far as it can be: an expression that cannot type-check against
`T`, whatever the decided name turns out to be (`pivoted["pen"].str.lower()` when `T` is numeric), is
refused at the verb. A name is not checked, because no name can be until the node has run.

### 3.5 Column names and order

The order of decided columns is the values of `D` sorted ascending by the `on` column's type, NULLs out,
which is the order pandas' default `sort=True` gives, the order Spark gives (it sorts the collected values
"so the output columns are in a consistent logical order", `RelationalGroupedDataset.scala`, v4.0.0,
`collectPivotValues`), and the order DuckDB 1.1.3 gave in every case tried. `naming` is one value per
frontend, so each frontend gives its library's names:

| `naming` | used by | name of value `v` (and measure `m`) |
|---|---|---|
| `PANDAS` | `pivot_table`, `pivot`, `crosstab` | `v` rendered as text by komira's cast to VARCHAR ([query_semantics.md](query_semantics.md)); a value equal to an `index` column's name is refused (`WIDEN_COLUMN_NAME_CONFLICT`) |
| `PANDAS_DUMMIES` | `get_dummies` | `prefix + prefix_sep + v`; the prefix defaults to the column's name, as in pandas |
| `DUCKDB` | SQL `PIVOT` | DuckDB's rule: `v` for one measure, `v` + `_` + the measure's alias for several (`ink_s`, `ink_c`); for several `ON` columns the values joined by `_` (`NL_Amsterdam` in DuckDB's documentation); a name equal to an earlier one, compared without case, gets DuckDB's numeric suffix (DuckDB 1.1.3 named `pen` beside `Pen` `pen_1`, and `region` beside the group column `region_1`) |

pandas keeps a label's own type (an integer `2024` stays an integer label); komira's column names are
strings, so `2024` becomes `"2024"`. That is a new departure, listed in section 10. pandas `columns=` takes
one column in the slices of this design; a list gives `MultiIndex` columns and is refused (section 5.3), so
several `on` columns come only from SQL.

**Row order.** pandas' `sort=True` sorts the rows by `index`, as `groupby(sort=True)` does; the
pandas-shaped skin puts a sort on the `index` columns above the node, as it puts one above a
`groupby(sort=True)` aggregate today (ruling 2 of [dataframe_surface.md](dataframe_surface.md)), and the
frame is ordered. A SQL `PIVOT` promises no row order without `ORDER BY`, as any plan whose root is not a sort does
([query_semantics.md](query_semantics.md) §4.8). So the order the hold or its spill partitions are read in never shows.

### 3.6 Identity, caching and digests

- **The authored plan.** Its render is deterministic: the `PLAN_WIDEN` node renders its parameters, and an
  unbound node renders by name exactly as a bound one does (the render omits `output_schema` already,
  `plan.proto` header). So `structural_hash`, the FNV-1a of the render that keys the context's plan-compile
  cache (`src/plan_proto/plan.proto` header; `sdk_exec`, [architecture.md](../architecture.md)), names
  the authored plan as it names any plan.
- **The bound continuation.** Its identity is the authored plan's identity together with the SHA-256 of
  the canonical decided schema. Two runs that decide the same columns compile the continuation once; a
  run that decides different columns compiles a different plan. The decided schema is never folded into
  the authored plan's hash: the authored plan does not change when the data does.
- **Optimized plans** (section 6). The first plan's `plan_digest` is computed as today. The second plan
  is an ordinary, fully bound `OptimizedPlan` whose source is the held result; its scan pin names that
  result by the first plan's digest, the run, and the digest of the decided schema, the way a stream's
  pin names the stream and its schema ([optimized_plan.md](optimized_plan.md) section 6.2). Nothing about
  the decision lives outside a digest, and nothing in a digest depends on when the plan was built.
- **Results** are not cached: calling a terminal twice runs the plan twice
  ([dataframe_surface.md](dataframe_surface.md) section 2), and the second run decides afresh.

## 4. Execution

### 4.1 The order of steps

One run of a plan that holds one `PLAN_WIDEN`, inside one call of `komira_plan_stream` or
`komira_sql_stream`:

1. **Split.** The driver (in `sdk_exec`, beside `run_plan_batch`, `src/sdk_exec/engine_plan.mojo:146`)
   cuts the plan at the lowest `PLAN_WIDEN` into the **first half** (the node's child, with the long form
   `L` on top) and the **continuation** (everything above, with a placeholder leaf where the node was).
2. **First half.** Optimise, lower and run it as any plan: the long form is an ordinary aggregate, so it
   lowers to today's grouped-aggregate sink (`SINK_AGG`, `src/pipeline_exec/sink_group_agg.mojo`), with
   that sink's key types: a key column of a type with no sink row (a timestamp, a small or unsigned
   integer) is refused at step `lower` with `LOWERING_SINK_UNSERVED`, as every grouped aggregate over
   such a key is today (`src/lowering/cut_aggregate.mojo`, header; `src/lowering/sink_capability.mojo`).
   The engine refuses what it cannot run yet, and the skins do not repeat its check
   ([dataframe_surface.md](dataframe_surface.md) section 6); a pivot on a timestamp works when grouped
   aggregation gains that key type. The first half's optimisation prunes the scan to the columns `L`
   needs, the `index`, `on` and measure columns. Its result is **held** (section 4.2).
3. **Decide.** Compute `D` from the held `L`: one pass over the `on` columns, stopping as soon as
   `max_columns + 1` distinct values are seen (section 4.5).
4. **Bind.** Replace the placeholder leaf with `W(L, D)` over an in-memory scan of the held result, and
   rebuild every unbound node through its factory against the decided schema. This is where a name that
   is not among the decided columns is found (section 4.4).
5. **Second half.** Optimise, lower and run the bound continuation, with the held result as its only
   source. The input is not read a second time.
6. If the bound continuation holds another `PLAN_WIDEN`, it is run by the same steps; a plan with several
   is several stages, in order from the bottom.

**Cases the steps settle.**

- *One pivot used twice* (a self-merge of a pivoted frame): two `PLAN_WIDEN` subtrees with the same render
  are one breaker. The driver runs it once and binds both places to the one held result, as shared
  subplans are cut once today (`cut_shared`, `src/lowering/README.md`).
- *Two independent pivots* (joined above): each is run by steps 2 and 3, the left one first, before either
  continuation is bound.
- *A pivot inside a subquery expression* (a scalar or `IN` subquery, which embeds a `WirePlan`): refused by
  name in the slices of this design (`WIDEN_IN_SUBQUERY_UNSUPPORTED`). A pivot in a derived table
  (`FROM (PIVOT ...)`) is an ordinary child and works.
- *A filter on an `index` column written after the pivot* is not moved below it: the first half is
  optimised before the continuation exists. Such a filter commutes with the pivot, because the pivot groups
  by `index`; a later slice may move the conjuncts that name only `index` columns below the node before the
  split, since those names are bound. Until then it is a cost: `L` is computed for rows the filter drops.

**Why the engine may optimise twice.** The rule that nothing after the producer re-optimises
([optimized_plan.md](optimized_plan.md) section 2; [plan_models.md](plan_models.md) section 1.1) is a rule
about executor hosts admitting an `OptimizedPlan`. A local run is the producer and the host in one
process: libkomira already optimises an authored plan in-process before lowering it
([libkomira_run_abi.md](libkomira_run_abi.md), "What `komira_plan_stream` runs"). Steps 2 and 5 each
optimise a plan that no one has optimised before; neither re-optimises a plan. Lowering stays pure and
never links the optimiser ([lowering_and_pipeline.md](lowering_and_pipeline.md), its closure). The
optimiser's two-pass protocol for scalar subqueries is the precedent: it is written for a caller that
executes a request, adds the answer and optimises again, and `optimize_for_run` refuses today because no
caller does (`OPTIMIZE_UNRESOLVED_SCALAR`, `src/sdk_exec/engine_plan.mojo:65`, `:126`;
`src/optimizer/optimizer_scalar_deps.mojo`, header). This driver is the first such caller.

**The source of the second half.** A `PLAN_SCAN` over an in-memory source already lowers to `SOURCE_BATCH`
with the batch's own schema (`src/lowering/cut_scan.mojo`; `src/pipeline_exec/source_batch.mojo`), which
is the source the second half needs. `SOURCE_SINK_OUTPUT` is not: it reads another segment's output
within one `run_plan` call and cannot cross two `lower` calls (`src/pipeline_exec/published_outputs.mojo`).
The plan wire refuses an in-memory source (`PLAN_WIRE_UNSUPPORTED_SOURCE_IN_MEMORY`,
`src/plan_wire/plan_wire_codec.mojo:813`), and it does not need to accept one: the bound continuation is
built inside the engine and never encoded.

### 4.2 Where the held result lives

- **In memory, charged to the run's budget.** The held `L` is reserved against the segment pool
  (`SegmentPool`, `WorkerReservation.try_grow`, `src/pipeline_exec/segment_pool.mojo`), the one bound on a
  query's memory (`EngineOptions.memory_budget_bytes`, `src/sdk_exec/engine_options.mojo:19`;
  `Session(memory_limit=)`). Today's collect sink and published outputs hold batches without a charge
  (`src/pipeline_exec/sink_collect.mojo`); the hold does not, because it lives across two lowerings.
- **Then spill.** When the pool denies a grow and the run has a spill directory
  (`EngineOptions.spill_directory`, `:22`), the hold writes `L` to it partitioned by a hash of the `index`
  keys, as the grouped aggregate's spill does today (`src/pipeline_exec/group_spill.mojo`). The reshape
  groups by `index`, so each partition is reshaped alone and the second half reads the partitions in turn.
  Without a spill directory a denied grow fails the run with `MEMORY_BUDGET_EXCEEDED`, as every charged
  sink does.
- **Bounded by construction.** The hold is a sink with a reservation. Nothing polls memory, and no
  watchdog exists or is added: a grow either succeeds against the budget or is denied at that call. The
  decision's distinct set is bounded by `max_columns + 1` entries. The cap bounds the number of columns,
  not the size of `L`: `L` has one row per distinct (`index`, `on`) pair, and a high-cardinality `on`
  column makes it large before the cap is checked. Spark bounds that case by collecting the values in a
  separate job (section 7.1); here the pool bounds it, and spill carries it. The reshape's state, up to
  `max_columns` times the measures per `index` group, is an aggregate's state and is charged to the pool
  like one. The driver adds no queue: the second
  half starts after the first half has finished, as every dependent segment does today
  (`src/pipeline_exec/run_plan.mojo`).
- **`get_dummies`** holds its input rows, since its long form is the input. Its held size is its input's,
  not a grouped size, and the slice that builds it says so in the user's documentation.

The held result is released when the second half has read it, and in every failure path; the run's
check that every reservation came back (`EXECUTE_POOL_NOT_RELEASED`) covers it.

### 4.3 Binding the continuation

Binding is the plan's ordinary construction, run late: each unbound node is rebuilt bottom-up through its
`LogicalPlan` factory with its child's now-known schema, then the plan validator runs over the result
(`validate_plan`, `src/sdk/plan_validator.mojo`). No binding rule exists only for this path, so a node
means the same thing above a pivot as anywhere else.

### 4.4 A failure in the second half

The caller sees a refusal at step `bind`, after the first half has run:

| failure | step | code | message (the slice's test checks it in full) |
|---|---|---|---|
| a name above the node is not a decided column | `bind` | `BIND_DECIDED_COLUMN_MISSING` | `column 'pne' is not among the columns the pivot of 'product' decided: [ink, pen]`, listing at most 50, sorted, as decision 3 of [credentials_and_writes.md](credentials_and_writes.md) proposes for `BIND_NAME_UNBOUND` |
| an expression above the node does not type-check against a decided column | `bind` | the code the validator gives the same expression anywhere else | unchanged |
| two rows for one cell of a `UNIQUE` pivot | `execute` | `WIDEN_DUPLICATE_CELL` | names the index values and the column, as pandas' `Index contains duplicate entries, cannot reshape` does |
| a decided name equal to an `index` column (`PANDAS` naming) | `bind` | `WIDEN_COLUMN_NAME_CONFLICT` | names the value and the column |
| more decided columns than the cap | `execute` | `WIDEN_COLUMN_LIMIT_EXCEEDED` | section 4.5 |

In Python, a `bind` refusal is a `BindError` (`python/komira/_errors.py`), with its `step` and `code`, at
the terminal. pandas would raise `KeyError` at `pivoted["pne"]`; komira cannot, because the name cannot be
checked until the node has run. That is a departure, listed in section 10.

### 4.5 The cap on decided columns

- **Spark** caps the distinct values it collects at `spark.sql.pivotMaxValues`, default 10000: "When doing
  a pivot without specifying values for the pivot column this is the maximum number of (distinct) values
  that will be collected without error" (`SQLConf.scala`, v4.0.0, `DATAFRAME_PIVOT_MAX_VALUES`). Above it,
  `collectPivotValues` fetches `maxValues + 1` values and raises: "The pivot column <pivotColumn> has more
  than <maxValues> distinct values, this could indicate an error. If this was intended, set <config> to at
  least the number of distinct values of the pivot column." (`_LEGACY_ERROR_TEMP_1324`,
  `error-conditions.json`, v4.0.0). Its comment says why: "to prevent unintended OOM errors".
- **DuckDB** caps pivot columns at the setting `pivot_limit`, default 100000
  ([configuration](https://duckdb.org/docs/stable/configuration/overview)); DuckDB 1.1.3 refused above it
  with `Binder Error: Pivot column limit of 2 exceeded. Use SET pivot_limit=X to increase the limit.`
- **komira** carries the cap in the node (`max_columns`). Its default is 10,000, Spark's: a bound
  continuation holds at least one expression per decided column, and a plan that the distributed form
  (section 6) ships must stay inside the plan wire's node budget (65,536 nodes, `PLAN_WIRE_TOO_MANY_NODES`,
  `src/plan_wire/plan_wire_admit.mojo`). A user raises it with `Session(pivot_limit=...)`, DuckDB's name for
  the setting; the session writes it into each node it builds. Above the cap the run fails at step
  `execute` with `WIDEN_COLUMN_LIMIT_EXCEEDED`:
  `the pivot of 'product' has more than 10000 distinct values; list the values, or raise Session(pivot_limit=...)`.
  Like Spark, the decision stops at `max_columns + 1` values, so the decision itself holds no more than
  that; `L` is already held when the cap is checked (section 4.2).
- A SQL `PIVOT` that DuckDB answers with between 10,001 and 100,000 columns is refused by komira by name
  under the default: a parity gap ([query_semantics.md](query_semantics.md), "PARITY GAP"), not a
  different answer.

## 5. The C ABI and the SDKs

### 5.1 The C ABI

No call is added or changed. `komira_plan_stream` and `komira_sql_stream` take a plan or a statement and
answer an Arrow C stream whose schema is fixed by the time the call returns `OK`, because the run
completes before the call returns ([libkomira_run_abi.md](libkomira_run_abi.md) section 5). A run with a
`PLAN_WIDEN` decides its schema inside the call, so the stream's `get_schema` answers the decided schema
as it answers any schema. The refusals of section 4 reach the caller through `komira_last_error_code` and
`komira_last_error_step` (ABI 1.7). Progress (`komira_run_progress`) counts segments, and a run with a
breaker of this kind learns its second half's segments only after the first half; its total grows once,
at step 4.

A later ABI that streams batches before the run completes would have to answer `get_schema` before the
first batch. A run with a `PLAN_WIDEN` can do that only after its first half; that is that ABI's problem
to state, and nothing in this design forecloses it.

### 5.2 `Session.sql`

The binder builds a `PLAN_WIDEN` for DuckDB's statement form without `IN`
(`PIVOT sales ON product USING sum(amount) GROUP BY region`), and an ordinary aggregate for the forms
that list the values: DuckDB's `ON product IN ('pen', 'ink')` and the standard
`FROM sales PIVOT (sum(amount) FOR product IN ('pen', 'ink'))` (section 7.3). The answer is DuckDB's
(rule B21). DuckDB 1.1.3 observations the oracle test pins against the pinned 1.5.6:

- a NULL `ON` value makes no column, and its row still appears with NULL cells;
- an empty input gives the group columns and no decided column;
- a missing cell is NULL for `sum` and 0 for `count`;
- the statement form works in a subquery (`SELECT * FROM (PIVOT ...) WHERE pen > 5`), and a name that the
  pivot did not decide fails at bind (`Binder Error: Referenced column "cap" not found`);
- DuckDB refuses a view over the statement form: `PIVOT statements with pivot elements extracted from the
  data cannot be used in views.` komira refuses the same: a SQL binding of a view whose plan holds a
  `PLAN_WIDEN` is refused by name (`BIND_VIEW_SCHEMA_UNDECIDED`), because the binder must know a view's
  columns to bind a statement over it, and those columns are known only inside a run (section 4.3). The
  binding itself is decision 2 of [credentials_and_writes.md](credentials_and_writes.md).

### 5.3 The pandas-shaped skin

The verbs keep pandas 3.0.6's signatures exactly:

```python
DataFrame.pivot_table(values=None, index=None, columns=None, aggfunc="mean", fill_value=None,
                      margins=False, dropna=True, margins_name="All", observed=True, sort=True, **kwargs)
DataFrame.pivot(*, columns, index=<no_default>, values=<no_default>)
komira.pivot_table(data, values=None, index=None, columns=None, aggfunc="mean", ...)  # pandas.pivot_table
komira.crosstab(index, columns, values=None, rownames=None, colnames=None, aggfunc=None,
                margins=False, margins_name="All", dropna=True, normalize=False)
komira.get_dummies(data, prefix=None, prefix_sep="_", dummy_na=False, columns=None, sparse=False,
                   drop_first=False, dtype=None)
```

An argument the plan cannot honour is refused at the call with `UnsupportedOperation`, naming the
argument and its value ([dataframe_surface.md](dataframe_surface.md) section 6): `margins=True`, a list
for `values` or `aggfunc` (pandas answers with `MultiIndex` columns, and a komira frame has no
`MultiIndex`), `sort=False` (the order of first appearance is a row-order choice, section 7 of that
document), `sparse=True`, and `observed=False`. `index` values become columns, as ruling 1 of
[dataframe_surface.md](dataframe_surface.md) already does for every verb that puts values in an index.

**`columns`, `dtypes` and `repr` before anything has run.** They run nothing, as on every frame
(section 2 of [dataframe_surface.md](dataframe_surface.md)):

- `df.columns` and `df.dtypes` on a frame whose plan holds a `PLAN_WIDEN` raise `UnsupportedOperation`:
  `.columns is not known before the frame runs: pivot_table(columns='product') takes its columns from the data; materialize() the frame to see them`.
- `repr(df)` and the notebook display show the known columns, then a line saying which columns the data
  decides (`+ one column per value of 'product', decided when the frame runs`). A display must not raise.

**Why refuse, and not run the first half.** Running the first half to answer `columns` would break the
rule that no verb and no attribute runs a query, which every skin promise rests on (no hidden cost, no
dunder that runs, a frame is only a plan). It would also do the expensive part of the query, the read and
the long-form aggregate, and then throw it away, because nothing is cached between a frame's attribute
and its terminal; and the data may change between the two, so the answer could be wrong by the time the
terminal runs. A user who needs the columns runs the frame.

A verb above the node that needs the whole column list to build its plan (`add_prefix`, `add_suffix`,
assigning `df.columns`, `df.sum()` over every column, `select_dtypes`) is refused by name until the plan
can say "every decided column" (section 9). A verb that names columns (`df[pred]`, `df[["a", "b"]]`,
`assign`, `rename(columns={...})`, `sort_values`, `merge`) is recorded unbound.

### 5.4 The polars-shaped skin

`komira.pl` mirrors polars 1.44.2, which has exactly one pivot on a lazy frame, and it takes the values:

```python
LazyFrame.pivot(on, on_columns, *, index=None, values=None, aggregate_function=None,
                maintain_order=False, separator="_", column_naming="auto")
```

(`py-polars/src/polars/lazyframe/frame.py:8505`, tag `py-1.44.2`; `column_naming` is marked unstable
there.) It builds an ordinary aggregate with one measure per listed value, so it never builds a
`PLAN_WIDEN`. `komira.pl` adds no lazy pivot without `on_columns`, no `to_dummies` (polars 1.44.2 has it
on the eager `DataFrame` only) and no `unstack`: polars has none of them on `LazyFrame`. The polars skin
therefore never has a frame whose schema is undecided, and `columns`, `schema` and `collect_schema()` keep
answering without running.

### 5.5 Other SDKs

The TypeScript package ([typescript_package.md](typescript_package.md)) is SQL-first and reaches the
breaker through `sql()` with nothing of its own. The Mojo SDK's plan builders (`src/sdk`) gain a builder
for `PLAN_WIDEN` in the slice that needs it, under the same rules.

## 6. Distributed and streaming plans

### 6.1 On several hosts

A job manager accepts only a serializable `OptimizedPlan` and never optimises or decodes the body (rule
B21; [optimized_plan.md](optimized_plan.md) section 2). A plan with a `PLAN_WIDEN` runs there as **two
optimized plans**:

1. The producer (the SDK, which links the optimiser) splits the plan as in section 4.1 and submits the
   first half as an `OptimizedPlan` whose root is a **hold**: the long form `L`, written once to the run's
   result store and sealed, as a shuffle's map phase is ([shuffle.md](shuffle.md): "a seal says the map
   phase is complete"). The run answers the decided values `D` with the seal.
2. The producer binds and optimises the continuation against `D` and submits it as a second
   `OptimizedPlan` whose source is the held result, pinned as section 3.6 says. A host that runs it reads
   only the held result.

So the breaker is a **stage boundary at which the plan ends**. The coordinator's cut stays mechanical
([optimized_plan.md](optimized_plan.md) section 8.2) and never meets a `PLAN_WIDEN`, because no optimized
plan holds one. The producer stays the only optimiser; the scheduler sees two ordinary plans.

**How it relates to adaptive execution.** At a sealed stage boundary a host may coalesce reducers, split
skewed partitions and switch a join's distribution, each recorded so a replay reproduces it, and nothing
else ([optimized_plan.md](optimized_plan.md) section 8.3). The breaker is not one of those changes and does
not widen that list: it does not modify a plan under its digest, it ends one plan and starts another under
a new digest. A replay of the second plan reads the pinned held result and reproduces the answer without
running the first.

The producer that binds the continuation is the program that submitted the first plan. A service that
re-optimises stored plans is a producer too (`komira/server`, [optimized_plan.md](optimized_plan.md)
section 2) and can take that role for a stored query; this design adds no other.

The result store, the hold's sink and the held-result source do not exist; the shuffle's seal is the
pattern they follow. This form is a late slice (section 8), after the coordinator's cut exists.

### 6.2 In a streaming plan

A plan with an `UNBOUNDED` scan is a streaming plan, and a blocking operator over unbounded input is
refused unless a contract version admits a streaming form of it (`OPTIMIZED_UNBOUNDED_INPUT_UNSUPPORTED`,
[optimized_plan.md](optimized_plan.md) section 5.2; detail reasons in [plan_models.md](plan_models.md)
section 3.3). A `PLAN_WIDEN` over unbounded input is refused with the new detail reason
`UNBOUNDED_SCHEMA_DECIDING`, and no streaming form is designed:

- an unbounded input never finishes, so the decision never happens;
- deciding per epoch would give each epoch a different schema, and a streaming plan's schemas are fixed
  for its life: its state is typed by a schema digest and changes only by a roll to a new plan
  ([plan_models.md](plan_models.md) sections 3.5 and 5.3);
- Spark refuses it the same way: `collectPivotValues` raises
  `pivot is not supported on a streaming DataFrames/Datasets` (`_LEGACY_ERROR_TEMP_3063`, v4.0.0).

A pivot with its values listed (the polars `LazyFrame.pivot`, SQL with `IN`) is an ordinary aggregate and
is admitted wherever that aggregate's streaming form is.

## 7. The alternatives

### 7.1 Way 1: two runs with static plans

Run a small query first for the distinct values, then build the real plan with them as constants. This is
what Spark does when `pivot` is given no values: `pivot(pivotColumn)` is
`pivot(pivotColumn, collectPivotValues(df, pivotColumn))`, and `collectPivotValues` runs
`df.select(pivotColumn).distinct().limit(maxValues + 1).sort(pivotColumn).collect()` before the plan is
built (`RelationalGroupedDataset.scala`, v4.0.0). DuckDB does it inside one statement: it "must be
translated into multiple queries", and the distinct values become a temporary `ENUM` injected into the
statement's `IN` lists ([DuckDB internals: PIVOT](https://duckdb.org/docs/stable/internals/pivot)).

- **Cost.** The input is read twice. A columnar file read only for the `on` column is cheaper the second
  time, but a filter, join or aggregate below the pivot runs twice in full. Between the two runs the data
  can change: on a file without a snapshot the columns are decided from one version and filled from
  another, silently.
- **Where it is strictly simpler.** No new kind of node, no unbound plan, no second optimisation inside a
  run, and a distributed run needs nothing new: both plans are static.
- **Not kept.** It contradicts the skins' rule that no verb runs a query if the SDK runs the first query,
  and it is the same read twice if the engine does. A later case may revisit it where the values are known
  without reading the data (a table's statistics that are exact for the column), recorded then as an
  optimisation with its own tests.

### 7.2 Way 3: one run, reshape at the end

When the pivot is the last step, aggregate in long form and reshape to wide when the result is handed
back. In this design that is exactly way 2 with an empty continuation: the second half is `W(L, D)` and
nothing else. It needs no separate path and gets none. It does not cover a filter on a new column, because
a step after the pivot needs the schema inside the plan.

### 7.3 Values listed: an ordinary aggregate

When the values are listed (polars `on_columns`, SQL `IN`, a future pandas spelling that lists them), the
output schema is known at build, and the pivot is an `AGGREGATE` grouped by `index` with one measure per
listed value and measure: `sum(CASE WHEN product = 'pen' THEN amount END) AS pen`. That is the
workaround the task pages spell by hand today, and it runs today. A `FILTER (WHERE ...)` clause would be
the closer SQL spelling, but the parser refuses it and points at `CASE WHEN` (`src/sql/sql_parser.mojo:1688`).
The listed form is kept as the special case it is, needs no `PLAN_WIDEN`, and is the only form a lazy
polars frame and a streaming plan have.

## 8. Slices, in order

Each slice is one pull request, and each names its tests by the behaviour they hold.

| # | slice | what works after it |
|---|---|---|
| 1 | `PLAN_WIDEN` (kind `AGGREGATE`, naming `PANDAS`), the `widen` wire arm (no version bump, section 3.3), the unbound decode, the split-hold-decide-bind driver in `sdk_exec` with the held result in memory and charged to the pool, `DataFrame.pivot_table` (one `values` column, one `aggfunc` of sum, mean, count, min or max, `dropna`, `fill_value`), `columns` and `dtypes` refusals, and the filter and projection verbs above the node | `km.read_parquet("sales.parquet").pivot_table(index="region", columns="product", values="amount", aggfunc="sum")`, then `pivoted[pivoted["pen"] > 5].materialize()`, end to end, equal to pinned pandas 3.0.6's answer under ruling 1 |
| 2 | SQL: the statement `PIVOT ... ON ... USING ... GROUP BY` with and without `IN`, the standard clause with `IN`, naming `DUCKDB`, the view refusal | `Session.sql` answers DuckDB's rows, columns and names, checked against the pinned DuckDB |
| 3 | the remaining verbs above the node (sort, groupby, merge, head), `komira.pivot_table`, `DataFrame.pivot` (kind `UNIQUE`), `crosstab`, and polars' `LazyFrame.pivot` (an ordinary aggregate) | the pandas and polars pivot verbs of sections 5.3 and 5.4 |
| 4 | `get_dummies` (kind `INDICATOR`, naming `PANDAS_DUMMIES`) | pandas' `get_dummies` |
| 5 | spill of the held result | a pivot whose long form exceeds `memory_limit` runs when a spill directory is set |
| 6 | streaming refusal `UNBOUNDED_SCHEMA_DECIDING`, with the streaming admission checks it belongs to | a streaming plan with an unlisted pivot is refused by name |
| 7 | the two-plan distributed form: the hold sink, the result store, the held-result source and pin | a pivot runs under a job manager |

Slice 1 is large because its case is end to end; each part of it is needed by that case and
by nothing else first.

### 8.1 How each rule is tested, with no real service

Every test reads files the test writes into its own scratch directory, and nothing talks to a network:

- **Plan IR** (Mojo, `src/plan_ir/tests`): a `PLAN_WIDEN` builds with its known columns; a node above it is
  unbound; a bound subtree beside it keeps its schema; rebinding against a decided schema gives the same
  plan as building it bound.
- **Wire** (Mojo, `src/plan_wire/tests`, and a golden `.txtpb` for the arm): the round trip of every field;
  each refusal by full text: an unbound node that carries a schema, `EXPR_COL_IDX` above the node,
  `kind` or `naming` unset, `max_columns` zero read as 10,000, a `widen` arm in an OPTIMIZED body. Rule
  B8's two directions: the new release on old data is the existing golden corpus
  (`src/plan_wire/tests/fixtures/golden`), which must pass unchanged; the previous release on new data
  cannot be run, because a test may not fetch a previous release (rule T12), so that test is waived for
  this reason. What the previous release does instead follows from its decoder: a `WirePlan` whose arm it
  does not know has no arm set and is refused. The `WireExpr` form of that refusal is tested today
  (`test_an_expr_with_no_node_arm_is_refused`, `src/plan_wire/tests/test_plan_wire_codec_tampered_wire.mojo`);
  slice 1 adds the `WirePlan` twin.
- **Driver** (Mojo, `src/sdk_exec/tests`, over a Parquet file written by the test): the first half runs once
  and the input is opened once (counted by the scan's opener); the cap at exactly `max_columns` values
  runs and at `max_columns + 1` is refused; empty input, all keys NULL, one value, a value equal to an
  index name, a value whose `mean` cells are all NULL (no column under `pandas_dropna`) and one whose `sum` cells are (a column of 0), a key of a type with no
  sink row (`LOWERING_SINK_UNSERVED`), one pivot used twice (its input opened once); a name above the node that was not decided (`BIND_DECIDED_COLUMN_MISSING`, full text); a
  denied grow without a spill directory (`MEMORY_BUDGET_EXCEEDED`) with every reservation returned; a
  cancellation between the two halves.
- **Skins** (Python, against the pinned pandas 3.0.6 and polars 1.44.2 as oracles,
  [dataframe_surface.md](dataframe_surface.md) section 11): each verb and argument against the library's
  answer under ruling 1, including the row order, a missing cell for each `aggfunc` (NaN for
  `pivot_table`, 0 for `crosstab`) and a cell whose values are all NULL; each refusal by full text; `columns`, `dtypes` and `repr` run nothing (the
  session's native call count is unchanged).
- **SQL** (the conformance corpus, answered by the pinned DuckDB through its oracle action): each
  observation of section 5.2, the names of section 3.5, and the limit.
- **Distributed** (slice 7): over the in-memory object store and the shuffle's seal tests' fakes.

The failure and boundary cases above are the complete set because they are the inputs that change the
decided schema's size (empty, one, the cap, the cap plus one), its names (NULL, collision with an index
column, collision under DuckDB's case-insensitive rule), its binding (a missing name, a bad type), and the
held result's life (denied memory, cancellation, error after the first half).

## 9. Out of scope

- `unstack`, `stack`, `transpose` and `T`: they move values between a frame's index and its columns, and
  komira frames have no index (ruling 1 of [dataframe_surface.md](dataframe_surface.md)); they stay refused
  by name.
- `Series.str.get_dummies`, `Series.str.split(expand=True)` and `json_normalize`: of this kind, not
  requested; each would be a new `kind` of the same node.
- `MultiIndex` columns, so lists of `values` or `aggfunc` and `margins=True`.
- A plan expression meaning "every decided column", which the whole-frame verbs of section 5.3 need.
- `UNPIVOT`, `melt` and `unpivot`: static schemas, a separate node, not this design.
- Schema inference of sources: decided at the reader, before the plan exists (section 2.1).
- A lazy polars pivot without `on_columns`: polars has none.
- A streaming form of the breaker (section 6.2).

## 10. Names and behaviours komira invents

Everything a user sees is taken from pandas, polars, DuckDB or Spark as cited above, except:

| name or behaviour | where | why komira needs it |
|---|---|---|
| `Session(pivot_limit=...)` and its default 10,000 | Python `Session` | the cap of section 4.5; the name is DuckDB's setting, the default is Spark's |
| `WIDEN_COLUMN_LIMIT_EXCEEDED` and its message | every surface | the refusal above the cap |
| `BIND_DECIDED_COLUMN_MISSING` and its message | every surface | a missing name found after the first half |
| `WIDEN_DUPLICATE_CELL` | pandas `pivot` | pandas' duplicate-entries error, named in komira's error vocabulary |
| `WIDEN_COLUMN_NAME_CONFLICT` | pandas-shaped pivots | a decided name equal to an index column is an error, where pandas keeps the index apart and has no clash |
| `WIDEN_IN_SUBQUERY_UNSUPPORTED` | SQL, plans | a pivot inside a subquery expression (section 4.1) |
| the 50-name limit and sorted list in `BIND_DECIDED_COLUMN_MISSING`'s message | every surface | follows decision 3 of [credentials_and_writes.md](credentials_and_writes.md), which proposes it for `BIND_NAME_UNBOUND` and is not built |
| the `repr` line `+ one column per value of '<column>', decided when the frame runs` | pandas-shaped frames after a pivot | section 5.3 |
| `BIND_VIEW_SCHEMA_UNDECIDED` | SQL bindings | DuckDB's view refusal, named |
| `UNBOUNDED_SCHEMA_DECIDING` | streaming admission | the refusal of section 6.2 |
| `PLAN_WIRE_UNBOUND_SCHEMA_PRESENT` | plan wire | an unbound node that carries a schema |
| `df.columns` / `df.dtypes` raise `UnsupportedOperation` before the frame runs | pandas-shaped frames after a pivot | pandas has no lazy frame; section 5.3 |
| an unknown name above a pivot raises `BindError` at the terminal, not `KeyError` at the subscript | pandas-shaped frames after a pivot | section 4.4 |
| pivot values that are not strings become string column names | pandas-shaped pivots | komira's column names are strings (section 3.5) |
| the `index` columns are columns of the result | pandas-shaped pivots | ruling 1 of [dataframe_surface.md](dataframe_surface.md), extended |
| the internal names `PLAN_WIDEN`, `WidenData`, `WireWidenNode`, `WireFill`, the arm `widen = 23`, the fields `kind`, `naming`, `separator`, `prefixes`, `fill`, `pandas_dropna`, `indicator_type`, `max_columns` (0 meaning 10,000), the kinds `AGGREGATE`, `UNIQUE`, `INDICATOR` and the namings `PANDAS`, `PANDAS_DUMMIES`, `DUCKDB` | plan IR and wire | not user-facing; listed so the owner can rename them before slice 1 |
| the reuse of `OPTIMIZED_FIELD_UNSUPPORTED` for a `widen` arm in an optimized body | plan wire | an existing code, given one more case |

## 11. Decisions for the owner

1. The concept, named "schema-deciding breaker", and its one node `PLAN_WIDEN` for every operation of the
   kind (section 3.1), rather than one node per verb. Recommended: one node, because the three parts of
   section 2.2 are the same for each.
2. `columns` and `dtypes` refuse before the run, rather than running the first half (section 5.3).
3. The default cap of 10,000, named `pivot_limit` (section 4.5).
4. The distributed form as two optimized plans with the producer binding the second (section 6.1), which
   keeps the job manager's rule and the coordinator's cut unchanged.
5. Way 1 and a separate way 3 are not built (section 7).
