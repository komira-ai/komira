# =============================================================================
# header_admit.mojo: §7.2 step 3 and the header invariants of §4.2 that the
# header library owns (docs/design/optimized_plan.md).
# =============================================================================
#
# `check_optimized_plan_header` runs on a decoded header, in this order:
#
#   producer   required, with a non-empty `engine_build` (invariant 2):
#              OPTIMIZED_PLAN_PRODUCER_MISSING. An empty `engine_build` is the
#              one value no revocation set can name, so a plan that carried one
#              could not be revoked.
#   revoked    `engine_build` is in the revocation set the caller passes
#              (§9.7): OPTIMIZED_PLAN_PRODUCER_REVOKED. Revocation names builds,
#              never versions.
#   digest     `plan_digest` is exactly 32 bytes (invariant 3):
#              OPTIMIZED_PLAN_DIGEST_MALFORMED. Recomputing it needs the body
#              and is the host's (§7.1).
#   needs      required (invariant 5): OPTIMIZED_PLAN_NEEDS_MISSING.
#   write      an empty `write_target.path` is refused, as in
#              `WirePlanEnvelope` (invariant 6):
#              OPTIMIZED_PLAN_WRITE_TARGET_EMPTY_PATH.
#
# `admit_optimized_plan_header` is decode (steps 1 and 2) then this check.
#
# `check_optimized_plan_contract` is §7.2 step 4, which the design gives the
# host and the coordinator, not the scheduler: a scheduler routes a plan whose
# contract version its own build does not know to hosts that do (§9.5). It
# lives here because the header library exposes each build's accepted sets
# (§9.5) and the host reads them from it.
#
# Not here, and why:
#   * OPTIMIZED_PLAN_NEEDS_OVER_LIMIT (step 3). The limits cap `ResourceNeeds`,
#     which optimized_plan.proto holds unnumbered (`held: ResourceNeeds
#     resources = 1`); with no field to compare, the check could not fail.
#   * `recurring_signature`'s length (invariant 4): advisory, checked by no
#     reader (§4.2).
#   * the `(format, codec)` pair of `write_target`: the host's sink table
#     (`write_target_supported`, komira_arrow) decides it, as for an envelope.
# =============================================================================

from komira_plan_proto.optimized_plan import OptimizedPlan

from .header_codec import decode_optimized_plan_header, version_set_text

comptime OPTIMIZED_PLAN_PRODUCER_MISSING: String = "OPTIMIZED_PLAN_PRODUCER_MISSING"
"""`producer` is absent, or its `engine_build` is empty (§4.2 invariant 2)."""

comptime OPTIMIZED_PLAN_PRODUCER_REVOKED: String = "OPTIMIZED_PLAN_PRODUCER_REVOKED"
"""`producer.engine_build` is in the caller's revocation set (§7.2 step 3,
§9.7)."""

comptime OPTIMIZED_PLAN_DIGEST_MALFORMED: String = "OPTIMIZED_PLAN_DIGEST_MALFORMED"
"""`plan_digest` is not exactly 32 bytes (§4.2 invariant 3)."""

comptime OPTIMIZED_PLAN_NEEDS_MISSING: String = "OPTIMIZED_PLAN_NEEDS_MISSING"
"""`needs` is absent (§4.2 invariant 5)."""

comptime OPTIMIZED_PLAN_WRITE_TARGET_EMPTY_PATH: String = "OPTIMIZED_PLAN_WRITE_TARGET_EMPTY_PATH"
"""`write_target` is present with an empty `path` (§4.2 invariant 6)."""

comptime OPTIMIZED_PLAN_CONTRACT_UNSUPPORTED: String = "OPTIMIZED_PLAN_CONTRACT_UNSUPPORTED"
"""`producer.optimizer_contract_version` is not in this build's accepted set
(§7.2 step 4, §9.3)."""

comptime OPTIMIZED_PLAN_CONTRACT_VERSION_1: UInt32 = 1
"""The first optimizer contract version. No version has been released yet."""

