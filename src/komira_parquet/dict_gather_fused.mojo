# =============================================================================
# dict_gather_fused: the blocked, bounds-fused dictionary gather
# =============================================================================
#
# `DictionaryDecoder.resolve_*` turns RLE_DICTIONARY codes into values. Its
# legacy arm spends its instructions on three things, and this module removes
# two of them and makes the third adaptive:
#
#   1. A SEPARATE FULL PASS FOR BOUNDS. `_validate_dict_indices` streams the
#      whole code array computing a SIMD min/max, and then the gather streams
#      the same array again. A row group of codes does not fit in L2, so that is
#      two trips to L3. Blocking the two together at 2,048 codes (8 KB, L1-sized)
#      makes the gather's read of each block an L1 hit, at the same instruction
#      count and the same safety: a block is fully bounds-checked BEFORE any of
#      its codes indexes the dictionary.
#
#   2. AN UNCONDITIONAL PREFETCH OF A RANDOM DICTIONARY ADDRESS. The legacy
#      loop issues `prefetch(dict + idx[i + 16])` every W values: an extra
#      int32 load, an address computation, a bounds branch and a load-port uop
#      per group. That is the right shape for a dictionary that misses L2 and
#      pure overhead for one that does not (a dictionary of a thousand Int64
#      entries is 8 KB and L1-resident).
#
#      THE THRESHOLD BELOW IS A MODEL, NOT A MEASUREMENT. `_PF_MIN_DICT_BYTES`
#      says "prefetch only when the dictionary cannot be L2-resident". The
#      dictionary's SIZE is exact (we know its length), but "L2-resident" is a
#      claim about a machine (L2 sizes run from 256 KiB to several MB per
#      core). A conservative single constant is used rather than a per-uarch
#      table, because a wrong-way error here re-introduces the stall the
#      prefetch exists to hide.
#
#   3. A LANE-BY-LANE SIMD VECTOR BUILD. `lanes[k] = dict[idx_k]` inside a
#      `comptime for` builds a SIMD vector one element at a time and stores it
#      whole: on AVX2 that is 4 scalar loads + 3 inserts + a store for 4
#      values, where a straight scalar gather is 4 loads + 4 stores with no
#      insert chain (and a hardware gather of 4 elements costs more cycles than
#      4 L1 loads on CPUs without AVX-512). The scalar arm is 4x-unrolled so the
#      loads issue independently.
#
# WHAT THIS MODULE DOES NOT DO. It does not change the bit-unpack
# (`rle.mojo`), a separate kernel. It does not fuse the unpack into the gather
# (which would delete the code array): that needs the column decoder's page
# loop restructured.
#
# EVERY ARM HERE IS A PURE PERMUTATION OF THE DICTIONARY. It cannot change a
# value; the tests run both arms over the same input in one process and
# assert element-wise equality plus the exact fire counts.
#
# SAFETY: `UnsafePointer` appears only INSIDE `_gather_range_*` /
# `_block_in_bounds`, all module-private, all reached through origin-tied
# `view_ro()` / `view_mut()` borrows held live across the call. No public
# signature in this module names a pointer.
# =============================================================================

from std.sys import size_of, simd_width_of
from std.sys.intrinsics import prefetch, PrefetchOptions

from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer


# -----------------------------------------------------------------------------
# Tunables — both are MODELS. See the header.
# -----------------------------------------------------------------------------

# Codes per bounds+gather block. 2,048 int32 = 8 KB, which is L1-resident on
# current CPUs (L1d is 32 KB or more). Big enough that the per-block loop overhead is noise
# (~6 instructions amortised over 2,048 values), small enough that the gather's
# re-read of the block cannot have been evicted by the gather's own output
# stores (2,048 x 8 B = 16 KB of stores between the check and the last re-read).
comptime _DICT_GATHER_BLOCK: Int = 2048

# Prefetch the dictionary only when it cannot plausibly be L2-resident. 256 KiB
# is the smallest per-core L2 of current server CPUs, so the arm is
# conservative in the direction that keeps the prefetch where it might matter.
comptime _PF_MIN_DICT_BYTES: Int = 256 * 1024

# Distance, in values, of the prefetched code from the one being gathered.
# Mirrors the legacy `_DICT_PF_INT64` / `_DICT_PF_FLOAT64` = 16.
comptime _DICT_PF_DISTANCE: Int = 16


# -----------------------------------------------------------------------------
# The blocked bounds check.
# -----------------------------------------------------------------------------


