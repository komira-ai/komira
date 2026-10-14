# =============================================================================
# test_optimized_plan_field_numbers.mojo
# =============================================================================
#
# THE FIELD-NUMBER CENSUS of optimized_plan.proto: every field of every
# message, each number written by hand in `LEDGER` (end of file) and held to
# the generated codec as wire bytes, read back by name. It is pinned the way
# the plan.v1 census is (header of test_plan_field_numbers_scan.mojo): each
# test writes a byte stream record by record, taking each record's number
# from the ledger row it names and the wire type from the field's proto
# type, with a value no other field of that message holds; then
#   1. it decodes the bytes with the generated codec and reads every field
#      back BY NAME: a field moved to another number reads as its default,
#      and two fields of one wire type that swapped numbers read each other's
#      values;
#   2. it encodes the decoded message and compares with the hand-written
#      records (canonical form, see `_same`): a field moved to an unused
#      number is dropped, a changed wire type re-encodes differently.
# A message field holds a non-empty sub-message. A WirePlan or a
# WireWriteTarget (pinned by the plan.v1 census) is written with raw numbers,
# as a value, not as a pin. `check_all_hit` fails on a ledger row no test
# wrote, and test_plan_census_complete.mojo fails on a field protoc declares
# that no row lists.
#
# HELD AND RESERVED NUMBERS (`HELD`, end of file). optimized_plan.proto
# leaves free each number the design gives a field this stage cannot declare
# yet (its header says why), and reserves the numbers of draft fields that
# were never released. For each such number, `test_held_numbers` writes one
# record with a non-zero payload under it, in the wire type the field will
# have, and requires that the message decodes and re-encodes to nothing: no
# declared field took the number. So a field declared at a held number (or a
# reserved one, once its `reserved` line is gone) fails here until its row
# moves from HELD to LEDGER, with a byte test, in the same change. Bytes
# cannot tell a held number from a reserved one; test_plan_reservations.mojo
# reads HELD's last column against the .proto's `reserved` statements.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import Serializable, decode_proto, encode_proto
from komira_plan_proto.plan import WirePlan
from komira_plan_proto.optimized_plan import (
    DeclaredNeeds,
    ExchangeEdge,
    OptimizedPlan,
    OptimizedPlanBody,
    OptimizedSegment,
    OptimizedSegmentDag,
    PinGroup,
    PlanAdvice,
    ProducerStamp,
    RuntimeNeed,
    ScanPin,
    ScanStats,
    SharedSubplan,
)


# ---- the ledger ---------------------------------------------------------------


struct _Ledger(Movable):
    """This file's census rows, `<Message>.<field> <number>`, read from
    `LEDGER`. Every hand-written record takes its number from here and marks
    its row; `check_all_hit` then refuses a row no test wrote."""

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
    """A varint record of `q` (an unsigned or a bool)."""
    _raw_u(b, L.number(q), v)


def _s(mut L: _Ledger, mut b: List[UInt8], q: String, s: String) raises:
    """A length-delimited record of a string or bytes `q`."""
    _raw_s(b, L.number(q), s)


def _m(mut L: _Ledger, mut b: List[UInt8], q: String, m: List[UInt8]) raises:
    _raw_m(b, L.number(q), m)


def _hex(b: List[UInt8]) -> String:
    var out = String("")
    for i in range(len(b)):
        out += hex(Int(b[i])) + " "
    return out


def _text(b: List[UInt8]) -> String:
    """A bytes field read back as the text it was written from."""
    var out = String("")
    for i in range(len(b)):
        out += chr(Int(b[i]))
    return out


# ⚠ THE GENERATED BINARY ENCODER WRITES PROTO3 ZERO VALUES (every scalar at
# its default) and writes a message's oneof after its plain fields. Both
# sides are compared in a canonical form: zero-valued records dropped
# (recursively), each level's records sorted stably by field number (a
# repeated field keeps its order). Every value this census writes is
# non-zero, so dropping zeros loses nothing it wrote.


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


