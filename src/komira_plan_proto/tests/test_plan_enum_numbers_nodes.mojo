# =============================================================================
# test_plan_enum_numbers_nodes.mojo
# =============================================================================
#
# THE ENUM-VALUE CENSUS of `komira.plan.v1` (plan_vocabulary.proto),
# part 1 of 2: the plan and expression tag spaces and the join, window,
# source and operator enums: PlanTag, ExprTag, AggFn, WindowFn,
# FrameUnits, FrameBound, JoinType, JoinAlgo, AsofDirection, AsofToleranceKind,
# CorrelatedKind, SourceType, SourceOrientation, SourceVariantTag, BinaryOp,
# UnaryOp. The other part is test_plan_enum_numbers_functions.mojo.
#
# An enum value's number is what is stored, like a field's: renumbering
# `COL_SIDE_LEFT = 2` in the .proto moves the generated encoder and decoder
# together and no Mojo round trip notices. `LEDGER` (at the end of the file)
# lists every value as `<Enum>.<VALUE> <number>`, written by hand, and each
# row must hold three ways:
#   1. the generated enum maps the NAME to the number and the number back to
#      the name, and declares the name;
#   2. where a field of the enum's type exists, the literal varint `<number>`
#      written under that field decodes to a value whose name is the row's
#      name (PlanTag, ExprTag and ArrowType have no such field);
#   3. that message re-encodes to the same records.
# test_plan_census_complete.mojo holds this ledger to every value protoc
# declares, so a value added without a row fails there.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import ProtoEnum, decode_proto, encode_proto
from komira_plan_proto.plan import (
    WireAggFn,
    WireAsofJoinNode,
    WireAsofTolerance,
    WireBinaryOp,
    WireCorrelatedSubquery,
    WireFrame,
    WireJoinNode,
    WireScanBinding,
    WireUnaryOp,
    WireWindowFn,
)
from komira_plan_proto.plan_vocabulary import (
    AggFn,
    AsofDirection,
    AsofToleranceKind,
    BinaryOp,
    CorrelatedKind,
    ExprTag,
    FrameBound,
    FrameUnits,
    JoinAlgo,
    JoinType,
    PlanTag,
    SourceOrientation,
    SourceType,
    SourceVariantTag,
    UnaryOp,
    WindowFn,
)


# ---- the ledger ---------------------------------------------------------------


struct _Ledger(Movable):
    """This file's census rows, `<Message>.<field> <number>` or
    `<Enum>.<VALUE> <number>`, read from `LEDGER`. Every hand-written record
    takes its number from here and marks its row; `check_all_hit` then
    refuses a row no test wrote."""

    var names: List[String]
    var numbers: List[Int]
    var hits: List[Int]

    def __init__(out self, text: String) raises:
        self.names = List[String]()
        self.numbers = List[Int]()
        self.hits = List[Int]()
        for raw in text.split("\n"):
            var line = String(String(raw).strip())
            if line.byte_length() == 0:
                continue
            var parts = line.split(" ")
            if len(parts) != 2:
                raise Error("malformed ledger row: `" + line + "`")
            var name = String(parts[0])
            for i in range(len(self.names)):
                if self.names[i] == name:
                    raise Error("ledger row listed twice: " + name)
            self.names.append(name)
            self.numbers.append(Int(String(parts[1])))
            self.hits.append(0)

    def number(mut self, name: String) raises -> Int:
        for i in range(len(self.names)):
            if self.names[i] == name:
                self.hits[i] += 1
                return self.numbers[i]
        raise Error("no ledger row for " + name)

    def check_all_hit(self) raises:
        var missed = String("")
        for i in range(len(self.names)):
            if self.hits[i] == 0:
                missed += " " + self.names[i]
        assert_equal(missed, "", "ledger rows no test wrote")


# ---- a hand-written wire stream ---------------------------------------------------

comptime _VARINT = 0
comptime _I64 = 1
comptime _LEN = 2


def _varint(mut b: List[UInt8], v: UInt64):
    var x = v
    while x >= 0x80:
        b.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    b.append(UInt8(x))


def _tag(mut b: List[UInt8], field: Int, wire_type: Int):
    _varint(b, UInt64((field << 3) | wire_type))


def _raw_u(mut b: List[UInt8], field: Int, v: UInt64):
    _tag(b, field, _VARINT)
    _varint(b, v)