comptime OPTIMIZED_PLAN_DIGEST_BYTES: Int = 32
"""The length of `plan_digest`, a sha256 (§7.1)."""


def optimized_plan_contract_versions() -> List[UInt32]:
    """This build's accepted `optimizer_contract_version` set: every released
    version up to its own, none ever removed (§9.3)."""
    return [OPTIMIZED_PLAN_CONTRACT_VERSION_1]


def _hex(b: List[UInt8]) -> String:
    comptime digits = "0123456789abcdef"
    var out = String("")
    for i in range(len(b)):
        var v = Int(b[i])
        out += String(digits[byte = v >> 4]) + String(digits[byte = v & 15])
    return out


def _same_bytes(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def require_header_producer(header: OptimizedPlan) raises:
    """Refuse a header whose `producer` is absent or has an empty
    `engine_build`: OPTIMIZED_PLAN_PRODUCER_MISSING."""
    if not header.producer or len(header.producer.value().engine_build) == 0:
        raise Error(
            OPTIMIZED_PLAN_PRODUCER_MISSING
            + ": an optimized plan names its producer with a non-empty engine_build"
            " (docs/design/optimized_plan.md §4.2)"
        )


def require_header_needs(header: OptimizedPlan) raises:
    """Refuse a header whose `needs` is absent: OPTIMIZED_PLAN_NEEDS_MISSING."""
    if not header.needs:
        raise Error(
            OPTIMIZED_PLAN_NEEDS_MISSING
            + ": an optimized plan declares its needs, the only input to placement"
            " (docs/design/optimized_plan.md §6.1)"
        )


def check_optimized_plan_header(header: OptimizedPlan, revoked_builds: List[List[UInt8]]) raises:
    """§7.2 step 3 and the header invariants of §4.2 on a decoded header;
    `revoked_builds` is the caller's revocation set of `engine_build` digests."""
    require_header_producer(header)
    ref producer = header.producer.value()
    for i in range(len(revoked_builds)):
        if _same_bytes(producer.engine_build, revoked_builds[i]):
            raise Error(
                OPTIMIZED_PLAN_PRODUCER_REVOKED
                + ": engine_build "
                + _hex(producer.engine_build)
                + " is revoked; produce the plan again with another build (docs/design/optimized_plan.md §9.7)"
            )
    if len(header.plan_digest) != OPTIMIZED_PLAN_DIGEST_BYTES:
        raise Error(
            OPTIMIZED_PLAN_DIGEST_MALFORMED
            + ": plan_digest is "
            + String(len(header.plan_digest))
            + " bytes; it is a sha256, 32 bytes"
        )
    require_header_needs(header)
    if header.write_target and header.write_target.value().path.byte_length() == 0:
        raise Error(
            OPTIMIZED_PLAN_WRITE_TARGET_EMPTY_PATH
            + ": write_target.path is empty, which is certainly not a destination"
        )


def admit_optimized_plan_header(var bytes: List[UInt8], revoked_builds: List[List[UInt8]]) raises -> OptimizedPlan:
    """§7.2 steps 1-3 on the header only: decode with the body left as bytes,
    then `check_optimized_plan_header`."""
    var header = decode_optimized_plan_header(bytes^)
    check_optimized_plan_header(header, revoked_builds)
    return header^


def check_optimized_plan_contract(header: OptimizedPlan) raises:
    """§7.2 step 4: `optimizer_contract_version` must be in
    `optimized_plan_contract_versions()`. The refusal names the accepted set,
    so a scheduler can route the plan or ask for a rebuild (§9.5)."""
    require_header_producer(header)
    ref producer = header.producer.value()
    var accepted = optimized_plan_contract_versions()
    for i in range(len(accepted)):
        if accepted[i] == producer.optimizer_contract_version:
            return
    raise Error(
        OPTIMIZED_PLAN_CONTRACT_UNSUPPORTED
        + ": optimizer_contract_version "
        + String(Int(producer.optimizer_contract_version))
        + " is not in this build's accepted set "
        + version_set_text(accepted)
    )
