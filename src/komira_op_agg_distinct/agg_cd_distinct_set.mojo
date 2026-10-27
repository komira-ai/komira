# =============================================================================
# CDPDEDUP — the per-worker DISTINCT-PAIR set for grouped COUNT(DISTINCT)
# =============================================================================
#
# THE SHAPE THIS FILE EXISTS TO CHANGE, stated as the two state layouts:
#
#     ours, before     `cd_sets: List[List[List[Int]]]` — one heap `List[Int]`
#                      per (agg, group), holding EVERY ACCEPTED ROW's value,
#                      deduped later by a `sort()` + adjacent-difference scan
#                      running on the DRIVER THREAD.
#     the shape here  a level-1 GROUP BY over {groups} U {aggregate argument}
#                      with ZERO aggregate functions: ONE hash-table row per
#                      DISTINCT PAIR, and the dedup IS the hash table —
#                      parallel by construction (the same shape DuckDB uses).
#
# We stored ROWS; this stores DISTINCT PAIRS. When rows repeat a value within a
# group, the per-row list holds several entries per pair, and deduping late
# makes a provably SINGLE-THREADED `aggout` phase.
#
# `CdDistinctSet` is the missing half: an open-addressed set over the pair
# (aggregate slot, group id, value), one per WORKER, probed once per accepted
# row. A row whose pair is already present contributes nothing and is dropped
# on the spot; a row whose pair is new bumps that group's running distinct
# counter. `aggout` then reads an integer per group.
#
# WHY THIS IS NOT AN AMDAHL FIX, AND WHY THE AMDAHL FIX WOULD NOT HAVE
#    WORKED. The obvious alternative — parallelise the existing per-group
#    `sort()` across groups — is refuted when one group holds most of the rows
#    (a top group with 91.8% of the rows): the serial cost is ONE group's sort
#    of one very long list, and splitting the group loop across K workers caps
#    out at 1/0.918 = 1.09x. Dedup at insert deletes the work instead of
#    spreading it, and it is the only one of the two shapes that also deletes
#    the per-group `List` headers (one per group).
#
# ============================== THE KEY ======================================
#
# `tag` packs the aggregate slot and the group id into one Int64 so a slot is
# two Int64s and the whole table is two flat allocations:
#
#     tag = (Int64(agg_slot) << _CD_TAG_AGG_SHIFT) | Int64(gid)
#
# `gid` is bounded by the per-worker group count (stored as Int32 in the group
# HT) and `agg_slot` by `num_aggs`, so `tag` is always >= 0 and `-1` is a free
# EMPTY sentinel — no separate occupancy array, no separate `agg` array.
#
# A SLOT HIT COMPARES BOTH WORDS. Comparing the hash, or the tag alone, would
#   make a hash collision silently merge two distinct values into one — a WRONG
#   COUNT that no exception and no schema check can see.
#
# ============================== LIFETIME =====================================
#
# Owned BY VALUE as a field of `_PerWorkerCDState`, which lives in the
# dispatch's `Slab[_PerWorkerCDState]`; worker `wid` is the unique writer to
# slot `wid`. Growth happens INSIDE the worker and is worker-local — the same
# property the group HT's own resize relies on (the driver that dispatches the
# workers is added by a later part).
#
# ALLOCATION IS DELIBERATELY LAZY. `reserve_hint` records a capacity and
#   allocates NOTHING; the first `admit` allocates. The driver's `init` loop is
#   SERIAL (`htinit`), so an eager allocation here would have paid, serially,
#   for a table that is filled in parallel. CDHTSIZE moved the
#   GROUP table out of that loop for the same reason — it now also records a
#   capacity and is allocated by the worker (`agg_cd_group_ht_sizing.mojo`).
#
# Pointer rules: no `UnsafePointer` in any signature, no
# wildcard origins, no `unsafe_from_address`. State is two `List[Int64]`s.
# (`_cd_distinct_value_at`, at the end of the file, reads a value column
# through `TypedColumnPtrs`' own accessors; it names no pointer type either.)
# =============================================================================


from komira_agg_api.cd_distinct_key import cd_f64_distinct_key
from komira_agg_api.agg_column_ptrs import (
    TypedColumnPtrs,
    AGG_KIND_COUNT,
    AGG_KIND_I32,
    AGG_KIND_I64,
)