# ---- payloads pinned elsewhere, written raw ----------------------------------------


def _raw_plan(hash: Int) -> List[UInt8]:
    """WirePlan { 18 cse_ref { 1 canonical_hash } }."""
    var c = List[UInt8]()
    _raw_u(c, 1, UInt64(hash))
    var b = List[UInt8]()
    _raw_m(b, 18, c)
    return b^


def _hash(p: WirePlan) raises -> Int:
    return Int(p.cse_ref.value().canonical_hash)


def _raw_write_target(path: String) -> List[UInt8]:
    """WireWriteTarget { 1 path }."""
    var b = List[UInt8]()
    _raw_s(b, 1, path)
    return b^


# ---- payloads pinned here: each builder marks its rows ----------------------------


def _stamp(mut L: _Ledger, kind: String) raises -> List[UInt8]:
    var b = List[UInt8]()
    _s(L, b, "ProducerStamp.engine_build", "eb-" + kind)
    _u(L, b, "ProducerStamp.optimizer_contract_version", 3)
    _s(L, b, "ProducerStamp.optimizer_config_digest", "cd-" + kind)
    _s(L, b, "ProducerStamp.kind", kind)
    return b^


def _runtime(mut L: _Ledger, id: String, abi: String) raises -> List[UInt8]:
    var b = List[UInt8]()
    _s(L, b, "RuntimeNeed.runtime", id)
    _s(L, b, "RuntimeNeed.runtime_abi", abi)
    return b^


def _needs(mut L: _Ledger, scope: String) raises -> List[UInt8]:
    var b = List[UInt8]()
    _s(L, b, "DeclaredNeeds.data_scopes", scope)
    _s(L, b, "DeclaredNeeds.data_scopes", scope + "-2")
    _u(L, b, "DeclaredNeeds.unbounded", 1)
    _m(L, b, "DeclaredNeeds.runtimes", _runtime(L, "komira/node", "node22"))
    _m(L, b, "DeclaredNeeds.runtimes", _runtime(L, "komira/python", "cp312"))
    _m(L, b, "DeclaredNeeds.udfs", _udf_ref_value("komira/python"))
    _m(L, b, "DeclaredNeeds.udfs", _udf_ref_value("komira/node"))
    return b^


def _udf_ref_value(runtime: String) -> List[UInt8]:
    """UdfRef { 16 code { 1 runtime } }: a value, not a pin (the UdfRef
    census is test_plan_field_numbers_udf.mojo)."""
    var code = List[UInt8]()
    _raw_s(code, 1, runtime)
    var b = List[UInt8]()
    _raw_m(b, 16, code)
    return b^


def _pin(mut L: _Ledger, key: String) raises -> List[UInt8]:
    var b = List[UInt8]()
    _s(L, b, "ScanPin.binding_key", key)
    _s(L, b, "ScanPin.data_fingerprint", "fp-" + key)
    return b^


def _group(mut L: _Ledger, name: String) raises -> List[UInt8]:
    var b = List[UInt8]()
    _s(L, b, "PinGroup.group", name)
    _s(L, b, "PinGroup.lineage", "lin-" + name)
    _u(L, b, "PinGroup.commit_seq", 42)
    _u(L, b, "PinGroup.members", 3)
    _u(L, b, "PinGroup.members", 5)
    return b^


def _stats(mut L: _Ledger, pin: Int, rows: Int) raises -> List[UInt8]:
    var b = List[UInt8]()
    _u(L, b, "ScanStats.pin_index", UInt64(pin))
    _u(L, b, "ScanStats.row_count", UInt64(rows))
    return b^


def _shared(mut L: _Ledger, hash: Int) raises -> List[UInt8]:
    var b = List[UInt8]()
    _u(L, b, "SharedSubplan.canonical_hash", UInt64(hash))
    _m(L, b, "SharedSubplan.plan", _raw_plan(hash + 1))
    return b^


