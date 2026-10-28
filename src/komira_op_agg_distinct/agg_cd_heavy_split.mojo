# =============================================================================
# CDP-HEAVYSPLIT — a HEAVY group's distinct pairs are spread across workers
# =============================================================================
#
# ★ THE PROBLEM. The grouped COUNT(DISTINCT) driver (added by a later part)
# hash-partitions rows by GROUP, so one group is one worker. When ONE group
# holds 91.8% of the rows (a second at 79.2% in another shape), ONE worker runs
# that group's whole `CdDistinctSet` probe stream — about 1.09M distinct pairs
# in a 2^21-slot, 32 MB table that misses cache on every probe — while the
# other 19 finish their scan and idle, so the dispatch is mostly skew and does
# not get faster as K grows from 2 to 20.
#
# ★ THE FIX, AND WHY IT IS CORRECT. A group whose SAMPLED share of rows exceeds
# 2/K is HEAVY. A heavy group's (row, aggregate) is owned by
# `cd_pair_bucket(group_hash, value, K)` — a pure function of the group AND the
# distinct value — instead of by the group alone. So:
#   * every copy of one (group, value) PAIR lands on ONE worker, whose
#     `CdDistinctSet` counts it once;
#   * different pairs of the same group land on DIFFERENT workers, so the
#     group's distinct count is the SUM of its per-worker partial counts —
#     exactly, with no overlap, because the pair sets are disjoint;
#   * the driver's merge folds a heavy group's K partial rows into ONE output
#     row by adding those counts (`_execute_count_distinct_agg_parallel`).
# A group that is NOT heavy is owned by its group hash exactly as before, so
# its partial is the whole group and the merge stays a CONCAT for it. This is
# a level-1 distinct table partitioned on the hash of (groups ∪ argument), as
# DuckDB does, applied only to the groups that need it, which is what lets a
# heavy group spread across workers.
#
# ⛔ CORRECTNESS DOES NOT DEPEND ON THE SAMPLE. Which groups are heavy decides
#   only WHERE pairs are counted. Any set — empty, wrong, or a hash collision
#   that drags a light group along with a heavy one — gives the same answer,
#   because (a) the ownership test and the merge both key on the group HASH
#   being in the heavy list, so the two can never disagree about a group, and
#   (b) the merge folds partials by FULL KEY EQUALITY, so two different groups
#   sharing a hash are never added together.
#
# ⛔ A NULL VALUE IS OWNED BY THE GROUP'S OWN BUCKET. It admits nothing, but the
#   row still has to create its group somewhere, or a heavy group whose values
#   are all NULL would never exist in any worker and would vanish from the
#   output instead of emitting a distinct count of 0.
#
# ⛔ ADMISSION: EVERY AGGREGATE MUST BE COUNT(DISTINCT). A split group's rows
#   reach several workers, so a non-distinct accumulator (a Float64 SUM, a MEAN)
#   would be summed in a different ORDER than the serial twin sums it and could
#   differ in its last bits — the two kernels are selected by a ROW-COUNT
#   crossover, so that would make an answer depend on the input size. Distinct
#   counts are integers and order-free. The driver declines the split (and runs
#   today's group partition unchanged) for any other shape.
#
# Route witness: `cd_heavy_note` below — the heavy groups detected, the partial
# rows the merge folded, and the rows the BUSIEST worker owned in the last
# dispatch. The last is what separates this mechanism from every value oracle:
# a split that never happens still answers correctly, only slowly.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.collections import Dict
from std.ffi import _Global
from std.memory import OwnedPointer, alloc


# Rows sampled to find heavy groups: evenly strided, so a group's share of the
# sample estimates its share of the input. 4,096 composite hashes is negligible
# serial driver time, against the skewed worker's pair-set work for a heavy
# group.
comptime CD_HEAVY_SAMPLE_ROWS: Int = 4096

# At most this many heavy groups. A group the driver SPLITS has share > 1/(4K)
# (`cd_split_groups`; > 2/K for the fused route's decline test,
# `cd_heavy_groups`); the worker loop compares each row's hash against every
# entry, so the list is kept short (heaviest first) and the comparisons are
# unrolled over locals.
comptime CD_HEAVY_MAX: Int = 4


def cd_heavy_sample_row(i: Int, samples: Int, num_rows: Int) -> Int:
    """Row index of sample `i` of `samples`, evenly strided over the input.

    Args:
        i: Sample index in `[0, samples)`.
        samples: Number of samples (`min(num_rows, CD_HEAVY_SAMPLE_ROWS)`).
        num_rows: Rows in the input.

    Returns:
        A row in `[0, num_rows)`.
    """
    return (i * num_rows) // samples


