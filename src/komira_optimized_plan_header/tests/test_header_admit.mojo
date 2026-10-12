# =============================================================================
# test_header_admit.mojo
# =============================================================================
#
# §7.2 step 3 and the header invariants of §4.2 (docs/design/optimized_plan.md)
# through `admit_optimized_plan_header` (decode, then check) and step 4
# through `check_optimized_plan_contract`. Each hostile header differs from a
# valid one in one field. What each test proves, and the defect it catches:
#
#   test_valid_header_admitted: a header with every field set is admitted and
#     comes back unchanged. Catches a check that refuses a valid header.
#   test_producer_missing: no `producer`, and a `producer` with an empty
#     `engine_build`, are OPTIMIZED_PLAN_PRODUCER_MISSING. Catches a check that
#     treats an absent stamp as an unrevoked one.
#   test_producer_revoked: a build in the revocation set is
#     OPTIMIZED_PLAN_PRODUCER_REVOKED wherever it stands in the set; a set of
#     other builds, one holding a prefix of this build, or a 32-byte build
#     that differs from it only in its first, a middle or its last byte,
#     admits it. Catches a check of the first entry only, a prefix
#     comparison, and a comparison that stops before the last byte.
#   test_digest_malformed: a `plan_digest` of 0, 31 or 33 bytes is
#     OPTIMIZED_PLAN_DIGEST_MALFORMED. Catches `>=` or `<=` for `==`.
#   test_needs_missing: no `needs` is OPTIMIZED_PLAN_NEEDS_MISSING.
#   test_write_target_empty_path: a `write_target` with an empty path is
#     OPTIMIZED_PLAN_WRITE_TARGET_EMPTY_PATH; no `write_target` is admitted.
#   test_check_order: a header with two defects is refused by the earlier
#     check, in the design's order (producer, revocation, digest, needs).
#   test_contract: contract version 1 passes step 4; 0 and 2 are
#     OPTIMIZED_PLAN_CONTRACT_UNSUPPORTED naming the accepted set; step 4 on a
#     header with no producer is OPTIMIZED_PLAN_PRODUCER_MISSING.
#   test_accepted_sets: the sets a scheduler routes by are {1} and {1}, and
#     a set prints as `{1, 2}`.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_optimized_plan_header import (
    OPTIMIZED_PLAN_CONTRACT_UNSUPPORTED,
    OPTIMIZED_PLAN_DIGEST_MALFORMED,
    OPTIMIZED_PLAN_NEEDS_MISSING,
    OPTIMIZED_PLAN_PRODUCER_MISSING,
    OPTIMIZED_PLAN_PRODUCER_REVOKED,
    OPTIMIZED_PLAN_WRITE_TARGET_EMPTY_PATH,
    admit_optimized_plan_header,
    check_optimized_plan_contract,
    check_optimized_plan_header,
    encode_optimized_plan_header,
    optimized_plan_contract_versions,
    optimized_plan_format_versions,
    version_set_text,
)
from komira_plan_proto.optimized_plan import (
    DeclaredNeeds,
    OptimizedPlan,
    PlanAdvice,
    ProducerStamp,
    RuntimeNeed,
    ScanStats,
)
from komira_plan_proto.plan import WireWriteTarget
from komira_plan_proto.plan_vocabulary import WriteCompression, WriteFormat


def _bytes(n: Int, v: UInt8) -> List[UInt8]:
    var b = List[UInt8]()
    for _ in range(n):
        b.append(v)
    return b^


def _valid() -> OptimizedPlan:
    var stamp = ProducerStamp(_bytes(32, 0xAB), 1, _bytes(32, 0x11), "komira/mojo-sdk")
    var needs = DeclaredNeeds([String("orders")], False, [RuntimeNeed("komira/python", "cp312")])
    var write = WireWriteTarget("out/", WriteFormat(1), WriteCompression(3))
    var advice = PlanAdvice([ScanStats(0, 10)])
    return OptimizedPlan(1, stamp^, _bytes(32, 0xCD), _bytes(32, 0xEF), needs^, write^, advice^, _bytes(3, 1))


def _no_revocations() -> List[List[UInt8]]:
    return List[List[UInt8]]()


def _admit(h: OptimizedPlan, revoked: List[List[UInt8]]) raises -> OptimizedPlan:
    return admit_optimized_plan_header(encode_optimized_plan_header(h), revoked)


def _refused(h: OptimizedPlan, revoked: List[List[UInt8]], token: String, needle: String, what: String) raises:
    var refused = False
    try:
        _ = _admit(h, revoked)
    except e:
        refused = True
        var text = String(e)
        assert_true(text.startswith(token + ":"), what + ": refused with another token: " + text)
        assert_true(needle in text, what + ": the refusal does not say `" + needle + "`: " + text)
    assert_true(refused, what + ": admitted, expected " + token)


def _contract_refused(h: OptimizedPlan, token: String, needle: String, what: String) raises:
    var refused = False
    try:
        check_optimized_plan_contract(h)
    except e:
        refused = True
        var text = String(e)
        assert_true(text.startswith(token + ":"), what + ": refused with another token: " + text)
        assert_true(needle in text, what + ": the refusal does not say `" + needle + "`: " + text)
    assert_true(refused, what + ": passed step 4, expected " + token)


