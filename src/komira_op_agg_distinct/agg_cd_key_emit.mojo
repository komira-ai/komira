# =============================================================================
# The grouped COUNT(DISTINCT) driver's STRING-KEY EMIT (KEYOUT), one body for
# whichever buffer a dict id's bytes live in
# =============================================================================
#
# The grouped COUNT(DISTINCT) driver (added by a later part) emits a string
# group key by turning each output group's DICT ID into the id's bytes: `bytes[starts[id] : starts[id] +
# lens[id]]`. Before L3 `bytes` was always a byte ARENA the encode had
# built. Since L3 (`agg_cd_strenc_parb.mojo`) the parallel Phase B builds no
# arena — its `starts` index the SOURCE column's value buffer — while the
# serial Phase B and the DICTIONARY arm still hand over an arena. The two are
# `Span`s of DIFFERENT origins, which one local cannot hold, so the emit is one
# function generic over the span's origin, called with whichever applies.
#
# ⭐ KEY PREFETCH — THE FULL EMIT IS A THREE-STREAM POINTER CHASE, AND THE K-WAY
# CONCAT IS WHAT MADE IT RANDOM. `gk[g]` is a dict id; reaching its bytes costs
# three dependent loads into three structures that do not fit in cache at
# millions of groups (`starts`, `lens`, `bytes`). Worker 0's block walks dict
# ids ascending, so at K=1 all three streams are sequential; every later
# worker's block is walked in HT-SLOT order, which is random. Two
# software-prefetch distances restore the overlap WITHOUT touching the emit
# ORDER: at `g + PF2` bring in the `starts`/`lens` entries, at `g + PF1` the
# byte line they point at. ⚠ OFF at K=1 (`prefetch_on=False`),
# where the walk is already ascending and the hints add nothing.
#
# ⭐⭐ CDPTOPK — THE BOUNDED ARM. When the plan's `AggGroupTopK(k)`
# hint was admitted, `emit_gids` names the <= k groups a `TOPN(k)` above can
# keep, and only their bytes are emitted. No prefetch there (ten rows) and no
# full-table length pre-pass: `ArrowStringBuilder` is Int32-offset `string`
# unconditionally, so `reserve_bytes` is an allocation hint, not a type input.
#
# The out-of-range arm (an id outside `[0, len(starts))`) emits a ZERO-LENGTH
# value, as the pre-CDPSPAN `String("")` did.
# =============================================================================

from std.sys.intrinsics import prefetch, PrefetchOptions
from std.memory import UnsafePointer

from komira_arrow.column import Column
from komira_arrow.string_builder import ArrowStringBuilder
from komira_buffer.heap_region import HeapRegion


# Software-prefetch distances for the full STRING key emit, in output
# rows. PF2 MUST be the larger: the `starts`/`lens` entry fetched at `g + PF2`
# is the address the byte prefetch issued at `g + PF1` depends on.
comptime _CDP_KEYOUT_PF2: Int = 32
comptime _CDP_KEYOUT_PF1: Int = 16


@always_inline
def _id_of(imm gk: List[Int], g: Int, identity: Bool) -> Int:
    """Output group g's dict id: `g` itself under `identity`, else `gk[g]`."""
    if identity:
        return g
    return gk[g]