def _edge(mut L: _Ledger, base: Int) raises -> List[UInt8]:
    var b = List[UInt8]()
    _u(L, b, "ExchangeEdge.producer_segment", UInt64(base))
    _u(L, b, "ExchangeEdge.consumer_segment", UInt64(base + 1))
    _u(L, b, "ExchangeEdge.keys", UInt64(base + 2))
    _u(L, b, "ExchangeEdge.keys", UInt64(base + 3))
    _u(L, b, "ExchangeEdge.partitions", UInt64(base + 4))
    _u(L, b, "ExchangeEdge.key_groups", UInt64(base + 5))
    return b^


def _segment(mut L: _Ledger, id: Int) raises -> List[UInt8]:
    var b = List[UInt8]()
    _s(L, b, "OptimizedSegment.engine_build", "seb")
    _s(L, b, "OptimizedSegment.parent_plan_digest", "spd")
    _u(L, b, "OptimizedSegment.segment_id", UInt64(id))
    _s(L, b, "OptimizedSegment.segment_digest", "ssd")
    _m(L, b, "OptimizedSegment.needs", _needs(L, "seg"))
    _m(L, b, "OptimizedSegment.shared", _shared(L, 70))
    _m(L, b, "OptimizedSegment.scan_pins", _pin(L, "seg-pin"))
    _m(L, b, "OptimizedSegment.logical", _raw_plan(80 + id))
    _m(L, b, "OptimizedSegment.pin_groups", _group(L, "seg-group"))
    return b^


# ---- the header and its parts --------------------------------------------------------


def test_producer_stamp(mut L: _Ledger) raises:
    var b = _stamp(L, "komira/mojo-sdk")
    var m = decode_proto[ProducerStamp](b.copy())
    assert_equal(_text(m.engine_build), "eb-komira/mojo-sdk", "ProducerStamp: m.engine_build")
    assert_equal(m.optimizer_contract_version, UInt32(3), "ProducerStamp: m.optimizer_contract_version")
    assert_equal(_text(m.optimizer_config_digest), "cd-komira/mojo-sdk", "ProducerStamp: m.optimizer_config_digest")
    assert_equal(m.kind, "komira/mojo-sdk", "ProducerStamp: m.kind")
    _same(encode_proto(m), b, "ProducerStamp")


def test_needs(mut L: _Ledger) raises:
    var r = _runtime(L, "komira/python", "cp313t")
    var rn = decode_proto[RuntimeNeed](r.copy())
    assert_equal(rn.runtime, "komira/python", "RuntimeNeed: rn.runtime")
    assert_equal(rn.runtime_abi, "cp313t", "RuntimeNeed: rn.runtime_abi")
    _same(encode_proto(rn), r, "RuntimeNeed")

    var b = _needs(L, "orders")
    var m = decode_proto[DeclaredNeeds](b.copy())
    assert_equal(len(m.data_scopes), 2, "DeclaredNeeds: len(m.data_scopes)")
    assert_equal(m.data_scopes[0], "orders", "DeclaredNeeds: m.data_scopes[0]")
    assert_equal(m.data_scopes[1], "orders-2", "DeclaredNeeds: m.data_scopes[1]")
    assert_true(m.unbounded, "DeclaredNeeds: m.unbounded")
    assert_equal(len(m.runtimes), 2, "DeclaredNeeds: len(m.runtimes)")
    assert_equal(m.runtimes[0].runtime, "komira/node", "DeclaredNeeds: m.runtimes[0].runtime")
    assert_equal(m.runtimes[1].runtime_abi, "cp312", "DeclaredNeeds: m.runtimes[1].runtime_abi")
    assert_equal(len(m.udfs), 2, "DeclaredNeeds: len(m.udfs)")
    assert_equal(m.udfs[0].code.value().runtime, "komira/python", "DeclaredNeeds: m.udfs[0]")
    assert_equal(m.udfs[1].code.value().runtime, "komira/node", "DeclaredNeeds: m.udfs[1]")
    _same(encode_proto(m), b, "DeclaredNeeds")


