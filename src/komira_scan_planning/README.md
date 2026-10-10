# komira_scan_planning

Contracts used while planning a scan over files. The package root exports
nothing; import from its modules:

- `komira_scan_planning.partition_predicate_split`: `split_partition_predicate`
  splits a scan filter (a `komira_plan_expr` `Expr`) into the part on
  partition columns, a `komira_fs` `PartitionPredicate` that can skip whole
  files by their Hive path before any file is opened, and a residual `Expr`
  over the data columns that stays on the scan. The filter is read as a
  conjunction of `AND`ed terms. A term `partition_col <op> literal`
  (`==`, `!=`, `<`, `<=`, `>`, `>=`) becomes a constraint, and so does an `OR`
  chain of equalities on one partition column (as an `IN` list). A term on a
  partition column that cannot be listed this way (an `OR` across columns, a
  column compared with a column) becomes an opaque constraint that keeps every
  file and also stays in the residual. Every other term goes to the residual
  unchanged; the residual is `None` when nothing is left.
  `should_use_pruned_discovery` is true when the split found at least one
  partition constraint.
- `komira_scan_planning.partition_pred_bridge`: `pod_from_predicate` and
  `predicate_from_pod` convert between that `PartitionPredicate` and the
  `PartitionPredicatePod` a plan node carries, losslessly.
- `komira_scan_planning.source_capability_config`: `SourceCapabilityConfig`,
  the options a columnar source is built with (pushed predicates, late
  materialisation, dictionary and bloom filter hooks, morsel size, prefetch,
  a row-group window). `SourceCapabilityConfig.default()` turns all of them off.
- `komira_scan_planning.reader_factory`: the `ReaderFactory` and `Reader`
  traits a file format implements so a scan can open a file and decode its
  units (row groups) and columns.

This package lists no files, opens no files and decodes nothing itself;
implementations of `ReaderFactory` live in the format packages.

## Examples

Split `dt = '2026-11-04' AND amount > 100` over a table partitioned by `dt`
and `region`:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import Expr, BIN_AND, BIN_EQ, BIN_GT, BIN_OR
from komira_plan_expr.scalar_value import ScalarValue
from komira_scan_planning.partition_predicate_split import should_use_pruned_discovery, split_partition_predicate

var partition_cols = List[String]()
partition_cols.append("dt")
partition_cols.append("region")
var partition_types = List[ArrowType]()
partition_types.append(ArrowType.STRING)
partition_types.append(ArrowType.STRING)

var on_dt = Expr.binary(BIN_EQ, Expr.col_ref("dt"), Expr.literal(ScalarValue.from_string("2026-11-04")))
var on_amount = Expr.binary(BIN_GT, Expr.col_ref("amount"), Expr.literal(ScalarValue.from_int(100)))
var split = split_partition_predicate(
    Expr.binary(BIN_AND, on_dt^, on_amount^), partition_cols, partition_types
)

assert_equal(split.partition_predicate.num_constraints(), 1)
ref c = split.partition_predicate.constraints[0]
assert_equal(c.col, "dt")
assert_true(c.is_equality())
assert_equal(c.values[0], "2026-11-04")
assert_true(Bool(split.residual))  # amount > 100 stays on the scan
assert_true(should_use_pruned_discovery(split))

# An OR chain of equalities on one partition column becomes an IN list.
var dt_a = Expr.binary(BIN_EQ, Expr.col_ref("dt"), Expr.literal(ScalarValue.from_string("a")))
var dt_b = Expr.binary(BIN_EQ, Expr.col_ref("dt"), Expr.literal(ScalarValue.from_string("b")))
var either = split_partition_predicate(
    Expr.binary(BIN_OR, dt_a^, dt_b^), partition_cols, partition_types
)
assert_true(either.partition_predicate.constraints[0].is_enumerable())
assert_equal(len(either.partition_predicate.constraints[0].values), 2)
assert_true(not Bool(either.residual))  # nothing left for the data columns

# A filter on data columns only prunes no files.
var data_only = split_partition_predicate(
    Expr.binary(BIN_GT, Expr.col_ref("amount"), Expr.literal(ScalarValue.from_int(5))),
    partition_cols,
    partition_types,
)
assert_equal(data_only.partition_predicate.num_constraints(), 0)
assert_true(not should_use_pruned_discovery(data_only))
```

The partition predicate travels on a plan node as a `PartitionPredicatePod`
and converts back unchanged:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_arrow.arrow_types import ArrowType
from komira_fs.pruned_hive_discovery import PartitionConstraint, PartitionPredicate
from komira_scan_planning.partition_pred_bridge import pod_from_predicate, predicate_from_pod
from komira_scan_planning.source_capability_config import SourceCapabilityConfig

var regions = List[String]()
regions.append("eu")
regions.append("us")
var constraints = List[PartitionConstraint]()
constraints.append(PartitionConstraint.eq("dt", "2026-11-04", ArrowType.STRING))
constraints.append(PartitionConstraint.in_list("region", regions, ArrowType.STRING))
var predicate = PartitionPredicate(constraints=constraints^)

var pod = pod_from_predicate(predicate)
assert_equal(len(pod.constraints), 2)
var back = predicate_from_pod(pod)
assert_equal(back.num_constraints(), 2)
assert_equal(back.constraints[1].col, "region")
assert_equal(back.constraints[1].op, predicate.constraints[1].op)
assert_equal(back.constraints[1].values[1], "us")
assert_equal(back.constraint_index_for("region"), 1)

var config = SourceCapabilityConfig.default()
assert_true(not config.count_only)
assert_true(not config.row_window_active)
assert_equal(config.morsel_rows, 0)
```
