# =============================================================================
# header_codec.mojo: the OptimizedPlan header, decoded and encoded without
# the body (docs/design/optimized_plan.md §4.1, §7.2 steps 1 and 2).
# =============================================================================
#
# `OptimizedPlan.body` is `bytes`, so the header (fields 1-7) decodes without
# the plan codec: this package's closure excludes `komira_plan_wire`, which the
# BUCK file's `closure_excludes` holds the build to. The body comes back as the
# bytes it arrived as and nothing here parses it.
#
# Decoding runs two admission steps, in the design's order:
#
#   1. SIZE. More than `OPTIMIZED_PLAN_MAX_BYTES` (the 16 MiB plan budget plus
#      `OPTIMIZED_PLAN_HEADER_ALLOWANCE_BYTES`) is refused before any byte is
#      read: `OPTIMIZED_PLAN_LIMIT_EXCEEDED`.
#   2. FORMAT. `format_version` must be a member of
#      `OPTIMIZED_PLAN_FORMAT_VERSIONS` (set membership, never `>=`, §9.2),
#      and the header must not carry a field or an enum value its version does
#      not include (an understated version): `OPTIMIZED_PLAN_VERSION_UNSUPPORTED`.
#
# The structure walk that finds an understated version also refuses what no
# version can mean, as `OPTIMIZED_PLAN_HEADER_MALFORMED`: bytes that do not
# frame as protobuf, a known field under the wrong wire type, a singular field
# that occurs twice, a `uint32` varint above 2^32-1 and a `bool` other than 0
# or 1. proto3 parsers resolve the last three silently and differently (last
# one wins, or a merge of two submessages; a truncation to 32 bits; any
# non-zero is true), so a scheduler and a host could read one header as two;
# refusing them leaves one reading.
#
# Version 1 is the field set optimized_plan.proto declares today: every
# header field it numbers, `WriteFormat` values 0-3 and `WriteCompression`
# values 0-5. A header field the schema holds (`DeclaredNeeds.udfs`, `hints`,
# `resources`, `scopes`; `PlanAdvice.estimates`, `udf_origins`,
# `index_coverage`; `ScanStats.source`, `columns`) or reserves is a field
# version 1 does not include, so a version-1 header that carries one is
# understated. No version has been released yet; the first release fixes
# version 1 for good (§9.2).
# =============================================================================

from komira_proto_codec import decode_proto, encode_proto
from komira_protobuf import (
    PB_WIRE_FIXED32,
    PB_WIRE_FIXED64,
    PB_WIRE_LEN,
    PB_WIRE_VARINT,
    pb_read_varint,
)
from komira_plan_proto.optimized_plan import OptimizedPlan

comptime OPTIMIZED_PLAN_LIMIT_EXCEEDED: String = "OPTIMIZED_PLAN_LIMIT_EXCEEDED"
"""The encoded header and body are larger than `OPTIMIZED_PLAN_MAX_BYTES`
(§7.2 step 1). Checked on the length alone, before parsing."""

comptime OPTIMIZED_PLAN_VERSION_UNSUPPORTED: String = "OPTIMIZED_PLAN_VERSION_UNSUPPORTED"
"""`format_version` is not in this reader's accepted set, or the header
carries a field or an enum value its version does not include (§7.2 step 2,
§9.2)."""

comptime OPTIMIZED_PLAN_HEADER_MALFORMED: String = "OPTIMIZED_PLAN_HEADER_MALFORMED"
"""The bytes are not an `OptimizedPlan` header any version can mean: they do
not frame as protobuf, a known field has the wrong wire type, a singular field
occurs twice, or a scalar is out of its type's range."""

comptime OPTIMIZED_PLAN_MAX_BODY_BYTES: Int = 16777216
"""The plan budget, 16 MiB: the same bound `komira_plan_wire` puts on a
`WirePlanEnvelope` (`PLAN_WIRE_MAX_BYTES`), restated here because this
package does not link that codec."""

comptime OPTIMIZED_PLAN_HEADER_ALLOWANCE_BYTES: Int = 1048576
"""The fixed allowance for header fields 1-7 above the plan budget, 1 MiB."""

comptime OPTIMIZED_PLAN_MAX_BYTES: Int = OPTIMIZED_PLAN_MAX_BODY_BYTES + OPTIMIZED_PLAN_HEADER_ALLOWANCE_BYTES
"""The most bytes `decode_optimized_plan_header` reads (§7.2 step 1)."""

comptime OPTIMIZED_PLAN_FORMAT_VERSION_1: UInt32 = 1
"""The field set optimized_plan.proto declares today (see the file header)."""


