# =============================================================================
# join_probe_inner -- the INNER probes of `HashJoinBuilder`: append to the
# caller's lists (`probe_inner_into`), count (`count_inner_matches`), and the
# resumable chunked probe (`probe_inner_chunk`), the hot entry of a streaming
# inner join
# =============================================================================
#
# Each public entry is a DISPATCHER: it reads the layout the build resolved
# (`fused`, `nobi`, payload-inline) and calls a COMPTIME-specialised body once,
# so no layout branch runs inside a walk. The chunked probe also resolves the
# phase-split size gate (`join_probe_phase_split`) once per entry and takes the
# batched walk (`join_probe_inner_ps`) when it admits.
#
# A NULL probe key matches nothing. The bloom pre-check runs only when the
# builder kept its bloom (`uses_bloom()`).
# =============================================================================

from std.memory import UnsafePointer
from std.sys.intrinsics import prefetch, PrefetchOptions

from komira_arrow.primitive_array import PrimitiveArray
from komira_join_assembly.join_payload_inline import (
    JOIN_KN_WORDS,
    JOIN_KN_WORDS_PAY,
    join_payload_inline_record_probe,
)

from .join import (
    HashJoinBuilder,
    ProbeInnerState,
    _CHAIN_END,
    _PREFETCH_DISTANCE,
    _hash_join_key,
)
from .join_layout_counter import (
    join_layout_record_probe,
    join_layout_record_probe_hot,
)
from .join_probe_inner_ps import _probe_inner_chunk_ps
from .join_probe_phase_split import (
    join_phase_split_admits,
    join_phase_split_record,
)


def probe_inner_into(
    b: HashJoinBuilder,
    probe_keys: PrimitiveArray[DType.int64],
    mut build_matches: List[Int],
    mut probe_matches: List[Int],
) raises:
    """Inner join probe that appends to caller-provided output lists.

    ⚠ THIS IS THE FOUR-WAY LAYOUT DISPATCHER, NOT THE LOOP. It reads the two
    layout dispositions the BUILD resolved and calls the COMPTIME-specialised
    body once; the gates are never read here and never inside the walk. The
    `[False, False]` instantiation is the split-layout loop, which is what
    makes it a usable A/B control.

    See `_probe_inner_into` for the algorithm."""
    b._refuse_pay_inline("probe_inner_into")
    join_layout_record_probe(
        "probe_inner_into", b._bi_elided, b._fused
    )
    if b._fused:
        if b._bi_elided:
            _probe_inner_into[True, True](
                b, probe_keys, build_matches, probe_matches
            )
        else:
            _probe_inner_into[True, False](
                b, probe_keys, build_matches, probe_matches
            )
    else:
        if b._bi_elided:
            _probe_inner_into[False, True](
                b, probe_keys, build_matches, probe_matches
            )
        else:
            _probe_inner_into[False, False](
                b, probe_keys, build_matches, probe_matches
            )


