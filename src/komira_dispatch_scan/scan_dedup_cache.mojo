# =============================================================================
# ScanDedupCache -- EngineContext-scoped cross-query scan-deduplication cache
# =============================================================================
#
# Companion to the parquet footer cache and the parquet column-stats cache:
# where those amortize the FOOTER parse and per-column STATS lookups, this cache
# amortizes the FULL parquet read+decode for plan-fragment shaped scans that are
# re-issued across separate executions on one session.
#
# Motivation: TPC-H q11 runs the same three-table join TWICE per query (once for
# the threshold subquery, once for the outer query), each time as a fresh plan
# with fresh scans of nation / supplier / partsupp. The within-plan scan dedup
# pass operates within ONE LogicalPlan only; it cannot see across calls. DuckDB
# materializes the shared subplan once as a CTE.
#
# Architecture (transparent):
#   - EngineContext owns one `ScanDedupCache` field.
#   - The scan dedup pass consults this cache per scan (NOT per ≥2-duplicate
#     group, since cross-call reuse fires even for single-occurrence scans
#     within one call).
#   - Cache hit → rewrite the scan to PLAN_SCAN(SOURCE_IN_MEMORY) referencing
#     a synthetic name in the per-call InMemoryRegistry, which is handed what
#     `lookup_copy` returns: an Arc SHARE of the cached buffers, not a copy of
#     them.
#   - Cache miss → materialize via `materialize_parquet_collect`, store the
#     result in BOTH the session cache AND the per-call registry.
#
# Eligibility:
#   - Source must be SOURCE_PARQUET.
#   - Row count must be known and ≤ the scan dedup pass's row threshold (10M).
#   - Pushed filter, projection, and source path are all part of the cache
#     key (collision-free: a lineitem scan with a discount filter must NOT
#     collide with an unfiltered lineitem scan).
#
# Concurrency: NOT thread-safe. Mutated only from the EngineContext-owning
# thread. The scan dedup pass runs SERIALLY at plan compile (single-threaded by
# construction; worker threads run AFTER plan compile is complete and never
# touch the cache).
#
# BOUND: this cache is HARD-BOUNDED on TWO axes with LRU eviction so it can
# NEVER OOM a persistent-runtime harness that drives MANY DISTINCT scans on ONE
# shared ctx. Each `insert` bumps an access clock; each `lookup_copy` HIT
# touches it (LRU). When a fresh insert pushes the cache over EITHER cap (entry
# count `_max_entries`, default 64; total array-memory bytes `_max_bytes`,
# default 1 GiB), the oldest (smallest last_access) entries are evicted until
# BOTH caps are satisfied OR only the just-inserted entry remains (so a single
# oversized batch is still cached rather than thrash-dropped; the ceiling is a
# hard multi-entry bound, soft only in the degenerate one-batch-bigger-than-the-
# whole-cap case). The common few-distinct-scan workload (a handful of
# distinct scans, well under 1 GiB) NEVER evicts; only the pathological
# many-distinct-key workload evicts.
#
# EVICTION SAFETY (lifetime): the cache owns each cached RecordBatch
# (`Slab[_ScanDedupEntry]` → `entry.batch`, held BY VALUE), and evicting an
# entry (Slab.take_at → drop) can dangle NOTHING. `lookup_copy` Arc-SHARES
# share-eligible columns, so a consumer CAN still hold the cached buffers after
# eviction; safety rests on the Arc itself -- eviction drops one REFERENCE, and
# the bytes die when the LAST holder releases. The real cost is accounting, not
# lifetime: see `_total_bytes` over-reporting in `lookup_copy`'s body.
# `_ScanDedupEntry` is a Movable value in a `Slab` (NO wildcard origins, NO
# UnsafePointer in any signature), the shape `clear()` relies on to drop every
# batch at once; eviction reuses that teardown (a single-entry `take_at`).
#
# DuckDB reference pattern: `external_file_cache` on `Database` /
# `ClientContext` (~25% of system memory, LRU-evicted). We follow the same
# shape: the PRODUCTION cache (EngineContext) is sized to AVAILABLE RAM at ctx
# init (`ScanDedupCache.ram_sized(max_bytes_flag)` ->
# `resolve_scan_dedup_max_bytes`): a safe fraction of `min(host MemAvailable,
# this scope's cgroup memory.max)`, clamped to [SCAN_DEDUP_MIN_BYTES,
# SCAN_DEDUP_MAX_BYTES_CEILING]. This lets a RAM-rich session hold a full
# benchmark working set larger than a fixed 1 GiB cap without thrashing it,
# while staying host-OOM-safe (free-RAM-relative and cgroup-aware, so
# co-located processes and capped runs stay safe). `max_bytes_flag` (bytes, or a
# `G`/`M`/`K` suffix) is the explicit operator knob. The zero-arg ctor keeps the
# fixed 1 GiB default (`SCAN_DEDUP_MAX_BYTES_DEFAULT`) for deterministic tests +
# the RAM-unknown (macOS / no procfs) fallback.
# =============================================================================

