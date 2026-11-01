# =============================================================================
# metrics_set.mojo — the per-operator MetricsSet data model
# =============================================================================
#
# DataFusion-shaped: each MorselOperator instance owns one MetricsSet via
# OwnedPointer indirection, surfaced to EXPLAIN ANALYZE.
#
# SCOPE (this module): the data model + hot-path API.
#
# Hot-path performance contract:
#
#   * In-pipeline `Counter.inc(n, worker_id=wid)` — <5ns, single
#     load+store on `per_worker[wid]`: far cheaper than an atomic in
#     dispatch-dominated workloads.
#
#   * Out-of-pipeline `Counter.inc(n)` — 15-25ns,
#     `Atomic[Int64].fetch_add(Relaxed)`. Embedder code, sink finalize,
#     driver thread.
#
#   * `Time.start(worker_id)` — returns a stack-allocated TimeScope that
#     records elapsed nanoseconds at scope exit (RAII). The hot-path
#     escape hatch is `Time.record_ns(ns, worker_id)` for callers that
#     prefer explicit timing measurement.
#
#   * `Gauge.set(v)` — last-write-wins semantics; uses
#     `Atomic[Int64].store(Relaxed)` because gauges are inherently shared.
#
# Bounded by construction:
#   MAX_COUNTERS = 8, MAX_TIMES = 4, MAX_GAUGES = 4.
#   MAX_WORKERS = 64 — the upper end of the engine's worker count.
#
# Encapsulation:
#   * Public-API surface is `Counter`, `Time`, `Gauge`, `MetricsSet`,
#     `MetricsSnapshot`, `TimeScope`. No raw UnsafePointer in any
#     signature — fields use Slab[T] / OwnedPointer[T] for indirection,
#     and the per-worker arrays are direct `InlineArray` fields.
#   * Slab[T] is the canonical container for non-Movable Atomic-bearing
#     element types (Slab.create_prefilled zero-fills bytes — matches
#     Atomic's expected initial state).
#   * MetricsSet is non-Movable (the Atomic fields propagate the
#     restriction). Callers wrap it in `OwnedPointer[MetricsSet]`
#     (`new_owned_metrics_set` below).
#   * No wildcard-origin fields.
# =============================================================================

from komira_atomic_alias import AtomicI32, AtomicI64
from std.memory import alloc, OwnedPointer, UnsafePointer

from komira_collections.slab import Slab

from komira_clock import now_ns as _platform_now_ns
from komira_name_registry import name_id as _literal_name_id


# Hot-path inline upper bound on worker count; matches the engine's
# worker-pool cap of 64.
comptime MAX_WORKERS: Int = 64

# Per-MetricsSet bounded entry counts. Hard ceilings — adding
# the 9th counter to a single MetricsSet returns False from `try_register_*`
# and is a build-time error in EXPLAIN ANALYZE rendering.
comptime MAX_COUNTERS: Int = 8
comptime MAX_TIMES: Int = 4
comptime MAX_GAUGES: Int = 4

# THE QUARANTINE SLOT. Each Slab is allocated with ONE slot more than its
# ceiling, and that extra slot is where an UNREGISTERED lookup is sent.
#
# WHY A SLOT AND NOT SLOT 0: the lookup accessors return `ref ... Counter`, so a
# miss must return SOMETHING. Returning slot 0 — the FIRST REGISTERED METRIC —
# would make a typo'd or unregistered name silently increment a real, unre-
# lated metric. That is data corruption, not a missing value.
#
# WHY IT IS NEVER REPORTED: every registration path caps at `MAX_*` and every
# read path (`reduce`, the snapshot, EXPLAIN ANALYZE) iterates `0 ..< n_*`,
# which can never reach `MAX_*`. The quarantine slot is therefore unreachable
# by construction from every path that publishes a value.
comptime QUARANTINE_COUNTER: Int = MAX_COUNTERS
comptime QUARANTINE_TIME: Int = MAX_TIMES
comptime QUARANTINE_GAUGE: Int = MAX_GAUGES


# -----------------------------------------------------------------------------
# Counter — the in-pipeline / out-of-pipeline counter primitive
# -----------------------------------------------------------------------------


