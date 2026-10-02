# =============================================================================
# histogram.mojo — the distribution instrument
# =============================================================================
#
# ⭐ WHY THIS EXISTS. Without a histogram a p99 is inexpressible: nothing
# records a distribution. `MetricsSet.Time` looks like a latency instrument
# and is not: `Time.reduce()` is a SUM, and a sum has no distribution to
# recover. The histogram is a new instrument, not a rename of `Time`; `Time`
# itself stays for EXPLAIN ANALYZE, which wants the sum.
#
# -----------------------------------------------------------------------------
# ⭐⭐ `MetricPoint` CANNOT CARRY A HISTOGRAM, BY DESIGN
# -----------------------------------------------------------------------------
# `MetricPoint` has ONE `value_bits`. A histogram data point is count + sum +
# min + max + N buckets. `METRIC_HISTOGRAM` is a declared KIND on that struct,
# but there is nowhere for the buckets to go: an on-ring metric payload is
# `value(8) || attrset_id(4) || start_ns_delta(8)` = 20 B, and histogram
# buckets would spill to the arena beyond the inline bytes. A histogram record
# is a different on-ring shape.
#
# So `HistogramPoint` is a SIBLING of `MetricPoint`, not a change to it.
# `MetricPoint` is a fixed interface and it is untouched.
#
# ⛔ THE ALTERNATIVE WAS CONSIDERED AND REJECTED: lower a histogram to a FAMILY
# of `MetricPoint`s — count, sum, and one counter per bucket carrying a
# synthetic `le=<bound>` attribute. That is the Prometheus exposition shape and
# it works, but it mints `HISTOGRAM_BUCKETS + 2` = 14 attribute sets per
# histogram SERIES, multiplying cardinality by 14 against the 4096-attrset
# process ceiling (`attr_set.MAX_ATTRSETS`), and it throws away the real OTLP
# histogram message that interop relies on. Rejected on both counts. A
# Prometheus endpoint can do that lowering at EXPORT time, where it costs
# nothing in-process.
#
# -----------------------------------------------------------------------------
# ⚠ THE BUCKET BOUNDS — 11 BOUNDS / 12 BUCKETS
# -----------------------------------------------------------------------------
# 11 bounds => 12 buckets, so a record always takes the arena path
# (12 x 8 B + 20 B header = 116 B > 48 B).
#
# ⚠ THE VALUES ARE OTel'S DEFAULT LIST, TRUNCATED. OTel's published default
# explicit bucket boundaries are
# `[0, 5, 10, 25, 50, 75, 100, 250, 500, 750, 1000, 2500, 5000, 7500, 10000]` —
# FIFTEEN bounds, sixteen buckets. The first ELEVEN of that list are used here,
# so this is NOT a citation of an OTel default. Moving to the full list is a
# change to `HISTOGRAM_BOUNDS` and the 116 B arithmetic above, together.
#
# -----------------------------------------------------------------------------
# ⚠ Int64 VALUES ONLY, DELIBERATELY
# -----------------------------------------------------------------------------
# OTel histograms are doubles. Everything else here is Int64: the series
# table's value, `MetricsSet.Time`'s nanoseconds, `MetricPoint.as_int`.
# A Float64 histogram alongside an Int64 everything-else is a second numeric
# path through the sweep, the reduction and the encoder for no case anyone has
# asked for — the instrument's first user is latency in nanoseconds. If a
# double histogram is ever needed, it is a flag on `HistogramPoint` and a
# second `record` overload, not a rewrite.
#
# -----------------------------------------------------------------------------
# ⭐ EVERY MECHANISM HERE IS PINNED BY A TEST THAT FAILS WHEN IT ALONE BREAKS
# -----------------------------------------------------------------------------
# `tests/test_histogram.mojo` plus the sweep's histogram arm in
# `tests/test_metric_sweep.mojo`. Each break, applied on its own, reds a test:
#
#   mechanism             the break                failing assertion
#   -------------------   ----------------------   -------------------------
#   bound/index AGREE     `histogram_bucket_       "one PAST bound #6 lands in
#                         index` bound 6 moved     the next bucket"
#                         100 -> 128, the BOUND
#                         list untouched
#   merge's empty-side    the `other.count == 0`   "does NOT drag the min to
#   guard                 early return disabled    0"
#   fresh value on        `values[idx] =           "the re-claimed slot starts
#   slot CLAIM            HistogramValue()`        at ONE"
#                         deleted from `_slot_for`
#   the DELTA reset       `take_slot_delta`        interval 2's count (in the
#                         returns without          sweep test)
#                         `reset()`
#   the SHARED batch      the histogram arm given  first tick emitted
#   ceiling               its own budget
#
# Encapsulation: `InlineArray` of POD + a `Slab[HistogramTable]`. No
# `UnsafePointer` in any signature, no wildcard origin.
# =============================================================================

