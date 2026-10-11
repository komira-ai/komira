# =============================================================================
# test_optimized_plan_goldens.mojo
# =============================================================================
#
# THE OPTIMIZED-PLAN GOLDENS, through this package's generated codec. One
# golden per message of optimized_plan.proto, under fixtures/optimized/golden/
# (BUCK `_OPTIMIZED_GOLDEN`):
#
#   <stem>.txtpb          hand-written text, protoc's print form
#   <stem>.canonical.hex  protoc's encoding of that text
#   <stem>.hex            the generated Mojo encoder's re-encoding of it
#
# The `optimized_plan_golden_fixtures` target holds the three files to protoc
# (decode of `.hex` is the `.txtpb`, encode of the `.txtpb` is the
# `.canonical.hex`, no undeclared field, every enum value named). This test
# holds them to the Mojo side, for each golden:
#   1. READER: the generated decoder reads protoc's bytes (`.canonical.hex`)
#      and every field the text sets reads back BY NAME with the text's
#      value. A field the generated decoder places at another number than
#      protoc does reads as its default here.
#   2. WRITER: the generated encoder writes that decoded message as the
#      committed `.hex`, byte for byte, and decoding the `.hex` and encoding
#      it again gives the same bytes. A writer that moves, drops or retypes a
#      field changes the bytes; protoc's check then also fails, because its
#      decode of the `.hex` no longer prints the `.txtpb`.
# On a writer mismatch the test prints every golden's Mojo bytes as hex
# before it fails, which is how a `.hex` is made: a deliberate change to a
# golden's text is followed by its `.canonical.hex` (the BUCK
# `optimized_golden_<stem>_canonical` target) and then the `.hex` printed
# here, never by hand.
# =============================================================================

from std.pathlib import Path
from std.testing import assert_equal, assert_true

from komira_proto_codec import Serializable, decode_proto, encode_proto
from komira_plan_proto.optimized_plan import (
    DeclaredNeeds,
    ExchangeEdge,
    OptimizedPlan,
    OptimizedPlanBody,
    OptimizedSegment,
    OptimizedSegmentDag,
    PinGroup,
    PlanAdvice,
    ProducerStamp,
    RuntimeNeed,
    ScanPin,
    ScanStats,
    SharedSubplan,
)

comptime _DIR = "fixtures/optimized/golden/"

# sha256 of the fixed strings the goldens' digests were made from; the
# goldens' digests are fixtures, not digests computed from a body (stage 5).
comptime _ENGINE = "4f6fc603903c936efd5359e7a42e103bca318df0614edf6b1f2c42136e453bc4"
comptime _CONFIG = "855aecc8f75deb62975c54b0f6a2d45a69ffdc2b61a1ac8c87d93aaf68dba733"
comptime _PLAN_DIGEST = "fb1a3aa0dec14c3496723edfebcada34a04f48742bd0de5e689a144598708521"
comptime _RECURRING = "ecd896d689e243225a2fd149fe8707cba3c43c9a64793b88d9102e8cde115aa5"
comptime _ORDERS_FP = "2344404db0f2d91381d71978feccf04f92daac6729c44cf5c61f71ea93e1db7c"
comptime _CUSTOMERS_FP = "85e61ce6455a4cdc7270229095f5381e17c36606fa81857fbc3c160c65897d6c"
comptime _SEGMENT_DIGEST = "799f491c7d3e3deaeef2e2c59120cc6d50c96639d593079dec452cc4a4fba9bd"
# `optimized_plan`'s body: OptimizedPlanBody { plan { cse_ref {
# canonical_hash: 77 } } shared { canonical_hash: 77 plan { view_ref {
# view_name: "v" } } } }, protoc's bytes.
comptime _BODY = "0a05920102084d120a084d12068a01030a0176"
# The `cse_ref` / `shared` hash the plan goldens share.
comptime _CSE = UInt64(1234567890123)


# ---- hex ---------------------------------------------------------------------


def _nibble(c: Int) raises -> Int:
    if c >= 48 and c <= 57:
        return c - 48
    if c >= 97 and c <= 102:
        return c - 87
    if c >= 65 and c <= 70:
        return c - 55
    raise Error("not a hex digit: " + chr(c))