struct Counter(Deinitable):
    """Per-worker int64 counter with an out-of-pipeline atomic fallback.

    Layout (POD aside from the trailing Atomic):
        per_worker:      InlineArray[Int64, MAX_WORKERS=64]   # ~512 bytes
        out_of_pipeline: Atomic[Int64]                         #     8 bytes

    Hot-path contract:
        * `inc(n, worker_id=wid)` — disjoint write to `per_worker[wid]`.
          O(1), single load+store, no atomic. Caller MUST hold the
          per-worker disjointness invariant (worker `w` writes only its
          own slot).
        * `inc(n)` — atomic fetch_add into `out_of_pipeline`. Used by
          driver-thread / sink-finalize / embedder code outside any
          parallelize fork-join.

    NOT Movable: holds an Atomic field. Wrap in `Slab[Counter]` /
    `OwnedPointer[Counter]` for parent-struct embedding (the
    `Slab.create_prefilled` pattern is the standard zero-fill init that
    Atomic[Int64] tolerates).
    """

    var per_worker: Array[Int64, MAX_WORKERS]
    var out_of_pipeline: AtomicI64

    def __init__(out self):
        self.per_worker = Array[Int64, MAX_WORKERS](fill=Int64(0))
        self.out_of_pipeline = AtomicI64(Int64(0))

    @always_inline
    def inc_in_pipeline(mut self, n: Int64, worker_id: Int):
        """In-pipeline increment. Worker-disjoint write — no atomic.

        Caller MUST respect the disjointness invariant:
            * Each worker `w` accesses ONLY `per_worker[w]`.
            * Two workers writing different slots is sound;
              two workers writing the SAME slot is UB.
        """
        debug_assert(
            worker_id >= 0 and worker_id < MAX_WORKERS,
            "Counter.inc_in_pipeline: worker_id out of range",
        )
        self.per_worker[worker_id] += n

    @always_inline
    def inc_out_of_pipeline(mut self, n: Int64):
        """Out-of-pipeline increment. Atomic fetch_add (Relaxed)."""
        _ = self.out_of_pipeline.fetch_add(n)

    @always_inline
    def reduce(self) -> Int64:
        """Sum every per-worker slot + out_of_pipeline. Off the hot path.

        Returns the canonical aggregate value used by EXPLAIN ANALYZE
        rendering. O(MAX_WORKERS) — ~64 adds.
        """
        var total = Int64(0)
        for i in range(MAX_WORKERS):
            total += self.per_worker[i]
        total += self.out_of_pipeline.load()
        return total

    def reset(mut self):
        """Zero every per-worker slot + out_of_pipeline.

        Used by tests that rebuild a counter between scenarios. Single-
        writer; callers must ensure no concurrent reader / writer.
        """
        for i in range(MAX_WORKERS):
            self.per_worker[i] = Int64(0)
        # SAFETY: Atomic.store via UnsafePointer(to=field.value) is the
        # validated 0.26.3 pattern.
        AtomicI64.store(
            UnsafePointer(to=self.out_of_pipeline)
            .unsafe_bitcast[Scalar[DType.int64]](),
            Int64(0),
        )


# -----------------------------------------------------------------------------
# Time — accumulated nanoseconds, same shape as Counter
# -----------------------------------------------------------------------------


