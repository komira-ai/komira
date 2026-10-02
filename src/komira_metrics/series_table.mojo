# =============================================================================
# series_table.mojo — the per-worker SERIES TABLE
# =============================================================================
#
# ⭐ THIS IS THE EXPENSIVE HALF of adopting OTel attributes. The cost splits in
# two: the INTERNER (`attr_set.mojo`, a bounded 4096-slot table, a rounding
# error) and this — the per-series storage that sits beside the "64-slot array
# keyed by NAME ALONE" instruments (`metrics_set.mojo`).
#
# THE SHAPE: each worker owns a private open-addressing table mapping
# `(name_id, attrset_id)` -> `Int64`, sized `MAX_SERIES_PER_WORKER`. The hot
# path is one hash and one probe into a WORKER-PRIVATE table — no atomic, no
# contention, the same "one load + one store, no sharing" property the
# `per_worker[wid]` write has, one indirection deeper. The export sweep reduces
# across the 64 tables, exactly as `Counter.reduce()` reduces across the 64
# slots.
#
# WHY THIS IS NOT AN `Atomic`: identical to `Counter.inc_in_pipeline`. Worker
# `w` touches ONLY `tables[w]`. Two workers writing different tables is sound;
# two writing the SAME table is UB, and it is the caller's invariant exactly as
# it already is for `Counter.per_worker[wid]`. The export sweep runs on ONE
# thread and is the only reader: worker-disjointness is a property of the
# WRITE, never of the export.
#
# -----------------------------------------------------------------------------
# ⚠ SIZE. KEY AND VALUE ARE NOT ENOUGH, AND HERE IS THE ARITHMETIC.
# -----------------------------------------------------------------------------
# `4096 series x 16 B (UInt64 key + Int64 value)` = 64 KiB per worker, 4 MiB
# per process, is the KEY AND VALUE only. Two more
# things have to be stored per slot and neither is optional:
#
#   `kind`   the sweep builds a `MetricPoint` from a slot and a COUNTER, an
#            UPDOWNCOUNTER and a GAUGE reduce DIFFERENTLY (sum-and-reset vs
#            last-value-and-keep). Without it the sweep cannot know which.
#   `scope`  `MetricPoint.scope_id` is a field, and the series key does not carry
#            it. See "SCOPE IS PER-SLOT" below.
#
# plus an `occupied` bitset, because key 0 is a LEGAL key (`name_id = 0` with
# the empty attrset) and cannot double as the empty sentinel — the same reason
# `AttrSetEntry.occupied` is its own field rather than `id != 0`.
#
#     entries   4096 x 16 B (key 8 + value 8)   = 65536 B
#     scopes    4096 x  4 B                     = 16384 B
#     kinds     4096 x  1 B                     =  4096 B
#     occupied    64 x  8 B  (one bit per slot) =    512 B
#     counters                                  =     16 B
#                                               ----------
#     per worker                                =  86544 B  = 84.5 KiB
#     x MAX_WORKERS 64                          =   5.28 MiB per process
#
# 5.28 MiB. A naive per-series replication is 512 MiB per process, so this is
# still **97x smaller**.
#
# -----------------------------------------------------------------------------
# ⭐ SCOPE IS PER-SLOT.
# -----------------------------------------------------------------------------
# `MetricPoint` carries `scope_id` (the instrumentation scope, deliberately the
# SAME id space as a log record's `module_id` so a metric and a log line from
# one module join without a mapping table). The key is `(name_id,
# attrset_id)` and has no room for it: the key is already 32+32 bits of a
# UInt64.
#
# Two answers were available. (a) A side `name_id -> scope_id` map, justified by
# "an instrument belongs to exactly one meter", which is true of OTel. (b) Store
# it per slot. **(b) is chosen** — the side map is a second table with its own
# ceiling, its own overflow arm and its own conflict rule, to save 16 KiB per
# worker on a structure that is already 5 MiB per process. A slot written with
# a scope different from the one it holds is a CONFLICT and is REFUSED (below),
# which gives the same protection the side map would have.
#
# -----------------------------------------------------------------------------
# ⛔ A CONFLICT IS REFUSED, NEVER OVERWRITTEN.
# -----------------------------------------------------------------------------
# A slot already holding `(kind=COUNTER, scope=S)` written as a GAUGE, or under
# a different scope, is the same series being measured by two different
# instruments. Writing it would silently corrupt one of them — the same class
# of failure as a lookup miss that returns slot 0, so an unregistered name
# increments a REAL, UNRELATED metric. So the write is refused and counted
# (`num_conflicts()`), never applied.
#
# -----------------------------------------------------------------------------
# ⚠ THE HASH MUST MIX, AND THE OBVIOUS KEY DOES NOT.
# -----------------------------------------------------------------------------
# `key = (name_id << 32) | attrset_id`. Indexing with `key & (N-1)` uses the LOW
# 32 bits — i.e. `attrset_id` alone — so EVERY metric sharing one attribute set
# lands on ONE home slot. With `MAX_ATTRS_PER_SET` label sets shared across a
# process's instruments that is the common case, not a corner. `_mix64` (the
# splitmix64 finaliser) is therefore not optional; it is what makes the "one
# hash and one probe" hot path true.
#
# -----------------------------------------------------------------------------
# ⚠ THE PROBE IS BOUNDED, DELIBERATELY UNLIKE `attr_set.mojo`.
# -----------------------------------------------------------------------------
# `AttrSetRegistry` probes the whole table because interning is a ONE-TIME cost
# on a cold path. This is the HOT path: an unbounded probe would put a
# 4096-iteration loop behind a counter increment. `SERIES_MAX_PROBE` caps it;
# past the cap the write is refused and counted. A cardinality-collapse layer
# is what would turn that refusal into a documented overflow bucket; without
# one it is a fail-CLOSED refusal with a number on it, never a silent slot
# reuse.
#
# -----------------------------------------------------------------------------
# ⭐ EVERY REFUSAL ARM IN THIS FILE IS DRIVEN BY ITS OWN TEST
# -----------------------------------------------------------------------------
# `tests/test_series_table.mojo`. Breaking each mechanism below ALONE reds
# exactly the predicted case — which is what makes the arms independent rather
# than jointly covered:
#
#   mechanism           the break                  failing case
#   -----------------   ------------------------   ---------------------------
#   `_mix64`            body replaced by `return    "name #64 sharing attrset 0
#                       z`                          is accepted" (the 65th
#                                                   name, i.e. EXACTLY
#                                                   SERIES_MAX_PROBE, refused)
#   conflict refusal    `return SERIES_SLOT_NONE`   3 cases at once: kind
#                       replaced by `pass`          conflict, COUNTER-vs-
#                                                   UPDOWNCOUNTER, scope
#                                                   conflict
#   overflow refusal    `return idx` (hand back     "a table 3x oversubscribed
#                       the last probed slot)       REFUSES"
#   delta reset         `take_slot_delta` returns   the value survives the take
#                       without zeroing
#
# Encapsulation: `InlineArray` of POD + a `Slab[SeriesTable]`. No
# `UnsafePointer` in any signature, no wildcard origin, no heap-owning field on
# `SeriesTable` itself (which is why `Slab.create_prefilled`'s zero-fill IS a
# valid empty table).
# =============================================================================

