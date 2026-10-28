# =============================================================================
# join_build_serial -- the serial builds of `HashJoinBuilder`: the chain-insert
# loop with the bloom filled inline (`hash_join_build`), and the one over a
# caller's pre-populated bloom (`hash_join_build_with_bloom`)
# =============================================================================
#
# `HashJoinBuilder.build` and `HashJoinBuilder.build_with_bloom` forward here.
# The parallel build is `hash_chain_parallel_build`; it falls back to
# `hash_join_build` below its threshold and produces the same layout.
# =============================================================================

from std.sys.intrinsics import prefetch, PrefetchOptions

from komira_arrow.primitive_array import PrimitiveArray
from komira_async.runtime.sched_trace import sched_trace_enabled
from komira_dynamic_filter.bloom_filter import BloomFilter
from komira_join_assembly.join_payload_inline import (
    JOIN_KN_WORDS,
    JOIN_KN_WORDS_PAY,
    join_payload_inline_record_build,
)

from .join import (
    HashJoinBuilder,
    _CHAIN_END,
    _PREFETCH_DISTANCE,
    _hash_join_key,
    _join_bloom_hash_family,
)
from .join_bloom_l1_resident import (
    bloom_l1_budget_bytes,
    bloom_l1_index_bytes,
    bloom_l1_note_declined,
    bloom_l1_note_kept,
    bloom_l1_should_decline,
    bloom_l1_trace_enabled,
    bloom_l1_witness,
)
from .join_layout_counter import join_layout_record_build