struct Time(Deinitable):
    """Per-worker accumulated nanoseconds + out-of-pipeline fallback.

    Same layout as `Counter`; the only semantic difference is intent
    (the units are nanoseconds, not arbitrary counts) and the
    `start(worker_id) -> TimeScope` RAII helper.

    NOT Movable (Atomic field). Stored in `Slab[Time]` like Counter.
    """

    var per_worker: Array[Int64, MAX_WORKERS]
    var out_of_pipeline: AtomicI64

    def __init__(out self):
        self.per_worker = Array[Int64, MAX_WORKERS](fill=Int64(0))
        self.out_of_pipeline = AtomicI64(Int64(0))

    @always_inline
    def record_ns_in_pipeline(mut self, ns: Int64, worker_id: Int):
        """In-pipeline accumulate. Worker-disjoint write — no atomic.

        Same contract as `Counter.inc_in_pipeline`. The hot-path entry
        for callers that measure elapsed time explicitly (e.g. an
        existing `t0 = now_ns(); ...; t1 = now_ns(); record(t1-t0)`
        block).
        """
        debug_assert(
            worker_id >= 0 and worker_id < MAX_WORKERS,
            "Time.record_ns_in_pipeline: worker_id out of range",
        )
        self.per_worker[worker_id] += ns

    @always_inline
    def record_ns_out_of_pipeline(mut self, ns: Int64):
        """Out-of-pipeline accumulate. Atomic fetch_add (Relaxed)."""
        _ = self.out_of_pipeline.fetch_add(ns)

    @always_inline
    def reduce(self) -> Int64:
        """Sum every per-worker slot + out_of_pipeline. Off the hot path."""
        var total = Int64(0)
        for i in range(MAX_WORKERS):
            total += self.per_worker[i]
        total += self.out_of_pipeline.load()
        return total

    def reset(mut self):
        """Zero every per-worker slot + out_of_pipeline."""
        for i in range(MAX_WORKERS):
            self.per_worker[i] = Int64(0)
        # SAFETY: see Counter.reset.
        AtomicI64.store(
            UnsafePointer(to=self.out_of_pipeline)
            .unsafe_bitcast[Scalar[DType.int64]](),
            Int64(0),
        )


# -----------------------------------------------------------------------------
# Gauge — last-write-wins instantaneous value
# -----------------------------------------------------------------------------


struct Gauge(Deinitable):
    """Per-worker instantaneous value + out-of-pipeline atomic.

    Last-write-wins semantics. Workers call `set(v, worker_id=wid)` to
    publish their latest observation; readers call `reduce()` which
    returns the maximum across slots (gauge-of-gauges semantics — see
    `reduce` docstring for the choice rationale).

    NOT Movable (Atomic field).
    """

    var per_worker: Array[Int64, MAX_WORKERS]
    var out_of_pipeline: AtomicI64

    def __init__(out self):
        self.per_worker = Array[Int64, MAX_WORKERS](fill=Int64(0))
        self.out_of_pipeline = AtomicI64(Int64(0))

    @always_inline
    def set_in_pipeline(mut self, v: Int64, worker_id: Int):
        """In-pipeline set. Worker-disjoint write — no atomic.

        Caller MUST hold the disjointness invariant. Last-write-wins
        within a worker's slot.
        """
        debug_assert(
            worker_id >= 0 and worker_id < MAX_WORKERS,
            "Gauge.set_in_pipeline: worker_id out of range",
        )
        self.per_worker[worker_id] = v

    @always_inline
    def set_out_of_pipeline(mut self, v: Int64):
        """Out-of-pipeline set. Atomic store (Relaxed)."""
        # SAFETY: see Counter.reset for the validated store pattern.
        AtomicI64.store(
            UnsafePointer(to=self.out_of_pipeline)
            .unsafe_bitcast[Scalar[DType.int64]](),
            v,
        )

    @always_inline
    def reduce(self) -> Int64:
        """Return the gauge value: max across all per-worker slots and
        out_of_pipeline.

        Gauge semantics are "instantaneous value." Across N workers each
        publishing a local observation (e.g. peak in-flight rows), the
        most useful aggregate is the MAXIMUM — the largest observed peak
        is the operator's overall peak. Callers wanting different
        semantics (sum, last-write) can iterate the per_worker array
        directly via `peek_slot`.
        """
        var best = self.out_of_pipeline.load()
        for i in range(MAX_WORKERS):
            var v = self.per_worker[i]
            if v > best:
                best = v
        return best

    @always_inline
    def peek_slot(self, worker_id: Int) -> Int64:
        """Read a single per-worker slot. Off the hot path."""
        debug_assert(
            worker_id >= 0 and worker_id < MAX_WORKERS,
            "Gauge.peek_slot: worker_id out of range",
        )
        return self.per_worker[worker_id]

    def reset(mut self):
        """Zero every per-worker slot + out_of_pipeline."""
        for i in range(MAX_WORKERS):
            self.per_worker[i] = Int64(0)
        # SAFETY: see Counter.reset for the validated store pattern.
        AtomicI64.store(
            UnsafePointer(to=self.out_of_pipeline)
            .unsafe_bitcast[Scalar[DType.int64]](),
            Int64(0),
        )


