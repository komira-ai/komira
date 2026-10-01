# =============================================================================
# komira_log.engine.log_event_record — the POD on-ring binary record (P2a).
# =============================================================================
#
# The fixed-stride POD record that rides the per-core SPSC ring: the
# `[ts, site_id, n_args, tags, arg-blob]` shape as a fixed-stride struct so the ring is a `Slab[LogEventRecord]`
# (exactly `SpanPacketRingBuffer`'s `Slab[SpanPacket]`), keeping the SPSC math
# unchanged and the POD invariant intact.
#
# Layout:
#   kind         UInt8     # 0=LOG, 1=SPAN_OPEN, 2=SPAN_CLOSE,
#                          #   3=METRIC (the unification
#                          #   discriminant — P2a only exercises LOG, but the
#                          #   field is designed for both record families).
#   level        UInt8     # LOG severity (LEVEL_*); span severity for spans.
#   flags        UInt16    # bit0 = arg-blob spilled to the ring arena
#                          #   (HAS_ARG_OVERFLOW); other bits reserved.
#   site_id      UInt32    # comptime FNV-1a digest (the dictionary key).
#   n_args       UInt8     # number of args encoded into the blob.
#   module_id    UInt32    # comptime FNV-1a digest of the module StringLiteral
#                          #   (the decoder maps it back to the module text).
#   timestamp    UInt64    # RAW cycle-counter ticks. The drain
#                          #   converts ticks→wall-time via the calibration
#                          #   anchor; ordering keys on raw ticks directly.
#   corr_id      UInt64    # span_id (spans) / log↔trace correlation (logs).
#   arg_inline_len UInt16  # bytes used of `arg_blob` when NOT spilled.
#   arg_off      UInt32    # ring-arena offset when spilled (flags bit0 set).
#   arg_len      UInt32    # ring-arena length when spilled.
#   arg_blob     InlineArray[UInt8, ARG_INLINE_BYTES]  # SSO-style inline args.
#
# Encapsulation:
#   - EVERY field is a primitive scalar or a fixed-size InlineArray[UInt8, N].
#     NO `List`, `String`, `OwnedPointer`, `ArcPointer`, or wildcard-origin
#     field. This is the stale-pointer-safe shape: the record can be stored in a
#     byte-/Slab-backed ring with ZERO heap-owning inner field to dangle.
#   - Long string args do NOT live in the record. They spill to a per-RING
#     arena (a field of the ring, not of the record) via the (arg_off, arg_len)
#     handle. The handle is plain POD; the arena's lifetime is the ring's.
#   - A compile-time `size_of` guard (mirrors `_SPAN_PACKET_SIZE_GUARD`) pins
#     the POD-ness; the unit test asserts the record carries no heap field by
#     round-tripping a default-constructed record through a `Slab`.
# =============================================================================

from std.sys import size_of


# -----------------------------------------------------------------------------
# Record-kind discriminant (the unification discriminant).
# P2a only emits LOG; the SPAN_* values are reserved so the trace facade
# (P4) rides the same record without a format change.
# -----------------------------------------------------------------------------

comptime REC_LOG: UInt8 = UInt8(0)
comptime REC_SPAN_OPEN: UInt8 = UInt8(1)
comptime REC_SPAN_CLOSE: UInt8 = UInt8(2)
# A METRIC point. Same ring, same drains, zero new transport: the
# field assignment (`site_id`=name_id, `module_id`=scope_id, `corr_id`=
# exemplar_span_id, `n_args`=0, the 20-byte `arg_blob` header) lives in
# `metric_emit.mojo`, which is the ONLY writer of this kind.
#
# ⚠ ADDING A KIND HERE IS HALF A CHANGE. The other half is an arm at EVERY ring
# consumer — there are SIX, across three modules (`shared_engine` x3,
# `drain` x2, `span_drain` x1) — because the closed default REFUSES what no arm
# claims. A kind added here and nowhere else is a kind that is counted and
# dropped, which is the fail-closed direction but is not a feature.
comptime REC_METRIC: UInt8 = UInt8(3)


# -----------------------------------------------------------------------------
# Flag bits.
# -----------------------------------------------------------------------------

comptime FLAG_HAS_ARG_OVERFLOW: UInt16 = UInt16(1)  # arg-blob spilled to arena


# -----------------------------------------------------------------------------
# Inline arg-blob capacity. Args (scalar bytes + short-string payloads) up to
# this many bytes live in the record; longer blobs spill to the ring arena.
# 48 bytes covers ~6 scalar args or a short interpolated arg set inline.
# -----------------------------------------------------------------------------

comptime ARG_INLINE_BYTES: Int = 48


