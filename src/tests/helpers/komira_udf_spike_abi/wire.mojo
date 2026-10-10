# The fixed message header of the UDF worker protocol (komira_udf_wire.h):
# 40 little-endian bytes, `{magic, op, request_id, flags, slot,
# payload_offset, payload_len}`, and the op table that ties every request to
# one entry of the C table (docs/design/udf_runtime_interface.md section 5.2).
#
# decode_header refuses, by name: a short header (UDF_WIRE_SHORT), another
# magic (UDF_WIRE_MAGIC), an op the protocol does not define (UDF_WIRE_OP), a
# flag bit it does not define (UDF_WIRE_FLAGS), and a payload whose end
# overflows 64 bits (UDF_WIRE_PAYLOAD_RANGE).

comptime WIRE_MAGIC: UInt32 = 0x4644554B
comptime WIRE_VERSION: UInt32 = 1
comptime WIRE_HEADER_BYTES = 40

comptime WIRE_INLINE: UInt32 = 1 << 0
comptime WIRE_END: UInt32 = 1 << 1
comptime _WIRE_FLAGS_ALL: UInt32 = WIRE_INLINE | WIRE_END

comptime OP_HELLO: UInt32 = 1
comptime OP_DESCRIBE: UInt32 = 2
comptime OP_VALIDATE: UInt32 = 3
comptime OP_LOAD: UInt32 = 4
comptime OP_UNLOAD: UInt32 = 5
comptime OP_OPEN_CONTEXT: UInt32 = 6
comptime OP_CLOSE_CONTEXT: UInt32 = 7
comptime OP_OPEN_INSTANCE: UInt32 = 8
comptime OP_CLOSE_INSTANCE: UInt32 = 9
comptime OP_CALL_BATCH: UInt32 = 10
comptime OP_FRAME_OPEN: UInt32 = 11
comptime OP_FRAME_IN: UInt32 = 12
comptime OP_FRAME_OUT: UInt32 = 13
comptime OP_FRAME_CLOSE: UInt32 = 14
comptime OP_AGG_OPEN: UInt32 = 15
comptime OP_AGG_UPDATE: UInt32 = 16
comptime OP_AGG_MERGE: UInt32 = 17
comptime OP_AGG_STATE: UInt32 = 18
comptime OP_AGG_FINISH: UInt32 = 19
comptime OP_AGG_CLOSE: UInt32 = 20
comptime OP_CANCEL: UInt32 = 21
comptime OP_SHUTDOWN: UInt32 = 22
comptime OP_OK: UInt32 = 128
comptime OP_ERROR: UInt32 = 129


def op_name(op: UInt32) -> String:
    """The protocol's name of `op`, or "" for an op it does not define."""
    var names = request_op_names()
    if op >= 1 and Int(op) <= len(names):
        return names[Int(op) - 1]
    if op == OP_OK:
        return "OK"
    if op == OP_ERROR:
        return "ERROR"
    return ""


def request_op_names() -> List[String]:
    """Every request op's name; element i is op i + 1."""
    return [
        "HELLO", "DESCRIBE", "VALIDATE", "LOAD", "UNLOAD", "OPEN_CONTEXT",
        "CLOSE_CONTEXT", "OPEN_INSTANCE", "CLOSE_INSTANCE", "CALL_BATCH",
        "FRAME_OPEN", "FRAME_IN", "FRAME_OUT", "FRAME_CLOSE", "AGG_OPEN",
        "AGG_UPDATE", "AGG_MERGE", "AGG_STATE", "AGG_FINISH", "AGG_CLOSE",
        "CANCEL", "SHUTDOWN",
    ]


def reply_ops() -> List[UInt32]:
    """The replies: every request is answered by one of these."""
    return [OP_OK, OP_ERROR]


