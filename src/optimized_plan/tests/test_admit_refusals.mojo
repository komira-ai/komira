# =============================================================================
# test_admit_refusals.mojo
# =============================================================================
#
# `admit_optimized_plan`, the executor's door (docs/design/optimized_plan.md
# §7.2), refuses what is not an optimized plan, and refuses each defect by its
# token, in the design's order. Hostile inputs are built by hand: a header
# sealed with `optimized_plan_digest` over the body the test chose, so the
# digest is right unless the test says it is not. Refusal tests assert the
# token and a needle of the detail; a message with no variable part is
# asserted whole. What each test proves:
#
#   A raw logical plan is refused
#   test_raw_envelope_is_refused_by_its_format_version: the bytes of
#     `plan_to_bytes` (a `WirePlanEnvelope`, format_version 4) are refused
#     OPTIMIZED_PLAN_VERSION_UNSUPPORTED naming the accepted set {1}.
#   test_a_body_that_is_a_raw_envelope_is_refused: an OptimizedPlan whose body
#     is a raw envelope is OPTIMIZED_PLAN_BODY_MALFORMED (its field 1 is a
#     varint, not the plan).
#   test_a_join_with_no_build_side_is_refused: a raw plan's wire plan placed in
#     a body, with a correct digest, is OPTIMIZED_JOIN_BUILD_SIDE_MISSING.
#   test_a_scan_with_row_count_is_refused: the same with a scan that carries
#     `row_count`, which RAW admits, is OPTIMIZED_FIELD_UNSUPPORTED.
#
#   The header
#   test_revoked_producer_passes_through: a revoked `engine_build` is
#     OPTIMIZED_PLAN_PRODUCER_REVOKED; a set of other builds admits it.
#   test_unsupported_contract_passes_through: contract version 2 is
#     OPTIMIZED_PLAN_CONTRACT_UNSUPPORTED naming {1}, before the digest is read.
#   test_declared_runtimes_are_refused: `needs.runtimes` is
#     OPTIMIZED_FIELD_UNSUPPORTED.
#
#   The body
#   test_empty_body_is_refused: no body bytes is OPTIMIZED_PLAN_BODY_MALFORMED
#     (no field 1), whole text asserted.
#   test_body_framing_refusals: a field number of 0 or above 2^29-1, a wire
#     type proto3 does not write, a truncated tag, varint, length, fixed32 and
#     fixed64, field 1 twice, and a wrong wire type on field 1 and on field 2
#     are each OPTIMIZED_PLAN_BODY_MALFORMED.
#   test_shared_pins_and_groups_are_refused_by_name: a record under field 2, 3
#     or 4 is OPTIMIZED_FIELD_UNSUPPORTED naming shared, scan_pins or
#     pin_groups; with two of them present, the first in the body is named.
#   test_plan_limits_apply_to_the_plan_bytes: a plan nested past depth 64 is
#     PLAN_WIRE_TOO_DEEP: plan_wire's limits see exactly the bytes of `plan`.
#
#   Canonical form, digest, needs
#   test_non_canonical_body_is_refused: a body written by the generated
#     encoder (defaults written, oneof arms last) and a body with an unknown
#     varint, fixed32, fixed64 or length-delimited field appended are
#     OPTIMIZED_PLAN_NOT_CANONICAL even with a digest recomputed over them; the
#     appended-varint case asserts the whole text.
#   test_a_changed_body_byte_is_refused: a changed plan path under the original
#     digest is OPTIMIZED_PLAN_DIGEST_MISMATCH; every single-bit change of
#     every body byte is refused, and some of them by the digest.
#   test_digest_covers_the_header_fields: a write target, or a data scope,
#     changed after the digest was taken is OPTIMIZED_PLAN_DIGEST_MISMATCH,
#     whole text asserted for the write target.
#   test_needs_unbounded_must_match_the_body: `needs.unbounded = true` on a
#     bounded body with a correct digest is OPTIMIZED_NEEDS_UNBOUNDED_MISMATCH
#     (whole text); the digest does not cover it.
# =============================================================================