from std.sys import size_of

from komira_core.collections import Slab

from komira_metrics.metric_point import METRIC_HISTOGRAM
from komira_metrics.metrics_set import MAX_WORKERS
from komira_metrics.series_table import (
    _mix64,
    series_key,
    series_key_attrset_id,
    series_key_name_id,
)


# See the header. 11 bounds, 12 buckets, the last one being +Inf.
comptime HISTOGRAM_BOUNDS: Int = 11
comptime HISTOGRAM_BUCKETS: Int = HISTOGRAM_BOUNDS + 1

# Histogram SERIES per worker. ⚠ NOT `MAX_SERIES_PER_WORKER`: a
# `HistogramValue` is 128 B against a scalar slot's 16 B, so 4096 of them would
# be 512 KiB per worker / 32 MiB per process — six times the ENTIRE scalar table
# and straight past the point where the series table's size argument holds. 256
# is `MAX_REGISTERED_NAMES` (`name_registry.mojo`) and one
# sixteenth of the scalar ceiling; histograms are the rarest instrument and the
# most expensive per series, which is the same direction.
#
#     keys      256 x   8 B =  2048 B
#     values    256 x 128 B = 32768 B
#     scopes    256 x   4 B =  1024 B
#     occupied    4 x   8 B =    32 B
#     counters              =    16 B
#                           ---------
#     per worker            = 35888 B = 35.0 KiB
#     x MAX_WORKERS 64      =  2.19 MiB per process
comptime MAX_HISTOGRAM_SERIES_PER_WORKER: Int = 256
comptime HISTOGRAM_BITSET_WORDS: Int = (
    MAX_HISTOGRAM_SERIES_PER_WORKER + 63
) // 64
# Bounded like the series table's, and for the same reason: this is a hot path.
comptime HISTOGRAM_MAX_PROBE: Int = 32
comptime HISTOGRAM_SLOT_NONE: Int = -1


@always_inline
def histogram_bound(i: Int) -> Int64:
    """The upper bound of bucket `i`, for `i` in `[0, HISTOGRAM_BOUNDS)`.

    ⚠ THIS AND `histogram_bucket_index` ARE TWO SPELLINGS OF ONE LIST, and a
    drift between them would put observations in a bucket whose exported bound
    says something else — silently, because both would still be well-formed.
    `test_histogram.mojo` asserts they agree for every bound and for the values
    either side of each."""
    if i == 0:
        return Int64(0)
    if i == 1:
        return Int64(5)
    if i == 2:
        return Int64(10)
    if i == 3:
        return Int64(25)
    if i == 4:
        return Int64(50)
    if i == 5:
        return Int64(75)
    if i == 6:
        return Int64(100)
    if i == 7:
        return Int64(250)
    if i == 8:
        return Int64(500)
    if i == 9:
        return Int64(750)
    return Int64(1000)


