# =============================================================================
# optimized_body.mojo: the framing of an `OptimizedPlanBody` and what version 1
# of the body carries (docs/design/optimized_plan.md §4.1, §7.2 steps 5 and 6).
# =============================================================================
#
# `frame_optimized_body` reads the top-level record stream of the body bytes
# and nothing deeper: it finds the bytes of field 1, `plan`, so that
# `plan_wire` decodes (and bounds) exactly those bytes before any generated
# decoder walks them. A hostile plan nested to any depth is therefore refused
# by `plan_wire`'s own limits, not by a stack overflow here.
#
#   field 1   `plan`: required, length-delimited, at most once:
#             OPTIMIZED_PLAN_BODY_MALFORMED.
#   fields 2-4  `shared`, `scan_pins`, `pin_groups`: version 1 of this reader
#             builds and admits none of them (a body with `cse_ref` nodes,
#             pins or pin groups is the later part of design stage 5), so any
#             record under these numbers is OPTIMIZED_FIELD_UNSUPPORTED. The
#             token is the one `plan_wire` raises for a statistics field, used
#             here for a body field this version does not carry.
#   other     a number this version does not declare is skipped here and
#             refused later: the canonical re-encoding has no unknown fields,
#             so the body differs from it (OPTIMIZED_PLAN_NOT_CANONICAL).
#
# Not a record stream at all (a field number of 0, a wire type proto3 does
# not write, a length past the end, a wrong wire type on a known field) is
# OPTIMIZED_PLAN_BODY_MALFORMED, as OPTIMIZED_PLAN_HEADER_MALFORMED is for the
# header.
#
# `OPTIMIZED_BODY_UNBOUNDED_V1`: `plan_wire` refuses a scan that is not
# BOUNDED (the format has no field for it), so a decoded version-1 body never
# holds an unbounded scan and its header says `needs.unbounded = false`.
# =============================================================================

from plan_wire import OPTIMIZED_FIELD_UNSUPPORTED
from protobuf import (
    PB_WIRE_FIXED32,
    PB_WIRE_FIXED64,
    PB_WIRE_LEN,
    PB_WIRE_VARINT,
    pb_read_varint,
)

comptime OPTIMIZED_PLAN_BODY_MALFORMED: String = "OPTIMIZED_PLAN_BODY_MALFORMED"
"""`OptimizedPlan.body` is not an `OptimizedPlanBody` any version can mean: it
does not frame as protobuf, `plan` (field 1) is absent, has the wrong wire
type or occurs twice."""

comptime OPTIMIZED_BODY_UNBOUNDED_V1: Bool = False
"""Whether a version-1 body holds an UNBOUNDED scan: never, `plan_wire` cannot
carry one."""


@fieldwise_init
struct BodyFrame(Copyable, Movable):
    """Where `plan` lies in the body: the bytes `[plan_start, plan_end)`."""

    var plan_start: Int
    var plan_end: Int


def _malformed(var what: String) -> Error:
    return Error(OPTIMIZED_PLAN_BODY_MALFORMED + ": " + what^)


def _varint(b: Span[UInt8, _], pos: Int, what: String) raises -> Tuple[UInt64, Int]:
    try:
        var r = pb_read_varint(b, pos)
        return (r.value, r.new_pos)
    except e:
        raise _malformed(what + " at byte " + String(pos) + ": " + String(e))


def frame_optimized_body(body: Span[UInt8, _]) raises -> BodyFrame:
    """The place of `plan` in `body`, after refusing a body that is not a
    record stream, lacks `plan`, or carries a field this version does not
    (module header)."""
    var plan_start = -1
    var plan_end = -1
    var unsupported = String("")
    var pos = 0
    while pos < len(body):
        var t = _varint(body, pos, "a field tag")
        var number = t[0] >> 3
        var wire_type = Int(t[0] & 7)
        var p = t[1]
        if number == 0 or number > 536870911:
            raise _malformed("field number " + String(number) + " at byte " + String(pos) + " is not a field number")
        var start = p
        var end = p
        if wire_type == PB_WIRE_VARINT:
            var v = _varint(body, p, "field " + String(number))
            end = v[1]
        elif wire_type == PB_WIRE_LEN:
            var n = _varint(body, p, "field " + String(number) + ": a length")
            start = n[1]
            if n[0] > UInt64(len(body) - start):
                raise _malformed(
                    "field " + String(number) + ": a length of " + String(n[0]) + " runs past the end of the body"
                )
            end = start + Int(n[0])
        else:
            var width = 0
            if wire_type == PB_WIRE_FIXED64:
                width = 8
            elif wire_type == PB_WIRE_FIXED32:
                width = 4
            else:
                raise _malformed("field " + String(number) + ": wire type " + String(wire_type) + " is not one proto3 writes")
            if len(body) - p < width:
                raise _malformed("field " + String(number) + ": a fixed-width value runs past the end of the body")
            end = p + width
        pos = end
        # `number` is at least 1 here: 0 was refused above.
        if number <= 4 and wire_type != PB_WIRE_LEN:
            raise _malformed("OptimizedPlanBody field " + String(number) + " arrives with wire type " + String(wire_type))
        if number == 1:
            if plan_start >= 0:
                raise _malformed("OptimizedPlanBody.plan occurs twice; a singular field occurs at most once")
            plan_start = start
            plan_end = end
        elif number <= 4 and unsupported.byte_length() == 0:
            unsupported = String("shared") if number == 2 else (String("scan_pins") if number == 3 else String("pin_groups"))
    if plan_start < 0:
        raise _malformed("OptimizedPlanBody.plan (field 1) is absent; a body is one plan")
    if unsupported.byte_length() > 0:
        raise Error(
            OPTIMIZED_FIELD_UNSUPPORTED
            + ": OptimizedPlanBody."
            + unsupported
            + " is not carried by format_version 1 of this reader: a body holds one uncut plan with no shared subplans, scan pins or pin groups"
        )
    return BodyFrame(plan_start, plan_end)