# -----------------------------------------------------------------------------
# TimeScope — RAII helper for timing a block
# -----------------------------------------------------------------------------


struct TimeScope(Movable, Deinitable):
    """Lightweight RAII helper that records elapsed nanoseconds into a
    `Time` slot when `stop()` is called.

    Designed to support both an explicit start/stop pattern and a
    future `with` block (Mojo 0.26.3 `__enter__`/`__exit__` shape):

        var ts = time.start(worker_id=wid)
        # ... work ...
        ts.stop()                         # explicit form

    The struct holds:
        * `_start_ns`  — captured at start time via the platform clock
                         (clock.now_ns).
        * `_active`   — whether the scope still needs to flush. The
                        public `stop()` method flips this to False and
                        is idempotent.

    The scope does NOT hold a pointer back to the `Time` struct it
    will flush into; instead the Time itself is the pivot — the caller
    obtained the scope from `Time.start(...)`, and on `stop()` the
    scope returns the elapsed value, which the caller flushes via
    `Time.record_ns_in_pipeline(elapsed, worker_id)`.

    This avoids a stored pointer on the hot path (encapsulation rule)
    and keeps `TimeScope` POD-shaped + Movable (no Atomic, no
    OwnedPointer fields).
    """

    var _start_ns: UInt64
    var _worker_id: Int
    var _active: Bool

    @always_inline
    def __init__(out self, worker_id: Int):
        self._start_ns = _platform_now_ns()
        self._worker_id = worker_id
        self._active = True

    @always_inline
    def elapsed_ns(self) -> UInt64:
        """Nanoseconds since this scope started. Const method — does NOT
        consume the scope; safe to peek mid-flight.
        """
        if not self._active:
            return UInt64(0)
        return _platform_now_ns() - self._start_ns

    @always_inline
    def worker_id(self) -> Int:
        return self._worker_id

    @always_inline
    def stop(mut self) -> UInt64:
        """Mark the scope finished and return its elapsed nanoseconds.

        Idempotent: subsequent calls return 0.
        """
        if not self._active:
            return UInt64(0)
        var elapsed = _platform_now_ns() - self._start_ns
        self._active = False
        return elapsed


# -----------------------------------------------------------------------------
# Named entry wrappers — name_id + payload, stored in MetricsSet's slabs
# -----------------------------------------------------------------------------


struct NamedCounter(Deinitable):
    """A registered (name, Counter) pair. Stored in MetricsSet.counters.

    `name_id` is the FNV-1a digest of a static literal (same registry
    family as spans). A `name_id == 0` slot is treated as empty by
    MetricsSet's lookup linear scan — FNV-1a never returns 0 for a
    non-empty input, so this sentinel is unambiguous.
    """

    var name_id: UInt32
    var counter: Counter

    def __init__(out self):
        self.name_id = UInt32(0)
        self.counter = Counter()


struct NamedTime(Deinitable):
    var name_id: UInt32
    var time: Time

    def __init__(out self):
        self.name_id = UInt32(0)
        self.time = Time()


struct NamedGauge(Deinitable):
    var name_id: UInt32
    var gauge: Gauge

    def __init__(out self):
        self.name_id = UInt32(0)
        self.gauge = Gauge()


# -----------------------------------------------------------------------------
# MetricsSnapshot — POD reduce result, suitable for cross-thread reads
# -----------------------------------------------------------------------------


comptime MAX_SNAPSHOT_ENTRIES: Int = MAX_COUNTERS + MAX_TIMES + MAX_GAUGES


struct MetricsSnapshotEntry(Copyable, Movable, Deinitable):
    """One reduced (name_id, kind, value) triple.

    `kind`: 0 = counter, 1 = time-ns, 2 = gauge. The simple int code
    avoids dragging in an enum dependency for what is fundamentally a
    POD payload.
    """

    var name_id: UInt32
    var kind: UInt8
    var value: Int64

    def __init__(out self):
        self.name_id = UInt32(0)
        self.kind = UInt8(0)
        self.value = Int64(0)

    def __init__(out self, name_id: UInt32, kind: UInt8, value: Int64):
        self.name_id = name_id
        self.kind = kind
        self.value = value