def cd_heavy_groups(sample_hashes: List[Int], num_workers: Int) -> List[Int]:
    """The composite group hashes whose SAMPLED share exceeds 2/K.

    A group above 2/K would give its owner more than twice a balanced worker's
    rows under the group partition, which is the imbalance worth paying a
    cross-worker merge for. At most `CD_HEAVY_MAX`, heaviest first (ties by
    hash, so the list is deterministic for a given sample).

    Args:
        sample_hashes: One composite group hash per sampled row.
        num_workers: K, the dispatch width. Below 2 there is nothing to spread
            across and the list is empty.

    Returns:
        The heavy group hashes, heaviest first.
    """
    return _groups_above_share(sample_hashes, num_workers, False)


def cd_split_groups(sample_hashes: List[Int], num_workers: Int) -> List[Int]:
    """The composite group hashes the general driver SPLITS by pair: sampled
    share above 1/(4K) (vs `cd_heavy_groups`' 2/K).

    The driver used `cd_heavy_groups` (2/K, "more than twice a balanced
    worker's rows"), which left a SECOND group of 4.1% of the rows (0.82 x N/K
    at K=20) owned WHOLE by one worker on top of that worker's balanced share
    of everything else. A split costs one partial row per (split group,
    worker), folded at the merge by integer addition, and one more entry in
    the row loop's unrolled hash compare; an unsplit group of share p costs
    its owner p x N extra rows — p x K balanced workers' worth. At 1/(4K) the
    worst unsplit group adds a QUARTER of a balanced worker's load. 1/(2K)
    still left a 2.27% group (a third group) whole. The
    list is still capped at `CD_HEAVY_MAX` (the row loop's unrolled compare),
    heaviest first.

    ⛔ The fused string-key route keeps `cd_heavy_groups` (2/K) for its
    DECLINE test on purpose: a lower bar there would hand a
    high-cardinality string key back to the general driver, which is the
    slower route for that shape.
    """
    return _groups_above_share(sample_hashes, num_workers, True)


def _groups_above_share(
    sample_hashes: List[Int], num_workers: Int, quarter_over_k: Bool
) -> List[Int]:
    """Groups whose sampled share exceeds 2/K (`quarter_over_k` False) or
    1/(4K) (True); at most `CD_HEAVY_MAX`, heaviest first, ties by hash
    ascending."""
    var out = List[Int]()
    var s = len(sample_hashes)
    if num_workers < 2 or s == 0:
        return out^
    var freq = Dict[Int, Int]()
    for i in range(s):
        var h = sample_hashes[i]
        freq[h] = freq.get(h, 0) + 1
    var cand_h = List[Int]()
    var cand_n = List[Int]()
    for e in freq.items():
        var heavy: Bool
        if quarter_over_k:
            heavy = 4 * e.value * num_workers > s
        else:
            heavy = e.value * num_workers > 2 * s
        if heavy:
            cand_h.append(e.key)
            cand_n.append(e.value)
    # Selection by (count desc, hash asc); the candidate list is at most K/2.
    while len(out) < CD_HEAVY_MAX and len(cand_h) > 0:
        var best = 0
        for j in range(1, len(cand_h)):
            if cand_n[j] > cand_n[best] or (
                cand_n[j] == cand_n[best] and cand_h[j] < cand_h[best]
            ):
                best = j
        out.append(cand_h[best])
        _ = cand_h.pop(best)
        _ = cand_n.pop(best)
    return out^


@always_inline
def cd_pair_bucket(group_key_hash: Int, val: Int, num_workers: Int) -> Int:
    """Which worker owns the distinct PAIR `(group, val)` of a heavy group.

    A splitmix64 finalizer over the group hash and the value, range-reduced
    by multiply-shift (no division — the CDP-DIVFREE rule for anything on the
    row path). PURE in `(group_key_hash, val, num_workers)`: every copy of one
    pair gets one owner, which is the whole correctness argument above.

    Args:
        group_key_hash: The row's composite group hash.
        val: The row's distinct value (the key `CdDistinctSet` admits).
        num_workers: K. Must be >= 1.

    Returns:
        A bucket in `[0, num_workers)`.
    """
    var z = UInt(val) + UInt(group_key_hash) * 0x9E3779B97F4A7C15
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) * 0x94D049BB133111EB
    z = z ^ (z >> 31)
    return Int(((z >> 32) * UInt(num_workers)) >> 32)


# =============================================================================
# Route witness — process-wide, folded once per query
# =============================================================================


