# =============================================================================
# join_probe_semi_anti -- the SEMI and ANTI probes of `HashJoinBuilder`, and
# their COUNT fast paths
# =============================================================================
#
# SEMI keeps a probe row with at least one match, once; ANTI keeps a probe row
# with none. A NULL probe key matches nothing, so SEMI drops it and ANTI keeps
# it. They read the chain KEY and LINK but never the build ROW, so only the
# `fused` layout changes their loops.
# =============================================================================

from std.sys.intrinsics import prefetch, PrefetchOptions

from komira_arrow.primitive_array import PrimitiveArray

from .join import HashJoinBuilder, _CHAIN_END, _PREFETCH_DISTANCE, _hash_join_key
from .join_layout_counter import join_layout_record_probe


def probe_semi(b: HashJoinBuilder, probe_keys: PrimitiveArray[DType.int64]) raises -> List[Int]:
    """Two-way chain-entry-layout dispatcher for the semi-join probe.

    SEMI reads the chain KEY and the chain LINK but never the build ROW, so
    only the `fused` chain-entry layout can change this loop -- the `nobi`
    layout has nothing to delete here. That is why this specialises on one parameter
    and `probe_inner_into` on two. See `_probe_semi`."""
    b._refuse_pay_inline("probe_semi")
    join_layout_record_probe("probe_semi", b._bi_elided, b._fused)
    if b._fused:
        return _probe_semi[True](b, probe_keys)
    return _probe_semi[False](b, probe_keys)