from komira_arrow.schema import RecordBatch
from komira_collections.slab import Slab
from komira_column_kernels.compiler_helpers import (
    copy_batch,
    share_batch_like_copy,
)

# The RAM-basis probe lives in `komira_host.proc_probe`.
from komira_host.proc_probe import detect_scan_cache_ram_basis_bytes


# =============================================================================
# Caps -- conservative fixed hard ceiling (documented; a bound, not a knob)
# =============================================================================
#
# ENTRY-COUNT cap: 64. An analytic session typically has a handful of distinct
# scans (the q11 shape has 3), so 64 leaves wide headroom — the common case
# never reaches it, so it never evicts.
comptime SCAN_DEDUP_MAX_ENTRIES_DEFAULT: Int = 64

# TOTAL-BYTES cap: 1 GiB of cached array-memory. The common few-scan workload
# caches small filtered/projected batches well under this (never evicts). A
# runaway harness driving dozens of distinct LARGE scans (each ≤10M rows per the
# pass's row-threshold eligibility) hits this ceiling and evicts LRU — a hard
# guard against a multi-GB accumulation exhausting host memory. 1 GiB leaves
# ample headroom for the runtime and co-located processes while still
# holding a handful of legitimate large cached batches.
comptime SCAN_DEDUP_MAX_BYTES_DEFAULT: Int = 1 << 30  # 1 GiB


# =============================================================================
# RAM-adaptive byte-budget sizing
# =============================================================================
#
# A persistent EngineContext amortizes scan-dedup ONLY when the byte budget
# holds the working set. Under a fixed 1 GiB cap a larger working set
# THRASHES the LRU -> full re-miss every rep -> ~zero benefit. So the budget is
# sized to AVAILABLE RAM at ctx init instead of a fixed cap, while keeping the
# host-OOM-safety a fixed cap gives.

# Fraction of the free-RAM basis to devote to the cache. 30% sits in a 25-40%
# band with generous headroom: on a capped/pod scope the
# basis is that scope's cgroup memory.max, so 30% leaves 70% for execution +
# heap; on an uncapped box the basis is host MemAvailable and the ceiling binds
# first. (The cache accounts ARRAY bytes, an under-count of true RSS, so a
# conservative fraction is deliberate.)
comptime SCAN_DEDUP_MEM_FRACTION_PCT: Int = 30

# FLOOR: never size below this. A very RAM-constrained basis yields a small but
# still-useful cache; keeping it above zero avoids a degenerate no-cache. 256
# MiB is well below the 1 GiB fixed default, so a constrained box gets LESS
# than the fixed default.
comptime SCAN_DEDUP_MIN_BYTES: Int = 256 * 1024 * 1024  # 256 MiB

# HARD CEILING: never size above this regardless of how much RAM is free. 8 GiB
# holds a large benchmark working set with room to spare — a guaranteed bound
# so even a 512 GiB box can't let the cache balloon.
comptime SCAN_DEDUP_MAX_BYTES_CEILING: Int = 8 << 30  # 8 GiB

# The explicit operator knob forces the byte budget outright: the
# `max_bytes_flag` argument of `resolve_scan_dedup_max_bytes`, bytes or a
# `G`/`M`/`K` (1024-based) suffix (e.g. `8G`). The caller reads it from a flag.


# The byte-size parse lives in `komira_exec_types.byte_size` so the parquet
# session-mmap-pin budget can share it: a second definition of what `8G` means
# is a bug waiting for the day the two drift.
#
# The alias keeps `_parse_byte_size` importable from THIS module, which is where
# `tests/test_scan_dedup_cache_ram_sizing.mojo` reads it from.
from komira_exec_types.byte_size import parse_byte_size as _parse_byte_size


