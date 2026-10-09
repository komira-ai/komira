# komira_lowering_rules

Host lowering rules. A host that runs an optimized plan never re-optimizes it;
while it lowers the plan to physical operators it applies only a closed list of
host-local rules. Each rule here is a pure function of the admitted plan and of
facts the host verified against the plan's pins, such as the statistics in the
Parquet footers it opened. A rule reads nothing else (no file, clock,
environment variable or global), does not change the plan, and gives the same
result for the same arguments. No rule reads a statistic a producer recorded on
the plan.

The package root exports nothing; import each rule's module:

- `komira_lowering_rules.payload_narrow`: `derive_payload_narrow(plan,
  footer_stats)`, payload narrowing for equi-joins. `footer_stats` holds one
  `Optional[TableStats]` per scan of the plan, in scan pre-order (a node before
  its children, a join's left side before its right, a union's children in
  order; plans inside expressions are not walked). The result holds, per scan
  in the same order, the `PayloadNarrowSpec`s (`komira_plan_expr.payload_narrow`)
  for the integer payload columns a join carries: for an INNER join with no
  residual and one key per side, on each side that is FILTER and pure PROJECT
  nodes over a Parquet scan, every column that is not that side's key, is
  declared INT64 and non-nullable, and has integer footer bounds whose span
  fits 1, 2 or 4 bytes is narrowed to the narrowest of those, with the footer
  minimum as its base. A footer list whose length is not the scan count is
  refused (`LOWERING_PAYLOAD_NARROW_FOOTER_COUNT`), and so is a node tag that
  is no `PLAN_*` tag (`LOWERING_SCAN_ORDER_UNKNOWN_TAG`). The module header
  states the rule in full.

The decisions are the ones `komira_optimizer`'s payload-narrowing pass makes
when each scan's plan statistics equal its footers;
`src/tests/conformance/komira_lowering_rules_conformance` checks this on a
fixture set and holds the expected results as a golden file.

The package may not depend on `komira_optimizer`, `komira_sql` or a plan
producer: its `BUCK` refuses such a dep when it loads.

## Example

A join of two Parquet scans whose payload columns have footer bounds
`[1, 999]` and `[1, 9999]`: each is carried in two bytes with base 1, and the
join key is never narrowed.

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, SchemaBuilder
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import LogicalPlan, SOURCE_PARQUET, JOIN_INNER
from komira_plan_stats.table_stats import ColumnStats, TableStats
from komira_lowering_rules.payload_narrow import derive_payload_narrow

def scan(payload: String) -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field("key", ArrowType.INT64, False))
    sb.add_field(Field(payload, ArrowType.INT64, False))
    return LogicalPlan.scan(payload + ".parquet", SOURCE_PARQUET, sb.build())

def footer(payload: String, hi: Int64) -> Optional[TableStats]:
    var names = List[String]()
    names.append("key")
    names.append(payload)
    var stats = List[ColumnStats]()
    stats.append(ColumnStats(None, Optional[ScalarValue](ScalarValue.from_int64(0)), Optional[ScalarValue](ScalarValue.from_int64(24999999))))
    stats.append(ColumnStats(None, Optional[ScalarValue](ScalarValue.from_int64(1)), Optional[ScalarValue](ScalarValue.from_int64(hi))))
    return Optional[TableStats](TableStats(1000, names^, stats^))

var keys = List[String]()
keys.append("key")
var plan = LogicalPlan.join(scan("probe_val"), scan("build_val"), keys.copy(), keys.copy(), JOIN_INNER)
var footers = List[Optional[TableStats]]()
footers.append(footer("probe_val", 999))
footers.append(footer("build_val", 9999))

var specs = derive_payload_narrow(plan, footers)
assert_equal(len(specs), 2)  # one list per scan, in scan pre-order
assert_equal(len(specs[0]), 1)  # the key is not narrowed
assert_equal(specs[0][0].column_name, String("probe_val"))
assert_equal(Int(specs[0][0].target_bytes), 2)
assert_equal(Int(specs[0][0].base), 1)
assert_equal(specs[1][0].column_name, String("build_val"))
assert_equal(Int(specs[1][0].target_bytes), 2)
```