def _raw_s(mut b: List[UInt8], field: Int, s: String):
    _tag(b, field, _LEN)
    _varint(b, UInt64(s.byte_length()))
    for c in s.as_bytes():
        b.append(c)


def _raw_m(mut b: List[UInt8], field: Int, m: List[UInt8]):
    _tag(b, field, _LEN)
    _varint(b, UInt64(len(m)))
    for i in range(len(m)):
        b.append(m[i])


def _u(mut L: _Ledger, mut b: List[UInt8], q: String, v: UInt64) raises:
    """A varint record of `q` (an unsigned, a bool, an enum)."""
    _raw_u(b, L.number(q), v)


def _i(mut L: _Ledger, mut b: List[UInt8], q: String, v: Int64) raises:
    """A varint record of a signed `q`: a negative is ten bytes."""
    _raw_u(b, L.number(q), UInt64(v))


def _s(mut L: _Ledger, mut b: List[UInt8], q: String, s: String) raises:
    _raw_s(b, L.number(q), s)


def _m(mut L: _Ledger, mut b: List[UInt8], q: String, m: List[UInt8]) raises:
    _raw_m(b, L.number(q), m)


def _d(mut L: _Ledger, mut b: List[UInt8], q: String, bits: UInt64) raises:
    """A 64-bit record (wire type 1) of a double `q`: its IEEE bits, little
    endian."""
    _tag(b, L.number(q), _I64)
    for k in range(8):
        b.append(UInt8((bits >> UInt64(8 * k)) & 0xFF))


def _hex(b: List[UInt8]) -> String:
    var out = String("")
    for i in range(len(b)):
        out += hex(Int(b[i])) + " "
    return out


# ⚠ THE GENERATED BINARY ENCODER WRITES PROTO3 ZERO VALUES (every scalar at
# its default) and writes a message's oneof after its plain fields. Both
# sides are compared in a canonical form: zero-valued records dropped
# (recursively), each level's records sorted stably by field number (a
# repeated field keeps its order). Every value this census writes is non-zero
# except false elements of repeated bools and the zero value of each enum,
# which the named assertions hold instead. A zero-length record is dropped
# too, so whether an absent message field writes nothing is held in exact
# bytes by `test_envelope_presence` (test_plan_field_numbers_plan.mojo).


def _read_varint(b: List[UInt8], mut pos: Int, mut ok: Bool) -> UInt64:
    var v: UInt64 = 0
    var shift: UInt64 = 0
    while pos < len(b) and shift < 64:
        var c = b[pos]
        pos += 1
        v |= UInt64(c & 0x7F) << shift
        if (c & 0x80) == 0:
            return v
        shift += 7
    ok = False
    return v


def _canon(b: List[UInt8], mut out: List[UInt8]) -> Bool:
    var fields = List[Int]()
    var records = List[List[UInt8]]()
    if not _canon_records(b, fields, records):
        return False
    var order = List[Int]()
    for i in range(len(fields)):
        var j = len(order)
        order.append(i)
        while j > 0 and fields[order[j - 1]] > fields[i]:
            order[j] = order[j - 1]
            j -= 1
        order[j] = i
    for k in range(len(order)):
        ref rec = records[order[k]]
        for x in range(len(rec)):
            out.append(rec[x])
    return True


def _canon_records(
    b: List[UInt8], mut fields: List[Int], mut records: List[List[UInt8]]
) -> Bool:
    var pos = 0
    var ok = True
    while pos < len(b):
        var tag = _read_varint(b, pos, ok)
        if not ok or (tag >> 3) == 0:
            return False
        var wt = Int(tag & 7)
        var rec = List[UInt8]()
        _varint(rec, tag)
        var keep = False
        if wt == _VARINT:
            var v = _read_varint(b, pos, ok)
            if not ok:
                return False
            keep = v != 0
            _varint(rec, v)
        elif wt == _LEN:
            var n = Int(_read_varint(b, pos, ok))
            if not ok or pos + n > len(b):
                return False
            var content = List[UInt8]()
            for k in range(n):
                content.append(b[pos + k])
            pos += n
            var inner = List[UInt8]()
            if not _canon(content, inner):
                inner = content^
            keep = len(inner) > 0
            _varint(rec, UInt64(len(inner)))
            for k in range(len(inner)):
                rec.append(inner[k])
        elif wt == 1 or wt == 5:
            var width = 8 if wt == 1 else 4
            if pos + width > len(b):
                return False
            for k in range(width):
                if b[pos + k] != 0:
                    keep = True
                rec.append(b[pos + k])
            pos += width
        else:
            return False
        if keep:
            fields.append(Int(tag >> 3))
            records.append(rec^)
    return True


