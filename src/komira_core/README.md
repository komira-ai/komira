# `komira_core`

## Responsibility

`komira_core` is the leaf of the engine's dependency graph. The engine,
compiler, file-format and SDK packages all depend on it; it depends only on
the Mojo standard library and `komira_core_ffi`.

That makes it the home for:

- **Plan IR** (`plan/`): the logical plan tree (`LogicalPlan`, `ScanData`,
  `FilterData`, `ProjectData`, `AggregateData`, `JoinData`, `SortData`,
  `LimitData`, `DistinctData`, `TopNData`, `PartitionByData`,
  `PartitionTopNData`, `AsofJoinData`), the expression IR (`Expr`,
  `BinaryOp`, `UnaryOp`, `LiteralData`, `AliasData`, `CastData`,
  `WhenData`, `StringOpData`, `ColRefData`), `AggExpr`, `PartitionExpr`,
  `ScalarValue`, `TableStats`, and the physical plan types.
- **Trait shapes** (`traits/`): `SourceCapabilities`, `SourceStatistics`,
  `ColumnStatistics`, `ExecResult`, `ExprId` -- the contract surface that
  the engine, the file-format readers and the SDK all conform to.
- **Arrow runtime types** (`arrow/`, `arrow_helpers/`): Arrow buffer, array
  and batch types.
- **Collections** (`collections/`): `Slab`, `DynValue`, `OwnedFd`,
  `BloomFilter`, `ByteView`, and related containers.
- **Eval primitives** (`eval/`): scalar evaluation kernels (arithmetic,
  comparison, string ops, cast, dictionary filters, selection vectors).
- **Helpers** (`helpers/`): plan-time helpers (`compiler_helpers`,
  `compiler_join_assembly`, `compiler_registry`, `compiler_scan`,
  `query_context`).
- **Runtime** (`runtime/`): CPU topology discovery, worker/driver placement
  (`EnginePlacement`), transparent-hugepage policy, `/proc` probes.
- **Runtime traits** (`runtime_traits/`): worker-pool and fork-join
  dispatch contracts.
- **Small shared types** at the package root: trait definitions and
  configuration / data-layout primitives that operators and runtime both
  consume.

### Top-level files

- `accumulator_trait.mojo` -- `Accumulator` trait: the minimum surface for
  columnar (SoA) aggregation accumulators.
- `agg_strategy.mojo` -- plan-time and runtime aggregation strategy codes
  (`STRATEGY_S1_RADIX`, `STRATEGY_S1_PARTITIONED`, ...) and the
  `select_optimal_strategy(...)` heuristic.
- `agg_layout.mojo` -- `AggLayout`, `MAX_AGGS`, `layout_for_funcs(...)`:
  the per-row tuple layout of aggregation accumulators (fixed-size
  `InlineArray` storage, no owning pointers).
- `agg_column_ptrs.mojo` -- `TypedColumnPtrs`, the classified per-aggregate
  value-column view consumed by the aggregation scatter / commit kernels.
- `key_column_view.mojo` -- `KeyColumnView`, the group-by key column view
  used by both the engine and the compiler.
- `engine_config.mojo` -- `EngineConfig`, the engine configuration value.
  The embedding program builds it (for example from its command-line flags)
  and passes it explicitly; nothing in the engine reads configuration from
  the process environment.
- `engine_error.mojo` -- `EngineError` and the `processor_error` helper,
  returned across the engine -> SDK boundary.

## Public API

The most-imported entry points are:

| Symbol | Module | Purpose |
|---|---|---|
| `LogicalPlan`, `ScanData`, `FilterData`, ... | `plan.logical_plan` | Logical plan tree |
| `Expr`, `BinaryOp`, `LiteralData`, ... | `plan.expr` | Expression IR |
| `AggExpr`, `AggExprArray` | `plan.agg_expr` | Aggregation expressions |
| `ScalarValue` | `plan.scalar_value` | Type-erased scalar literal |
| `TableStats`, `ColumnStats` | `plan.table_stats` | Plan-time statistics |
| `StatsProvider` | `plan.stats_provider` | Format-agnostic stats trait |
| `MorselSegment`, `PhysicalPlanFragment` | `plan.physical_plan` | Physical plan IR |
| `ExecResult`, `NEED_MORE_INPUT`, ... | `traits.exec_result` | Operator result codes |
| `SourceCapabilities`, `SourceStatistics`, `ColumnStatistics` | `traits.*` | Source extensibility surface |
| `ExprId` | `traits.expr_id` | Late-bound expression handle |
| `Accumulator` | `accumulator_trait` | Columnar accumulator trait |
| `STRATEGY_*`, `select_optimal_strategy` | `agg_strategy` | Aggregation strategy selector |
| `AggLayout`, `MAX_AGGS`, `layout_for_funcs` | `agg_layout` | Per-row tuple layout |
| `TypedColumnPtrs` | `agg_column_ptrs` | Aggregation scatter typed pointers |
| `KeyColumnView` | `key_column_view` | Key column view type |
| `EngineConfig` | `engine_config` | Engine configuration value |
| `EnginePlacement` | `runtime.engine_placement` | Worker / driver CPU placement |
| `EngineError`, `processor_error` | `engine_error` | Error type + helper |
| `Column`, `RecordBatch`, `Schema`, `Bitmap`, `AlignedBuffer`, ... | `arrow.*` | Arrow runtime types |
| `Slab`, `DynValue`, `OwnedFd`, `BloomFilter`, `ByteView` | `collections.*` | Container primitives |
| `eval_gt`, `eval_eq`, `eval_add`, `eval_string_*`, ... | `eval.*` | Scalar eval kernels |
| `resolve_col_index` | `helpers.compiler_helpers` | Plan-time column-name -> index resolver |
| `_simd_sum`, `_simd_min`, `_simd_max`, `simd_add_arrays`, ... | `simd_helpers` | SIMD kernel helpers |

The package `__init__.mojo` re-exports `simd_helpers`. The other modules
are imported directly (`from komira_core.plan.expr import Expr`).

## Data structures

Types in `komira_core` are either:

- **Plain data / inert IR** -- no atomics, and no heap-owning fields other
  than `Slab[T]` / `OwnedPointer[T]`. The plan tree, the trait return
  shapes, and the aggregation layout / strategy primitives are all of this
  shape.
- **Arrow runtime types** -- `Column`, `RecordBatch`, `Bitmap`,
  `AlignedBuffer`, `PrimitiveArray`, and so on. These own heap buffers
  (through `Slab[UInt8]` / `AlignedBuffer`) and never hold an owning
  pointer with a wildcard origin.

Worker pools and other active runtime structures live in the engine
runtime package, above this one.

## Dependency direction

```
komira_core -> std, komira_core_ffi                 (leaf)
engine / compiler / file formats / SDK -> komira_core
```

A dependency from `komira_core` onto any higher-tier package is a layering
error; building `komira_core` on its own is the guard for it.