from std.sys import size_of

from komira_core.collections import Slab

from komira_metrics.metric_point import (
    METRIC_COUNTER,
    METRIC_GAUGE,
    METRIC_UPDOWNCOUNTER,
)
from komira_metrics.metrics_set import MAX_WORKERS


# Series per worker. Every ceiling here is derived from
# `komira_spsc_ring.DEFAULT_RING_CAPACITY = 4096` so it cannot drift out of agreement with the
# transport; this is that number. Power of two is required for the probe wrap.
comptime MAX_SERIES_PER_WORKER: Int = 4096

# One bit per slot. Same shape as the bitset the tracer keeps over registered names.
comptime SERIES_BITSET_WORDS: Int = (MAX_SERIES_PER_WORKER + 63) // 64

# Hot-path probe cap. See the header. 64 at a 4096-slot table is a run of 1/64
# of the table; reaching it means the table is effectively full for that key.
comptime SERIES_MAX_PROBE: Int = 64

# Returned by `_slot_for` when no slot is available within the probe cap.
comptime SERIES_SLOT_NONE: Int = -1


@always_inline
def series_key(name_id: UInt32, attrset_id: UInt32) -> UInt64:
    """Compose the series key. NOT a hash — the exact `(name_id, attrset_id)`
    pair, losslessly, so `_slot_for` can compare keys for equality rather than
    trusting a digest. `_mix64` is applied to this to pick the home slot."""
    return (UInt64(name_id) << UInt64(32)) | UInt64(attrset_id)