def optimized_plan_format_versions() -> List[UInt32]:
    """This reader's accepted `format_version` set: every released version,
    none ever removed (§9.2). A scheduler that routes by version reads it
    (§9.5)."""
    return [OPTIMIZED_PLAN_FORMAT_VERSION_1]


def version_set_text(v: List[UInt32]) -> String:
    """A version set as refusals print it: `{1, 2}`."""
    var out = String("{")
    for i in range(len(v)):
        if i > 0:
            out += ", "
        out += String(Int(v[i]))
    return out + "}"


# ---- the version-1 field set ---------------------------------------------------

# The header's messages, by index.
comptime _M_PLAN = 0
comptime _M_STAMP = 1
comptime _M_NEEDS = 2
comptime _M_RUNTIME = 3
comptime _M_WRITE = 4
comptime _M_ADVICE = 5
comptime _M_STATS = 6

# How a field's value is checked.
comptime _K_U32 = 0  # varint, at most 2^32-1
comptime _K_U64 = 1  # varint
comptime _K_BOOL = 2  # varint, 0 or 1
comptime _K_ENUM = 3  # varint, at most `limit`: a larger value is one the version does not include
comptime _K_BYTES = 4  # bytes
comptime _K_STR = 5  # string: well-formed UTF-8, which protoc requires and the generated decoder does not check
comptime _K_MSG = 6  # a header submessage, walked as `child`
comptime _K_BODY = 7  # `OptimizedPlan.body`: length-delimited, never parsed


@fieldwise_init
struct _Rule(Copyable, Movable, ImplicitlyCopyable):
    """What version 1 says about one field number of one message."""

    var known: Bool
    var name: String
    var kind: Int
    var repeated: Bool
    var child: Int
    var limit: UInt64


def _f(name: String, kind: Int, repeated: Bool = False, child: Int = -1, limit: UInt64 = 0) -> _Rule:
    return _Rule(True, name, kind, repeated, child, limit)


def _unknown() -> _Rule:
    return _Rule(False, "", -1, False, -1, 0)


def _message_name(m: Int) -> String:
    if m == _M_PLAN:
        return "OptimizedPlan"
    if m == _M_STAMP:
        return "ProducerStamp"
    if m == _M_NEEDS:
        return "DeclaredNeeds"
    if m == _M_RUNTIME:
        return "RuntimeNeed"
    if m == _M_WRITE:
        return "WireWriteTarget"
    if m == _M_ADVICE:
        return "PlanAdvice"
    return "ScanStats"


def _rule(m: Int, n: Int) -> _Rule:
    """Version 1's rule for field `n` of message `m`; `known` is False for a
    number version 1 does not include (held, reserved or never declared)."""
    if m == _M_PLAN:
        if n == 1:
            return _f("format_version", _K_U32)
        if n == 2:
            return _f("producer", _K_MSG, child=_M_STAMP)
        if n == 3:
            return _f("plan_digest", _K_BYTES)
        if n == 4:
            return _f("recurring_signature", _K_BYTES)
        if n == 5:
            return _f("needs", _K_MSG, child=_M_NEEDS)
        if n == 6:
            return _f("write_target", _K_MSG, child=_M_WRITE)
        if n == 7:
            return _f("advice", _K_MSG, child=_M_ADVICE)
        if n == 8:
            return _f("body", _K_BODY)
    elif m == _M_STAMP:
        if n == 1:
            return _f("engine_build", _K_BYTES)
        if n == 2:
            return _f("optimizer_contract_version", _K_U32)
        if n == 3:
            return _f("optimizer_config_digest", _K_BYTES)
        if n == 5:
            return _f("kind", _K_STR)
    elif m == _M_NEEDS:
        if n == 5:
            return _f("data_scopes", _K_STR, repeated=True)
        if n == 8:
            return _f("unbounded", _K_BOOL)
        if n == 9:
            return _f("runtimes", _K_MSG, repeated=True, child=_M_RUNTIME)
    elif m == _M_RUNTIME:
        if n == 1:
            return _f("runtime", _K_STR)
        if n == 2:
            return _f("runtime_abi", _K_STR)
    elif m == _M_WRITE:
        if n == 1:
            return _f("path", _K_STR)
        if n == 2:
            return _f("format", _K_ENUM, limit=3)  # WFMT_JSONL
        if n == 3:
            return _f("codec", _K_ENUM, limit=5)  # WCOMP_LZ4
    elif m == _M_ADVICE:
        if n == 2:
            return _f("stats_basis", _K_MSG, repeated=True, child=_M_STATS)
    else:
        if n == 1:
            return _f("pin_index", _K_U32)
        if n == 2:
            return _f("row_count", _K_U64)
    return _unknown()