def _probe_semi[
    fused: Bool
](b: HashJoinBuilder, probe_keys: PrimitiveArray[DType.int64]) raises -> List[Int]:
    """Semi-join: return probe indices that have at least one match.

    For each probe row, checks if ANY matching build key exists.
    Each probe row appears at most once in the result, even if
    multiple build rows match (this is the key difference from inner
    join, which would emit N pairs for N build matches).

    This implements the "key-only dedup" optimization:
    we only need to know IF a match exists, not enumerate all matches.
    Walking the chain stops at the first match.

    Performance note: when the build side is small (< 4096 entries),
    the hash table fits entirely in L1/L2 cache. In this case, the
    Bloom filter check (FNV-1a hash + 8 block reads per probe) is MORE
    expensive than a direct HT probe (1 hash + 1-2 memory reads). We
    skip the Bloom filter for small build sides.

    Args:
        probe_keys: The probe-side join key column.

    Returns:
        A list of probe indices that have at least one match in the
        build side. Length <= probe_keys.length.
    """
    var n = probe_keys.length
    var result = List[Int](capacity=min(n, b.num_build))
    var mask = UInt64(b.capacity - 1)
    # A NULL probe key has no match -> not emitted by SEMI.
    var probe_has_nulls = probe_keys.null_count != 0
    # Origin-tied view of the key buffer (`view_ro`), bitcast to Int64.
    # `probe_key_view` keepalive holds the borrow through the probe body.
    var probe_key_view = probe_keys.view_ro()
    var probe_key_ptr = probe_key_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
    var build_n = b.num_build

    # SAFETY: Direct pointer access into build_keys and hash_table
    # avoids per-element bounds checks in the hot loop. Indices come
    # from the hash table chains which are constructed in build() and
    # are guaranteed valid.
    var build_key_ptr = b.build_keys.unsafe_ptr()
    var ht_ptr = b.hash_table.unsafe_ptr()
    var chain_ptr = b.next_chain.unsafe_ptr()
    # Fused 16-byte-record view; empty and never dereferenced unless `fused`.
    var kn_ptr = b.key_next.unsafe_ptr()

    # For small build sides (HT fits in L1 cache), skip the Bloom
    # filter entirely. The FNV-1a hash + block reads cost more than
    # a direct HT probe when the table is cache-resident.
    # Threshold: 4096 entries * ~24 bytes/entry = ~96KB < L1 cache.
    if build_n <= 4096:
        # Small-build fast path: direct HT probe, no prefetch (HT is
        # fully L1-resident, prefetch is pure overhead here).
        for probe_idx in range(n):
            # NULL probe key matches nothing -> not emitted by SEMI.
            if probe_has_nulls and probe_keys.is_null(probe_idx):
                continue
            var probe_key = Int64((probe_key_ptr + probe_idx)[])
            var h = _hash_join_key(probe_key)
            var slot = Int(h & mask)
            var chain_idx = (ht_ptr + slot)[]
            while chain_idx != _CHAIN_END:
                var chain_key: Int64
                comptime if fused:
                    chain_key = (kn_ptr + 2 * chain_idx)[]
                else:
                    chain_key = (build_key_ptr + chain_idx)[]
                if chain_key == probe_key:
                    result.append(probe_idx)
                    break
                comptime if fused:
                    chain_idx = Int((kn_ptr + 2 * chain_idx + 1)[])
                else:
                    chain_idx = (chain_ptr + chain_idx)[]
    else:
        # PERF-CRITICAL: the large-build path mirrors probe_inner_into's
        # two-stage prefetch (stage 1: HT bucket; stage 2: build_keys
        # entry at the chain head).
        # NOT-VECTORIZABLE: HJ probe -- chain pointer traversal is
        # data-dependent.
        for probe_idx in range(n):
            # Stage 1: full-distance prefetch of HT bucket.
            if probe_idx + _PREFETCH_DISTANCE < n:
                var future_key = Int64((probe_key_ptr + probe_idx + _PREFETCH_DISTANCE)[])
                var fh = _hash_join_key(future_key)
                var future_slot = Int(fh & mask)
                prefetch[params = PrefetchOptions().for_read().high_locality()](
                    (ht_ptr + future_slot).bitcast[Scalar[DType.int64]]()
                )

            # Stage 2: half-distance prefetch of build_keys head of chain.
            if probe_idx + _PREFETCH_DISTANCE // 2 < n:
                var mid_key = Int64((probe_key_ptr + probe_idx + _PREFETCH_DISTANCE // 2)[])
                var mh = _hash_join_key(mid_key)
                var mid_slot = Int(mh & mask)
                var mid_chain = (ht_ptr + mid_slot)[]
                if mid_chain != _CHAIN_END:
                    comptime if fused:
                        prefetch[params = PrefetchOptions().for_read().high_locality()](
                            (kn_ptr + 2 * mid_chain).bitcast[Scalar[DType.int64]]()
                        )
                    else:
                        prefetch[params = PrefetchOptions().for_read().high_locality()](
                            (build_key_ptr + mid_chain).bitcast[Scalar[DType.int64]]()
                        )

            var probe_key = Int64((probe_key_ptr + probe_idx)[])
            # NULL probe key matches nothing -> not emitted by SEMI.
            if probe_has_nulls and probe_keys.is_null(probe_idx):
                continue
            # bypass empty-bloom builders.
            # reuse the HT hash for the bloom pre-check.
            var h = _hash_join_key(probe_key)
            if b._use_bloom and not b.bloom.might_contain_join_key(
                probe_key, h
            ):
                continue
            var slot = Int(h & mask)
            var chain_idx = (ht_ptr + slot)[]
            while chain_idx != _CHAIN_END:
                var chain_key: Int64
                comptime if fused:
                    chain_key = (kn_ptr + 2 * chain_idx)[]
                else:
                    chain_key = (build_key_ptr + chain_idx)[]
                if chain_key == probe_key:
                    result.append(probe_idx)
                    break
                comptime if fused:
                    chain_idx = Int((kn_ptr + 2 * chain_idx + 1)[])
                else:
                    chain_idx = (chain_ptr + chain_idx)[]

    # Keepalives: prevent premature destruction of self's fields whose
    # raw pointers were extracted above.
    _ = b.hash_table
    _ = b.build_keys
    _ = b.next_chain
    _ = b.key_next
    return result^


def probe_semi_count(
    b: HashJoinBuilder, probe_keys: PrimitiveArray[DType.int64]
) raises -> Int:
    """Two-way chain-entry-layout dispatcher for the SEMI COUNT fast path.

    Like `probe_semi`, this never reads the build ROW, so only the fused
    key/next lever can change the loop. See `_probe_semi_count`."""
    b._refuse_pay_inline("probe_semi_count")
    join_layout_record_probe(
        "probe_semi_count", b._bi_elided, b._fused
    )
    if b._fused:
        return _probe_semi_count[True](b, probe_keys)
    return _probe_semi_count[False](b, probe_keys)


def _probe_semi_count[
    fused: Bool
](b: HashJoinBuilder, probe_keys: PrimitiveArray[DType.int64]) raises -> Int:
    """SEMI-join COUNT fast path.

    Return the NUMBER of probe rows that have >= 1 match in build, WITHOUT
    materializing the survivor index list (the `probe_semi -> List[Int]` the
    count-only caller then only `len()`s + gathers). Used by the count-only
    join sink when a SEMI breaker feeds a 0-key `COUNT(*)`: the answer is the
    survivor row COUNT, so tallying a scalar counter over the SAME bloom-skip /
    two-stage-prefetch chain walk avoids building the survivor List and the gather that follows
it.

    BYTE-IDENTICAL count to `len(probe_semi(probe_keys))` for every input (the
    match predicate is the SAME chain-walk-to-first-match; NULL probe keys are
    excluded identically). Honors NO selection mask -- the count-only probe op
    falls back to the `probe_semi` + `_sel_keep_single` + `len` path when a
    selection mask is present (correctness), so this scalar counter is reached
    only for the no-mask probe.
    """
    var n = probe_keys.length
    var count = 0
    var mask = UInt64(b.capacity - 1)
    # A NULL probe key has no match -> not counted by SEMI.
    var probe_has_nulls = probe_keys.null_count != 0
    var probe_key_view = probe_keys.view_ro()
    var probe_key_ptr = probe_key_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
    var build_n = b.num_build

    # SAFETY: Direct pointer access into build_keys and hash_table avoids
    # per-element bounds checks in the hot loop. Indices come from the hash
    # table chains constructed in build() and are guaranteed valid; the
    # keepalives below hold self's fields alive through the loop.
    var build_key_ptr = b.build_keys.unsafe_ptr()
    var ht_ptr = b.hash_table.unsafe_ptr()
    var chain_ptr = b.next_chain.unsafe_ptr()
    # Fused 16-byte-record view; empty and never dereferenced unless `fused`.
    var kn_ptr = b.key_next.unsafe_ptr()

    # Small-build fast path: HT is L1-resident, skip Bloom + prefetch (mirrors
    # probe_semi's `build_n <= 4096` arm).
    if build_n <= 4096:
        for probe_idx in range(n):
            if probe_has_nulls and probe_keys.is_null(probe_idx):
                continue
            var probe_key = Int64((probe_key_ptr + probe_idx)[])
            var h = _hash_join_key(probe_key)
            var slot = Int(h & mask)
            var chain_idx = (ht_ptr + slot)[]
            while chain_idx != _CHAIN_END:
                var chain_key: Int64
                comptime if fused:
                    chain_key = (kn_ptr + 2 * chain_idx)[]
                else:
                    chain_key = (build_key_ptr + chain_idx)[]
                if chain_key == probe_key:
                    count += 1
                    break
                comptime if fused:
                    chain_idx = Int((kn_ptr + 2 * chain_idx + 1)[])
                else:
                    chain_idx = (chain_ptr + chain_idx)[]
    else:
        # Large-build path: two-stage prefetch mirror of probe_semi's large arm.
        # NOT-VECTORIZABLE: HJ probe -- chain pointer traversal is data-dependent.
        for probe_idx in range(n):
            if probe_idx + _PREFETCH_DISTANCE < n:
                var future_key = Int64((probe_key_ptr + probe_idx + _PREFETCH_DISTANCE)[])
                var fh = _hash_join_key(future_key)
                var future_slot = Int(fh & mask)
                prefetch[params = PrefetchOptions().for_read().high_locality()](
                    (ht_ptr + future_slot).bitcast[Scalar[DType.int64]]()
                )
            if probe_idx + _PREFETCH_DISTANCE // 2 < n:
                var mid_key = Int64((probe_key_ptr + probe_idx + _PREFETCH_DISTANCE // 2)[])
                var mh = _hash_join_key(mid_key)
                var mid_slot = Int(mh & mask)
                var mid_chain = (ht_ptr + mid_slot)[]
                if mid_chain != _CHAIN_END:
                    comptime if fused:
                        prefetch[params = PrefetchOptions().for_read().high_locality()](
                            (kn_ptr + 2 * mid_chain).bitcast[Scalar[DType.int64]]()
                        )
                    else:
                        prefetch[params = PrefetchOptions().for_read().high_locality()](
                            (build_key_ptr + mid_chain).bitcast[Scalar[DType.int64]]()
                        )
            var probe_key = Int64((probe_key_ptr + probe_idx)[])
            if probe_has_nulls and probe_keys.is_null(probe_idx):
                continue
            # reuse the HT hash for the bloom pre-check
            # (the semi COUNT(*) hot path: avoids the redundant xxHash64).
            var h = _hash_join_key(probe_key)
            if b._use_bloom and not b.bloom.might_contain_join_key(
                probe_key, h
            ):
                continue
            var slot = Int(h & mask)
            var chain_idx = (ht_ptr + slot)[]
            while chain_idx != _CHAIN_END:
                var chain_key: Int64
                comptime if fused:
                    chain_key = (kn_ptr + 2 * chain_idx)[]
                else:
                    chain_key = (build_key_ptr + chain_idx)[]
                if chain_key == probe_key:
                    count += 1
                    break
                comptime if fused:
                    chain_idx = Int((kn_ptr + 2 * chain_idx + 1)[])
                else:
                    chain_idx = (chain_ptr + chain_idx)[]

    # Keepalives: prevent premature destruction of self's fields whose raw
    # pointers were extracted above.
    _ = b.hash_table
    _ = b.build_keys
    _ = b.next_chain
    _ = b.key_next
    return count


def probe_anti(b: HashJoinBuilder, probe_keys: PrimitiveArray[DType.int64]) raises -> List[Int]:
    """Two-way chain-entry-layout dispatcher for the anti-join probe.

    ANTI reads the chain KEY and the chain LINK but never the build ROW, so
    only the fused key/next lever changes this loop. See `_probe_anti`."""
    b._refuse_pay_inline("probe_anti")
    join_layout_record_probe("probe_anti", b._bi_elided, b._fused)
    if b._fused:
        return _probe_anti[True](b, probe_keys)
    return _probe_anti[False](b, probe_keys)


def _probe_anti[
    fused: Bool
](b: HashJoinBuilder, probe_keys: PrimitiveArray[DType.int64]) raises -> List[Int]:
    """Anti-join: return probe indices that have NO match in build.

    The complement of semi-join: returns probe rows where no build
    row has a matching key. Used for "NOT IN" / "NOT EXISTS" queries.

    PERF-CRITICAL: Two-stage software prefetch
    mirrors probe_inner_into. For large probe sizes (>= _PREFETCH_DISTANCE
    rows), stage-1 prefetches the HT bucket _PREFETCH_DISTANCE ahead and
    stage-2 prefetches the build_keys entry the bucket points to. This
    is the same latency-hiding pattern
    probe_inner_into has had since day 1 (the anti-join previously
    lacked it). Bloom filter is NOT used for anti-join: when the build
    side is large and the typical anti-join has significant key overlap
    (few unmatched rows), bloom.might_contain returns
    True ~100% of the time -- a wasted 8-word block read before the
    mandatory chain walk. We skip it entirely to cut a full cache miss
    out of the inner loop.

    Args:
        probe_keys: The probe-side join key column.

    Returns:
        A list of probe indices that have NO match in the build side.
        Length <= probe_keys.length.
    """
    var n = probe_keys.length
    # Most anti-join outputs are small (tiny selectivity). Start with a
    # conservative capacity to avoid 1M-int over-allocation when the
    # workload is "match almost everything".
    var result = List[Int](capacity=max(n // 64, 256))
    var mask = UInt64(b.capacity - 1)
    # A NULL probe key matches nothing -> NOT EXISTS is TRUE -> KEPT by
    # ANTI. Critical even though NULL build keys are excluded: a NULL probe
    # key encodes as 0 and would otherwise spuriously match a real build key
    # 0 and be (wrongly) dropped. `probe_has_nulls` gates the consult.
    var probe_has_nulls = probe_keys.null_count != 0
    # Origin-tied view of the key buffer (`view_ro`), bitcast to Int64.
    # `probe_key_view` keepalive holds the borrow through the probe body.
    var probe_key_view = probe_keys.view_ro()
    var probe_key_ptr = probe_key_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
    var build_key_ptr = b.build_keys.unsafe_ptr()
    var ht_ptr = b.hash_table.unsafe_ptr()
    var chain_ptr = b.next_chain.unsafe_ptr()
    # Fused 16-byte-record view; empty and never dereferenced unless `fused`.
    var kn_ptr = b.key_next.unsafe_ptr()

    # NOT-VECTORIZABLE: HJ probe -- chain pointer traversal is data-dependent.
    # Software prefetch hides HT and build_keys load latency.
    for probe_idx in range(n):
        # Stage 1: prefetch the HT bucket for a future probe key.
        if probe_idx + _PREFETCH_DISTANCE < n:
            var future_key = Int64((probe_key_ptr + probe_idx + _PREFETCH_DISTANCE)[])
            var fh = _hash_join_key(future_key)
            var future_slot = Int(fh & mask)
            # SAFETY: Prefetch is a hint -- invalid addresses silently ignored.
            prefetch[params = PrefetchOptions().for_read().high_locality()](
                (ht_ptr + future_slot).bitcast[Scalar[DType.int64]]()
            )

        # Stage 2: the stage-1-prefetched HT bucket should be in L1 by now
        # at half-distance. Prefetch the build_keys entry it points to.
        if probe_idx + _PREFETCH_DISTANCE // 2 < n:
            var mid_key = Int64((probe_key_ptr + probe_idx + _PREFETCH_DISTANCE // 2)[])
            var mh = _hash_join_key(mid_key)
            var mid_slot = Int(mh & mask)
            var mid_chain = (ht_ptr + mid_slot)[]
            if mid_chain != _CHAIN_END:
                comptime if fused:
                    prefetch[params = PrefetchOptions().for_read().high_locality()](
                        (kn_ptr + 2 * mid_chain).bitcast[Scalar[DType.int64]]()
                    )
                else:
                    prefetch[params = PrefetchOptions().for_read().high_locality()](
                        (build_key_ptr + mid_chain).bitcast[Scalar[DType.int64]]()
                    )

        var probe_key = Int64((probe_key_ptr + probe_idx)[])
        var found = False
        # A NULL probe key matches nothing -> KEPT by ANTI (skip walk).
        if not (probe_has_nulls and probe_keys.is_null(probe_idx)):
            var h = _hash_join_key(probe_key)
            var slot = Int(h & mask)
            var chain_idx = (ht_ptr + slot)[]
            while chain_idx != _CHAIN_END:
                var chain_key: Int64
                comptime if fused:
                    chain_key = (kn_ptr + 2 * chain_idx)[]
                else:
                    chain_key = (build_key_ptr + chain_idx)[]
                if chain_key == probe_key:
                    found = True
                    break
                comptime if fused:
                    chain_idx = Int((kn_ptr + 2 * chain_idx + 1)[])
                else:
                    chain_idx = (chain_ptr + chain_idx)[]
        if not found:
            result.append(probe_idx)

    # Keepalive: prevent premature destruction of self's fields whose
    # raw pointers were extracted above.
    _ = b.hash_table
    _ = b.build_keys
    _ = b.next_chain
    _ = b.key_next
    return result^


def probe_anti_count(
    b: HashJoinBuilder, probe_keys: PrimitiveArray[DType.int64]
) raises -> Int:
    """Two-way chain-entry-layout dispatcher for the ANTI COUNT fast path.

    Reads no build ROW, so only the fused key/next lever applies. See
    `_probe_anti_count`."""
    b._refuse_pay_inline("probe_anti_count")
    join_layout_record_probe(
        "probe_anti_count", b._bi_elided, b._fused
    )
    if b._fused:
        return _probe_anti_count[True](b, probe_keys)
    return _probe_anti_count[False](b, probe_keys)


def _probe_anti_count[
    fused: Bool
](b: HashJoinBuilder, probe_keys: PrimitiveArray[DType.int64]) raises -> Int:
    """ANTI-join COUNT fast path.

    Return the NUMBER of probe rows that have NO match in build (the complement
    of `probe_semi_count`), WITHOUT materializing the survivor index list. Used
    by the count-only join sink when an ANTI breaker feeds a 0-key `COUNT(*)`.
    BYTE-IDENTICAL count to `len(probe_anti(probe_keys))` for every input (the
    SAME chain-walk match predicate; a NULL probe key is KEPT by ANTI
    identically). Honors NO selection mask -- the count-only probe op falls back
    to `probe_anti` + `_sel_keep_single` + `len` when a mask is present.
    """
    var n = probe_keys.length
    var count = 0
    var mask = UInt64(b.capacity - 1)
    # A NULL probe key matches nothing -> KEPT by ANTI (counted).
    var probe_has_nulls = probe_keys.null_count != 0
    var probe_key_view = probe_keys.view_ro()
    var probe_key_ptr = probe_key_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
    # SAFETY: raw pointer access into build_keys/hash_table for the hot loop;
    # indices come from build()-constructed chains, kept alive by the
    # keepalives below. Anti-join skips the Bloom filter (probe_anti rationale).
    var build_key_ptr = b.build_keys.unsafe_ptr()
    var ht_ptr = b.hash_table.unsafe_ptr()
    var chain_ptr = b.next_chain.unsafe_ptr()
    # Fused 16-byte-record view; empty and never dereferenced unless `fused`.
    var kn_ptr = b.key_next.unsafe_ptr()

    # NOT-VECTORIZABLE: HJ probe -- chain pointer traversal is data-dependent.
    # Two-stage software prefetch mirrors probe_anti.
    for probe_idx in range(n):
        if probe_idx + _PREFETCH_DISTANCE < n:
            var future_key = Int64((probe_key_ptr + probe_idx + _PREFETCH_DISTANCE)[])
            var fh = _hash_join_key(future_key)
            var future_slot = Int(fh & mask)
            prefetch[params = PrefetchOptions().for_read().high_locality()](
                (ht_ptr + future_slot).bitcast[Scalar[DType.int64]]()
            )
        if probe_idx + _PREFETCH_DISTANCE // 2 < n:
            var mid_key = Int64((probe_key_ptr + probe_idx + _PREFETCH_DISTANCE // 2)[])
            var mh = _hash_join_key(mid_key)
            var mid_slot = Int(mh & mask)
            var mid_chain = (ht_ptr + mid_slot)[]
            if mid_chain != _CHAIN_END:
                comptime if fused:
                    prefetch[params = PrefetchOptions().for_read().high_locality()](
                        (kn_ptr + 2 * mid_chain).bitcast[Scalar[DType.int64]]()
                    )
                else:
                    prefetch[params = PrefetchOptions().for_read().high_locality()](
                        (build_key_ptr + mid_chain).bitcast[Scalar[DType.int64]]()
                    )

        var probe_key = Int64((probe_key_ptr + probe_idx)[])
        var found = False
        # A NULL probe key matches nothing -> KEPT by ANTI (skip walk).
        if not (probe_has_nulls and probe_keys.is_null(probe_idx)):
            var h = _hash_join_key(probe_key)
            var slot = Int(h & mask)
            var chain_idx = (ht_ptr + slot)[]
            while chain_idx != _CHAIN_END:
                var chain_key: Int64
                comptime if fused:
                    chain_key = (kn_ptr + 2 * chain_idx)[]
                else:
                    chain_key = (build_key_ptr + chain_idx)[]
                if chain_key == probe_key:
                    found = True
                    break
                comptime if fused:
                    chain_idx = Int((kn_ptr + 2 * chain_idx + 1)[])
                else:
                    chain_idx = (chain_ptr + chain_idx)[]
        if not found:
            count += 1

    # Keepalive: prevent premature destruction of self's fields whose raw
    # pointers were extracted above.
    _ = b.hash_table
    _ = b.build_keys
    _ = b.next_chain
    _ = b.key_next
    return count