def test_pins_and_advice(mut L: _Ledger) raises:
    var p = _pin(L, "orders")
    var pm = decode_proto[ScanPin](p.copy())
    assert_equal(pm.binding_key, "orders", "ScanPin: pm.binding_key")
    assert_equal(_text(pm.data_fingerprint), "fp-orders", "ScanPin: pm.data_fingerprint")
    _same(encode_proto(pm), p, "ScanPin")

    var g = _group(L, "graph")
    var gm = decode_proto[PinGroup](g.copy())
    assert_equal(gm.group, "graph", "PinGroup: gm.group")
    assert_equal(gm.lineage, "lin-graph", "PinGroup: gm.lineage")
    assert_equal(gm.commit_seq, UInt64(42), "PinGroup: gm.commit_seq")
    assert_equal(len(gm.members), 2, "PinGroup: len(gm.members)")
    assert_equal(gm.members[0], UInt32(3), "PinGroup: gm.members[0]")
    assert_equal(gm.members[1], UInt32(5), "PinGroup: gm.members[1]")
    _same(encode_proto(gm), g, "PinGroup")

    var s = _stats(L, 7, 6001215)
    var sm = decode_proto[ScanStats](s.copy())
    assert_equal(sm.pin_index, UInt32(7), "ScanStats: sm.pin_index")
    assert_equal(sm.row_count, UInt64(6001215), "ScanStats: sm.row_count")
    _same(encode_proto(sm), s, "ScanStats")

    var a = List[UInt8]()
    _m(L, a, "PlanAdvice.stats_basis", _stats(L, 1, 100))
    _m(L, a, "PlanAdvice.stats_basis", _stats(L, 2, 200))
    var am = decode_proto[PlanAdvice](a.copy())
    assert_equal(len(am.stats_basis), 2, "PlanAdvice: len(am.stats_basis)")
    assert_equal(am.stats_basis[0].row_count, UInt64(100), "PlanAdvice: am.stats_basis[0].row_count")
    assert_equal(am.stats_basis[1].pin_index, UInt32(2), "PlanAdvice: am.stats_basis[1].pin_index")
    _same(encode_proto(am), a, "PlanAdvice")


def test_optimized_plan(mut L: _Ledger) raises:
    var a = List[UInt8]()
    _m(L, a, "PlanAdvice.stats_basis", _stats(L, 4, 400))
    var b = List[UInt8]()
    _u(L, b, "OptimizedPlan.format_version", 2)
    assert_equal(b[0], UInt8(0x08), "OptimizedPlan field 1, varint: tag byte 0x08")
    _m(L, b, "OptimizedPlan.producer", _stamp(L, "komira/server"))
    _s(L, b, "OptimizedPlan.plan_digest", "digest")
    _s(L, b, "OptimizedPlan.recurring_signature", "recurring")
    _m(L, b, "OptimizedPlan.needs", _needs(L, "lineitem"))
    _m(L, b, "OptimizedPlan.write_target", _raw_write_target("out/q1/"))
    _m(L, b, "OptimizedPlan.advice", a)
    _s(L, b, "OptimizedPlan.body", "body-bytes")
    var m = decode_proto[OptimizedPlan](b.copy())
    assert_equal(m.format_version, UInt32(2), "OptimizedPlan: m.format_version")
    assert_equal(m.producer.value().kind, "komira/server", "OptimizedPlan: m.producer.value().kind")
    assert_equal(_text(m.plan_digest), "digest", "OptimizedPlan: m.plan_digest")
    assert_equal(_text(m.recurring_signature), "recurring", "OptimizedPlan: m.recurring_signature")
    assert_equal(m.needs.value().data_scopes[0], "lineitem", "OptimizedPlan: m.needs.value().data_scopes[0]")
    assert_equal(m.write_target.value().path, "out/q1/", "OptimizedPlan: m.write_target.value().path")
    assert_equal(m.advice.value().stats_basis[0].row_count, UInt64(400), "OptimizedPlan: m.advice")
    assert_equal(_text(m.body), "body-bytes", "OptimizedPlan: m.body")
    _same(encode_proto(m), b, "OptimizedPlan")