def hash_join_build_with_bloom(
    keys: PrimitiveArray[DType.int64],
    var bloom: BloomFilter,
    nobi: Bool = True,
    fused: Bool = True,
) raises -> HashJoinBuilder:
    """Construct the index from a PRE-POPULATED bloom filter, skipping the
    inline `bloom.insert_join_key` work in the serial chain loop.

    Identical algorithm to `build`, but the caller is responsible for
    populating `bloom` exhaustively (typically per-worker shadow blooms
    OR-reduced in parallel by the build sink). False
    negatives in the supplied bloom would silently corrupt probe
    results; the prefill MUST cover every key.

    Bloom insertion is 30-50% of the serial build wall on a 25M-key
    build (a 30 MB filter, random read-modify-writes into ~1M blocks,
    entirely cache-miss-bound); hoisting it out of the serial loop is
    what lets it run in parallel while chain insertion stays serial.

    Args:
        keys: The build-side join key column. Same row-order
            invariant as `build`.
        bloom: A BloomFilter pre-populated with every key in `keys`.
            Ownership is transferred.
        nobi: Chain-entry layout — elide `build_indices`. See `build`.
        fused: Chain-entry layout — interleave key/next. See `build`.

    Returns:
        A HashJoinBuilder wrapping the pre-built bloom.
    """
    var n = keys.length

    var min_cap = max(Int(Float64(n) * 1.4) + 1, 16)
    var cap = 1
    while cap < min_cap:
        cap *= 2

    var ht = List[Int]()
    ht.resize(cap, _CHAIN_END)

    # CHAIN-ENTRY LAYOUT. The disposition arrives as an argument, is fixed
    # for the life of the builder, and is carried on the returned value --
    # never re-read inside a loop, and never re-read by a probe.
    var build_keys = List[Int64](capacity=0 if fused else n)
    var build_indices = List[Int](capacity=0 if nobi else n)
    var next_chain = List[Int](capacity=0 if fused else n)
    var key_next = List[Int64](capacity=2 * n if fused else 0)

    var mask = UInt64(cap - 1)

    # NULL keys (see `hash_join_build`): a NULL build key is
    # recorded but NOT linked into a
    # bucket -> never a probe match target. The caller-prebuilt bloom may
    # carry the NULL's zero bits, but that only yields a probe-side false
    # positive (the chain walk finds nothing). `has_nulls` gates the consult.
    var has_nulls = keys.null_count != 0

    # Origin-tied view of the key buffer (`view_ro`), bitcast to Int64;
    # `key_view` keeps the buffer borrowed for the whole loop.
    var key_view = keys.view_ro()
    var key_ptr = key_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
    var ht_ptr = ht.unsafe_ptr()

    # PERF-CRITICAL: identical chain-insert loop to `build` minus the
    # `bloom.insert_int64(key)` line. Single-stage prefetch on the
    # HT slot remains; bloom block prefetch is now subsumed by the
    # parallel pre-pass.
    for i in range(n):
        if i + _PREFETCH_DISTANCE < n:
            var future_key = Int64((key_ptr + i + _PREFETCH_DISTANCE)[])
            var fh = _hash_join_key(future_key)
            var future_slot = Int(fh & mask)
            prefetch[params = PrefetchOptions().for_write().high_locality()](
                (ht_ptr + future_slot).bitcast[Scalar[DType.int64]]()
            )

        var key = Int64((key_ptr + i)[])
        var h = _hash_join_key(key)
        var slot = Int(h & mask)

        var old_head = (ht_ptr + slot)[]
        # `entry_idx` WAS `len(build_keys)`. It is `i`: the appends below run
        # unconditionally over `range(n)`, so the entry index and the build
        # row index have always been the same number. Spelling it `i` is what
        # makes the fused layout (where `build_keys` stays empty) expressible,
        # and it is the SAME identity the NOBI lever exploits one line down.
        var entry_idx = i

        if fused:
            # 16-byte record: [2i] = key, [2i + 1] = chain link.
            key_next.append(key)
            key_next.append(Int64(old_head))
        else:
            build_keys.append(key)
            next_chain.append(old_head)
        if not nobi:
            build_indices.append(i)

        # NULL build key recorded above but NOT linked -> never a
        # probe match target.
        if has_nulls and keys.is_null(i):
            continue

        (ht_ptr + slot)[] = entry_idx

    join_layout_record_build(
        "serial_bloom", nobi, fused, n, sched_trace_enabled()
    )
    # ---- BLOOML1, the SAME predicate, so `_use_bloom` has ONE decider ---
    #
    # IT CANNOT FIRE AT THE BUILD SINK'S THRESHOLDS AND IS HERE ANYWAY. The
    # sink takes this entry only for builds of at least 100,000 rows, where
    # the fused index is 2.65 MB, eighty times any L1d budget this lever can
    # be given. Stating the predicate in both
    # constructors costs one comparison per BUILD and means the invariant
    # holds if that threshold is ever lowered, instead of holding by an
    # argument written down in a different file.
    #
    # The caller has already paid for the prefill by the time we get here,
    # so a decline wastes that work rather than saving it. That is the
    # correct trade regardless: the prefill is paid ONCE, the probe-side
    # check would be paid per row.
    var pbl_budget = bloom_l1_budget_bytes()
    var pbl_bytes = bloom_l1_index_bytes(
        n, cap, JOIN_KN_WORDS, fused, nobi
    )
    var pbl_decline = bloom_l1_should_decline(pbl_bytes, pbl_budget)
    if pbl_decline:
        bloom_l1_note_declined(n)
    else:
        bloom_l1_note_kept()
    if bloom_l1_trace_enabled():
        bloom_l1_witness(n, pbl_bytes, pbl_budget, pbl_decline)
    return HashJoinBuilder(
        build_keys=build_keys^,
        build_indices=build_indices^,
        hash_table=ht^,
        next_chain=next_chain^,
        capacity=cap,
        bloom=bloom^,
        use_bloom=not pbl_decline,
        key_next=key_next^,
        num_build=n,
        bi_elided=nobi,
        fused=fused,
    )

