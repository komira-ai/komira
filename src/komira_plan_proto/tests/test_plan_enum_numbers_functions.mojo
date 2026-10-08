# =============================================================================
# test_plan_enum_numbers_functions.mojo
# =============================================================================
#
# THE ENUM-VALUE CENSUS of `komira.plan.v1` (plan_vocabulary.proto),
# part 2 of 2: the function, type and option enums: StringOp, StringFn, StringFnN, ColSide,
# MathFn1, MathFn2, ExtractField, RegexpOp, ArrowType, WriteFormat,
# WriteCompression, ScalarKind, ScalarTimeUnit, ParamTag,
# PushdownGateMode, SnapshotPolicy, DTypeCode. The other part is test_plan_enum_numbers_nodes.mojo.
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
    WireColRef,
    WireExtract,
    WireField,
    WireMathFn,
    WireMathFn2,
    WireParam,
    WirePushdownGate,
    WireRegexp,
    WireScalar,
    WireScanBinding,
    WireStringFn,
    WireStringFnN,
    WireStringOp,
    WireWriteTarget,
)
from komira_plan_proto.plan_vocabulary import (
    ArrowType,
    ColSide,
    DTypeCode,
    ExtractField,
    MathFn1,
    MathFn2,
    ParamTag,
    PushdownGateMode,
    RegexpOp,
    ScalarKind,
    ScalarTimeUnit,
    SnapshotPolicy,
    StringFn,
    StringFnN,
    StringOp,
    WriteCompression,
    WriteFormat,
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
    if enum == "StringOp":
        _names_agree[StringOp](v, n, q)
        var b = _rec(1, n)  # WireStringOp.op
        var m = decode_proto[WireStringOp](b.copy())
        _host(m.op.json_name(), encode_proto(m), b, v, q)
    elif enum == "StringFn":
        _names_agree[StringFn](v, n, q)
        var b = _rec(1, n)  # WireStringFn.op
        var m = decode_proto[WireStringFn](b.copy())
        _host(m.op.json_name(), encode_proto(m), b, v, q)
    elif enum == "StringFnN":
        _names_agree[StringFnN](v, n, q)
        var b = _rec(1, n)  # WireStringFnN.op
        var m = decode_proto[WireStringFnN](b.copy())
        _host(m.op.json_name(), encode_proto(m), b, v, q)
    elif enum == "ColSide":
        _names_agree[ColSide](v, n, q)
        var b = _rec(2, n)  # WireColRef.side
        var m = decode_proto[WireColRef](b.copy())
        _host(m.side.json_name(), encode_proto(m), b, v, q)
    elif enum == "MathFn1":
        _names_agree[MathFn1](v, n, q)
        var b = _rec(1, n)  # WireMathFn.op
        var m = decode_proto[WireMathFn](b.copy())
        _host(m.op.json_name(), encode_proto(m), b, v, q)
    elif enum == "MathFn2":
        _names_agree[MathFn2](v, n, q)
        var b = _rec(1, n)  # WireMathFn2.op
        var m = decode_proto[WireMathFn2](b.copy())
        _host(m.op.json_name(), encode_proto(m), b, v, q)
    elif enum == "ExtractField":
        _names_agree[ExtractField](v, n, q)
        var b = _rec(1, n)  # WireExtract.unit
        var m = decode_proto[WireExtract](b.copy())
        _host(m.unit.json_name(), encode_proto(m), b, v, q)
    elif enum == "RegexpOp":
        _names_agree[RegexpOp](v, n, q)
        var b = _rec(1, n)  # WireRegexp.op
        var m = decode_proto[WireRegexp](b.copy())
        _host(m.op.json_name(), encode_proto(m), b, v, q)
    elif enum == "ArrowType":
        _names_agree[ArrowType](v, n, q)
    elif enum == "WriteFormat":
        _names_agree[WriteFormat](v, n, q)
        var b = _rec(2, n)  # WireWriteTarget.format
        var m = decode_proto[WireWriteTarget](b.copy())
        _host(m.format.json_name(), encode_proto(m), b, v, q)
    elif enum == "WriteCompression":
        _names_agree[WriteCompression](v, n, q)
        var b = _rec(3, n)  # WireWriteTarget.codec
        var m = decode_proto[WireWriteTarget](b.copy())
        _host(m.codec.json_name(), encode_proto(m), b, v, q)
    elif enum == "ScalarKind":
        _names_agree[ScalarKind](v, n, q)
        var b = _rec(6, n)  # WireScalar.kind
        var m = decode_proto[WireScalar](b.copy())
        _host(m.kind.json_name(), encode_proto(m), b, v, q)
    elif enum == "ScalarTimeUnit":
        _names_agree[ScalarTimeUnit](v, n, q)
        var b = _rec(17, n)  # WireScalar.time_unit
        var m = decode_proto[WireScalar](b.copy())
        _host(m.time_unit.json_name(), encode_proto(m), b, v, q)
    elif enum == "ParamTag":
        _names_agree[ParamTag](v, n, q)
        var b = _rec(2, n)  # WireParam.tag
        var m = decode_proto[WireParam](b.copy())
        _host(m.tag.json_name(), encode_proto(m), b, v, q)
    elif enum == "PushdownGateMode":
        _names_agree[PushdownGateMode](v, n, q)
        var b = _rec(1, n)  # WirePushdownGate.mode
        var m = decode_proto[WirePushdownGate](b.copy())
        _host(m.mode.json_name(), encode_proto(m), b, v, q)
    elif enum == "SnapshotPolicy":
        _names_agree[SnapshotPolicy](v, n, q)
        var b = _rec(10, n)  # WireScanBinding.snapshot_policy
        var m = decode_proto[WireScanBinding](b.copy())
        _host(m.snapshot_policy.json_name(), encode_proto(m), b, v, q)
    elif enum == "DTypeCode":
        _names_agree[DTypeCode](v, n, q)
        var b = _rec(3, n)  # WireField.dtype_code
        var m = decode_proto[WireField](b.copy())
        _host(m.dtype_code.json_name(), encode_proto(m), b, v, q)
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
StringOp.STR_WIRE_UNSPECIFIED 0
StringOp.STR_CONTAINS 1
StringOp.STR_STARTS_WITH 2
StringOp.STR_ENDS_WITH 3
StringOp.STR_LIKE 4
StringFn.STRFN_WIRE_UNSPECIFIED 0
StringFn.STRFN_UPPER 1
StringFn.STRFN_LOWER 2
StringFn.STRFN_TRIM 3
StringFn.STRFN_LTRIM 4
StringFn.STRFN_RTRIM 5
StringFn.STRFN_LENGTH 6
StringFn.STRFN_REVERSE 7
StringFn.STRFN_ASCII 8
StringFn.STRFN_UNICODE 9
StringFn.STRFN_STRLEN 10
StringFn.STRFN_BIT_LENGTH 11
StringFn.STRFN_HEX 12
StringFn.STRFN_BIN 13
StringFn.STRFN_URL_ENCODE 14
StringFn.STRFN_URL_DECODE 15
StringFn.STRFN_REGEXP_ESCAPE 16
StringFn.STRFN_MD5 17
StringFn.STRFN_SHA1 18
StringFn.STRFN_SHA256 19
StringFnN.STRFNN_WIRE_UNSPECIFIED 0
StringFnN.STRFNN_CONCAT 1
StringFnN.STRFNN_CONCAT_WS 2
StringFnN.STRFNN_REPLACE 3
StringFnN.STRFNN_LPAD 4
StringFnN.STRFNN_RPAD 5
StringFnN.STRFNN_REPEAT 6
StringFnN.STRFNN_STRPOS 7
StringFnN.STRFNN_LEVENSHTEIN 8
StringFnN.STRFNN_DAMERAU_LEVENSHTEIN 9
StringFnN.STRFNN_HAMMING 10
StringFnN.STRFNN_TRANSLATE 11
StringFnN.STRFNN_JARO 12
StringFnN.STRFNN_JARO_WINKLER 13
StringFnN.STRFNN_JACCARD 14
ColSide.COL_SIDE_WIRE_UNSPECIFIED 0
ColSide.COL_SIDE_NONE 1
ColSide.COL_SIDE_LEFT 2
ColSide.COL_SIDE_RIGHT 3
MathFn1.MATH_WIRE_UNSPECIFIED 0
MathFn1.MATH_SIN 1
MathFn1.MATH_COS 2
MathFn1.MATH_SQRT 3
MathFn1.MATH_ASIN 4
MathFn1.MATH_RADIANS 5
MathFn1.MATH_CEIL 6
MathFn1.MATH_FLOOR 7
MathFn1.MATH_LN 8
MathFn1.MATH_EXP 9
MathFn1.MATH_LOG10 10
MathFn1.MATH_LOG2 11
MathFn1.MATH_TAN 12
MathFn1.MATH_ATAN 13
MathFn1.MATH_ACOS 14
MathFn1.MATH_COT 15
MathFn1.MATH_DEGREES 16
MathFn1.MATH_CBRT 17
MathFn1.MATH_SINH 18
MathFn1.MATH_COSH 19
MathFn1.MATH_TANH 20
MathFn1.MATH_ACOSH 21
MathFn1.MATH_ASINH 22
MathFn1.MATH_ATANH 23
MathFn1.MATH_GAMMA 24
MathFn2.MATH2_WIRE_UNSPECIFIED 0
MathFn2.MATH2_ATAN2 1
MathFn2.MATH2_POW 2
ExtractField.EXTRACT_WIRE_UNSPECIFIED 0
ExtractField.EXTRACT_YEAR 1
ExtractField.EXTRACT_QUARTER 2
ExtractField.EXTRACT_MONTH 3
ExtractField.EXTRACT_DAY 4
ExtractField.EXTRACT_HOUR 5
ExtractField.EXTRACT_MINUTE 6
ExtractField.EXTRACT_SECOND 7
ExtractField.EXTRACT_DAYOFWEEK 8
ExtractField.EXTRACT_ISODOW 9
ExtractField.EXTRACT_DAYOFYEAR 10
ExtractField.EXTRACT_WEEK 11
ExtractField.EXTRACT_ISOYEAR 12
ExtractField.EXTRACT_YEARWEEK 13
ExtractField.EXTRACT_MILLISECOND 14
ExtractField.EXTRACT_MICROSECOND 15
ExtractField.EXTRACT_TRUNC_YEAR 17
ExtractField.EXTRACT_TRUNC_QUARTER 18
ExtractField.EXTRACT_TRUNC_MONTH 19
ExtractField.EXTRACT_TRUNC_WEEK 20
ExtractField.EXTRACT_TRUNC_DAY 21
ExtractField.EXTRACT_TRUNC_HOUR 22
ExtractField.EXTRACT_TRUNC_MINUTE 23
ExtractField.EXTRACT_TRUNC_SECOND 24
ExtractField.EXTRACT_TRUNC_MILLISECOND 25
ExtractField.EXTRACT_TRUNC_MICROSECOND 26
RegexpOp.REGEXP_WIRE_UNSPECIFIED 0
RegexpOp.REGEXP_LIKE 1
RegexpOp.REGEXP_MATCH 2
RegexpOp.REGEXP_REPLACE 3
RegexpOp.REGEXP_EXTRACT 4
RegexpOp.REGEXP_SPLIT_TO_ARRAY 5
RegexpOp.REGEXP_EXTRACT_ALL 6
RegexpOp.REGEXP_COUNT 7
RegexpOp.REGEXP_INSTR 8
RegexpOp.REGEXP_SUBSTR 9
RegexpOp.REGEXP_FULL_MATCH 10
ArrowType.ARROW_TYPE_WIRE_UNSPECIFIED 0
ArrowType.ARROW_TYPE_NULL 1
ArrowType.ARROW_TYPE_BOOL 2
ArrowType.ARROW_TYPE_INT8 3
ArrowType.ARROW_TYPE_INT16 4
ArrowType.ARROW_TYPE_INT32 5
ArrowType.ARROW_TYPE_INT64 6
ArrowType.ARROW_TYPE_UINT8 7
ArrowType.ARROW_TYPE_UINT16 8
ArrowType.ARROW_TYPE_UINT32 9
ArrowType.ARROW_TYPE_UINT64 10
ArrowType.ARROW_TYPE_FLOAT16 11
ArrowType.ARROW_TYPE_FLOAT32 12
ArrowType.ARROW_TYPE_FLOAT64 13
ArrowType.ARROW_TYPE_STRING 14
ArrowType.ARROW_TYPE_BINARY 15
ArrowType.ARROW_TYPE_DATE32 16
ArrowType.ARROW_TYPE_DATE64 17
ArrowType.ARROW_TYPE_TIMESTAMP 18
ArrowType.ARROW_TYPE_DECIMAL128 19
ArrowType.ARROW_TYPE_DICTIONARY 20
ArrowType.ARROW_TYPE_LIST 21
ArrowType.ARROW_TYPE_STRUCT 22
ArrowType.ARROW_TYPE_TIMESTAMP_S 23
ArrowType.ARROW_TYPE_TIMESTAMP_MS 24
ArrowType.ARROW_TYPE_TIMESTAMP_US 25
ArrowType.ARROW_TYPE_TIMESTAMP_NS 26
ArrowType.ARROW_TYPE_LARGE_STRING 27
ArrowType.ARROW_TYPE_LARGE_BINARY 28
ArrowType.ARROW_TYPE_MAP 29
ArrowType.ARROW_TYPE_DECIMAL256 30
ArrowType.ARROW_TYPE_TIME32_S 31
ArrowType.ARROW_TYPE_TIME32_MS 32
ArrowType.ARROW_TYPE_TIME64_US 33
ArrowType.ARROW_TYPE_TIME64_NS 34
ArrowType.ARROW_TYPE_DURATION_S 35
ArrowType.ARROW_TYPE_DURATION_MS 36
ArrowType.ARROW_TYPE_DURATION_US 37
ArrowType.ARROW_TYPE_DURATION_NS 38
ArrowType.ARROW_TYPE_INTERVAL_YEAR_MONTH 39
ArrowType.ARROW_TYPE_INTERVAL_DAY_TIME 40
ArrowType.ARROW_TYPE_INTERVAL_MONTH_DAY_NANO 41
ArrowType.ARROW_TYPE_UNION_SPARSE 42
ArrowType.ARROW_TYPE_UNION_DENSE 43
ArrowType.ARROW_TYPE_LARGE_LIST 44
ArrowType.ARROW_TYPE_FIXED_SIZE_BINARY 45
ArrowType.ARROW_TYPE_FIXED_SIZE_LIST 46
ArrowType.ARROW_TYPE_BINARY_VIEW 47
ArrowType.ARROW_TYPE_UTF8_VIEW 48
ArrowType.ARROW_TYPE_LIST_VIEW 49
ArrowType.ARROW_TYPE_LARGE_LIST_VIEW 50
WriteFormat.WFMT_WIRE_UNSPECIFIED 0
WriteFormat.WFMT_PARQUET 1
WriteFormat.WFMT_CSV 2
WriteFormat.WFMT_JSONL 3
WriteCompression.WCOMP_WIRE_UNSPECIFIED 0
WriteCompression.WCOMP_SNAPPY 1
WriteCompression.WCOMP_UNCOMPRESSED 2
WriteCompression.WCOMP_ZSTD 3
WriteCompression.WCOMP_GZIP 4
WriteCompression.WCOMP_LZ4 5
ScalarKind.SCALAR_KIND_WIRE_UNSPECIFIED 0
ScalarKind.SCALAR_KIND_DTYPE 1
ScalarKind.SCALAR_KIND_DECIMAL128 2
ScalarKind.SCALAR_KIND_DATE32 3
ScalarKind.SCALAR_KIND_TIMESTAMP 4
ScalarKind.SCALAR_KIND_STRING 5
ScalarKind.SCALAR_KIND_INTERVAL 6
ScalarKind.SCALAR_KIND_TIME 7
ScalarKind.SCALAR_KIND_DURATION 8
ScalarKind.SCALAR_KIND_DECIMAL256 9
ScalarKind.SCALAR_KIND_BINARY 10
ScalarTimeUnit.SCALAR_TIME_UNIT_WIRE_UNSPECIFIED 0
ScalarTimeUnit.SCALAR_TIME_UNIT_SECOND 1
ScalarTimeUnit.SCALAR_TIME_UNIT_MILLI 2
ScalarTimeUnit.SCALAR_TIME_UNIT_MICRO 3
ScalarTimeUnit.SCALAR_TIME_UNIT_NANO 4
ParamTag.PARAM_WIRE_UNSPECIFIED 0
ParamTag.PARAM_STR 1
ParamTag.PARAM_I64 2
ParamTag.PARAM_U64 3
ParamTag.PARAM_F64 4
ParamTag.PARAM_BOOL 5
ParamTag.PARAM_BYTES 6
PushdownGateMode.GATE_WIRE_UNSPECIFIED 0
PushdownGateMode.GATE_REJECT_ALL 1
PushdownGateMode.GATE_ACCEPT_ALL 2
PushdownGateMode.GATE_SHAPED 3
SnapshotPolicy.SNAPSHOT_WIRE_UNSPECIFIED 0
SnapshotPolicy.SNAPSHOT_NONE 1
SnapshotPolicy.SNAPSHOT_PINNED 2
SnapshotPolicy.SNAPSHOT_LIVE 3
DTypeCode._DT_INVALID 0
DTypeCode._DT_BOOL 1
DTypeCode._DT_INT8 2
DTypeCode._DT_INT16 3
DTypeCode._DT_INT32 4
DTypeCode._DT_INT64 5
DTypeCode._DT_UINT8 6
DTypeCode._DT_UINT16 7
DTypeCode._DT_UINT32 8
DTypeCode._DT_UINT64 9
DTypeCode._DT_FLOAT16 10
DTypeCode._DT_FLOAT32 11
DTypeCode._DT_FLOAT64 12
"""