def test_body_and_shared(mut L: _Ledger) raises:
    var s = _shared(L, 10)
    var sm = decode_proto[SharedSubplan](s.copy())
    assert_equal(sm.canonical_hash, UInt64(10), "SharedSubplan: sm.canonical_hash")
    assert_equal(_hash(sm.plan.value()), 11, "SharedSubplan: _hash(sm.plan.value())")
    _same(encode_proto(sm), s, "SharedSubplan")

    var b = List[UInt8]()
    _m(L, b, "OptimizedPlanBody.plan", _raw_plan(20))
    _m(L, b, "OptimizedPlanBody.shared", _shared(L, 30))
    _m(L, b, "OptimizedPlanBody.scan_pins", _pin(L, "orders"))
    _m(L, b, "OptimizedPlanBody.scan_pins", _pin(L, "customers"))
    _m(L, b, "OptimizedPlanBody.pin_groups", _group(L, "graph"))
    var m = decode_proto[OptimizedPlanBody](b.copy())
    assert_equal(_hash(m.plan.value()), 20, "OptimizedPlanBody: _hash(m.plan.value())")
    assert_equal(m.shared[0].canonical_hash, UInt64(30), "OptimizedPlanBody: m.shared[0].canonical_hash")
    assert_equal(len(m.scan_pins), 2, "OptimizedPlanBody: len(m.scan_pins)")
    assert_equal(m.scan_pins[1].binding_key, "customers", "OptimizedPlanBody: m.scan_pins[1].binding_key")
    assert_equal(m.pin_groups[0].group, "graph", "OptimizedPlanBody: m.pin_groups[0].group")
    _same(encode_proto(m), b, "OptimizedPlanBody")


# ---- segments ------------------------------------------------------------------------


def test_segment(mut L: _Ledger) raises:
    var b = _segment(L, 2)
    var m = decode_proto[OptimizedSegment](b.copy())
    assert_equal(_text(m.engine_build), "seb", "OptimizedSegment: m.engine_build")
    assert_equal(_text(m.parent_plan_digest), "spd", "OptimizedSegment: m.parent_plan_digest")
    assert_equal(m.segment_id, UInt32(2), "OptimizedSegment: m.segment_id")
    assert_equal(_text(m.segment_digest), "ssd", "OptimizedSegment: m.segment_digest")
    assert_equal(m.needs.value().data_scopes[0], "seg", "OptimizedSegment: m.needs.value().data_scopes[0]")
    assert_equal(m.shared[0].canonical_hash, UInt64(70), "OptimizedSegment: m.shared[0].canonical_hash")
    assert_equal(m.scan_pins[0].binding_key, "seg-pin", "OptimizedSegment: m.scan_pins[0].binding_key")
    assert_equal(m._oneof0_case, 1, "OptimizedSegment: `logical` is the first arm of oneof body")
    assert_equal(_hash(m.logical.value()), 82, "OptimizedSegment: _hash(m.logical.value())")
    assert_equal(m.pin_groups[0].group, "seg-group", "OptimizedSegment: m.pin_groups[0].group")
    _same(encode_proto(m), b, "OptimizedSegment")


