# =============================================================================
# tests/test_broker_compacted_reap_guard_offline.mojo
#   Compaction reverse-guard
# =============================================================================
#
# Compaction's commit-then-supersede protocol advances the LIVE log_start PAST
# a superseded range (CompactionWorker.run_once, in komira_broker_compaction) —
# so once that lands, the LIVE tier no longer holds the range and the compacted
# Parquet object is the SOLE copy. Read-repair is ONE-direction only (a
# live-miss falls back to the compacted tier; there is NO compacted-miss ->
# live fallback). So if the compacted object/entry is later reaped while
# its range is still SERVABLE, the range becomes readable from NEITHER tier — a
# silent hole.
#
# The guard is a reverse-guard on `CompactionIndex`: a compacted entry is reapable
# ONLY if its WHOLE range has aged out below the partition's earliest-readable
# floor (`last_offset < earliest_readable_offset`). A reaper calls
# `assert_compacted_entry_reapable` BEFORE deleting a compacted object; it raises
# (refuses) if the entry is still the sole copy of a servable range.
#
# The cases: a compacted entry covering a STILL-readable range
# (live already superseded it) -> the guard refuses (raises). An aged-out entry
# (range fully below the readable floor) -> the guard permits.
#
# Hard-rule audit: no UnsafePointer in any signature, no wildcard origins,
# no unsafe_from_address / take_pointee.
# =============================================================================

from std.testing import assert_true, assert_false

from komira_broker.compacted_index import (
    CompactedEntry,
    CompactionIndex,
)

from komira_objectstore.cas_manifest import RetryPolicy
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)


comptime _Store = SharedInMemoryConditionalStore


def _make_index(store: _Store, partition_prefix: String) -> CompactionIndex[_Store]:
    return CompactionIndex[_Store].build(
        store.clone(), partition_prefix, RetryPolicy.fast_test()
    )


def _entry(base: Int64, last: Int64) -> CompactedEntry:
    return CompactedEntry(
        chunk_seq=Int64(0),
        base_offset=base,
        last_offset=last,
        record_count=last - base + Int64(1),
        supersedes_lo=Int64(0),
        supersedes_hi=Int64(0),
        parquet_key=String("c/.../p.parquet"),
    )


# =============================================================================
# (1) Sole copy of a STILL-READABLE range → guard REFUSES (raises).
#     The compaction supersede advanced live log_start past the range, so the
#     live tier no longer holds it; the range is still at/above the readable
#     floor → the compacted object is the sole copy → must NOT be reaped.
# =============================================================================


def test_refuse_reap_sole_copy_of_servable_range() raises:
    print("[test_refuse_reap_sole_copy_of_servable_range] starting...")
    var store = _Store()
    var index = _make_index(store, String("c1/_meta/topics/t/0"))

    # Compacted entry covers [0, 49]. The partition's earliest-readable offset is
    # 0 (nothing retention-aged-out) — so this range is fully servable. The live
    # tier has superseded it (live log_start advanced to 50).
    var e = _entry(Int64(0), Int64(49))
    var earliest_readable = Int64(0)
    var live_log_start = Int64(50)

    var reapable = index.compacted_entry_is_reapable(
        e, earliest_readable, live_log_start
    )
    assert_false(
        reapable,
        "a servable compacted range that live has superseded is the SOLE copy"
        " -> NOT reapable",
    )

    var raised = False
    try:
        index.assert_compacted_entry_reapable(
            e, earliest_readable, live_log_start
        )
    except err:
        raised = True
        assert_true(
            String(err).find("REFUSING to reap") >= 0,
            "raise names the refusal",
        )
    assert_true(raised, "assert form RAISES on the sole-copy reap attempt")
    print("[test_refuse_reap_sole_copy_of_servable_range] PASS")


# =============================================================================
# (2) Range straddling the readable floor → still REFUSE (a consumer resuming
#     at earliest_readable would touch it).
# =============================================================================


def test_refuse_reap_range_straddling_readable_floor() raises:
    print("[test_refuse_reap_range_straddling_readable_floor] starting...")
    var store = _Store()
    var index = _make_index(store, String("c2/_meta/topics/t/0"))

    # Entry [40, 99]; earliest-readable floor at 60 (retention aged out [0,59]).
    # The suffix [60, 99] is still servable → the entry is NOT fully aged out.
    var e = _entry(Int64(40), Int64(99))
    var reapable = index.compacted_entry_is_reapable(
        e, Int64(60), Int64(100)
    )
    assert_false(
        reapable, "a range whose suffix is still servable is NOT reapable"
    )
    print("[test_refuse_reap_range_straddling_readable_floor] PASS")


# =============================================================================
# (3) Range fully aged out below the readable floor → PERMIT reap.
# =============================================================================


def test_permit_reap_fully_aged_out_range() raises:
    print("[test_permit_reap_fully_aged_out_range] starting...")
    var store = _Store()
    var index = _make_index(store, String("c3/_meta/topics/t/0"))

    # Entry [0, 49]; earliest-readable floor at 50 (retention aged out [0,49]
    # entirely). No consumer can read this range → dropping the compacted copy
    # loses nothing → reapable.
    var e = _entry(Int64(0), Int64(49))
    var reapable = index.compacted_entry_is_reapable(
        e, Int64(50), Int64(50)
    )
    assert_true(reapable, "a fully aged-out range is reapable")

    # The assert form does NOT raise on a reapable entry.
    index.assert_compacted_entry_reapable(e, Int64(50), Int64(50))
    print("[test_permit_reap_fully_aged_out_range] PASS")


# =============================================================================
# (4) Boundary: last_offset exactly one below the floor → reapable;
#     last_offset == floor → NOT reapable (the floor offset is still readable).
# =============================================================================


def test_reap_floor_boundary() raises:
    print("[test_reap_floor_boundary] starting...")
    var store = _Store()
    var index = _make_index(store, String("c4/_meta/topics/t/0"))

    # last_offset = 49, floor = 50 -> 49 < 50 -> reapable.
    var e_below = _entry(Int64(0), Int64(49))
    assert_true(
        index.compacted_entry_is_reapable(e_below, Int64(50), Int64(50)),
        "last_offset just below the floor is reapable",
    )

    # last_offset = 50, floor = 50 -> 50 is the earliest STILL-readable offset
    # -> NOT reapable.
    var e_at = _entry(Int64(0), Int64(50))
    assert_false(
        index.compacted_entry_is_reapable(e_at, Int64(50), Int64(51)),
        "last_offset AT the readable floor is NOT reapable",
    )
    print("[test_reap_floor_boundary] PASS")


def main() raises:
    test_refuse_reap_sole_copy_of_servable_range()
    test_refuse_reap_range_straddling_readable_floor()
    test_permit_reap_fully_aged_out_range()
    test_reap_floor_boundary()
    print("ALL test_broker_compacted_reap_guard_offline TESTS PASSED")