def test_valid_header_admitted() raises:
    var h = _admit(_valid(), _no_revocations())
    assert_equal(h.format_version, UInt32(1), "format_version")
    assert_equal(len(h.plan_digest), 32, "plan_digest")
    assert_equal(h.needs.value().data_scopes[0], "orders", "needs.data_scopes[0]")
    assert_equal(h.write_target.value().path, "out/", "write_target.path")
    assert_equal(len(h.body), 3, "body")
    # The check also runs on a header the caller built or decoded itself.
    check_optimized_plan_header(_valid(), _no_revocations())


def test_producer_missing() raises:
    var h = _valid()
    h.producer = None
    _refused(h, _no_revocations(), OPTIMIZED_PLAN_PRODUCER_MISSING, "non-empty engine_build", "no producer")
    var empty = _valid()
    empty.producer.value().engine_build = List[UInt8]()
    _refused(empty, _no_revocations(), OPTIMIZED_PLAN_PRODUCER_MISSING, "non-empty engine_build", "an empty engine_build")


def test_producer_revoked() raises:
    var hex_ab = String("")
    for _ in range(32):
        hex_ab += "ab"
    var first: List[List[UInt8]] = [_bytes(32, 0xAB), _bytes(32, 0x01)]
    _refused(_valid(), first, OPTIMIZED_PLAN_PRODUCER_REVOKED, "engine_build " + hex_ab + " is revoked", "revoked, first")
    var last: List[List[UInt8]] = [_bytes(32, 0x01), _bytes(32, 0x02), _bytes(32, 0xAB)]
    _refused(_valid(), last, OPTIMIZED_PLAN_PRODUCER_REVOKED, "is revoked", "revoked, last")
    var others: List[List[UInt8]] = [_bytes(32, 0x01), _bytes(31, 0xAB), _bytes(33, 0xAB)]
    _ = _admit(_valid(), others)
    # A same-length build that differs from this one in one byte, at the
    # first, a middle and the last place, is another build: each admits it.
    var places: List[Int] = [0, 16, 31]
    for i in range(len(places)):
        var near = _bytes(32, 0xAB)
        near[places[i]] = 0xAC
        var one: List[List[UInt8]] = [near^]
        _ = _admit(_valid(), one)


def test_digest_malformed() raises:
    var sizes: List[Int] = [0, 31, 33]
    for i in range(len(sizes)):
        var n = sizes[i]
        var h = _valid()
        h.plan_digest = _bytes(n, 0xCD)
        _refused(
            h,
            _no_revocations(),
            OPTIMIZED_PLAN_DIGEST_MALFORMED,
            "plan_digest is " + String(n) + " bytes",
            "a digest of " + String(n) + " bytes",
        )


def test_needs_missing() raises:
    var h = _valid()
    h.needs = None
    _refused(h, _no_revocations(), OPTIMIZED_PLAN_NEEDS_MISSING, "declares its needs", "no needs")


def test_write_target_empty_path() raises:
    var h = _valid()
    h.write_target.value().path = ""
    _refused(h, _no_revocations(), OPTIMIZED_PLAN_WRITE_TARGET_EMPTY_PATH, "write_target.path is empty", "empty path")
    var plain = _valid()
    plain.write_target = None
    _ = _admit(plain, _no_revocations())


def test_check_order() raises:
    var a = _valid()
    a.producer = None
    a.needs = None
    _refused(a, _no_revocations(), OPTIMIZED_PLAN_PRODUCER_MISSING, "engine_build", "producer before needs")
    var b = _valid()
    b.plan_digest = _bytes(1, 0)
    var revoked: List[List[UInt8]] = [_bytes(32, 0xAB)]
    _refused(b, revoked, OPTIMIZED_PLAN_PRODUCER_REVOKED, "revoked", "revocation before the digest")
    var c = _valid()
    c.plan_digest = _bytes(1, 0)
    c.needs = None
    _refused(c, _no_revocations(), OPTIMIZED_PLAN_DIGEST_MALFORMED, "1 bytes", "the digest before needs")
    var d = _valid()
    d.needs = None
    d.write_target.value().path = ""
    _refused(d, _no_revocations(), OPTIMIZED_PLAN_NEEDS_MISSING, "needs", "needs before the write target")


def test_contract() raises:
    check_optimized_plan_contract(_valid())
    var versions: List[Int] = [0, 2]
    for i in range(len(versions)):
        var v = versions[i]
        var h = _valid()
        h.producer.value().optimizer_contract_version = UInt32(v)
        _contract_refused(
            h,
            OPTIMIZED_PLAN_CONTRACT_UNSUPPORTED,
            "optimizer_contract_version " + String(v) + " is not in this build's accepted set {1}",
            "contract " + String(v),
        )
    var h = _valid()
    h.producer = None
    _contract_refused(h, OPTIMIZED_PLAN_PRODUCER_MISSING, "engine_build", "step 4 with no producer")


def test_accepted_sets() raises:
    assert_equal(version_set_text(optimized_plan_format_versions()), "{1}", "format_version set")
    assert_equal(version_set_text(optimized_plan_contract_versions()), "{1}", "contract set")
    assert_equal(version_set_text([UInt32(1), 2]), "{1, 2}", "a two-member set")
    assert_equal(version_set_text(List[UInt32]()), "{}", "the empty set")


def main() raises:
    test_valid_header_admitted()
    test_producer_missing()
    test_producer_revoked()
    test_digest_malformed()
    test_needs_missing()
    test_write_target_empty_path()
    test_check_order()
    test_contract()
    test_accepted_sets()
    print("every step 3 and step 4 refusal of the header library, by name")
