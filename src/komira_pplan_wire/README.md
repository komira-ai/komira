# komira_pplan_wire

A byte format for one physical plan shape, `PROJECT? -> FILTER* -> SCAN(parquet)`:
a `ParquetSourceData` (the Parquet source of `komira_plan_ir`) and the
`MorselOp` operators that run over it. `pplan_to_bytes` encodes the pair and
`pplan_from_bytes` decodes it into a `PhysicalCollectPlan`. The format is
little-endian and length-prefixed, starts with the magic `PPW1` and a format
version (`PPLAN_WIRE_FORMAT_VERSION`), and needs no protobuf runtime. Encoding
is deterministic: the same plan always gives the same bytes.

What it carries: the source's file path, projection, pushed filter, file
system descriptor, explicit paths, row window and the two dictionary flags;
the operators `FILTER`, `PROJECT` and `LIMIT`; the expression kinds column
reference, literal, binary operator, unary operator and alias; and every field
of a `ScalarValue`. Anything else is refused by name rather than dropped: a
Hive partition column list or Hive predicate, any other operator or
expression kind (a `CAST` or a string match included), and on decode a wrong
magic or version, truncation, trailing bytes, an out-of-vocabulary code, a
negative count, a non-UTF-8 identifier, a value out of range, a `PROJECT`
whose name and expression counts differ, or an expression nested deeper than
64. Each refusal is an error whose text contains one of the exported
`PPLAN_WIRE_*` names.

`pplan_fields_equal` (with `pq_data_equal`, `ops_equal`, `exprs_equal` and
`scalars_equal`) compares two plans field for field; it is what a round-trip
test asserts on. It does not check that a `ScalarValue`'s fields agree with
its kind. The source's `payload_narrow` list is not part of the format: a
decoded plan has it empty.

## Examples

A plan with a projection, a pushed filter, two filters, a projection operator
and a limit round-trips field for field:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_collections.slab import Slab
from komira_plan_expr.col_expr import col
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import ExprArray
from komira_plan_ir.physical_plan import MorselOp, ParquetSourceData
from komira_pplan_wire import pplan_fields_equal, pplan_from_bytes, pplan_to_bytes

var columns = List[String]()
columns.append("id")
columns.append("amount")
var source = ParquetSourceData(
    "events.parquet",
    Optional[List[String]](columns^),
    Optional[Expr](col("amount") > 3),
)

var ops = Slab[MorselOp]()
ops.append(MorselOp.filter(col("status") == 1))
ops.append(MorselOp.filter(col("region") == String("us")))
var exprs = ExprArray()
exprs.append(col("id").copy_expr())
exprs.append(col("amount").alias("amt"))
var names = List[String]()
names.append("id")
names.append("amt")
ops.append(MorselOp.project(exprs^, names^))
ops.append(MorselOp.limit(10))

var wire = pplan_to_bytes(source, ops)
assert_equal(wire[0], UInt8(0x50))  # 'P', the start of the magic "PPW1"
var plan = pplan_from_bytes(wire.copy())
assert_equal(plan.pq_data.file_path, "events.parquet")
assert_equal(len(plan.ops), 4)
assert_true(pplan_fields_equal(source, ops, plan.pq_data, plan.ops))

# The same plan encodes to the same bytes.
var again = pplan_to_bytes(plan.pq_data, plan.ops)
assert_equal(len(again), len(wire))
for i in range(len(wire)):
    assert_equal(again[i], wire[i])
```

What the format cannot carry, and bytes that are not a plan, are refused by
name:

<!-- mojo-hidden from std.testing import assert_true -->
```mojo
from komira_collections.slab import Slab
from komira_plan_expr.col_expr import col
from komira_plan_expr.expr import Expr, STR_CONTAINS
from komira_plan_ir.physical_plan import MorselOp, ParquetSourceData
from komira_pplan_wire import PPLAN_WIRE_BAD_MAGIC, PPLAN_WIRE_TRAILING_BYTES, PPLAN_WIRE_TRUNCATED, PPLAN_WIRE_UNSUPPORTED_EXPR_TAG, pplan_from_bytes, pplan_to_bytes

def decode_error(var data: List[UInt8]) -> String:
    try:
        _ = pplan_from_bytes(data^)
    except e:
        return String(e)
    return String("decoded")

var no_filter: Optional[Expr] = None
var source = ParquetSourceData("t.parquet", None, no_filter^)

# A string match is not one of the five expression kinds the format carries.
var unsupported = Slab[MorselOp]()
unsupported.append(MorselOp.filter(Expr.string_op(STR_CONTAINS, Expr.col_ref("name"), "smith")))
var encode_error = String("encoded")
try:
    _ = pplan_to_bytes(source, unsupported)
except e:
    encode_error = String(e)
assert_true(PPLAN_WIRE_UNSUPPORTED_EXPR_TAG in encode_error)

var ops = Slab[MorselOp]()
ops.append(MorselOp.limit(1))
var wire = pplan_to_bytes(source, ops)
assert_true(decode_error(wire.copy()) == "decoded")

var bad_magic = wire.copy()
bad_magic[0] = 0
assert_true(PPLAN_WIRE_BAD_MAGIC in decode_error(bad_magic^))

var trailing = wire.copy()
trailing.append(7)
assert_true(PPLAN_WIRE_TRAILING_BYTES in decode_error(trailing^))

var cut = List[UInt8]()
for i in range(len(wire) - 1):
    cut.append(wire[i])
assert_true(PPLAN_WIRE_TRUNCATED in decode_error(cut^))
```
