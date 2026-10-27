# komira_plan_wire

The byte format of a logical plan: `plan_to_bytes` encodes a `komira_plan_ir`
`LogicalPlan` as a `komira.plan.v1.WirePlanEnvelope` protobuf message (from
`komira_plan_proto`) and `plan_from_bytes` decodes one, so a plan can be
written by one program, in any language, and executed by another. A decoded
plan renders to the same text as the original, so its structural hash is the
same; `plan_round_trip` does both directions in one call.
`plan_to_bytes_with_write_target` adds a destination (`COPY <plan> TO
<target>`) and declares format version 5; a plain plan declares version 4,
and `plan_wire_supported_versions` is the set this build reads.
`schema_to_bytes` and `binding_to_bytes` let a frontend in another language
write the schema of a Parquet scan or a whole scan binding without computing
the engine's codes itself.

Decoding treats the bytes as untrusted. Before parsing, `plan_wire_admit`
refuses a message over `PLAN_WIRE_MAX_BYTES` (16 MiB), a version this build
does not read, a write target under a version that predates it, and a plan
deeper than `PLAN_WIRE_MAX_DEPTH` (64) or larger than `PLAN_WIRE_MAX_NODES`.
After parsing, `plan_wire_check_values` refuses values the engine cannot
execute, such as a column name the input schema does not have, a positional
column reference, a negative count or empty sort keys. Encoding refuses what
the format cannot carry rather than dropping it: an in-memory source, a
Hive-partitioned or non-local Parquet scan, an undescribable user-defined
function and the other shapes the codec's ledger lists. Every refusal is an
error whose text starts with one of the exported `PLAN_WIRE_*` or
`OPTIMIZED_UDF_*` names.

The decoder rebuilds every node through its `LogicalPlan` factory and refuses
a message whose `output_schema` differs from the one the factory derives
(`PLAN_WIRE_OUTPUT_SCHEMA_DIVERGED`). For a join, that schema marks the side
that supplies NULLs as nullable: the right side's fields of a LEFT join, the
left side's of a RIGHT join, both sides' of a FULL join, and the right side's
of an as-of join. A producer in another language must write `nullable: true`
for those fields even when the input column is not nullable.

This package does not optimize or execute a plan.

## Examples

Scan, filter and limit a Parquet file, encode the plan and decode it again:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.expr import Expr, BIN_GT
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import LogicalPlan
from komira_scan_source.parquet_source import ParquetSource
from komira_scan_source.source_variant import SourceVariant
from komira_plan_wire import plan_from_bytes, plan_to_bytes, plan_wire_admit, plan_wire_supported_versions

def orders_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("qty", ArrowType.INT64, True))
    sb.add_field(Field("note", ArrowType.STRING, True))
    return sb.build()

def orders_plan(column: String) raises -> LogicalPlan:
    var scan = LogicalPlan.scan_from_source(
        SourceVariant(ParquetSource("orders.parquet", orders_schema())), orders_schema()
    )
    var over_25 = Expr.binary(BIN_GT, Expr.col_ref(column), Expr.literal(ScalarValue.from_int64(25)))
    return LogicalPlan.limit(10, LogicalPlan.filter(over_25^, scan^))

var plan = orders_plan("qty")
var wire = plan_to_bytes(plan)
plan_wire_admit(wire, plan_wire_supported_versions())  # the checks before parsing pass
var back = plan_from_bytes(wire.copy())
assert_equal(String(back), String(plan))  # the same plan text
assert_equal(back.structural_hash(), plan.structural_hash())
assert_equal(back.output_schema.field_name(1), "qty")
```

A plan whose filter names a column the scan does not have, and bytes that are
not a whole message, are refused when decoded:

<!-- mojo-hidden
from std.testing import assert_true
from komira_arrow.schema import Field
from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema, SchemaBuilder
from komira_plan_expr.expr import BIN_GT, Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import LogicalPlan
from komira_scan_source.parquet_source import ParquetSource
from komira_scan_source.source_variant import SourceVariant

def orders_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("qty", ArrowType.INT64, True))
    sb.add_field(Field("note", ArrowType.STRING, True))
    return sb.build()

def orders_plan(column: String) raises -> LogicalPlan:
    var scan = LogicalPlan.scan_from_source(
        SourceVariant(ParquetSource("orders.parquet", orders_schema())), orders_schema()
    )
    var over_25 = Expr.binary(BIN_GT, Expr.col_ref(column), Expr.literal(ScalarValue.from_int64(25)))
    return LogicalPlan.limit(10, LogicalPlan.filter(over_25^, scan^))
-->
```mojo
from komira_plan_wire import PLAN_WIRE_UNRESOLVED_COLUMN, plan_from_bytes, plan_to_bytes

def decode_error(var data: List[UInt8]) -> String:
    try:
        _ = plan_from_bytes(data^)
    except e:
        return String(e)
    return String("decoded")

var good = plan_to_bytes(orders_plan("qty"))
assert_true(decode_error(good.copy()) == "decoded")

var unknown_column = plan_to_bytes(orders_plan("quantity"))
assert_true(PLAN_WIRE_UNRESOLVED_COLUMN in decode_error(unknown_column^))