def _scan_dedup_budget_from_ram(ram_basis_bytes: Int, override_bytes: Int) -> Int:
    """Pure budget policy: given a free-RAM basis and an explicit override,
    return the byte budget. Order:
      1. `override_bytes > 0` wins outright (the operator knob).
      2. `ram_basis_bytes <= 0` (RAM unknown / macOS) -> the fixed 1 GiB
         default (the fallback).
      3. otherwise a `SCAN_DEDUP_MEM_FRACTION_PCT`% fraction of the basis,
         clamped to [`SCAN_DEDUP_MIN_BYTES`, `SCAN_DEDUP_MAX_BYTES_CEILING`].

    No FFI — the deterministic core the unit test drives with explicit inputs.
    """
    if override_bytes > 0:
        return override_bytes
    if ram_basis_bytes <= 0:
        return SCAN_DEDUP_MAX_BYTES_DEFAULT
    var budget = ram_basis_bytes * SCAN_DEDUP_MEM_FRACTION_PCT // 100
    if budget < SCAN_DEDUP_MIN_BYTES:
        budget = SCAN_DEDUP_MIN_BYTES
    if budget > SCAN_DEDUP_MAX_BYTES_CEILING:
        budget = SCAN_DEDUP_MAX_BYTES_CEILING
    return budget


def resolve_scan_dedup_max_bytes(max_bytes_flag: String) -> Int:
    """Resolve the production scan-dedup byte budget at EngineContext init:
    the explicit override `max_bytes_flag` if it parses to a positive size
    (an empty or malformed value is ignored), else a safe fraction of the
    free-RAM basis (host MemAvailable min the scope's cgroup memory.max), else
    the fixed 1 GiB default. See `_scan_dedup_budget_from_ram` for the policy."""
    var override_bytes = _parse_byte_size(max_bytes_flag)
    var ram = detect_scan_cache_ram_basis_bytes()
    return _scan_dedup_budget_from_ram(ram, override_bytes)


@always_inline
def _estimate_batch_bytes(batch: RecordBatch) -> Int:
    """Sum the array-memory footprint of `batch` (mirrors the intent of
    Arrow's `RecordBatch::get_array_memory_size` and of
    `ExternalSorter._estimate_batch_bytes`). Per column: the primary data
    buffer + the optional offsets buffer + the validity bitmap (bits→bytes) +
    the optional dictionary-values buffer (so a dict-encoded low-card string
    column counts BOTH its codes in `_data` AND its dictionary in `_dict_data`,
    the exact multi-table dedup shape).

    Field reads only — no pointer crosses a function boundary (the encapsulation
    rule): every `.len()` / `.length` returns an Int scalar. The estimate is a
    close upper bound on resident bytes; it is used only to enforce the memory
    ceiling, so a small over-count (e.g. shared dict pages) is safe (evicts
    slightly earlier, never later)."""
    var total = 0
    var nc = batch.num_columns()
    for c in range(nc):
        ref col = batch.column_at(c)
        total += col._data.len()
        if col._offsets:
            total += col._offsets.value().len()
        if col._validity:
            # Bitmap stores `length` in BITS; storage is (length+7)>>3 bytes.
            total += (col._validity.value().length + 7) >> 3
        if col._dict_data:
            total += col._dict_data.value().len()
    return total


# =============================================================================
# _ScanDedupEntry -- one cached materialized RecordBatch
# =============================================================================


struct _ScanDedupEntry(Movable):
    """One cached materialized scan result.

    Owns the RecordBatch by value (Slab[RecordBatch] → entry.batch).

    `lookup_copy` Arc-SHARES by default (the cache's `share_on`, default
    True); the deep `copy_batch` is that switch's OFF arm, which is its
    differential oracle. The per-hit cost of this cache is O(ncols)
    refcount bumps, NOT a memcpy of the cached relation -- the distinction a
    reader sizing this cache needs.

    Fields:
        key:         Cache key (path \\0 filter_fp \\0 projection_fp).
        batch:       Materialized RecordBatch (the result of one
                     `materialize_parquet_collect` call).
        hit_count:   Number of cache hits served from this entry. Test
                     hook + verification signal.
        last_access: Monotonic access-clock value stamped on insert and bumped
                     on every `lookup_copy` HIT — the LRU key (smallest ==
                     oldest == first evicted).
        nbytes:      Cached `_estimate_batch_bytes(batch)` at insert time —
                     the entry's contribution to the cache's `_total_bytes`
                     (recorded so eviction can subtract it in O(1) without
                     re-walking the batch).
    """

    var key: String
    var batch: RecordBatch
    var hit_count: Int
    var last_access: UInt64
    var nbytes: Int

    def __init__(
        out self,
        var key: String,
        var batch: RecordBatch,
        last_access: UInt64,
        nbytes: Int,
    ):
        self.key = key^
        self.batch = batch^
        self.hit_count = 0
        self.last_access = last_access
        self.nbytes = nbytes


