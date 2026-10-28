# =============================================================================
# CDHTSIZE — size the grouped COUNT(DISTINCT) GROUP table from GROUPS, not ROWS
# =============================================================================
#
# ★ THE PROBLEM THIS FILE EXISTS TO REMOVE, derived from the source rather than
#   from any timer:
#
#     per_worker_rows = ceil(5,563,212 / 20)          = 278,161
#     ht_cap          = next_pow2(2 * per_worker_rows) = 1,048,576   (old clamp)
#     bytes           = 20 workers x 1,048,576 x 12 B  = 251,658,240
#
#   `_execute_count_distinct_agg_parallel` sized every worker's open-addressed
#   group table from the ROW count and filled all K of them on the DRIVER
#   THREAD before the dispatch (`htinit`), so a 165-group key allocated,
#   zeroed, merge-scanned and freed 251.7 MB of hash table to hold **165
#   groups**, and the serial `merge` was almost entirely the walk over 19 x
#   1,048,576 EMPTY slots.
#
# ⭐ THE RULE TO FOLLOW (the one DuckDB's grouped hash table uses): start at a
#   small constant capacity, double when the load passes a threshold, and
#   create each per-thread table lazily inside the thread that fills it, never
#   sized from the input row count. A capacity is derived from a count only
#   when the count is of GROUPS.
#
# ⭐ WHAT WE DO NOW — the same rule, plus the one exact count this driver has:
#   * For a key set whose every column went through the string DICTIONARY
#     encode (STRING / LARGE_STRING / DICTIONARY), the dict
#     sizes are an exact per-column distinct count, so their product (capped at
#     the row count; +1 per key for a NULL group) is an UPPER BOUND on groups.
#     `cd_groups_upper_bound`. That is a runtime fact, not a plan-time
#     estimate — see `komira_compiler/plan_group_estimate.mojo` for why no
#     plan-time estimator reaches this door.
#   * Otherwise (any INT key) there is
#     NO bound, and the table starts at `CD_GROUP_HT_MIN_CAP` and DOUBLES at load
#     0.5 inside the worker.
#   * The table is allocated by the WORKER, not the driver: `htinit` stops
#     being a serial phase at all.
#
# ⛔ CORRECTNESS DOES NOT DEPEND ON THE BOUND. The bound picks only the FIRST
#   capacity; the worker's load-0.5 doubling (`_PerWorkerCDState.grow_ht`) is
#   what guarantees the table never fills, for any bound, including a wrong one.
#
# ⛔ AND IT DOES NOT TOUCH THE PARTITION. Growth is a per-worker rehash on
#   `hash & new_mask`; which worker owns a row is `_cd_partition_bucket(hash,
#   K)`, a different function of the same hash that no capacity enters. A group
#   still never spans workers, so the concat-merge stays sound.
#
# ⚠ WHAT DOES CHANGE: THE EMISSION ORDER OF GROUPS FROM WORKERS >= 1. The merge
#   walks each worker's table in SLOT order, and slot order is a function of
#   the capacity. GROUP BY without ORDER BY promises no order; every CD test
#   compares order-independently; and a TopN over this node resolves ties in
#   concat order exactly as it already did across different K.
#
# Route witness (for tests): the two process-wide
# counters below. Same blessed `_Global` + `Atomic` idiom as
# `cd_passenger_lane_counter.mojo`; folded ONCE PER QUERY by the
# driver after the dispatch, never on the row path. No env var.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, alloc


# The starting capacity of a group table (4,096 entries). At 12 B/slot (Int64
# hash + Int32 gid) that is 48 KB per worker — 20 workers are ~1 MB, against
# the 251.7 MB the row-sized tables cost a 165-group key.
comptime CD_GROUP_HT_MIN_CAP: Int = 4096

# The old row-based sizing's clamp, kept as the ceiling of the FIRST capacity
# only. A worker that needs more doubles past it exactly as before.
comptime CD_GROUP_HT_MAX_INITIAL_CAP: Int = 1_048_576