def _probe_inner_into[
    fused: Bool, nobi: Bool
](
    b: HashJoinBuilder,
    probe_keys: PrimitiveArray[DType.int64],
    mut build_matches: List[Int],
    mut probe_matches: List[Int],
) raises:
    """Inner join probe that appends to caller-provided output lists.

    This is the preferred API for the hot path: Mojo's Tuple[List[Int],
    List[Int]] cannot have its fields partially moved out, so callers of
    the Tuple-returning `probe_inner` are forced to `.copy()` each
    element — a full 8*num_matches-byte memcpy per element. Passing
    the output lists in via `mut` eliminates that copy entirely:
    the caller allocates once and consumes via `^` move at its final
    site.

    See `probe_inner` for the algorithmic docstring. This method
    implements the same algorithm but appends to the caller's buffers
    instead of allocating and returning a tuple.

    Args:
        probe_keys: The probe-side join key column.
        build_matches: Output list for build-side row indices (appended).
        probe_matches: Output list for probe-side row indices (appended).
    """
    var n = probe_keys.length
    var mask = UInt64(b.capacity - 1)

    # NULL keys: a NULL probe key matches NOTHING. For
    # INNER, a NULL probe row produces no output. `probe_has_nulls` gates
    # the per-row consult to keep the all-valid probe byte-identical.
    var probe_has_nulls = probe_keys.null_count != 0

    # Direct pointer access avoids per-element bounds checks in the probe loop.
    # Origin-tied view of the key buffer (`view_ro`), bitcast to Int64.
    # `probe_key_view` keepalive holds the borrow through the probe loop.
    var probe_key_view = probe_keys.view_ro()
    var probe_key_ptr = probe_key_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()

    # SAFETY: Raw pointers for the entire probe loop. All four Lists
    # (hash_table, build_keys, build_indices, next_chain) are fields of
    # `self`, which is borrowed for the full duration of this method, so
    # the backing storage remains alive. The final `_ = b.<field>`
    # keepalives at the bottom prevent any premature destruction the AOT
    # compiler might otherwise insert. Replaces bounds-checked List[]
    # access in the chain walk with pointer arithmetic.
    var ht_ptr = b.hash_table.unsafe_ptr()
    var bk_ptr = b.build_keys.unsafe_ptr()
    var bi_ptr = b.build_indices.unsafe_ptr()
    var nc_ptr = b.next_chain.unsafe_ptr()
    # The fused 16-byte-record view. EMPTY (and never dereferenced) unless
    # `fused`; taking `.unsafe_ptr()` of an empty List is a load-free address
    # computation, and the `@parameter if` below deletes the untaken arm at
    # compile time, so no null is ever read.
    var kn_ptr = b.key_next.unsafe_ptr()

    # NOT-VECTORIZABLE: HJ probe — chain pointer traversal is data-dependent.
    # Software prefetch already applied for latency hiding.
    for probe_idx in range(n):
        # Two-stage software prefetch :
        #
        # Stage 1 (full distance): prefetch hash table bucket for a
        # future probe key.
        if probe_idx + _PREFETCH_DISTANCE < n:
            var future_key = Int64((probe_key_ptr + probe_idx + _PREFETCH_DISTANCE)[])
            var fh = _hash_join_key(future_key)
            var future_slot = Int(fh & mask)
            # SAFETY: Prefetch is a hint -- invalid addresses silently ignored.
            prefetch[params = PrefetchOptions().for_read().high_locality()](
                (ht_ptr + future_slot).bitcast[Scalar[DType.int64]]()
            )

        # Stage 2 (half distance): the hash table bucket should be in L1
        # by now (from stage 1). Prefetch the build_keys entry it points to.
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
                        (bk_ptr + mid_chain).bitcast[Scalar[DType.int64]]()
                    )

        var probe_key = Int64((probe_key_ptr + probe_idx)[])

        # A NULL probe key matches nothing -> no INNER output.
        if probe_has_nulls and probe_keys.is_null(probe_idx):
            continue

        # Bloom filter pre-check: skip hash table walk if key is
        # definitely not in the build side. False positives are OK
        # (we just fall through to the chain walk), false negatives
        # are impossible (correctness is preserved).
        # Bypass when the builder kept no bloom: the placeholder bloom holds
        # ZERO blocks over a NULL buffer, and a bloom call on it reads 32
        # bytes through that null pointer. See the `_use_bloom` field.
        # compute the HT hash first, then reuse it for the
        # bloom pre-check via `might_contain_join_key` (one hash for both).
        var h = _hash_join_key(probe_key)
        if b._use_bloom and not b.bloom.might_contain_join_key(
            probe_key, h
        ):
            continue

        var slot = Int(h & mask)

        # Walk the chain at this bucket using raw pointer arithmetic.
        var chain_idx = (ht_ptr + slot)[]
        while chain_idx != _CHAIN_END:
            # ⚠ THE LOAD ORDER IS PRESERVED EXACTLY. The chain link is read
            # AFTER the key compare, as it always was -- reading it first
            # would overlap the two loads and change the control arm, which
            # is precisely the confound this specialisation exists to avoid.
            var chain_key: Int64
            comptime if fused:
                chain_key = (kn_ptr + 2 * chain_idx)[]
            else:
                chain_key = (bk_ptr + chain_idx)[]
            if chain_key == probe_key:
                # Match found: emit the pair using original row indices.
                comptime if nobi:
                    # `build_indices[chain_idx] == chain_idx`, always.
                    build_matches.append(chain_idx)
                else:
                    build_matches.append((bi_ptr + chain_idx)[])
                probe_matches.append(probe_idx)
            comptime if fused:
                chain_idx = Int((kn_ptr + 2 * chain_idx + 1)[])
            else:
                chain_idx = (nc_ptr + chain_idx)[]

    # Keepalive: prevent premature destruction of self's fields whose
    # raw pointers were extracted above.
    _ = b.hash_table
    _ = b.build_keys
    _ = b.build_indices
    _ = b.next_chain
    _ = b.key_next


