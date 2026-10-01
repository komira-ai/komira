# =============================================================================
# komira_log.engine.record_ring — per-core SPSC ring of LogEventRecords (P2a).
# =============================================================================
#
# Generalizes `komira_obs.SpanPacketRingBuffer` (packet_ring.mojo) from
# `Slab[SpanPacket]` to `Slab[LogEventRecord]`. Same SPSC invariant, same
# cacheline-padded head/tail, same BLOCK/DROP backpressure. The ring logic is
# intentionally a parallel of the obs ring at the slot-type boundary only —
# Mojo cannot express a generic `Ring[T]` over an Atomic-bearing non-Movable
# struct (the obs ring documents the same constraint).
#
# Per-core means: one ring per worker slot, touched only by its owning core —
# produced into during work, drained by the SAME core when idle. The SPSC
# single-producer-single-consumer invariant therefore holds by construction
# (no second thread ever touches a ring). P2a exercises one ring
# at a time with a producer-then-consumer round-trip; P2b weaves the drain into
# the worker loop.
#
# String-arg arena: long string args spill out of the record's inline blob into
# a per-RING `List[UInt8]` arena (a field of the ring, not of the POD record).
# The record carries only an (arg_off, arg_len) handle. The arena is owned by
# the ring: the Slab stores only POD records; the heap-owning
# arena is the ring's own List field, never byte-slab-stored.
#
# Encapsulation: `UnsafePointer` arithmetic is the Slab's (we only index
# via `get_mut_interior`); no `UnsafePointer` crosses this module's public API.
# No wildcard-origin field. The arena is a plain owned `List[UInt8]`.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.memory import UnsafePointer

from komira_core.collections import Slab

from komira_obs.ring_buffer import (
    CACHELINE_BYTES,
    DEFAULT_RING_CAPACITY,
    OVERFLOW_BLOCK,
    OVERFLOW_DROP,
)

from komira_log.engine.log_event_record import (
    LogEventRecord,
    FLAG_HAS_ARG_OVERFLOW,
)