@always_inline
def series_key_name_id(key: UInt64) -> UInt32:
    return UInt32((key >> UInt64(32)) & UInt64(0xFFFFFFFF))


@always_inline
def series_key_attrset_id(key: UInt64) -> UInt32:
    return UInt32(key & UInt64(0xFFFFFFFF))


@always_inline
def _mix64(x: UInt64) -> UInt64:
    """The splitmix64 finaliser. See the header: without it the home slot is
    `attrset_id` alone and every instrument sharing one label set piles onto one
    slot. Chosen over a second FNV pass because it is three multiplies with no
    loop, which is the whole hot-path budget."""
    var z = x
    z = (z ^ (z >> UInt64(30))) * UInt64(0xBF58476D1CE4E5B9)
    z = (z ^ (z >> UInt64(27))) * UInt64(0x94D049BB133111EB)
    return z ^ (z >> UInt64(31))


struct SeriesEntry(Copyable, Movable, Deinitable):
    """One slot's key and value. 16 B, the table's stated stride.

    `value` is an Int64 for every kind. A GAUGE stores its level here and a
    COUNTER its running delta; `SeriesTable.kinds[i]` is what says which, and
    NOTHING ELSE DOES — do not infer it from the sign or the magnitude."""

    var key: UInt64
    var value: Int64

    def __init__(out self):
        self.key = UInt64(0)
        self.value = Int64(0)