def request_op_for_entry(entry: String) -> UInt32:
    """The request op that carries table entry `entry` (a komira_udf_runtime
    field name), or 0 when the entry has no op (memory_report: a worker's
    resident memory is the authoritative number)."""
    if entry == "describe":
        return OP_DESCRIBE
    if entry == "validate":
        return OP_VALIDATE
    if entry == "load":
        return OP_LOAD
    if entry == "unload":
        return OP_UNLOAD
    if entry == "open_context":
        return OP_OPEN_CONTEXT
    if entry == "close_context":
        return OP_CLOSE_CONTEXT
    if entry == "open_instance":
        return OP_OPEN_INSTANCE
    if entry == "close_instance":
        return OP_CLOSE_INSTANCE
    if entry == "call_batch":
        return OP_CALL_BATCH
    if entry == "frame_open":
        return OP_FRAME_OPEN
    if entry == "frame_next":
        return OP_FRAME_OUT
    if entry == "frame_close":
        return OP_FRAME_CLOSE
    if entry == "agg_open":
        return OP_AGG_OPEN
    if entry == "agg_update":
        return OP_AGG_UPDATE
    if entry == "agg_merge":
        return OP_AGG_MERGE
    if entry == "agg_state":
        return OP_AGG_STATE
    if entry == "agg_finish":
        return OP_AGG_FINISH
    if entry == "agg_close":
        return OP_AGG_CLOSE
    if entry == "shutdown":
        return OP_SHUTDOWN
    return 0


def entries_without_op() -> List[String]:
    """Table entries no request carries, each for the reason in
    komira_udf_wire.h."""
    return ["memory_report"]


def requests_without_entry() -> List[UInt32]:
    """Requests that carry no table entry: HELLO (init), FRAME_IN (the `in`
    stream's get_next, worker side) and CANCEL (the per-call flag)."""
    return [OP_HELLO, OP_FRAME_IN, OP_CANCEL]


@fieldwise_init
struct WireHeader(Copyable, Movable, Writable):
    """One decoded message header."""

    var op: UInt32
    var request_id: UInt64
    var flags: UInt32
    var slot: UInt32
    var payload_offset: UInt64
    var payload_len: UInt64

    def write_to(self, mut writer: Some[Writer]):
        writer.write(
            op_name(self.op), "#", self.request_id, " flags=", self.flags, " slot=", self.slot,
            " payload=", self.payload_offset, "+", self.payload_len,
        )


def _put(mut out: List[UInt8], v: UInt64, n: Int):
    var x = v
    for _ in range(n):
        out.append(UInt8(x & 0xFF))
        x >>= 8


def _get(b: Span[UInt8, _], at: Int, n: Int) -> UInt64:
    var v: UInt64 = 0
    for k in range(n - 1, -1, -1):
        v = (v << 8) | UInt64(b[at + k])
    return v


def encode_header(h: WireHeader) -> List[UInt8]:
    """The 40 bytes of `h`, little-endian, in komira_udf_wire_header order."""
    var out = List[UInt8](capacity=WIRE_HEADER_BYTES)
    _put(out, UInt64(WIRE_MAGIC), 4)
    _put(out, UInt64(h.op), 4)
    _put(out, h.request_id, 8)
    _put(out, UInt64(h.flags), 4)
    _put(out, UInt64(h.slot), 4)
    _put(out, h.payload_offset, 8)
    _put(out, h.payload_len, 8)
    return out^


def decode_header(b: Span[UInt8, _]) raises -> WireHeader:
    """The header at the start of `b`, refused by name as the file header
    says."""
    if len(b) < WIRE_HEADER_BYTES:
        raise Error("UDF_WIRE_SHORT: " + String(len(b)) + " bytes, a header is 40")
    var magic = UInt32(_get(b, 0, 4))
    if magic != WIRE_MAGIC:
        raise Error("UDF_WIRE_MAGIC: " + String(magic))
    var op = UInt32(_get(b, 4, 4))
    if op_name(op) == "":
        raise Error("UDF_WIRE_OP: " + String(op))
    var flags = UInt32(_get(b, 16, 4))
    if flags & ~_WIRE_FLAGS_ALL != 0:
        raise Error("UDF_WIRE_FLAGS: " + String(flags))
    var off = _get(b, 24, 8)
    var n = _get(b, 32, 8)
    if off + n < off:
        raise Error("UDF_WIRE_PAYLOAD_RANGE: " + String(off) + "+" + String(n))
    return WireHeader(op, _get(b, 8, 8), flags, UInt32(_get(b, 20, 4)), off, n)
