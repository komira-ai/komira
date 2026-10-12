# =============================================================================
# test_plan_field_numbers_udf.mojo
# =============================================================================
#
# THE FIELD-NUMBER CENSUS of `komira.plan.v1`'s user-code messages
# (optimized_plan_udfs.md §10.3, §10.4): UdfRef, UdfReadSet, UdfCode,
# CodeDigest, UdfResources, RecordedFields, WireUdfApply, WireMapBatchesNode
# and WireStepNode, and the values of UdfKind, CodeForm, UdfStability and
# UdfNullMode. How a message is pinned, and why, is in the header of
# test_plan_field_numbers_scan.mojo; the helpers are restated here, since a
# welded test is one source file. Each test writes a record per field under
# its ledger number with a value no other field of that message holds, reads
# every field back by name, and re-encodes to the same records (canonical
# form, `_same`). A WireField, WireExpr, WirePlan or WireScalar inside them is
# written with raw numbers, as a value: those messages are pinned by the
# other census files.
#
# PRESENCE. `_same` drops empty records, so it cannot see the difference that
# `UdfRef.read_set` exists for: a set message with no records is not an
# absent one. `test_presence` holds that in exact bytes.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import ProtoEnum, decode_proto, encode_proto
from komira_plan_proto.plan import (
    CodeDigest,
    CodeForm,
    RecordedFields,
    UdfCode,
    UdfKind,
    UdfNullMode,
    UdfReadSet,
    UdfRef,
    UdfResources,
    UdfStability,
    WireMapBatchesNode,
    WireStepNode,
    WireUdfApply,
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




# ---- raw values of messages other census files pin -------------------------------


def _raw_field(name: String) -> List[UInt8]:
    """WireField { 1 name }."""
    var b = List[UInt8]()
    _raw_s(b, 1, name)
    return b^


def _raw_expr(index: Int) -> List[UInt8]:
    """WireExpr { 3 col_idx { 1 index } }."""
    var c = List[UInt8]()
    _raw_u(c, 1, UInt64(index))
    var b = List[UInt8]()
    _raw_m(b, 3, c)
    return b^


def _raw_plan(hash: Int) -> List[UInt8]:
    """WirePlan { 18 cse_ref { 1 canonical_hash } }."""
    var c = List[UInt8]()
    _raw_u(c, 1, UInt64(hash))
    var b = List[UInt8]()
    _raw_m(b, 18, c)
    return b^


def _raw_scalar(v: Int) -> List[UInt8]:
    """WireScalar { 2 int_val }."""
    var b = List[UInt8]()
    _raw_u(b, 2, UInt64(v))
    return b^


def _text(b: List[UInt8]) -> String:
    """A bytes field read back as the text it was written from."""
    var out = String("")
    for i in range(len(b)):
        out += chr(Int(b[i]))
    return out


# ---- payloads -----------------------------------------------------------------------


def _digest(mut L: _Ledger, role: String) raises -> List[UInt8]:
    var b = List[UInt8]()
    _s(L, b, "CodeDigest.role", role)
    _s(L, b, "CodeDigest.sha256", "sha-" + role)
    return b^


def _code(mut L: _Ledger) raises -> List[UInt8]:
    var b = List[UInt8]()
    _s(L, b, "UdfCode.runtime", "komira/python")
    _u(L, b, "UdfCode.form", 3)
    _s(L, b, "UdfCode.entry", "pkg.mod:score")
    _m(L, b, "UdfCode.code", _digest(L, "payload"))
    _m(L, b, "UdfCode.code", _digest(L, "bundle"))
    _u(L, b, "UdfCode.descriptor_version", 7)
    _s(L, b, "UdfCode.descriptor", "desc")
    return b^


def _resources(mut L: _Ledger) raises -> List[UInt8]:
    var b = List[UInt8]()
    _u(L, b, "UdfResources.worker_mem_bytes", 1000)
    _u(L, b, "UdfResources.max_workers", 2)
    _u(L, b, "UdfResources.max_batch_rows", 256)
    _u(L, b, "UdfResources.max_runtime_ms", 5000)
    _u(L, b, "UdfResources.max_concurrent_calls", 8)
    return b^


def _read_set(mut L: _Ledger) raises -> List[UInt8]:
    var b = List[UInt8]()
    _s(L, b, "UdfReadSet.columns", "a")
    _s(L, b, "UdfReadSet.columns", "b")
    return b^


def _udf_ref(mut L: _Ledger) raises -> List[UInt8]:
    var b = List[UInt8]()
    _u(L, b, "UdfRef.kind", 6)
    _m(L, b, "UdfRef.code", _code(L))
    _m(L, b, "UdfRef.arg_types", _raw_field("a"))
    _m(L, b, "UdfRef.arg_types", _raw_field("b"))
    _s(L, b, "UdfRef.data_blobs", "blob1")
    _s(L, b, "UdfRef.data_blobs", "blob2")
    _m(L, b, "UdfRef.return_type", _raw_field("ret"))
    _u(L, b, "UdfRef.stability", 2)
    _u(L, b, "UdfRef.null_mode", 1)
    _m(L, b, "UdfRef.resources", _resources(L))
    _m(L, b, "UdfRef.state_type", _raw_field("state"))
    _u(L, b, "UdfRef.preserves_event_time", 1)
    _m(L, b, "UdfRef.read_set", _read_set(L))
    return b^


# ---- the tests ---------------------------------------------------------------------


def test_udf_ref(mut L: _Ledger) raises:
    var b = _udf_ref(L)
    var m = decode_proto[UdfRef](b.copy())
    assert_equal(m.kind.number(), 6, "UdfRef: m.kind")
    ref c = m.code.value()
    assert_equal(c.runtime, "komira/python", "UdfCode: c.runtime")
    assert_equal(c.form.number(), 3, "UdfCode: c.form")
    assert_equal(c.entry, "pkg.mod:score", "UdfCode: c.entry")
    assert_equal(len(c.code), 2, "UdfCode: len(c.code)")
    assert_equal(c.code[0].role, "payload", "CodeDigest: c.code[0].role")
    assert_equal(_text(c.code[1].sha256), "sha-bundle", "CodeDigest: c.code[1].sha256")
    assert_equal(c.descriptor_version, UInt32(7), "UdfCode: c.descriptor_version")
    assert_equal(_text(c.descriptor), "desc", "UdfCode: c.descriptor")
    assert_equal(len(m.arg_types), 2, "UdfRef: len(m.arg_types)")
    assert_equal(m.arg_types[1].name, "b", "UdfRef: m.arg_types[1].name")
    assert_equal(len(m.data_blobs), 2, "UdfRef: len(m.data_blobs)")
    assert_equal(_text(m.data_blobs[1]), "blob2", "UdfRef: m.data_blobs[1]")
    assert_equal(m.return_type.value().name, "ret", "UdfRef: m.return_type")
    assert_equal(m.stability.number(), 2, "UdfRef: m.stability")
    assert_equal(m.null_mode.number(), 1, "UdfRef: m.null_mode")
    ref r = m.resources.value()
    assert_equal(r.worker_mem_bytes, UInt64(1000), "UdfResources: worker_mem_bytes")
    assert_equal(r.max_workers, UInt32(2), "UdfResources: max_workers")
    assert_equal(r.max_batch_rows, UInt32(256), "UdfResources: max_batch_rows")
    assert_equal(r.max_runtime_ms, UInt64(5000), "UdfResources: max_runtime_ms")
    assert_equal(r.max_concurrent_calls, UInt32(8), "UdfResources: max_concurrent_calls")
    assert_equal(m.state_type.value().name, "state", "UdfRef: m.state_type")
    assert_true(m.preserves_event_time, "UdfRef: m.preserves_event_time")
    _strs(m.read_set.value().columns, "a b", "UdfReadSet.columns")
    _same(encode_proto(m), b, "UdfRef")


def test_recorded_fields(mut L: _Ledger) raises:
    var b = List[UInt8]()
    _m(L, b, "RecordedFields.fields", _raw_field("a"))
    _m(L, b, "RecordedFields.fields", _raw_field("b"))
    _m(L, b, "RecordedFields.key_fields", _raw_field("k"))
    var m = decode_proto[RecordedFields](b.copy())
    assert_equal(len(m.fields), 2, "RecordedFields: len(m.fields)")
    assert_equal(m.fields[1].name, "b", "RecordedFields: m.fields[1].name")
    assert_equal(len(m.key_fields), 1, "RecordedFields: len(m.key_fields)")
    assert_equal(m.key_fields[0].name, "k", "RecordedFields: m.key_fields[0].name")
    _same(encode_proto(m), b, "RecordedFields")


def test_udf_arms(mut L: _Ledger) raises:
    var a = List[UInt8]()
    _u(L, a, "WireUdfApply.udf_index", 3)
    _m(L, a, "WireUdfApply.args", _raw_expr(41))
    _m(L, a, "WireUdfApply.args", _raw_expr(42))
    var ua = decode_proto[WireUdfApply](a.copy())
    assert_equal(ua.udf_index, UInt32(3), "WireUdfApply: udf_index")
    assert_equal(len(ua.args), 2, "WireUdfApply: len(args)")
    assert_equal(ua.args[1].col_idx.value().index, Int64(42), "WireUdfApply: args[1]")
    _same(encode_proto(ua), a, "WireUdfApply")

    var m = List[UInt8]()
    _m(L, m, "WireMapBatchesNode.child", _raw_plan(55))
    _u(L, m, "WireMapBatchesNode.udf_index", 4)
    _m(L, m, "WireMapBatchesNode.group_by", _raw_expr(43))
    _m(L, m, "WireMapBatchesNode.group_by", _raw_expr(44))
    var mb = decode_proto[WireMapBatchesNode](m.copy())
    assert_equal(mb.child[0].cse_ref.value().canonical_hash, UInt64(55), "WireMapBatchesNode: child")
    assert_equal(mb.udf_index, UInt32(4), "WireMapBatchesNode: udf_index")
    assert_equal(len(mb.group_by), 2, "WireMapBatchesNode: len(group_by)")
    assert_equal(mb.group_by[0].col_idx.value().index, Int64(43), "WireMapBatchesNode: group_by[0]")
    _same(encode_proto(mb), m, "WireMapBatchesNode")

    var s = List[UInt8]()
    _u(L, s, "WireStepNode.udf_index", 5)
    _m(L, s, "WireStepNode.args", _raw_scalar(61))
    _m(L, s, "WireStepNode.args", _raw_scalar(62))
    var st = decode_proto[WireStepNode](s.copy())
    assert_equal(st.udf_index, UInt32(5), "WireStepNode: udf_index")
    assert_equal(len(st.args), 2, "WireStepNode: len(args)")
    assert_equal(st.args[1].int_val, Int64(62), "WireStepNode: args[1]")
    _same(encode_proto(st), s, "WireStepNode")


def test_presence(mut L: _Ledger) raises:
    """`read_set` is a message so that unset and empty differ, in EXACT bytes
    (`_same` drops empty records): an absent `read_set` writes no record, a
    present empty one writes its tag and a zero length."""
    var base = List[UInt8]()
    _u(L, base, "UdfRef.kind", 6)
    var absent = decode_proto[UdfRef](base.copy())
    assert_true(not Bool(absent.read_set), "UdfRef: read_set absent decodes unset")

    var with_empty = base.copy()
    _m(L, with_empty, "UdfRef.read_set", List[UInt8]())
    var empty = decode_proto[UdfRef](with_empty.copy())
    assert_true(Bool(empty.read_set), "UdfRef: an empty read_set record decodes set")
    assert_equal(len(empty.read_set.value().columns), 0, "UdfRef: the set read_set has no columns")
    var e_absent = encode_proto(absent)
    var e_empty = encode_proto(empty)
    assert_true(_hex(e_absent) != _hex(e_empty), "UdfRef: unset and empty read_set encode differently")
    # The empty one is the unset one plus exactly `9a 01 00` (field 19, LEN, 0).
    var tail = String("0x9a 0x1 0x0 ")
    assert_equal(_hex(e_empty), _hex(e_absent) + tail, "UdfRef: a present empty read_set writes its tag and 00")



def _check(enum: String, v: String, n: Int) raises:
    """Row `<enum>.<v> <n>`: the generated enum maps the name and the number to
    each other, and the literal varint `n` under its host field decodes as
    `v` and re-encodes the same."""
    var q = enum + "." + v
    if enum == "UdfKind":
        _names_agree[UdfKind](v, n, q)
        var b = _rec(2, n)  # UdfRef.kind
        var m = decode_proto[UdfRef](b.copy())
        _host(m.kind.json_name(), encode_proto(m), b, v, q)
    elif enum == "CodeForm":
        _names_agree[CodeForm](v, n, q)
        var b = _rec(2, n)  # UdfCode.form
        var m = decode_proto[UdfCode](b.copy())
        _host(m.form.json_name(), encode_proto(m), b, v, q)
    elif enum == "UdfStability":
        _names_agree[UdfStability](v, n, q)
        var b = _rec(10, n)  # UdfRef.stability
        var m = decode_proto[UdfRef](b.copy())
        _host(m.stability.json_name(), encode_proto(m), b, v, q)
    elif enum == "UdfNullMode":
        _names_agree[UdfNullMode](v, n, q)
        var b = _rec(11, n)  # UdfRef.null_mode
        var m = decode_proto[UdfRef](b.copy())
        _host(m.null_mode.json_name(), encode_proto(m), b, v, q)
    else:
        raise Error("no check for enum " + enum + ": add it to `_check`")


def _rec(field: Int, n: Int) -> List[UInt8]:
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


def test_enum_values(mut L: _Ledger) raises:
    for i in range(len(L.names)):
        var row = L.names[i]
        var dot = row.find(".")
        var head = String(row[byte=0:dot])
        if head == "UdfKind" or head == "CodeForm" or head == "UdfStability" or head == "UdfNullMode":
            var value = String(row[byte = dot + 1 : row.byte_length()])
            _check(head, value, L.number(row))


def main() raises:
    print("test_plan_field_numbers_udf: the user-code census")
    var L = _Ledger(LEDGER)
    test_udf_ref(L)
    test_recorded_fields(L)
    test_udf_arms(L)
    test_presence(L)
    test_enum_values(L)
    L.check_all_hit()
    print("ALL", len(L.names), "user-code FIELDS AND VALUES PINNED")


# ---- THE LEDGER: every field of the 9 messages and every value of the 4 enums -------
# Change a number here only with the .proto, and only one no released
# format_version carries: a released number is permanent.

comptime LEDGER = """
UdfRef.kind 2
UdfRef.code 16
UdfRef.arg_types 17
UdfRef.data_blobs 6
UdfRef.return_type 8
UdfRef.stability 10
UdfRef.null_mode 11
UdfRef.resources 12
UdfRef.state_type 15
UdfRef.preserves_event_time 18
UdfRef.read_set 19
UdfReadSet.columns 1
UdfCode.runtime 1
UdfCode.form 2
UdfCode.entry 3
UdfCode.code 4
UdfCode.descriptor_version 5
UdfCode.descriptor 6
CodeDigest.role 1
CodeDigest.sha256 2
UdfResources.worker_mem_bytes 3
UdfResources.max_workers 4
UdfResources.max_batch_rows 5
UdfResources.max_runtime_ms 6
UdfResources.max_concurrent_calls 7
RecordedFields.fields 1
RecordedFields.key_fields 2
WireUdfApply.udf_index 1
WireUdfApply.args 2
WireMapBatchesNode.child 1
WireMapBatchesNode.udf_index 2
WireMapBatchesNode.group_by 3
WireStepNode.udf_index 1
WireStepNode.args 2
UdfKind.UDF_KIND_UNSPECIFIED 0
UdfKind.SCALAR 1
UdfKind.MAP_BATCHES_COLUMN 2
UdfKind.AGGREGATE 3
UdfKind.STEP 4
UdfKind.MAP_BATCHES_FRAME 5
UdfKind.ROW 6
CodeForm.CODE_FORM_UNSPECIFIED 0
CodeForm.PACKAGE 1
CodeForm.BUNDLE 2
CodeForm.VALUE 3
UdfStability.UDF_STABILITY_WIRE_UNSPECIFIED 0
UdfStability.UDF_STABILITY_IMMUTABLE 1
UdfStability.UDF_STABILITY_STABLE 2
UdfStability.UDF_STABILITY_VOLATILE 3
UdfNullMode.UDF_NULL_WIRE_UNSPECIFIED 0
UdfNullMode.UDF_NULL_MANUAL 1
UdfNullMode.UDF_NULL_PROPAGATE 2
UdfNullMode.UDF_NULL_SKIP_NULL_FAST_PATH 3
"""