comptime METRIC_KIND_COUNTER: UInt8 = UInt8(0)
comptime METRIC_KIND_TIME: UInt8 = UInt8(1)
comptime METRIC_KIND_GAUGE: UInt8 = UInt8(2)


struct MetricsSnapshot(Copyable, Movable, Deinitable):
    """Reduced view of a MetricsSet. Returned by `MetricsSet.reduce()`.

    POD-shaped — embedders pass it across thread boundaries safely.
    EXPLAIN ANALYZE renders directly from this.

    Copyable: the entries array is `InlineArray[MetricsSnapshotEntry, _]`
    where `MetricsSnapshotEntry` is itself Copyable POD, so the snapshot
    is bitwise-copyable. EXPLAIN ANALYZE relies on this so the
    report builder can `.copy()` snapshots into its `List[...]` storage
    (List requires `T: Copyable`).
    """

    var entries: Array[MetricsSnapshotEntry, MAX_SNAPSHOT_ENTRIES]
    var n_entries: UInt8

    def __init__(out self):
        self.entries = Array[MetricsSnapshotEntry, MAX_SNAPSHOT_ENTRIES](
            fill=MetricsSnapshotEntry()
        )
        self.n_entries = UInt8(0)

    @always_inline
    def count(self) -> Int:
        return Int(self.n_entries)

    def append(mut self, name_id: UInt32, kind: UInt8, value: Int64) -> Bool:
        """Append a snapshot entry. Returns False if the snapshot is full."""
        var n = Int(self.n_entries)
        if n >= MAX_SNAPSHOT_ENTRIES:
            return False
        self.entries[n] = MetricsSnapshotEntry(name_id, kind, value)
        self.n_entries = UInt8(n + 1)
        return True

    def lookup(self, name_id: UInt32) -> Optional[Int64]:
        """Return the reduced value for `name_id` if present.

        Linear scan — capacity is small (max 16 entries total).
        """
        var n = Int(self.n_entries)
        for i in range(n):
            if self.entries[i].name_id == name_id:
                return Optional[Int64](self.entries[i].value)
        return Optional[Int64]()

    def merge_sum(mut self, other: MetricsSnapshot):
        """Merge `other` into `self` by summing values for matching
        `(name_id, kind)` pairs.

        Used by EXPLAIN ANALYZE to aggregate the per-worker
        operator snapshots after fork-join. Each per-worker MorselOperator
        instance reduces its own MetricsSet to a snapshot; the executor
        sums them across workers via this helper before appending to the
        ExecutionReport.

        Counters and Times sum naturally (worker totals stack). Gauges
        take the maximum (gauge-of-gauges semantics, matching
        `Gauge.reduce()`). New `(name_id, kind)` triples in `other`
        are appended; entries beyond `MAX_SNAPSHOT_ENTRIES` are dropped.
        """
        var n_other = Int(other.n_entries)
        for j in range(n_other):
            var name_id = other.entries[j].name_id
            var kind = other.entries[j].kind
            var value = other.entries[j].value
            var merged = False
            var n_self = Int(self.n_entries)
            for i in range(n_self):
                if (
                    self.entries[i].name_id == name_id
                    and self.entries[i].kind == kind
                ):
                    if kind == METRIC_KIND_GAUGE:
                        if value > self.entries[i].value:
                            self.entries[i].value = value
                    else:
                        self.entries[i].value += value
                    merged = True
                    break
            if not merged:
                _ = self.append(name_id, kind, value)


# -----------------------------------------------------------------------------
# MetricsSet — the per-operator-instance metrics aggregator
# -----------------------------------------------------------------------------


