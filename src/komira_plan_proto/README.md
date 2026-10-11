# `komira_plan_proto`

## Responsibility

The logical plan IR on the wire: the protobuf schema `komira.plan.v1` and
the Mojo structs generated from it. Three files:

- `plan_vocabulary.proto`: every enumerated tag space a plan or expression
  node can name (`PlanTag`, `ExprTag`, `AggFn`, `JoinType`, `ColSide`, ...).
  Wire number = engine tag + 1 in every space, so wire 0 is always the
  `*_WIRE_UNSPECIFIED` value and a missing tag never decodes as a real node.
  A reader must refuse wire 0 and any value it does not know.
- `plan.proto`: the message layer: what a node is (`WirePlan`, `WireExpr`,
  `WireSchema`, ...), and `WirePlanEnvelope`, the top-level message with a
  `format_version`.
- `optimized_plan.proto`: the optimized plan, a plan already optimized once
  that a host lowers without optimizing again. `OptimizedPlan` is a header
  (format version, producer, digest, declared needs, write target, advice)
  over a `body` of bytes that hold an `OptimizedPlanBody` (a `WirePlan`, its
  shared subplans and its snapshot pins); `OptimizedSegment` and
  `OptimizedSegmentDag` are the pieces of a plan cut across hosts. It imports
  `plan.proto` for the plan itself. The design is
  `docs/design/optimized_plan.md` (komira-ai/komira#1094); this is its
  schema stage, and fields whose types later stages add are left free at
  the numbers the design gives them (the file's header lists them). No codec
  reads these messages yet.

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
shipped number never changes. `optimized_plan.proto` has its own ledger,
`tests/test_optimized_plan_field_numbers.mojo`, which also requires that no
declared field takes a number the file holds free or reserves. Its goldens
(`tests/fixtures/optimized/golden/`, one per message) are read by protoc
(the `optimized_plan_golden_fixtures` target) and by the generated codec
(`tests/test_optimized_plan_goldens.mojo`).

## API

| name | file | what it is |
|---|---|---|
| `WirePlanEnvelope`, `WirePlan`, `WireExpr`, ... | [plan.proto](https://github.com/komira-ai/komira/blob/main/src/komira_plan_proto/plan.proto) | the message layer (module `komira_plan_proto.plan`) |
| `OptimizedPlan`, `OptimizedPlanBody`, `OptimizedSegment`, ... | [optimized_plan.proto](https://github.com/komira-ai/komira/blob/main/src/komira_plan_proto/optimized_plan.proto) | the optimized plan (module `komira_plan_proto.optimized_plan`) |
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

An `OptimizedPlan` carries its body as bytes, so a reader of the header
never decodes the plan; the body decodes on its own as an
`OptimizedPlanBody`:

```mojo
from komira_plan_proto.optimized_plan import DeclaredNeeds, OptimizedPlan, OptimizedPlanBody
from komira_plan_proto.optimized_plan import ProducerStamp, RuntimeNeed, ScanPin
from komira_proto_codec import decode_proto, encode_proto
from std.testing import assert_equal, assert_true

var fingerprint: List[UInt8] = [1, 2, 3]
var pin = ScanPin(String("orders"), fingerprint^)
var body = OptimizedPlanBody(None, [], [pin^], [])
var needs = DeclaredNeeds(
    [String("orders")], True, [RuntimeNeed(String("komira/python"), String("cp312"))]
)
var stamp = ProducerStamp([], UInt32(1), [], String("komira/mojo-sdk"))
var header = OptimizedPlan(
    UInt32(1), stamp^, [], [], needs^, None, None, encode_proto(body)
)

var back = decode_proto[OptimizedPlan](encode_proto(header))
assert_true(back.needs.value().unbounded)
assert_equal(back.producer.value().kind, "komira/mojo-sdk")
# `body` is bytes until a reader chooses to decode it.
var inner = decode_proto[OptimizedPlanBody](back.body.copy())
assert_equal(inner.scan_pins[0].binding_key, "orders")
```