@always_inline
def histogram_bucket_index(v: Int64) -> Int:
    """The bucket `v` falls in. Bucket `i < HISTOGRAM_BOUNDS` counts
    `v <= histogram_bound(i)`; bucket `HISTOGRAM_BOUNDS` is +Inf.

    An unrolled comparison chain rather than a loop over an array, because this
    runs once per observation and building an 11-element array per call to walk
    it would be the entire hot-path budget."""
    if v <= Int64(0):
        return 0
    if v <= Int64(5):
        return 1
    if v <= Int64(10):
        return 2
    if v <= Int64(25):
        return 3
    if v <= Int64(50):
        return 4
    if v <= Int64(75):
        return 5
    if v <= Int64(100):
        return 6
    if v <= Int64(250):
        return 7
    if v <= Int64(500):
        return 8
    if v <= Int64(750):
        return 9
    if v <= Int64(1000):
        return 10
    return HISTOGRAM_BOUNDS


struct HistogramValue(Copyable, Movable, Deinitable):
    """One series' accumulated distribution. 128 B, POD.

    ⚠ `min` / `max` ARE ONLY MEANINGFUL WHEN `count > 0`. A zero-observation
    value carries `min = 0, max = 0`, which is indistinguishable from a single
    observation of 0 — read `count` first. They are stored rather than derived
    because a bucketed distribution CANNOT recover them: every observation in
    the +Inf bucket is "greater than 1000" and nothing more."""

    var count: UInt64
    var sum: Int64
    var min: Int64
    var max: Int64
    var buckets: Array[UInt64, HISTOGRAM_BUCKETS]

    def __init__(out self):
        self.count = UInt64(0)
        self.sum = Int64(0)
        self.min = Int64(0)
        self.max = Int64(0)
        self.buckets = Array[UInt64, HISTOGRAM_BUCKETS](fill=UInt64(0))

    @always_inline
    def record(mut self, v: Int64):
        """One observation. Bucket increment + four scalar updates."""
        if self.count == UInt64(0):
            self.min = v
            self.max = v
        else:
            if v < self.min:
                self.min = v
            if v > self.max:
                self.max = v
        self.count += UInt64(1)
        self.sum += v
        self.buckets[histogram_bucket_index(v)] += UInt64(1)

    def merge(mut self, other: HistogramValue):
        """Fold another worker's accumulation in. The reduction step, and the
        reason a histogram reduces correctly across 64 tables at all: bucket
        counts are ADDITIVE, which a percentile is not."""
        if other.count == UInt64(0):
            return
        if self.count == UInt64(0):
            self.min = other.min
            self.max = other.max
        else:
            if other.min < self.min:
                self.min = other.min
            if other.max > self.max:
                self.max = other.max
        self.count += other.count
        self.sum += other.sum
        for i in range(HISTOGRAM_BUCKETS):
            self.buckets[i] += other.buckets[i]

    def reset(mut self):
        """DELTA temporality: the sweep takes the distribution and zeroes it,
        exactly as `SeriesTable.take_slot_delta` does for a scalar."""
        self.count = UInt64(0)
        self.sum = Int64(0)
        self.min = Int64(0)
        self.max = Int64(0)
        for i in range(HISTOGRAM_BUCKETS):
            self.buckets[i] = UInt64(0)