struct MetricsSet(Deinitable):
    """Per-operator-instance metric registry.

    Bounded by MAX_COUNTERS / MAX_TIMES / MAX_GAUGES. Operators register
    every metric they emit at construction time:

        var ms = MetricsSet()
        _ = ms.register_counter["rows_consumed"]()
        _ = ms.register_counter["groups_built"]()
        _ = ms.register_time["elapsed_compute"]()
        _ = ms.register_gauge["peak_groups_in_flight"]()

    Hot-path access from operator execute(). Worker-disjoint writes:

        ms.counter["rows_consumed"]().inc_in_pipeline(n, worker_id=wid)

    `MetricsSet` is NOT Movable — the underlying Slab[NamedCounter] holds
    Atomic[Int64] fields that propagate the restriction. Operators wrap
    the MetricsSet in `OwnedPointer[MetricsSet]` (see
    `new_owned_metrics_set`).
    """

    var counters: Slab[NamedCounter]
    var times: Slab[NamedTime]
    var gauges: Slab[NamedGauge]
    var n_counters: UInt8
    var n_times: UInt8
    var n_gauges: UInt8
    # Drop counter for over-capacity registrations — observable by
    # tests / EXPLAIN ANALYZE to surface "operator declared too many
    # metrics" without crashing the run.
    var dropped_registrations: AtomicI32

    # UNREGISTERED-LOOKUP counter. A one-slot Slab rather than a bare
    # `Atomic` field because the lookup accessors take `self` IMMUTABLY and get
    # their mutability from `Slab.get_mut_interior` — the same interior-
    # mutability primitive the accessors already return through. A bare
    # `Atomic` field cannot be `fetch_add`ed through an immutable `self`.
    var lookup_misses: Slab[Counter]

    def __init__(out self):
        # Pre-allocate every slot zero-filled (matches AtomicSlab's
        # historical zero-fill semantics: the inner Atomic[Int64] starts
        # at 0, which is the correct initial state for a counter).
        # +1 for the quarantine slot; see QUARANTINE_COUNTER above.
        self.counters = Slab[NamedCounter].create_prefilled(MAX_COUNTERS + 1)
        self.times = Slab[NamedTime].create_prefilled(MAX_TIMES + 1)
        self.gauges = Slab[NamedGauge].create_prefilled(MAX_GAUGES + 1)
        self.lookup_misses = Slab[Counter].create_prefilled(1)
        self.n_counters = UInt8(0)
        self.n_times = UInt8(0)
        self.n_gauges = UInt8(0)
        self.dropped_registrations = AtomicI32(Int32(0))

    # -------------------------------------------------------------------------
    # Registration
    # -------------------------------------------------------------------------

    def register_counter[name: StringLiteral](mut self) -> Bool:
        """Register a counter with comptime-known name. Returns False if
        full (and increments `dropped_registrations`).

        Idempotent: registering the same name twice returns True the
        first time and False on subsequent calls (the second call is
        a no-op, NOT a duplicate slot).
        """
        comptime name_id = _literal_name_id[name]()
        # Already registered?
        for i in range(Int(self.n_counters)):
            ref existing = self.counters.get_mut_interior(i)
            if existing.name_id == name_id:
                return False
        # Bounded?
        var n = Int(self.n_counters)
        if n >= MAX_COUNTERS:
            _ = self.dropped_registrations.fetch_add(Int32(1))
            return False
        # Claim the next slot. The slab byte storage is already
        # zero-filled (create_prefilled), so the Counter inside the
        # NamedCounter has every per_worker slot at 0 and the Atomic
        # at 0 — the correct initial state. We only patch in the name_id.
        ref slot = self.counters.get_mut_interior(n)
        slot.name_id = name_id
        self.n_counters = UInt8(n + 1)
        return True

    def register_time[name: StringLiteral](mut self) -> Bool:
        """Register a time metric with comptime-known name."""
        comptime name_id = _literal_name_id[name]()
        for i in range(Int(self.n_times)):
            ref existing = self.times.get_mut_interior(i)
            if existing.name_id == name_id:
                return False
        var n = Int(self.n_times)
        if n >= MAX_TIMES:
            _ = self.dropped_registrations.fetch_add(Int32(1))
            return False
        ref slot = self.times.get_mut_interior(n)
        slot.name_id = name_id
        self.n_times = UInt8(n + 1)
        return True

    def register_gauge[name: StringLiteral](mut self) -> Bool:
        """Register a gauge with comptime-known name."""
        comptime name_id = _literal_name_id[name]()
        for i in range(Int(self.n_gauges)):
            ref existing = self.gauges.get_mut_interior(i)
            if existing.name_id == name_id:
                return False
        var n = Int(self.n_gauges)
        if n >= MAX_GAUGES:
            _ = self.dropped_registrations.fetch_add(Int32(1))
            return False
        ref slot = self.gauges.get_mut_interior(n)
        slot.name_id = name_id
        self.n_gauges = UInt8(n + 1)
        return True

    # -------------------------------------------------------------------------
    # Lookup — returns ref to the inner primitive
    # -------------------------------------------------------------------------

    @always_inline
    def counter[name: StringLiteral](self) -> ref [MutUntrackedOrigin] Counter:
        """Lookup a registered Counter by comptime name.

        Returns a MUTABLE ref through immutable `self` — the Slab
        `get_mut_interior` interior-mutability primitive (the same
        pattern `MorselSinkImpl.consume(self, ...)` uses). The caller
        carries the disjoint-worker-slot invariant.

        An UNREGISTERED name is a COUNTED DROP: the miss is recorded in
        `num_unregistered_lookups()` and the returned ref is the QUARANTINE
        slot, which no read path can reach. It is NOT slot 0 — see
        `QUARANTINE_COUNTER`. Callers must still register every metric they
        emit; the difference is that failing to now loses the write instead of
        corrupting an unrelated metric.
        """
        comptime name_id = _literal_name_id[name]()
        for i in range(Int(self.n_counters)):
            ref slot = self.counters.get_mut_interior(i)
            if slot.name_id == name_id:
                return slot.counter
        # CALLER BUG — counted, then quarantined.
        #
        # NOT a `debug_assert`: its DEFAULT `assert_mode="none"` is live only
        # at `ASSERT=all`, so under `ASSERT=safe` or `ASSERT=none` it is dead
        # in EVERY build configuration, tests included. And NOT slot 0: the
        # first registered counter would then be incremented by a typo'd name
        # as if it were its own. The miss is counted and quarantined instead.
        self.lookup_misses.get_mut_interior(0).inc_out_of_pipeline(Int64(1))
        return self.counters.get_mut_interior(QUARANTINE_COUNTER).counter

    @always_inline
    def time[name: StringLiteral](self) -> ref [MutUntrackedOrigin] Time:
        """Lookup a registered Time by comptime name. See `counter` for
        the `ref [MutExternalOrigin]` contract.
        """
        comptime name_id = _literal_name_id[name]()
        for i in range(Int(self.n_times)):
            ref slot = self.times.get_mut_interior(i)
            if slot.name_id == name_id:
                return slot.time
        # CALLER BUG — counted, then quarantined. See `counter` above.
        self.lookup_misses.get_mut_interior(0).inc_out_of_pipeline(Int64(1))
        return self.times.get_mut_interior(QUARANTINE_TIME).time

    @always_inline
    def gauge[name: StringLiteral](self) -> ref [MutUntrackedOrigin] Gauge:
        """Lookup a registered Gauge by comptime name."""
        comptime name_id = _literal_name_id[name]()
        for i in range(Int(self.n_gauges)):
            ref slot = self.gauges.get_mut_interior(i)
            if slot.name_id == name_id:
                return slot.gauge
        # CALLER BUG — counted, then quarantined. See `counter` above.
        self.lookup_misses.get_mut_interior(0).inc_out_of_pipeline(Int64(1))
        return self.gauges.get_mut_interior(QUARANTINE_GAUGE).gauge

    # -------------------------------------------------------------------------
    # Capacity / introspection
    # -------------------------------------------------------------------------

    @always_inline
    def num_counters(self) -> Int:
        return Int(self.n_counters)

    @always_inline
    def num_times(self) -> Int:
        return Int(self.n_times)

    @always_inline
    def num_gauges(self) -> Int:
        return Int(self.n_gauges)

    @always_inline
    def num_dropped_registrations(self) -> Int:
        return Int(self.dropped_registrations.load())

    def num_unregistered_lookups(self) -> Int:
        """Lookups (`counter` / `time` / `gauge`) whose name was NOT registered.

        NON-ZERO MEANS WRITES WERE LOST. Each miss was sent to the quarantine
        slot instead of being applied to a real metric — which is the point:
        landing on slot 0, the first registered metric of that kind, would
        corrupt it silently.
        """
        return Int(self.lookup_misses.get_mut_interior(0).reduce())

    # -------------------------------------------------------------------------
    # reduce -- single-pass flatten across every registered entry.
    # -------------------------------------------------------------------------

    def reduce(self) -> MetricsSnapshot:
        """Flatten every registered Counter/Time/Gauge into a snapshot.

        Off the hot path. Called by EXPLAIN ANALYZE and by the unit tests.
        """
        var snap = MetricsSnapshot()
        # Counters -> snapshot.
        var nc = Int(self.n_counters)
        for i in range(nc):
            ref nc_slot = self.counters.get_mut_interior(i)
            var v = nc_slot.counter.reduce()
            _ = snap.append(nc_slot.name_id, METRIC_KIND_COUNTER, v)
        # Times.
        var nt = Int(self.n_times)
        for i in range(nt):
            ref nt_slot = self.times.get_mut_interior(i)
            var v = nt_slot.time.reduce()
            _ = snap.append(nt_slot.name_id, METRIC_KIND_TIME, v)
        # Gauges.
        var ng = Int(self.n_gauges)
        for i in range(ng):
            ref ng_slot = self.gauges.get_mut_interior(i)
            var v = ng_slot.gauge.reduce()
            _ = snap.append(ng_slot.name_id, METRIC_KIND_GAUGE, v)
        return snap^