def test_dag_and_edge(mut L: _Ledger) raises:
    var e = _edge(L, 10)
    var em = decode_proto[ExchangeEdge](e.copy())
    assert_equal(em.producer_segment, UInt32(10), "ExchangeEdge: em.producer_segment")
    assert_equal(em.consumer_segment, UInt32(11), "ExchangeEdge: em.consumer_segment")
    assert_equal(len(em.keys), 2, "ExchangeEdge: len(em.keys)")
    assert_equal(em.keys[0], UInt32(12), "ExchangeEdge: em.keys[0]")
    assert_equal(em.keys[1], UInt32(13), "ExchangeEdge: em.keys[1]")
    assert_equal(em.partitions, UInt32(14), "ExchangeEdge: em.partitions")
    assert_equal(em.key_groups, UInt32(15), "ExchangeEdge: em.key_groups")
    _same(encode_proto(em), e, "ExchangeEdge")

    var b = List[UInt8]()
    _m(L, b, "OptimizedSegmentDag.segments", _segment(L, 1))
    _m(L, b, "OptimizedSegmentDag.segments", _segment(L, 3))
    _m(L, b, "OptimizedSegmentDag.edges", _edge(L, 20))
    var m = decode_proto[OptimizedSegmentDag](b.copy())
    assert_equal(len(m.segments), 2, "OptimizedSegmentDag: len(m.segments)")
    assert_equal(m.segments[1].segment_id, UInt32(3), "OptimizedSegmentDag: m.segments[1].segment_id")
    assert_equal(m.edges[0].key_groups, UInt32(25), "OptimizedSegmentDag: m.edges[0].key_groups")
    _same(encode_proto(m), b, "OptimizedSegmentDag")


# ---- held and reserved numbers ----------------------------------------------------------


def _residue[M: Serializable & ImplicitlyDestructible](b: List[UInt8]) raises -> String:
    """What a decode then re-encode of `b` as `M` keeps, canonically: empty
    when no declared field read the record."""
    var out = List[UInt8]()
    assert_true(_canon(encode_proto(decode_proto[M](b.copy())), out), "the re-encoding parses")
    return _hex(out)


def _residue_of(message: String, b: List[UInt8]) raises -> String:
    if message == "ProducerStamp":
        return _residue[ProducerStamp](b)
    elif message == "PlanAdvice":
        return _residue[PlanAdvice](b)
    elif message == "DeclaredNeeds":
        return _residue[DeclaredNeeds](b)
    elif message == "ScanPin":
        return _residue[ScanPin](b)
    elif message == "ScanStats":
        return _residue[ScanStats](b)
    elif message == "OptimizedSegment":
        return _residue[OptimizedSegment](b)
    elif message == "ExchangeEdge":
        return _residue[ExchangeEdge](b)
    raise Error("HELD names a message this test does not decode: " + message)


def _words(line: String) -> List[String]:
    var out = List[String]()
    for w in line.split(" "):
        if w.byte_length() > 0:
            out.append(String(w))
    return out^


def test_held_numbers() raises:
    """Each HELD row: a record under the number, non-zero, in the wire type
    the field will have, that no declared field of the message reads."""
    var rows = 0
    for raw in String(HELD).split("\n"):
        var line = String(String(raw).strip())
        if line.byte_length() == 0:
            continue
        var w = _words(line)
        if len(w) != 4 or (w[2] != "varint" and w[2] != "len") or (w[3] != "held" and w[3] != "reserved"):
            raise Error("malformed HELD row: `" + line + "`")
        var message = w[0].copy()
        var number = Int(w[1])
        var b = List[UInt8]()
        if w[2] == "varint":
            _raw_u(b, number, 7)
        else:
            _raw_m(b, number, _raw_plan(9))  # a non-empty payload that parses as a message too
        var what = message + " field " + String(number) + " (" + w[3] + ")"
        var residue = String("")
        try:
            residue = _residue_of(message, b)
        except e:
            raise Error(what + ": a declared field reads this number with another wire type: " + String(e))
        assert_equal(residue, "", what + ": a declared field took this number; move its row from HELD to LEDGER")
        rows += 1
    assert_true(rows > 0, "HELD has rows")


