# =============================================================================
# join_probe_outer -- the LEFT, RIGHT and FULL outer probes of
# `HashJoinBuilder`
# =============================================================================
#
# An unmatched row of a preserved side is emitted once with -1 for the other
# side. A NULL key matches nothing: a NULL probe row is unmatched (kept by
# LEFT and FULL), and a NULL build row, recorded but never linked, is emitted
# by the RIGHT/FULL unmatched-build sweep.
# =============================================================================

from komira_arrow.primitive_array import PrimitiveArray

from .join import HashJoinBuilder, _CHAIN_END, _hash_join_key
from .join_layout_counter import join_layout_record_probe


def probe_left_into(
    b: HashJoinBuilder,
    probe_keys: PrimitiveArray[DType.int64],
    mut build_matches: List[Int],
    mut probe_matches: List[Int],
) raises:
    """Four-way chain-entry-layout dispatcher for the LEFT outer probe.

    See `probe_inner_into` for why the four arms are comptime-specialised
    rather than branched per row, and `_probe_left_into` for the algorithm."""
    b._refuse_pay_inline("probe_left_into")
    join_layout_record_probe(
        "probe_left_into", b._bi_elided, b._fused
    )
    if b._fused:
        if b._bi_elided:
            _probe_left_into[True, True](
                b, probe_keys, build_matches, probe_matches
            )
        else:
            _probe_left_into[True, False](
                b, probe_keys, build_matches, probe_matches
            )
    else:
        if b._bi_elided:
            _probe_left_into[False, True](
                b, probe_keys, build_matches, probe_matches
            )
        else:
            _probe_left_into[False, False](
                b, probe_keys, build_matches, probe_matches
            )


def _probe_left_into[
    fused: Bool, nobi: Bool
](
    b: HashJoinBuilder,
    probe_keys: PrimitiveArray[DType.int64],
    mut build_matches: List[Int],
    mut probe_matches: List[Int],
) raises:
    """Left outer join probe that appends to caller-provided output lists.

    Same algorithm as `probe_left` but writes into pre-allocated output
    buffers. See `probe_inner_into` for the rationale (avoids the
    `.copy()` on each tuple element that the Tuple-returning API
    forces on every caller).

    Args:
        probe_keys: The probe-side join key column.
        build_matches: Output list for build-side row indices (-1 when
            no match); appended.
        probe_matches: Output list for probe-side row indices; appended.
    """
    var n = probe_keys.length
    var mask = UInt64(b.capacity - 1)

    # A NULL probe key matches nothing. For LEFT outer the NULL probe
    # row is STILL emitted (-1 build fill) — the no-match path — so the only
    # change is to skip the chain walk for NULL keys. `probe_has_nulls` gates.
    var probe_has_nulls = probe_keys.null_count != 0

    # Origin-tied view of the key buffer (`view_ro`), bitcast to Int64.
    # `probe_key_view` keepalive holds the borrow through the probe body.
    var probe_key_view = probe_keys.view_ro()
    var probe_key_ptr = probe_key_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()

    # SAFETY: Raw pointers for the chain walk. All four Lists are fields
    # of `self`, which is borrowed for the full duration of this method.
    # Keepalives at the bottom guard against AOT destructor reordering.
    var ht_ptr = b.hash_table.unsafe_ptr()
    var bk_ptr = b.build_keys.unsafe_ptr()
    var bi_ptr = b.build_indices.unsafe_ptr()
    var nc_ptr = b.next_chain.unsafe_ptr()
    # Fused 16-byte-record view; empty and never dereferenced unless `fused`.
    var kn_ptr = b.key_next.unsafe_ptr()

    for probe_idx in range(n):
        var probe_key = Int64((probe_key_ptr + probe_idx)[])

        # Walk the chain at this bucket using raw pointer arithmetic.
        # A NULL probe key matches nothing -> skip the walk so the
        # unmatched LEFT emit below fires (found stays False).
        var found = False
        if not (probe_has_nulls and probe_keys.is_null(probe_idx)):
            var h = _hash_join_key(probe_key)
            var slot = Int(h & mask)
            var chain_idx = (ht_ptr + slot)[]
            while chain_idx != _CHAIN_END:
                var chain_key: Int64
                comptime if fused:
                    chain_key = (kn_ptr + 2 * chain_idx)[]
                else:
                    chain_key = (bk_ptr + chain_idx)[]
                if chain_key == probe_key:
                    # Match found: emit the pair using original row indices.
                    comptime if nobi:
                        build_matches.append(chain_idx)
                    else:
                        build_matches.append((bi_ptr + chain_idx)[])
                    probe_matches.append(probe_idx)
                    found = True
                comptime if fused:
                    chain_idx = Int((kn_ptr + 2 * chain_idx + 1)[])
                else:
                    chain_idx = (nc_ptr + chain_idx)[]

        if not found:
            # No match: emit probe row with -1 for build side (null).
            build_matches.append(-1)
            probe_matches.append(probe_idx)

    # Keepalive: prevent premature destruction of self's fields.
    _ = b.hash_table
    _ = b.build_keys
    _ = b.build_indices
    _ = b.next_chain
    _ = b.key_next