def cd_groups_upper_bound(dict_sizes: List[Int], num_rows: Int) -> Int:
    """An upper bound on the number of GROUPS, or -1 if none is known.

    Args:
        dict_sizes: One entry per group key: the number of distinct dictionary
            ids the encode produced for that key, or a NEGATIVE value for a key
            that was not dictionary-encoded (an INT key). One such key makes
            the whole bound unknown — its cardinality is not observed anywhere
            this driver can read it.
        num_rows: Rows in the input. Every group holds at least one row, so
            this caps the bound.

    Returns:
        `min(num_rows, prod(dict_sizes[k] + 1))`, or -1. The `+ 1` per key is
        slack for a NULL key forming its own group; it can only over-size.
    """
    var bound = 1
    for k in range(len(dict_sizes)):
        var d = dict_sizes[k]
        if d < 0:
            return -1
        var nk = d + 1
        # Saturate before multiplying: bound * nk > num_rows <=> this test.
        if bound > num_rows // nk:
            return num_rows
        bound = bound * nk
    if bound > num_rows:
        return num_rows
    return bound


def cd_group_ht_initial_cap(groups_bound: Int, num_workers: Int) -> Int:
    """First capacity (slots, a power of two) of ONE worker's group table.

    ⛔ Deliberately NOT a function of the row count — that is the defect this
    file removes. With a known `groups_bound` the hash partition gives each of
    the K workers about `groups_bound / K` groups; one eighth plus 64 of slack
    absorbs the partition's imbalance (and a bound's `+1` NULL slots), and the
    table is sized to hold that at load <= 0.5, the same threshold the worker's
    doubling uses. With no bound it is `CD_GROUP_HT_MIN_CAP` and the worker
    grows it.

    Args:
        groups_bound: `cd_groups_upper_bound(...)`, or -1 for unknown.
        num_workers: K, the dispatch width.

    Returns:
        A power of two in `[CD_GROUP_HT_MIN_CAP, CD_GROUP_HT_MAX_INITIAL_CAP]`.
    """
    var want = 0
    if groups_bound >= 0:
        var k = num_workers if num_workers > 0 else 1
        var mean = (groups_bound + k - 1) // k
        want = mean + mean // 8 + 64
    var cap = CD_GROUP_HT_MIN_CAP
    while cap < 2 * want and cap < CD_GROUP_HT_MAX_INITIAL_CAP:
        cap = cap * 2
    return cap


# =============================================================================
# Route witness — process-wide, folded once per query
# =============================================================================


def _init_cd_group_ht_slots() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn: total group-table SLOTS allocated, once per process."""
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


def _init_cd_group_ht_resizes() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn: total group-table DOUBLINGS, once per process."""
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _CD_GROUP_HT_SLOTS = _Global[
    "komira_cd_group_ht_slots_allocated", _init_cd_group_ht_slots,
]

comptime _CD_GROUP_HT_RESIZES = _Global[
    "komira_cd_group_ht_resizes", _init_cd_group_ht_resizes,
]


def cd_group_ht_note(slots: Int, resizes: Int) raises:
    """Fold one query's totals (summed over its workers) into the counters.

    `slots` counts every slot of every table ALLOCATED — the first table and
    each doubling's new table — so it is the zero-fill work, not the final
    size. Called once per query by the driver, never on the row path."""
    # SAFETY: §6 FFI carve-out — `get_or_create_ptr` targets KGEN-runtime static
    # storage (process-lifetime); the wildcard is the stdlib `_Global` API's own
    # return type, confined to this helper.
    if slots != 0:
        var gs = _CD_GROUP_HT_SLOTS.get_or_create_ptr()
        _ = gs[][].fetch_add(Int64(slots))
    if resizes != 0:
        var gr = _CD_GROUP_HT_RESIZES.get_or_create_ptr()
        _ = gr[][].fetch_add(Int64(resizes))


def cd_group_ht_slots_count() raises -> Int:
    """Read the process-wide count of group-table slots allocated."""
    # SAFETY: §6 FFI carve-out (see `cd_group_ht_note`).
    var gs = _CD_GROUP_HT_SLOTS.get_or_create_ptr()
    return Int(gs[][].load())


def cd_group_ht_resizes_count() raises -> Int:
    """Read the process-wide count of group-table doublings."""
    # SAFETY: §6 FFI carve-out (see `cd_group_ht_note`).
    var gr = _CD_GROUP_HT_RESIZES.get_or_create_ptr()
    return Int(gr[][].load())


def reset_cd_group_ht_counters() raises:
    """Reset both process-wide counters to 0 (test setup)."""
    # SAFETY: §6 FFI carve-out (see `cd_group_ht_note`).
    var gs = _CD_GROUP_HT_SLOTS.get_or_create_ptr()
    gs[][].store(Scalar[DType.int64](0))
    var gr = _CD_GROUP_HT_RESIZES.get_or_create_ptr()
    gr[][].store(Scalar[DType.int64](0))