from std.testing import assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from optimized_plan import (
    OPTIMIZED_NEEDS_UNBOUNDED_MISMATCH,
    OPTIMIZED_PLAN_BODY_MALFORMED,
    OPTIMIZED_PLAN_DIGEST_MISMATCH,
    OPTIMIZED_PLAN_NOT_CANONICAL,
    admit_optimized_plan,
    encode_canonical,
    optimized_plan_digest,
    produce_optimized_plan,
)
from optimized_plan_header import (
    OPTIMIZED_PLAN_CONTRACT_UNSUPPORTED,
    OPTIMIZED_PLAN_PRODUCER_REVOKED,
    OPTIMIZED_PLAN_VERSION_UNSUPPORTED,
)
from plan_ir.logical_plan import (
    JOIN_ALGO_AUTO,
    JOIN_BUILD_SIDE_UNSET,
    JOIN_INNER,
    SOURCE_PARQUET,
    LogicalPlan,
)
from plan_ir.udf_ref import UdfRef
from plan_proto.optimized_plan import (
    DeclaredNeeds,
    OptimizedPlan,
    OptimizedPlanBody,
    ProducerStamp,
    RuntimeNeed,
)
from plan_proto.plan import WirePlan, WirePlanEnvelope, WireWriteTarget
from plan_proto.plan_vocabulary import WriteCompression, WriteFormat
from proto_codec import decode_proto, encode_proto
from plan_wire import (
    OPTIMIZED_FIELD_UNSUPPORTED,
    OPTIMIZED_JOIN_BUILD_SIDE_MISSING,
    PLAN_WIRE_TOO_DEEP,
    optimized_plan_to_wire,
    plan_to_bytes,
)


def _bytes(n: Int, v: UInt8) -> List[UInt8]:
    var b = List[UInt8]()
    for _ in range(n):
        b.append(v)
    return b^


def _stamp(contract: UInt32 = 1) -> ProducerStamp:
    return ProducerStamp(_bytes(32, 0xAB), contract, _bytes(32, 0x11), "komira/mojo-sdk")


def _no_revocations() -> List[List[UInt8]]:
    return List[List[UInt8]]()


def _schema(a: String, b: String) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(a, ArrowType.INT64, True))
    sb.add_field(Field(b, ArrowType.FLOAT64, True))
    return sb.build()


def _scan(path: String, a: String, b: String) -> LogicalPlan:
    return LogicalPlan.scan(path, SOURCE_PARQUET, _schema(a, b))


def _raw_join() -> LogicalPlan:
    """The unoptimized form of a join: no build side recorded."""
    var lon: List[String] = ["a"]
    var ron: List[String] = ["c"]
    return LogicalPlan.join(
        _scan("/d/l.parquet", "a", "b"), _scan("/d/r.parquet", "c", "d"),
        lon^, ron^, JOIN_INNER, JOIN_ALGO_AUTO, None, JOIN_BUILD_SIDE_UNSET, False,
    )


def _good_body() raises -> List[UInt8]:
    """The canonical body of a plan of one scan."""
    var wire = optimized_plan_to_wire(_scan("/d/l.parquet", "a", "b"), List[UdfRef]())
    return encode_canonical(OptimizedPlanBody(Optional(wire^), [], [], []))


def _needs() -> DeclaredNeeds:
    return DeclaredNeeds([], [], False, [])


def _sealed(
    body: List[UInt8], var needs: DeclaredNeeds, write: Optional[WireWriteTarget] = None, contract: UInt32 = 1
) raises -> OptimizedPlan:
    """A header over `body` whose digest is right for what it holds."""
    var header = OptimizedPlan(
        1, Optional(_stamp(contract)), List[UInt8](), List[UInt8](), Optional(needs^),
        write.copy(), None, body.copy(),
    )
    header.plan_digest = optimized_plan_digest(Span(body), header)
    return header^


def _sealed_body(body: List[UInt8]) raises -> List[UInt8]:
    return encode_canonical(_sealed(body, _needs()))


def _refusal_with(var bytes: List[UInt8], revoked: List[List[UInt8]]) -> String:
    try:
        _ = admit_optimized_plan(bytes^, revoked)
    except e:
        return String(e)
    return String("")