struct LogEventRecord(
    Copyable, Movable, Deinitable
):
    # MOJO-1.0.0: `ImplicitlyCopyable` DROPPED, `Copyable` kept. 1.0.0 makes
    # `InlineArray` non-implicitly-copyable, and a struct owning one cannot
    # synthesise an implicit copy ctor -- there is no manual override (a
    # hand-written `__copyinit__` is not consulted). Copies of this POD
    # record are now spelled `.copy()`; that is the SAME memcpy b2 emitted
    # implicitly, so codegen and cost are unchanged.
    """The POD on-ring record — fixed stride, no heap-owning field.

    Crosses the producer→drain boundary by value (a single fixed-stride
    copy). Every field is a primitive scalar or a fixed `InlineArray[UInt8]`.
    The arg-blob is inline up to `ARG_INLINE_BYTES`; longer blobs reference
    the ring arena via (arg_off, arg_len) with `FLAG_HAS_ARG_OVERFLOW` set.
    """

    var kind: UInt8
    var level: UInt8
    var flags: UInt16
    var site_id: UInt32
    var n_args: UInt8
    var _pad0: Array[UInt8, 3]
    var module_id: UInt32
    var timestamp: UInt64
    var corr_id: UInt64
    var arg_inline_len: UInt16
    var _pad1: Array[UInt8, 2]
    var arg_off: UInt32
    var arg_len: UInt32
    var arg_blob: Array[UInt8, ARG_INLINE_BYTES]

    def __init__(out self):
        self.kind = REC_LOG
        self.level = UInt8(0)
        self.flags = UInt16(0)
        self.site_id = UInt32(0)
        self.n_args = UInt8(0)
        self._pad0 = Array[UInt8, 3](fill=UInt8(0))
        self.module_id = UInt32(0)
        self.timestamp = UInt64(0)
        self.corr_id = UInt64(0)
        self.arg_inline_len = UInt16(0)
        self._pad1 = Array[UInt8, 2](fill=UInt8(0))
        self.arg_off = UInt32(0)
        self.arg_len = UInt32(0)
        self.arg_blob = Array[UInt8, ARG_INLINE_BYTES](fill=UInt8(0))

    @always_inline
    def has_arg_overflow(self) -> Bool:
        return (self.flags & FLAG_HAS_ARG_OVERFLOW) != 0


# -----------------------------------------------------------------------------
# ArgBlobWriter — the NanoLog "no-alloc-on-the-hot-path" arg sink.
# -----------------------------------------------------------------------------
#
# The P2b emit fast path encodes args DIRECTLY into the record's inline
# `arg_blob: InlineArray[UInt8, ARG_INLINE_BYTES]` with ZERO heap allocation for
# the common case (≤48 encoded bytes — ~6 scalar args or a short string set).
# Only when the encoded args exceed the inline capacity does the writer spill
# the OVERFLOW into a function-local `List[UInt8]` (the long-string path); the
# facade then arena-appends just the overflow-tail.
#
# The writer wraps a `mut` ref to the record's `arg_blob` (NO pointer crosses an
# API — the facade constructs the writer over `rec.arg_blob` in-method) + an
# inline cursor + an overflow List that stays EMPTY on the common path. The wire
# format is byte-identical to the prior `List[UInt8]` encode (same tag table +
# raw little-endian bytes), so the drain decoder is unchanged and the round-trip
# render is byte-for-byte the same.
#
# Encapsulation: `ArgBlobWriter` is a function-local value the facade
# constructs over the on-stack `rec.arg_blob` (via a `mut` ref param). It is
# NEVER stored in a slab or a struct field — it lives only for the encode call.
# The one `UnsafePointer` it holds is a `mut`-ref to the record's own inline
# array, with a concrete origin, confined to this module (the SAFETY note on the
# field). No wildcard origin, no `unsafe_from_address`, no heap-owning field.
# -----------------------------------------------------------------------------


struct ArgBlobWriter[origin: Origin[mut=True]](Movable):
    """Encodes arg bytes directly into a record's inline `arg_blob`, spilling
    only the overflow tail to a function-local `List` when the encoded length
    exceeds `ARG_INLINE_BYTES`. Common path = zero heap allocation."""

    # SAFETY: a concrete-origin `mut` reference to the record's own
    # `InlineArray[UInt8, ARG_INLINE_BYTES]`. The writer is a function-local
    # value the facade constructs over an on-stack record's `arg_blob`; it is
    # never stored, never crosses a module boundary, and the origin ties its
    # lifetime to that record. Not a wildcard origin.
    var _inline: UnsafePointer[UInt8, Self.origin]
    # Total bytes written so far (across inline + overflow). The inline blob
    # holds bytes [0, min(pos, ARG_INLINE_BYTES)); overflow holds the rest.
    var _pos: Int
    # The overflow tail — stays EMPTY (no alloc) on the common ≤48-byte path.
    var _overflow: List[UInt8]

    @always_inline
    def __init__(
        out self, ref [Self.origin] blob: Array[UInt8, ARG_INLINE_BYTES]
    ):
        self._inline = UnsafePointer(to=blob[0])
        self._pos = 0
        self._overflow = List[UInt8]()

    @always_inline
    def append(mut self, b: UInt8):
        if self._pos < ARG_INLINE_BYTES:
            self._inline[self._pos] = b
        else:
            self._overflow.append(b)
        self._pos += 1

    @always_inline
    def put_u64(mut self, v: UInt64):
        for i in range(8):
            self.append(UInt8((v >> (UInt64(i) * 8)) & 0xFF))

    @always_inline
    def total_len(self) -> Int:
        return self._pos

    @always_inline
    def inline_len(self) -> Int:
        return self._pos if self._pos < ARG_INLINE_BYTES else ARG_INLINE_BYTES

    @always_inline
    def overflowed(self) -> Bool:
        return self._pos > ARG_INLINE_BYTES

    def full_blob(self) -> List[UInt8]:
        """Reconstruct the COMPLETE encoded blob (inline 48 bytes + overflow
        tail) for the RARE spill path. The drain reads the whole blob from the
        arena when `FLAG_HAS_ARG_OVERFLOW` is set, so the spilled bytes must be
        the full sequence, not just the tail. Only called when `overflowed()`
        is True (long-string args) — never on the common zero-alloc path."""
        var out = List[UInt8]()
        for i in range(ARG_INLINE_BYTES):
            out.append(self._inline[i])
        for i in range(len(self._overflow)):
            out.append(self._overflow[i])
        return out^


# Compile-time POD-size guard (mirrors `_SPAN_PACKET_SIZE_GUARD`,
# span_packet.mojo). The unit test asserts this is a fixed, non-zero
# stride and that a record round-trips through a `Slab[LogEventRecord]`.
comptime _LOG_EVENT_RECORD_SIZE_GUARD: Int = size_of[LogEventRecord]()
