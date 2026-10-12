# =============================================================================
# join_probe_inner_ps -- the PHASE-SPLIT chunked inner probe (B probe rows
# walked one chain step at a time, so their cache misses overlap) and the
# row-at-a-time walk it falls back to for one row
# =============================================================================
#
# Reached from `join_probe_inner.probe_inner_chunk` when
# `join_probe_phase_split.join_phase_split_admits` says the index is large
# enough for the memory-level parallelism to pay. Answer-identical to the
# row-at-a-time chunked probe, INCLUDING THE ORDER of the emitted pairs.
# =============================================================================

from std.memory import UnsafePointer
from std.sys.intrinsics import prefetch, PrefetchOptions

from komira_arrow.primitive_array import PrimitiveArray
from komira_join_assembly.join_payload_inline import (
    JOIN_KN_WORDS,
    JOIN_KN_WORDS_PAY,
    join_payload_inline_record_probe,
)

from .join import HashJoinBuilder, ProbeInnerState, _CHAIN_END, _hash_join_key
from .join_probe_phase_split import (
    JOIN_PS_BATCH,
    JOIN_PS_MATCH_CAP,
    JOIN_PS_MIN_HEADROOM,
)


@always_inline
def _probe_row_walk[
    fused: Bool,
    nobi: Bool,
    pay: Bool,
    o_build: Origin[mut=True],
    o_probe: Origin[mut=True],
    o_pay: Origin[mut=True],
](
    b: HashJoinBuilder,
    probe_keys: PrimitiveArray[DType.int64],
    probe_idx: Int,
    start_chain: Int,
    build_buf: UnsafePointer[Int, o_build],
    probe_buf: UnsafePointer[Int, o_probe],
    pay_buf: UnsafePointer[Int64, o_pay],
    chunk_capacity: Int,
    mut count: Int,
    mut state: ProbeInnerState,
) raises -> Bool:
    """Walk ONE probe row's chain row-at-a-time, emitting every match.

    The incumbent `_probe_inner_chunk` body, narrowed to a single row. It is
    NOT a duplicate of that loop kept "just in case" -- the phase-split walk
    needs it at two points where batching is either impossible or unable to
    make progress, and both are correctness paths:

      * RESUME MID-CHAIN. `state.chain_pos != _CHAIN_END` means the previous
        call stopped part-way through a row's chain. A batch cannot start on
        a half-walked row without either re-emitting its earlier matches or
        carrying that row's cursor as a special case through every phase.
        One row is finished here; the batch then always begins on a fresh
        one.
      * NO ROW COMPLETED. When a batch's match buffer or the caller's chunk
        fills before the FIRST probe row of the batch has finished its chain,
        the batch has nothing it may emit (see `_probe_inner_chunk_ps` on
        `s_stop`), and re-running it would loop forever. That row is walked
        here instead, which is unbounded in chain length and honours
        `chunk_capacity`, so progress is guaranteed.

    `start_chain == _CHAIN_END` means "fresh row": do the NULL and bloom
    checks and read the directory. Otherwise resume the walk at that chain
    entry -- the incumbent's contract for `state.chain_pos`.

    ⚠ IT CARRIES THE PAYLOAD TOO, AND IT HAS TO. This is not a fallback
    that "only runs rarely" -- it is the path a RESUMED mid-chain row and a
    first-row-of-batch-did-not-complete row take, and both emit real output
    pairs. A version of this loop that skipped `pay_buf` would leave those
    rows' payload words UNWRITTEN in a buffer the assemble then copies
    verbatim: a wrong answer in one column, on a fraction of rows that
    depends on chunk boundaries, with the row count exactly right.

    Returns True iff the caller's buffer FILLED, in which case `state` has
    been positioned by the same rule the incumbent uses and the caller must
    return `count` immediately.
    """
    # Same COMPTIME stride, same reason, as `_probe_inner_chunk`.
    comptime _KNW = JOIN_KN_WORDS_PAY if pay else JOIN_KN_WORDS
    # SAFETY: raw pointers for the chain walk. All five Lists are fields of
    # `self`, borrowed for the full duration of this method, and the
    # keepalives below guard against AOT destructor reordering. Identical
    # hoist to `_probe_inner_chunk`; CSE'd into the caller's own hoist
    # because this is `@always_inline`.
    var mask = UInt64(b.capacity - 1)
    var probe_key_view = probe_keys.view_ro()
    var probe_key_ptr = probe_key_view._unsafe_ptr().bitcast[
        Scalar[DType.int64]
    ]()
    var ht_ptr = b.hash_table.unsafe_ptr()
    var bk_ptr = b.build_keys.unsafe_ptr()
    var bi_ptr = b.build_indices.unsafe_ptr()
    var nc_ptr = b.next_chain.unsafe_ptr()
    var kn_ptr = b.key_next.unsafe_ptr()

    var probe_key = Int64((probe_key_ptr + probe_idx)[])
    var chain_idx = start_chain

    if chain_idx == _CHAIN_END:
        # A NULL probe key matches nothing -> no INNER output.
        if probe_keys.null_count != 0 and probe_keys.is_null(probe_idx):
            _ = probe_key_view
            return False
        # reuse the HT hash for the bloom pre-check.
        var h = _hash_join_key(probe_key)
        if b._use_bloom and not b.bloom.might_contain_join_key(
            probe_key, h
        ):
            _ = probe_key_view
            return False
        chain_idx = (ht_ptr + Int(h & mask))[]

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
            comptime if pay:
                (pay_buf + count)[] = (kn_ptr + _KNW * chain_idx + 2)[]
            count += 1

            if count >= chunk_capacity:
                var nxt: Int
                comptime if fused:
                    nxt = Int((kn_ptr + _KNW * chain_idx + 1)[])
                else:
                    nxt = (nc_ptr + chain_idx)[]
                if nxt == _CHAIN_END:
                    state.probe_pos = probe_idx + 1
                    state.chain_pos = _CHAIN_END
                else:
                    state.probe_pos = probe_idx
                    state.chain_pos = nxt
                _ = b.hash_table
                _ = b.build_keys
                _ = b.build_indices
                _ = b.next_chain
                _ = b.key_next
                _ = probe_key_view
                return True

        comptime if fused:
            chain_idx = Int((kn_ptr + _KNW * chain_idx + 1)[])
        else:
            chain_idx = (nc_ptr + chain_idx)[]

    _ = b.hash_table
    _ = b.build_keys
    _ = b.build_indices
    _ = b.next_chain
    _ = b.key_next
    _ = probe_key_view
    return False