# =============================================================================
# ScanDedupCache -- borrow-only cross-query scan cache
# =============================================================================


struct ScanDedupCache(Movable, Deinitable):
    """EngineContext-scoped cache of materialized scan results.

    Storage layout (mirrors ParquetMetadataCache for consistency):
        - `_entries: Slab[_ScanDedupEntry]`. Linear-scan lookup keyed on the
          composite cache key (path + filter fingerprint + projection
          fingerprint). Bounded to `_max_entries` entries; linear scan is
          well under L1 cache pressure.

    Bound: capped on entry count AND total array-memory bytes
    with LRU eviction — see the module header. `_access_clock` is the monotonic
    LRU clock; `_total_bytes` tracks the running sum of every live entry's
    `nbytes`.

    Lifetime: owned by the session that holds it; drops with that owner.

    Concurrency: NOT thread-safe. See module-header comment.

    Test hooks:
        - `size()` — number of entries (= number of distinct scans cached).
        - `miss_count` — total cache misses (= number of materializations).
        - `hit_count_for(key)` — per-entry hit count (useful for verifying
          which entries fire on q11's two-call shape).
        - `total_bytes()` / `max_entries()` / `max_bytes()` — bound inspection.
    """

    var _entries: Slab[_ScanDedupEntry]
    var _miss_count: Int
    """Total cache misses (= number of `materialize_parquet_collect` calls
    that bypassed the cache). Test hook."""

    var _hit_count: Int
    """Total cache HITS across every key. The per-key
    `hit_count_for` cannot
    answer the whole-session question this counter exists for: **did the
    cross-call memo serve anything at all on this run?** `size()` and
    `miss_count()` both count INSERTS, so a run that inserted N entries and
    read back ZERO of them is indistinguishable from one that served every
    lookup -- which is precisely the difference between a cache that is
    earning its keep and one that is pure cost. A session that never calls
    `lookup_copy` keeps this at 0, so a run with the cross-call memo off is
    PROVEN rather than asserted."""

    var _access_clock: UInt64
    """Monotonic LRU clock. Bumped on every insert and every `lookup_copy`
    HIT; the stamped value becomes the touched entry's `last_access`."""

    var _total_bytes: Int
    """Running sum of every live entry's `nbytes` (the array-memory bound
    axis). Incremented on insert, decremented on eviction / clear."""

    var _max_entries: Int
    """Entry-count ceiling (default `SCAN_DEDUP_MAX_ENTRIES_DEFAULT`)."""

    var _max_bytes: Int
    """Total-array-bytes ceiling (default `SCAN_DEDUP_MAX_BYTES_DEFAULT`)."""

    var _share_on: Bool
    """`lookup_copy` shares the cached buffers when True (the default) and
    deep-copies them with `copy_batch` when False, the differential oracle."""

    def __init__(out self, *, share_on: Bool = True):
        """Construct an empty cache with the default conservative caps."""
        self._entries = Slab[_ScanDedupEntry]()
        self._miss_count = 0
        self._hit_count = 0
        self._access_clock = UInt64(0)
        self._total_bytes = 0
        self._max_entries = SCAN_DEDUP_MAX_ENTRIES_DEFAULT
        self._max_bytes = SCAN_DEDUP_MAX_BYTES_DEFAULT
        self._share_on = share_on

    def __init__(
        out self, max_entries: Int, max_bytes: Int, *, share_on: Bool = True
    ):
        """Construct an empty cache with EXPLICIT caps.

        Production uses the zero-arg ctor (the conservative fixed ceiling); this
        overload lets tests drive eviction deterministically with small caps.
        A cap ≤ 0 is
        clamped to 1 so the eviction loop always terminates (it never evicts the
        single just-inserted entry)."""
        self._entries = Slab[_ScanDedupEntry]()
        self._miss_count = 0
        self._hit_count = 0
        self._access_clock = UInt64(0)
        self._total_bytes = 0
        self._max_entries = max_entries if max_entries > 0 else 1
        self._max_bytes = max_bytes if max_bytes > 0 else 1
        self._share_on = share_on

    @staticmethod
    def ram_sized(max_bytes_flag: String) -> ScanDedupCache:
        """The PRODUCTION constructor: entry cap at the default, byte cap sized
        to AVAILABLE RAM at ctx init via
        `resolve_scan_dedup_max_bytes(max_bytes_flag)` (the flag's override ->
        free-RAM fraction -> 1 GiB fallback). A session uses this; the
        zero-arg ctor stays fixed-1-GiB for deterministic tests."""
        return ScanDedupCache(
            SCAN_DEDUP_MAX_ENTRIES_DEFAULT,
            resolve_scan_dedup_max_bytes(max_bytes_flag),
        )

    def _find(self, key: String) -> Int:
        """Linear-scan lookup. Returns -1 on miss, else the slab index.

        # PERF: O(N) where N = num distinct scans cached, capped at
        # `_max_entries`. Branch-predictable inner loop on string equality.
        """
        for i in range(self._entries.len()):
            ref entry = self._entries[i]
            if entry.key == key:
                return i
        return -1

    def has(self, key: String) -> Bool:
        """Return True iff `key` is in the cache.

        A MEMBERSHIP probe, NOT an access — does NOT bump the LRU clock (the
        real access is `lookup_copy`, which does). Keeping `has` non-mutating
        preserves its immutable-`self` signature for the callers that probe
        before deciding to materialize."""
        return self._find(key) >= 0

    def lookup_copy(mut self, key: String) raises -> Optional[RecordBatch]:
        """If `key` is present, return a `share_batch_like_copy` of the cached
        RecordBatch, bump the entry's hit_count, and TOUCH it for LRU (stamp
        the current access clock). Otherwise return None.

        Returns by value (consumer takes ownership, can store in its own
        per-call InMemoryRegistry). Share-eligible columns ALIAS the cache's
        buffers through an Arc; they are not copies of the bytes.

        ⚠ THE NAME SAYS COPY. What it returns with `share_on` (the default) is
        a SHARE; it deep-copies only with `share_on=False`.

        PERF: cache hit = O(N) string compare + O(ncols) refcount bumps and a
        schema rebuild. It is NOT a memcpy of the cached relation. Do not size
        this cache as if a hit copied bytes.
        A share-INELIGIBLE column still falls back to `copy_column`, so a hit
        is not unconditionally copy-free. The LRU touch is a clock bump + one
        field write — negligible.

        Args:
            key: Composite cache key (path \\0 filter_fp \\0 projection_fp).

        Returns:
            Some(RecordBatch sharing the cached buffers) on cache hit, None on
            miss.
        """
        var idx = self._find(key)
        if idx < 0:
            return None
        self._access_clock = self._access_clock + UInt64(1)
        self._hit_count = self._hit_count + 1
        ref entry_ref = self._entries[idx]
        entry_ref.hit_count = entry_ref.hit_count + 1
        # LRU touch: a HIT moves the entry to MRU position (largest clock).
        entry_ref.last_access = self._access_clock
        # ★ SHARE, DO NOT DEEP-COPY. A deep copy here makes every hit pay a
        # memcpy of the cached relation into freshly faulted pages.
        #
        # WHY SHARING IS SAFE. The hazard of handing out the cache's buffers is
        # EVICTION: `_evict_over_cap` can drop an entry while a consumer still
        # holds it. An Arc dissolves exactly that -- eviction means "drop one
        # reference", not "free the bytes", and the bytes die when the LAST
        # holder releases. Arrow buffers are immutable on every downstream
        # consumer (split / join / agg / filter / project all READ and emit NEW
        # batches), the same premise `share_batch` rests on.
        #
        # `share_batch_like_copy`, not `share_batch`: `copy_column` also
        # NORMALISES (drops an all-valid validity bitmap, back-fills DECIMAL
        # (p,s), rebases an `_offset != 0` row slice), so a raw share is not a
        # structural no-op at a site whose consumers branch on `if
        # col._validity:`. The `_like_copy` twin shares where
        # `project_column_share_eligible` proves it equivalent and calls
        # `copy_column` verbatim where it does not.
        #
        # ⚠ THE ONE REAL COST. `_total_bytes` accounting over-reports freed
        # memory: an evicted entry whose buffers are still held by a consumer is
        # charged as released while its pages are still resident, so PEAK RSS
        # can exceed the cap transiently (until end of query, when the last
        # holder drops). That is a genuine trade, so report peak RSS beside any
        # wall-time comparison of the two arms.
        #
        # `share_on=False` deep-copies with `copy_batch`, which is the A/B
        # baseline and the differential oracle.
        if self._share_on:
            return Optional[RecordBatch](share_batch_like_copy(entry_ref.batch))
        return Optional[RecordBatch](copy_batch(entry_ref.batch))

    def insert(mut self, var key: String, var batch: RecordBatch) raises:
        """Store `batch` under `key`. Bumps `_miss_count`, accounts the batch's
        bytes, and EVICTS LRU entries if the insert pushes the cache over either
        cap.

        Caller should call this AFTER a successful `materialize_parquet_collect`
        when the cache lookup missed. The cache takes ownership of the batch.

        Idempotent on duplicate keys: no-op if `key` is already present.
        (The cache key is structural, so this should not happen in
        deduplicate_scans — the per-call grouping prevents within-call
        duplicates from materializing twice — but the guard makes the
        cache safe under concurrent insertion attempts in future
        multi-threaded callers.)
        """
        if self._find(key) >= 0:
            # Already cached — race-safe no-op. Drop the new batch.
            _ = batch^
            _ = key^
            return
        self._miss_count = self._miss_count + 1
        var nbytes = _estimate_batch_bytes(batch)
        self._access_clock = self._access_clock + UInt64(1)
        var stamp = self._access_clock
        self._total_bytes = self._total_bytes + nbytes
        var entry = _ScanDedupEntry(key^, batch^, stamp, nbytes)
        self._entries.append(entry^)
        self._evict_over_cap()

    def _evict_over_cap(mut self) raises:
        """Evict the LRU (smallest `last_access`) entries until BOTH caps hold
        OR only one entry remains.

        The `len > 1` floor guarantees the just-inserted entry (which carries
        the largest clock, so it is never the oldest) is never evicted — the
        cache always keeps at least the current batch, even if it alone exceeds
        `_max_bytes` (a single oversized batch is cached rather than thrash-
        dropped; the loop cannot spin). Removal is `Slab.take_at(idx)`, which
        drops the evicted `_ScanDedupEntry` (and its owned RecordBatch) — safe
        because every buffer a consumer still holds is held through an Arc, so
        the drop releases one reference rather than the bytes (see module
        header EVICTION SAFETY).
        """
        while (
            self._entries.len() > self._max_entries
            or self._total_bytes > self._max_bytes
        ) and self._entries.len() > 1:
            # Find the oldest (smallest last_access) entry.
            var oldest_idx = 0
            var oldest_clock = self._entries[0].last_access
            for i in range(1, self._entries.len()):
                var c = self._entries[i].last_access
                if c < oldest_clock:
                    oldest_clock = c
                    oldest_idx = i
            self._total_bytes = (
                self._total_bytes - self._entries[oldest_idx].nbytes
            )
            _ = self._entries.take_at(oldest_idx)

    def size(self) -> Int:
        """Number of entries in the cache. Test hook."""
        return self._entries.len()

    def miss_count(self) -> Int:
        """Total cache misses (= number of materializations bypassed). Test hook."""
        return self._miss_count

    def hit_count(self) -> Int:
        """Total cache hits across ALL keys since construction / `clear`.

        ⭐ THE WITNESS FOR A RUN WITH THE SCAN CACHE OFF. `size()` and
        `miss_count()` count inserts; only this counts READ-BACKS. A session
        whose scan dedup pass never calls `lookup_copy` keeps this at 0 for its
        life -- a run can therefore PROVE the cross-call memo was off instead of
        claiming it."""
        return self._hit_count

    def total_bytes(self) -> Int:
        """Current sum of cached array-memory bytes (the memory-bound axis).
        Test hook + bound inspection."""
        return self._total_bytes

    def max_entries(self) -> Int:
        """The entry-count cap in force. Test hook."""
        return self._max_entries

    def max_bytes(self) -> Int:
        """The total-bytes cap in force. Test hook."""
        return self._max_bytes

    def share_on(self) -> Bool:
        """Whether `lookup_copy` shares (True) or deep-copies. Test hook."""
        return self._share_on

    def hit_count_for(self, key: String) -> Int:
        """Return the hit_count for a given key, or -1 if not present.

        Test hook for verifying cache hit rate on q11-shape benches.
        """
        var idx = self._find(key)
        if idx < 0:
            return -1
        ref entry_ref = self._entries[idx]
        return entry_ref.hit_count

    def clear(mut self):
        """Drop all entries. Resets hit/miss counts, bytes, and the LRU clock.

        The explicit escape hatch for long-running sessions that want to fully reclaim the cache between
        phases. Eviction reuses the SAME per-entry teardown this whole-slab
        clear relies on.
        """
        self._entries.clear()
        self._miss_count = 0
        self._hit_count = 0
        self._total_bytes = 0
        self._access_clock = UInt64(0)