# -----------------------------------------------------------------------------
# Owned construction helper
# -----------------------------------------------------------------------------


def new_owned_metrics_set() raises -> OwnedPointer[MetricsSet]:
    """Allocate + in-place construct a MetricsSet behind an OwnedPointer.

    `MetricsSet` is non-Movable (its inner Slab[NamedCounter] /
    NamedTime / NamedGauge hold Atomic[Int64] fields, which propagate
    the move restriction up the type tree). The standard
    `OwnedPointer[T](value=t^)` shape requires `T: Movable`, so this
    factory uses the `unsafe_from_raw_pointer=` constructor instead.

    Callers (every MorselOperatorImpl conformer that emits metrics) use
    this factory in `__init__` to populate their
    `_metrics: OwnedPointer[MetricsSet]` field.

    Lifetime contract: the returned OwnedPointer is single-owner; on
    drop it calls `MetricsSet.__del__` and frees the heap slot. No
    callers should bypass the OwnedPointer wrapper to extract the raw
    underlying pointer (encapsulation rule).
    """
    # SAFETY: alloc[MetricsSet](1) returns one slot of MetricsSet-sized
    # UNINITIALIZED bytes (a reused heap block holds whatever its last owner
    # left there). Every field is initialized in place through
    # `init_pointee_move` on a pointer to that field: plain assignment
    # (`raw[].counters = ...`) would first destroy the field's "old value",
    # running `Slab.__deinit__` over a garbage slot count and freeing a garbage
    # buffer pointer (komira-ai/komira#1072). `raw[].__init__()` is not an
    # option either: the compiler treats `out self` as a value-construction
    # site, not an interior-initialization site. Every field is written
    # exactly once, so the OwnedPointer below owns a fully constructed value.
    var raw = alloc[MetricsSet](1)
    # +1 for the quarantine slot; see QUARANTINE_COUNTER above. This is the
    # SECOND construction path — it initializes fields directly rather than
    # calling `__init__`, so it must mirror every field the ctor sets.
    UnsafePointer(to=raw[].counters).init_pointee_move(
        Slab[NamedCounter].create_prefilled(MAX_COUNTERS + 1)
    )
    UnsafePointer(to=raw[].times).init_pointee_move(
        Slab[NamedTime].create_prefilled(MAX_TIMES + 1)
    )
    UnsafePointer(to=raw[].gauges).init_pointee_move(
        Slab[NamedGauge].create_prefilled(MAX_GAUGES + 1)
    )
    UnsafePointer(to=raw[].lookup_misses).init_pointee_move(
        Slab[Counter].create_prefilled(1)
    )
    UnsafePointer(to=raw[].n_counters).init_pointee_move(UInt8(0))
    UnsafePointer(to=raw[].n_times).init_pointee_move(UInt8(0))
    UnsafePointer(to=raw[].n_gauges).init_pointee_move(UInt8(0))
    UnsafePointer(to=raw[].dropped_registrations).init_pointee_move(
        AtomicI32(Int32(0))
    )
    return OwnedPointer[MetricsSet](unsafe_from_raw_pointer=raw)
