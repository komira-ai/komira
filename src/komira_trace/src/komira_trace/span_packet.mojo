# =============================================================================
# span_packet.mojo — compact open/close packets for the hot path
# =============================================================================
#
# Hot-path wire shape. Writing the full 192-byte `SpanRecord` per
# start_span / end_span costs a few hundred ns/op at the producer site,
# dominated by the InlineArray + slot copy.
#
# Split the wire shape: producers emit fixed-32-byte `SpanPacket`s (one
# OPEN, one CLOSE per span); the drain joins matching pairs by `span_id`
# at JSONL render time and reconstructs the full `SpanRecord` schema
# for downstream consumers (an offline trace analyzer).
#
# Layout (POD by construction):
#   kind       UInt8     (PACKET_OPEN=0, PACKET_CLOSE=1)
#   _pad0      InlineArray[UInt8, 3]
#   name_id    UInt32    (FNV-1a hash; OPEN only — CLOSE leaves zero)
#   span_id    UInt64
#   parent_id  UInt64    (OPEN only — CLOSE leaves zero)
#   ts_ns      UInt64    (start_ns on OPEN, end_ns on CLOSE)
#   worker_id  UInt16
#   flags      UInt16    (low 8 bits == SPAN_FLAG_*; SPAN_STATUS sits in `kind`)
#   trace_id_lo UInt32   (low 32 bits of trace_id; full 16-byte trace_id is
#                         reconstructed by the drain from a per-process
#                         lookup at the analyzer side. The tracer uses sequential
#                         trace_ids whose low 32 bits are unique within the
#                         analyzer window.)
# Total: 1 + 3 + 4 + 8 + 8 + 8 + 2 + 2 + 4 = 40 bytes (compiler may pad to
# 48; either way the 192→48 reduction is the load-bearing win).
#
# Why we keep `SpanRecord` for the joined output: the JSONL schema
# is the contract an offline trace analyzer consumes; that schema
# carries `start_ns`, `end_ns`, full `trace_id`, links, etc. on a
# per-span basis. The drain joins OPEN+CLOSE packets back into a
# `SpanRecord` before formatting JSONL. Joining is a small dict keyed
# by span_id and is off the hot path.
# =============================================================================

from std.sys import size_of


# Packet kind discriminant — the first byte of every packet.
comptime PACKET_OPEN: UInt8 = UInt8(0)
comptime PACKET_CLOSE: UInt8 = UInt8(1)


struct SpanPacket(Copyable, Movable, Deinitable):
    # MOJO-1.0.0: `ImplicitlyCopyable` DROPPED, `Copyable` kept. 1.0.0 makes
    # `InlineArray` non-implicitly-copyable, and a struct owning one cannot
    # synthesise an implicit copy ctor -- there is no manual override (a
    # hand-written `__copyinit__` is not consulted). Copies of this POD
    # record are now spelled `.copy()`; that is the SAME memcpy an implicit copy emitted
    # implicitly, so codegen and cost are unchanged.
    """Compact open/close packet — POD by construction.

    Crosses the worker → drain boundary. Every field is a primitive
    scalar or fixed-size InlineArray of UInt8. NO heap-owning fields.
    """

    var kind: UInt8
    var _pad0: Array[UInt8, 3]
    var name_id: UInt32
    var span_id: UInt64
    var parent_id: UInt64
    var ts_ns: UInt64
    var worker_id: UInt16
    var flags: UInt16
    var trace_id_lo: UInt32

    def __init__(out self):
        self.kind = PACKET_OPEN
        self._pad0 = Array[UInt8, 3](fill=UInt8(0))
        self.name_id = UInt32(0)
        self.span_id = UInt64(0)
        self.parent_id = UInt64(0)
        self.ts_ns = UInt64(0)
        self.worker_id = UInt16(0)
        self.flags = UInt16(0)
        self.trace_id_lo = UInt32(0)

    @staticmethod
    @always_inline
    def open(
        span_id: UInt64,
        parent_id: UInt64,
        name_id: UInt32,
        ts_ns: UInt64,
        worker_id: UInt16,
        flags: UInt16,
        trace_id_lo: UInt32,
    ) -> SpanPacket:
        var p = SpanPacket()
        p.kind = PACKET_OPEN
        p.name_id = name_id
        p.span_id = span_id
        p.parent_id = parent_id
        p.ts_ns = ts_ns
        p.worker_id = worker_id
        p.flags = flags
        p.trace_id_lo = trace_id_lo
        return p^

    @staticmethod
    @always_inline
    def close(
        span_id: UInt64,
        ts_ns: UInt64,
        worker_id: UInt16,
    ) -> SpanPacket:
        var p = SpanPacket()
        p.kind = PACKET_CLOSE
        p.span_id = span_id
        p.ts_ns = ts_ns
        p.worker_id = worker_id
        return p^


# Compile-time POD-size guard. Caught by `tests/test_span_record_pod.mojo`.
comptime _SPAN_PACKET_SIZE_GUARD: Int = size_of[SpanPacket]()