struct SeriesTable(Copyable, Movable, Deinitable):
    """ONE worker's private `(name_id, attrset_id) -> Int64` table.

    ⚠ SINGLE-WRITER BY CONTRACT, exactly like `Counter.per_worker[wid]`. There
    is no atomic here and that is the point: the whole design is that the
    hot path keeps the "one load + one store, no sharing" property.

    ⭐ A ZERO-FILLED `SeriesTable` IS A VALID EMPTY TABLE — every bitset word 0,
    every counter 0 — which is what makes `Slab.create_prefilled` the correct
    constructor for the 64-table array and avoids ever building 5 MiB of
    `InlineArray` on a stack."""

    var entries: Array[SeriesEntry, MAX_SERIES_PER_WORKER]
    # `MetricPoint.scope_id` for this slot's series. See "SCOPE IS PER-SLOT".
    var scopes: Array[UInt32, MAX_SERIES_PER_WORKER]
    # One of the `METRIC_*` kinds. Read ONLY for an occupied slot; the
    # zero-filled value happens to be `METRIC_COUNTER` and means nothing.
    var kinds: Array[UInt8, MAX_SERIES_PER_WORKER]
    # Occupancy. Its own bitset rather than `key != 0`, because key 0 is legal.
    var occupied: Array[UInt64, SERIES_BITSET_WORDS]
    var n_live: UInt32
    # Writes refused because no slot was free within `SERIES_MAX_PROBE`.
    # NON-ZERO MEANS OBSERVATIONS WERE LOST — a cardinality collapse is what
    # would turn that into a documented bucket rather than a loss.
    var n_overflowed: UInt32
    # Writes refused because the slot held a different kind or scope.
    var n_conflicts: UInt32
    var _pad: UInt32

    def __init__(out self):
        self.entries = Array[SeriesEntry, MAX_SERIES_PER_WORKER](
            fill=SeriesEntry()
        )
        self.scopes = Array[UInt32, MAX_SERIES_PER_WORKER](
            fill=UInt32(0)
        )
        self.kinds = Array[UInt8, MAX_SERIES_PER_WORKER](fill=UInt8(0))
        self.occupied = Array[UInt64, SERIES_BITSET_WORDS](
            fill=UInt64(0)
        )
        self.n_live = UInt32(0)
        self.n_overflowed = UInt32(0)
        self.n_conflicts = UInt32(0)
        self._pad = UInt32(0)

    # -------------------------------------------------------------------------
    # Occupancy bitset
    # -------------------------------------------------------------------------

    @always_inline
    def is_occupied(self, idx: Int) -> Bool:
        return (
            self.occupied[idx >> 6] & (UInt64(1) << UInt64(idx & 63))
        ) != UInt64(0)

    @always_inline
    def _mark_occupied(mut self, idx: Int):
        self.occupied[idx >> 6] = self.occupied[idx >> 6] | (
            UInt64(1) << UInt64(idx & 63)
        )

    # -------------------------------------------------------------------------
    # The probe. ONE function, so the hot path and the sweep cannot disagree
    # about where a key lives.
    # -------------------------------------------------------------------------

    def _slot_for(
        mut self,
        key: UInt64,
        scope_id: UInt32,
        kind: UInt8,
        insert: Bool,
    ) -> Int:
        """Find (or, if `insert`, claim) the slot for `key`.

        Returns `SERIES_SLOT_NONE` and COUNTS on every refusal:
          * the slot exists but holds a different kind or scope -> conflict;
          * no free slot within `SERIES_MAX_PROBE`               -> overflow;
          * `insert` is False and the key is absent              -> neither
            (a pure lookup miss is not a refusal and is not counted).
        """
        var idx = Int(_mix64(key) & UInt64(MAX_SERIES_PER_WORKER - 1))
        var probe = 0
        while probe < SERIES_MAX_PROBE:
            if not self.is_occupied(idx):
                if not insert:
                    return SERIES_SLOT_NONE
                self._mark_occupied(idx)
                self.entries[idx].key = key
                self.entries[idx].value = Int64(0)
                self.scopes[idx] = scope_id
                self.kinds[idx] = kind
                self.n_live += UInt32(1)
                return idx
            if self.entries[idx].key == key:
                # ⛔ REFUSE, never overwrite. See the header.
                if self.kinds[idx] != kind or self.scopes[idx] != scope_id:
                    self.n_conflicts += UInt32(1)
                    return SERIES_SLOT_NONE
                return idx
            idx = (idx + 1) & (MAX_SERIES_PER_WORKER - 1)
            probe += 1
        if insert:
            self.n_overflowed += UInt32(1)
        return SERIES_SLOT_NONE

    # -------------------------------------------------------------------------
    # The hot path. Two entry points rather than one with a runtime branch on
    # `kind`: a COUNTER accumulates and a GAUGE stores, and the branch would be
    # paid on every observation to decide something the CALLER already knows.
    # -------------------------------------------------------------------------

    def add(
        mut self,
        name_id: UInt32,
        scope_id: UInt32,
        attrset_id: UInt32,
        kind: UInt8,
        n: Int64,
    ) -> Bool:
        """Accumulate `n` into the (name, attrs) series. For COUNTER and
        UPDOWNCOUNTER only — a GAUGE is a level, not a sum, and passing one here
        would make the sweep emit the SUM of every reading in the interval.

        Returns False on refusal (conflict / overflow / wrong kind), never
        having written anything."""
        if kind != METRIC_COUNTER and kind != METRIC_UPDOWNCOUNTER:
            self.n_conflicts += UInt32(1)
            return False
        var idx = self._slot_for(
            series_key(name_id, attrset_id), scope_id, kind, True
        )
        if idx == SERIES_SLOT_NONE:
            return False
        self.entries[idx].value += n
        return True

    def set_gauge(
        mut self,
        name_id: UInt32,
        scope_id: UInt32,
        attrset_id: UInt32,
        v: Int64,
    ) -> Bool:
        """Last-write-wins store of a level. Returns False on refusal."""
        var idx = self._slot_for(
            series_key(name_id, attrset_id), scope_id, METRIC_GAUGE, True
        )
        if idx == SERIES_SLOT_NONE:
            return False
        self.entries[idx].value = v
        return True

    # -------------------------------------------------------------------------
    # Read side — the sweep, and tests
    # -------------------------------------------------------------------------

    def lookup(mut self, name_id: UInt32, attrset_id: UInt32) -> Optional[Int64]:
        """The value held for this series, or None if the worker never touched
        it. ⚠ `mut` only because it shares `_slot_for` with the write path; a
        pure lookup miss mutates nothing and is not counted."""
        var key = series_key(name_id, attrset_id)
        var idx = Int(_mix64(key) & UInt64(MAX_SERIES_PER_WORKER - 1))
        var probe = 0
        while probe < SERIES_MAX_PROBE:
            if not self.is_occupied(idx):
                return Optional[Int64]()
            if self.entries[idx].key == key:
                return Optional[Int64](self.entries[idx].value)
            idx = (idx + 1) & (MAX_SERIES_PER_WORKER - 1)
            probe += 1
        return Optional[Int64]()

    def next_occupied(self, from_idx: Int) -> Int:
        """The next occupied slot at or after `from_idx`, or
        `SERIES_SLOT_NONE`. Skips 64 empty slots per word, which is what makes
        a sweep over a SPARSE table (the normal case — a worker allocates only
        the series it touches) cheap."""
        var i = from_idx
        if i < 0:
            i = 0
        while i < MAX_SERIES_PER_WORKER:
            var w = i >> 6
            var word = self.occupied[w] >> UInt64(i & 63)
            if word == UInt64(0):
                i = (w + 1) << 6
                continue
            while (word & UInt64(1)) == UInt64(0):
                word = word >> UInt64(1)
                i += 1
            return i
        return SERIES_SLOT_NONE

    @always_inline
    def slot_key(self, idx: Int) -> UInt64:
        return self.entries[idx].key

    @always_inline
    def slot_value(self, idx: Int) -> Int64:
        return self.entries[idx].value

    @always_inline
    def slot_scope(self, idx: Int) -> UInt32:
        return self.scopes[idx]

    @always_inline
    def slot_kind(self, idx: Int) -> UInt8:
        return self.kinds[idx]

    @always_inline
    def take_slot_delta(mut self, idx: Int) -> Int64:
        """Read a DELTA slot and zero it — the "reduced and reset each export
        sweep produces deltas naturally" half of `metric_point.mojo`'s
        temporality note. The slot stays OCCUPIED: the series still exists, it
        just has no unexported observations."""
        var v = self.entries[idx].value
        self.entries[idx].value = Int64(0)
        return v

    def clear(mut self):
        """Forget every series. Only the OCCUPANCY and the counters are zeroed —
        `entries` / `scopes` / `kinds` are gated by occupancy on every read, so
        clearing 84 KiB to re-clear bytes nothing can observe would make the
        sweep's per-generation reset 170x more expensive than it needs to be."""
        for i in range(SERIES_BITSET_WORDS):
            self.occupied[i] = UInt64(0)
        self.n_live = UInt32(0)
        self.n_overflowed = UInt32(0)
        self.n_conflicts = UInt32(0)

    @always_inline
    def live_count(self) -> Int:
        return Int(self.n_live)