def probe_inner(b: HashJoinBuilder, probe_keys: PrimitiveArray[DType.int64]) raises -> Tuple[List[Int], List[Int]]:
    """Inner join probe: find all matching (build, probe) index pairs.

    Tuple-returning public API (preserved for existing tests). Hot-path
    callers in the engine use `probe_inner_into` directly to skip the
    `Tuple[List[Int], List[Int]]` packing/unpacking (which forces a
    `.copy()` on every element because Mojo's tuple fields cannot be
    partial-moved).

    Args:
        probe_keys: The probe-side join key column.

    Returns:
        A tuple of (build_indices, probe_indices) where each position
        represents one matching pair. Both lists have the same length.
    """
    # Pre-allocate: for 1:1 joins, output ~= min(probe, build). For many-to-many,
    # this is a lower bound that still eliminates the initial 19 doublings from 0.
    var est = min(probe_keys.length, b.num_build)
    var build_matches = List[Int](capacity=est)
    var probe_matches = List[Int](capacity=est)
    probe_inner_into(b, probe_keys, build_matches, probe_matches)
    return (build_matches^, probe_matches^)


@always_inline
def avg_chain_length(b: HashJoinBuilder) -> Int:
    """Estimate average matches per probe key from build-side HT stats.

    Computes build_rows / non_empty_buckets. For many-to-many joins (e.g.
    J2: 10K build, 100 unique keys -> avg 100 matches per key), this is
    the expected fan-out per matching probe row.

    PERF-CRITICAL: Used by join dispatch to route high fan-out joins
    to the chunked path instead of the parallel path. The parallel path
    builds N_probe * fan_out intermediate List[Int] entries; for J2
    (6M * 100 = 600M entries) that's 9.6GB of allocation + gather.
    The chunked path fuses probe+gather in 64K chunks, avoiding this.

    COST: THIS IS O(CAPACITY), SERIAL, NOT O(build_rows). The loop below touches every hash-table SLOT, and capacity
    is 1.4 * build_rows rounded UP to a power of two, so just past a
    boundary it is ~2.8x the build row count. At a 25M-row build that is
    2^26 = 67,108,864 slots over a 512 MiB array, read single-threaded on
    the calling thread, to produce one integer. It is cheap relative to a
    large probe and it is not free, and it scales with the BUILD side —
    which is the side that is supposed to be the small one.

    The bounded version would be a non-empty-bucket count maintained by the
    build.

    Returns:
        Average chain length (>= 1). Returns 1 if the HT is empty.
    """
    var num_build = b.num_build
    if num_build == 0:
        return 1
    var non_empty = 0
    # SAFETY: hash_table is borrowed for this method's duration.
    var ht_ptr = b.hash_table.unsafe_ptr()
    for b in range(b.capacity):
        if (ht_ptr + b)[] != _CHAIN_END:
            non_empty += 1
    _ = b.hash_table  # keepalive
    if non_empty == 0:
        return 1
    return max(num_build // non_empty, 1)


def count_inner_matches(b: HashJoinBuilder, probe_keys: PrimitiveArray[DType.int64]) raises -> Int:
    """Count total matching pairs without materializing indices.

    Walks the same probe logic as probe_inner but only increments a
    counter. Used to pre-allocate output buffers for chunked assembly.

    Args:
        probe_keys: The probe-side join key column.

    Returns:
        Total number of (build, probe) match pairs.
    """
    join_layout_record_probe(
        "count_inner_matches", b._bi_elided, b._fused
    )
    var total = 0
    var mask = UInt64(b.capacity - 1)
    var n = probe_keys.length
    # NULL probe key matches nothing — mirror probe_inner's skip so the
    # pre-allocation count stays consistent with the emitted pairs.
    var probe_has_nulls = probe_keys.null_count != 0
    # Origin-tied view of the key buffer (`view_ro`), bitcast to Int64.
    # `probe_key_view` keepalive holds the borrow through the probe body.
    var probe_key_view = probe_keys.view_ro()
    var probe_key_ptr = probe_key_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()

    for probe_idx in range(n):
        var probe_key = Int64((probe_key_ptr + probe_idx)[])

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

        var chain_idx = b.hash_table[slot]
        while chain_idx != _CHAIN_END:
            # Layout-tolerant, RUNTIME-branched: this walk was already
            # bounds-checked `List` indexing, so a field test per step is not
            # a new class of cost here. The hot inner probe uses the comptime
            # body instead -- see `build_row_at`'s block comment.
            if b.chain_key_at(chain_idx) == probe_key:
                total += 1
            chain_idx = b.chain_next_at(chain_idx)

    return total


def probe_inner_start(b: HashJoinBuilder) -> ProbeInnerState:
    """Create a cursor for chunked inner join probing.

    Returns a ProbeInnerState that can be passed to probe_inner_chunk()
    repeatedly until all matches are emitted.

    Returns:
        A new ProbeInnerState positioned at the start of the probe.
    """
    return ProbeInnerState()


def probe_inner_chunk[
    o_build: Origin[mut=True],
    o_probe: Origin[mut=True],
    o_pay: Origin[mut=True],
](
    b: HashJoinBuilder,
    probe_keys: PrimitiveArray[DType.int64],
    mut state: ProbeInnerState,
    build_buf: Span[Int, o_build],
    probe_buf: Span[Int, o_probe],
    pay_buf: Span[Int64, o_pay],
    chunk_capacity: Int,
) raises -> Int:
    """Six-way chain-entry-layout dispatcher for the chunked inner probe.

    Reads the two dispositions the BUILD resolved and calls the
    COMPTIME-specialised body; no gate is read here and none inside the walk.
    THIS IS THE HOT ENTRY of a streaming inner join: the join probe operator
    calls it once per probe morsel, so a lever landed on `probe_inner_into`
    alone does not reach the fused scan-and-probe route.

    The three buffers are caller-owned spans of at least `chunk_capacity`
    entries (`pay_buf` only when the index carries an inlined payload);
    a shorter span is refused rather than written past.

    ⛔ `pay_buf` IS REQUIRED, NOT DEFAULTED, AND THAT IS THE POINT. A
    defaulted buffer would let a caller probe a PAYLOAD-INLINE index without
    anywhere to put the payload, and the only two things that code could
    then do are refuse at run time or silently drop a column. Making it a
    parameter moves the check to the compiler: every caller must have
    decided. A caller that knows the index is unarmed passes a one-element
    dummy span, which the `pay=False` instantiation never dereferences.

    ⚠ THE FIRING MARKER IS HERE AND NOT ON `probe_inner_start`, WHICH WOULD
    HAVE BEEN THE TIDIER PLACE AND WOULD HAVE FIRED ON NOTHING: the live
    chunked driver constructs `ProbeInnerState()` directly and never calls
    `probe_inner_start`, so a marker there is a marker on a method with no
    production caller. It uses the LATCHING recorder because this entry runs
    ~50,000 times per large query; see `join_layout_record_probe_hot` for why
    an unconditional counter here would have been charged to the treatment
    arm as several ms of instrumentation."""
    if len(build_buf) < chunk_capacity or len(probe_buf) < chunk_capacity:
        raise Error(
            "probe_inner_chunk: the build and probe buffers must hold"
            " chunk_capacity entries"
        )
    if b._pay_inline and len(pay_buf) < chunk_capacity:
        raise Error(
            "probe_inner_chunk: this index carries an inlined payload; the"
            " payload buffer must hold chunk_capacity entries"
        )
    # SAFETY: the spans are caller-owned and outlive this call; each kernel
    # writes at most `chunk_capacity` entries through them (checked above).
    var build_ptr = build_buf.unsafe_ptr()
    var probe_ptr = probe_buf.unsafe_ptr()
    var pay_ptr = pay_buf.unsafe_ptr()
    join_layout_record_probe_hot(
        "probe_inner_chunk", b._bi_elided, b._fused
    )

    # ---- THE PHASE-SPLIT SIZE GATE -----------------------------------
    # Resolved HERE, at the dispatcher, once per entry -- never inside a
    # walk. `join_phase_split_admits` reads a process-global setting; it
    # does not touch the environment.
    # See `join_probe_phase_split.mojo` for why the threshold is in BYTES
    # OF INDEX and why declining is the safe direction.
    var ps = join_phase_split_admits(
        b.num_build,
        b.capacity,
        b._fused,
        probe_keys.length,
        chunk_capacity,
        b._pay_inline,
    )
    join_phase_split_record(ps)
    # ---- PAYLOAD-INLINE. Only ever paired with `fused`: the constructor
    # REFUSES `pay_inline` without it, so the two `pay=True` arms below are
    # the complete set and there is no `[False, *, True]` instantiation to
    # write. The extra dimension costs two instantiations per walk, not
    # four.
    if ps:
        if b._fused:
            if b._pay_inline:
                if b._bi_elided:
                    return _probe_inner_chunk_ps[True, True, True](
                        b, probe_keys, state, build_ptr, probe_ptr, pay_ptr,
                        chunk_capacity
                    )
                return _probe_inner_chunk_ps[True, False, True](
                    b, probe_keys, state, build_ptr, probe_ptr, pay_ptr,
                    chunk_capacity
                )
            if b._bi_elided:
                return _probe_inner_chunk_ps[True, True, False](
                    b, probe_keys, state, build_ptr, probe_ptr, pay_ptr,
                    chunk_capacity
                )
            return _probe_inner_chunk_ps[True, False, False](
                b, probe_keys, state, build_ptr, probe_ptr, pay_ptr,
                chunk_capacity
            )
        if b._bi_elided:
            return _probe_inner_chunk_ps[False, True, False](
                b, probe_keys, state, build_ptr, probe_ptr, pay_ptr,
                chunk_capacity
            )
        return _probe_inner_chunk_ps[False, False, False](
            b, probe_keys, state, build_ptr, probe_ptr, pay_ptr, chunk_capacity
        )

    if b._fused:
        if b._pay_inline:
            if b._bi_elided:
                return _probe_inner_chunk[True, True, True](
                    b, probe_keys, state, build_ptr, probe_ptr, pay_ptr,
                    chunk_capacity
                )
            return _probe_inner_chunk[True, False, True](
                b, probe_keys, state, build_ptr, probe_ptr, pay_ptr,
                chunk_capacity
            )
        if b._bi_elided:
            return _probe_inner_chunk[True, True, False](
                b, probe_keys, state, build_ptr, probe_ptr, pay_ptr,
                chunk_capacity
            )
        return _probe_inner_chunk[True, False, False](
            b, probe_keys, state, build_ptr, probe_ptr, pay_ptr, chunk_capacity
        )
    if b._bi_elided:
        return _probe_inner_chunk[False, True, False](
            b, probe_keys, state, build_ptr, probe_ptr, pay_ptr, chunk_capacity
        )
    return _probe_inner_chunk[False, False, False](
        b, probe_keys, state, build_ptr, probe_ptr, pay_ptr, chunk_capacity
    )


def _probe_inner_chunk[
    fused: Bool,
    nobi: Bool,
    pay: Bool,
    o_build: Origin[mut=True],
    o_probe: Origin[mut=True],
    o_pay: Origin[mut=True],
](
    b: HashJoinBuilder,
    probe_keys: PrimitiveArray[DType.int64],
    mut state: ProbeInnerState,
    build_buf: UnsafePointer[Int, o_build],
    probe_buf: UnsafePointer[Int, o_probe],
    pay_buf: UnsafePointer[Int64, o_pay],
    chunk_capacity: Int,
) raises -> Int:
    """Emit the next chunk of inner join matches into caller-owned buffers.

    Resumes from where the previous call left off (tracked by state).
    Fills build_buf and probe_buf with up to chunk_capacity match pairs.
    Returns the number of pairs emitted (0 when done).

    This avoids allocating 800MB+ of List[Int] for many-to-many joins.
    Instead, the caller provides small fixed buffers (e.g. 65536 entries)
    and processes each chunk before requesting the next.

    PERF-CRITICAL:
        The chain walk runs on raw pointers hoisted from the builder's lists,
        as `probe_inner_into` does: bounds-checked `List` indexing costs four
        checks per match (~24M on a 6M-probe join), and the same two-stage
        software prefetch.

    Args:
        probe_keys: The probe-side join key column.
        state: Mutable cursor tracking probe position and chain position.
        build_buf: Caller-owned buffer for build-side indices.
        probe_buf: Caller-owned buffer for probe-side indices.
        pay_buf: PAYLOAD-INLINE. Receives, for each emitted pair, the build
            payload word carried IN the chain entry the walk just compared.
            Written ONLY when `pay`; on every other instantiation the
            parameter is dead and the caller may pass a one-element dummy.
            ★ This is the whole lever: the value comes off a line the probe
            has already loaded, so the downstream random gather out of the
            build column is DELETED, not moved somewhere else.
        chunk_capacity: Maximum number of pairs to emit.

    Returns:
        Number of pairs written to build_buf/probe_buf. 0 means done.
    """
    if state.done:
        return 0

    # PAYLOAD-INLINE stride, COMPTIME. `pay` is a PARAMETER and not a field
    # read precisely so the default instantiation compiles to byte-for-byte
    # the pre-lever loop: the A/B must not measure a branch this lever added
    # to the arm it is being compared against.
    comptime _KNW = JOIN_KN_WORDS_PAY if pay else JOIN_KN_WORDS

    comptime if pay:
        join_payload_inline_record_probe()

    var count = 0
    var mask = UInt64(b.capacity - 1)
    var n = probe_keys.length
    # NULL probe key matches nothing -> no INNER output (chunked path).
    var probe_has_nulls = probe_keys.null_count != 0
    # Origin-tied view of the key buffer (`view_ro`), bitcast to Int64.
    # `probe_key_view` keepalive holds the borrow through the probe body.
    var probe_key_view = probe_keys.view_ro()
    var probe_key_ptr = probe_key_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()

    # SAFETY: raw pointers for the chain walk. All four Lists are fields
    # of `self`, which is borrowed for the full duration of this method.
    # The final `_ = b.<field>` keepalives guard against AOT destructor
    # reordering. Mirror of `probe_inner_into`'s pointer hoist.
    var ht_ptr = b.hash_table.unsafe_ptr()
    var bk_ptr = b.build_keys.unsafe_ptr()
    var bi_ptr = b.build_indices.unsafe_ptr()
    var nc_ptr = b.next_chain.unsafe_ptr()
    # Fused 16-byte-record view; empty and never dereferenced unless `fused`.
    var kn_ptr = b.key_next.unsafe_ptr()

    # Resume from saved position
    var probe_idx = state.probe_pos
    var chain_idx = state.chain_pos

    while probe_idx < n:
        var probe_key = Int64((probe_key_ptr + probe_idx)[])

        # If resuming mid-chain, skip the bloom check, hash lookup,
        # and prefetch.
        if chain_idx == _CHAIN_END:
            # Two-stage software prefetch (same schedule as
            # `probe_inner_into`). Only issued for fresh probe rows
            # to avoid double-prefetch on mid-chain resumes.
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
                            (kn_ptr + _KNW * mid_chain).bitcast[Scalar[DType.int64]]()
                        )
                    else:
                        prefetch[params = PrefetchOptions().for_read().high_locality()](
                            (bk_ptr + mid_chain).bitcast[Scalar[DType.int64]]()
                        )

            # A NULL probe key matches nothing -> skip this row.
            if probe_has_nulls and probe_keys.is_null(probe_idx):
                probe_idx += 1
                continue

            # New probe row: bloom filter pre-check.
            # bypass empty-bloom builders.
            # reuse the HT hash for the bloom pre-check.
            var h = _hash_join_key(probe_key)
            if b._use_bloom and not b.bloom.might_contain_join_key(
                probe_key, h
            ):
                probe_idx += 1
                continue

            var slot = Int(h & mask)
            chain_idx = (ht_ptr + slot)[]

        # Walk the chain from current position via raw pointer arithmetic.
        while chain_idx != _CHAIN_END:
            var chain_key: Int64
            comptime if fused:
                chain_key = (kn_ptr + _KNW * chain_idx)[]
            else:
                chain_key = (bk_ptr + chain_idx)[]
            if chain_key == probe_key:
                comptime if nobi:
                    (build_buf + count)[] = chain_idx
                else:
                    (build_buf + count)[] = (bi_ptr + chain_idx)[]
                (probe_buf + count)[] = probe_idx
                # ★ THE LEVER. Word 2 of the entry whose word 0 was just
                # compared -- the SAME 32-byte record, the same cache line,
                # already resident. No second address is computed and no
                # second array is touched.
                comptime if pay:
                    (pay_buf + count)[] = (kn_ptr + _KNW * chain_idx + 2)[]
                count += 1

                if count >= chunk_capacity:
                    # Buffer full: save position for next call.
                    # Advance chain past the match we just emitted.
                    var next: Int
                    comptime if fused:
                        next = Int((kn_ptr + _KNW * chain_idx + 1)[])
                    else:
                        next = (nc_ptr + chain_idx)[]
                    if next == _CHAIN_END:
                        # Chain exhausted for this probe row. Move to
                        # the next probe row on resume so we don't
                        # re-hash and re-walk the same chain.
                        state.probe_pos = probe_idx + 1
                        state.chain_pos = _CHAIN_END
                    else:
                        # More chain entries remain for this probe row.
                        state.probe_pos = probe_idx
                        state.chain_pos = next
                    # Keepalives before early return.
                    _ = b.hash_table
                    _ = b.build_keys
                    _ = b.build_indices
                    _ = b.next_chain
                    _ = b.key_next
                    return count

            comptime if fused:
                chain_idx = Int((kn_ptr + _KNW * chain_idx + 1)[])
            else:
                chain_idx = (nc_ptr + chain_idx)[]

        # Finished this probe row, move to next
        probe_idx += 1
        chain_idx = _CHAIN_END

    # All probe rows exhausted
    state.done = True

    # Keepalives: prevent premature destruction of self's fields whose
    # raw pointers were extracted above.
    _ = b.hash_table
    _ = b.build_keys
    _ = b.build_indices
    _ = b.next_chain
    _ = b.key_next
    return count