def _same(got: List[UInt8], want: List[UInt8], what: String) raises:
    var cg = List[UInt8]()
    var cw = List[UInt8]()
    assert_true(_canon(got, cg), what + ": the re-encoding does not parse")
    assert_true(_canon(want, cw), what + ": the hand-written bytes do not parse")
    assert_equal(
        _hex(cg),
        _hex(cw),
        what
        + ": re-encoding the decoded message does not give the hand-written"
        + " records back, so a field number or wire type moved",
    )


def _names(s: String) -> List[String]:
    var out = List[String]()
    for w in s.split(" "):
        if w.byte_length() > 0:
            out.append(String(w))
    return out^


def _strs(got: List[String], want: String, what: String) raises:
    """`got` is the space-separated `want`, in order."""
    var w = _names(want)
    assert_equal(len(got), len(w), what + ": element count")
    for i in range(len(w)):
        assert_equal(got[i], w[i], what + "[" + String(i) + "]")


def _one_hot(got: List[Bool], names: List[String], hot: Int, what: String) raises:
    """Exactly `got[hot]` is true: the one bool written landed on its name.
    `got` reads every bool of the message's ONE_HOT row, in its order."""
    assert_equal(len(got), len(names), what + ": the test reads every bool of its ONE_HOT row")
    for i in range(len(got)):
        assert_equal(got[i], i == hot, what + ": bool " + String(i) + " of the message")


def _first_tag(b: List[UInt8]) -> String:
    """The tag bytes of the first record of `b`."""
    var out = String("")
    for i in range(len(b)):
        out += hex(Int(b[i])) + " "
        if (b[i] & 0x80) == 0:
            break
    return out


# ---- the checks ---------------------------------------------------------------------


def _rec(field: Int, n: Int) -> List[UInt8]:
    """A varint record of value `n` under the host field `field` (a payload:
    the host field's number is pinned by the field census)."""
    var b = List[UInt8]()
    _raw_u(b, field, UInt64(n))
    return b^


def _names_agree[E: ProtoEnum & ImplicitlyDestructible](v: String, n: Int, q: String) raises:
    assert_true(E.is_known_json_name(v), q + ": not a declared value name")
    assert_equal(E.from_json_name(v).number(), n, q + ": the number its name maps to")
    assert_equal(E.from_number(n).json_name(), v, q + ": the name its number maps to")


def _host(got: String, again: List[UInt8], sent: List[UInt8], v: String, q: String) raises:
    assert_equal(got, v, q + ": the value its number decodes as through its host field")
    _same(again, sent, q)