def _parse_hex(text: String) raises -> List[UInt8]:
    """The fixture hex format: two digits a byte, whitespace ignored."""
    var out = List[UInt8]()
    var high = -1
    for b in text.as_bytes():
        var c = Int(b)
        if c == 32 or c == 9 or c == 10 or c == 13:
            continue
        var n = _nibble(c)
        if high < 0:
            high = n
        else:
            out.append(UInt8(high * 16 + n))
            high = -1
    if high >= 0 or len(out) == 0:
        raise Error("an odd number of hex digits, or none")
    return out^


def _hex(b: List[UInt8]) -> String:
    """Lowercase, two digits a byte, no separators."""
    comptime digits = "0123456789abcdef"
    var out = String("")
    for i in range(len(b)):
        var v = Int(b[i])
        out += String(digits[byte = v >> 4]) + String(digits[byte = v & 15])
    return out


def _read(path: String) raises -> List[UInt8]:
    return _parse_hex(Path(path).read_text())


# ---- the two legs --------------------------------------------------------------


def _golden[M: Serializable & ImplicitlyDestructible](stem: String, mut mismatched: List[String]) raises -> M:
    """Leg 1's decode of protoc's bytes, after leg 2: the Mojo encoding of
    that decode must be the committed `.hex`, and stable under a second
    decode and encode. A mismatch is collected, with the bytes the encoder
    wrote, so every golden's is printed before the test fails."""
    var m = decode_proto[M](_read(_DIR + stem + ".canonical.hex"))
    var mojo = encode_proto(m)
    var committed = _read(_DIR + stem + ".hex")
    if _hex(mojo) != _hex(committed):
        mismatched.append(stem + " " + _hex(mojo))
        return m^
    var again = encode_proto(decode_proto[M](committed.copy()))
    assert_equal(_hex(again), _hex(committed), stem + ": decoding and re-encoding the committed .hex changes it")
    return m^


def _strings(got: List[String], want: String, what: String) raises:
    var w = want.split(" ")
    assert_equal(len(got), len(w), what + ": element count")
    for i in range(len(w)):
        assert_equal(got[i], String(w[i]), what + "[" + String(i) + "]")


def _u32s(got: List[UInt32], want: List[Int], what: String) raises:
    assert_equal(len(got), len(want), what + ": element count")
    for i in range(len(want)):
        assert_equal(Int(got[i]), want[i], what + "[" + String(i) + "]")


# ---- one check per golden: the values its .txtpb sets ------------------------------


def _check_stamp(m: ProducerStamp, what: String) raises:
    assert_equal(_hex(m.engine_build), _ENGINE, what + ".engine_build")
    assert_equal(m.optimizer_contract_version, UInt32(1), what + ".optimizer_contract_version")
    assert_equal(_hex(m.optimizer_config_digest), _CONFIG, what + ".optimizer_config_digest")
    assert_equal(m.kind, "komira/python-sdk", what + ".kind")


def _check_needs(m: DeclaredNeeds, what: String) raises:
    _strings(m.data_scopes, "orders customers", what + ".data_scopes")
    assert_true(m.unbounded, what + ".unbounded")
    assert_equal(len(m.runtimes), 2, what + ".runtimes: count")
    assert_equal(m.runtimes[0].runtime, "komira/node", what + ".runtimes[0].runtime")
    assert_equal(m.runtimes[0].runtime_abi, "node22", what + ".runtimes[0].runtime_abi")
    assert_equal(m.runtimes[1].runtime, "komira/python", what + ".runtimes[1].runtime")
    assert_equal(m.runtimes[1].runtime_abi, "cp312", what + ".runtimes[1].runtime_abi")


def _check_pin_orders(m: ScanPin, what: String) raises:
    assert_equal(m.binding_key, "orders", what + ".binding_key")
    assert_equal(_hex(m.data_fingerprint), _ORDERS_FP, what + ".data_fingerprint")


def _check_group(m: PinGroup, what: String) raises:
    assert_equal(m.group, "social_graph", what + ".group")
    assert_equal(m.lineage, "graph/lineage", what + ".lineage")
    assert_equal(m.commit_seq, UInt64(42), what + ".commit_seq")
    _u32s(m.members, [0, 1], what + ".members")


