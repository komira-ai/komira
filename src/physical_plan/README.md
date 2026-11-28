# physical_plan

The PhysicalPlan IR (segment descriptors: a source, a chain of morsel operators and a sink, as inert data), its IR version door, and the purity gate that refuses a physical plan still holding a LogicalPlan.

- `physical_plan`: the segment descriptor `SegmentDescPod`, its `SourceSpecPod` (a Parquet source names one file, or lists several with their Hive partition columns and values; a `SOURCE_GENERATE_SERIES` source carries the `scan_source.series_scan.SeriesSpec` of a `generate_series` / `range` call in `series_spec`), the `MorselOp` operator, the source, operator, sink and edge tags, and `PHYSICAL_PLAN_IR_VERSION` with its door `assert_physical_plan_ir_version_compatible`, which refuses a segment emitted at another IR version. It imports the names of `sink_data`, `parquet_source_data`, `csv_source_spec` and `iceberg_scan_spec`, so each is also importable from `physical_plan.physical_plan`.
- `sink_data`: the sink payloads a segment's `sink_param_id` names (`AggSinkData`, `SortSinkData`, `TopNSinkData`, `PartitionBySinkData`, `PartitionTopNSinkData`, `AsofJoinSinkData`, `HashBuildSinkData`, `SMJBuildSinkData`) and `is_explicit_nulls_first_request`.
- `parquet_source_data`: `ParquetSourceData` and `ParquetRowWindow`, the configuration of a Parquet morsel source, moved out of `physical_plan` unchanged so that file stays under 1000 lines.
- `csv_source_spec`: `CsvSourceSpec`, the `SOURCE_CSV` arm of a `SourceSpecPod` (`csv_spec`): one local CSV file, its dialect, and every column of the file with the type the plan bound it at. An empty spec holds the CSV defaults (a comma, a header row, RFC 4180, no column).
- `iceberg_scan_spec`: `IcebergScanSpec`, the `SOURCE_ICEBERG` arm of a `SourceSpecPod` (`iceberg_spec`): the bound columns with their Iceberg field ids, the data files the host planned (`IcebergDataFileSpec`: the path to open, the path the manifest stores, and the indices of the delete files that apply) and the delete files they refer to (`IcebergDeleteSpec`: path, content 1 position or 2 equality, format, equality columns). An empty spec reads no file and binds no column.
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

A `SOURCE_ICEBERG` spec, as lowering mints one for a scan of an Iceberg table whose files the host planned:

```mojo
from std.testing import assert_equal, assert_true

from arrow.arrow_types import ArrowType
from physical_plan.iceberg_scan_spec import (
    IcebergDataFileSpec,
    IcebergDeleteSpec,
    IcebergScanSpec,
)
from physical_plan.physical_plan import SourceSpecPod

var names = List[String]()
names.append("id")
var types = List[ArrowType]()
types.append(ArrowType.INT64)
var ids = List[Int]()
ids.append(1)
var position_deletes = List[Int]()
position_deletes.append(0)
var files = List[IcebergDataFileSpec]()
files.append(
    IcebergDataFileSpec(
        "/warehouse/orders/data/a.parquet",
        "file:///warehouse/orders/data/a.parquet",
        position_deletes^,
        List[Int](),
    )
)
var deletes = List[IcebergDeleteSpec]()
deletes.append(
    IcebergDeleteSpec(
        "/warehouse/orders/data/a-deletes.parquet",
        1,
        "PARQUET",
        List[String](),
    )
)
var spec = SourceSpecPod.iceberg(
    IcebergScanSpec(names^, types^, ids^, files^, deletes^)
)
assert_equal(len(spec.iceberg_spec.data_files), 1)
assert_equal(spec.iceberg_spec.data_files[0].position_deletes[0], 0)
assert_equal(spec.iceberg_spec.deletes[0].content, 1)
# Any other arm's spec holds no file and no column.
var other = SourceSpecPod.batch(0)
assert_equal(len(other.iceberg_spec.data_files), 0)
assert_true(spec.iceberg_spec.column_types[0] == ArrowType.INT64)
```