def _init_cd_heavy_counter() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn shared by the counters below."""
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _CD_HEAVY_GROUPS = _Global[
    "komira_cd_heavy_split_groups", _init_cd_heavy_counter,
]
comptime _CD_HEAVY_MERGED = _Global[
    "komira_cd_heavy_split_merged_partials", _init_cd_heavy_counter,
]
comptime _CD_WORKER_MAX_ROWS = _Global[
    "komira_cd_worker_max_rows_last", _init_cd_heavy_counter,
]
comptime _CD_WORKER_ROWS = _Global[
    "komira_cd_worker_rows_total_last", _init_cd_heavy_counter,
]
comptime _CD_WORKER_SCANNED = _Global[
    "komira_cd_worker_rows_scanned_total_last", _init_cd_heavy_counter,
]


def cd_heavy_note(
    heavy_groups: Int, merged_partials: Int, max_worker_rows: Int, total_rows: Int
) raises:
    """Fold one dispatch into the witness. Called once per query by the driver.

    Args:
        heavy_groups: Heavy groups this dispatch split (ADDED to the counter).
        merged_partials: Partial group rows the merge folded into an earlier
            partial of the same group (ADDED).
        max_worker_rows: Rows the busiest worker owned (STORED: last dispatch).
        total_rows: Rows owned summed over workers (STORED: last dispatch).
    """
    # SAFETY: §6 FFI carve-out — `get_or_create_ptr` targets KGEN-runtime static
    # storage (process-lifetime); the wildcard is the stdlib `_Global` API's own
    # return type, confined to this helper.
    if heavy_groups != 0:
        var g = _CD_HEAVY_GROUPS.get_or_create_ptr()
        _ = g[][].fetch_add(Int64(heavy_groups))
    if merged_partials != 0:
        var m = _CD_HEAVY_MERGED.get_or_create_ptr()
        _ = m[][].fetch_add(Int64(merged_partials))
    var x = _CD_WORKER_MAX_ROWS.get_or_create_ptr()
    x[][].store(Scalar[DType.int64](max_worker_rows))
    var t = _CD_WORKER_ROWS.get_or_create_ptr()
    t[][].store(Scalar[DType.int64](total_rows))


def cd_worker_scan_note(scanned_total: Int) raises:
    """CDP-OWNERMAP witness (STORED: last dispatch): rows whose keys the AGG
    pass READ and HASHED, summed over workers. Under the old K x N scan it
    was K x N; with the owner map it is N (plus K-1 extra reads of each heavy
    row whose aggregates are owned separately). Once per query.

    Args:
        scanned_total: The sum of every worker's `wk_scanned`.
    """
    # SAFETY: §6 FFI carve-out (see `cd_heavy_note`).
    var sc = _CD_WORKER_SCANNED.get_or_create_ptr()
    sc[][].store(Scalar[DType.int64](scanned_total))


def cd_worker_rows_scanned_total_last() raises -> Int:
    """Rows the AGG pass keyed and hashed, summed over workers, LAST dispatch."""
    # SAFETY: §6 FFI carve-out (see `cd_heavy_note`).
    var sc = _CD_WORKER_SCANNED.get_or_create_ptr()
    return Int(sc[][].load())


def cd_heavy_groups_count() raises -> Int:
    """Process-wide count of heavy groups split."""
    # SAFETY: §6 FFI carve-out (see `cd_heavy_note`).
    var g = _CD_HEAVY_GROUPS.get_or_create_ptr()
    return Int(g[][].load())


def cd_heavy_merged_count() raises -> Int:
    """Process-wide count of partial group rows folded by the merge."""
    # SAFETY: §6 FFI carve-out (see `cd_heavy_note`).
    var m = _CD_HEAVY_MERGED.get_or_create_ptr()
    return Int(m[][].load())


def cd_worker_max_rows_last() raises -> Int:
    """Rows the busiest worker owned in the LAST dispatch."""
    # SAFETY: §6 FFI carve-out (see `cd_heavy_note`).
    var x = _CD_WORKER_MAX_ROWS.get_or_create_ptr()
    return Int(x[][].load())


def cd_worker_rows_total_last() raises -> Int:
    """Rows owned summed over workers in the LAST dispatch."""
    # SAFETY: §6 FFI carve-out (see `cd_heavy_note`).
    var t = _CD_WORKER_ROWS.get_or_create_ptr()
    return Int(t[][].load())


def reset_cd_heavy_counters() raises:
    """Reset every counter in this file to 0 (test setup)."""
    # SAFETY: §6 FFI carve-out (see `cd_heavy_note`).
    var g = _CD_HEAVY_GROUPS.get_or_create_ptr()
    g[][].store(Scalar[DType.int64](0))
    var m = _CD_HEAVY_MERGED.get_or_create_ptr()
    m[][].store(Scalar[DType.int64](0))
    var x = _CD_WORKER_MAX_ROWS.get_or_create_ptr()
    x[][].store(Scalar[DType.int64](0))
    var t = _CD_WORKER_ROWS.get_or_create_ptr()
    t[][].store(Scalar[DType.int64](0))
    var sc = _CD_WORKER_SCANNED.get_or_create_ptr()
    sc[][].store(Scalar[DType.int64](0))