struct SeriesTables(Movable, Deinitable):
    """The `MAX_WORKERS` per-worker tables, heap-owned.

    ⭐ `Slab.create_prefilled` AND NOT AN `InlineArray` FIELD. 64 tables is
    5.28 MiB; an `InlineArray[SeriesTable, 64]` field would be constructed
    wherever the owner is, which for a stack-local owner is a 5 MiB stack
    frame. `Slab` puts it on the heap and its zero-fill IS the empty state
    (see `SeriesTable`), so no 4096-iteration per-table constructor runs
    either.

    ⛔ NOT `Copyable`. Copying 5.28 MiB by accident is exactly the kind of thing
    a `.copy()` at a call site does silently."""

    var _tables: Slab[SeriesTable]

    def __init__(out self):
        self._tables = Slab[SeriesTable].create_prefilled(MAX_WORKERS)

    @always_inline
    def num_workers(self) -> Int:
        return MAX_WORKERS

    # ⚠ NO `table(worker_id) -> ref SeriesTable` ACCESSOR, DELIBERATELY. Handing
    # out a `ref` into the Slab would (a) leak `Slab`'s internal byte origin
    # through this module's public signature and (b) hand a caller a table it can
    # hold across statements, which is the shape that makes a
    # worker-disjointness violation easy to write by accident. Every access goes
    # through a forwarder that takes `worker_id` at the point of use.

    # -------------------------------------------------------------------------
    # Hot-path forwarders. Present so a caller never has to hold a `ref` to a
    # table across statements — the shape that makes a disjointness violation
    # easy to write by accident.
    # -------------------------------------------------------------------------

    def add(
        mut self,
        worker_id: Int,
        name_id: UInt32,
        scope_id: UInt32,
        attrset_id: UInt32,
        kind: UInt8,
        n: Int64,
    ) -> Bool:
        if worker_id < 0 or worker_id >= MAX_WORKERS:
            return False
        return self._tables[worker_id].add(
            name_id, scope_id, attrset_id, kind, n
        )

    def set_gauge(
        mut self,
        worker_id: Int,
        name_id: UInt32,
        scope_id: UInt32,
        attrset_id: UInt32,
        v: Int64,
    ) -> Bool:
        if worker_id < 0 or worker_id >= MAX_WORKERS:
            return False
        return self._tables[worker_id].set_gauge(
            name_id, scope_id, attrset_id, v
        )

    # -------------------------------------------------------------------------
    # Per-slot read side, forwarded. This is what `MetricSweep` walks: for each
    # worker, `next_occupied` to skip 64 empty slots at a time, then the four
    # `slot_*` reads, then `take_slot_delta` for the DELTA kinds.
    # -------------------------------------------------------------------------

    def next_occupied(mut self, worker_id: Int, from_idx: Int) -> Int:
        return self._tables[worker_id].next_occupied(from_idx)

    def slot_key(mut self, worker_id: Int, idx: Int) -> UInt64:
        return self._tables[worker_id].slot_key(idx)

    def slot_value(mut self, worker_id: Int, idx: Int) -> Int64:
        return self._tables[worker_id].slot_value(idx)

    def slot_scope(mut self, worker_id: Int, idx: Int) -> UInt32:
        return self._tables[worker_id].slot_scope(idx)

    def slot_kind(mut self, worker_id: Int, idx: Int) -> UInt8:
        return self._tables[worker_id].slot_kind(idx)

    def take_slot_delta(mut self, worker_id: Int, idx: Int) -> Int64:
        return self._tables[worker_id].take_slot_delta(idx)

    def worker_live_count(mut self, worker_id: Int) -> Int:
        return self._tables[worker_id].live_count()

    def worker_num_overflowed(mut self, worker_id: Int) -> Int:
        return Int(self._tables[worker_id].n_overflowed)

    # -------------------------------------------------------------------------
    # Reduction — exactly as `Counter.reduce()` reduces across the 64 slots.
    # This is the O(MAX_WORKERS) off-hot-path form used by tests
    # and by EXPLAIN-style readers; `MetricSweep` does the cursored, resetting
    # version over the whole table.
    # -------------------------------------------------------------------------

    def reduce_sum(mut self, name_id: UInt32, attrset_id: UInt32) -> Int64:
        """Sum one series across every worker. For DELTA kinds. Does NOT reset —
        a reader must not be able to consume the sweep's data."""
        var total = Int64(0)
        for w in range(MAX_WORKERS):
            var v = self._tables[w].lookup(name_id, attrset_id)
            if v:
                total += v.value()
        return total

    def reduce_last(mut self, name_id: UInt32, attrset_id: UInt32) -> Optional[Int64]:
        """The GAUGE reduction: the value from the HIGHEST-numbered worker
        holding the series.

        ⚠ WHICH WORKER WINS IS ARBITRARY AMONG CONCURRENT WRITERS, AND THAT IS
        THE SPEC. OTel's synchronous gauge is last-value-wins with no ordering
        guarantee across threads; `MetricsSet.Gauge` already takes the same
        position with a relaxed atomic store ("gauges are inherently shared").
        Ascending worker order makes it DETERMINISTIC given a table state, which
        is what a test needs, without pretending it is meaningful."""
        var out = Optional[Int64]()
        for w in range(MAX_WORKERS):
            var v = self._tables[w].lookup(name_id, attrset_id)
            if v:
                out = Optional[Int64](v.value())
        return out

    def live_series(mut self) -> Int:
        """Total occupied slots across all workers. ⚠ NOT the number of DISTINCT
        series — one series touched by 8 workers counts 8 times. The distinct
        count is what a sweep generation produces."""
        var total = 0
        for w in range(MAX_WORKERS):
            total += self._tables[w].live_count()
        return total

    def num_overflowed(mut self) -> Int:
        var total = 0
        for w in range(MAX_WORKERS):
            total += Int(self._tables[w].n_overflowed)
        return total

    def num_conflicts(mut self) -> Int:
        var total = 0
        for w in range(MAX_WORKERS):
            total += Int(self._tables[w].n_conflicts)
        return total

    def clear(mut self):
        for w in range(MAX_WORKERS):
            self._tables[w].clear()


# -----------------------------------------------------------------------------
# Compile-time SIZE anchors — the convention this package follows.
#
# ⛔ NOT POD GUARDS. `metric_point.mojo` records why (a `size_of[String]()`
# probe compiles fine, with an unknown-name positive control proving the block
# elaborates). What these buy is a NUMBER read by `tests/test_series_table.mojo`,
# which is the only thing that
# catches the 84.5 KiB arithmetic in this header drifting away from the layout.
# -----------------------------------------------------------------------------
comptime _SERIES_ENTRY_SIZE_GUARD: Int = size_of[SeriesEntry]()
comptime _SERIES_TABLE_SIZE_GUARD: Int = size_of[SeriesTable]()
