# physical_plan

The PhysicalPlan IR (segment descriptors: a source, a chain of morsel operators and a sink, as inert data), its IR version door, and the purity gate that refuses a physical plan still holding a LogicalPlan.

- `physical_plan`: the segment descriptor `SegmentDescPod`, its `SourceSpecPod`, the `MorselOp` operator, the source, operator, sink and edge tags, and `PHYSICAL_PLAN_IR_VERSION` with its door `assert_physical_plan_ir_version_compatible`, which refuses a segment emitted at another IR version. It imports the names of `sink_data` and `csv_source_spec`, so each is also importable from `physical_plan.physical_plan`.
- `sink_data`: the sink payloads a segment's `sink_param_id` names (`AggSinkData`, `SortSinkData`, `TopNSinkData`, `PartitionBySinkData`, `PartitionTopNSinkData`, `AsofJoinSinkData`, `HashBuildSinkData`, `SMJBuildSinkData`) and `is_explicit_nulls_first_request`.
- `csv_source_spec`: `CsvSourceSpec`, the `SOURCE_CSV` arm of a `SourceSpecPod` (`csv_spec`): one local CSV file, its dialect, and every column of the file with the type the plan bound it at. An empty spec holds the CSV defaults (a comma, a header row, RFC 4180, no column).
- `physical_plan_purity_gate`: `assert_physical_plan_carries_no_logical_plan`, which refuses a segment whose expressions still hold a correlated subquery (and so a LogicalPlan), and raises on an expression tag it does not model.

The logical plan, which this package builds on, is in `plan_ir`. `optimizer` emits a LogicalPlan and does not depend on this package, so an import of it from the optimizer does not resolve and fails the optimizer's build. Users import the modules (`from physical_plan.physical_plan import MorselOp`); the package's `__init__.mojo` exports nothing.

A `SOURCE_CSV` spec, as lowering mints one for `read_csv`:

```mojo
from std.testing import assert_equal, assert_true

from arrow.arrow_types import ArrowType
from physical_plan.csv_source_spec import CsvSourceSpec
from physical_plan.physical_plan import SourceSpecPod

var names = List[String]()
names.append("id")
names.append("name")
var types = List[ArrowType]()
types.append(ArrowType.INT64)
types.append(ArrowType.STRING)
var spec = SourceSpecPod.csv(
    CsvSourceSpec("t.csv.gz", UInt8(ord("|")), True, 0, names^, types^)
)
assert_equal(spec.csv_spec.path, "t.csv.gz")
assert_equal(Int(spec.csv_spec.delimiter), ord("|"))
assert_equal(len(spec.csv_spec.column_names), 2)
assert_true(spec.csv_spec.column_types[1] == ArrowType.STRING)
# Any other arm's spec holds the CSV defaults: a comma and a header row.
var other = SourceSpecPod.batch(0)
assert_equal(Int(other.csv_spec.delimiter), ord(","))
assert_true(other.csv_spec.has_header)
```
