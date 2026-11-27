# =============================================================================
# optimized_admit.mojo: the executor's door (docs/design/optimized_plan.md
# §7.2).
# =============================================================================
#
# `admit_optimized_plan` runs, in this order, and stops at the first refusal:
#
#   1-3  the header library: size, format version, structure, producer,
#        revocation, digest length, needs, write target
#        (`admit_optimized_plan_header`);
#   4    `check_optimized_plan_contract`;
#   --   version 1 carries no UDF: `needs.udfs` is not a field of the version
#        and the header library refuses it (OPTIMIZED_PLAN_VERSION_UNSUPPORTED);
#        a header that names a runtime is OPTIMIZED_FIELD_UNSUPPORTED (the UDF
#        arms of the body codec are a later part of design stage 5);
#   --   body framing (`frame_optimized_body`): OPTIMIZED_PLAN_BODY_MALFORMED,
#        and OPTIMIZED_FIELD_UNSUPPORTED for `shared`, `scan_pins` and
#        `pin_groups`;
#   5-6  `plan_wire` decodes exactly the bytes of `plan` in the OPTIMIZED
#        context, so its limits (16 MiB, depth 64, 65,536 nodes) apply to the
#        real bytes and its tokens pass through unchanged (PLAN_WIRE_TOO_LARGE,
#        PLAN_WIRE_TOO_DEEP, PLAN_WIRE_TOO_MANY_NODES, the value checks,
#        OPTIMIZED_JOIN_BUILD_SIDE_MISSING, OPTIMIZED_FIELD_UNSUPPORTED for a
#        scan statistic);
#   7    OPTIMIZED_PLAN_NOT_CANONICAL when the decoded body, encoded
#        canonically, is not the body's bytes (unknown fields, explicit
#        defaults and reordered fields all land here), then
#        OPTIMIZED_PLAN_DIGEST_MISMATCH when `plan_digest` is not the digest
#        of the bytes as produced;
#   8    OPTIMIZED_NEEDS_UNBOUNDED_MISMATCH when `needs.unbounded` is not what
#        the body says (the other structure checks of step 8 belong to parts
#        this version does not carry: aggregate modes, exchanges, pins, UDFs;
#        the build side and scan statistics are checked in steps 5-6).
#
# A raw logical plan (a `WirePlanEnvelope`, or an `OptimizedPlan` whose body is
# one, or a body whose joins record no build side) is refused at step 2, at the
# body framing or at step 6, by the tokens above. Nothing here reads SQL or
# optimizes: the plan is decoded and handed on.
# =============================================================================

from optimized_plan_header import (
    admit_optimized_plan_header,
    check_optimized_plan_contract,
)
from plan_ir.logical_plan import LogicalPlan
from plan_ir.udf_ref import UdfRef
from plan_proto.optimized_plan import OptimizedPlan, OptimizedPlanBody
from plan_wire import OPTIMIZED_FIELD_UNSUPPORTED, optimized_plan_from_bytes
from proto_codec import decode_proto

from .canonical_encoder import encode_canonical
from .optimized_body import OPTIMIZED_BODY_UNBOUNDED_V1, frame_optimized_body
from .optimized_digest import header_plan_digest

comptime OPTIMIZED_PLAN_NOT_CANONICAL: String = "OPTIMIZED_PLAN_NOT_CANONICAL"
"""The body is not the canonical encoding of the message it decodes to
(§7.1, §7.2 step 7)."""

comptime OPTIMIZED_PLAN_DIGEST_MISMATCH: String = "OPTIMIZED_PLAN_DIGEST_MISMATCH"
"""`plan_digest` is not sha256(body ‖ canonical(DigestTrailer)) of the plan as
received (§7.2 step 7)."""

comptime OPTIMIZED_NEEDS_UNBOUNDED_MISMATCH: String = "OPTIMIZED_NEEDS_UNBOUNDED_MISMATCH"
"""`needs.unbounded` disagrees with the scans of the body (§6.1, §7.2 step 8)."""


struct AdmittedOptimizedPlan(Movable):
    """A plan that passed admission: its header (the body bytes included, as
    received) and the decoded plan."""

    var header: OptimizedPlan
    var plan: LogicalPlan

    def __init__(out self, var header: OptimizedPlan, var plan: LogicalPlan):
        self.header = header^
        self.plan = plan^


def _hex(b: Span[UInt8, _]) -> String:
    comptime digits = "0123456789abcdef"
    var out = String("")
    for i in range(len(b)):
        var v = Int(b[i])
        out += String(digits[byte = v >> 4]) + String(digits[byte = v & 15])
    return out


def _check_canonical(body: List[UInt8]) raises:
    # The framing and `plan_wire` have refused every input this decoder
    # does, so it does not raise on a body that got here.
    var decoded = decode_proto[OptimizedPlanBody](body.copy())
    var canonical = encode_canonical(decoded)
    var first = 0
    var common = min(len(canonical), len(body))
    while first < common and canonical[first] == body[first]:
        first += 1
    if first == len(canonical) and first == len(body):
        return
    raise Error(
        OPTIMIZED_PLAN_NOT_CANONICAL
        + ": the body is "
        + String(len(body))
        + " bytes and its canonical encoding is "
        + String(len(canonical))
        + "; they first differ at byte "
        + String(first)
        + ". A producer writes the canonical form (docs/design/optimized_plan.md §7.1)"
    )


def admit_optimized_plan(
    var bytes: List[UInt8], revoked_builds: List[List[UInt8]]
) raises -> AdmittedOptimizedPlan:
    """Admit `bytes` as an optimized plan (module header). `revoked_builds` is
    the caller's revocation set of `engine_build` digests."""
    var header = admit_optimized_plan_header(bytes^, revoked_builds)
    check_optimized_plan_contract(header)
    ref needs = header.needs.value()
    if len(needs.runtimes) > 0:
        raise Error(
            OPTIMIZED_FIELD_UNSUPPORTED
            + ": needs names "
            + String(len(needs.runtimes))
            + " runtimes; format_version 1 of this reader carries no UDF, so no runtime"
        )
    var frame = frame_optimized_body(Span(header.body))
    var plan_bytes = List[UInt8](capacity=frame.plan_end - frame.plan_start)
    plan_bytes.extend(Span(header.body)[frame.plan_start : frame.plan_end])
    var plan = optimized_plan_from_bytes(plan_bytes^, List[UdfRef]())
    _check_canonical(header.body)
    var digest = header_plan_digest(header)
    if digest != header.plan_digest:
        raise Error(
            OPTIMIZED_PLAN_DIGEST_MISMATCH
            + ": plan_digest "
            + _hex(Span(header.plan_digest))
            + " is not the digest of the plan as received, "
            + _hex(Span(digest))
        )
    if needs.unbounded != OPTIMIZED_BODY_UNBOUNDED_V1:
        raise Error(
            OPTIMIZED_NEEDS_UNBOUNDED_MISMATCH
            + ": needs.unbounded is "
            + String(needs.unbounded)
            + ", and format_version 1 bodies hold only bounded scans, so the header must say false"
        )
    return AdmittedOptimizedPlan(header^, plan^)
