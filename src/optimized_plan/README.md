# `optimized_plan`

## Responsibility

The optimized plan's serialization (`docs/design/optimized_plan.md` §7.1,
§7.2): the canonical protobuf encoding of every message reachable from
`OptimizedPlanBody`, `OptimizedSegment` and `DigestTrailer`, the bytes a digest
is taken over, and on top of it the digest, the producer and the executor's
admission.

The BUCK file's `closure_excludes = ["optimizer"]` keeps the optimizer out of
this package's dependency closure (design §7.3): a host that links this package
does not link the optimizer. Analysis fails if a dependency brings it in
(`tools/build/mojo/README.md`).

- `canonical_encoder`: `CanonicalPbEncoder`, a `WireEncoder` whose output is
  canonical, and `encode_canonical`, which encodes any `Serializable` with it.
  Fields are written in ascending field-number order (the generated `encode`
  writes in declaration order, oneof arms last, so records are sorted when a
  message ends, nested messages included). A scalar at its default is omitted;
  a set message field is written even when empty and an unset one is not
  written; a repeated numeric scalar is packed into one record and omitted when
  empty; a repeated string, bytes or message is one record per element in list
  order. Varints are minimal, every NaN is written as one bit pattern (double
  `0x7FF8000000000000`, float `0x7FC00000`) and `-0.0` stays distinct from
  `+0.0`. The bytes are those protoc's serializer gives, except for NaN; the
  welded tests compare them with protoc's encodings of the plan goldens.

A map field is refused with `CANONICAL_MAP_UNSUPPORTED`: no message of the plan
protos has one, and protoc leaves a map's entry order open. Every refusal is an
`Error` whose text begins with its token.

## Digest, producer and admission

- `optimized_plan_digest(body, header)`: `plan_digest = sha256(body ‖
  canonical(DigestTrailer))` (§7.1). The trailer copies `format_version`,
  `producer.optimizer_contract_version`, `write_target`, `needs.udfs`,
  `needs.runtimes` and `needs.data_scopes` from the header.
- `produce_optimized_plan(plan, stamp, write_target)`: serializes a plan the
  caller has already optimized (the producer never calls the optimizer) into
  canonical `OptimizedPlan` bytes: body `OptimizedPlanBody{plan}` from
  `plan_wire`'s OPTIMIZED encoder, needs with `unbounded = false`, versions
  from `optimized_plan_header`, digest, output canonical so equal plans give
  equal bytes. The producer sets the stamp's contract version. It does not
  strip scan statistics (plan_ir has no whole-tree rewrite of scans): a scan
  with `row_count` or `table_stats` is refused `OPTIMIZED_FIELD_UNSUPPORTED`,
  and a join with no recorded build side `OPTIMIZED_JOIN_BUILD_SIDE_MISSING`.
- `admit_optimized_plan(bytes, revoked_builds)`: the executor's door, §7.2 in
  order: header steps 1-3, contract (4), the body's framing
  (`OPTIMIZED_PLAN_BODY_MALFORMED`; a `shared`, `scan_pins` or `pin_groups`
  record, or `needs.runtimes`, is `OPTIMIZED_FIELD_UNSUPPORTED`), `plan_wire`'s
  OPTIMIZED decode of exactly the bytes of `plan` (its limits and tokens pass
  through), `OPTIMIZED_PLAN_NOT_CANONICAL`, `OPTIMIZED_PLAN_DIGEST_MISMATCH`
  and `OPTIMIZED_NEEDS_UNBOUNDED_MISMATCH`. It returns an
  `AdmittedOptimizedPlan` holding the header and the decoded `LogicalPlan`. A raw
  logical plan (an envelope, a body that is one, a join with no build side) is
  refused by those tokens.

Not here: segments and the cut, shared subplans (`cse_ref`), scan pins and
pin groups, UDFs and runtimes, advice, upgrade chains between contract
versions, the structure checks of step 8 other than the unbounded one, and
lowering (design §12 stages 6 onward).

## Example

```mojo
from std.testing import assert_equal

from optimized_plan import encode_canonical
from plan_proto.optimized_plan import PinGroup


def main() raises:
    var members = List[UInt32]()
    members.append(1)
    members.append(300)
    # An empty `lineage` and a zero `commit_seq` are omitted; `members` is one
    # packed record (tag 0x22, length 3).
    var bytes = encode_canonical(PinGroup("g", "", 0, members^))
    var expected: List[UInt8] = [0x0A, 0x01, 0x67, 0x22, 0x03, 0x01, 0xAC, 0x02]
    assert_equal(len(bytes), len(expected))
    for i in range(len(expected)):
        assert_equal(bytes[i], expected[i])
    print("canonical PinGroup:", len(bytes), "bytes")
```


A produced plan admitted again:

```mojo
from std.testing import assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, SchemaBuilder
from optimized_plan import admit_optimized_plan, produce_optimized_plan
from plan_ir.logical_plan import LogicalPlan, SOURCE_PARQUET
from plan_proto.optimized_plan import ProducerStamp


def main() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    var plan = LogicalPlan.scan("/d/t.parquet", SOURCE_PARQUET, sb.build())
    var build = List[UInt8]()
    for _ in range(32):
        build.append(0xAB)
    var stamp = ProducerStamp(build^, 1, List[UInt8](), "komira/mojo-sdk")
    var bytes = produce_optimized_plan(plan, stamp^)
    var admitted = admit_optimized_plan(bytes^, List[List[UInt8]]())
    assert_true(admitted.plan.is_scan())
    assert_equal(len(admitted.header.plan_digest), 32)
    print("admitted a plan of", admitted.plan.output_schema.num_columns(), "column")
```