def _refusal(var bytes: List[UInt8]) -> String:
    return _refusal_with(bytes^, _no_revocations())


def _refusal_of_body(body: List[UInt8]) raises -> String:
    return _refusal(_sealed_body(body))


def _hex(b: List[UInt8]) -> String:
    comptime digits = "0123456789abcdef"
    var out = String("")
    for i in range(len(b)):
        var v = Int(b[i])
        out += String(digits[byte = v >> 4]) + String(digits[byte = v & 15])
    return out


def _concat(a: List[UInt8], b: List[UInt8]) -> List[UInt8]:
    var out = a.copy()
    out.extend(Span(b))
    return out^


def _wire_plan_of(raw: LogicalPlan) raises -> WirePlan:
    """The `WirePlan` of a raw plan: what an envelope holds."""
    var env = decode_proto[WirePlanEnvelope](plan_to_bytes(raw))
    return env.plan.value().copy()


def _body_of_wire(var wire: WirePlan) raises -> List[UInt8]:
    return encode_canonical(OptimizedPlanBody(Optional(wire^), [], [], []))


def test_raw_envelope_is_refused_by_its_format_version() raises:
    var raw = plan_to_bytes(_scan("/d/l.parquet", "a", "b"))
    assert_equal(
        _refusal(raw^),
        OPTIMIZED_PLAN_VERSION_UNSUPPORTED + ": format_version 4 is not in this reader's accepted set {1}",
    )


def test_a_body_that_is_a_raw_envelope_is_refused() raises:
    var m = _refusal_of_body(plan_to_bytes(_scan("/d/l.parquet", "a", "b")))
    assert_equal(m, OPTIMIZED_PLAN_BODY_MALFORMED + ": OptimizedPlanBody field 1 arrives with wire type 0")


def test_a_join_with_no_build_side_is_refused() raises:
    var m = _refusal_of_body(_body_of_wire(_wire_plan_of(_raw_join())))
    assert_true(m.startswith(OPTIMIZED_JOIN_BUILD_SIDE_MISSING))
    assert_true("states no build_side" in m)


def test_a_scan_with_row_count_is_refused() raises:
    var counted = LogicalPlan.scan("/d/t.parquet", SOURCE_PARQUET, _schema("a", "b"), None, None, Optional(12))
    var m = _refusal_of_body(_body_of_wire(_wire_plan_of(counted)))
    assert_true(m.startswith(OPTIMIZED_FIELD_UNSUPPORTED))
    assert_true("carries row_count" in m)


def test_revoked_producer_passes_through() raises:
    var bytes = produce_optimized_plan(_scan("/d/l.parquet", "a", "b"), _stamp())
    var other = List[List[UInt8]]()
    other.append(_bytes(32, 0x01))
    _ = admit_optimized_plan(bytes.copy(), other)
    var revoked = List[List[UInt8]]()
    revoked.append(_bytes(32, 0x01))
    revoked.append(_bytes(32, 0xAB))
    var m = _refusal_with(bytes^, revoked)
    assert_true(m.startswith(OPTIMIZED_PLAN_PRODUCER_REVOKED))
    assert_true(_hex(_bytes(32, 0xAB)) in m)


def test_unsupported_contract_passes_through() raises:
    var bytes = encode_canonical(_sealed(_good_body(), _needs(), None, 2))
    assert_equal(
        _refusal(bytes^),
        OPTIMIZED_PLAN_CONTRACT_UNSUPPORTED
        + ": optimizer_contract_version 2 is not in this build's accepted set {1}",
    )


def test_declared_runtimes_are_refused() raises:
    var needs = DeclaredNeeds([], [], False, [RuntimeNeed("komira/python", "cp312")])
    var m = _refusal(encode_canonical(_sealed(_good_body(), needs^)))
    assert_equal(
        m,
        OPTIMIZED_FIELD_UNSUPPORTED
        + ": needs names 1 runtimes; format_version 1 of this reader carries no UDF, so no runtime",
    )