def main() raises:
    print("test_optimized_plan_field_numbers: the optimized_plan.proto census")
    var L = _Ledger(LEDGER)
    test_producer_stamp(L)
    test_needs(L)
    test_pins_and_advice(L)
    test_optimized_plan(L)
    test_body_and_shared(L)
    test_segment(L)
    test_dag_and_edge(L)
    L.check_all_hit()
    test_held_numbers()
    print("ALL optimized_plan.proto FIELD NUMBERS PINNED:", len(L.names), "fields")


# ---- THE LEDGER: every field of the 13 messages, numbers written by hand --------------
# Change a number here only with the .proto, and only one no released
# format_version carries: a released number is permanent.

comptime LEDGER = """
OptimizedPlan.format_version 1
OptimizedPlan.producer 2
OptimizedPlan.plan_digest 3
OptimizedPlan.recurring_signature 4
OptimizedPlan.needs 5
OptimizedPlan.write_target 6
OptimizedPlan.advice 7
OptimizedPlan.body 8
ProducerStamp.engine_build 1
ProducerStamp.optimizer_contract_version 2
ProducerStamp.optimizer_config_digest 3
ProducerStamp.kind 5
OptimizedPlanBody.plan 1
OptimizedPlanBody.shared 2
OptimizedPlanBody.scan_pins 3
OptimizedPlanBody.pin_groups 4
PlanAdvice.stats_basis 2
SharedSubplan.canonical_hash 1
SharedSubplan.plan 2
DeclaredNeeds.data_scopes 5
DeclaredNeeds.unbounded 8
DeclaredNeeds.runtimes 9
DeclaredNeeds.udfs 2
RuntimeNeed.runtime 1
RuntimeNeed.runtime_abi 2
ScanPin.binding_key 1
ScanPin.data_fingerprint 2
PinGroup.group 1
PinGroup.lineage 2
PinGroup.commit_seq 3
PinGroup.members 4
ScanStats.pin_index 1
ScanStats.row_count 2
OptimizedSegment.engine_build 1
OptimizedSegment.parent_plan_digest 2
OptimizedSegment.segment_id 3
OptimizedSegment.segment_digest 4
OptimizedSegment.needs 6
OptimizedSegment.shared 7
OptimizedSegment.scan_pins 8
OptimizedSegment.logical 10
OptimizedSegment.pin_groups 12
OptimizedSegmentDag.segments 1
OptimizedSegmentDag.edges 2
ExchangeEdge.producer_segment 1
ExchangeEdge.consumer_segment 2
ExchangeEdge.keys 4
ExchangeEdge.partitions 6
ExchangeEdge.key_groups 7
"""

# ---- HELD: `<Message> <number> <varint|len> <held|reserved>` -------------------------
# `held`: a number the design gives a field this stage cannot declare (the
# field and its stage are in the `held:` comment at that number in
# optimized_plan.proto), never in a `reserved` statement. `reserved`: a
# draft field never released, in its message's `reserved` statement
# (test_plan_reservations.mojo holds both to the .proto).

comptime HELD = """
ProducerStamp 4 varint reserved
PlanAdvice 1 len held
PlanAdvice 3 len held
PlanAdvice 4 len held
DeclaredNeeds 1 len held
DeclaredNeeds 3 len reserved
DeclaredNeeds 4 len held
DeclaredNeeds 6 len reserved
DeclaredNeeds 7 len reserved
DeclaredNeeds 10 len held
ScanPin 3 len held
ScanPin 4 len held
ScanPin 5 len held
ScanPin 6 len held
ScanPin 7 len held
ScanPin 8 len held
ScanPin 9 len held
ScanPin 10 len held
ScanPin 11 varint held
ScanPin 12 varint held
ScanStats 3 varint held
ScanStats 4 len held
OptimizedSegment 5 len held
OptimizedSegment 11 len reserved
ExchangeEdge 3 varint held
ExchangeEdge 5 varint held
"""