def cd_emit_string_key_column[
    mut: Bool, //, o: Origin[mut=mut]
](
    bytes: Span[UInt8, o],
    imm gk: List[Int],
    imm starts: List[Int],
    imm lens: List[Int],
    imm emit_gids: List[Int],
    bounded: Bool,
    num_groups: Int,
    prefetch_on: Bool,
    gk_identity: Bool = False,
) raises -> Column[HeapRegion]:
    """Build the STRING key column of the grouped COUNT(DISTINCT) output.

    Args:
        bytes: The buffer the dict ids' spans index — the encode's arena, or
            (L3) the source column's own value buffer.
        gk: Dict id of each output group, in output order.
        starts: Span start of each dict id inside `bytes`.
        lens: Span length of each dict id.
        emit_gids: CDPTOPK survivors (indices into `gk`); read only when
            `bounded`.
        bounded: True when CDPTOPK fired — emit `emit_gids` only.
        num_groups: Rows of the full emit (`gk`'s length).
        prefetch_on: key prefetch hints on the full emit (False at K=1).
        gk_identity: Output group g's dict id IS g (`gk` is not read) — the
            fused route (added by a later part), whose output order is
            dict-id order. Saves building a `num_groups`-long identity list.

    Returns:
        The key column, `len(emit_gids)` rows when `bounded`, else
        `num_groups`.
    """
    var n_rev = len(starts)
    var empty = List[UInt8]()
    if bounded:
        var n_emit = len(emit_gids)
        var total_t = 0
        for i in range(n_emit):
            var idx_t = _id_of(gk, emit_gids[i], gk_identity)
            if idx_t >= 0 and idx_t < n_rev:
                total_t += lens[idx_t]
        var sbld_t = ArrowStringBuilder()
        sbld_t.reserve_rows(n_emit)
        sbld_t.reserve_bytes(total_t)
        for i in range(n_emit):
            var ip_t = _id_of(gk, emit_gids[i], gk_identity)
            if ip_t < 0 or ip_t >= n_rev:
                sbld_t.push_bytes(Span(empty))
            else:
                var s_t = starts[ip_t]
                sbld_t.push_bytes(bytes[s_t : s_t + lens[ip_t]])
        return sbld_t^.build()

    var pf2 = _CDP_KEYOUT_PF2 if prefetch_on else 0
    var pf1 = _CDP_KEYOUT_PF1 if prefetch_on else 0
    # Length pre-pass: `reserve_bytes` allocates `data` ONCE at its final
    # size, so no doubling-realloc traffic appears. Value-invisible;
    # `tests/test_cd_key_emit.mojo` pins it.
    var total_bytes = 0
    for g in range(num_groups):
        var gp = g + pf2
        if pf2 > 0 and gp < num_groups:
            var ip = _id_of(gk, gp, gk_identity)
            if ip >= 0 and ip < n_rev:
                # SAFETY: a prefetch ADDRESS only (architecturally a hint,
                # never a dereference), formed from an index range-checked
                # against `n_rev` on the line above.
                prefetch[params = PrefetchOptions().for_read().high_locality()](
                    UnsafePointer(to=lens[ip])
                )
        var idx_b = _id_of(gk, g, gk_identity)
        if idx_b >= 0 and idx_b < n_rev:
            total_bytes += lens[idx_b]
    var sbld = ArrowStringBuilder()
    sbld.reserve_rows(num_groups)
    sbld.reserve_bytes(total_bytes)
    # SAFETY: `_ar` is the byte Span's own base pointer, used ONLY as a
    # prefetch address. The emitted bytes still go through the bounds-checked
    # `bytes[lo:hi]` slice below; every address formed here is `base +
    # starts[i]` for an `i` already range-checked against `n_rev` and an offset
    # re-checked against the span length — the same arithmetic the slice does.
    var _ar = bytes.unsafe_ptr()
    var _arn = len(bytes)
    for g in range(num_groups):
        var g2 = g + pf2
        if pf2 > 0 and g2 < num_groups:
            var i2 = _id_of(gk, g2, gk_identity)
            if i2 >= 0 and i2 < n_rev:
                prefetch[params = PrefetchOptions().for_read().high_locality()](
                    UnsafePointer(to=starts[i2])
                )
                prefetch[params = PrefetchOptions().for_read().high_locality()](
                    UnsafePointer(to=lens[i2])
                )
        var g1 = g + pf1
        if pf1 > 0 and g1 < num_groups:
            var i1 = _id_of(gk, g1, gk_identity)
            if i1 >= 0 and i1 < n_rev:
                var o1 = starts[i1]
                if o1 >= 0 and o1 < _arn:
                    prefetch[params = PrefetchOptions().for_read().high_locality()](
                        _ar + o1
                    )
        var idx_p = _id_of(gk, g, gk_identity)
        if idx_p < 0 or idx_p >= n_rev:
            sbld.push_bytes(Span(empty))
        else:
            var s_p = starts[idx_p]
            sbld.push_bytes(bytes[s_p : s_p + lens[idx_p]])
    return sbld^.build()
