# =============================================================================
# join_perfect_hash -- `PerfectHashJoin`, the direct-indexed join for dense
# unique INT64 build keys
# =============================================================================

from std.memory import memset, UnsafePointer

from komira_arrow.primitive_array import PrimitiveArray


# =============================================================================
# PerfectHashJoin -- direct-indexed join for dense integer keys
# =============================================================================
#
# For builds where keys are dense integers in a bounded range, use a direct-
# indexed array instead of hashing. entries[key - min_key] = build_row_index.
# Probe is a single array lookup -- no hashing, no chaining, no bloom check.
#
# When to use: single Int64 key, range (max-min+1) <= PERFECT_RANGE_CAP,
#              build-side has unique keys (PK-FK pattern).
# =============================================================================

# Maximum range for the perfect hash table. 4M entries * 8 bytes = 32MB.
comptime PERFECT_RANGE_CAP: Int = 4_194_304

# Sentinel: no build row at this key value.
comptime _PERFECT_EMPTY: Int = -1


struct PerfectHashJoin(Movable):
    """Direct-indexed join for dense integer keys (PK-FK pattern).

    _entries[key - min_key] = build row index, or _PERFECT_EMPTY if absent.
    Probe is a single array read -- zero hashing, zero chaining.

    The entries array is an internal raw buffer — callers should go through
    `probe_inner` / `probe_inner_into` rather than reach for the pointer.
    `_unsafe_entries_ptr()` is provided for rare cases where the caller
    needs direct array access (e.g., debugging / introspection).
    """
    # A `List[Int]`: the synthesised move and drop own the buffer.
    var _entries: List[Int]
    var min_key: Int
    var range_size: Int
    var num_rows: Int

    def __init__(out self, var entries: List[Int],
                 min_key: Int, range_size: Int, num_rows: Int):
        self._entries = entries^
        self.min_key = min_key
        self.range_size = range_size
        self.num_rows = num_rows

    @always_inline
    def _entries_mut_ptr(mut self) -> UnsafePointer[Int, origin_of(self)]:
        """Mutable-origin pointer to the entries buffer.

        SAFETY: Two-step cast widens the immutable-origin pointer
        `self._entries.unsafe_ptr()` returns on a borrowed `self` to a
        concrete mutable origin tied to `self` (the origin is
        tied to `self`, not widened). Takes `mut self` so `origin_of(self)` is a
        concrete mutable origin. Invalidated by any List realloc.
        """
        return self._entries.unsafe_ptr().unsafe_mut_cast[True]().unsafe_origin_cast[
            origin_of(self)
        ]()

    @always_inline
    def _unsafe_entries_ptr(mut self) -> UnsafePointer[Int, origin_of(self)]:
        """Raw entries-array pointer. SAFETY: valid for the lifetime of self."""
        return self._entries_mut_ptr()

    @staticmethod
    def try_build(keys: PrimitiveArray[DType.int64]) -> Optional[PerfectHashJoin]:
        """Try to build a PerfectHashJoin. Returns None if keys don't qualify.

        Qualifies when: non-empty, non-null, range <= PERFECT_RANGE_CAP,
        and all keys are unique.
        """
        var n = keys.length
        if n == 0:
            return None

        # NULL keys: the perfect-hash fast path encodes a
        # NULL build key as the DType-zero value, which would map a genuine SQL
        # NULL to a real dense slot and let a NULL probe key (also zero) match it.
        # The perfect hash is a pure optimization, so DECLINE when the build key
        # column has any nulls -> the caller falls back to the chained
        # `HashJoinBuilder`, which is NULL-correct (NULL build keys recorded but
        # unlinked; NULL probe keys match nothing).
        if keys.null_count != 0:
            return None

        # Origin-tied view of the key buffer (`view_ro`), bitcast to Int64.
        # `key_view` keeps the key buffer alive until the loop below ends.
        var key_view = keys.view_ro()
        var key_ptr = key_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
        var mn = Int((key_ptr + 0)[])
        var mx = mn
        for i in range(1, n):
            var v = Int((key_ptr + i)[])
            if v < mn:
                mn = v
            if v > mx:
                mx = v

        var rng = mx - mn + 1
        if rng > PERFECT_RANGE_CAP or rng < n:
            # Range too large or more rows than range (duplicates).
            return None

        var entries = List[Int](capacity=rng)
        entries.resize(unsafe_uninit_length=rng)
        memset(entries.unsafe_ptr().bitcast[UInt8](), 0xFF, rng * 8)  # fill with -1

        # Check uniqueness during insertion.
        # SAFETY: Mutable raw pointer into the local `entries` List.
        # The pointer's origin is tied to `entries` via `origin_of(entries)`.
        var ent_ptr = entries.unsafe_ptr().unsafe_mut_cast[True]().unsafe_origin_cast[
            origin_of(entries)
        ]()
        for i in range(n):
            var idx = Int((key_ptr + i)[]) - mn
            if (ent_ptr + idx)[] != _PERFECT_EMPTY:
                return None  # duplicate key
            (ent_ptr + idx)[] = i

        _ = keys  # keepalive
        return PerfectHashJoin(entries^, mn, rng, n)

    def probe_inner_into(
        mut self,
        probe_keys: PrimitiveArray[DType.int64],
        mut build_matches: List[Int],
        mut probe_matches: List[Int],
    ) raises:
        """Inner join probe via direct array lookup that appends to caller buffers.

        Preferred hot-path API (see `HashJoinBuilder.probe_inner_into` for
        the rationale). For each probe key: if in range and entries[key-min]
        != EMPTY, appends (build_idx, probe_idx).

        `mut self` is required by `_entries_mut_ptr()` (origin_of(self)
        yields a concrete MutableOrigin only on mut self). No mutation
        to self occurs; this is purely a read-only probe.

        `raises` because the NULL guard below consults
        `PrimitiveArray.is_null`, whose out-of-range arm raises — the same
        reason `HashJoinBuilder.probe_inner_into` is `raises`. The
        call is short-circuited away entirely on an all-valid probe.
        """
        var n = probe_keys.length

        # NULL keys: a NULL probe key matches NOTHING, so an
        # INNER probe emits no pair for it.
        #
        # NOTE: THIS IS NOT A DEFENSIVE CHECK — IT IS THE SAME ARGUMENT `try_build`
        # ALREADY MAKES ON THE OTHER SIDE. This table is indexed by the KEY
        # VALUE (`entries[key - min_key]`) and an Arrow NULL carries a DType-zero
        # value under its cleared validity bit, so an unguarded probe maps EVERY
        # NULL probe row onto slot `0 - min_key` and matches whatever build row
        # sits there — a silently WRONG EXTRA ROW with no exception and no crash.
        # `try_build` DECLINES a null-carrying BUILD side for exactly this reason
        # (see its comment); the identical reasoning applies to the probe side,
        # and `HashJoinBuilder.probe_inner_into` carries it too. Regression
        # test: `tests/test_join_sort_merge_perfect_hash.mojo`.
        #
        # `probe_has_nulls` gates the per-row consult so the all-valid probe —
        # every TPC-H PK-FK cell — stays byte-identical and pays one hoisted
        # compare for the whole loop.
        var probe_has_nulls = probe_keys.null_count != 0
        # Origin-tied view of the key buffer (`view_ro`), bitcast to Int64.
        # `pk_view` keepalive holds the borrow through the probe loop.
        var pk_view = probe_keys.view_ro()
        var pk_ptr = pk_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
        var mn = self.min_key
        var rng = self.range_size
        # Hoist the entries pointer once — loop body reads through it.
        var entries_ptr = self._entries_mut_ptr()

        for pi in range(n):
            # A NULL probe key matches nothing -> no INNER output.
            if probe_has_nulls and probe_keys.is_null(pi):
                continue
            var key = Int((pk_ptr + pi)[])
            var idx = key - mn
            if idx >= 0 and idx < rng:
                var build_row = (entries_ptr + idx)[]
                if build_row != _PERFECT_EMPTY:
                    build_matches.append(build_row)
                    probe_matches.append(pi)

        _ = probe_keys  # keepalive

    def probe_inner(
        mut self, probe_keys: PrimitiveArray[DType.int64]
    ) raises -> Tuple[List[Int], List[Int]]:
        """Inner join probe: Tuple-returning wrapper for test callers.

        Hot-path callers use `probe_inner_into` to skip the `.copy()`-forced
        tuple packing.
        """
        # PK-FK: unique keys, so output ~= n rows
        var build_matches = List[Int](capacity=probe_keys.length)
        var probe_matches = List[Int](capacity=probe_keys.length)
        self.probe_inner_into(probe_keys, build_matches, probe_matches)
        return (build_matches^, probe_matches^)
