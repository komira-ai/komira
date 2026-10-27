# komira_plan_ir

The LogicalPlan tree, its variants, schema propagation, display, the scan-binding bind pass and audits. The PhysicalPlan IR, its version door and its purity gate are the package [`komira_physical_plan`](https://github.com/komira-ai/komira/tree/main/src/komira_physical_plan), which depends on this one.

A `LogicalPlan` is built bottom-up with its static constructors
(`LogicalPlan.scan`, `filter`, `project`, `aggregate`, `join`, `sort`,
`limit`, ...). Each node computes its output schema when it is built: a
filter keeps its child's columns, a projection derives one field per
expression (an `Alias` names it). The expressions are those of
[`komira_plan_expr`](https://github.com/komira-ai/komira/tree/main/src/komira_plan_expr).

A plan's text (`write_to`, so `String(plan)`) is one line per node, children
indented two spaces under their parent. That text is the plan's identity:
`structural_hash` is the FNV-1a hash of it, so two plans hash alike exactly
when they render alike.

## Examples

Build a scan, a filter, a projection and a limit; read the schema, the
render and the hash:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo module
from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_collections.slab import Slab
from komira_plan_expr.col_expr import col
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import LogicalPlan, SOURCE_PARQUET


def schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, nullable=False))
    sb.add_field(Field("b", ArrowType.INT64, nullable=False))
    return sb.build()


def plan(n: Int) -> LogicalPlan:
    """SELECT b, a * b AS ab FROM t.parquet WHERE a > 1 LIMIT n"""
    var scan = LogicalPlan.scan(String("t.parquet"), SOURCE_PARQUET, schema())
    var filtered = LogicalPlan.filter(col("a") > 1, scan^)
    var exprs = Slab[Expr].create(2)
    exprs.append(col("b").copy_expr())
    exprs.append((col("a") * col("b")).alias("ab"))
    var projected = LogicalPlan.project(exprs^, filtered^)
    return LogicalPlan.limit(n, projected^)


def main() raises:
    var p = plan(3)
    assert_true(p.is_limit())

    # The projection's output schema: one field per expression.
    assert_equal(p.output_schema.num_columns(), 2)
    assert_equal(p.output_schema.field_name(0), "b")
    assert_equal(p.output_schema.field_name(1), "ab")

    # One line per node, each child two spaces under its parent.
    assert_equal(
        String(p),
        String("Limit(n=3)\n")
        + '  Project(exprs=[ColRef(b), Alias(BinaryOp(MUL, ColRef(a), ColRef(b)), "ab")])\n'
        + "    Filter(predicate=BinaryOp(GT, ColRef(a), Literal(ScalarValue(int64, 1))))\n"
        + '      Scan(path="t.parquet", type=PARQUET, source_kind=COLUMNAR)\n',
    )

    # The render is the identity: the same plan built twice hashes alike,
    # a different limit does not.
    assert_equal(p.structural_hash(), plan(3).structural_hash())
    assert_true(p.structural_hash() != plan(4).structural_hash())
```