struct HistogramPoint(Copyable, Movable, Deinitable):
    """The decoded histogram data point — `MetricPoint`'s SIBLING.

    Field order and names deliberately mirror `MetricPoint` up to the payload,
    so an encoder and any exporter can share the header handling. `kind` is
    always `METRIC_HISTOGRAM` and is carried anyway, so a consumer's CLOSED
    discriminant switch works uniformly over both record shapes."""

    var name_id: UInt32
    var scope_id: UInt32
    var attrset_id: UInt32
    var kind: UInt8
    var flags: UInt8
    var _pad: Array[UInt8, 2]
    var start_time_unix_ns: UInt64
    var time_unix_ns: UInt64
    var count: UInt64
    var sum: Int64
    var min: Int64
    var max: Int64
    var buckets: Array[UInt64, HISTOGRAM_BUCKETS]

    def __init__(out self):
        self.name_id = UInt32(0)
        self.scope_id = UInt32(0)
        self.attrset_id = UInt32(0)
        self.kind = METRIC_HISTOGRAM
        self.flags = UInt8(0)
        self._pad = Array[UInt8, 2](fill=UInt8(0))
        self.start_time_unix_ns = UInt64(0)
        self.time_unix_ns = UInt64(0)
        self.count = UInt64(0)
        self.sum = Int64(0)
        self.min = Int64(0)
        self.max = Int64(0)
        self.buckets = Array[UInt64, HISTOGRAM_BUCKETS](fill=UInt64(0))

    @always_inline
    def bucket(self, i: Int) -> UInt64:
        return self.buckets[i]

    def bucket_upper_bound(self, i: Int) -> Optional[Int64]:
        """The exported bound for bucket `i`. **None for the +Inf bucket**,
        which is a value and not a missing number — an exporter that rendered
        +Inf as some large integer would make the last bucket look bounded."""
        if i < 0 or i >= HISTOGRAM_BUCKETS:
            return Optional[Int64]()
        if i == HISTOGRAM_BOUNDS:
            return Optional[Int64]()
        return Optional[Int64](histogram_bound(i))


def histogram_point(
    name_id: UInt32,
    scope_id: UInt32,
    attrset_id: UInt32,
    value: HistogramValue,
    start_time_unix_ns: UInt64,
    time_unix_ns: UInt64,
) -> HistogramPoint:
    """A DELTA histogram point over `[start, time)`. Mirrors
    `counter_point` / `gauge_point` in `metric_point.mojo`, and exists for the
    same reason: the fields that MUST agree are set in one place."""
    var p = HistogramPoint()
    p.name_id = name_id
    p.scope_id = scope_id
    p.attrset_id = attrset_id
    p.start_time_unix_ns = start_time_unix_ns
    p.time_unix_ns = time_unix_ns
    p.count = value.count
    p.sum = value.sum
    p.min = value.min
    p.max = value.max
    for i in range(HISTOGRAM_BUCKETS):
        p.buckets[i] = value.buckets[i]
    return p^