def _probe_inner_chunk_ps[
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
    """PHASE-SPLIT chunked inner probe -- the memory-level-parallelism arm.

    Answer-identical to `_probe_inner_chunk`, INCLUDING THE ORDER OF THE
    EMITTED PAIRS, and reached only when `join_phase_split_admits` says the
    join is big enough for the lever to be worth its instructions.

    ## THE MECHANISM

    The incumbent walks one probe row's chain to exhaustion before touching
    the next, so chain entry k+1's ADDRESS comes out of entry k's cache
    line: every miss is serialised against every other miss and the CPU has
    nothing outstanding to hide it behind. Here B probe rows are advanced
    together, one chain STEP at a time:

      PHASE 0a  hash + slot for all B rows, prefetch the directory line.
                Pure ALU; no dependent load anywhere in the loop.
      PHASE 0b  B INDEPENDENT directory loads. Rows that are NULL, that the
                bloom rejects, or whose bucket is empty drop out here, and
                the survivors are COMPACTED IN PLACE (`na <= j` at every
                step, so the compaction never overwrites an unread slot).
      PHASE 1   `na` INDEPENDENT chain-record loads -- the k-th step of `na`
                DIFFERENT rows, which is the whole lever.
      PHASE 2   compare, record the match, compact the still-walking rows,
                and prefetch each survivor's NEXT record. Loop to PHASE 1.

    Measured on real hardware BEFORE this was written: offcore requests
    outstanding roughly doubles, load stalls fall from 63.6% to 13.4% of
    cycles, and LLC-load-misses per row is UNCHANGED. It moves the same
    bytes and wins on latency alone -- which is exactly why it needs the
    size gate, and why the DENSE selection vector below (a two-level
    `d_cur[t] -> record` gather) is the shape that was measured rather than
    the sparse `act[t] -> cur[act[t]] -> record` one, which spilled ~6
    pointer reloads per visit.

    ## ★ WHY THE PAIRS COME OUT IN THE INCUMBENT'S ORDER, WHICH IS NOT FREE

    The phases emit ROUND-MAJOR: all of round 0's matches (one per active
    row, in row order), then round 1's, and so on. The incumbent emits
    ROW-MAJOR: every match of row r, in chain order, before any match of row
    r+1. Those are the two traversals of the same (row, chain-step) grid and
    they are NOT the same sequence whenever any probe row has more than one
    match.

    Matches are therefore buffered for the batch and re-emitted through a
    STABLE COUNTING SORT on the batch-relative row slot. Because the active
    set stays in increasing slot order through every compaction, a stable
    sort by slot reproduces chain order within each row exactly. The cost is
    two streaming passes over the batch's matches plus a `s_stop`-entry
    histogram -- a few operations per row against the ~116 the walk already
    spends, and this arm is latency-bound, not instruction-bound.

    ⚠ THE ALTERNATIVE WAS CONSIDERED AND REJECTED ON EVIDENCE, NOT TASTE.
    Emitting round-major would have been free, and hc4's output row order is
    already nondeterministic run-to-run, so hc4 itself could not tell. But
    `h2o/j1..j4` ARE order-deterministic, the corpus
    value gate compares order-independent per-column signatures and so
    cannot see an order change AT ALL, and preserving order is what lets the
    differential test below assert POSITION BY POSITION against the
    incumbent instead of comparing multisets. A weaker oracle was not worth
    the few operations per row.

    ## ★ RESUMABILITY IS NOT MADE COARSER -- THE STATE IS STILL O(1)

    The lever could have pushed `ProbeInnerState` from O(1) to O(B) (the
    selection vector plus each live row's cursor, key and row). It does not,
    and `ProbeInnerState` is
    UNCHANGED. Three properties together buy that back:

      1. A batch only ever emits pairs for probe rows that have COMPLETED
         their entire chain (`s_stop`, below), so after every emission the
         cursor is exactly "row r, fresh" -- an incumbent-shaped position.
      2. A row that stops mid-chain because the caller's buffer filled is
         walked by `_probe_row_walk`, which saves the incumbent's own
         `(probe_pos, chain_pos)` pair.
      3. When the caller's buffer is too full to start another batch the
         kernel returns a SHORT CHUNK rather than half a batch. The driver
         already loops on `count`, so a short chunk costs one extra round
         trip and nothing else.

    The price is re-walking, on the next call, the rows of a truncated batch
    that had already completed. It is bounded by one batch (256 rows) per
    cut, and a cut happens at most once per `chunk_capacity` (65536) pairs:
    under 0.4% of the walk, paid only at chunk boundaries.

    Args:
        probe_keys: The probe-side join key column.
        state: Mutable cursor tracking probe position and chain position.
        build_buf: Caller-owned buffer for build-side indices.
        probe_buf: Caller-owned buffer for probe-side indices.
        pay_buf: PAYLOAD-INLINE. See `_probe_inner_chunk`. Written ONLY
            when `pay`.
        chunk_capacity: Maximum number of pairs to emit.

    Returns:
        Number of pairs written to build_buf/probe_buf. 0 means done.
    """
    if state.done:
        return 0

    # ---- PAYLOAD-INLINE, COMPTIME. Same parameterisation, same reason, as
    # `_probe_inner_chunk`: the default instantiation must be byte-for-byte
    # the pre-lever kernel.
    #
    # ★ THE O(1) RESUME CONTRACT IS UNTOUCHED, AND THAT IS NOT AN ACCIDENT
    # OF THIS EDIT. `ProbeInnerState` gains no field. The payload rides in
    # the batch's SCRATCH (`g_pay`, `m_pay`) and is emitted through the SAME
    # counting sort, at the SAME index `count + p`, as the build index it
    # accompanies -- so a payload word is never in flight across a call
    # boundary. Every resume rule above ("a batch only emits rows that
    # COMPLETED their chain", "a truncated row is walked by
    # `_probe_row_walk`", "a full buffer returns a SHORT CHUNK") holds
    # verbatim, and `_probe_row_walk` carries the payload for exactly the
    # rows it is responsible for.
    #
    # ⚠ L1 BUDGET, because this arm's whole win is latency and the constant
    # above was chosen against a measured 32 KiB ceiling. The round loop's
    # HOT set was `d_key + d_cur + d_slot + g_key + g_next` = 5 x 256 x 8 B
    # = 10 KiB, plus 16 KiB of prefetched chain lines = 26 KiB. `g_pay` adds
    # ONE more 256-entry region -> 12 KiB + 16 KiB = 28 KiB, still inside
    # L1d. `m_pay` is NOT in that figure, for the same reason `m_build` is
    # not: it is written once and read once per batch, never in the round
    # loop. The prefetched lines are unchanged in COUNT (one per active row)
    # though each is now a 32 B entry rather than 16 B -- which is the
    # lever, and is why the model prices the wide entry at the same line
    # count as the narrow one.
    comptime _KNW = JOIN_KN_WORDS_PAY if pay else JOIN_KN_WORDS

    comptime if pay:
        join_payload_inline_record_probe()

    var count = 0
    var mask = UInt64(b.capacity - 1)
    var n = probe_keys.length
    var probe_has_nulls = probe_keys.null_count != 0
    var probe_key_view = probe_keys.view_ro()
    var probe_key_ptr = probe_key_view._unsafe_ptr().bitcast[
        Scalar[DType.int64]
    ]()

    # SAFETY: raw pointers for the chain walk. All five Lists are fields of
    # `self`, which is borrowed for the full duration of this method; the
    # `_ = b.<field>` keepalives at every exit guard against AOT
    # destructor reordering. Same hoist, same justification, as
    # `_probe_inner_chunk`.
    var ht_ptr = b.hash_table.unsafe_ptr()
    var bk_ptr = b.build_keys.unsafe_ptr()
    var bi_ptr = b.build_indices.unsafe_ptr()
    var nc_ptr = b.next_chain.unsafe_ptr()
    var kn_ptr = b.key_next.unsafe_ptr()

    var probe_idx = state.probe_pos

    # ---- RESUME TAIL: finish a half-walked row so every batch below
    # begins on a fresh probe row. See `_probe_row_walk`.
    if state.chain_pos != _CHAIN_END:
        if _probe_row_walk[fused, nobi, pay](
            b, probe_keys,
            probe_idx,
            state.chain_pos,
            build_buf,
            probe_buf,
            pay_buf,
            chunk_capacity,
            count,
            state,
        ):
            _ = probe_key_view
            return count
        probe_idx += 1
        state.chain_pos = _CHAIN_END

    # ---- Batch scratch, ONE allocation per call, carved into regions.
    #
    # `unsafe_uninit_length` and not `resize(N, 0)`: every region below is
    # written before it is read (the histogram is zeroed explicitly over
    # its live prefix), and zeroing ~29 KiB on each of the ~13,000 entries
    # one large query makes would be tens of milliseconds of memset charged
    # to this arm alone.
    #
    # A `List` rather than `alloc`/`free` because two calls in the loop
    # below can raise (`is_null`, the bloom), and a raw allocation would
    # leak on the unwind path.
    comptime _B = JOIN_PS_BATCH
    comptime _M = JOIN_PS_MATCH_CAP
    # PAYLOAD-INLINE adds `g_pay` [_B] and `m_pay` [_M]. Both are carved
    # out of the SAME single allocation, and both are ZERO-WIDTH on the
    # default instantiation -- `_PAYB`/`_PAYM` are comptime, so the shipped
    # arm allocates and addresses exactly the bytes it did before.
    comptime _PAYB = _B if pay else 0
    comptime _PAYM = _M if pay else 0
    comptime _SCRATCH = 5 * _B + 2 * _M + _B + 1 + _PAYB + _PAYM
    var scratch = List[Int64]()
    scratch.resize(unsafe_uninit_length=_SCRATCH)
    # SAFETY: module-internal pointer arithmetic into a local List that
    # outlives every use below (`_ = scratch` keepalives at each exit). No
    # region overlaps another; the offsets are comptime constants and every
    # index is bounded by `_B` / `_M` / `s_stop <= _B`.
    var sp = scratch.unsafe_ptr()
    var d_key = sp                       # [_B]  active row's probe key
    var d_cur = sp + _B                  # [_B]  slot, then chain cursor
    var d_slot = sp + 2 * _B             # [_B]  batch-relative row slot
    var g_key = sp + 3 * _B              # [_B]  gathered chain key
    var g_next = sp + 4 * _B             # [_B]  gathered chain link
    var m_slot = sp + 5 * _B             # [_M]  match: row slot
    var m_build = sp + 5 * _B + _M       # [_M]  match: build index
    var hist = sp + 5 * _B + 2 * _M      # [_B + 1] counting-sort histogram
    # ⚠ APPENDED AFTER `hist`, NOT INSERTED BEFORE IT. Every offset above is
    # a comptime constant and the two new regions are the LAST two, so on
    # the default instantiation (`_PAYB == _PAYM == 0`) every pre-existing
    # region lands at byte-identical offsets and the two dead pointers sit
    # at the end of the buffer, never dereferenced.
    var g_pay = sp + 5 * _B + 2 * _M + _B + 1        # [_PAYB] gathered pay
    var m_pay = sp + 5 * _B + 2 * _M + _B + 1 + _PAYB  # [_PAYM] match: pay

    while probe_idx < n:
        # Not enough room left in the caller's buffer to run a batch and
        # still be able to emit whatever it produces -- return a SHORT
        # chunk. `count > 0` necessarily holds: the gate refuses any
        # `chunk_capacity < JOIN_PS_MIN_HEADROOM`, so an empty buffer always
        # has room. That refusal is what keeps a 0-length return meaning
        # "probe exhausted" and nothing else.
        if chunk_capacity - count < JOIN_PS_MIN_HEADROOM:
            state.probe_pos = probe_idx
            state.chain_pos = _CHAIN_END
            break

        var i = probe_idx
        var nb = _B
        if i + nb > n:
            nb = n - i

        # ---- PHASE 0a: hash + slot for all nb rows. Pure ALU + prefetch.
        for j in range(nb):
            var k = Int64((probe_key_ptr + i + j)[])
            d_key[j] = k
            var s = Int(_hash_join_key(k) & mask)
            d_cur[j] = Int64(s)
            prefetch[params = PrefetchOptions().for_read().high_locality()](
                (ht_ptr + s).bitcast[Scalar[DType.int64]]()
            )

        # ---- PHASE 0b: nb INDEPENDENT directory loads, compacted in place.
        var na = 0
        for j in range(nb):
            var row = i + j
            # A NULL probe key matches nothing.
            if probe_has_nulls and probe_keys.is_null(row):
                continue
            var k = d_key[j]
            # Bypass empty-bloom builders. The
            # Fibonacci hash is recomputed rather than carried in a sixth
            # scratch array -- three ALU ops against 2 KiB of L1.
            if b._use_bloom and not b.bloom.might_contain_join_key(
                k, _hash_join_key(k)
            ):
                continue
            var head = (ht_ptr + Int(d_cur[j]))[]
            if head == _CHAIN_END:
                continue
            d_cur[na] = Int64(head)
            d_key[na] = k
            d_slot[na] = Int64(j)
            na += 1

        # First chain record for every survivor, all independent.
        for t in range(na):
            comptime if fused:
                prefetch[
                    params = PrefetchOptions().for_read().high_locality()
                ]((kn_ptr + _KNW * Int(d_cur[t])).bitcast[Scalar[DType.int64]]())
            else:
                prefetch[
                    params = PrefetchOptions().for_read().high_locality()
                ]((bk_ptr + Int(d_cur[t])).bitcast[Scalar[DType.int64]]())

        # ---- ROUNDS
        var nmatch = 0
        while na > 0:
            # Both bounds are checked BEFORE the round, so a round never
            # overruns either buffer and no match ever has to be discarded
            # after being emitted. `s_stop` below repairs the truncation.
            if nmatch + na > _M:
                break
            if count + nmatch + na > chunk_capacity:
                break

            # ---- PHASE 1: gather. na INDEPENDENT record loads.
            for t in range(na):
                var c = Int(d_cur[t])
                comptime if fused:
                    g_key[t] = (kn_ptr + _KNW * c)[]
                    g_next[t] = (kn_ptr + _KNW * c + 1)[]
                    # ★ THE LEVER, in the phase-split shape. Word 2 of the
                    # record whose words 0 and 1 were just loaded -- the
                    # same line, in the same independent gather. It costs
                    # one more load off a line already in flight and it
                    # deletes a whole random access downstream.
                    comptime if pay:
                        g_pay[t] = (kn_ptr + _KNW * c + 2)[]
                else:
                    g_key[t] = (bk_ptr + c)[]
                    g_next[t] = Int64((nc_ptr + c)[])

            # ---- PHASE 2: compare + record + compact + prefetch.
            var na2 = 0
            for t in range(na):
                var nx = g_next[t]
                if g_key[t] == d_key[t]:
                    m_slot[nmatch] = d_slot[t]
                    comptime if nobi:
                        m_build[nmatch] = d_cur[t]
                    else:
                        m_build[nmatch] = Int64(
                            (bi_ptr + Int(d_cur[t]))[]
                        )
                    comptime if pay:
                        m_pay[nmatch] = g_pay[t]
                    nmatch += 1
                if nx != Int64(_CHAIN_END):
                    d_cur[na2] = nx
                    d_key[na2] = d_key[t]
                    d_slot[na2] = d_slot[t]
                    na2 += 1
                    comptime if fused:
                        prefetch[
                            params = PrefetchOptions()
                            .for_read()
                            .high_locality()
                        ](
                            (kn_ptr + _KNW * Int(nx)).bitcast[
                                Scalar[DType.int64]
                            ]()
                        )
                    else:
                        prefetch[
                            params = PrefetchOptions()
                            .for_read()
                            .high_locality()
                        ](
                            (bk_ptr + Int(nx)).bitcast[
                                Scalar[DType.int64]
                            ]()
                        )
            na = na2

        # ---- HOW MUCH OF THE BATCH MAY BE EMITTED.
        # A probe row's matches may only be emitted once its whole chain has
        # been walked, or row-major order would interleave rows. The active
        # set is maintained in increasing slot order by every compaction, so
        # `d_slot[0]` IS the lowest slot still walking and every slot below
        # it is finished. When the rounds ran to completion, all of them are.
        var s_stop = nb
        if na > 0:
            s_stop = Int(d_slot[0])

        if s_stop == 0:
            # Nothing completed: the very first row of the batch is still
            # walking. Re-running the batch would not make progress, so that
            # one row is finished row-at-a-time (unbounded chain, honours
            # `chunk_capacity`) and the next batch starts after it.
            if _probe_row_walk[fused, nobi, pay](
                b, probe_keys,
                i,
                _CHAIN_END,
                build_buf,
                probe_buf,
                pay_buf,
                chunk_capacity,
                count,
                state,
            ):
                _ = scratch
                _ = probe_key_view
                return count
            probe_idx = i + 1
            continue

        # ---- STABLE COUNTING SORT by row slot, emitting straight into the
        # caller's buffers. Iterating `t` upward is what makes it stable,
        # and stability is what preserves chain order within a row.
        for s in range(s_stop):
            hist[s] = Int64(0)
        for t in range(nmatch):
            var s = Int(m_slot[t])
            if s < s_stop:
                hist[s] = hist[s] + Int64(1)
        var run = 0
        for s in range(s_stop):
            var c = Int(hist[s])
            hist[s] = Int64(run)
            run += c
        for t in range(nmatch):
            var s = Int(m_slot[t])
            if s < s_stop:
                var p = Int(hist[s])
                hist[s] = Int64(p + 1)
                (build_buf + count + p)[] = Int(m_build[t])
                (probe_buf + count + p)[] = i + s
                # The payload travels with its pair through the SAME
                # permutation `p`. Emitting it anywhere else -- or through a
                # second pass -- would decouple the two, and a payload
                # column permuted differently from its build index is a
                # wrong answer no row-count or multiset oracle can see.
                comptime if pay:
                    (pay_buf + count + p)[] = m_pay[t]
        count += run

        probe_idx = i + s_stop
        state.probe_pos = probe_idx
        state.chain_pos = _CHAIN_END

    if probe_idx >= n:
        state.probe_pos = probe_idx
        state.chain_pos = _CHAIN_END
        state.done = True

    # Keepalives: prevent premature destruction of self's fields (and the
    # scratch) whose raw pointers were extracted above.
    _ = scratch
    _ = probe_key_view
    _ = b.hash_table
    _ = b.build_keys
    _ = b.build_indices
    _ = b.next_chain
    _ = b.key_next
    return count