def probe_left(b: HashJoinBuilder, probe_keys: PrimitiveArray[DType.int64]) raises -> Tuple[List[Int], List[Int]]:
    """Left outer join probe: Tuple-returning wrapper for test callers.

    Hot-path callers use `probe_left_into` directly to skip the
    `.copy()`-forced tuple packing.

    Returns:
        A tuple of (build_indices, probe_indices) where build_indices[i]
        is -1 when there is no match (null on the build side).
    """
    # Left join: every probe row appears, so output >= n rows
    var build_matches = List[Int](capacity=probe_keys.length)
    var probe_matches = List[Int](capacity=probe_keys.length)
    probe_left_into(b, probe_keys, build_matches, probe_matches)
    return (build_matches^, probe_matches^)


def probe_right(b: HashJoinBuilder, probe_keys: PrimitiveArray[DType.int64]) raises -> Tuple[List[Int], List[Int]]:
    """Right outer join probe: all build rows appear, with matched probe rows or -1.

    For each probe row, hashes the key, looks up the hash bucket, and
    walks the chain comparing keys. Matches produce (build_index, probe_index)
    pairs. Additionally, tracks which build rows were matched. After probing,
    emits (build_index, -1) for every unmatched build row.

    This guarantees every build row appears at least once in the output.

    Args:
        probe_keys: The probe-side join key column.

    Returns:
        A tuple of (build_indices, probe_indices) where probe_indices[i]
        is -1 when there is no match (null on the probe side).
    """
    join_layout_record_probe("probe_right", b._bi_elided, b._fused)
    var n = probe_keys.length
    # Right join: output >= max(n, build) rows
    var num_build = b.num_build
    var build_matches = List[Int](capacity=max(n, num_build))
    var probe_matches = List[Int](capacity=max(n, num_build))
    var mask = UInt64(b.capacity - 1)

    # Track which build entries have been matched.
    var matched = List[Bool]()
    for _ in range(num_build):
        matched.append(False)

    # A NULL probe key matches nothing -> no pair (RIGHT outer drops
    # the unmatched probe row). A NULL build key is recorded but unlinked, so
    # it stays unmatched and is emitted by the unmatched-build sweep below.
    var probe_has_nulls = probe_keys.null_count != 0

    # Origin-tied view of the key buffer (`view_ro`), bitcast to Int64.
    # `probe_key_view` keepalive holds the borrow through the probe body.
    var probe_key_view = probe_keys.view_ro()
    var probe_key_ptr = probe_key_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()

    for probe_idx in range(n):
        var probe_key = Int64((probe_key_ptr + probe_idx)[])
        if probe_has_nulls and probe_keys.is_null(probe_idx):
            continue
        var h = _hash_join_key(probe_key)
        var slot = Int(h & mask)

        # Walk the chain at this bucket.
        var chain_idx = b.hash_table[slot]
        while chain_idx != _CHAIN_END:
            # Layout-tolerant, RUNTIME-branched: this walk was already
            # bounds-checked `List` indexing. RIGHT/FULL are the cold outer
            # arms; the hot inner/left/semi/anti probes take the comptime
            # bodies instead. See `build_row_at`'s block comment.
            if b.chain_key_at(chain_idx) == probe_key:
                build_matches.append(b.build_row_at(chain_idx))
                probe_matches.append(probe_idx)
                matched[chain_idx] = True
            chain_idx = b.chain_next_at(chain_idx)

    # Emit unmatched build rows with -1 for probe side.
    for i in range(num_build):
        if not matched[i]:
            build_matches.append(b.build_row_at(i))
            probe_matches.append(-1)

    return (build_matches^, probe_matches^)


