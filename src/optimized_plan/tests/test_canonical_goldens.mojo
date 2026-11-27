# =============================================================================
# test_canonical_goldens.mojo
# =============================================================================
#
# The canonical encoder against protoc, the reference serializer. Each fixture
# is protoc's encoding of a hand-written text message, owned by plan_proto
# (BUCK `test_data` names its `canonical_fixture_*` targets).
#
# What the test proves:
#   test_optimized_goldens_match_protoc: for each of the fourteen messages of
#     optimized_plan.proto (DigestTrailer among them), the generated decoder
#     reads protoc's bytes and `encode_canonical` writes them back byte for
#     byte; decoding those bytes and encoding again gives the same bytes
#     (idempotence). OptimizedPlanBody, OptimizedSegment and OptimizedPlan
#     embed WirePlans, so oneof node arms and nested expressions are held
#     against protoc here.
# =============================================================================

from std.pathlib import Path
from std.testing import assert_equal

from proto_codec import Serializable, decode_proto
from optimized_plan import encode_canonical
from plan_proto.optimized_plan import (
    DeclaredNeeds,
    DigestTrailer,
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


def _nibble(c: Int) raises -> Int:
    if c >= 48 and c <= 57:
        return c - 48
    if c >= 97 and c <= 102:
        return c - 87
    raise Error("not a lower-case hex digit: " + chr(c))


def _read(path: String) raises -> List[UInt8]:
    """The fixture hex format: two digits a byte, whitespace ignored."""
    var out = List[UInt8]()
    var high = -1
    for b in Path(path).read_text().as_bytes():
        var c = Int(b)
        if c == 32 or c == 10 or c == 13 or c == 9:
            continue
        if high < 0:
            high = _nibble(c)
        else:
            out.append(UInt8(high * 16 + _nibble(c)))
            high = -1
    return out^


def _hex(b: List[UInt8]) -> String:
    comptime digits = "0123456789abcdef"
    var out = String("")
    for i in range(len(b)):
        var v = Int(b[i])
        out += String(digits[byte = v >> 4]) + String(digits[byte = v & 15])
    return out


def _check[T: Serializable & Deinitable](path: String) raises:
    var protoc = _read(path)
    var msg = decode_proto[T](protoc.copy())
    var canonical = encode_canonical(msg)
    assert_equal(_hex(canonical), _hex(protoc), path + ": canonical vs protoc")
    var again = encode_canonical(decode_proto[T](canonical.copy()))
    assert_equal(_hex(again), _hex(protoc), path + ": idempotence")


def test_optimized_goldens_match_protoc() raises:
    comptime d = "fixtures/"
    _check[DeclaredNeeds](d + "declared_needs.canonical.hex")
    _check[DigestTrailer](d + "digest_trailer.canonical.hex")
    _check[ExchangeEdge](d + "exchange_edge.canonical.hex")
    _check[OptimizedPlan](d + "optimized_plan.canonical.hex")
    _check[OptimizedPlanBody](d + "optimized_plan_body.canonical.hex")
    _check[OptimizedSegment](d + "optimized_segment.canonical.hex")
    _check[OptimizedSegmentDag](d + "optimized_segment_dag.canonical.hex")
    _check[PinGroup](d + "pin_group.canonical.hex")
    _check[PlanAdvice](d + "plan_advice.canonical.hex")
    _check[ProducerStamp](d + "producer_stamp.canonical.hex")
    _check[RuntimeNeed](d + "runtime_need.canonical.hex")
    _check[ScanPin](d + "scan_pin.canonical.hex")
    _check[ScanStats](d + "scan_stats.canonical.hex")
    _check[SharedSubplan](d + "shared_subplan.canonical.hex")


def main() raises:
    test_optimized_goldens_match_protoc()
    print("the canonical encoder matches protoc on the optimized-plan goldens")
