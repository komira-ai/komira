# =============================================================================
# tests/test_scan_dedup_cache_bound.mojo
#
# The scan dedup cache's bound — the falsifier + guard.
#
# `ScanDedupCache` (EngineContext-scoped) caches a full materialized RecordBatch
# per distinct `(path, filter_fp, projection_fp)` key on the multi-table plan
# route (q11/q15/q22-shape). Unbounded, a persistent-runtime harness driving
# MANY DISTINCT multi-table scans on ONE shared ctx would accumulate a cached
# batch per distinct key without limit and OOM the host.
#
# This is the falsifier for the BOUND. `test_entry_count_cap_bounds_
# distinct_scans` drives 200 DISTINCT keys (the many-distinct-scan accumulation
# workload) through ONE cache and asserts `size()` stays at the entry cap (64),
# NOT 200.
#
#   An `insert` without eviction lets `size()` grow to 200 (== every distinct
#   scan retained → the unbounded accumulation), and the assertion
#   `size() == SCAN_DEDUP_MAX_ENTRIES_DEFAULT` (64) trips at 200. LRU eviction
#   caps `size()` at 64.
#
# The other cells lock the second axis + the invariants: the total-bytes cap
# evicts by memory, LRU keeps the RECENTLY-touched and drops the oldest, the
# single-oversized-batch carve-out never thrash-drops the only entry, and the
# COMMON few-distinct-scan case NEVER evicts (identical hits / dedup benefit —
# the perf win is preserved).
#
# EVICTION SAFETY (why dropping cached batches on eviction is sound): the cache
# OWNS each RecordBatch and `lookup_copy` hands consumers Arc shares (or deep
# copies with `share_on=False`), so eviction drops one reference and can dangle
# nothing (module header EVICTION SAFETY). These tests exercise
# insert→evict→lookup interleavings to confirm no use-after-free.
#
# Pointer rules: NO UnsafePointer in any signature, NO wildcard origins, NO
# unsafe_from_address / take_pointee. Pure value API.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_equal, assert_false

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import SchemaBuilder, Field, RecordBatchBuilder
from komira_arrow.column import Column
from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch

from komira_dispatch_scan.scan_dedup_cache import (
    ScanDedupCache,
    SCAN_DEDUP_MAX_ENTRIES_DEFAULT,
    SCAN_DEDUP_MAX_BYTES_DEFAULT,
)


def _int_batch(nrows: Int) raises -> RecordBatch:
    """A 1-column INT64 batch of `nrows` rows. Its array-memory footprint is
    exactly `nrows * 8` bytes (no offsets / validity / dict) — so the bytes-cap
    cells can size eviction precisely."""
    var a = PrimitiveArray[DType.int64].allocate(nrows)
    for i in range(nrows):
        a.set(i, Int64(i))
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.INT64, False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(Column.from_primitive[DType.int64](a^))
    return rbb.build(schema^)


def test_entry_count_cap_bounds_distinct_scans() raises:
    """THE FALSIFIER. Drive 200 DISTINCT keys (the many-distinct-scan
    accumulation the persistent-runtime harness triggers) through ONE default
    cache. An unbounded `insert` would retain all 200 (→ OOM); the bound caps
    `size()` at the entry ceiling (64) via LRU eviction, and the MOST-RECENT
    keys survive while the oldest are evicted."""
    var cache = ScanDedupCache()
    assert_equal(
        cache.max_entries(),
        SCAN_DEDUP_MAX_ENTRIES_DEFAULT,
        "default entry cap is 64",
    )
    var n = 200
    for i in range(n):
        # 1-row batches (8 bytes each) — total 1600 bytes << 1 GiB, so ONLY the
        # entry-count cap fires here, not the bytes cap.
        cache.insert(String("scan_") + String(i), _int_batch(1))

    # THE BOUND: 200 distinct inserts, size pinned at the cap (NOT 200).
    assert_equal(
        cache.size(),
        SCAN_DEDUP_MAX_ENTRIES_DEFAULT,
        "200 distinct scans -> size capped at 64 (unbounded it would be 200)",
    )
    assert_true(
        cache.total_bytes() <= cache.max_bytes(),
        "bytes stay under the bytes cap too",
    )
    # The 64 most-recent keys survive; the oldest are evicted.
    assert_true(cache.has(String("scan_199")), "newest key retained")
    assert_true(cache.has(String("scan_137")), "recent key (200-64+1) retained")
    assert_false(cache.has(String("scan_0")), "oldest key evicted")
    assert_false(cache.has(String("scan_135")), "beyond-window old key evicted")


def test_bytes_cap_evicts_when_over_budget() raises:
    """The MEMORY axis: with a small explicit bytes cap, inserting more total
    array-bytes than the cap evicts LRU until the sum fits. Entry cap is large
    (1000) so ONLY the bytes cap is under test here."""
    var cap_bytes = 100_000
    var cache = ScanDedupCache(1000, cap_bytes)
    # Each batch = 3000 rows * 8 = 24_000 bytes. 10 distinct -> 240_000 raw,
    # but the cache must hold the running sum <= 100_000 (== 4 entries max).
    for i in range(10):
        cache.insert(String("big_") + String(i), _int_batch(3000))

    assert_true(
        cache.total_bytes() <= cap_bytes,
        String("total_bytes ") + String(cache.total_bytes())
        + String(" must stay <= bytes cap ") + String(cap_bytes),
    )
    assert_true(
        cache.size() <= 4,
        String("bytes cap holds at most 4x24KB entries, got ")
        + String(cache.size()),
    )
    assert_true(cache.size() >= 1, "cache is not fully emptied")
    # The most recent survives; the oldest was evicted by memory pressure.
    assert_true(cache.has(String("big_9")), "newest big batch retained")
    assert_false(cache.has(String("big_0")), "oldest big batch evicted")