# Aggregate slot occupies the bits above the group id. A per-worker group id is
# bounded by the worker's own group count and stored as Int32 upstream, so 40
# bits is >2^8 times the widest gid that can reach here and leaves 23 bits of
# aggregate slot under the sign bit.
comptime _CD_TAG_AGG_SHIFT: Int = 40

# EMPTY sentinel. A real tag is `(agg << 40) | gid` with both halves >= 0, so
# it is never negative and `-1` cannot collide with one.
comptime _CD_EMPTY_TAG: Int64 = -1

# Growth threshold, as a fraction expressed in integers: resize when
# `count * _CD_LOAD_DEN > cap * _CD_LOAD_NUM`, i.e. above 2/3 full. Linear
# probing degrades past ~3/4; 2/3 keeps the probe chain short while holding the
# table half the size a 1/2 threshold would have demanded — which is what keeps
# a worker holding ~1.09M distinct pairs at 2^21 slots instead of 2^22.
comptime _CD_LOAD_NUM: Int = 2
comptime _CD_LOAD_DEN: Int = 3

# Floor / ceiling on the capacity the driver's row-count hint may ask for. The
# hint is a ROW count and the table holds PAIRS, so it is an over-estimate by
# exactly the rows/pairs factor this file exists to exploit; capping it keeps
# the up-front allocation at 1 MiB per worker and lets growth find the real
# size.
comptime _CD_MIN_CAP: Int = 1024
comptime _CD_HINT_MAX_CAP: Int = 65_536


@always_inline
def cd_pair_tag(agg_slot: Int, gid: Int) -> Int64:
    """Pack `(agg_slot, gid)` into the Int64 tag half of a distinct-pair key.

    Args:
        agg_slot: Aggregate slot index within this aggregation.
        gid: Per-worker group id.

    Returns:
        The packed tag, always >= 0 so `_CD_EMPTY_TAG` cannot collide.
    """
    return (Int64(agg_slot) << Int64(_CD_TAG_AGG_SHIFT)) | Int64(gid)


@always_inline
def _cd_pair_hash(tag: Int64, val: Int64) -> UInt64:
    """Mix the two key words. Both halves must reach the low bits: `val` alone
    would collide every group on the same value, and `tag` alone would collide
    every value in the same group — the two shapes this table is asked for.

    Args:
        tag: The packed `(agg_slot, gid)` half of the key.
        val: The distinct value half of the key.

    Returns:
        The mixed 64-bit hash; the caller masks it to a slot.
    """
    var h = (UInt64(val) + 0x9E3779B97F4A7C15) * 0xBF58476D1CE4E5B9
    h = (h ^ UInt64(tag)) * 0x94D049BB133111EB
    return h ^ (h >> 31)