def _check_advice(m: PlanAdvice, what: String) raises:
    assert_equal(len(m.stats_basis), 2, what + ".stats_basis: count")
    assert_equal(m.stats_basis[0].pin_index, UInt32(0), what + ".stats_basis[0].pin_index")
    assert_equal(m.stats_basis[0].row_count, UInt64(150000), what + ".stats_basis[0].row_count")
    assert_equal(m.stats_basis[1].pin_index, UInt32(1), what + ".stats_basis[1].pin_index")
    assert_equal(m.stats_basis[1].row_count, UInt64(6001215), what + ".stats_basis[1].row_count")


def _check_shared(m: SharedSubplan, what: String) raises:
    assert_equal(m.canonical_hash, _CSE, what + ".canonical_hash")
    ref p = m.plan.value()
    assert_equal(p.output_schema.value().fields[0].name, "o_orderkey", what + ".plan.output_schema.fields[0].name")
    assert_equal(p.output_schema.value().fields[0].arrow_type_id, UInt32(5), what + ".plan.output_schema.fields[0].arrow_type_id")
    assert_equal(p.view_ref.value().view_name, "orders_v", what + ".plan.view_ref.view_name")


def test_goldens() raises:
    var bad = List[String]()

    _check_stamp(_golden[ProducerStamp]("producer_stamp", bad), "producer_stamp")

    var rn = _golden[RuntimeNeed]("runtime_need", bad)
    assert_equal(rn.runtime, "komira/python", "runtime_need.runtime")
    assert_equal(rn.runtime_abi, "cp312", "runtime_need.runtime_abi")

    _check_needs(_golden[DeclaredNeeds]("declared_needs", bad), "declared_needs")
    _check_pin_orders(_golden[ScanPin]("scan_pin", bad), "scan_pin")
    _check_group(_golden[PinGroup]("pin_group", bad), "pin_group")

    var st = _golden[ScanStats]("scan_stats", bad)
    assert_equal(st.pin_index, UInt32(1), "scan_stats.pin_index")
    assert_equal(st.row_count, UInt64(6001215), "scan_stats.row_count")

    _check_shared(_golden[SharedSubplan]("shared_subplan", bad), "shared_subplan")
    _check_advice(_golden[PlanAdvice]("plan_advice", bad), "plan_advice")

    var body = _golden[OptimizedPlanBody]("optimized_plan_body", bad)
    assert_equal(body.plan.value().cse_ref.value().canonical_hash, _CSE, "optimized_plan_body.plan.cse_ref.canonical_hash")
    assert_equal(len(body.shared), 1, "optimized_plan_body.shared: count")
    _check_shared(body.shared[0], "optimized_plan_body.shared[0]")
    assert_equal(len(body.scan_pins), 2, "optimized_plan_body.scan_pins: count")
    _check_pin_orders(body.scan_pins[0], "optimized_plan_body.scan_pins[0]")
    assert_equal(body.scan_pins[1].binding_key, "customers", "optimized_plan_body.scan_pins[1].binding_key")
    assert_equal(_hex(body.scan_pins[1].data_fingerprint), _CUSTOMERS_FP, "optimized_plan_body.scan_pins[1].data_fingerprint")
    assert_equal(len(body.pin_groups), 1, "optimized_plan_body.pin_groups: count")
    _check_group(body.pin_groups[0], "optimized_plan_body.pin_groups[0]")

    var op = _golden[OptimizedPlan]("optimized_plan", bad)
    assert_equal(op.format_version, UInt32(1), "optimized_plan.format_version")
    _check_stamp(op.producer.value(), "optimized_plan.producer")
    assert_equal(_hex(op.plan_digest), _PLAN_DIGEST, "optimized_plan.plan_digest")
    assert_equal(_hex(op.recurring_signature), _RECURRING, "optimized_plan.recurring_signature")
    _check_needs(op.needs.value(), "optimized_plan.needs")
    assert_equal(op.write_target.value().path, "out/orders/", "optimized_plan.write_target.path")
    assert_equal(op.write_target.value().format.json_name(), "WFMT_PARQUET", "optimized_plan.write_target.format")
    assert_equal(op.write_target.value().codec.json_name(), "WCOMP_ZSTD", "optimized_plan.write_target.codec")
    _check_advice(op.advice.value(), "optimized_plan.advice")
    assert_equal(_hex(op.body), _BODY, "optimized_plan.body")
    # The body is opaque bytes to the header, and a canonical OptimizedPlanBody.
    var inner = decode_proto[OptimizedPlanBody](op.body.copy())
    assert_equal(inner.plan.value().cse_ref.value().canonical_hash, UInt64(77), "optimized_plan.body: plan.cse_ref")
    assert_equal(inner.shared[0].canonical_hash, UInt64(77), "optimized_plan.body: shared[0].canonical_hash")
    assert_equal(inner.shared[0].plan.value().view_ref.value().view_name, "v", "optimized_plan.body: shared[0].plan.view_ref")

    var seg = _golden[OptimizedSegment]("optimized_segment", bad)
    assert_equal(_hex(seg.engine_build), _ENGINE, "optimized_segment.engine_build")
    assert_equal(_hex(seg.parent_plan_digest), _PLAN_DIGEST, "optimized_segment.parent_plan_digest")
    assert_equal(seg.segment_id, UInt32(2), "optimized_segment.segment_id")
    assert_equal(_hex(seg.segment_digest), _SEGMENT_DIGEST, "optimized_segment.segment_digest")
    _strings(seg.needs.value().data_scopes, "orders", "optimized_segment.needs.data_scopes")
    _check_shared(seg.shared[0], "optimized_segment.shared[0]")
    _check_pin_orders(seg.scan_pins[0], "optimized_segment.scan_pins[0]")
    assert_equal(seg._oneof0_case, 1, "optimized_segment: the `logical` arm is set")
    assert_equal(seg.logical.value().cse_ref.value().canonical_hash, _CSE, "optimized_segment.logical.cse_ref")
    _check_group(seg.pin_groups[0], "optimized_segment.pin_groups[0]")

    var dag = _golden[OptimizedSegmentDag]("optimized_segment_dag", bad)
    assert_equal(len(dag.segments), 2, "optimized_segment_dag.segments: count")
    assert_equal(dag.segments[0].segment_id, UInt32(1), "optimized_segment_dag.segments[0].segment_id")
    assert_equal(dag.segments[0].logical.value().view_ref.value().view_name, "orders_v", "optimized_segment_dag.segments[0].logical")
    assert_equal(dag.segments[1].segment_id, UInt32(2), "optimized_segment_dag.segments[1].segment_id")
    assert_equal(len(dag.edges), 1, "optimized_segment_dag.edges: count")
    ref e = dag.edges[0]
    assert_equal(e.producer_segment, UInt32(1), "optimized_segment_dag.edges[0].producer_segment")
    assert_equal(e.consumer_segment, UInt32(2), "optimized_segment_dag.edges[0].consumer_segment")
    _u32s(e.keys, [0, 3], "optimized_segment_dag.edges[0].keys")
    assert_equal(e.partitions, UInt32(8), "optimized_segment_dag.edges[0].partitions")
    assert_equal(e.key_groups, UInt32(128), "optimized_segment_dag.edges[0].key_groups")

    var edge = _golden[ExchangeEdge]("exchange_edge", bad)
    assert_equal(edge.producer_segment, UInt32(3), "exchange_edge.producer_segment")
    assert_equal(edge.consumer_segment, UInt32(4), "exchange_edge.consumer_segment")
    _u32s(edge.keys, [1, 2], "exchange_edge.keys")
    assert_equal(edge.partitions, UInt32(16), "exchange_edge.partitions")
    assert_equal(edge.key_groups, UInt32(0), "exchange_edge.key_groups")

    for i in range(len(bad)):
        print("MOJO-HEX", bad[i])
    assert_equal(len(bad), 0, "goldens whose committed .hex is not the generated encoder's bytes (MOJO-HEX lines above)")


def main() raises:
    test_goldens()
    print("ALL 13 optimized_plan.proto GOLDENS READ AND WRITTEN BY THE GENERATED CODEC")