def _wire_type_of(kind: Int) -> Int:
    if kind == _K_BYTES or kind == _K_STR or kind == _K_MSG or kind == _K_BODY:
        return PB_WIRE_LEN
    return PB_WIRE_VARINT


# ---- the walk ------------------------------------------------------------------


@fieldwise_init
struct _Field(Copyable, Movable, ImplicitlyCopyable):
    """One field of a message: its number and wire type, and its value as a
    varint (`value`) or as the payload `[start, end)`; `next` follows it."""

    var number: Int
    var wire_type: Int
    var value: UInt64
    var start: Int
    var end: Int
    var next: Int


def _malformed(var what: String) -> Error:
    return Error(OPTIMIZED_PLAN_HEADER_MALFORMED + ": " + what^)


def _varint(b: Span[UInt8, _], pos: Int, end: Int, what: String) raises -> Tuple[UInt64, Int]:
    """The varint at `pos`, which must end at or before `end`."""
    var v: UInt64
    var p: Int
    try:
        var r = pb_read_varint(b, pos)
        v = r.value
        p = r.new_pos
    except e:
        raise _malformed(what + " at byte " + String(pos) + ": " + String(e))
    if p > end:
        raise _malformed(what + " at byte " + String(pos) + " runs past the end of its message")
    return (v, p)


def _next_field(b: Span[UInt8, _], pos: Int, end: Int, msg: String) raises -> _Field:
    var t = _varint(b, pos, end, msg + ": a field tag")
    var number = Int(t[0] >> 3)
    var wire_type = Int(t[0] & 7)
    var p = t[1]
    if number == 0 or t[0] >> 3 > 536870911:
        raise _malformed(msg + ": field number " + String(t[0] >> 3) + " at byte " + String(pos) + " is not a field number")
    var where = msg + " field " + String(number)
    if wire_type == PB_WIRE_VARINT:
        var v = _varint(b, p, end, where)
        return _Field(number, wire_type, v[0], p, v[1], v[1])
    if wire_type == PB_WIRE_LEN:
        var n = _varint(b, p, end, where + ": a length")
        var s = n[1]
        if n[0] > UInt64(end - s):
            raise _malformed(where + ": a length of " + String(n[0]) + " runs past the end of its message")
        var e = s + Int(n[0])
        return _Field(number, wire_type, 0, s, e, e)
    var width = 0
    if wire_type == PB_WIRE_FIXED64:
        width = 8
    elif wire_type == PB_WIRE_FIXED32:
        width = 4
    else:
        raise _malformed(where + ": wire type " + String(wire_type) + " is not one proto3 writes")
    if end - p < width:
        raise _malformed(where + ": a fixed-width value runs past the end of its message")
    return _Field(number, wire_type, 0, p, p + width, p + width)


def _check_utf8(b: Span[UInt8, _], start: Int, end: Int, where: String) raises:
    """Refuse a `string` field that is not well-formed UTF-8 (the Unicode
    table: no overlong form, no surrogate, nothing above U+10FFFF)."""
    var p = start
    while p < end:
        var c = b[p]
        if c < 0x80:
            p += 1
            continue
        var n = 0
        var lo: UInt8 = 0x80
        var hi: UInt8 = 0xBF
        if c >= 0xC2 and c <= 0xDF:
            n = 2
        elif c == 0xE0:
            n = 3
            lo = 0xA0
        elif (c >= 0xE1 and c <= 0xEC) or c == 0xEE or c == 0xEF:
            n = 3
        elif c == 0xED:
            n = 3
            hi = 0x9F
        elif c == 0xF0:
            n = 4
            lo = 0x90
        elif c >= 0xF1 and c <= 0xF3:
            n = 4
        elif c == 0xF4:
            n = 4
            hi = 0x8F
        if n == 0 or end - p < n or b[p + 1] < lo or b[p + 1] > hi:
            raise _malformed(where + " is not well-formed UTF-8 at byte " + String(p))
        for k in range(2, n):
            if b[p + k] < 0x80 or b[p + k] > 0xBF:
                raise _malformed(where + " is not well-formed UTF-8 at byte " + String(p))
        p += n


def _understated(version: UInt32, msg: String, number: Int, what: String) -> Error:
    return Error(
        OPTIMIZED_PLAN_VERSION_UNSUPPORTED
        + ": format_version "
        + String(Int(version))
        + " does not include "
        + msg
        + " "
        + what
        + " (field "
        + String(number)
        + "); a header that carries it understates its version (docs/design/optimized_plan.md §9.2)"
    )