def probe_full(b: HashJoinBuilder, probe_keys: PrimitiveArray[DType.int64]) raises -> Tuple[List[Int], List[Int]]:
    """Full outer join probe: all rows from both sides, -1 for no match.

    Combines inner join matches with unmatched probe rows (build_index = -1)
    and unmatched build rows (probe_index = -1). Every row from both sides
    appears at least once in the output.

    Args:
        probe_keys: The probe-side join key column.

    Returns:
        A tuple of (build_indices, probe_indices) where build_indices[i]
        is -1 when probe row has no match, and probe_indices[i] is -1
        when build row has no match.
    """
    join_layout_record_probe("probe_full", b._bi_elided, b._fused)
    var n = probe_keys.length
    # Full join: output >= max(n, build) + unmatched from both sides
    var num_build = b.num_build
    var build_matches = List[Int](capacity=n + num_build)
    var probe_matches = List[Int](capacity=n + num_build)
    var mask = UInt64(b.capacity - 1)

    # Track which build entries have been matched.
    var matched = List[Bool]()
    for _ in range(num_build):
        matched.append(False)

    # A NULL probe key matches nothing. For FULL outer the NULL probe
    # row is STILL emitted as unmatched (-1 build); a NULL build key is
    # recorded-but-unlinked and emitted by the unmatched-build sweep. So the
    # only change is to skip the chain walk for a NULL probe key.
    var probe_has_nulls = probe_keys.null_count != 0

    # Origin-tied view of the key buffer (`view_ro`), bitcast to Int64.
    # `probe_key_view` keepalive holds the borrow through the probe body.
    var probe_key_view = probe_keys.view_ro()
    var probe_key_ptr = probe_key_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()

    for probe_idx in range(n):
        var probe_key = Int64((probe_key_ptr + probe_idx)[])

        # Walk the chain at this bucket.
        var found = False
        if not (probe_has_nulls and probe_keys.is_null(probe_idx)):
            var h = _hash_join_key(probe_key)
            var slot = Int(h & mask)
            var chain_idx = b.hash_table[slot]
            while chain_idx != _CHAIN_END:
                # Layout-tolerant, RUNTIME-branched -- see `probe_right`.
                if b.chain_key_at(chain_idx) == probe_key:
                    build_matches.append(b.build_row_at(chain_idx))
                    probe_matches.append(probe_idx)
                    matched[chain_idx] = True
                    found = True
                chain_idx = b.chain_next_at(chain_idx)

        if not found:
            # Unmatched probe row: -1 for build side.
            build_matches.append(-1)
            probe_matches.append(probe_idx)

    # Emit unmatched build rows with -1 for probe side.
    for i in range(num_build):
        if not matched[i]:
            build_matches.append(b.build_row_at(i))
            probe_matches.append(-1)

    return (build_matches^, probe_matches^)