@always_inline
def _block_in_bounds[
    o: Origin[mut=False]
](
    idx_ptr: UnsafePointer[Scalar[DType.int32], o],
    start: Int,
    end: Int,
    dict_len: Int,
) -> Bool:
    """True iff every code in `idx_ptr[start:end]` lies in `[0, dict_len)`.

    Branch-free SIMD min/max over the block, then ONE comparison — the same
    shape as `dictionary._validate_dict_indices`, applied to a block instead of
    to the whole array so the gather's re-read of the block is an L1 hit.

    ⚠ THIS RETURNS A BOOL AND DOES NOT RAISE. The caller re-runs the exact
    whole-array validator on failure, so the ERROR MESSAGE a corrupt file
    produces is byte-for-byte the one it produced before this module existed
    (it names the min and max over the WHOLE code stream, not over the first
    offending block). Corrupt input is not a hot path; the message is evidence.

    SAFETY: `idx_ptr` is derived from an origin-tied `view_ro()` held live by
    the caller across this call; `start`/`end` are bounded by the caller's
    `num_values`.
    """
    comptime W: Int = simd_width_of[DType.int32]()
    var n = end - start
    if n <= 0:
        return True

    var min_code = idx_ptr.load[width=1](start)
    var max_code = min_code
    var i = start + 1

    var simd_end = start + (n // W) * W
    if simd_end > start:
        var first = idx_ptr.load[width=W](start)
        var min_acc = first
        var max_acc = first
        i = start + W
        while i < simd_end:
            var chunk = idx_ptr.load[width=W](i)
            min_acc = (min_acc.lt(chunk)).select(min_acc, chunk)
            max_acc = (max_acc.gt(chunk)).select(max_acc, chunk)
            i += W
        min_code = min_acc.reduce_min()
        max_code = max_acc.reduce_max()

    while i < end:
        var v = idx_ptr.load[width=1](i)
        if v < min_code:
            min_code = v
        if v > max_code:
            max_code = v
        i += 1

    return Int(min_code) >= 0 and Int(max_code) < dict_len


# -----------------------------------------------------------------------------
# The gather kernels.
# -----------------------------------------------------------------------------


@always_inline
def _gather_range_flat[
    T: DType,
    o_i: Origin[mut=False],
    o_d: Origin[mut=False],
    o_o: Origin[mut=True],
](
    idx_ptr: UnsafePointer[Scalar[DType.int32], o_i],
    dict_ptr: UnsafePointer[Scalar[T], o_d],
    out_ptr: UnsafePointer[Scalar[T], o_o],
    start: Int,
    end: Int,
):
    """4x-unrolled scalar gather for an L1/L2-RESIDENT dictionary.

    Three x86 instructions per value in the steady state — `movslq` of the
    code (the sign-extend folds into the addressing mode of the next load),
    the dictionary load, and the store — with the four loads independent so the
    OOO core issues them in parallel. No prefetch (the dictionary is already
    close), no vector-lane insert chain, no per-group branch.

    SAFETY: every code in `[start, end)` was proven in `[0, dict_len)` by
    `_block_in_bounds` BEFORE this call, on this very block. All three pointers
    come from origin-tied views the caller holds live.
    """
    var i = start
    var unroll_end = start + ((end - start) >> 2 << 2)
    while i < unroll_end:
        var c0 = Int(idx_ptr.load[width=1](i))
        var c1 = Int(idx_ptr.load[width=1](i + 1))
        var c2 = Int(idx_ptr.load[width=1](i + 2))
        var c3 = Int(idx_ptr.load[width=1](i + 3))
        out_ptr.store[width=1](i, dict_ptr.load[width=1](c0))
        out_ptr.store[width=1](i + 1, dict_ptr.load[width=1](c1))
        out_ptr.store[width=1](i + 2, dict_ptr.load[width=1](c2))
        out_ptr.store[width=1](i + 3, dict_ptr.load[width=1](c3))
        i += 4
    while i < end:
        var c = Int(idx_ptr.load[width=1](i))
        out_ptr.store[width=1](i, dict_ptr.load[width=1](c))
        i += 1


@always_inline
def _gather_range_prefetched[
    T: DType,
    o_i: Origin[mut=False],
    o_d: Origin[mut=False],
    o_o: Origin[mut=True],
](
    idx_ptr: UnsafePointer[Scalar[DType.int32], o_i],
    dict_ptr: UnsafePointer[Scalar[T], o_d],
    out_ptr: UnsafePointer[Scalar[T], o_o],
    start: Int,
    end: Int,
    pf_limit: Int,
):
    """4x-unrolled scalar gather that PREFETCHES the dictionary line for the
    code `_DICT_PF_DISTANCE` values ahead.

    Selected only when the dictionary is larger than `_PF_MIN_DICT_BYTES`, i.e.
    when a gather is a genuine L2/LLC miss and the ~1.4 instructions per value
    the prefetch costs buy a hidden miss. `pf_limit` is the whole array length
    (not the block end) so the prefetch reaches ACROSS a block boundary — the
    blocking is a cache-residency device for the CODES and must not shorten the
    lookahead for the DICTIONARY.

    SAFETY: as `_gather_range_flat`. The prefetched code at `i + distance` may
    belong to a not-yet-validated block; a prefetch is a HINT that never faults
    and never produces an architecturally visible value, so it cannot leak an
    out-of-range read — and its own index load is bounded by `pf_limit`.
    """
    var i = start
    var unroll_end = start + ((end - start) >> 2 << 2)
    while i < unroll_end:
        if i + _DICT_PF_DISTANCE < pf_limit:
            var pf_idx = Int(idx_ptr.load[width=1](i + _DICT_PF_DISTANCE))
            prefetch[
                params = PrefetchOptions().for_read().high_locality()
            ]((dict_ptr + pf_idx))
        var c0 = Int(idx_ptr.load[width=1](i))
        var c1 = Int(idx_ptr.load[width=1](i + 1))
        var c2 = Int(idx_ptr.load[width=1](i + 2))
        var c3 = Int(idx_ptr.load[width=1](i + 3))
        out_ptr.store[width=1](i, dict_ptr.load[width=1](c0))
        out_ptr.store[width=1](i + 1, dict_ptr.load[width=1](c1))
        out_ptr.store[width=1](i + 2, dict_ptr.load[width=1](c2))
        out_ptr.store[width=1](i + 3, dict_ptr.load[width=1](c3))
        i += 4
    while i < end:
        var c = Int(idx_ptr.load[width=1](i))
        out_ptr.store[width=1](i, dict_ptr.load[width=1](c))
        i += 1


# -----------------------------------------------------------------------------
# The public entry point.
# -----------------------------------------------------------------------------


def resolve_gather_fused[
    T: DType
](
    indices: PrimitiveArray[DType.int32],
    dict_values: PrimitiveArray[T],
) raises -> Optional[PrimitiveArray[T]]:
    """Resolve dictionary codes to values, bounds-check FUSED into the gather.

    Returns `None` — and gathers NOTHING — if any block fails its bounds check.
    The caller then runs the whole-array validator, which raises with the
    message a corrupt file has always produced. A `None` return therefore means
    "corrupt input, go raise properly", never "unsupported".

    Args:
        indices: RLE_DICTIONARY codes for one column chunk.
        dict_values: The decoded dictionary page for this chunk.

    Returns:
        The resolved values, or `None` if a code was out of range.
    """
    var num_values = indices.length
    var dict_len = dict_values.length

    comptime elem_size = size_of[Scalar[T]]()
    var buf = OwnedAlignedBuffer(max(num_values * elem_size, 1))
    buf.set_length(Int64(num_values * elem_size))

    if num_values <= 0:
        return Optional[PrimitiveArray[T]](
            PrimitiveArray[T](buf^, 0, None, 0, 0)
        )
    if dict_len <= 0:
        # Codes to resolve but no dictionary: the whole-array validator owns
        # this diagnostic (it names the count and the empty extent).
        return Optional[PrimitiveArray[T]](None)

    var idx_view = indices.view_ro()
    var idx_ptr = idx_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    var dict_view = dict_values.view_ro()
    var dict_ptr = dict_view._unsafe_ptr().bitcast[Scalar[T]]()
    var buf_view = buf.view_mut()
    var out_ptr = buf_view._unsafe_ptr().bitcast[Scalar[T]]()

    # ⚠ THE ARM CHOICE IS A MODEL (see `_PF_MIN_DICT_BYTES` in the header):
    # dictionary BYTES is exact, "fits in L2" is a claim about a box.
    var prefetch_arm = (dict_len * elem_size) > _PF_MIN_DICT_BYTES

    var blk = 0
    while blk < num_values:
        var end = min(blk + _DICT_GATHER_BLOCK, num_values)
        # SAFETY: the gather below indexes the dictionary with these codes and
        # ONLY these codes, and it does not run unless this returns True.
        if not _block_in_bounds(idx_ptr, blk, end, dict_len):
            _ = idx_view^
            _ = dict_view^
            _ = buf_view^
            return Optional[PrimitiveArray[T]](None)
        if prefetch_arm:
            _gather_range_prefetched[T](
                idx_ptr, dict_ptr, out_ptr, blk, end, num_values
            )
        else:
            _gather_range_flat[T](idx_ptr, dict_ptr, out_ptr, blk, end)
        blk = end

    _ = idx_view^
    _ = dict_view^
    _ = buf_view^
    return Optional[PrimitiveArray[T]](
        PrimitiveArray[T](buf^, num_values, None, 0, 0)
    )


# =============================================================================
# The second dictionary gather: the sub-row-group cursor route's
# =============================================================================
#
# The sub-row-group cursor route has its own code fill and its own gather (a
# per-value clamping loop over a decoded `List` dictionary), so a lever on
# `DictionaryDecoder.resolve_*` does not reach it. This entry point gives that
# route the same blocked shape.
#
# WHAT IS DIFFERENT ABOUT THIS ONE, AND WHY IT NEEDS ITS OWN ENTRY POINT. The
# `resolve_*` family RAISES on an out-of-range code. This one CLAMPS it to
# `dict[0]`, deliberately: the caller's row-group completeness check has
# already declined a malformed row group, and the clamp is the second guard.
# So the semantics are not interchangeable and this cannot reuse
# `resolve_gather_fused`. What it CAN reuse is the shape: hoist the bounds test
# out of the per-value loop into a per-block branchless SIMD min/max, and gather
# branchlessly when the block passes. A block that FAILS falls back to the exact
# per-value clamping loop, so a malformed row group produces identical output.
#
# THE PER-VALUE BRANCH IS THE POINT. The legacy loop is
# `if code < 0 or code >= col_dict_size: code = 0` on EVERY value: a compare, a
# compare, a conditional move or branch, inside a loop that is otherwise three
# instructions. Hoisting it removes them from every block that passes.
# =============================================================================


def gather_flat_clamped[
    T: DType
](
    codes: OwnedAlignedBuffer,
    n_rows: Int,
    rows_val: Int,
    imm col_dict: List[Scalar[T]],
) raises -> PrimitiveArray[T]:
    """Resolve `rows_val` int32 codes from `codes` against `col_dict`, CLAMPING
    an out-of-range code to `dict[0]`, and fill `rows_val..n_rows` with
    `dict[0]`.

    Byte-for-byte the contract of the sub-row-group route's per-value loop; the
    difference is that the bounds test is hoisted to a per-block branchless SIMD
    min/max instead of running on every value.

    Args:
        codes: The FIXED value buffer, holding at least `n_rows` int32 codes.
        n_rows: Rows in the output column.
        rows_val: Codes actually filled (`< n_rows` only on a malformed RG).
        col_dict: The decoded dictionary for this column.

    Returns:
        The resolved column data.

    Raises:
        Error if `n_rows` or `rows_val` is negative, or `codes` holds fewer
        bytes (its length) than the codes it is asked to resolve.
    """
    if n_rows < 0 or rows_val < 0:
        raise Error(
            "gather_flat_clamped: negative row count (n_rows "
            + String(n_rows)
            + ", rows_val "
            + String(rows_val)
            + ")"
        )
    var nv = min(rows_val, n_rows)
    if nv > codes.len() // 4:
        raise Error(
            "gather_flat_clamped: the code buffer holds "
            + String(codes.len())
            + " bytes, fewer than the "
            + String(nv)
            + " codes to resolve"
        )
    var dict_size = len(col_dict)
    var arr = PrimitiveArray[T].allocate_uninitialized(n_rows)
    var out_view = arr.view_mut()
    var out_ptr = out_view._unsafe_ptr().bitcast[Scalar[T]]()
    var cview = codes.view_range_ro(0, nv * 4)
    # SAFETY: `cview` covers nv*4 bytes, checked against the buffer's length
    # above; every read below is bounded by `nv`.
    var cptr = cview._unsafe_ptr().bitcast[Scalar[DType.int32]]()

    var fill = Scalar[T](0)
    if dict_size > 0:
        fill = col_dict[0]

    var blk = 0
    while blk < nv:
        var end = min(blk + _DICT_GATHER_BLOCK, nv)
        if dict_size > 0 and _block_in_bounds(cptr, blk, end, dict_size):
            # FAST: every code in this block is in range, so the per-value
            # compare pair cannot fire. Branchless 4x-unrolled gather.
            var i = blk
            var unroll_end = blk + ((end - blk) >> 2 << 2)
            while i < unroll_end:
                var c0 = Int(cptr.load[width=1](i))
                var c1 = Int(cptr.load[width=1](i + 1))
                var c2 = Int(cptr.load[width=1](i + 2))
                var c3 = Int(cptr.load[width=1](i + 3))
                out_ptr.store[width=1](i, col_dict[c0])
                out_ptr.store[width=1](i + 1, col_dict[c1])
                out_ptr.store[width=1](i + 2, col_dict[c2])
                out_ptr.store[width=1](i + 3, col_dict[c3])
                i += 4
            while i < end:
                out_ptr.store[width=1](i, col_dict[Int(cptr.load[width=1](i))])
                i += 1
        else:
            # SLOW: byte-for-byte the legacy per-value clamping loop, so a
            # malformed row group produces IDENTICAL output.
            for r in range(blk, end):
                var code = Int(cptr.load[width=1](r))
                if code < 0 or code >= dict_size:
                    code = 0
                out_ptr.store[width=1](r, col_dict[code] if dict_size > 0 else Scalar[T](0))
        blk = end

    for r in range(nv, n_rows):
        out_ptr.store[width=1](r, fill)

    _ = cview^
    _ = out_view^
    return arr^