def _check(enum: String, v: String, n: Int) raises:
    """Row `<enum>.<v> <n>`: the generated enum maps the name and the number
    to each other, and (where a field of the enum type exists) the literal
    varint `n` under that field decodes as `v` and re-encodes the same."""
    var q = enum + "." + v
    if enum == "PlanTag":
        _names_agree[PlanTag](v, n, q)
    elif enum == "ExprTag":
        _names_agree[ExprTag](v, n, q)
    elif enum == "AggFn":
        _names_agree[AggFn](v, n, q)
        var b = _rec(1, n)  # WireAggFn.op
        var m = decode_proto[WireAggFn](b.copy())
        _host(m.op.json_name(), encode_proto(m), b, v, q)
    elif enum == "WindowFn":
        _names_agree[WindowFn](v, n, q)
        var b = _rec(1, n)  # WireWindowFn.func
        var m = decode_proto[WireWindowFn](b.copy())
        _host(m.func.json_name(), encode_proto(m), b, v, q)
    elif enum == "FrameUnits":
        _names_agree[FrameUnits](v, n, q)
        var b = _rec(1, n)  # WireFrame.units
        var m = decode_proto[WireFrame](b.copy())
        _host(m.units.json_name(), encode_proto(m), b, v, q)
    elif enum == "FrameBound":
        _names_agree[FrameBound](v, n, q)
        var b = _rec(2, n)  # WireFrame.start_tag
        var m = decode_proto[WireFrame](b.copy())
        _host(m.start_tag.json_name(), encode_proto(m), b, v, q)
    elif enum == "JoinType":
        _names_agree[JoinType](v, n, q)
        var b = _rec(5, n)  # WireJoinNode.join_type
        var m = decode_proto[WireJoinNode](b.copy())
        _host(m.join_type.json_name(), encode_proto(m), b, v, q)
    elif enum == "JoinAlgo":
        _names_agree[JoinAlgo](v, n, q)
        var b = _rec(6, n)  # WireJoinNode.algo_hint
        var m = decode_proto[WireJoinNode](b.copy())
        _host(m.algo_hint.json_name(), encode_proto(m), b, v, q)
    elif enum == "AsofDirection":
        _names_agree[AsofDirection](v, n, q)
        var b = _rec(5, n)  # WireAsofJoinNode.strategy
        var m = decode_proto[WireAsofJoinNode](b.copy())
        _host(m.strategy.json_name(), encode_proto(m), b, v, q)
    elif enum == "AsofToleranceKind":
        _names_agree[AsofToleranceKind](v, n, q)
        var b = _rec(1, n)  # WireAsofTolerance.kind
        var m = decode_proto[WireAsofTolerance](b.copy())
        _host(m.kind.json_name(), encode_proto(m), b, v, q)
    elif enum == "CorrelatedKind":
        _names_agree[CorrelatedKind](v, n, q)
        var b = _rec(3, n)  # WireCorrelatedSubquery.kind
        var m = decode_proto[WireCorrelatedSubquery](b.copy())
        _host(m.kind.json_name(), encode_proto(m), b, v, q)
    elif enum == "SourceType":
        _names_agree[SourceType](v, n, q)
        var b = _rec(13, n)  # WireScanBinding.legacy_source_type
        var m = decode_proto[WireScanBinding](b.copy())
        _host(m.legacy_source_type.json_name(), encode_proto(m), b, v, q)
    elif enum == "SourceOrientation":
        _names_agree[SourceOrientation](v, n, q)
        var b = _rec(12, n)  # WireScanBinding.orientation
        var m = decode_proto[WireScanBinding](b.copy())
        _host(m.orientation.json_name(), encode_proto(m), b, v, q)
    elif enum == "SourceVariantTag":
        _names_agree[SourceVariantTag](v, n, q)
        var b = _rec(14, n)  # WireScanBinding.variant_tag
        var m = decode_proto[WireScanBinding](b.copy())
        _host(m.variant_tag.json_name(), encode_proto(m), b, v, q)
    elif enum == "BinaryOp":
        _names_agree[BinaryOp](v, n, q)
        var b = _rec(1, n)  # WireBinaryOp.op
        var m = decode_proto[WireBinaryOp](b.copy())
        _host(m.op.json_name(), encode_proto(m), b, v, q)
    elif enum == "UnaryOp":
        _names_agree[UnaryOp](v, n, q)
        var b = _rec(1, n)  # WireUnaryOp.op
        var m = decode_proto[WireUnaryOp](b.copy())
        _host(m.op.json_name(), encode_proto(m), b, v, q)
    else:
        raise Error("no check for enum " + enum + ": add it to `_check`")


def main() raises:
    var L = _Ledger(LEDGER)
    var enums = 0
    var last = String("")
    for i in range(len(L.names)):
        var row = L.names[i]
        var dot = row.find(".")
        var enum = String(row[byte=0:dot])
        var value = String(row[byte = dot + 1 : row.byte_length()])
        if enum != last:
            enums += 1
            last = enum
        _check(enum, value, L.number(row))
    L.check_all_hit()
    print("ALL", len(L.names), "VALUES OF", enums, "komira.plan.v1 ENUMS PINNED")


# ---- THE LEDGER: every value of these enums, numbers written by hand --------
# Change a number here only with the .proto, and only one that never
# shipped: a shipped number is permanent.