def _walk(b: Span[UInt8, _], start: Int, end: Int, m: Int, version: UInt32) raises:
    """Check message `m` in `b[start:end]` against version 1's field set,
    descending into every header submessage and never into `body`."""
    var msg = _message_name(m)
    var seen = List[Int]()
    var pos = start
    while pos < end:
        var f = _next_field(b, pos, end, msg)
        pos = f.next
        var r = _rule(m, f.number)
        if not r.known:
            raise _understated(version, msg, f.number, "this field")
        var where = msg + "." + r.name
        if f.wire_type != _wire_type_of(r.kind):
            raise _malformed(where + " (field " + String(f.number) + ") arrives with wire type " + String(f.wire_type))
        if not r.repeated:
            for i in range(len(seen)):
                if seen[i] == f.number:
                    raise _malformed(where + " occurs twice; a singular field occurs at most once")
            seen.append(f.number)
        if r.kind == _K_U32 and f.value > 4294967295:
            raise _malformed(where + " is " + String(f.value) + ", above the uint32 range")
        if r.kind == _K_BOOL and f.value > 1:
            raise _malformed(where + " is " + String(f.value) + "; a bool is 0 or 1")
        if r.kind == _K_ENUM and f.value > r.limit:
            raise _understated(version, msg, f.number, "the " + r.name + " value " + String(f.value))
        if r.kind == _K_STR:
            _check_utf8(b, f.start, f.end, where)
        if r.kind == _K_MSG:
            _walk(b, f.start, f.end, r.child, version)


def _format_version(b: Span[UInt8, _]) raises -> UInt32:
    """`format_version` from the top-level field stream; 0 when absent, which
    no version is. The framing and the field's own form are checked here, and
    every other rule in the walk that follows."""
    var version: UInt64 = 0
    var found = False
    var pos = 0
    while pos < len(b):
        var f = _next_field(b, pos, len(b), "OptimizedPlan")
        pos = f.next
        if f.number != 1:
            continue
        if f.wire_type != PB_WIRE_VARINT:
            raise _malformed("OptimizedPlan.format_version (field 1) arrives with wire type " + String(f.wire_type))
        if found:
            raise _malformed("OptimizedPlan.format_version occurs twice; a singular field occurs at most once")
        if f.value > 4294967295:
            raise _malformed("OptimizedPlan.format_version is " + String(f.value) + ", above the uint32 range")
        found = True
        version = f.value
    return UInt32(version)


# ---- the codec -----------------------------------------------------------------


def decode_optimized_plan_header(var bytes: List[UInt8]) raises -> OptimizedPlan:
    """Decode an `OptimizedPlan` with its body left as bytes, after steps 1
    and 2 of §7.2: refuses `OPTIMIZED_PLAN_LIMIT_EXCEEDED`,
    `OPTIMIZED_PLAN_VERSION_UNSUPPORTED` and `OPTIMIZED_PLAN_HEADER_MALFORMED`.
    Step 3 is `check_optimized_plan_header` (header_admit.mojo)."""
    if len(bytes) > OPTIMIZED_PLAN_MAX_BYTES:
        raise Error(
            OPTIMIZED_PLAN_LIMIT_EXCEEDED
            + ": "
            + String(len(bytes))
            + " bytes; an optimized plan is at most "
            + String(OPTIMIZED_PLAN_MAX_BYTES)
            + " (the 16 MiB plan budget and a 1 MiB header allowance)"
        )
    var version = _format_version(Span(bytes))
    var accepted = optimized_plan_format_versions()
    var member = False
    for i in range(len(accepted)):
        if accepted[i] == version:
            member = True
    if not member:
        raise Error(
            OPTIMIZED_PLAN_VERSION_UNSUPPORTED
            + ": format_version "
            + String(Int(version))
            + " is not in this reader's accepted set "
            + version_set_text(accepted)
        )
    _walk(Span(bytes), 0, len(bytes), _M_PLAN, version)
    try:
        return decode_proto[OptimizedPlan](bytes^)
    except e:
        raise _malformed("the generated decoder refused it: " + String(e))  # cov: unreachable the walk above refuses every input the generated decoder does


def encode_optimized_plan_header(header: OptimizedPlan) raises -> List[UInt8]:
    """The header and its body bytes as protobuf, through the generated
    encoder of `komira_plan_proto` (which writes default scalars; the header
    has no canonical form, only the body does, §7.1)."""
    return encode_proto(header)