# Field 1 claims 127 bytes and one follows.
var truncated: List[UInt8] = [0x0A, 0x7F, 0x00]
assert_true(decode_error(truncated^) != "decoded")
```

## User code: `UdfRef` and the UDF arms

A plan calls user functions by index into a list that travels beside it
(docs/design/optimized_plan_udfs.md §10.3-§10.4): a `UdfRef`
(`komira_plan_ir.udf_ref`) names the runtime, the code, the argument and
return types (nested to any depth, `komira_plan_expr.udf_type.UdfType`) and,
for a ROW or frame function, the columns it reads. Three plan arms call one:
`EXPR_UDF_APPLY` in an expression (inside an `AGG_UDF` measure for an
aggregate), `PLAN_MAP_BATCHES` over a child, and `PLAN_STEP` as a source.

A RAW plan carries the list in its envelope: `plan_to_bytes_with_udfs`
writes it, and `plan_envelope_from_bytes` returns it beside the plan
(`plan_from_bytes` refuses such an envelope, `PLAN_WIRE_UDFS_DROPPED`, since
a `LogicalPlan` cannot carry the list). An optimized plan carries the list in
its declared needs; `optimized_plan_from_bytes` decodes a bare `WirePlan`
against it in the OPTIMIZED context, which also refuses the named UDF forms
(`OPTIMIZED_UDF_LEGACY_FORM`), and `optimized_plan_to_bytes` encodes one and
checks it the same way. `udf_ref_to_bytes` and `udf_ref_from_bytes` convert
one entry. Every decoder checks each entry on its own (a missing return type,
a malformed runtime id, a read set on the wrong kind or out of order) and
then every call against the entry it names (`plan_wire_check_udfs`: the
index, the kind, the argument types, the read set against the input, the
node schema against the return type). An unset read set means every input
column; an empty one means none, and the two never share bytes.

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.expr import Expr
from komira_plan_expr.udf_data import UDF_NULL_MANUAL, UDF_NULL_PROPAGATE, UDF_STABILITY_STABLE
from komira_plan_expr.udf_type import UdfType
from komira_plan_ir.logical_plan import ExprArray, LogicalPlan
from komira_plan_ir.udf_ref import UdfCode, UdfRef, UDF_REF_KIND_ROW, UDF_REF_KIND_SCALAR, CODE_FORM_PACKAGE
from komira_scan_source.parquet_source import ParquetSource
from komira_scan_source.source_variant import SourceVariant
from komira_plan_wire import plan_to_bytes_with_udfs, plan_envelope_from_bytes, plan_wire_check_udfs
from komira_plan_wire import optimized_plan_from_bytes, optimized_plan_to_bytes
from komira_plan_wire import udf_ref_from_bytes, udf_ref_to_bytes, udf_runtime_id_is_valid
from komira_plan_wire import OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH

def f64(name: String) -> UdfType:
    return UdfType(name, ArrowType.FLOAT64, DType.float64, True)

def score() -> UdfRef:
    """A SCALAR `score(x: float64) -> float64` from an installed package."""
    var args = List[UdfType]()
    args.append(f64("x"))
    return UdfRef(
        UDF_REF_KIND_SCALAR, UdfCode("komira/python", CODE_FORM_PACKAGE, "pkg.mod:score"),
        args^, Optional(f64("score")), UDF_STABILITY_STABLE, UDF_NULL_PROPAGATE,
    )

def prices() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("price", ArrowType.FLOAT64, True))
    return sb.build()

def scored(column: String) raises -> LogicalPlan:
    var scan = LogicalPlan.scan_from_source(
        SourceVariant(ParquetSource("prices.parquet", prices())), prices()
    )
    var call_args = List[Expr]()
    call_args.append(Expr.col_ref(column))
    var exprs = ExprArray()
    exprs.append(Expr.alias(Expr.udf_apply(0, f64("score"), call_args^), "s"))
    return LogicalPlan.project(exprs^, scan^)

var udfs = List[UdfRef]()
udfs.append(score())
var plan = scored("price")

# RAW: the list rides in the envelope and comes back beside the plan.
var raw = plan_envelope_from_bytes(plan_to_bytes_with_udfs(plan, udfs))
assert_equal(len(raw.udfs), 1)
assert_equal(raw.take_plan().structural_hash(), plan.structural_hash())

# OPTIMIZED: a bare plan, decoded against the list the optimized plan declares.
var back = optimized_plan_from_bytes(optimized_plan_to_bytes(plan, udfs), udfs)
assert_equal(back.output_schema.field_name(0), "s")

# A call whose argument is not the declared type is refused by name: `id` is int64.
var refused = String("")
try:
    plan_wire_check_udfs(scored("id"), udfs)
except e:
    refused = String(e)
assert_true(refused.startswith(OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH))

# Unset and empty read sets are different values with different bytes.
var every = UdfRef(
    UDF_REF_KIND_ROW, UdfCode("komira/python", CODE_FORM_PACKAGE, "pkg.mod:row"),
    List[UdfType](), Optional(f64("r")), UDF_STABILITY_STABLE, UDF_NULL_MANUAL,
)
var none = every.copy()
none.read_set = Optional(List[String]())
assert_false(Bool(udf_ref_from_bytes(udf_ref_to_bytes(every)).read_set))
assert_true(Bool(udf_ref_from_bytes(udf_ref_to_bytes(none)).read_set))
assert_true(udf_runtime_id_is_valid("example.org/go"))
```