def hash_join_build(
    keys: PrimitiveArray[DType.int64],
    build_bloom: Bool = True,
    nobi: Bool = True,
    fused: Bool = True,
    var pay_values: List[Int64] = List[Int64](),
    pay_build_col: Int = -1,
) raises -> HashJoinBuilder:
    """Build a hash join index from the build-side key column.

    Iterates all rows, hashing each key and inserting into the hash
    table with separate chaining. The capacity is sized to ~1.4x the
    number of rows (targeting 70% load factor) and rounded to the
    next power of 2 for bitwise masking.

    Args:
        keys: The build-side join key column.
        build_bloom: When True (default), populate the bloom filter
            inline during the chain-insert loop and use it for
            probe-side rejection. When False, skip the
            `bloom.insert_int64` work and store an empty bloom; the
            resulting builder has `_use_bloom=False` and probe-side
            `might_contain_int64` checks are bypassed. Set False when
            the probe consumes no dynamic filter: an unused large
            bloom build is a measurable share of a query's time.
            TRUE IS A REQUEST, NOT A GUARANTEE: when the BLOOML1 budget is
            set (`bloom_l1_configure`) and the resulting index is that
            small, this build takes the `False` arm anyway and returns
            `uses_bloom() == False`. Unset (the default), `True` means
            exactly what it says. See `join_bloom_l1_resident`.
        pay_values: PAYLOAD-INLINE. One Int64 per build
            row, written into the third word of each 32-byte chain entry so
            the probe's existing chain touch yields it and the downstream
            random gather out of build column `pay_build_col` is deleted.
            EMPTY (the default) selects the shipped 16-byte entry, so every
            existing caller is unchanged. WARNING: Its length must equal the key
            count; a short list is REFUSED rather than defaulting the tail
            rows' payload, which would be a wrong answer confined to the end
            of the build side and invisible to every row-count assertion.
        pay_build_col: The build-batch column `pay_values` copies. Carried
            on the builder so the probe operator's staged and deferred arms
            both learn which output column the entry now serves.
        nobi: CHAIN-ENTRY LAYOUT, the shipped default; tests pass False.
            True (the shipped state) omits `build_indices` entirely: it is
            never allocated, never written, and the probe emits `chain_idx`
            where it used to emit `build_indices[chain_idx]`. The
            substitution is exact, not approximate — `build_indices[i] == i`
            on every producer in this tree, so the array's only function was
            to return the number used to read it.
        fused: CHAIN-ENTRY LAYOUT, the shipped default; tests pass False.
            True (the shipped state) replaces the `build_keys` +
            `next_chain` pair with one interleaved 16-byte-record array, so
            a chain step touches one cache line where it used to touch two.

    WHY `nobi` / `fused` ARE ARGUMENTS. They are fixed per build and
    carried on the builder; the default is what every production caller
    gets, and the split layout survives as the ORACLE: the chain-layout
    byte-equivalence test drives both layouts over the same fixtures and
    compares the emitted match sets.

    The fused layout wins on large, random chain walks and loses a little on
    short, dense, cache-resident ones: a 16-byte record halves the build rows
    per cache line.

    Returns:
        A HashJoinBuilder ready for probe() calls.
    """
    var n = keys.length

    # Determine capacity: at least 1.4x rows, power of 2, minimum 16.
    var min_cap = max(Int(Float64(n) * 1.4) + 1, 16)
    var cap = 1
    while cap < min_cap:
        cap *= 2

    # PERF-CRITICAL: Bulk-fill hash table buckets to _CHAIN_END.
    # The scalar `for _ in range(cap): ht.append(...)` pattern bounds-checks
    # every append and does a capacity-grow check per call — at cap=1M+ on
    # a 700K-row build side, that's 1M branches before probe even starts.
    # `List.resize(cap, value)` allocates in one go and fills the slab.
    var ht = List[Int]()
    ht.resize(cap, _CHAIN_END)

    # PERF-CRITICAL: pre-size build_keys/build_indices/next_chain
    # at n capacity to avoid the 5-8 doubling reallocations (1, 2, 4, ..., n)
    # that `List.append` triggers when starting from capacity=0. On C-4 anti
    # (1M build rows) the reallocation series moves ~16MB of data multiple
    # times. Measured: HashJoinBuilder.build 30ms -> under 20ms.
    # ---- PAYLOAD-INLINE layout resolution, ONCE per build ---------------
    # `pay` is the disposition for the whole builder. It is resolved here
    # from the ARGUMENT the caller passed after consulting the gate, never
    # re-derived inside the loop and never re-read by a probe -- the same
    # contract `fused` and `nobi` have.
    var pay = fused and len(pay_values) > 0
    if len(pay_values) > 0:
        if not fused:
            raise Error(
                "hash_join_build: pay_values requires the fused"
                " chain-entry layout"
            )
        if len(pay_values) != n:
            raise Error(
                "hash_join_build: pay_values length "
                + String(len(pay_values))
                + " != build key count "
                + String(n)
            )
    var kn_words = JOIN_KN_WORDS_PAY if pay else JOIN_KN_WORDS

    # ---- BLOOML1: DECLINE THE BLOOM OVER AN L1-RESIDENT INDEX ----------
    #
    # DEFAULT-OFF. `join_bloom_l1_resident`
    # carries the whole argument; the two sentences that matter here:
    #
    #  * A bloom is a CACHE-MISS AVOIDANCE device. When the hash table and
    #    the chain entries both fit in L1, the bucket-head load a rejection
    #    would have skipped is ALREADY an L1 hit, so the bloom's own L1 load
    #    plus its block check cannot be cheaper than what it saves — AT ANY
    #    REJECTION RATE. `h2o/j1_join_small` is the extreme case: a 3,648 B
    #    index (2,048 B table + 1,600 B entries) consulted 6,000,000 times
    #    for 0 rejections.
    #  * DECLINING IS VALUE-INVARIANT. A bloom has no false negatives, so a
    #    row it would have rejected instead loads a bucket head and finds
    #    `_CHAIN_END` or walks a chain whose compares all fail. Identical
    #    pairs, identical order — which is exactly why the counters below
    #    are not optional.
    #
    # IT IS DECIDED HERE, NOT AT A DRIVER: every single-key driver reaches
    # this constructor, so one site covers all of them and the witness
    # cannot miss a route.
    var l1_budget = bloom_l1_budget_bytes()
    var l1_index_bytes = bloom_l1_index_bytes(
        n, cap, kn_words, fused, nobi
    )
    var l1_decline = bloom_l1_should_decline(l1_index_bytes, l1_budget)
    var use_bloom_eff = build_bloom and not l1_decline
    if build_bloom:
        # Notched ONLY on the arm that reached the predicate, so
        # `kept=0 declined=0` reads as "never reached" rather than "kept".
        if l1_decline:
            bloom_l1_note_declined(n)
        else:
            bloom_l1_note_kept()
        if bloom_l1_trace_enabled():
            bloom_l1_witness(n, l1_index_bytes, l1_budget, l1_decline)

    # CHAIN-ENTRY LAYOUT. Fixed by the arguments, per build. See
    # `build_with_bloom` for why `entry_idx` stops being `len(build_keys)`.
    var build_keys = List[Int64](capacity=0 if fused else n)
    var build_indices = List[Int](capacity=0 if nobi else n)
    var next_chain = List[Int](capacity=0 if fused else n)
    var key_next = List[Int64](capacity=kn_words * n if fused else 0)

    # Bloom filter sized for NDV=n with 1% false positive rate.
    # Minimum 256 bytes to avoid degenerate tiny filters.
    # THIS BUILDS THE BLOOM AT EVERY SIZE: `n` is not consulted, and the
    # whole INNER probe family consults the bloom at every build size. On a
    # small build that is a real cost (`tpch/q11`'s build is 396 rows /
    # 14.2 KB, L1-resident, and 78.2% of its join kernel was bloom plus
    # prefetch against 4.9% for the chain walk). DO NOT "FIX" IT BY
    # SKIPPING THE BUILD FOR SMALL `n`: not building the filter is not the
    # same decision as not CONSULTING it, and the probe would then trust
    # `_use_bloom == True` over an empty bloom. The decline that is safe is
    # BLOOML1 above, which clears `_use_bloom` with it.
    # When `build_bloom == False` (or BLOOML1 declined), skip
    # the bloom allocation entirely — the empty placeholder bloom
    # (`BloomFilter()`) holds zero bytes and the `_use_bloom` field
    # gates probe-side `might_contain_int64` calls so the bloom is
    # never consulted.
    #
    # BLOOML1: `use_bloom_eff`, not `build_bloom`. The
    # L1-resident decline takes exactly this arm — empty
    # placeholder filter, no inserts, `_use_bloom=False` on the returned
    # builder — so it adds no new state and no new probe-side path.
    var bloom: BloomFilter
    if use_bloom_eff:
        bloom = BloomFilter.with_ndv_fpp(
            max(n, 1), 0.01, _join_bloom_hash_family()
        )
    else:
        bloom = BloomFilter()

    var mask = UInt64(cap - 1)

    # NULL keys: a NULL build key is NEVER a match target
    # (SQL "NULL never matches"). It is recorded in build_keys/build_indices/
    # next_chain but
    # NOT linked into a hash bucket AND NOT bloom-inserted — so it is never
    # reachable from any probe chain walk. `has_nulls` gates the per-row
    # consult to keep the all-valid build byte-identical to an unguarded loop.
    var has_nulls = keys.null_count != 0

    # Direct pointer access avoids per-element bounds checks in the build loop.
    # Origin-tied view of the key buffer (`view_ro`), bitcast to Int64.
    # `key_view` keepalive holds the borrow through the build loop.
    var key_view = keys.view_ro()
    var key_ptr = key_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
    var ht_ptr = ht.unsafe_ptr()

    # PERF-CRITICAL: Build loop with pre-sized Lists and a
    # single-stage prefetch of the HT slot _PREFETCH_DISTANCE ahead.
    # For 1M-row builds the hash_table is ~8MB (cap = 2^21 * 8B), far
    # beyond L2. The ht[slot] read-modify-write on the chain-head is
    # random-access and the single biggest build-time cache-miss
    # source. Prefetching for-write hides the latency across the bloom
    # insert + list appends that follow (~30 cycles of useful work).
    # SAFETY: Prefetch is a hint; invalid addresses silently ignored.
    for i in range(n):
        # Prefetch the future HT slot we'll read-modify-write.
        if i + _PREFETCH_DISTANCE < n:
            var future_key = Int64((key_ptr + i + _PREFETCH_DISTANCE)[])
            var fh = _hash_join_key(future_key)
            var future_slot = Int(fh & mask)
            prefetch[params = PrefetchOptions().for_write().high_locality()](
                (ht_ptr + future_slot).bitcast[Scalar[DType.int64]]()
            )

        var key = Int64((key_ptr + i)[])
        var h = _hash_join_key(key)
        var slot = Int(h & mask)

        # LIFO chaining: new entry becomes the chain head.
        # Read-modify-write via raw pointer (avoids bounds checks).
        var old_head = (ht_ptr + slot)[]
        # See `build_with_bloom`: `entry_idx == i` by construction.
        var entry_idx = i

        if fused:
            key_next.append(key)
            key_next.append(Int64(old_head))
            if pay:
                # Word 2 is the payload; words 3.. are PAD, and the pad is
                # what keeps a record off a 64-byte line boundary.
                #
                # NOTE: THE PAD COUNT IS DERIVED FROM `kn_words`, NOT WRITTEN
                # OUT. A literal here would make the WRITE stride and the
                # READ stride (`_KNW` in the three probe kernels, also
                # `JOIN_KN_WORDS_PAY`) two independent facts that agree only
                # by coincidence: narrowing the constant to 3 words would
                # change every reader and leave the writer emitting 4, so the walk would read
                # entry i at offset 3i of a 4-wide array. Keys belonging to
                # other rows, with the layout constant looking correct in
                # both places.
                #
                # Every entry is written even for a NULL key -- which is
                # recorded here and skipped only from BUCKET LINKING below
                # -- so `kn_words * chain_idx` indexes every entry.
                key_next.append(pay_values[i])
                for _w in range(kn_words - 3):
                    key_next.append(Int64(0))
        else:
            build_keys.append(key)
            next_chain.append(old_head)
        if not nobi:
            build_indices.append(i)

        # NULL build key is recorded above but NOT linked into the bucket and NOT bloom-inserted ->
        # never a probe match target.
        if has_nulls and keys.is_null(i):
            continue

        # Insert key into bloom filter for fast probe-side rejection.
        # skipped when `build_bloom` is
        # False — driver-side wiring guarantees the bloom is unused
        # downstream (`_use_bloom` field on the resulting builder).
        # reuse the already-computed `h = _hash_join_key(key)`
        # when the bloom is FIBONACCI_JOIN (no re-hash); falls back to
        # `insert_int64(key)` when the kill-switch selected xxHash64.
        if use_bloom_eff:
            bloom.insert_join_key(key, h)

        # Update bucket to point to this new entry.
        (ht_ptr + slot)[] = entry_idx

    # NOTE: THE WRITE STRIDE AND THE READ STRIDE, RECONCILED ONCE PER BUILD.
    # O(1), off every hot path, and it is the only thing standing between a
    # layout-constant change and a probe walk that reads entry i at the
    # wrong offset -- which produces keys from other rows rather than a
    # crash. The pad is derived from `kn_words` for the same reason.
    if fused and len(key_next) != kn_words * n:
        raise Error(
            "hash_join_build: chain-entry array is "
            + String(len(key_next))
            + " words for "
            + String(n)
            + " rows at stride "
            + String(kn_words)
            + " -- the write stride and the read stride disagree"
        )
    join_layout_record_build(
        "serial", nobi, fused, n, sched_trace_enabled()
    )
    if pay:
        join_payload_inline_record_build(n, pay_build_col)
    return HashJoinBuilder(
        build_keys=build_keys^,
        build_indices=build_indices^,
        hash_table=ht^,
        next_chain=next_chain^,
        capacity=cap,
        bloom=bloom^,
        use_bloom=use_bloom_eff,
        key_next=key_next^,
        num_build=n,
        bi_elided=nobi,
        fused=fused,
        pay_inline=pay,
        pay_build_col=pay_build_col,
    )