comptime LEDGER = """
PlanTag.PLAN_WIRE_UNSPECIFIED 0
PlanTag.PLAN_SCAN 1
PlanTag.PLAN_FILTER 2
PlanTag.PLAN_PROJECT 3
PlanTag.PLAN_AGGREGATE 4
PlanTag.PLAN_JOIN 5
PlanTag.PLAN_SORT 6
PlanTag.PLAN_LIMIT 7
PlanTag.PLAN_DISTINCT 8
PlanTag.PLAN_TOPN 9
PlanTag.PLAN_PARTITION_BY 10
PlanTag.PLAN_PARTITION_TOPN 11
PlanTag.PLAN_ASOF_JOIN 12
PlanTag.PLAN_UNION 13
PlanTag.PLAN_VIEW_REF 14
PlanTag.PLAN_CSE_REF 15
PlanTag.PLAN_CAST_TO_VARCHAR 16
ExprTag.EXPR_WIRE_UNSPECIFIED 0
ExprTag.EXPR_COL_REF 1
ExprTag.EXPR_COL_IDX 2
ExprTag.EXPR_LITERAL 3
ExprTag.EXPR_BINARY_OP 4
ExprTag.EXPR_UNARY_OP 5
ExprTag.EXPR_CAST 6
ExprTag.EXPR_ALIAS 7
ExprTag.EXPR_STRING_OP 8
ExprTag.EXPR_WHEN 9
ExprTag.EXPR_IN_LIST 10
ExprTag.EXPR_AGG_FN 13
ExprTag.EXPR_WINDOW_FN 14
ExprTag.EXPR_CORRELATED_SUBQUERY 15
ExprTag.EXPR_REGEXP 16
ExprTag.EXPR_STRUCT_FIELD 17
ExprTag.EXPR_STRUCT_FIELD_IDX 18
ExprTag.EXPR_MAP_GET 19
ExprTag.EXPR_JSON_EXTRACT 20
ExprTag.EXPR_EXTRACT 21
ExprTag.EXPR_MATH_FN 22
ExprTag.EXPR_MATH_FN2 23
ExprTag.EXPR_SUBSTRING 24
ExprTag.EXPR_STRING_FN 25
ExprTag.EXPR_UDF_CALL 26
ExprTag.EXPR_STRING_FN_N 27
AggFn.AGG_WIRE_UNSPECIFIED 0
AggFn.AGG_SUM 1
AggFn.AGG_COUNT 2
AggFn.AGG_MIN 3
AggFn.AGG_MAX 4
AggFn.AGG_MEAN 5
AggFn.AGG_COUNT_DISTINCT 6
AggFn.AGG_FIRST 7
AggFn.AGG_LAST 8
AggFn.AGG_STDDEV_SAMP 9
AggFn.AGG_CORR 10
AggFn.AGG_MEDIAN 11
AggFn.AGG_LARGEST_K 12
AggFn.AGG_VAR_SAMP 13
AggFn.AGG_COVAR_POP 14
AggFn.AGG_COVAR_SAMP 15
AggFn.AGG_REGR_AVGX 16
AggFn.AGG_REGR_AVGY 17
AggFn.AGG_REGR_COUNT 18
AggFn.AGG_REGR_SXX 19
AggFn.AGG_REGR_SXY 20
AggFn.AGG_REGR_SYY 21
AggFn.AGG_REGR_SLOPE 22
AggFn.AGG_REGR_INTERCEPT 23
AggFn.AGG_REGR_R2 24
AggFn.AGG_VAR_POP 25
AggFn.AGG_STDDEV_POP 26
AggFn.AGG_SEM 27
AggFn.AGG_COUNT_IF 28
AggFn.AGG_BOOL_AND 29
AggFn.AGG_BOOL_OR 30
AggFn.AGG_PRODUCT 31
AggFn.AGG_ANY_VALUE 32
AggFn.AGG_KAHAN_SUM 33
AggFn.AGG_KAHAN_AVG 34
AggFn.AGG_SKEWNESS 35
AggFn.AGG_KURTOSIS 36
AggFn.AGG_KURTOSIS_POP 37
WindowFn.PF_WIRE_UNSPECIFIED 0
WindowFn.PF_ROW_NUMBER 1
WindowFn.PF_RANK 2
WindowFn.PF_DENSE_RANK 3
WindowFn.PF_PERCENT_RANK 4
WindowFn.PF_CUME_DIST 5
WindowFn.PF_NTILE 6
WindowFn.PF_LAG 11
WindowFn.PF_LEAD 12
WindowFn.PF_FIRST_VALUE 13
WindowFn.PF_LAST_VALUE 14
WindowFn.PF_NTH_VALUE 15
WindowFn.PF_SUM 21
WindowFn.PF_AVG 22
WindowFn.PF_COUNT 23
WindowFn.PF_MIN 24
WindowFn.PF_MAX 25
FrameUnits.FRAME_UNITS_WIRE_UNSPECIFIED 0
FrameUnits.FRAME_UNITS_ROWS 1
FrameUnits.FRAME_UNITS_RANGE 2
FrameBound.FRAME_BOUND_WIRE_UNSPECIFIED 0
FrameBound.FRAME_BOUND_UNBOUNDED_PRECEDING 1
FrameBound.FRAME_BOUND_PRECEDING 2
FrameBound.FRAME_BOUND_CURRENT_ROW 3
FrameBound.FRAME_BOUND_FOLLOWING 4
FrameBound.FRAME_BOUND_UNBOUNDED_FOLLOWING 5
JoinType.JOIN_WIRE_UNSPECIFIED 0
JoinType.JOIN_INNER 1
JoinType.JOIN_LEFT 2
JoinType.JOIN_RIGHT 3
JoinType.JOIN_FULL 4
JoinType.JOIN_SEMI 5
JoinType.JOIN_ANTI 6
JoinType.JOIN_CROSS 7
JoinAlgo.JOIN_ALGO_WIRE_UNSPECIFIED 0
JoinAlgo.JOIN_ALGO_AUTO 1
JoinAlgo.JOIN_ALGO_HASH 2
JoinAlgo.JOIN_ALGO_SORT_MERGE 3
AsofDirection.ASOF_WIRE_UNSPECIFIED 0
AsofDirection.ASOF_BACKWARD 1
AsofDirection.ASOF_FORWARD 2
AsofDirection.ASOF_NEAREST 3
AsofToleranceKind.ASOF_TOL_WIRE_UNSPECIFIED 0
AsofToleranceKind.ASOF_TOL_NONE 1
AsofToleranceKind.ASOF_TOL_INT64 2
AsofToleranceKind.ASOF_TOL_FLOAT64 3
CorrelatedKind.CORR_KIND_WIRE_UNSPECIFIED 0
CorrelatedKind.CORR_KIND_EXISTS 1
CorrelatedKind.CORR_KIND_NOT_EXISTS 2
CorrelatedKind.CORR_KIND_SCALAR 3
CorrelatedKind.CORR_KIND_IN_CORRELATED 4
SourceType.SOURCE_WIRE_UNSPECIFIED 0
SourceType.SOURCE_PARQUET 1
SourceType.SOURCE_CSV 2
SourceType.SOURCE_NDJSON 3
SourceType.SOURCE_IN_MEMORY 4
SourceType.SOURCE_JSON 5
SourceType.SOURCE_ORC 6
SourceType.SOURCE_AVRO 7
SourceType.SOURCE_ARROW 8
SourceType.SOURCE_BINDING 9
SourceOrientation.SOURCE_KIND_WIRE_UNSPECIFIED 0
SourceOrientation.SOURCE_KIND_COLUMNAR 1
SourceOrientation.SOURCE_KIND_ROW 2
SourceOrientation.SOURCE_KIND_UNSET 256
SourceVariantTag.SOURCE_VARIANT_WIRE_UNSPECIFIED 0
SourceVariantTag.SOURCE_VARIANT_JSON 3
SourceVariantTag.SOURCE_VARIANT_CSV 4
SourceVariantTag.SOURCE_VARIANT_ARROW_UNCOMPRESSED 5
SourceVariantTag.SOURCE_VARIANT_ARROW_LZ4_FRAME 6
SourceVariantTag.SOURCE_VARIANT_ARROW_ZSTD 7
SourceVariantTag.SOURCE_VARIANT_ORC 8
SourceVariantTag.SOURCE_VARIANT_AVRO 9
SourceVariantTag.SOURCE_VARIANT_BINDING 10
BinaryOp.BIN_WIRE_UNSPECIFIED 0
BinaryOp.BIN_ADD 1
BinaryOp.BIN_SUB 2
BinaryOp.BIN_MUL 3
BinaryOp.BIN_DIV 4
BinaryOp.BIN_MOD 5
BinaryOp.BIN_EQ 11
BinaryOp.BIN_NE 12
BinaryOp.BIN_LT 13
BinaryOp.BIN_LE 14
BinaryOp.BIN_GT 15
BinaryOp.BIN_GE 16
BinaryOp.BIN_AND 21
BinaryOp.BIN_OR 22
UnaryOp.UN_WIRE_UNSPECIFIED 0
UnaryOp.UN_NOT 1
UnaryOp.UN_NEGATE 2
UnaryOp.UN_IS_NULL 3
UnaryOp.UN_IS_NOT_NULL 4
UnaryOp.UN_ABS 5
UnaryOp.UN_SIGN 6
UnaryOp.UN_TRUNC 7
UnaryOp.UN_ROUND 8
UnaryOp.UN_BIT_COUNT 9
"""
