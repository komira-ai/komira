# komira_plan_stats

Plan-time statistics: the StatsProvider trait, ColumnStats and TableStats, the physical-type tag, the exact/inexact/absent precision lattice, per-source statistics, and the group-count and table-statistics estimators built on the HyperLogLog sketch of komira_collections.

Nothing here reads a file. A source format implements `StatsProvider` (row
groups, row count, and per-column physical type, min/max, distinct and null
counts, and HyperLogLog registers when the writer kept them), and the
estimators in `komira_plan_stats.cardinality_estimator` read only that trait:

- `estimate_groups` is the GROUP BY group count: the product of the keys'
  distinct counts, clamped to the row count, or `None` when a key has no
  distinct-count signal or the source has no rows.
- `build_table_stats_from_provider` turns a provider into a `TableStats`, the
  per-column `ColumnStats` a scan carries into the cost model.
- `merge_table_stats` unions the `TableStats` of several sources: row and
  null counts add; a column's distinct count is the estimate of the union of
  the sources' sketches when every source has one, else the largest
  per-source count.

`PrecisionScalar` tags a statistic as exact, inexact (an estimate) or absent.

There is no facade: import from the sub-modules
(`komira_plan_stats.stats_provider`, `komira_plan_stats.table_stats`, and so
on).

## Examples

A provider over an in-memory table, and the group counts it gives:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo module
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_stats.cardinality_estimator import estimate_groups
from komira_plan_stats.physical_type import PhysicalType
from komira_plan_stats.stats_provider import StatsProvider


struct Orders(StatsProvider):
    """1000 rows in 2 row groups: 4 regions, 30 days, 900 customers."""

    var names: List[String]
    var distinct: List[Int]

    def __init__(out self):
        self.names = ["region", "day", "customer"]
        self.distinct = [4, 30, 900]

    def num_row_groups(self) -> Int:
        return 2

    def total_row_count(self) -> Int:
        return 1000

    def column_physical_type(self, name: String) -> Optional[PhysicalType]:
        return None

    def column_rg_min_max(
        self, name: String, rg_idx: Int
    ) -> Optional[Tuple[ScalarValue, ScalarValue]]:
        return None

    def column_min_max(self, name: String) -> Optional[Tuple[ScalarValue, ScalarValue]]:
        return None

    def column_distinct_count(self, name: String) -> Optional[Int]:
        return self.column_ndv_estimate(name)

    def column_null_count(self, name: String) -> Optional[Int]:
        return Optional[Int](0)

    def column_ndv_estimate(self, name: String) -> Optional[Int]:
        for i in range(len(self.names)):
            if self.names[i] == name:
                return Optional[Int](self.distinct[i])
        return None

    def column_ndv_estimate_from_hll(self, name: String) -> Bool:
        return False

    def column_merged_hll_registers(self, name: String) -> Optional[List[UInt8]]:
        return None


def main() raises:
    var orders = Orders()
    var by_region: List[String] = ["region"]
    var by_region_day: List[String] = ["region", "day"]
    var by_customer_day: List[String] = ["customer", "day"]
    var by_unknown: List[String] = ["region", "coupon"]

    assert_equal(estimate_groups(orders, List[String]()).value(), 1)  # no keys: one group
    assert_equal(estimate_groups(orders, by_region).value(), 4)
    assert_equal(estimate_groups(orders, by_region_day).value(), 120)  # 4 * 30
    # 900 * 30 is more groups than rows: clamped to the row count.
    assert_equal(estimate_groups(orders, by_customer_day).value(), 1000)
    # A key with no distinct-count signal: no estimate.
    assert_false(Bool(estimate_groups(orders, by_unknown)))
```

Two sources' statistics merged. Neither carries sketch registers, so a
column's distinct count is the larger of the two, and the result says so:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_plan_stats.cardinality_estimator import merge_table_stats
from komira_plan_stats.table_stats import (
    ColumnStats,
    STATS_SOURCE_PARQUET_METADATA,
    TableStats,
)

var jan = List[ColumnStats]()
jan.append(ColumnStats(distinct_count=Optional[Int](40), null_count=Optional[Int](2)))
var feb = List[ColumnStats]()
feb.append(ColumnStats(distinct_count=Optional[Int](65), null_count=Optional[Int](5)))
var sources = List[TableStats]()
sources.append(TableStats(600, ["customer"], jan^))
sources.append(TableStats(400, ["customer"], feb^))

var merged = merge_table_stats(sources)
assert_equal(merged.row_count, 1000)  # rows add
assert_equal(merged.column_distinct_count("customer").value(), 65)  # the larger
assert_false(merged.column_distinct_count_from_hll("customer"))  # not a sketch union
assert_equal(merged.column_stats[0].null_count.value(), 7)  # nulls add
assert_equal(merged.source, STATS_SOURCE_PARQUET_METADATA)
assert_false(Bool(merged.column_distinct_count("coupon")))  # no such column
```

The precision lattice:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_stats.precision_scalar import PrecisionScalar

var footer_max = PrecisionScalar.exact(ScalarValue.from_int(99))
var sampled_ndv = PrecisionScalar.inexact(ScalarValue.from_int(1200))
var unknown = PrecisionScalar.absent()

assert_true(footer_max.is_exact())
assert_true(footer_max.is_present())
assert_true(footer_max.value.value() == ScalarValue.from_int(99))
assert_true(sampled_ndv.is_inexact())
assert_true(sampled_ndv.is_present())
assert_false(sampled_ndv.is_exact())
assert_true(unknown.is_absent())
assert_false(unknown.is_present())
assert_false(Bool(unknown.value))
```
