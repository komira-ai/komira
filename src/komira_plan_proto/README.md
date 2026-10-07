# `komira_plan_proto`

## Responsibility

The logical plan IR on the wire: the protobuf schema `komira.plan.v1` and
the Mojo structs generated from it. Two files:

- `plan_vocabulary.proto`: every enumerated tag space a plan or expression
  node can name (`PlanTag`, `ExprTag`, `AggFn`, `JoinType`, `ColSide`, ...).
  Wire number = engine tag + 1 in every space, so wire 0 is always the
  `*_WIRE_UNSPECIFIED` value and a missing tag never decodes as a real node.
  A reader must refuse wire 0 and any value it does not know.
- `plan.proto`: the message layer: what a node is (`WirePlan`, `WireExpr`,
  `WireSchema`, ...), and `WirePlanEnvelope`, the top-level message with a
  `format_version`.

This package is the schema, not the codec. `komira_plan_wire` converts a
`LogicalPlan` to and from these messages and checks sizes, versions and
nesting before it decodes; use it to send a plan. The generated
`plan_vocabulary` module exists so that other languages reading the
`.proto` see typed enums; the Mojo codec computes wire numbers through its
own vocabulary and only wraps them in these types.

The field-number census pins every field of every message and every enum
value by number, as wire bytes written by hand and read back by name:
`tests/test_plan_field_numbers_{scan,expr,plan}.mojo` and
`tests/test_plan_enum_numbers_{nodes,functions}.mojo`, each from a
hand-written `LEDGER`. `tests/test_plan_census_complete.mojo` fails when
protoc declares a field or value no ledger lists. A new field or value
therefore needs a ledger row and a byte test in the same change, and a
shipped number never changes.

## API

| name | file | what it is |
|---|---|---|
| `WirePlanEnvelope`, `WirePlan`, `WireExpr`, ... | [plan.proto](https://github.com/komira-ai/komira/blob/main/src/komira_plan_proto/plan.proto) | the message layer (module `komira_plan_proto.plan`) |
| `PlanTag`, `ExprTag`, `ColSide`, ... | [plan_vocabulary.proto](https://github.com/komira-ai/komira/blob/main/src/komira_plan_proto/plan_vocabulary.proto) | the tag spaces (module `komira_plan_proto.plan_vocabulary`) |

Each message is a struct whose constructor takes its fields in declaration
order (a message field is an `Optional`, a `repeated` field a `List`); an
enum is a struct over its wire number, with one constant per value. The
structs conform to `komira_proto_codec`'s `Serializable`.

## Example

Every example below runs as a test when the package is built.

```mojo
from komira_plan_proto.plan import WireColRef
from komira_plan_proto.plan_vocabulary import ColSide, PlanTag
from komira_proto_codec import decode_proto, encode_proto
from std.testing import assert_equal

var col = WireColRef(String("amount"), ColSide(ColSide.COL_SIDE_LEFT))
var back = decode_proto[WireColRef](encode_proto(col))
assert_equal(back.name, "amount")
assert_equal(back.side.json_name(), "COL_SIDE_LEFT")

# Wire number = engine tag + 1: the engine's first plan tag, SCAN, is 1 here.
assert_equal(PlanTag.PLAN_WIRE_UNSPECIFIED, 0)
assert_equal(PlanTag.PLAN_SCAN, 1)
```