def test_common_case_no_eviction_preserves_hits() raises:
    """PERF/CORRECTNESS PRESERVATION: the common few-distinct-scan workload
    (<= 8 distinct scans) NEVER evicts — every insert is retained and every
    subsequent lookup HITS, so the bound costs the common case no dedup
    benefit."""
    var cache = ScanDedupCache()
    for i in range(8):
        cache.insert(String("t_") + String(i), _int_batch(10))
    assert_equal(cache.size(), 8, "8 distinct scans all retained (no eviction)")
    assert_equal(cache.miss_count(), 8, "8 misses (materializations)")

    # Every key still HITS (a share returned) -> dedup benefit preserved.
    for i in range(8):
        var got = cache.lookup_copy(String("t_") + String(i))
        assert_true(got.__bool__(), "common-case key still hits")
        var rb = got.take()
        assert_equal(rb.num_rows(), 10, "hit returns the cached batch shape")
        _ = rb^
    assert_equal(cache.size(), 8, "lookups do not change size")
    for i in range(8):
        assert_true(
            cache.hit_count_for(String("t_") + String(i)) == 1,
            "each key served exactly one hit",
        )


def test_lru_evicts_oldest_keeps_touched() raises:
    """LRU is by ACCESS, not insertion order: a `lookup_copy` HIT touches an
    entry to MRU, so a later over-cap insert evicts the oldest UNTOUCHED entry,
    not the touched one."""
    var cache = ScanDedupCache(3, SCAN_DEDUP_MAX_BYTES_DEFAULT)
    cache.insert(String("k0"), _int_batch(4))
    cache.insert(String("k1"), _int_batch(4))
    cache.insert(String("k2"), _int_batch(4))
    assert_equal(cache.size(), 3, "at entry cap")

    # Touch k0 -> it becomes MRU; k1 is now the oldest untouched.
    var h = cache.lookup_copy(String("k0"))
    assert_true(h.__bool__(), "k0 hit")
    _ = h.take()

    # Insert k3 -> over the entry cap -> evict the LRU (k1), NOT the touched k0.
    cache.insert(String("k3"), _int_batch(4))
    assert_equal(cache.size(), 3, "still at cap after evict+insert")
    assert_true(cache.has(String("k0")), "touched k0 survived (MRU)")
    assert_false(cache.has(String("k1")), "untouched oldest k1 evicted")
    assert_true(cache.has(String("k2")), "k2 survived")
    assert_true(cache.has(String("k3")), "newest k3 present")


def test_single_oversized_batch_not_thrash_dropped() raises:
    """The carve-out: a single batch bigger than the whole bytes cap is CACHED,
    not thrash-dropped (the eviction loop never removes the sole/just-inserted
    entry). A SECOND distinct oversized insert then evicts the older one — the
    multi-entry bound stays hard."""
    var cache = ScanDedupCache(10, 1000)  # 1000-byte cap
    cache.insert(String("huge0"), _int_batch(3000))  # 24_000 bytes >> cap
    assert_equal(cache.size(), 1, "sole oversized entry retained (soft carve-out)")
    assert_true(cache.has(String("huge0")), "the only batch is cached")

    cache.insert(String("huge1"), _int_batch(3000))
    assert_equal(
        cache.size(), 1, "second oversized insert evicts the older one (hard bound)"
    )
    assert_true(cache.has(String("huge1")), "newest oversized batch retained")
    assert_false(cache.has(String("huge0")), "older oversized batch evicted")


def test_clear_resets_bound_state() raises:
    """`clear()` drops all entries and resets the bytes + clock bookkeeping so a
    reused cache starts clean."""
    var cache = ScanDedupCache()
    for i in range(5):
        cache.insert(String("c_") + String(i), _int_batch(100))
    assert_true(cache.total_bytes() > 0, "bytes accounted before clear")
    cache.clear()
    assert_equal(cache.size(), 0, "cleared")
    assert_equal(cache.total_bytes(), 0, "bytes reset")
    assert_equal(cache.miss_count(), 0, "miss count reset")
    # Reusable after clear.
    cache.insert(String("post"), _int_batch(10))
    assert_equal(cache.size(), 1, "reusable after clear")


def main() raises:
    var suite = TestSuite()
    suite.test[test_entry_count_cap_bounds_distinct_scans]()
    suite.test[test_bytes_cap_evicts_when_over_budget]()
    suite.test[test_common_case_no_eviction_preserves_hits]()
    suite.test[test_lru_evicts_oldest_keeps_touched]()
    suite.test[test_single_oversized_batch_not_thrash_dropped]()
    suite.test[test_clear_resets_bound_state]()
    suite^.run()