struct HistogramTable(Copyable, Movable, Deinitable):
    """ONE worker's private `(name_id, attrset_id) -> HistogramValue` table.

    Same probe, same occupancy discipline and the same conflict rule as
    `SeriesTable` — see that file's header for why the key must be MIXED and why
    the probe is BOUNDED on a hot path. It is a separate struct rather than a
    parameterised `SeriesTable` because the value is 128 B rather than 8 and the
    ceiling is 256 rather than 4096; sharing the struct would have meant sharing
    the WORSE of each.

    ⚠ SINGLE-WRITER BY CONTRACT, like every per-worker structure here.

    ⭐ A ZERO-FILLED `HistogramTable` IS A VALID EMPTY TABLE."""

    var keys: Array[UInt64, MAX_HISTOGRAM_SERIES_PER_WORKER]
    var values: Array[HistogramValue, MAX_HISTOGRAM_SERIES_PER_WORKER]
    var scopes: Array[UInt32, MAX_HISTOGRAM_SERIES_PER_WORKER]
    var occupied: Array[UInt64, HISTOGRAM_BITSET_WORDS]
    var n_live: UInt32
    var n_overflowed: UInt32
    var n_conflicts: UInt32
    var _pad: UInt32

    def __init__(out self):
        self.keys = Array[UInt64, MAX_HISTOGRAM_SERIES_PER_WORKER](
            fill=UInt64(0)
        )
        self.values = Array[
            HistogramValue, MAX_HISTOGRAM_SERIES_PER_WORKER
        ](fill=HistogramValue())
        self.scopes = Array[UInt32, MAX_HISTOGRAM_SERIES_PER_WORKER](
            fill=UInt32(0)
        )
        self.occupied = Array[UInt64, HISTOGRAM_BITSET_WORDS](
            fill=UInt64(0)
        )
        self.n_live = UInt32(0)
        self.n_overflowed = UInt32(0)
        self.n_conflicts = UInt32(0)
        self._pad = UInt32(0)

    @always_inline
    def is_occupied(self, idx: Int) -> Bool:
        return (
            self.occupied[idx >> 6] & (UInt64(1) << UInt64(idx & 63))
        ) != UInt64(0)

    def _slot_for(
        mut self, key: UInt64, scope_id: UInt32, insert: Bool
    ) -> Int:
        var idx = Int(
            _mix64(key) & UInt64(MAX_HISTOGRAM_SERIES_PER_WORKER - 1)
        )
        var probe = 0
        while probe < HISTOGRAM_MAX_PROBE:
            if not self.is_occupied(idx):
                if not insert:
                    return HISTOGRAM_SLOT_NONE
                self.occupied[idx >> 6] = self.occupied[idx >> 6] | (
                    UInt64(1) << UInt64(idx & 63)
                )
                self.keys[idx] = key
                self.values[idx] = HistogramValue()
                self.scopes[idx] = scope_id
                self.n_live += UInt32(1)
                return idx
            if self.keys[idx] == key:
                # ⛔ REFUSE, never overwrite — see `series_table.mojo`.
                if self.scopes[idx] != scope_id:
                    self.n_conflicts += UInt32(1)
                    return HISTOGRAM_SLOT_NONE
                return idx
            idx = (idx + 1) & (MAX_HISTOGRAM_SERIES_PER_WORKER - 1)
            probe += 1
        if insert:
            self.n_overflowed += UInt32(1)
        return HISTOGRAM_SLOT_NONE

    def record(
        mut self,
        name_id: UInt32,
        scope_id: UInt32,
        attrset_id: UInt32,
        v: Int64,
    ) -> Bool:
        """The hot path: one hash, one probe, one bucket increment."""
        var idx = self._slot_for(
            series_key(name_id, attrset_id), scope_id, True
        )
        if idx == HISTOGRAM_SLOT_NONE:
            return False
        self.values[idx].record(v)
        return True

    def lookup(
        mut self, name_id: UInt32, attrset_id: UInt32
    ) -> Optional[HistogramValue]:
        var key = series_key(name_id, attrset_id)
        var idx = Int(
            _mix64(key) & UInt64(MAX_HISTOGRAM_SERIES_PER_WORKER - 1)
        )
        var probe = 0
        while probe < HISTOGRAM_MAX_PROBE:
            if not self.is_occupied(idx):
                return Optional[HistogramValue]()
            if self.keys[idx] == key:
                return Optional[HistogramValue](self.values[idx].copy())
            idx = (idx + 1) & (MAX_HISTOGRAM_SERIES_PER_WORKER - 1)
            probe += 1
        return Optional[HistogramValue]()

    def next_occupied(self, from_idx: Int) -> Int:
        var i = from_idx
        if i < 0:
            i = 0
        while i < MAX_HISTOGRAM_SERIES_PER_WORKER:
            var w = i >> 6
            var word = self.occupied[w] >> UInt64(i & 63)
            if word == UInt64(0):
                i = (w + 1) << 6
                continue
            while (word & UInt64(1)) == UInt64(0):
                word = word >> UInt64(1)
                i += 1
            return i
        return HISTOGRAM_SLOT_NONE

    @always_inline
    def slot_key(self, idx: Int) -> UInt64:
        return self.keys[idx]

    @always_inline
    def slot_scope(self, idx: Int) -> UInt32:
        return self.scopes[idx]

    @always_inline
    def slot_value(self, idx: Int) -> HistogramValue:
        return self.values[idx].copy()

    def take_slot_delta(mut self, idx: Int) -> HistogramValue:
        """Read the distribution and zero it. The slot stays OCCUPIED — the
        series still exists, it just has no unexported observations."""
        var out = self.values[idx].copy()
        self.values[idx].reset()
        return out^

    def merge_into_slot(
        mut self,
        name_id: UInt32,
        scope_id: UInt32,
        attrset_id: UInt32,
        other: HistogramValue,
    ) -> Bool:
        """Fold `other` into this table's slot for the series, creating it if
        needed. This is what the sweep's reduction scratch uses."""
        var idx = self._slot_for(
            series_key(name_id, attrset_id), scope_id, True
        )
        if idx == HISTOGRAM_SLOT_NONE:
            return False
        self.values[idx].merge(other)
        return True

    def clear(mut self):
        """Occupancy and counters only — every read is gated by occupancy, so
        re-zeroing 35 KiB of value bytes nothing can observe would make the
        sweep's per-generation reset far more expensive than it needs to be.

        ⚠ THE VALUES ARE ZEROED ON CLAIM, NOT HERE: `_slot_for` assigns a fresh
        `HistogramValue()` when it marks a slot occupied. Without that a
        re-claimed slot would inherit the previous generation's buckets."""
        for i in range(HISTOGRAM_BITSET_WORDS):
            self.occupied[i] = UInt64(0)
        self.n_live = UInt32(0)
        self.n_overflowed = UInt32(0)
        self.n_conflicts = UInt32(0)

    @always_inline
    def live_count(self) -> Int:
        return Int(self.n_live)