struct LogRecordRing(Deinitable):
    """Per-worker SPSC ring of `LogEventRecord`s + a string-arg spill arena.

    Mirrors `SpanPacketRingBuffer`; see `ring_buffer.mojo` for the full SPSC
    invariant + ordering rationale. The producing core writes records (and
    spills long strings into `_arena`); the same core, when idle, drains.
    """

    var _capacity: Int
    # LAZY SLOTS. `_capacity` is the LOGICAL capacity from the
    # moment of construction — every index/mask/backpressure computation below
    # reads it and is unchanged. `_slots` is the BACKING STORE, allocated on
    # the FIRST `try_push`, not at construction.
    #
    # WHY: `EngineContext` builds N+1 of these per process unconditionally and
    # the docstring above already says "never emitted unless explicitly
    # enabled — zero ring traffic by default". With dozens of workers the
    # eager form would `memset` many MiB of slots that never receive a record,
    # paying milliseconds and thousands of first-touch faults at startup.
    #
    # SPSC SAFETY: the producer is the only writer of the `_slots` HANDLE, and
    # it writes it exactly once, before the `_tail.fetch_add` that publishes the
    # first record. `try_pop` touches `_slots` only when `tail > head`, which it
    # learns from a seq_cst `_tail.load()`; that load synchronizes-with the
    # producer's `fetch_add`, so the handle write is visible before any consumer
    # dereference. Subsequent pushes never touch the handle again.
    var _slots: Slab[LogEventRecord]
    var _head: AtomicI64
    var _head_pad: Array[UInt8, CACHELINE_BYTES - 8]
    var _tail: AtomicI64
    var _tail_pad: Array[UInt8, CACHELINE_BYTES - 8]
    var _overflow_dropped: AtomicI64
    var _overflow_blocked: AtomicI64
    # UNKNOWN-KIND DROPS. Every drain over this ring routes by
    # `LogEventRecord.kind`. A kind no drain recognises is REFUSED rather than
    # decoded as a log record, and the refusal is counted HERE — on the ring —
    # because the six consumers of this ring are split across three modules
    # (`shared_engine`, `span_drain`, `drain`), three of them free functions
    # with no engine to hold a counter. Every one of them has the ring in hand.
    #
    # WHY REFUSING BEATS DECODING: `decode_one` reads `rec.n_args` and walks the
    # inline blob as an arg table. On a record that is not a log record those
    # bytes are not an arg table, and the site lookup then misses, rendering
    # `"<unknown site N>"` into whatever the drain feeds. On the deployed
    # indexing path that is a row written into a production log index.
    var _unknown_kind_dropped: AtomicI64
    # SPAN RECORDS THAT REACHED A DRAIN AND PRODUCED NOTHING. Distinct
    # from the counter above in BOTH directions: a span is a kind every drain
    # RECOGNISES (so it is not an unknown-kind refusal), and it is not an
    # overflow drop (it was pushed, popped and routed). It is counted here for
    # the SAME reason `_unknown_kind_dropped` is — the consumers of this ring
    # are split across three modules and two of them are free functions with no
    # engine to hold a counter, but every one of them has the ring in hand.
    #
    # THE TWO CAUSES, both of which are policy rather than error:
    #   1. `drain_to_lines` / `drain_to_views` (the bare free fns) have no
    #      `OpenSpanTable`, so they cannot pair an OPEN with a CLOSE and skip
    #      both records. Uncounted, that skip would be SILENT.
    #   2. An engine drain completed a span but had nowhere to put it —
    #      `_capture_spans` is off on a drain that has no sink, or the retained
    #      buffer is at `span_buf_max`.
    #
    # NON-ZERO MEANS TRACE DATA WAS LOST. That is acceptable when nothing is
    # consuming traces and intolerable when something is; the number is the
    # only way to tell the two apart from outside the process.
    var _span_record_dropped: AtomicI64
    # METRIC RECORDS THAT REACHED A DRAIN AND PRODUCED NO POINT. The third
    # member of the same family, and distinct from BOTH of the two above for the
    # same two reasons: REC_METRIC is a kind every drain now RECOGNISES (so it is
    # not an unknown-kind refusal), and the record was pushed, popped and routed
    # (so it is not an overflow drop). It lives on the ring for the reason the
    # other two do -- the six consumers span three modules and three of them are
    # free functions with no engine to hold a counter.
    #
    # THE THREE CAUSES, all of them policy rather than error:
    #   1. `drain_to_lines` / `drain_to_views` (the bare free fns) return
    #      `List[String]` / `List[LogRecordView]`, and a metric point is neither.
    #      They skip it, exactly as they skip a span.
    #   2. An engine drain decoded a point but had nowhere to put it --
    #      `_capture_metrics` is off, or `_metric_buf` is at `metric_buf_max`.
    #   3. The record was NOT DECODABLE: it carries `FLAG_HAS_ARG_OVERFLOW` (the
    #      histogram arena payload -- a decoded form for it EXISTS,
    #      `HistogramPoint`, but there is no ring codec for it) or a truncated
    #      header. Refused, never half-decoded.
    #
    # ⚠ THE ASYMMETRY WITH SPANS IS DELIBERATE AND IS THE PAYLOAD TYPE'S FAULT.
    # When span capture is off, `drain_worker` writes the span to its SINK,
    # because a span's egress form is a rendered line. A `MetricPoint` is POD and
    # rendering it at the drain would be a dead end, so
    # `drain_worker` has NO fallback destination for a metric and drops it here.
    var _metric_record_dropped: AtomicI64
    var _overflow_policy: UInt8
    # String-arg spill arena. Owned by the ring (a plain List). Append-only
    # within a drain cycle; the drain calls `reset_arena()` after consuming.
    var _arena: List[UInt8]

    def __init__(
        out self,
        capacity: Int = DEFAULT_RING_CAPACITY,
        overflow_policy: UInt8 = OVERFLOW_BLOCK,
    ) raises:
        if capacity <= 0:
            raise Error("LogRecordRing: capacity must be > 0")
        var cap = 1
        while cap < capacity:
            cap = cap * 2
        self._capacity = cap
        # Deferred: allocated by `_ensure_slots` on the first `try_push`.
        self._slots = Slab[LogEventRecord]()
        self._head = AtomicI64(Int64(0))
        self._head_pad = Array[UInt8, CACHELINE_BYTES - 8](fill=UInt8(0))
        self._tail = AtomicI64(Int64(0))
        self._tail_pad = Array[UInt8, CACHELINE_BYTES - 8](fill=UInt8(0))
        self._overflow_dropped = AtomicI64(Int64(0))
        self._overflow_blocked = AtomicI64(Int64(0))
        self._unknown_kind_dropped = AtomicI64(Int64(0))
        self._span_record_dropped = AtomicI64(Int64(0))
        self._metric_record_dropped = AtomicI64(Int64(0))
        self._overflow_policy = overflow_policy
        self._arena = List[UInt8]()

    @staticmethod
    def init_in_place[o: Origin[mut=True], //](
        ptr: UnsafePointer[LogRecordRing, o],
        capacity: Int = DEFAULT_RING_CAPACITY,
        overflow_policy: UInt8 = OVERFLOW_BLOCK,
    ) raises:
        """In-place init for a `Slab[LogRecordRing]` slot (the per-core engine
        owns N rings in a Slab — `LogRecordRing` is non-Movable, so it cannot
        live in a `List`). Parallels `SpanPacketRingBuffer.init_in_place`.

        SAFETY (init-only): `ptr` points at zero-initialized
        bytes from `Slab.create_prefilled`; the slot is uninitialized BEFORE
        this call and fully initialized AFTER. The pointer does not
        propagate to live data — it is confined to this init site.

        The origin is a PARAMETER, not a wildcard: Mojo does not coerce the
        concrete origin that `UnsafePointer(to=...)` yields into a wildcard,
        and the caller's Slab-slot origin is exactly what should be tracked
        here. `o` is inferred at the call site.
        """
        if capacity <= 0:
            raise Error("LogRecordRing.init_in_place: capacity must be > 0")
        var cap = 1
        while cap < capacity:
            cap = cap * 2
        ptr[]._capacity = cap
        # Deferred: allocated by `_ensure_slots` on the first `try_push`.
        ptr[]._slots = Slab[LogEventRecord]()
        ptr[]._head = AtomicI64(Int64(0))
        ptr[]._head_pad = Array[UInt8, CACHELINE_BYTES - 8](
            fill=UInt8(0)
        )
        ptr[]._tail = AtomicI64(Int64(0))
        ptr[]._tail_pad = Array[UInt8, CACHELINE_BYTES - 8](
            fill=UInt8(0)
        )
        ptr[]._overflow_dropped = AtomicI64(Int64(0))
        ptr[]._overflow_blocked = AtomicI64(Int64(0))
        ptr[]._unknown_kind_dropped = AtomicI64(Int64(0))
        ptr[]._span_record_dropped = AtomicI64(Int64(0))
        ptr[]._metric_record_dropped = AtomicI64(Int64(0))
        ptr[]._overflow_policy = overflow_policy
        ptr[]._arena = List[UInt8]()

    @always_inline
    def capacity(self) -> Int:
        return self._capacity

    @always_inline
    def slots_allocated(self) -> Bool:
        """True once the backing store has been materialized (first push).

        Introspection for the lazy-slots guard — a freshly constructed ring
        reports False and still reports `capacity()` as its logical capacity.
        """
        return len(self._slots) == self._capacity

    @always_inline
    def _ensure_slots(mut self) -> None:
        """Materialize the backing store. Idempotent; producer-side only.

        SAFETY (SPSC): only `try_push` calls this, and `try_push` has exactly
        one producer by the ring's contract, so the handle write races nothing.
        See the `_slots` field comment for the consumer-visibility argument.
        """
        if len(self._slots) != self._capacity:
            self._slots = Slab[LogEventRecord].create_prefilled(self._capacity)

    @always_inline
    def overflow_dropped_count(self) -> Int64:
        return self._overflow_dropped.load()

    @always_inline
    def overflow_blocked_count(self) -> Int64:
        return self._overflow_blocked.load()

    @always_inline
    def unknown_kind_dropped_count(self) -> Int64:
        """Records this ring's drains refused because no arm recognised their
        `kind`. A non-zero value means a producer is emitting a record kind the
        drains predate — the record was DROPPED, not rendered."""
        return self._unknown_kind_dropped.load()

    @always_inline
    def note_unknown_kind(mut self) -> None:
        """Count one refused record. Called by the closed default arm of every
        drain over this ring. DEGRADE, DO NOT ABORT: the drain skips the record
        and keeps going, exactly as it does for a corrupt arg header — a logger
        may not take down the process it instruments."""
        _ = self._unknown_kind_dropped.fetch_add(Int64(1))

    @always_inline
    def span_record_dropped_count(self) -> Int64:
        """SPAN_OPEN / SPAN_CLOSE records this ring's drains consumed without
        producing a span. See `_span_record_dropped` for the two causes."""
        return self._span_record_dropped.load()

    @always_inline
    def note_span_record_dropped(mut self) -> None:
        """Count one span record that reached a drain and produced no span.
        DEGRADE, DO NOT ABORT — same contract as `note_unknown_kind`."""
        _ = self._span_record_dropped.fetch_add(Int64(1))

    @always_inline
    def metric_record_dropped_count(self) -> Int64:
        """REC_METRIC records this ring's drains consumed without producing a
        `MetricPoint`. See `_metric_record_dropped` for the three causes.

        ⚠ NON-ZERO MEANS METRIC DATA WAS LOST, and its ZERO is the only evidence
        from outside the process that the metric path is intact. A metrics
        pipeline that silently drops is worse than one that is off: the graph
        still draws, and the missing points read as real."""
        return self._metric_record_dropped.load()

    @always_inline
    def note_metric_record_dropped(mut self) -> None:
        """Count one metric record that reached a drain and produced no point.
        DEGRADE, DO NOT ABORT — same contract as `note_unknown_kind`."""
        _ = self._metric_record_dropped.fetch_add(Int64(1))

    # -------------------------------------------------------------------------
    # Producer-side arena spill. Returns the (offset, len) handle the record
    # carries. Append-only; the bytes survive until the drain `reset_arena()`s.
    # -------------------------------------------------------------------------
    def arena_append(
        mut self, bytes: List[UInt8]
    ) -> Tuple[UInt32, UInt32]:
        var off = len(self._arena)
        for i in range(len(bytes)):
            self._arena.append(bytes[i])
        return Tuple[UInt32, UInt32](UInt32(off), UInt32(len(bytes)))

    def arena_slice(self, off: UInt32, length: UInt32) -> List[UInt8]:
        """Drain-side read of a spilled arg blob, CLAMPED to the arena.

        `off`/`length` arrive from a record HEADER the drain read back out of a
        ring slot; this function owns `_arena` and is therefore the only place
        that can tell whether they describe bytes that exist. Indexed unchecked,
        a record whose bytes were wrong would take an out-of-bounds
        `List.__getitem__` and ABORT the process — in a logger, linked into
        every service. A span that is not there yields the bytes that are
        (possibly none) and the decode renders a short line.

        This is not the producer's contract getting looser: `arena_append` is
        the only writer, it returns the handle it just wrote, and a well-formed
        record is unaffected. It is the drain refusing to trust bytes it did not
        write. Cost on the spill path: two `Int` compares before a loop that was
        already allocating; the inline path never calls this at all.
        """
        var out = List[UInt8]()
        var have = len(self._arena)
        var o = Int(off)
        if o < 0 or o >= have:
            return out^
        var n = Int(length)
        if n > have - o:
            n = have - o
        for i in range(n):
            out.append(self._arena[o + i])
        return out^

    def reset_arena(mut self):
        """Drop spilled bytes after a drain cycle has consumed them. Only safe
        when the ring is empty (head == tail) — the drain calls this at the end
        of a full drain pass."""
        self._arena.clear()

    # -------------------------------------------------------------------------
    # Producer-side push. Backpressure mirrors the obs ring verbatim.
    # -------------------------------------------------------------------------
    def try_push(mut self, record: LogEventRecord) -> Bool:
        """Write `record` into the ring. Returns True on success, False if the
        ring is full and policy is DROP. Under BLOCK, spins until a slot frees.
        """
        var tail = self._tail.load()
        var head = self._head.load()
        var capacity_i64 = Int64(self._capacity)
        var occupied = tail - head

        if occupied >= capacity_i64:
            if self._overflow_policy == OVERFLOW_DROP:
                _ = self._overflow_dropped.fetch_add(Int64(1))
                return False
            _ = self._overflow_blocked.fetch_add(Int64(1))
            while True:
                head = self._head.load()
                if tail - head < capacity_i64:
                    break

        self._ensure_slots()
        var idx = Int(tail) & (self._capacity - 1)
        ref slot = self._slots.get_mut_interior(idx)
        slot = record.copy()

        _ = self._tail.fetch_add(Int64(1))
        return True

    # -------------------------------------------------------------------------
    # Drain-side pop.
    # -------------------------------------------------------------------------
    def try_pop(mut self) -> Optional[LogEventRecord]:
        var head = self._head.load()
        var tail = self._tail.load()
        if head >= tail:
            return Optional[LogEventRecord]()

        var idx = Int(head) & (self._capacity - 1)
        ref slot = self._slots.get_mut_interior(idx)
        var record = slot.copy()

        _ = self._head.fetch_add(Int64(1))
        return Optional[LogEventRecord](record^)

    @always_inline
    def is_empty(self) -> Bool:
        return self._head.load() >= self._tail.load()

    @always_inline
    def approximate_size(self) -> Int64:
        return self._tail.load() - self._head.load()
