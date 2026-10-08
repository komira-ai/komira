# =============================================================================
# test_plan_field_numbers_expr.mojo
# =============================================================================
#
# THE FIELD-NUMBER CENSUS of `komira.plan.v1`, part 2 of 3: the expression
# messages (WireColRef to WireWindowFn, WireExpr and its 25 arms, and
# WireAggExpr). How a message is pinned, and why, is in the header of
# test_plan_field_numbers_scan.mojo (part 1); the same helpers are restated
# here, since a welded test is one source file.
#
# WireExpr's arms are each written as an empty sub-message under the arm's
# number and must decode as that arm BY NAME, as the arm at that position of
# the oneof, and re-encode under the same tag bytes. The arm messages
# themselves are pinned field by field above them.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_proto, encode_proto
from komira_plan_proto.plan import (
    WireAggExpr,
    WireAggFn,
    WireAlias,
    WireBinaryOp,
    WireCast,
    WireColIdx,
    WireColRef,
    WireCorrelatedSubquery,
    WireExpr,
    WireExtract,
    WireFrame,
    WireInList,
    WireJsonExtract,
    WireMapGet,
    WireMathFn,
    WireMathFn2,
    WireRegexp,
    WireStringFn,
    WireStringFnN,
    WireStringOp,
    WireStructField,
    WireStructFieldIdx,
    WireSubstring,
    WireUdfCall,
    WireUnaryOp,
    WireWhen,
    WireWhenCase,
    WireWindowFn,
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

def _one_hot_row(message: String) raises -> List[String]:
    """The single bools of `message`, from its `ONE_HOT` row."""
    for raw in String(ONE_HOT).split("\n"):
        var w = _names(String(raw))
        if len(w) > 0 and w[0] == message:
            var out = List[String]()
            for i in range(1, len(w)):
                out.append(w[i])
            return out^
    raise Error("no ONE_HOT row for " + message)



def _first_tag(b: List[UInt8]) -> String:
    """The tag bytes of the first record of `b`."""
    var out = String("")
    for i in range(len(b)):
        out += hex(Int(b[i])) + " "
        if (b[i] & 0x80) == 0:
            break
    return out


# ---- payloads ---------------------------------------------------------------------


def _expr(mut L: _Ledger, index: Int) raises -> List[UInt8]:
    """A WireExpr holding `col_idx { index }`: a distinct child per field."""
    var c = List[UInt8]()
    _i(L, c, "WireColIdx.index", Int64(index))
    var b = List[UInt8]()
    _m(L, b, "WireExpr.col_idx", c)
    return b^


def _idx(e: WireExpr) raises -> Int:
    return Int(e.col_idx.value().index)


def _raw_plan(hash: Int) -> List[UInt8]:
    """A WirePlan holding `cse_ref { canonical_hash }` (18 cse_ref,
    WireCseRefNode 1; pinned in test_plan_field_numbers_plan.mojo)."""
    var c = List[UInt8]()
    _raw_u(c, 1, UInt64(hash))
    var b = List[UInt8]()
    _raw_m(b, 18, c)
    return b^


def _raw_scalar(v: Int) -> List[UInt8]:
    """A WireScalar holding `int_val` (2; pinned in
    test_plan_field_numbers_scan.mojo)."""
    var b = List[UInt8]()
    _raw_u(b, 2, UInt64(v))
    return b^


# ---- column references -----------------------------------------------------------


def test_col_ref(mut L: _Ledger) raises:
    var b = List[UInt8]()
    _s(L, b, "WireColRef.name", "amount")
    _u(L, b, "WireColRef.side", 3)
    var m = decode_proto[WireColRef](b.copy())
    assert_equal(m.name, "amount", "WireColRef: m.name")
    assert_equal(m.side.number(), 3, "WireColRef: m.side.number()")
    _same(encode_proto(m), b, "WireColRef")


def test_col_idx(mut L: _Ledger) raises:
    var b = List[UInt8]()
    _i(L, b, "WireColIdx.index", 41)
    assert_equal(b[0], UInt8(0x08), "WireColIdx field 1, varint: tag byte 0x08")
    var m = decode_proto[WireColIdx](b.copy())
    assert_equal(m.index, Int64(41), "WireColIdx: m.index")
    _same(encode_proto(m), b, "WireColIdx")
    var neg = List[UInt8]()
    _i(L, neg, "WireColIdx.index", -2)
    assert_equal(len(neg), 1 + 10, "a negative int64 is a 10-byte varint")
    var n = decode_proto[WireColIdx](neg.copy())
    assert_equal(n.index, Int64(-2), "WireColIdx: n.index")
    _same(encode_proto(n), neg, "WireColIdx negative")


# ---- operators ---------------------------------------------------------------------


def test_binary_op(mut L: _Ledger) raises:
    var b = List[UInt8]()
    _u(L, b, "WireBinaryOp.op", 5)
    _m(L, b, "WireBinaryOp.left", _expr(L, 11))
    _m(L, b, "WireBinaryOp.right", _expr(L, 12))
    var m = decode_proto[WireBinaryOp](b.copy())
    assert_equal(m.op.number(), 5, "WireBinaryOp: m.op.number()")
    assert_equal(_idx(m.left[0]), 11, "WireBinaryOp: _idx(m.left[0])")
    assert_equal(_idx(m.right[0]), 12, "WireBinaryOp: _idx(m.right[0])")
    _same(encode_proto(m), b, "WireBinaryOp")


def test_unary_op(mut L: _Ledger) raises:
    var b = List[UInt8]()
    _u(L, b, "WireUnaryOp.op", 3)
    _m(L, b, "WireUnaryOp.child", _expr(L, 13))
    var m = decode_proto[WireUnaryOp](b.copy())
    assert_equal(m.op.number(), 3, "WireUnaryOp: m.op.number()")
    assert_equal(_idx(m.child[0]), 13, "WireUnaryOp: _idx(m.child[0])")
    _same(encode_proto(m), b, "WireUnaryOp")


def test_alias(mut L: _Ledger) raises:
    var b = List[UInt8]()
    _m(L, b, "WireAlias.child", _expr(L, 14))
    _s(L, b, "WireAlias.name", "total")
    var m = decode_proto[WireAlias](b.copy())
    assert_equal(_idx(m.child[0]), 14, "WireAlias: _idx(m.child[0])")
    assert_equal(m.name, "total", "WireAlias: m.name")
    _same(encode_proto(m), b, "WireAlias")


def test_in_list(mut L: _Ledger) raises:
    var b = List[UInt8]()
    _m(L, b, "WireInList.child", _expr(L, 15))
    _m(L, b, "WireInList.values", _raw_scalar(20))
    _m(L, b, "WireInList.values", _raw_scalar(21))
    var m = decode_proto[WireInList](b.copy())
    assert_equal(_idx(m.child[0]), 15, "WireInList: _idx(m.child[0])")
    assert_equal(len(m.values), 2, "WireInList: len(m.values)")
    assert_equal(m.values[0].int_val, Int64(20), "WireInList: m.values[0].int_val")
    assert_equal(m.values[1].int_val, Int64(21), "WireInList: m.values[1].int_val")
    _same(encode_proto(m), b, "WireInList")


def test_cast(mut L: _Ledger) raises:
    var b = List[UInt8]()
    _m(L, b, "WireCast.child", _expr(L, 16))
    _u(L, b, "WireCast.target_dtype_code", 7)
    _u(L, b, "WireCast.target_arrow_type_id", 9)
    _i(L, b, "WireCast.decimal_precision", 10)
    _i(L, b, "WireCast.decimal_scale", 2)
    _u(L, b, "WireCast.try_cast", 1)
    var m = decode_proto[WireCast](b.copy())
    assert_equal(_idx(m.child[0]), 16, "WireCast: _idx(m.child[0])")
    assert_equal(m.target_dtype_code.number(), 7, "WireCast: m.target_dtype_code.number()")
    assert_equal(m.target_arrow_type_id, UInt32(9), "WireCast: m.target_arrow_type_id")
    assert_equal(m.decimal_precision, Int64(10), "WireCast: m.decimal_precision")
    assert_equal(m.decimal_scale, Int64(2), "WireCast: m.decimal_scale")
    assert_true(m.try_cast, "WireCast: m.try_cast")
    _same(encode_proto(m), b, "WireCast")


def test_correlated_subquery(mut L: _Ledger) raises:
    var b = List[UInt8]()
    _m(L, b, "WireCorrelatedSubquery.inner_plan", _raw_plan(33))
    _s(L, b, "WireCorrelatedSubquery.outer_refs", "o1")
    _s(L, b, "WireCorrelatedSubquery.outer_refs", "o2")
    _u(L, b, "WireCorrelatedSubquery.kind", 2)
    _s(L, b, "WireCorrelatedSubquery.in_lhs_col", "lhs")
    _s(L, b, "WireCorrelatedSubquery.in_rhs_col", "rhs")
    var m = decode_proto[WireCorrelatedSubquery](b.copy())
    assert_equal(m.inner_plan[0].cse_ref.value().canonical_hash, UInt64(33), "WireCorrelatedSubquery: m.inner_plan[0].cse_ref.value().canonical_hash")
    _strs(m.outer_refs, "o1 o2", "WireCorrelatedSubquery.outer_refs")
    assert_equal(m.kind.number(), 2, "WireCorrelatedSubquery: m.kind.number()")
    assert_equal(m.in_lhs_col, "lhs", "WireCorrelatedSubquery: m.in_lhs_col")
    assert_equal(m.in_rhs_col, "rhs", "WireCorrelatedSubquery: m.in_rhs_col")
    _same(encode_proto(m), b, "WireCorrelatedSubquery")


def _when_case(mut L: _Ledger, cond: Int, result: Int) raises -> List[UInt8]:
    var b = List[UInt8]()
    _m(L, b, "WireWhenCase.condition", _expr(L, cond))
    _m(L, b, "WireWhenCase.result", _expr(L, result))
    return b^


def test_when(mut L: _Ledger) raises:
    var c = _when_case(L, 17, 18)
    var mc = decode_proto[WireWhenCase](c.copy())
    assert_equal(_idx(mc.condition[0]), 17, "WireWhenCase: _idx(mc.condition[0])")
    assert_equal(_idx(mc.result[0]), 18, "WireWhenCase: _idx(mc.result[0])")
    _same(encode_proto(mc), c, "WireWhenCase")

    var b = List[UInt8]()
    _m(L, b, "WireWhen.cases", _when_case(L, 19, 20))
    _m(L, b, "WireWhen.cases", _when_case(L, 21, 22))
    _m(L, b, "WireWhen.default_expr", _expr(L, 23))
    var m = decode_proto[WireWhen](b.copy())
    assert_equal(len(m.cases), 2, "WireWhen: len(m.cases)")
    assert_equal(_idx(m.cases[0].condition[0]), 19, "WireWhen: _idx(m.cases[0].condition[0])")
    assert_equal(_idx(m.cases[1].result[0]), 22, "WireWhen: _idx(m.cases[1].result[0])")
    assert_equal(_idx(m.default_expr[0]), 23, "WireWhen: _idx(m.default_expr[0])")
    _same(encode_proto(m), b, "WireWhen")


# ---- functions -----------------------------------------------------------------------


def test_functions_of_one_child(mut L: _Ledger) raises:
    """WireAggFn, WireExtract, WireMathFn and WireStringFn: 1 op (or unit),
    2 child."""
    var b = List[UInt8]()
    _u(L, b, "WireAggFn.op", 4)
    _m(L, b, "WireAggFn.child", _expr(L, 24))
    var a = decode_proto[WireAggFn](b.copy())
    assert_equal(a.op.number(), 4, "WireAggFn: a.op.number()")
    assert_equal(_idx(a.child[0]), 24, "WireAggFn: _idx(a.child[0])")
    _same(encode_proto(a), b, "WireAggFn")

    var x = List[UInt8]()
    _u(L, x, "WireExtract.unit", 6)
    _m(L, x, "WireExtract.child", _expr(L, 25))
    var e = decode_proto[WireExtract](x.copy())
    assert_equal(e.unit.number(), 6, "WireExtract: e.unit.number()")
    assert_equal(_idx(e.child[0]), 25, "WireExtract: _idx(e.child[0])")
    _same(encode_proto(e), x, "WireExtract")

    var f = List[UInt8]()
    _u(L, f, "WireMathFn.op", 7)
    _m(L, f, "WireMathFn.child", _expr(L, 26))
    var mf = decode_proto[WireMathFn](f.copy())
    assert_equal(mf.op.number(), 7, "WireMathFn: mf.op.number()")
    assert_equal(_idx(mf.child[0]), 26, "WireMathFn: _idx(mf.child[0])")
    _same(encode_proto(mf), f, "WireMathFn")

    var s = List[UInt8]()
    _u(L, s, "WireStringFn.op", 8)
    _m(L, s, "WireStringFn.child", _expr(L, 29))
    var sf = decode_proto[WireStringFn](s.copy())
    assert_equal(sf.op.number(), 8, "WireStringFn: sf.op.number()")
    assert_equal(_idx(sf.child[0]), 29, "WireStringFn: _idx(sf.child[0])")
    _same(encode_proto(sf), s, "WireStringFn")


def test_math_fn2_and_string_fn_n(mut L: _Ledger) raises:
    var b = List[UInt8]()
    _u(L, b, "WireMathFn2.op", 2)
    _m(L, b, "WireMathFn2.left", _expr(L, 27))
    _m(L, b, "WireMathFn2.right", _expr(L, 28))
    var m = decode_proto[WireMathFn2](b.copy())
    assert_equal(m.op.number(), 2, "WireMathFn2: m.op.number()")
    assert_equal(_idx(m.left[0]), 27, "WireMathFn2: _idx(m.left[0])")
    assert_equal(_idx(m.right[0]), 28, "WireMathFn2: _idx(m.right[0])")
    _same(encode_proto(m), b, "WireMathFn2")

    var n = List[UInt8]()
    _u(L, n, "WireStringFnN.op", 9)
    _m(L, n, "WireStringFnN.args", _expr(L, 30))
    _m(L, n, "WireStringFnN.args", _expr(L, 31))
    var s = decode_proto[WireStringFnN](n.copy())
    assert_equal(s.op.number(), 9, "WireStringFnN: s.op.number()")
    assert_equal(len(s.args), 2, "WireStringFnN: len(s.args)")
    assert_equal(_idx(s.args[0]), 30, "WireStringFnN: _idx(s.args[0])")
    assert_equal(_idx(s.args[1]), 31, "WireStringFnN: _idx(s.args[1])")
    _same(encode_proto(s), n, "WireStringFnN")


def test_udf_call(mut L: _Ledger) raises:
    var b = List[UInt8]()
    _s(L, b, "WireUdfCall.name", "my_fn")
    _u(L, b, "WireUdfCall.in_arrow_type_id", 13)
    _u(L, b, "WireUdfCall.out_arrow_type_id", 14)
    _m(L, b, "WireUdfCall.child", _expr(L, 32))
    var m = decode_proto[WireUdfCall](b.copy())
    assert_equal(m.name, "my_fn", "WireUdfCall: m.name")
    assert_equal(m.in_arrow_type_id, UInt32(13), "WireUdfCall: m.in_arrow_type_id")
    assert_equal(m.out_arrow_type_id, UInt32(14), "WireUdfCall: m.out_arrow_type_id")
    assert_equal(_idx(m.child[0]), 32, "WireUdfCall: _idx(m.child[0])")
    _same(encode_proto(m), b, "WireUdfCall")


def test_substring_and_string_op(mut L: _Ledger) raises:
    var b = List[UInt8]()
    _m(L, b, "WireSubstring.child", _expr(L, 34))
    _i(L, b, "WireSubstring.start", 3)
    _i(L, b, "WireSubstring.length", 4)
    var m = decode_proto[WireSubstring](b.copy())
    assert_equal(_idx(m.child[0]), 34, "WireSubstring: _idx(m.child[0])")
    assert_equal(m.start, Int64(3), "WireSubstring: m.start")
    assert_equal(m.length, Int64(4), "WireSubstring: m.length")
    _same(encode_proto(m), b, "WireSubstring")

    var s = List[UInt8]()
    _u(L, s, "WireStringOp.op", 2)
    _m(L, s, "WireStringOp.child", _expr(L, 35))
    _s(L, s, "WireStringOp.pattern", "%x%")
    var o = decode_proto[WireStringOp](s.copy())
    assert_equal(o.op.number(), 2, "WireStringOp: o.op.number()")
    assert_equal(_idx(o.child[0]), 35, "WireStringOp: _idx(o.child[0])")
    assert_equal(o.pattern, "%x%", "WireStringOp: o.pattern")
    _same(encode_proto(o), s, "WireStringOp")


def test_regexp(mut L: _Ledger) raises:
    var b = List[UInt8]()
    _u(L, b, "WireRegexp.op", 3)
    _m(L, b, "WireRegexp.child", _expr(L, 36))
    _s(L, b, "WireRegexp.pattern", "a+")
    _s(L, b, "WireRegexp.replacement", "b")
    _s(L, b, "WireRegexp.flags", "i")
    _i(L, b, "WireRegexp.group", 2)
    _s(L, b, "WireRegexp.group_name", "g")
    var m = decode_proto[WireRegexp](b.copy())
    assert_equal(m.op.number(), 3, "WireRegexp: m.op.number()")
    assert_equal(_idx(m.child[0]), 36, "WireRegexp: _idx(m.child[0])")
    assert_equal(m.pattern, "a+", "WireRegexp: m.pattern")
    assert_equal(m.replacement, "b", "WireRegexp: m.replacement")
    assert_equal(m.flags, "i", "WireRegexp: m.flags")
    assert_equal(m.group, Int64(2), "WireRegexp: m.group")
    assert_equal(m.group_name, "g", "WireRegexp: m.group_name")
    _same(encode_proto(m), b, "WireRegexp")


# ---- nested access ---------------------------------------------------------------------


def test_struct_and_map_access(mut L: _Ledger) raises:
    var b = List[UInt8]()
    _m(L, b, "WireStructField.parent", _expr(L, 37))
    _s(L, b, "WireStructField.field_name", "f1")
    var f = decode_proto[WireStructField](b.copy())
    assert_equal(_idx(f.parent[0]), 37, "WireStructField: _idx(f.parent[0])")
    assert_equal(f.field_name, "f1", "WireStructField: f.field_name")
    _same(encode_proto(f), b, "WireStructField")

    var i = List[UInt8]()
    _m(L, i, "WireStructFieldIdx.parent", _expr(L, 38))
    _i(L, i, "WireStructFieldIdx.field_idx", 4)
    var fi = decode_proto[WireStructFieldIdx](i.copy())
    assert_equal(_idx(fi.parent[0]), 38, "WireStructFieldIdx: _idx(fi.parent[0])")
    assert_equal(fi.field_idx, Int64(4), "WireStructFieldIdx: fi.field_idx")
    _same(encode_proto(fi), i, "WireStructFieldIdx")

    var g = List[UInt8]()
    _m(L, g, "WireMapGet.parent", _expr(L, 39))
    _m(L, g, "WireMapGet.key", _expr(L, 40))
    var mg = decode_proto[WireMapGet](g.copy())
    assert_equal(_idx(mg.parent[0]), 39, "WireMapGet: _idx(mg.parent[0])")
    assert_equal(_idx(mg.key[0]), 40, "WireMapGet: _idx(mg.key[0])")
    _same(encode_proto(mg), g, "WireMapGet")

    var j = List[UInt8]()
    _m(L, j, "WireJsonExtract.parent", _expr(L, 42))
    _s(L, j, "WireJsonExtract.path_segments", "a")
    _s(L, j, "WireJsonExtract.path_segments", "b")
    _u(L, j, "WireJsonExtract.output_arrow_type_id", 13)
    _u(L, j, "WireJsonExtract.preserve_extension_metadata", 1)
    var je = decode_proto[WireJsonExtract](j.copy())
    assert_equal(_idx(je.parent[0]), 42, "WireJsonExtract: _idx(je.parent[0])")
    _strs(je.path_segments, "a b", "WireJsonExtract.path_segments")
    assert_equal(je.output_arrow_type_id, UInt32(13), "WireJsonExtract: je.output_arrow_type_id")
    assert_true(je.preserve_extension_metadata, "WireJsonExtract: je.preserve_extension_metadata")
    _same(encode_proto(je), j, "WireJsonExtract")


# ---- windows ---------------------------------------------------------------------------


def test_frame_and_window_fn(mut L: _Ledger) raises:
    var f = List[UInt8]()
    _u(L, f, "WireFrame.units", 2)
    _u(L, f, "WireFrame.start_tag", 3)
    _i(L, f, "WireFrame.start_offset", 7)
    _u(L, f, "WireFrame.end_tag", 4)
    _i(L, f, "WireFrame.end_offset", 9)
    var fr = decode_proto[WireFrame](f.copy())
    assert_equal(fr.units.number(), 2, "WireFrame: fr.units.number()")
    assert_equal(fr.start_tag.number(), 3, "WireFrame: fr.start_tag.number()")
    assert_equal(fr.start_offset, Int64(7), "WireFrame: fr.start_offset")
    assert_equal(fr.end_tag.number(), 4, "WireFrame: fr.end_tag.number()")
    assert_equal(fr.end_offset, Int64(9), "WireFrame: fr.end_offset")
    _same(encode_proto(fr), f, "WireFrame")

    var small = List[UInt8]()
    _i(L, small, "WireFrame.start_offset", 6)
    var b = List[UInt8]()
    _u(L, b, "WireWindowFn.func", 5)
    _s(L, b, "WireWindowFn.arg_col", "x")
    _i(L, b, "WireWindowFn.arg_offset", 2)
    _m(L, b, "WireWindowFn.frame", small)
    _s(L, b, "WireWindowFn.partition_by", "p")
    _s(L, b, "WireWindowFn.order_by", "o1")
    _s(L, b, "WireWindowFn.order_by", "o2")
    _u(L, b, "WireWindowFn.descending", 1)
    _u(L, b, "WireWindowFn.descending", 0)
    var w = decode_proto[WireWindowFn](b.copy())
    assert_equal(w.func.number(), 5, "WireWindowFn: w.func.number()")
    assert_equal(w.arg_col, "x", "WireWindowFn: w.arg_col")
    assert_equal(w.arg_offset, Int64(2), "WireWindowFn: w.arg_offset")
    assert_equal(w.frame.value().start_offset, Int64(6), "WireWindowFn: w.frame.value().start_offset")
    _strs(w.partition_by, "p", "WireWindowFn.partition_by")
    _strs(w.order_by, "o1 o2", "WireWindowFn.order_by")
    assert_equal(len(w.descending), 2, "WireWindowFn: len(w.descending)")
    assert_true(w.descending[0] and not w.descending[1], "WireWindowFn: w.descending[0] and not w.descending[1]")
    _same(encode_proto(w), b, "WireWindowFn")


# ---- the expression ------------------------------------------------------------------


def _arm_of(e: WireExpr) -> String:
    """The name of every arm `e` holds, comma-separated."""
    var out = List[String]()
    if e.col_ref:
        out.append("col_ref")
    if e.col_idx:
        out.append("col_idx")
    if e.literal:
        out.append("literal")
    if len(e.binary_op) > 0:
        out.append("binary_op")
    if len(e.unary_op) > 0:
        out.append("unary_op")
    if len(e.alias_) > 0:
        out.append("alias")
    if len(e.in_list) > 0:
        out.append("in_list")
    if len(e.cast) > 0:
        out.append("cast")
    if len(e.correlated_subquery) > 0:
        out.append("correlated_subquery")
    if len(e.when) > 0:
        out.append("when")
    if len(e.agg_fn) > 0:
        out.append("agg_fn")
    if len(e.extract) > 0:
        out.append("extract")
    if len(e.math_fn) > 0:
        out.append("math_fn")
    if len(e.math_fn2) > 0:
        out.append("math_fn2")
    if len(e.substring) > 0:
        out.append("substring")
    if len(e.string_op) > 0:
        out.append("string_op")
    if len(e.regexp) > 0:
        out.append("regexp")
    if len(e.struct_field) > 0:
        out.append("struct_field")
    if len(e.struct_field_idx) > 0:
        out.append("struct_field_idx")
    if len(e.map_get) > 0:
        out.append("map_get")
    if len(e.json_extract) > 0:
        out.append("json_extract")
    if e.window_fn:
        out.append("window_fn")
    if len(e.string_fn) > 0:
        out.append("string_fn")
    if len(e.string_fn_n) > 0:
        out.append("string_fn_n")
    if len(e.udf_call) > 0:
        out.append("udf_call")
    var joined = String("")
    for i in range(len(out)):
        joined += (String(",") if i > 0 else String("")) + out[i]
    return joined


def test_expr_arms(mut L: _Ledger) raises:
    """oneof node { 2 col_ref .. 26 udf_call } (1 is reserved): each arm,
    written under its ledger number, decodes as that arm by name."""
    var arms = _names(
        "col_ref col_idx literal binary_op unary_op alias in_list cast"
        + " correlated_subquery when agg_fn extract math_fn math_fn2 substring"
        + " string_op regexp struct_field struct_field_idx map_get json_extract"
        + " window_fn string_fn string_fn_n udf_call"
    )
    for k in range(len(arms)):
        var q = "WireExpr." + arms[k]
        var b = List[UInt8]()
        _m(L, b, q, List[UInt8]())
        var e = decode_proto[WireExpr](b.copy())
        assert_equal(_arm_of(e), arms[k], q + ": the arm the bytes decode as")
        assert_equal(e._oneof0_case, k + 1, q + ": its position in the oneof")
        assert_equal(_first_tag(encode_proto(e)), _first_tag(b), q + ": re-encoded tag")
    var c = _expr(L, 77)
    var e = decode_proto[WireExpr](c.copy())
    assert_equal(_idx(e), 77, "WireExpr: col_idx.index")
    _same(encode_proto(e), c, "WireExpr.col_idx with a child")


def test_agg_expr(mut L: _Ledger) raises:
    var b = List[UInt8]()
    _u(L, b, "WireAggExpr.func", 6)
    _m(L, b, "WireAggExpr.child0", _expr(L, 50))
    _m(L, b, "WireAggExpr.child1", _expr(L, 51))
    _m(L, b, "WireAggExpr.child2", _expr(L, 52))
    _m(L, b, "WireAggExpr.child3", _expr(L, 53))
    _s(L, b, "WireAggExpr.alias_name", "agg")
    var m = decode_proto[WireAggExpr](b.copy())
    assert_equal(m.func.number(), 6, "WireAggExpr: m.func.number()")
    assert_equal(_idx(m.child0[0]), 50, "WireAggExpr: _idx(m.child0[0])")
    assert_equal(_idx(m.child1[0]), 51, "WireAggExpr: _idx(m.child1[0])")
    assert_equal(_idx(m.child2[0]), 52, "WireAggExpr: _idx(m.child2[0])")
    assert_equal(_idx(m.child3[0]), 53, "WireAggExpr: _idx(m.child3[0])")
    assert_equal(m.alias_name, "agg", "WireAggExpr: m.alias_name")
    _same(encode_proto(m), b, "WireAggExpr")
    var bools = _one_hot_row("WireAggExpr")
    for k in range(len(bools)):
        var q = "WireAggExpr." + bools[k]
        var h = List[UInt8]()
        _u(L, h, q, 1)
        var g = decode_proto[WireAggExpr](h.copy())
        var got = List[Bool]()
        got.append(g.has_child0)
        got.append(g.has_child1)
        got.append(g.has_child2)
        got.append(g.has_child3)
        got.append(g.has_alias_name)
        _one_hot(got, bools, k, q)
        _same(encode_proto(g), h, q)


def main() raises:
    print("test_plan_field_numbers_expr: the expression census")
    var L = _Ledger(LEDGER)
    test_col_ref(L)
    test_col_idx(L)
    test_binary_op(L)
    test_unary_op(L)
    test_alias(L)
    test_in_list(L)
    test_cast(L)
    test_correlated_subquery(L)
    test_when(L)
    test_functions_of_one_child(L)
    test_math_fn2_and_string_fn_n(L)
    test_udf_call(L)
    test_substring_and_string_op(L)
    test_regexp(L)
    test_struct_and_map_access(L)
    test_frame_and_window_fn(L)
    test_expr_arms(L)
    test_agg_expr(L)
    L.check_all_hit()
    print("ALL komira.plan.v1 EXPRESSION FIELD NUMBERS PINNED:", len(L.names), "fields")


# ---- THE LEDGER: every field of the 28 expression messages, numbers written by hand --------
# Change a number here only with the .proto, and only one that never
# shipped: a shipped number is permanent.

comptime LEDGER = """
WireColRef.name 1
WireColRef.side 2
WireColIdx.index 1
WireBinaryOp.op 1
WireBinaryOp.left 2
WireBinaryOp.right 3
WireUnaryOp.op 1
WireUnaryOp.child 2
WireAlias.child 1
WireAlias.name 2
WireInList.child 1
WireInList.values 2
WireCast.child 1
WireCast.target_dtype_code 2
WireCast.target_arrow_type_id 3
WireCast.decimal_precision 4
WireCast.decimal_scale 5
WireCast.try_cast 6
WireCorrelatedSubquery.inner_plan 1
WireCorrelatedSubquery.outer_refs 2
WireCorrelatedSubquery.kind 3
WireCorrelatedSubquery.in_lhs_col 4
WireCorrelatedSubquery.in_rhs_col 5
WireWhenCase.condition 1
WireWhenCase.result 2
WireWhen.cases 1
WireWhen.default_expr 2
WireAggFn.op 1
WireAggFn.child 2
WireExtract.unit 1
WireExtract.child 2
WireMathFn.op 1
WireMathFn.child 2
WireMathFn2.op 1
WireMathFn2.left 2
WireMathFn2.right 3
WireStringFn.op 1
WireStringFn.child 2
WireStringFnN.op 1
WireStringFnN.args 2
WireUdfCall.name 1
WireUdfCall.in_arrow_type_id 2
WireUdfCall.out_arrow_type_id 3
WireUdfCall.child 4
WireSubstring.child 1
WireSubstring.start 2
WireSubstring.length 3
WireStringOp.op 1
WireStringOp.child 2
WireStringOp.pattern 3
WireRegexp.op 1
WireRegexp.child 2
WireRegexp.pattern 3
WireRegexp.replacement 4
WireRegexp.flags 5
WireRegexp.group 6
WireRegexp.group_name 7
WireStructField.parent 1
WireStructField.field_name 2
WireStructFieldIdx.parent 1
WireStructFieldIdx.field_idx 2
WireMapGet.parent 1
WireMapGet.key 2
WireJsonExtract.parent 1
WireJsonExtract.path_segments 2
WireJsonExtract.output_arrow_type_id 3
WireJsonExtract.preserve_extension_metadata 4
WireFrame.units 1
WireFrame.start_tag 2
WireFrame.start_offset 3
WireFrame.end_tag 4
WireFrame.end_offset 5
WireWindowFn.func 1
WireWindowFn.arg_col 2
WireWindowFn.arg_offset 3
WireWindowFn.frame 4
WireWindowFn.partition_by 5
WireWindowFn.order_by 6
WireWindowFn.descending 7
WireExpr.col_ref 2
WireExpr.col_idx 3
WireExpr.literal 4
WireExpr.binary_op 5
WireExpr.unary_op 6
WireExpr.alias 7
WireExpr.in_list 8
WireExpr.cast 9
WireExpr.correlated_subquery 10
WireExpr.when 11
WireExpr.agg_fn 12
WireExpr.extract 13
WireExpr.math_fn 14
WireExpr.math_fn2 15
WireExpr.substring 16
WireExpr.string_op 17
WireExpr.regexp 18
WireExpr.struct_field 19
WireExpr.struct_field_idx 20
WireExpr.map_get 21
WireExpr.json_extract 22
WireExpr.window_fn 23
WireExpr.string_fn 24
WireExpr.string_fn_n 25
WireExpr.udf_call 26
WireAggExpr.func 1
WireAggExpr.has_child0 2
WireAggExpr.child0 3
WireAggExpr.has_child1 4
WireAggExpr.child1 5
WireAggExpr.has_child2 6
WireAggExpr.child2 7
WireAggExpr.has_child3 8
WireAggExpr.child3 9
WireAggExpr.has_alias_name 10
WireAggExpr.alias_name 11
"""


# ---- THE ONE-HOT ROWS: each message with two or more single (non-repeated)
# bools, and those bools in the order its test reads them. Two true bools that
# swap numbers look the same in one stream, so each is written alone.
# test_plan_census_complete.mojo requires these rows to be exactly the
# messages and bools protoc declares.

comptime ONE_HOT = """
WireAggExpr has_child0 has_child1 has_child2 has_child3 has_alias_name
"""