struct CdDistinctSet(Movable):
    """Open-addressed set of `(agg_slot, gid, value)` distinct pairs.

    One per worker, covering every aggregate slot and every group that worker
    owns. `admit` is the whole contract: it returns True exactly once per
    distinct pair, and False for every repeat.
    """

    var _tag: List[Int64]
    var _val: List[Int64]
    var _cap: Int
    var _mask: Int
    var _count: Int
    var _hint: Int

    def __init__(out self):
        self._tag = List[Int64]()
        self._val = List[Int64]()
        self._cap = 0
        self._mask = 0
        self._count = 0
        self._hint = _CD_MIN_CAP

    def reserve_hint(mut self, rows: Int):
        """Record the capacity the first `admit` should allocate. ALLOCATES
        NOTHING — see the lifetime note in the header: the caller runs this in
        a serial loop over K workers.

        Args:
            rows: The number of rows this worker may be offered. An
                over-estimate of the pair count by the rows/pairs factor,
                which is why the recorded capacity is capped.
        """
        var c = _CD_MIN_CAP
        while c < rows and c < _CD_HINT_MAX_CAP:
            c = c * 2
        self._hint = c

    def count(self) -> Int:
        """Number of distinct pairs admitted so far.

        Returns:
            The route witness: the number of rows a level-1 pair table
            holds, strictly below the number of rows offered whenever any value
            repeats within a group.
        """
        return self._count

    def capacity(self) -> Int:
        """Current slot capacity.

        Returns:
            0 before the first `admit` — the lazy-allocation contract.
        """
        return self._cap

    def _rehash_into(mut self, new_cap: Int):
        """Re-insert every live pair into a fresh table of `new_cap` slots.

        Args:
            new_cap: The new slot count. Must be a power of two and strictly
                greater than the live pair count.
        """
        var new_mask = new_cap - 1
        var new_tag = List[Int64](capacity=new_cap)
        var new_val = List[Int64](capacity=new_cap)
        for _ in range(new_cap):
            new_tag.append(_CD_EMPTY_TAG)
            new_val.append(Int64(0))
        for old in range(self._cap):
            var t = self._tag[old]
            if t == _CD_EMPTY_TAG:
                continue
            var v = self._val[old]
            var s = Int(_cd_pair_hash(t, v)) & new_mask
            while new_tag[s] != _CD_EMPTY_TAG:
                s = (s + 1) & new_mask
            new_tag[s] = t
            new_val[s] = v
        self._tag = new_tag^
        self._val = new_val^
        self._cap = new_cap
        self._mask = new_mask

    @always_inline
    def admit(mut self, tag: Int64, val: Int64) -> Bool:
        """Insert `(tag, val)` if absent.

        This is the dedup, and it happens at INSERT — the caller increments its
        per-group distinct counter on True and does nothing on False, so no
        per-group value buffer is ever built and nothing is sorted later.

        Args:
            tag: The packed `(agg_slot, gid)` key half, from `cd_pair_tag`.
            val: The distinct value key half.

        Returns:
            True iff the pair was NOT already present.
        """
        if self._cap == 0:
            self._rehash_into(self._hint)
        var slot = Int(_cd_pair_hash(tag, val)) & self._mask
        while True:
            var t = self._tag[slot]
            if t == _CD_EMPTY_TAG:
                self._tag[slot] = tag
                self._val[slot] = val
                self._count += 1
                # Load factor is held below 1 at all times, so the probe loop
                # above always terminates on an empty slot.
                if self._count * _CD_LOAD_DEN > self._cap * _CD_LOAD_NUM:
                    self._rehash_into(self._cap * 2)
                return True
            # BOTH WORDS. A tag-only or hash-only hit would merge two
            # distinct values into one and under-count, silently.
            if t == tag and self._val[slot] == val:
                return False
            slot = (slot + 1) & self._mask


# =============================================================================
# The distinct KEY of an aggregate's value — shared by every CD route
# =============================================================================


@always_inline
def _cd_distinct_value_at[
    o: Origin
](val_ptrs: TypedColumnPtrs[o], a: Int, row: Int) -> Int:
    """The distinct KEY of aggregate `a` at `row` -- the Int `CdDistinctSet`
    admits. Caller has already skipped a NULL row.

    ONE FUNCTION, EVERY READER, ON PURPOSE. The general parallel driver
    reads it to ADMIT a pair and, for a heavy group, to decide which worker
    OWNS the pair (`cd_pair_bucket(hash, value, K)`); the fused string-key
    route (added by a later part) reads it to admit. Those readings must
    be the SAME value: if ownership keyed on a different spelling of the value
    than the one admitted, two copies of one pair could land on two workers and
    be counted twice, and if the two routes keyed differently one query could
    answer two ways. (It lives here so both routes share it without an import
    cycle.)

    CD-TYPE-WIDTH -- `Int(f64)` TRUNCATES, so
    `count(DISTINCT price)` over [1.1, 1.9] keyed BOTH rows on 1 and answered
    1. The distinct key for a float is its IEEE bit pattern with -0.0 folded
    onto +0.0 -- the key `agg_mixed_cd_fold` and the streaming sink use.
    REACHABILITY: the one live route in gates the CD input to INT32/INT64,
    so the float arm is not reachable today; it is kept correct rather than left as a trap for whoever
    widens that envelope. The SERIAL TWIN carries the identical conversion --
    the two kernels are selected by a ROW-COUNT crossover, so a one-sided fix
    would make the answer depend on the row count.
    """
    var d = val_ptrs.kind_at(a)
    var off = val_ptrs.offset_at(a)
    if d == AGG_KIND_COUNT:
        return 0
    elif d == AGG_KIND_I32:
        return Int((val_ptrs._i32_ptr(a) + off + row)[])
    elif d == AGG_KIND_I64:
        return Int((val_ptrs._i64_ptr(a) + off + row)[])
    return Int(
        cd_f64_distinct_key(Float64((val_ptrs._f64_ptr(a) + off + row)[]))
    )