def test_empty_body_is_refused() raises:
    assert_equal(
        _refusal_of_body(List[UInt8]()),
        OPTIMIZED_PLAN_BODY_MALFORMED + ": OptimizedPlanBody.plan (field 1) is absent; a body is one plan",
    )


def _expect_malformed(body: List[UInt8], needle: String) raises:
    var m = _refusal_of_body(body)
    assert_true(m.startswith(OPTIMIZED_PLAN_BODY_MALFORMED), m)
    assert_true(needle in m, m)


def test_body_framing_refusals() raises:
    var good = _good_body()
    _expect_malformed([0x00, 0x00], "field number 0 at byte 0")
    _expect_malformed([0x80, 0x80, 0x80, 0x80, 0x10], "is not a field number")
    _expect_malformed([0x7B], "wire type 3 is not one proto3 writes")
    _expect_malformed([0x80], "a field tag at byte 0")
    _expect_malformed([0x78], "field 15 at byte 1")
    _expect_malformed([0x0A], "field 1: a length at byte 1")
    _expect_malformed([0x0A, 0x05, 0x01], "a length of 5 runs past the end of the body")
    _expect_malformed([0x79, 0x01, 0x02, 0x03], "field 15: a fixed-width value runs past the end of the body")
    _expect_malformed([0x7D, 0x01], "field 15: a fixed-width value runs past the end of the body")
    _expect_malformed(_concat(good, good), "OptimizedPlanBody.plan occurs twice")
    _expect_malformed([0x08, 0x01], "OptimizedPlanBody field 1 arrives with wire type 0")
    _expect_malformed(_concat(good, [0x10, 0x01]), "OptimizedPlanBody field 2 arrives with wire type 0")


def test_shared_pins_and_groups_are_refused_by_name() raises:
    var good = _good_body()
    var names: List[String] = ["shared", "scan_pins", "pin_groups"]
    for i in range(3):
        var tag = UInt8((i + 2) * 8 + 2)
        var m = _refusal_of_body(_concat(good, [tag, 0x00]))
        assert_true(m.startswith(OPTIMIZED_FIELD_UNSUPPORTED), m)
        assert_true("OptimizedPlanBody." + names[i] + " is not carried" in m, m)
    # Two of them: the first in the body's order is the one named.
    var both = _refusal_of_body(_concat(good, [0x1A, 0x00, 0x12, 0x00]))
    assert_true("OptimizedPlanBody.scan_pins is not carried" in both, both)


def _nest(depth: Int) -> List[UInt8]:
    """`depth` length-delimited records of field 1, one inside the next."""
    var inner = List[UInt8]()
    for _ in range(depth):
        var out: List[UInt8] = [0x0A]
        var n = len(inner)
        while n >= 128:
            out.append(UInt8((n & 127) | 128))
            n >>= 7
        out.append(UInt8(n))
        out.extend(Span(inner))
        inner = out^
    return inner^


def test_plan_limits_apply_to_the_plan_bytes() raises:
    var m = _refusal_of_body(_nest(70))
    assert_true(m.startswith(PLAN_WIRE_TOO_DEEP), m)


def test_non_canonical_body_is_refused() raises:
    var good = _good_body()
    var loose = encode_proto(decode_proto[OptimizedPlanBody](good.copy()))
    assert_true(loose != good)
    var m = _refusal_of_body(loose)
    assert_true(m.startswith(OPTIMIZED_PLAN_NOT_CANONICAL), m)
    var n = String(len(good))
    assert_equal(
        _refusal_of_body(_concat(good, [0x78, 0x01])),
        OPTIMIZED_PLAN_NOT_CANONICAL
        + ": the body is " + String(len(good) + 2) + " bytes and its canonical encoding is " + n
        + "; they first differ at byte " + n
        + ". A producer writes the canonical form (docs/design/optimized_plan.md §7.1)",
    )
    var fixed32: List[UInt8] = [0x7D, 1, 2, 3, 4]
    var fixed64: List[UInt8] = [0x79, 1, 2, 3, 4, 5, 6, 7, 8]
    var delimited: List[UInt8] = [0x7A, 0x01, 0x00]
    assert_true(_refusal_of_body(_concat(good, fixed32)).startswith(OPTIMIZED_PLAN_NOT_CANONICAL))
    assert_true(_refusal_of_body(_concat(good, fixed64)).startswith(OPTIMIZED_PLAN_NOT_CANONICAL))
    assert_true(_refusal_of_body(_concat(good, delimited)).startswith(OPTIMIZED_PLAN_NOT_CANONICAL))


