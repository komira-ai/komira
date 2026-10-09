# =============================================================================
# test_plan_field_numbers_scan.mojo
# =============================================================================
#
# THE FIELD-NUMBER CENSUS of `komira.plan.v1`, part 1 of 3: the schema, the
# scalar and the scan messages (WireField, WireSchema, WireScalar, WireParam,
# WirePushdownGate, WireScanBinding, WireParquetSource, WirePartitionValueRow,
# WireScanSource, WireScanNode, WireUdfColumn, WireUdf). Parts 2 and 3 are
# test_plan_field_numbers_expr.mojo and test_plan_field_numbers_plan.mojo;
# the enum values are test_plan_enum_numbers_*.mojo; and
# test_plan_census_complete.mojo holds the ledgers of all of them to the
# fields and values protoc declares.
#
# Why it exists: a field number is what is stored, and renumbering one in
# plan.proto moves the generated encoder and decoder together, so every Mojo
# round trip stays green and the golden fixtures (and protoc's
# `.canonical.hex`) can be regenerated green over the change. A reader built
# from the old schema then decodes the wrong field. This file restates the
# numbers by hand, so a renumbered field fails here.
#
# HOW A MESSAGE IS PINNED. `LEDGER` (at the end of the file) lists every
# field as `<Message>.<field> <number>`, written by hand. Each test writes a
# byte stream record by record, taking each record's number from the ledger
# row it names and the wire type from the field's proto type, with a value
# no other field of that message holds. Then:
#   1. it decodes the bytes with the generated codec and reads every field
#      back BY NAME: a field moved to another number reads as its default,
#      and two fields of one wire type that swapped numbers read each other's
#      values;
#   2. it encodes the decoded message and compares with the hand-written
#      records (canonical form, see `_same`): a field moved to an unused
#      number is dropped, a changed wire type re-encodes differently.
# BOOLS. A message with two or more singular (non-repeated) bools lists them
# in a `ONE_HOT` row (end of file) and is also written once per bool with only
# that bool true, since two true bools that swap numbers look the same; a
# message with one singular bool sets it in its main stream. Repeated bools
# are pinned by distinct patterns and lengths ([true, false] against
# [false, true, true]), read back by name.
# ONEOFS. Three: WireScanSource.payload (1 parquet, 2 binding; each written
# with a full payload, here), WireExpr.node (25 arms, 2 to 26) and
# WirePlan.node (16 arms, 4 to 19); each arm of the last two is written empty
# and checked by arm name, oneof position and re-encoded tag (parts 2, 3).
# A message field holds a non-empty sub-message; when its type is pinned in
# another file that payload is written with raw numbers (`_raw_*`), as a
# value, not as a pin. `check_all_hit` fails on a ledger row no test wrote.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_proto, encode_proto
from komira_plan_proto.plan import (
    WireField,
    WireParam,
    WireParquetSource,
    WirePartitionValueRow,
    WirePushdownGate,
    WireScalar,
    WireScanBinding,
    WireScanNode,
    WireScanSource,
    WireSchema,
    WireUdf,
    WireUdfColumn,
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


# ---- payloads pinned in another file ------------------------------------------------


def _raw_expr(index: Int) -> List[UInt8]:
    """A WireExpr holding `col_idx { index }` (3 col_idx, WireColIdx 1 index;
    pinned in test_plan_field_numbers_expr.mojo)."""
    var c = List[UInt8]()
    _raw_u(c, 1, UInt64(index))
    var b = List[UInt8]()
    _raw_m(b, 3, c)
    return b^


# ---- the schema ---------------------------------------------------------------------


def _field(mut L: _Ledger) raises -> List[UInt8]:
    var b = List[UInt8]()
    _s(L, b, "WireField.name", "price")
    _u(L, b, "WireField.arrow_type_id", 7)
    _u(L, b, "WireField.dtype_code", 4)
    _u(L, b, "WireField.nullable", 1)
    _i(L, b, "WireField.decimal_precision", 18)
    _i(L, b, "WireField.decimal_scale", 9)
    _s(L, b, "WireField.tz", "UTC")
    _u(L, b, "WireField.dict_index_type_id", 11)
    _i(L, b, "WireField.union_type_ids", 21)
    _i(L, b, "WireField.union_type_ids", 22)
    _i(L, b, "WireField.flags", 13)
    _s(L, b, "WireField.metadata_keys", "unit")
    _s(L, b, "WireField.metadata_keys", "scale")
    _s(L, b, "WireField.metadata_values", "cents")
    _s(L, b, "WireField.metadata_values", "two")
    _s(L, b, "WireField.child_names", "a")
    _s(L, b, "WireField.child_names", "b")
    _u(L, b, "WireField.child_type_ids", 31)
    _u(L, b, "WireField.child_type_ids", 32)
    _u(L, b, "WireField.child_nullables", 1)
    _u(L, b, "WireField.child_nullables", 0)
    return b^


def _field_named(mut L: _Ledger, name: String) raises -> List[UInt8]:
    var b = List[UInt8]()
    _s(L, b, "WireField.name", name)
    return b^


def _schema(mut L: _Ledger, key: String) raises -> List[UInt8]:
    """A WireSchema holding one metadata key."""
    var b = List[UInt8]()
    _s(L, b, "WireSchema.metadata_keys", key)
    return b^


def test_field(mut L: _Ledger) raises:
    var b = _field(L)
    var m = decode_proto[WireField](b.copy())
    assert_equal(m.name, "price", "WireField: m.name")
    assert_equal(m.arrow_type_id, UInt32(7), "WireField: m.arrow_type_id")
    assert_equal(m.dtype_code.number(), 4, "WireField: m.dtype_code.number()")
    assert_true(m.nullable, "WireField: m.nullable")
    assert_equal(m.decimal_precision, Int64(18), "WireField: m.decimal_precision")
    assert_equal(m.decimal_scale, Int64(9), "WireField: m.decimal_scale")
    assert_equal(m.tz, "UTC", "WireField: m.tz")
    assert_equal(m.dict_index_type_id, UInt32(11), "WireField: m.dict_index_type_id")
    assert_equal(len(m.union_type_ids), 2, "WireField: len(m.union_type_ids)")
    assert_equal(m.union_type_ids[0], Int64(21), "WireField: m.union_type_ids[0]")
    assert_equal(m.union_type_ids[1], Int64(22), "WireField: m.union_type_ids[1]")
    assert_equal(m.flags, Int64(13), "WireField: m.flags")
    _strs(m.metadata_keys, "unit scale", "WireField.metadata_keys")
    _strs(m.metadata_values, "cents two", "WireField.metadata_values")
    _strs(m.child_names, "a b", "WireField.child_names")
    assert_equal(len(m.child_type_ids), 2, "WireField: len(m.child_type_ids)")
    assert_equal(m.child_type_ids[0], UInt32(31), "WireField: m.child_type_ids[0]")
    assert_equal(m.child_type_ids[1], UInt32(32), "WireField: m.child_type_ids[1]")
    assert_equal(len(m.child_nullables), 2, "WireField: len(m.child_nullables)")
    assert_true(m.child_nullables[0], "WireField: m.child_nullables[0]")
    assert_true(not m.child_nullables[1], "WireField: not m.child_nullables[1]")
    _same(encode_proto(m), b, "WireField")


def test_schema(mut L: _Ledger) raises:
    var b = List[UInt8]()
    _m(L, b, "WireSchema.fields", _field(L))
    _m(L, b, "WireSchema.fields", _field_named(L, "qty"))
    _s(L, b, "WireSchema.metadata_keys", "origin")
    _s(L, b, "WireSchema.metadata_values", "lake")
    var m = decode_proto[WireSchema](b.copy())
    assert_equal(len(m.fields), 2, "WireSchema: len(m.fields)")
    assert_equal(m.fields[0].name, "price", "WireSchema: m.fields[0].name")
    assert_equal(m.fields[0].flags, Int64(13), "WireSchema: m.fields[0].flags")
    assert_equal(m.fields[1].name, "qty", "WireSchema: m.fields[1].name")
    _strs(m.metadata_keys, "origin", "WireSchema.metadata_keys")
    _strs(m.metadata_values, "lake", "WireSchema.metadata_values")
    _same(encode_proto(m), b, "WireSchema")


# ---- the scalar -----------------------------------------------------------------------


def test_scalar(mut L: _Ledger) raises:
    var b = List[UInt8]()
    _u(L, b, "WireScalar.dtype_code", 5)
    _i(L, b, "WireScalar.int_val", -7)
    _d(L, b, "WireScalar.float_val", 0x3FF8000000000000)  # 1.5
    _s(L, b, "WireScalar.string_val", "text")
    _u(L, b, "WireScalar.bool_val", 1)
    _u(L, b, "WireScalar.kind", 3)
    _i(L, b, "WireScalar.dec128_high", 70)
    _i(L, b, "WireScalar.dec128_low", 80)
    _i(L, b, "WireScalar.dec128_precision", 38)
    _i(L, b, "WireScalar.dec128_scale", 12)
    _i(L, b, "WireScalar.date32_val", 19000)
    _i(L, b, "WireScalar.ts_micros", 1234567)
    _u(L, b, "WireScalar.null_dtype_code", 6)
    _i(L, b, "WireScalar.iv_months", 14)
    _i(L, b, "WireScalar.iv_days", 15)
    _i(L, b, "WireScalar.iv_nanos", 16000)
    _u(L, b, "WireScalar.time_unit", 2)
    _i(L, b, "WireScalar.dec256_high_lo", 180)
    _i(L, b, "WireScalar.dec256_high_hi", 190)
    var neg = List[UInt8]()
    _raw_u(neg, 1, UInt64(Int64(-7)))
    assert_equal(len(neg), 1 + 10, "a negative int64 is a 10-byte varint")
    var m = decode_proto[WireScalar](b.copy())
    assert_equal(m.dtype_code.number(), 5, "WireScalar: m.dtype_code.number()")
    assert_equal(m.int_val, Int64(-7), "WireScalar: m.int_val")
    assert_equal(m.float_val, Float64(1.5), "WireScalar: m.float_val")
    assert_equal(m.string_val, "text", "WireScalar: m.string_val")
    assert_true(m.bool_val, "WireScalar: m.bool_val")
    assert_equal(m.kind.number(), 3, "WireScalar: m.kind.number()")
    assert_equal(m.dec128_high, Int64(70), "WireScalar: m.dec128_high")
    assert_equal(m.dec128_low, Int64(80), "WireScalar: m.dec128_low")
    assert_equal(m.dec128_precision, Int64(38), "WireScalar: m.dec128_precision")
    assert_equal(m.dec128_scale, Int64(12), "WireScalar: m.dec128_scale")
    assert_equal(m.date32_val, Int32(19000), "WireScalar: m.date32_val")
    assert_equal(m.ts_micros, Int64(1234567), "WireScalar: m.ts_micros")
    assert_equal(m.null_dtype_code.number(), 6, "WireScalar: m.null_dtype_code.number()")
    assert_equal(m.iv_months, Int32(14), "WireScalar: m.iv_months")
    assert_equal(m.iv_days, Int32(15), "WireScalar: m.iv_days")
    assert_equal(m.iv_nanos, Int64(16000), "WireScalar: m.iv_nanos")
    assert_equal(m.time_unit.number(), 2, "WireScalar: m.time_unit.number()")
    assert_equal(m.dec256_high_lo, Int64(180), "WireScalar: m.dec256_high_lo")
    assert_equal(m.dec256_high_hi, Int64(190), "WireScalar: m.dec256_high_hi")
    _same(encode_proto(m), b, "WireScalar")


# ---- the scan binding --------------------------------------------------------------


def _param(mut L: _Ledger) raises -> List[UInt8]:
    var b = List[UInt8]()
    _s(L, b, "WireParam.key", "region")
    _u(L, b, "WireParam.tag", 3)
    _s(L, b, "WireParam.s", "eu")
    _i(L, b, "WireParam.i", 44)
    _d(L, b, "WireParam.f", 0x4004000000000000)  # 2.5
    return b^


def test_param(mut L: _Ledger) raises:
    var b = _param(L)
    var m = decode_proto[WireParam](b.copy())
    assert_equal(m.key, "region", "WireParam: m.key")
    assert_equal(m.tag.number(), 3, "WireParam: m.tag.number()")
    assert_equal(m.s, "eu", "WireParam: m.s")
    assert_equal(m.i, Int64(44), "WireParam: m.i")
    assert_equal(m.f, Float64(2.5), "WireParam: m.f")
    _same(encode_proto(m), b, "WireParam")


def test_pushdown_gate(mut L: _Ledger) raises:
    var b = List[UInt8]()
    _u(L, b, "WirePushdownGate.mode", 2)
    _u(L, b, "WirePushdownGate.allowed_binary_ops", 60)
    var m = decode_proto[WirePushdownGate](b.copy())
    assert_equal(m.mode.number(), 2, "WirePushdownGate: m.mode.number()")
    assert_equal(m.allowed_binary_ops, UInt32(60), "WirePushdownGate: m.allowed_binary_ops")
    _same(encode_proto(m), b, "WirePushdownGate")
    var bools = _one_hot_row("WirePushdownGate")
    for k in range(len(bools)):
        var q = "WirePushdownGate." + bools[k]
        var h = List[UInt8]()
        _u(L, h, q, 1)
        var g = decode_proto[WirePushdownGate](h.copy())
        var got = List[Bool]()
        got.append(g.allow_and_recurse)
        got.append(g.allow_in_list)
        got.append(g.require_stat_friendly_col)
        _one_hot(got, bools, k, q)
        _same(encode_proto(g), h, q)


def _binding(mut L: _Ledger) raises -> List[UInt8]:
    var gate = List[UInt8]()
    _u(L, gate, "WirePushdownGate.mode", 3)
    var b = List[UInt8]()
    _u(L, b, "WireScanBinding.kind_id", 101)
    _s(L, b, "WireScanBinding.kind_name", "index")
    _s(L, b, "WireScanBinding.name", "orders")
    _m(L, b, "WireScanBinding.params", _param(L))
    var p2 = List[UInt8]()
    _s(L, p2, "WireParam.key", "bucket")
    _m(L, b, "WireScanBinding.params", p2)
    _m(L, b, "WireScanBinding.schema", _schema(L, "bound"))
    _u(L, b, "WireScanBinding.fingerprint", 0xFEDCBA9876543210)
    _u(L, b, "WireScanBinding.structural_id", 77)
    _m(L, b, "WireScanBinding.pushdown_gate", gate)
    _s(L, b, "WireScanBinding.pushdown_extra_cols", "x")
    _s(L, b, "WireScanBinding.pushdown_extra_cols", "y")
    _u(L, b, "WireScanBinding.snapshot_policy", 2)
    _u(L, b, "WireScanBinding.snapshot_token", 111)
    _u(L, b, "WireScanBinding.orientation", 3)
    _u(L, b, "WireScanBinding.legacy_source_type", 4)
    _u(L, b, "WireScanBinding.variant_tag", 5)
    return b^


def test_scan_binding(mut L: _Ledger) raises:
    var b = _binding(L)
    var m = decode_proto[WireScanBinding](b.copy())
    assert_equal(m.kind_id, UInt32(101), "WireScanBinding: m.kind_id")
    assert_equal(m.kind_name, "index", "WireScanBinding: m.kind_name")
    assert_equal(m.name, "orders", "WireScanBinding: m.name")
    assert_equal(len(m.params), 2, "WireScanBinding: len(m.params)")
    assert_equal(m.params[0].key, "region", "WireScanBinding: m.params[0].key")
    assert_equal(m.params[1].key, "bucket", "WireScanBinding: m.params[1].key")
    assert_equal(m.schema.value().metadata_keys[0], "bound", "WireScanBinding: m.schema.value().metadata_keys[0]")
    assert_equal(m.fingerprint, UInt64(0xFEDCBA9876543210), "WireScanBinding: m.fingerprint")
    assert_equal(m.structural_id, UInt64(77), "WireScanBinding: m.structural_id")
    assert_equal(m.pushdown_gate.value().mode.number(), 3, "WireScanBinding: m.pushdown_gate.value().mode.number()")
    _strs(m.pushdown_extra_cols, "x y", "WireScanBinding.pushdown_extra_cols")
    assert_equal(m.snapshot_policy.number(), 2, "WireScanBinding: m.snapshot_policy.number()")
    assert_equal(m.snapshot_token, UInt64(111), "WireScanBinding: m.snapshot_token")
    assert_equal(m.orientation.number(), 3, "WireScanBinding: m.orientation.number()")
    assert_equal(m.legacy_source_type.number(), 4, "WireScanBinding: m.legacy_source_type.number()")
    assert_equal(m.variant_tag.number(), 5, "WireScanBinding: m.variant_tag.number()")
    _same(encode_proto(m), b, "WireScanBinding")
    var bools = _one_hot_row("WireScanBinding")
    for k in range(len(bools)):
        var q = "WireScanBinding." + bools[k]
        var h = List[UInt8]()
        _u(L, h, q, 1)
        var g = decode_proto[WireScanBinding](h.copy())
        var got = List[Bool]()
        got.append(g.has_legacy_source_type)
        got.append(g.has_stats)
        _one_hot(got, bools, k, q)
        _same(encode_proto(g), h, q)


# ---- the parquet source and the scan source ---------------------------------------


def _parquet(mut L: _Ledger) raises -> List[UInt8]:
    var b = List[UInt8]()
    _s(L, b, "WireParquetSource.paths", "a.parquet")
    _s(L, b, "WireParquetSource.paths", "b.parquet")
    _m(L, b, "WireParquetSource.schema", _schema(L, "files"))
    _s(L, b, "WireParquetSource.name", "pq")
    _u(L, b, "WireParquetSource.mtime_ns", 1700000000000000000)
    _m(L, b, "WireParquetSource.partition_cols", _field_named(L, "year"))
    var r1 = List[UInt8]()
    _s(L, r1, "WirePartitionValueRow.values", "2024")
    var r2 = List[UInt8]()
    _s(L, r2, "WirePartitionValueRow.values", "2025")
    _m(L, b, "WireParquetSource.partition_values", r1)
    _m(L, b, "WireParquetSource.partition_values", r2)
    return b^


def test_parquet_source(mut L: _Ledger) raises:
    var b = _parquet(L)
    var m = decode_proto[WireParquetSource](b.copy())
    _strs(m.paths, "a.parquet b.parquet", "WireParquetSource.paths")
    assert_equal(m.schema.value().metadata_keys[0], "files", "WireParquetSource: m.schema.value().metadata_keys[0]")
    assert_equal(m.name, "pq", "WireParquetSource: m.name")
    assert_equal(m.mtime_ns, UInt64(1700000000000000000), "WireParquetSource: m.mtime_ns")
    assert_equal(len(m.partition_cols), 1, "WireParquetSource: len(m.partition_cols)")
    assert_equal(m.partition_cols[0].name, "year", "WireParquetSource: m.partition_cols[0].name")
    assert_equal(len(m.partition_values), 2, "WireParquetSource: len(m.partition_values)")
    _strs(m.partition_values[0].values, "2024", "partition_values[0]")
    _strs(m.partition_values[1].values, "2025", "partition_values[1]")
    _same(encode_proto(m), b, "WireParquetSource")
    var bools = _one_hot_row("WireParquetSource")
    for k in range(len(bools)):
        var q = "WireParquetSource." + bools[k]
        var h = List[UInt8]()
        _u(L, h, q, 1)
        var g = decode_proto[WireParquetSource](h.copy())
        var got = List[Bool]()
        got.append(g.has_name)
        got.append(g.hive_dir_scan)
        got.append(g.has_hive_predicate)
        got.append(g.fs_is_local)
        _one_hot(got, bools, k, q)
        _same(encode_proto(g), h, q)


def test_partition_value_row(mut L: _Ledger) raises:
    var b = List[UInt8]()
    _s(L, b, "WirePartitionValueRow.values", "p")
    _s(L, b, "WirePartitionValueRow.values", "q")
    var m = decode_proto[WirePartitionValueRow](b.copy())
    _strs(m.values, "p q", "WirePartitionValueRow.values")
    _same(encode_proto(m), b, "WirePartitionValueRow")


def test_scan_source(mut L: _Ledger) raises:
    """oneof payload { 1 parquet, 2 binding }, each arm by name."""
    var p = List[UInt8]()
    _m(L, p, "WireScanSource.parquet", _parquet(L))
    var mp = decode_proto[WireScanSource](p.copy())
    assert_equal(mp._oneof0_case, 1, "WireScanSource.parquet is the first arm")
    assert_true(Bool(mp.parquet) and not Bool(mp.binding), "the parquet arm")
    assert_equal(mp.parquet.value().name, "pq", "WireScanSource: mp.parquet.value().name")
    _same(encode_proto(mp), p, "WireScanSource.parquet")

    var s = List[UInt8]()
    _m(L, s, "WireScanSource.binding", _binding(L))
    var ms = decode_proto[WireScanSource](s.copy())
    assert_equal(ms._oneof0_case, 2, "WireScanSource.binding is the second arm")
    assert_true(Bool(ms.binding) and not Bool(ms.parquet), "the binding arm")
    assert_equal(ms.binding.value().name, "orders", "WireScanSource: ms.binding.value().name")
    _same(encode_proto(ms), s, "WireScanSource.binding")


def test_scan_node(mut L: _Ledger) raises:
    var src = List[UInt8]()
    var bound = List[UInt8]()
    _s(L, bound, "WireScanBinding.name", "events")
    _m(L, src, "WireScanSource.binding", bound)
    var b = List[UInt8]()
    _m(L, b, "WireScanNode.source", src)
    _m(L, b, "WireScanNode.schema", _schema(L, "scan"))
    _s(L, b, "WireScanNode.projection", "c1")
    _s(L, b, "WireScanNode.projection", "c2")
    _m(L, b, "WireScanNode.filter", _raw_expr(9))
    _i(L, b, "WireScanNode.row_count", 999)
    _u(L, b, "WireScanNode.source_kind", 2)
    var m = decode_proto[WireScanNode](b.copy())
    assert_equal(m.source.value().binding.value().name, "events", "WireScanNode: m.source.value().binding.value().name")
    assert_equal(m.schema.value().metadata_keys[0], "scan", "WireScanNode: m.schema.value().metadata_keys[0]")
    _strs(m.projection, "c1 c2", "WireScanNode.projection")
    assert_equal(len(m.filter), 1, "WireScanNode: len(m.filter)")
    assert_equal(m.filter[0].col_idx.value().index, Int64(9), "WireScanNode: m.filter[0].col_idx.value().index")
    assert_equal(m.row_count, Int64(999), "WireScanNode: m.row_count")
    assert_equal(m.source_kind.number(), 2, "WireScanNode: m.source_kind.number()")
    _same(encode_proto(m), b, "WireScanNode")
    var bools = _one_hot_row("WireScanNode")
    for k in range(len(bools)):
        var q = "WireScanNode." + bools[k]
        var h = List[UInt8]()
        _u(L, h, q, 1)
        var g = decode_proto[WireScanNode](h.copy())
        var got = List[Bool]()
        got.append(g.has_schema)
        got.append(g.has_projection)
        got.append(g.has_filter)
        got.append(g.has_row_count)
        got.append(g.has_table_stats)
        _one_hot(got, bools, k, q)
        _same(encode_proto(g), h, q)


# ---- the UDF description -----------------------------------------------------------


def _udf_column(mut L: _Ledger, name: String, tag: Int) raises -> List[UInt8]:
    var b = List[UInt8]()
    _s(L, b, "WireUdfColumn.name", name)
    _u(L, b, "WireUdfColumn.dtype_tag", UInt64(tag))
    return b^


def test_udf_column(mut L: _Ledger) raises:
    var b = _udf_column(L, "in0", 23)
    var m = decode_proto[WireUdfColumn](b.copy())
    assert_equal(m.name, "in0", "WireUdfColumn: m.name")
    assert_equal(m.dtype_tag, UInt32(23), "WireUdfColumn: m.dtype_tag")
    _same(encode_proto(m), b, "WireUdfColumn")


def test_udf(mut L: _Ledger) raises:
    var b = List[UInt8]()
    _u(L, b, "WireUdf.kind", 3)
    _s(L, b, "WireUdf.name", "my_udf")
    _m(L, b, "WireUdf.input_columns", _udf_column(L, "in0", 23))
    _m(L, b, "WireUdf.input_columns", _udf_column(L, "in1", 24))
    _m(L, b, "WireUdf.output_columns", _udf_column(L, "out0", 25))
    _u(L, b, "WireUdf.null_mode", 5)
    _u(L, b, "WireUdf.stability", 6)
    _u(L, b, "WireUdf.parallelism_tag", 7)
    _s(L, b, "WireUdf.partition_keys", "pk")
    _s(L, b, "WireUdf.order_keys", "ok1")
    _s(L, b, "WireUdf.order_keys", "ok2")
    _u(L, b, "WireUdf.has_vector_path", 1)
    _u(L, b, "WireUdf.operator_factory_id", 11)
    _u(L, b, "WireUdf.call_site_salt", 12)
    var m = decode_proto[WireUdf](b.copy())
    assert_equal(m.kind, UInt32(3), "WireUdf: m.kind")
    assert_equal(m.name, "my_udf", "WireUdf: m.name")
    assert_equal(len(m.input_columns), 2, "WireUdf: len(m.input_columns)")
    assert_equal(m.input_columns[0].name, "in0", "WireUdf: m.input_columns[0].name")
    assert_equal(m.input_columns[1].dtype_tag, UInt32(24), "WireUdf: m.input_columns[1].dtype_tag")
    assert_equal(len(m.output_columns), 1, "WireUdf: len(m.output_columns)")
    assert_equal(m.output_columns[0].name, "out0", "WireUdf: m.output_columns[0].name")
    assert_equal(m.null_mode, UInt32(5), "WireUdf: m.null_mode")
    assert_equal(m.stability, UInt32(6), "WireUdf: m.stability")
    assert_equal(m.parallelism_tag, UInt32(7), "WireUdf: m.parallelism_tag")
    _strs(m.partition_keys, "pk", "WireUdf.partition_keys")
    _strs(m.order_keys, "ok1 ok2", "WireUdf.order_keys")
    assert_true(m.has_vector_path, "WireUdf: m.has_vector_path")
    assert_equal(m.operator_factory_id, UInt32(11), "WireUdf: m.operator_factory_id")
    assert_equal(m.call_site_salt, UInt32(12), "WireUdf: m.call_site_salt")
    _same(encode_proto(m), b, "WireUdf")


def main() raises:
    print("test_plan_field_numbers_scan: the schema, scalar and scan census")
    var L = _Ledger(LEDGER)
    test_field(L)
    test_schema(L)
    test_scalar(L)
    test_param(L)
    test_pushdown_gate(L)
    test_scan_binding(L)
    test_parquet_source(L)
    test_partition_value_row(L)
    test_scan_source(L)
    test_scan_node(L)
    test_udf_column(L)
    test_udf(L)
    L.check_all_hit()
    print("ALL komira.plan.v1 SCAN FIELD NUMBERS PINNED:", len(L.names), "fields")


# ---- THE LEDGER: every field of the twelve messages above, numbers written by hand --------
# Change a number here only with the .proto, and only one that never
# shipped: a shipped number is permanent.

comptime LEDGER = """
WireField.name 1
WireField.arrow_type_id 2
WireField.dtype_code 3
WireField.nullable 4
WireField.decimal_precision 5
WireField.decimal_scale 6
WireField.tz 7
WireField.dict_index_type_id 8
WireField.union_type_ids 9
WireField.flags 10
WireField.metadata_keys 11
WireField.metadata_values 12
WireField.child_names 13
WireField.child_type_ids 14
WireField.child_nullables 15
WireSchema.fields 1
WireSchema.metadata_keys 2
WireSchema.metadata_values 3
WireScalar.dtype_code 1
WireScalar.int_val 2
WireScalar.float_val 3
WireScalar.string_val 4
WireScalar.bool_val 5
WireScalar.kind 6
WireScalar.dec128_high 7
WireScalar.dec128_low 8
WireScalar.dec128_precision 9
WireScalar.dec128_scale 10
WireScalar.date32_val 11
WireScalar.ts_micros 12
WireScalar.null_dtype_code 13
WireScalar.iv_months 14
WireScalar.iv_days 15
WireScalar.iv_nanos 16
WireScalar.time_unit 17
WireScalar.dec256_high_lo 18
WireScalar.dec256_high_hi 19
WireParam.key 1
WireParam.tag 2
WireParam.s 3
WireParam.i 4
WireParam.f 5
WirePushdownGate.mode 1
WirePushdownGate.allowed_binary_ops 2
WirePushdownGate.allow_and_recurse 3
WirePushdownGate.allow_in_list 4
WirePushdownGate.require_stat_friendly_col 5
WireScanBinding.kind_id 1
WireScanBinding.kind_name 2
WireScanBinding.name 3
WireScanBinding.params 4
WireScanBinding.schema 5
WireScanBinding.fingerprint 6
WireScanBinding.structural_id 7
WireScanBinding.pushdown_gate 8
WireScanBinding.pushdown_extra_cols 9
WireScanBinding.snapshot_policy 10
WireScanBinding.snapshot_token 11
WireScanBinding.orientation 12
WireScanBinding.has_legacy_source_type 16
WireScanBinding.legacy_source_type 13
WireScanBinding.variant_tag 14
WireScanBinding.has_stats 15
WireParquetSource.paths 1
WireParquetSource.schema 2
WireParquetSource.has_name 3
WireParquetSource.name 4
WireParquetSource.mtime_ns 5
WireParquetSource.partition_cols 6
WireParquetSource.partition_values 7
WireParquetSource.hive_dir_scan 8
WireParquetSource.has_hive_predicate 9
WireParquetSource.fs_is_local 10
WirePartitionValueRow.values 1
WireScanSource.parquet 1
WireScanSource.binding 2
WireScanNode.source 1
WireScanNode.has_schema 2
WireScanNode.schema 3
WireScanNode.has_projection 4
WireScanNode.projection 5
WireScanNode.has_filter 6
WireScanNode.filter 7
WireScanNode.has_row_count 8
WireScanNode.row_count 9
WireScanNode.source_kind 10
WireScanNode.has_table_stats 11
WireUdfColumn.name 1
WireUdfColumn.dtype_tag 2
WireUdf.kind 1
WireUdf.name 2
WireUdf.input_columns 3
WireUdf.output_columns 4
WireUdf.null_mode 5
WireUdf.stability 6
WireUdf.parallelism_tag 7
WireUdf.partition_keys 8
WireUdf.order_keys 9
WireUdf.has_vector_path 10
WireUdf.operator_factory_id 11
WireUdf.call_site_salt 12
"""


# ---- THE ONE-HOT ROWS: each message with two or more single (non-repeated)
# bools, and those bools in the order its test reads them. Two true bools that
# swap numbers look the same in one stream, so each is written alone.
# test_plan_census_complete.mojo requires these rows to be exactly the
# messages and bools protoc declares.

comptime ONE_HOT = """
WirePushdownGate allow_and_recurse allow_in_list require_stat_friendly_col
WireScanBinding has_legacy_source_type has_stats
WireParquetSource has_name hive_dir_scan has_hive_predicate fs_is_local
WireScanNode has_schema has_projection has_filter has_row_count has_table_stats
"""
