# =============================================================================
# test_plan_field_numbers_plan.mojo
# =============================================================================
#
# THE FIELD-NUMBER CENSUS of `komira.plan.v1`, part 3 of 3: the plan nodes,
# WirePlan and its 16 arms, the write target and the envelope. How a message
# is pinned, and why, is in the header of test_plan_field_numbers_scan.mojo
# (part 1); the same helpers are restated here, since a welded test is one
# source file.
#
# WirePlan's arms are each written as an empty sub-message under the arm's
# number and must decode as that arm BY NAME, as the arm at that position of
# the oneof, and re-encode under the same tag bytes. The node messages
# themselves are pinned field by field above them.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_proto, encode_proto
from komira_plan_proto.plan import (
    WireAggregateNode,
    WireAsofJoinNode,
    WireAsofTolerance,
    WireCastToVarcharNode,
    WireCseRefNode,
    WireDistinctNode,
    WireFilterNode,
    WireJoinNode,
    WireLimitNode,
    WirePartitionByNode,
    WirePartitionExpr,
    WirePartitionTopNNode,
    WirePlan,
    WirePlanEnvelope,
    WireProjectNode,
    WireSortNode,
    WireTopNNode,
    WireUnionNode,
    WireViewRefNode,
    WireWriteTarget,
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


def _plan(mut L: _Ledger, hash: Int) raises -> List[UInt8]:
    """A WirePlan holding `cse_ref { canonical_hash }`: a distinct child per
    field."""
    var c = List[UInt8]()
    _u(L, c, "WireCseRefNode.canonical_hash", UInt64(hash))
    var b = List[UInt8]()
    _m(L, b, "WirePlan.cse_ref", c)
    return b^


def _hash(p: WirePlan) raises -> Int:
    return Int(p.cse_ref.value().canonical_hash)


# Payloads whose numbers are pinned in the other two files, written raw.


def _raw_one(field: Int, v: Int) -> List[UInt8]:
    """A message holding one varint record."""
    var b = List[UInt8]()
    _raw_u(b, field, UInt64(v))
    return b^


def _raw_named(field: Int, s: String) -> List[UInt8]:
    """A message holding one string record."""
    var b = List[UInt8]()
    _raw_s(b, field, s)
    return b^


def _raw_expr(index: Int) -> List[UInt8]:
    """WireExpr { 3 col_idx { 1 index } }."""
    var b = List[UInt8]()
    _raw_m(b, 3, _raw_one(1, index))
    return b^


def _raw_udf(name: String) -> List[UInt8]:
    """WireUdf { 2 name }."""
    return _raw_named(2, name)


# ---- unary nodes ------------------------------------------------------------------


def test_filter_node(mut L: _Ledger) raises:
    var b = List[UInt8]()
    _m(L, b, "WireFilterNode.predicate", _raw_expr(5))
    _m(L, b, "WireFilterNode.child", _plan(L, 6))
    _u(L, b, "WireFilterNode.has_udf", 1)
    _m(L, b, "WireFilterNode.udf", _raw_udf("u1"))
    var m = decode_proto[WireFilterNode](b.copy())
    assert_equal(m.predicate[0].col_idx.value().index, Int64(5), "WireFilterNode: m.predicate[0].col_idx.value().index")
    assert_equal(_hash(m.child[0]), 6, "WireFilterNode: _hash(m.child[0])")
    assert_true(m.has_udf, "WireFilterNode: m.has_udf")
    assert_equal(m.udf.value().name, "u1", "WireFilterNode: m.udf.value().name")
    _same(encode_proto(m), b, "WireFilterNode")


def test_project_node(mut L: _Ledger) raises:
    var b = List[UInt8]()
    _m(L, b, "WireProjectNode.exprs", _raw_expr(7))
    _m(L, b, "WireProjectNode.exprs", _raw_expr(8))
    _m(L, b, "WireProjectNode.child", _plan(L, 9))
    _m(L, b, "WireProjectNode.udf", _raw_udf("u2"))
    var m = decode_proto[WireProjectNode](b.copy())
    assert_equal(len(m.exprs), 2, "WireProjectNode: len(m.exprs)")
    assert_equal(m.exprs[0].col_idx.value().index, Int64(7), "WireProjectNode: m.exprs[0].col_idx.value().index")
    assert_equal(m.exprs[1].col_idx.value().index, Int64(8), "WireProjectNode: m.exprs[1].col_idx.value().index")
    assert_equal(_hash(m.child[0]), 9, "WireProjectNode: _hash(m.child[0])")
    assert_equal(m.udf.value().name, "u2", "WireProjectNode: m.udf.value().name")
    _same(encode_proto(m), b, "WireProjectNode")
    var bools = _one_hot_row("WireProjectNode")
    for k in range(len(bools)):
        var q = "WireProjectNode." + bools[k]
        var h = List[UInt8]()
        _u(L, h, q, 1)
        var g = decode_proto[WireProjectNode](h.copy())
        var got = List[Bool]()
        got.append(g.is_cse_introduced)
        got.append(g.has_udf)
        _one_hot(got, bools, k, q)
        _same(encode_proto(g), h, q)


def test_aggregate_node(mut L: _Ledger) raises:
    var b = List[UInt8]()
    _m(L, b, "WireAggregateNode.group_by", _raw_expr(10))
    _m(L, b, "WireAggregateNode.agg_exprs", _raw_named(11, "s"))  # WireAggExpr 11 alias_name
    _m(L, b, "WireAggregateNode.agg_exprs", _raw_named(11, "c"))
    _m(L, b, "WireAggregateNode.child", _plan(L, 11))
    _i(L, b, "WireAggregateNode.estimated_groups", 500)
    _m(L, b, "WireAggregateNode.udf", _raw_udf("u3"))
    var m = decode_proto[WireAggregateNode](b.copy())
    assert_equal(m.group_by[0].col_idx.value().index, Int64(10), "WireAggregateNode: m.group_by[0].col_idx.value().index")
    assert_equal(len(m.agg_exprs), 2, "WireAggregateNode: len(m.agg_exprs)")
    assert_equal(m.agg_exprs[0].alias_name, "s", "WireAggregateNode: m.agg_exprs[0].alias_name")
    assert_equal(m.agg_exprs[1].alias_name, "c", "WireAggregateNode: m.agg_exprs[1].alias_name")
    assert_equal(_hash(m.child[0]), 11, "WireAggregateNode: _hash(m.child[0])")
    assert_equal(m.estimated_groups, Int64(500), "WireAggregateNode: m.estimated_groups")
    assert_equal(m.udf.value().name, "u3", "WireAggregateNode: m.udf.value().name")
    _same(encode_proto(m), b, "WireAggregateNode")
    var bools = _one_hot_row("WireAggregateNode")
    for k in range(len(bools)):
        var q = "WireAggregateNode." + bools[k]
        var h = List[UInt8]()
        _u(L, h, q, 1)
        var g = decode_proto[WireAggregateNode](h.copy())
        var got = List[Bool]()
        got.append(g.has_estimated_groups)
        got.append(g.has_udf)
        _one_hot(got, bools, k, q)
        _same(encode_proto(g), h, q)


def test_sort_limit_distinct_topn(mut L: _Ledger) raises:
    var s = List[UInt8]()
    _s(L, s, "WireSortNode.keys", "k1")
    _s(L, s, "WireSortNode.keys", "k2")
    _u(L, s, "WireSortNode.descending", 1)
    _u(L, s, "WireSortNode.descending", 0)
    _u(L, s, "WireSortNode.nulls_first", 0)
    _u(L, s, "WireSortNode.nulls_first", 1)
    _u(L, s, "WireSortNode.nulls_first", 1)
    _m(L, s, "WireSortNode.child", _plan(L, 15))
    var sn = decode_proto[WireSortNode](s.copy())
    _strs(sn.keys, "k1 k2", "WireSortNode.keys")
    assert_equal(len(sn.descending), 2, "descending is [true, false]")
    assert_true(sn.descending[0] and not sn.descending[1], "WireSortNode: sn.descending[0] and not sn.descending[1]")
    assert_equal(len(sn.nulls_first), 3, "nulls_first is [false, true, true]")
    assert_true(not sn.nulls_first[0] and sn.nulls_first[1] and sn.nulls_first[2], "WireSortNode: not sn.nulls_first[0] and sn.nulls_first[1] and sn.nulls_first[2]")
    assert_equal(_hash(sn.child[0]), 15, "WireSortNode: _hash(sn.child[0])")
    _same(encode_proto(sn), s, "WireSortNode")

    var l = List[UInt8]()
    _i(L, l, "WireLimitNode.n", 10)
    _i(L, l, "WireLimitNode.offset", 20)
    _m(L, l, "WireLimitNode.child", _plan(L, 16))
    var ln = decode_proto[WireLimitNode](l.copy())
    assert_equal(ln.n, Int64(10), "WireLimitNode: ln.n")
    assert_equal(ln.offset, Int64(20), "WireLimitNode: ln.offset")
    assert_equal(_hash(ln.child[0]), 16, "WireLimitNode: _hash(ln.child[0])")
    _same(encode_proto(ln), l, "WireLimitNode")

    var d = List[UInt8]()
    _s(L, d, "WireDistinctNode.columns", "d")
    _m(L, d, "WireDistinctNode.child", _plan(L, 17))
    _i(L, d, "WireDistinctNode.estimated_groups", 40)
    var dn = decode_proto[WireDistinctNode](d.copy())
    _strs(dn.columns, "d", "WireDistinctNode.columns")
    assert_equal(_hash(dn.child[0]), 17, "WireDistinctNode: _hash(dn.child[0])")
    assert_equal(dn.estimated_groups, Int64(40), "WireDistinctNode: dn.estimated_groups")
    _same(encode_proto(dn), d, "WireDistinctNode")
    var bools = _one_hot_row("WireDistinctNode")
    for k in range(len(bools)):
        var q = "WireDistinctNode." + bools[k]
        var h = List[UInt8]()
        _u(L, h, q, 1)
        var g = decode_proto[WireDistinctNode](h.copy())
        var got = List[Bool]()
        got.append(g.has_columns)
        got.append(g.has_estimated_groups)
        _one_hot(got, bools, k, q)
        _same(encode_proto(g), h, q)

    var t = List[UInt8]()
    _s(L, t, "WireTopNNode.keys", "t")
    _u(L, t, "WireTopNNode.descending", 1)
    _u(L, t, "WireTopNNode.descending", 0)
    _u(L, t, "WireTopNNode.nulls_first", 0)
    _u(L, t, "WireTopNNode.nulls_first", 1)
    _u(L, t, "WireTopNNode.nulls_first", 1)
    _i(L, t, "WireTopNNode.n", 5)
    _m(L, t, "WireTopNNode.child", _plan(L, 18))
    var tn = decode_proto[WireTopNNode](t.copy())
    _strs(tn.keys, "t", "WireTopNNode.keys")
    assert_equal(len(tn.descending), 2, "descending is [true, false]")
    assert_true(tn.descending[0] and not tn.descending[1], "WireTopNNode: tn.descending[0] and not tn.descending[1]")
    assert_equal(len(tn.nulls_first), 3, "nulls_first is [false, true, true]")
    assert_equal(tn.n, Int64(5), "WireTopNNode: tn.n")
    assert_equal(_hash(tn.child[0]), 18, "WireTopNNode: _hash(tn.child[0])")
    _same(encode_proto(tn), t, "WireTopNNode")


# ---- joins and unions ----------------------------------------------------------------


def test_join_and_union(mut L: _Ledger) raises:
    var b = List[UInt8]()
    _m(L, b, "WireJoinNode.left", _plan(L, 12))
    _m(L, b, "WireJoinNode.right", _plan(L, 13))
    _s(L, b, "WireJoinNode.left_on", "lk")
    _s(L, b, "WireJoinNode.right_on", "rk1")
    _s(L, b, "WireJoinNode.right_on", "rk2")
    _u(L, b, "WireJoinNode.join_type", 3)
    _u(L, b, "WireJoinNode.algo_hint", 2)
    _u(L, b, "WireJoinNode.has_residual", 1)
    _m(L, b, "WireJoinNode.residual", _raw_expr(14))
    var j = decode_proto[WireJoinNode](b.copy())
    assert_equal(_hash(j.left[0]), 12, "WireJoinNode: _hash(j.left[0])")
    assert_equal(_hash(j.right[0]), 13, "WireJoinNode: _hash(j.right[0])")
    _strs(j.left_on, "lk", "WireJoinNode.left_on")
    _strs(j.right_on, "rk1 rk2", "WireJoinNode.right_on")
    assert_equal(j.join_type.number(), 3, "WireJoinNode: j.join_type.number()")
    assert_equal(j.algo_hint.number(), 2, "WireJoinNode: j.algo_hint.number()")
    assert_true(j.has_residual, "WireJoinNode: j.has_residual")
    assert_equal(j.residual[0].col_idx.value().index, Int64(14), "WireJoinNode: j.residual[0].col_idx.value().index")
    _same(encode_proto(j), b, "WireJoinNode")

    var u = List[UInt8]()
    _m(L, u, "WireUnionNode.children", _plan(L, 19))
    _m(L, u, "WireUnionNode.children", _plan(L, 20))
    var un = decode_proto[WireUnionNode](u.copy())
    assert_equal(len(un.children), 2, "WireUnionNode: len(un.children)")
    assert_equal(_hash(un.children[0]), 19, "WireUnionNode: _hash(un.children[0])")
    assert_equal(_hash(un.children[1]), 20, "WireUnionNode: _hash(un.children[1])")
    _same(encode_proto(un), u, "WireUnionNode")


def test_asof_join(mut L: _Ledger) raises:
    var t = List[UInt8]()
    _u(L, t, "WireAsofTolerance.kind", 2)
    _i(L, t, "WireAsofTolerance.int_val", 3)
    _d(L, t, "WireAsofTolerance.float_val", 0x3FD0000000000000)  # 0.25
    var tol = decode_proto[WireAsofTolerance](t.copy())
    assert_equal(tol.kind.number(), 2, "WireAsofTolerance: tol.kind.number()")
    assert_equal(tol.int_val, Int64(3), "WireAsofTolerance: tol.int_val")
    assert_equal(tol.float_val, Float64(0.25), "WireAsofTolerance: tol.float_val")
    _same(encode_proto(tol), t, "WireAsofTolerance")

    var small = List[UInt8]()
    _i(L, small, "WireAsofTolerance.int_val", 7)
    var b = List[UInt8]()
    _s(L, b, "WireAsofJoinNode.left_keys", "a")
    _s(L, b, "WireAsofJoinNode.right_keys", "b1")
    _s(L, b, "WireAsofJoinNode.right_keys", "b2")
    _s(L, b, "WireAsofJoinNode.left_asof", "lt")
    _s(L, b, "WireAsofJoinNode.right_asof", "rt")
    _u(L, b, "WireAsofJoinNode.strategy", 2)
    _m(L, b, "WireAsofJoinNode.tolerance", small)
    _s(L, b, "WireAsofJoinNode.left_sort_keys", "ls")
    _u(L, b, "WireAsofJoinNode.left_sort_desc", 1)
    _u(L, b, "WireAsofJoinNode.left_sort_desc", 0)
    _s(L, b, "WireAsofJoinNode.right_sort_keys", "rs1")
    _s(L, b, "WireAsofJoinNode.right_sort_keys", "rs2")
    _u(L, b, "WireAsofJoinNode.right_sort_desc", 0)
    _u(L, b, "WireAsofJoinNode.right_sort_desc", 1)
    _u(L, b, "WireAsofJoinNode.right_sort_desc", 1)
    _m(L, b, "WireAsofJoinNode.left", _plan(L, 23))
    _m(L, b, "WireAsofJoinNode.right", _plan(L, 24))
    var m = decode_proto[WireAsofJoinNode](b.copy())
    _strs(m.left_keys, "a", "WireAsofJoinNode.left_keys")
    _strs(m.right_keys, "b1 b2", "WireAsofJoinNode.right_keys")
    assert_equal(m.left_asof, "lt", "WireAsofJoinNode: m.left_asof")
    assert_equal(m.right_asof, "rt", "WireAsofJoinNode: m.right_asof")
    assert_equal(m.strategy.number(), 2, "WireAsofJoinNode: m.strategy.number()")
    assert_equal(m.tolerance.value().int_val, Int64(7), "WireAsofJoinNode: m.tolerance.value().int_val")
    _strs(m.left_sort_keys, "ls", "WireAsofJoinNode.left_sort_keys")
    assert_equal(len(m.left_sort_desc), 2, "left_sort_desc is [true, false]")
    assert_true(m.left_sort_desc[0] and not m.left_sort_desc[1], "WireAsofJoinNode: m.left_sort_desc[0] and not m.left_sort_desc[1]")
    _strs(m.right_sort_keys, "rs1 rs2", "WireAsofJoinNode.right_sort_keys")
    assert_equal(len(m.right_sort_desc), 3, "right_sort_desc is [false, true, true]")
    assert_true(not m.right_sort_desc[0] and m.right_sort_desc[1], "WireAsofJoinNode: not m.right_sort_desc[0] and m.right_sort_desc[1]")
    assert_equal(_hash(m.left[0]), 23, "WireAsofJoinNode: _hash(m.left[0])")
    assert_equal(_hash(m.right[0]), 24, "WireAsofJoinNode: _hash(m.right[0])")
    _same(encode_proto(m), b, "WireAsofJoinNode")


# ---- partitions ------------------------------------------------------------------------


def test_partition_nodes(mut L: _Ledger) raises:
    var e = List[UInt8]()
    _u(L, e, "WirePartitionExpr.func", 4)
    _s(L, e, "WirePartitionExpr.column", "c")
    _i(L, e, "WirePartitionExpr.offset", 2)
    _m(L, e, "WirePartitionExpr.default_value", _raw_one(2, 9))  # WireScalar 2 int_val
    _u(L, e, "WirePartitionExpr.has_default", 1)
    _m(L, e, "WirePartitionExpr.frame", _raw_one(3, 6))  # WireFrame 3 start_offset
    _s(L, e, "WirePartitionExpr.alias_name", "lag1")
    var pe = decode_proto[WirePartitionExpr](e.copy())
    assert_equal(pe.func.number(), 4, "WirePartitionExpr: pe.func.number()")
    assert_equal(pe.column, "c", "WirePartitionExpr: pe.column")
    assert_equal(pe.offset, Int64(2), "WirePartitionExpr: pe.offset")
    assert_equal(pe.default_value.value().int_val, Int64(9), "WirePartitionExpr: pe.default_value.value().int_val")
    assert_true(pe.has_default, "WirePartitionExpr: pe.has_default")
    assert_equal(pe.frame.value().start_offset, Int64(6), "WirePartitionExpr: pe.frame.value().start_offset")
    assert_equal(pe.alias_name, "lag1", "WirePartitionExpr: pe.alias_name")
    _same(encode_proto(pe), e, "WirePartitionExpr")

    var second = List[UInt8]()
    _s(L, second, "WirePartitionExpr.column", "c2")
    var b = List[UInt8]()
    _s(L, b, "WirePartitionByNode.partition_keys", "pk")
    _s(L, b, "WirePartitionByNode.order_keys", "ok1")
    _s(L, b, "WirePartitionByNode.order_keys", "ok2")
    _u(L, b, "WirePartitionByNode.descending", 1)
    _u(L, b, "WirePartitionByNode.descending", 0)
    _m(L, b, "WirePartitionByNode.partition_exprs", e)
    _m(L, b, "WirePartitionByNode.partition_exprs", second)
    _m(L, b, "WirePartitionByNode.child", _plan(L, 21))
    var pb = decode_proto[WirePartitionByNode](b.copy())
    _strs(pb.partition_keys, "pk", "WirePartitionByNode.partition_keys")
    _strs(pb.order_keys, "ok1 ok2", "WirePartitionByNode.order_keys")
    assert_equal(len(pb.descending), 2, "WirePartitionByNode: len(pb.descending)")
    assert_true(pb.descending[0] and not pb.descending[1], "WirePartitionByNode: pb.descending[0] and not pb.descending[1]")
    assert_equal(len(pb.partition_exprs), 2, "WirePartitionByNode: len(pb.partition_exprs)")
    assert_equal(pb.partition_exprs[0].alias_name, "lag1", "WirePartitionByNode: pb.partition_exprs[0].alias_name")
    assert_equal(pb.partition_exprs[1].column, "c2", "WirePartitionByNode: pb.partition_exprs[1].column")
    assert_equal(_hash(pb.child[0]), 21, "WirePartitionByNode: _hash(pb.child[0])")
    _same(encode_proto(pb), b, "WirePartitionByNode")

    var t = List[UInt8]()
    _s(L, t, "WirePartitionTopNNode.partition_keys", "p")
    _s(L, t, "WirePartitionTopNNode.sort_keys", "s1")
    _s(L, t, "WirePartitionTopNNode.sort_keys", "s2")
    _u(L, t, "WirePartitionTopNNode.descending", 0)
    _u(L, t, "WirePartitionTopNNode.descending", 1)
    _u(L, t, "WirePartitionTopNNode.descending", 1)
    _i(L, t, "WirePartitionTopNNode.k", 3)
    _u(L, t, "WirePartitionTopNNode.func", 5)
    _i(L, t, "WirePartitionTopNNode.over_fetch_k", 6)
    _u(L, t, "WirePartitionTopNNode.has_output_rank_col_name", 1)
    _s(L, t, "WirePartitionTopNNode.output_rank_col_name", "rnk")
    _m(L, t, "WirePartitionTopNNode.child", _plan(L, 22))
    var pt = decode_proto[WirePartitionTopNNode](t.copy())
    _strs(pt.partition_keys, "p", "WirePartitionTopNNode.partition_keys")
    _strs(pt.sort_keys, "s1 s2", "WirePartitionTopNNode.sort_keys")
    assert_equal(len(pt.descending), 3, "WirePartitionTopNNode: len(pt.descending)")
    assert_true(not pt.descending[0] and pt.descending[1], "WirePartitionTopNNode: not pt.descending[0] and pt.descending[1]")
    assert_equal(pt.k, Int64(3), "WirePartitionTopNNode: pt.k")
    assert_equal(pt.func.number(), 5, "WirePartitionTopNNode: pt.func.number()")
    assert_equal(pt.over_fetch_k, Int64(6), "WirePartitionTopNNode: pt.over_fetch_k")
    assert_true(pt.has_output_rank_col_name, "WirePartitionTopNNode: pt.has_output_rank_col_name")
    assert_equal(pt.output_rank_col_name, "rnk", "WirePartitionTopNNode: pt.output_rank_col_name")
    assert_equal(_hash(pt.child[0]), 22, "WirePartitionTopNNode: _hash(pt.child[0])")
    _same(encode_proto(pt), t, "WirePartitionTopNNode")


# ---- leaves -------------------------------------------------------------------------------


def test_leaf_nodes(mut L: _Ledger) raises:
    var v = List[UInt8]()
    _s(L, v, "WireViewRefNode.view_name", "v")
    var vr = decode_proto[WireViewRefNode](v.copy())
    assert_equal(vr.view_name, "v", "WireViewRefNode: vr.view_name")
    _same(encode_proto(vr), v, "WireViewRefNode")

    var c = List[UInt8]()
    _u(L, c, "WireCseRefNode.canonical_hash", 0xFEDCBA9876543210)
    var cr = decode_proto[WireCseRefNode](c.copy())
    assert_equal(cr.canonical_hash, UInt64(0xFEDCBA9876543210), "WireCseRefNode: cr.canonical_hash")
    _same(encode_proto(cr), c, "WireCseRefNode")

    var x = List[UInt8]()
    _m(L, x, "WireCastToVarcharNode.child", _plan(L, 25))
    var cv = decode_proto[WireCastToVarcharNode](x.copy())
    assert_equal(_hash(cv.child[0]), 25, "WireCastToVarcharNode: _hash(cv.child[0])")
    _same(encode_proto(cv), x, "WireCastToVarcharNode")


# ---- the plan --------------------------------------------------------------------------


def _arm_of(p: WirePlan) -> String:
    """The name of every arm `p` holds, comma-separated."""
    var out = String("")
    var names = List[String]()
    if len(p.scan) > 0:
        names.append("scan")
    if len(p.filter) > 0:
        names.append("filter")
    if len(p.project) > 0:
        names.append("project")
    if len(p.aggregate) > 0:
        names.append("aggregate")
    if len(p.join) > 0:
        names.append("join")
    if len(p.sort) > 0:
        names.append("sort")
    if len(p.limit) > 0:
        names.append("limit")
    if len(p.distinct) > 0:
        names.append("distinct")
    if len(p.topn) > 0:
        names.append("topn")
    if len(p.union_all) > 0:
        names.append("union_all")
    if len(p.partition_by) > 0:
        names.append("partition_by")
    if len(p.partition_topn) > 0:
        names.append("partition_topn")
    if len(p.asof_join) > 0:
        names.append("asof_join")
    if p.view_ref:
        names.append("view_ref")
    if p.cse_ref:
        names.append("cse_ref")
    if len(p.cast_to_varchar) > 0:
        names.append("cast_to_varchar")
    for i in range(len(names)):
        out += (String(",") if i > 0 else String("")) + names[i]
    return out


def test_plan(mut L: _Ledger) raises:
    """2 output_schema; oneof node { 4 scan .. 19 cast_to_varchar } (1 and 3
    are reserved): each arm, written under its ledger number, decodes as
    that arm by name."""
    var arms = _names(
        "scan filter project aggregate join sort limit distinct topn union_all"
        + " partition_by partition_topn asof_join view_ref cse_ref cast_to_varchar"
    )
    for k in range(len(arms)):
        var q = "WirePlan." + arms[k]
        var b = List[UInt8]()
        _m(L, b, q, List[UInt8]())
        var p = decode_proto[WirePlan](b.copy())
        assert_equal(_arm_of(p), arms[k], q + ": the arm the bytes decode as")
        assert_equal(p._oneof0_case, k + 1, q + ": its position in the oneof")
        assert_equal(_first_tag(encode_proto(p)), _first_tag(b), q + ": re-encoded tag")

    var b = List[UInt8]()
    _m(L, b, "WirePlan.output_schema", _raw_named(2, "os"))  # WireSchema 2 metadata_keys
    var v = List[UInt8]()
    _s(L, v, "WireViewRefNode.view_name", "orders_v")
    _m(L, b, "WirePlan.view_ref", v)
    var p = decode_proto[WirePlan](b.copy())
    assert_equal(p.output_schema.value().metadata_keys[0], "os", "WirePlan: p.output_schema.value().metadata_keys[0]")
    assert_equal(p.view_ref.value().view_name, "orders_v", "WirePlan: p.view_ref.value().view_name")
    _same(encode_proto(p), b, "WirePlan")


def test_write_target_and_envelope(mut L: _Ledger) raises:
    var w = List[UInt8]()
    _s(L, w, "WireWriteTarget.path", "out.parquet")
    _u(L, w, "WireWriteTarget.format", 2)
    _u(L, w, "WireWriteTarget.codec", 3)
    var wt = decode_proto[WireWriteTarget](w.copy())
    assert_equal(wt.path, "out.parquet", "WireWriteTarget: wt.path")
    assert_equal(wt.format.number(), 2, "WireWriteTarget: wt.format.number()")
    assert_equal(wt.codec.number(), 3, "WireWriteTarget: wt.codec.number()")
    _same(encode_proto(wt), w, "WireWriteTarget")

    var b = List[UInt8]()
    _u(L, b, "WirePlanEnvelope.format_version", 3)
    assert_equal(b[0], UInt8(0x08), "WirePlanEnvelope field 1, varint: tag byte 0x08")
    _m(L, b, "WirePlanEnvelope.plan", _plan(L, 26))
    _m(L, b, "WirePlanEnvelope.write_target", w)
    var e = decode_proto[WirePlanEnvelope](b.copy())
    assert_equal(e.format_version, UInt32(3), "WirePlanEnvelope: e.format_version")
    assert_equal(_hash(e.plan.value()), 26, "WirePlanEnvelope: _hash(e.plan.value())")
    assert_equal(e.write_target.value().path, "out.parquet", "WirePlanEnvelope: e.write_target.value().path")
    _same(encode_proto(e), b, "WirePlanEnvelope")


def test_envelope_presence(mut L: _Ledger) raises:
    """Message-field presence, in EXACT bytes (`_same` drops empty records, so
    it cannot see this): an absent `plan` or `write_target` writes no record,
    and a present empty `plan` writes its tag and a zero length."""
    var b = List[UInt8]()
    _u(L, b, "WirePlanEnvelope.format_version", 3)
    var e = decode_proto[WirePlanEnvelope](b.copy())
    assert_true(not Bool(e.plan), "WirePlanEnvelope: plan absent decodes unset")
    assert_true(not Bool(e.write_target), "WirePlanEnvelope: write_target absent decodes unset")
    assert_equal(_hex(encode_proto(e)), _hex(b), "WirePlanEnvelope: an absent message field writes no record")

    var p = b.copy()
    _m(L, p, "WirePlanEnvelope.plan", List[UInt8]())
    var ep = decode_proto[WirePlanEnvelope](p.copy())
    assert_true(Bool(ep.plan), "WirePlanEnvelope: an empty plan record decodes set")
    assert_true(not Bool(ep.write_target), "WirePlanEnvelope: write_target still unset")
    assert_equal(_hex(encode_proto(ep)), _hex(p), "WirePlanEnvelope: a present empty plan writes its tag and 00")


def main() raises:
    print("test_plan_field_numbers_plan: the plan-node and envelope census")
    var L = _Ledger(LEDGER)
    test_filter_node(L)
    test_project_node(L)
    test_aggregate_node(L)
    test_sort_limit_distinct_topn(L)
    test_join_and_union(L)
    test_asof_join(L)
    test_partition_nodes(L)
    test_leaf_nodes(L)
    test_plan(L)
    test_write_target_and_envelope(L)
    test_envelope_presence(L)
    L.check_all_hit()
    print("ALL komira.plan.v1 PLAN FIELD NUMBERS PINNED:", len(L.names), "fields")


# ---- THE LEDGER: every field of the 20 plan messages, numbers written by hand --------
# Change a number here only with the .proto, and only one that never
# shipped: a shipped number is permanent.

comptime LEDGER = """
WireFilterNode.predicate 1
WireFilterNode.child 2
WireFilterNode.has_udf 3
WireFilterNode.udf 4
WireProjectNode.exprs 1
WireProjectNode.child 2
WireProjectNode.is_cse_introduced 3
WireProjectNode.has_udf 4
WireProjectNode.udf 5
WireAggregateNode.group_by 1
WireAggregateNode.agg_exprs 2
WireAggregateNode.child 3
WireAggregateNode.has_estimated_groups 4
WireAggregateNode.estimated_groups 5
WireAggregateNode.has_udf 6
WireAggregateNode.udf 7
WireJoinNode.left 1
WireJoinNode.right 2
WireJoinNode.left_on 3
WireJoinNode.right_on 4
WireJoinNode.join_type 5
WireJoinNode.algo_hint 6
WireJoinNode.has_residual 7
WireJoinNode.residual 8
WireSortNode.keys 1
WireSortNode.descending 2
WireSortNode.nulls_first 3
WireSortNode.child 4
WireLimitNode.n 1
WireLimitNode.offset 2
WireLimitNode.child 3
WireDistinctNode.has_columns 1
WireDistinctNode.columns 2
WireDistinctNode.child 3
WireDistinctNode.has_estimated_groups 4
WireDistinctNode.estimated_groups 5
WireTopNNode.keys 1
WireTopNNode.descending 2
WireTopNNode.nulls_first 3
WireTopNNode.n 4
WireTopNNode.child 5
WireUnionNode.children 1
WirePartitionExpr.func 1
WirePartitionExpr.column 2
WirePartitionExpr.offset 3
WirePartitionExpr.default_value 4
WirePartitionExpr.has_default 5
WirePartitionExpr.frame 6
WirePartitionExpr.alias_name 7
WirePartitionByNode.partition_keys 1
WirePartitionByNode.order_keys 2
WirePartitionByNode.descending 3
WirePartitionByNode.partition_exprs 4
WirePartitionByNode.child 5
WirePartitionTopNNode.partition_keys 1
WirePartitionTopNNode.sort_keys 2
WirePartitionTopNNode.descending 3
WirePartitionTopNNode.k 4
WirePartitionTopNNode.func 5
WirePartitionTopNNode.over_fetch_k 6
WirePartitionTopNNode.has_output_rank_col_name 7
WirePartitionTopNNode.output_rank_col_name 8
WirePartitionTopNNode.child 9
WireAsofTolerance.kind 1
WireAsofTolerance.int_val 2
WireAsofTolerance.float_val 3
WireAsofJoinNode.left_keys 1
WireAsofJoinNode.right_keys 2
WireAsofJoinNode.left_asof 3
WireAsofJoinNode.right_asof 4
WireAsofJoinNode.strategy 5
WireAsofJoinNode.tolerance 6
WireAsofJoinNode.left_sort_keys 7
WireAsofJoinNode.left_sort_desc 8
WireAsofJoinNode.right_sort_keys 9
WireAsofJoinNode.right_sort_desc 10
WireAsofJoinNode.left 11
WireAsofJoinNode.right 12
WireViewRefNode.view_name 1
WireCseRefNode.canonical_hash 1
WireCastToVarcharNode.child 1
WirePlan.output_schema 2
WirePlan.scan 4
WirePlan.filter 5
WirePlan.project 6
WirePlan.aggregate 7
WirePlan.join 8
WirePlan.sort 9
WirePlan.limit 10
WirePlan.distinct 11
WirePlan.topn 12
WirePlan.union_all 13
WirePlan.partition_by 14
WirePlan.partition_topn 15
WirePlan.asof_join 16
WirePlan.view_ref 17
WirePlan.cse_ref 18
WirePlan.cast_to_varchar 19
WireWriteTarget.path 1
WireWriteTarget.format 2
WireWriteTarget.codec 3
WirePlanEnvelope.format_version 1
WirePlanEnvelope.plan 2
WirePlanEnvelope.write_target 3
"""


# ---- THE ONE-HOT ROWS: each message with two or more single (non-repeated)
# bools, and those bools in the order its test reads them. Two true bools that
# swap numbers look the same in one stream, so each is written alone.
# test_plan_census_complete.mojo requires these rows to be exactly the
# messages and bools protoc declares.

comptime ONE_HOT = """
WireProjectNode is_cse_introduced has_udf
WireAggregateNode has_estimated_groups has_udf
WireDistinctNode has_columns has_estimated_groups
"""