def _index_of(hay: List[UInt8], needle: String) -> Int:
    var nb = needle.as_bytes()
    for i in range(len(hay) - len(nb) + 1):
        var same = True
        for k in range(len(nb)):
            if hay[i + k] != nb[k]:
                same = False
                break
        if same:
            return i
    return -1


def test_a_changed_body_byte_is_refused() raises:
    var good = _good_body()
    var sealed = _sealed(good, _needs())
    var at = _index_of(good, "l.parquet")
    assert_true(at >= 0)
    var edited = good.copy()
    edited[at] = UInt8(ord("m"))
    var header = sealed.copy()
    header.body = edited^
    var m = _refusal(encode_canonical(header))
    assert_true(m.startswith(OPTIMIZED_PLAN_DIGEST_MISMATCH), m)
    var by_digest = 0
    for i in range(len(good)):
        var flipped = good.copy()
        flipped[i] = flipped[i] ^ 1
        var h = sealed.copy()
        h.body = flipped^
        var refusal = _refusal(encode_canonical(h))
        assert_true(refusal.byte_length() > 0, "byte " + String(i) + " changed and the plan was admitted")
        if refusal.startswith(OPTIMIZED_PLAN_DIGEST_MISMATCH):
            by_digest += 1
    assert_true(by_digest > 0)


def test_digest_covers_the_header_fields() raises:
    var body = _good_body()
    var write = WireWriteTarget("out/", WriteFormat(1), WriteCompression(3))
    var sealed = _sealed(body, _needs(), Optional(write^))
    var tampered = sealed.copy()
    tampered.write_target = Optional(WireWriteTarget("other/", WriteFormat(1), WriteCompression(3)))
    var want = optimized_plan_digest(Span(body), tampered)
    assert_equal(
        _refusal(encode_canonical(tampered)),
        OPTIMIZED_PLAN_DIGEST_MISMATCH + ": plan_digest " + _hex(sealed.plan_digest)
        + " is not the digest of the plan as received, " + _hex(want),
    )
    var scoped = _sealed(body, _needs())
    scoped.needs = Optional(DeclaredNeeds([], [String("orders")], False, []))
    assert_true(_refusal(encode_canonical(scoped)).startswith(OPTIMIZED_PLAN_DIGEST_MISMATCH))
    var untouched = _sealed(body, _needs(), Optional(WireWriteTarget("out/", WriteFormat(1), WriteCompression(3))))
    var admitted = admit_optimized_plan(encode_canonical(untouched), _no_revocations())
    assert_equal(admitted.header.write_target.value().path, "out/")


def test_needs_unbounded_must_match_the_body() raises:
    var needs = DeclaredNeeds([], [], True, [])
    var m = _refusal(encode_canonical(_sealed(_good_body(), needs^)))
    assert_equal(
        m,
        OPTIMIZED_NEEDS_UNBOUNDED_MISMATCH
        + ": needs.unbounded is True, and format_version 1 bodies hold only bounded scans, so the header must say false",
    )


def main() raises:
    test_raw_envelope_is_refused_by_its_format_version()
    test_a_body_that_is_a_raw_envelope_is_refused()
    test_a_join_with_no_build_side_is_refused()
    test_a_scan_with_row_count_is_refused()
    test_revoked_producer_passes_through()
    test_unsupported_contract_passes_through()
    test_declared_runtimes_are_refused()
    test_empty_body_is_refused()
    test_body_framing_refusals()
    test_shared_pins_and_groups_are_refused_by_name()
    test_plan_limits_apply_to_the_plan_bytes()
    test_non_canonical_body_is_refused()
    test_a_changed_body_byte_is_refused()
    test_digest_covers_the_header_fields()
    test_needs_unbounded_must_match_the_body()
    print("test_admit_refusals: 15 passed")
