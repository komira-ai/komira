# The worker message header (wire.mojo) and the op table's 1:1 mapping onto
# the C table.
#
# What it proves and the defect each part catches:
#   - encode then decode returns every field, and the bytes are little-endian
#     at komira_udf_wire_header's offsets (a field written at the wrong
#     offset or byte order);
#   - each refusal is raised by name: short, magic, unknown op, unknown flag,
#     payload range overflow (a decoder that accepts garbage);
#   - every table entry the C probe lists (in header order) maps to exactly
#     one request op, every request op is the image of exactly one entry or
#     is one of the three named entry-less requests, and the replies are OK
#     and ERROR only; memory_report is the only entry without an op (an entry
#     or an op added on one side only).
# Mutant planted: request_op_for_entry("agg_state") returning OP_AGG_FINISH
# (two entries on one op): red ("request AGG_STATE carries 0 entries").

from std.testing import assert_equal, assert_true

from komira_udf_spike_abi._cabi import c_layout_rows
from komira_udf_spike_abi.wire import *


def _raises_with(b: List[UInt8], name: String) raises:
    var msg = String()
    try:
        _ = decode_header(Span(b))
    except e:
        msg = String(e)
    assert_true(msg.startswith(name), "expected " + name + ", got '" + msg + "'")


def _round_trip() raises:
    var h = WireHeader(OP_CALL_BATCH, 0x0102030405060708, WIRE_INLINE | WIRE_END, 7, 4096, 65536)
    var b = encode_header(h)
    assert_equal(len(b), WIRE_HEADER_BYTES)
    assert_equal(Int(b[0]), 0x4B)  # 'K'
    assert_equal(Int(b[3]), 0x46)  # 'F'
    assert_equal(Int(b[4]), Int(OP_CALL_BATCH))
    assert_equal(Int(b[8]), 0x08)
    assert_equal(Int(b[15]), 0x01)
    assert_equal(Int(b[16]), 3)
    assert_equal(Int(b[20]), 7)
    assert_equal(Int(b[25]), 0x10)  # 4096 = 0x1000
    assert_equal(Int(b[34]), 0x01)  # 65536 = 0x10000
    var d = decode_header(Span(b))
    assert_equal(d.op, h.op)
    assert_equal(d.request_id, h.request_id)
    assert_equal(d.flags, h.flags)
    assert_equal(d.slot, h.slot)
    assert_equal(d.payload_offset, h.payload_offset)
    assert_equal(d.payload_len, h.payload_len)
    assert_equal(String(d), "CALL_BATCH#72623859790382856 flags=3 slot=7 payload=4096+65536")


def _refusals() raises:
    var good = encode_header(WireHeader(OP_OK, 1, 0, 0, 0, 0))
    _ = decode_header(Span(good))
    var short = good.copy()
    _ = short.pop()
    _raises_with(short, "UDF_WIRE_SHORT")
    var magic = good.copy()
    magic[0] = 0x4C
    _raises_with(magic, "UDF_WIRE_MAGIC")
    var op = good.copy()
    op[4] = 23
    _raises_with(op, "UDF_WIRE_OP")
    var op0 = good.copy()
    op0[4] = 0
    _raises_with(op0, "UDF_WIRE_OP")
    # The edges of the two op ranges: 1 to 22 (requests), 128 and 129 (replies).
    for edge in [1, 22, 128, 129]:
        var e = good.copy()
        e[4] = UInt8(edge)
        assert_equal(Int(decode_header(Span(e)).op), edge)
    for gap in [127, 130]:
        var e = good.copy()
        e[4] = UInt8(gap)
        _raises_with(e, "UDF_WIRE_OP")
    var flags = good.copy()
    flags[16] = 4
    _raises_with(flags, "UDF_WIRE_FLAGS")
    var rng = encode_header(WireHeader(OP_FRAME_IN, 1, 0, 0, 0xFFFFFFFFFFFFFFF0, 0x20))
    _raises_with(rng, "UDF_WIRE_PAYLOAD_RANGE")
    var edge = encode_header(WireHeader(OP_FRAME_IN, 1, 0, 0, 0xFFFFFFFFFFFFFFF0, 0x0F))
    _ = decode_header(Span(edge))


def _bijection() raises:
    var c = c_layout_rows()
    var entries = List[String]()
    for i in range(len(c.names)):
        if c.names[i].startswith("slot "):
            entries.append(String(c.names[i][byte=5:]))
    assert_equal(len(entries), 20, "table entries in the C probe")
    var names = request_op_names()
    var hits = List[Int]()
    for _ in range(len(names) + 1):
        hits.append(0)
    var without = entries_without_op()
    for i in range(len(entries)):
        var op = request_op_for_entry(entries[i])
        if op == 0:
            var listed = False
            for k in range(len(without)):
                if without[k] == entries[i]:
                    listed = True
            assert_true(listed, "entry " + entries[i] + " has no op and is not listed as such")
            continue
        assert_true(Int(op) >= 1 and Int(op) <= len(names), "entry " + entries[i] + " maps to a reply")
        hits[Int(op)] += 1
    var free = requests_without_entry()
    for op in range(1, len(names) + 1):
        var expected = 1
        for k in range(len(free)):
            if Int(free[k]) == op:
                expected = 0
        assert_equal(hits[op], expected, "request " + names[op - 1] + " carries " + String(hits[op]) + " entries")
    assert_equal(len(without), 1)
    var replies = reply_ops()
    assert_equal(len(replies), 2)
    assert_equal(op_name(replies[0]), "OK")
    assert_equal(op_name(replies[1]), "ERROR")
    assert_equal(op_name(130), "")


def main() raises:
    _round_trip()
    _refusals()
    _bijection()
    print("test_wire: ok")