struct HistogramTables(Movable, Deinitable):
    """The `MAX_WORKERS` per-worker histogram tables, heap-owned. Same shape,
    same reasons, as `SeriesTables` — including no `ref` accessor."""

    var _tables: Slab[HistogramTable]

    def __init__(out self):
        self._tables = Slab[HistogramTable].create_prefilled(MAX_WORKERS)

    def record(
        mut self,
        worker_id: Int,
        name_id: UInt32,
        scope_id: UInt32,
        attrset_id: UInt32,
        v: Int64,
    ) -> Bool:
        if worker_id < 0 or worker_id >= MAX_WORKERS:
            return False
        return self._tables[worker_id].record(
            name_id, scope_id, attrset_id, v
        )

    def next_occupied(mut self, worker_id: Int, from_idx: Int) -> Int:
        return self._tables[worker_id].next_occupied(from_idx)

    def slot_key(mut self, worker_id: Int, idx: Int) -> UInt64:
        return self._tables[worker_id].slot_key(idx)

    def slot_scope(mut self, worker_id: Int, idx: Int) -> UInt32:
        return self._tables[worker_id].slot_scope(idx)

    def take_slot_delta(mut self, worker_id: Int, idx: Int) -> HistogramValue:
        return self._tables[worker_id].take_slot_delta(idx)

    def reduce(
        mut self, name_id: UInt32, attrset_id: UInt32
    ) -> HistogramValue:
        """Fold one series across every worker. Off the hot path; does NOT
        reset, so a reader cannot consume the sweep's data."""
        var out = HistogramValue()
        for w in range(MAX_WORKERS):
            var v = self._tables[w].lookup(name_id, attrset_id)
            if v:
                out.merge(v.value())
        return out^

    def live_series(mut self) -> Int:
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
# Compile-time SIZE anchors. ⛔ NOT POD GUARDS (`metric_point.mojo` records the
# measurement that killed that claim). What they buy is a number READ by
# `test_histogram.mojo`, which is the only thing keeping this header's 35.0 KiB
# / 2.19 MiB arithmetic honest.
# -----------------------------------------------------------------------------
comptime _HISTOGRAM_VALUE_SIZE_GUARD: Int = size_of[HistogramValue]()
comptime _HISTOGRAM_POINT_SIZE_GUARD: Int = size_of[HistogramPoint]()
comptime _HISTOGRAM_TABLE_SIZE_GUARD: Int = size_of[HistogramTable]()
