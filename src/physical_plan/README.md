# physical_plan

The PhysicalPlan IR (segment descriptors: a source, a chain of morsel operators and a sink, as inert data), its IR version door, and the purity gate that refuses a physical plan still holding a LogicalPlan.

- `physical_plan`: the segment descriptor `SegmentDescPod`, its `SourceSpecPod` (a Parquet source names one file, or lists several with their Hive partition columns and values), the `MorselOp` operator and the sink payloads, which are defined in `source_spec` (`SourceSpecPod`, `ParquetSourceData`, `ParquetRowWindow`, the `SOURCE_*` tags) and `sink_data` (the `*SinkData` structs) and re-exported by `physical_plan`, the source, operator, sink and edge tags, and `PHYSICAL_PLAN_IR_VERSION` with its door `assert_physical_plan_ir_version_compatible`, which refuses a segment emitted at another IR version.
- `source_spec` and `sink_data`: the Parquet source configuration with `SourceSpecPod`, and the sink payload structs, split out of `physical_plan` to keep each file small; `from physical_plan.physical_plan import SortSinkData` still works.
- `physical_plan_purity_gate`: `assert_physical_plan_carries_no_logical_plan`, which refuses a segment whose expressions still hold a correlated subquery (and so a LogicalPlan), and raises on an expression tag it does not model.

A Parquet source of several files, with one Hive partition column, is a `SourceSpecPod` made by `parquet_files`. `parquet_path` is the first file, `parquet_paths` lists them all, and `parquet_partition_values` holds one row of decoded values per file:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from arrow.arrow_types import ArrowType
from arrow.schema import Field
from physical_plan.physical_plan import SourceSpecPod

var paths = List[String]()
paths.append("sales/dt=2026-10-01/a.parquet")
paths.append("sales/dt=2026-10-02/b.parquet")
var cols = List[Field]()
cols.append(Field("dt", ArrowType.DATE32, False))
var first = List[String]()
first.append("2026-10-01")
var second = List[String]()
second.append("2026-10-02")
var values = List[List[String]]()
values.append(first^)
values.append(second^)

var spec = SourceSpecPod.parquet_files(paths^, cols^, values^, None, None)
assert_equal(spec.parquet_path, "sales/dt=2026-10-01/a.parquet")
assert_equal(len(spec.parquet_paths), 2)
assert_equal(spec.parquet_partition_cols[0].name, "dt")
assert_equal(spec.parquet_partition_values[0][0], "2026-10-01")
assert_equal(spec.parquet_partition_values[1][0], "2026-10-02")
assert_true(spec.parquet_spec_is_total)
```

The logical plan, which this package builds on, is in `plan_ir`. `optimizer` emits a LogicalPlan and does not depend on this package, so an import of it from the optimizer does not resolve and fails the optimizer's build. Users import the modules (`from physical_plan.physical_plan import MorselOp`); the package's `__init__.mojo` exports nothing.
