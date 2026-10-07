# =============================================================================
# join_gather_narrow — the 2-byte and 1-byte typed-store gather arms
# =============================================================================
#
# WHAT THIS IS. `join_deferred_kernels.mojo` specialised `width == 8` and
# `width == 4` onto a typed-store + 16-ahead-prefetch loop and dropped every
# other width into an `else:` that copies `width` bytes per row through
# `view_range_mut / copy_from_view_at`. This file supplies the SAME LOOP for
# widths 2 and 1, so a narrowed payload column reaches a typed store instead of
# a per-row byte copy.
#
# ⭐ WHY IT MATTERS, MEASURED, NOT ASSUMED
# (a high-cardinality join benchmark, 20 workers on one NUMA node, three
# value-identical fixtures differing only in the physical width of the two
# non-key columns, 6/6 block medians disjoint):
#
#     payload    out B/row    wall        DRAM bytes
#     BIGINT 8       32       —           —
#     INTEGER 4      24       -7.83%      -7.85%     <- hits the 4-byte arm
#     SMALLINT 2     20       +6.99%      +4.07%     <- fell into the memcpy
#
# The 2-byte fixture moves strictly FEWER useful bytes than the 8-byte one (peak
# RSS -21.4%) and was still 7% slower, on a cell where DuckDB is flat across all
# three fixtures. The per-row copy was the only structural difference. This file
# is the treatment.
#
# ⛔ THE 8-BYTE AND 4-BYTE ARMS ARE DELIBERATELY NOT ROUTED THROUGH HERE. They
# could be — the body below is generic over `VT` and would bind `int64` /
# `int32` — and it was written that way first and then reverted. The reason is
# that this change's whole falsifier is a WALL-CLOCK A/B whose CONTROL arm is
# the shipped 8-byte and 4-byte path. Re-spelling those two loops, however
# faithfully, puts "did the control arm's codegen move?" inside the measurement,
# and there is no cheap instrument that answers it. The arms stay byte-identical
# to what shipped; this file is purely additive. Collapsing the four into one
# generic body is a legitimate follow-up — AFTER the A/B is banked, and with its
# own before/after instruction count.
#
# ⚠ THE `nt` PARAMETER IS HONOURED IN SPELLING AND IS A NO-OP BELOW 4 BYTES ON
# x86. `movnti` exists at 32 and 64 bits only, so an `!nontemporal` i16/i8 store
# lowers to an ordinary store and the write-combining path is not taken. The
# spelling is kept so the arms do not silently diverge from their 8/4 siblings,
# but `note_nt_out_write`'s byte total is a REQUEST at these widths, not an
# achievement — which is consistent with that counter's own header ("the counter
# is a model"), and is stated here so nobody reads a narrow-column NT byte count
# as evidence of write-combining.
#
# ⛔ AND THAT CAVEAT IS LOAD-BEARING ON THE SHIPPED PATH. Non-temporal stores
# are the default, so the `comptime if nt` arms
# below are what production takes -- and at widths 2 and 1 they are the
# ORDINARY store, by the `movnti` argument above. Two consequences, neither of
# which is a defect:
#   * a narrow column contributes to `nt_out_bytes_modelled` while contributing
#     NOTHING to the RFO deletion the lever is priced on. A join that gathers
#     one 2-byte column of 100M rows (`gather_narrow_typed`) models ~2 of its
#     18 B/row as a request the hardware declines. Price the NT lever off
#     `CAS_COUNT.RD`, never off this counter -- it already over-predicted the
#     measured DRAM read reduction by 2.6x before this term was counted.
#   * the width-2/1 arms are therefore NOT a measurable part of the NT half of
#     the flip. They ARE a measurable part of the UNROLL half, which is generic
#     over the payload type and real at every width.
#
# ⚠ THE PREFETCH DISTANCE IS 16 OUTPUT ROWS, UNSCALED — the same constant and
# the same reasoning as `_gather_fixed_into_range_i32`'s header. It is a
# distance in ROWS, not in bytes; the source stride is the SOURCE column's, and
# narrowing the payload is exactly what changed that stride. Re-tuning it here
# would fold a second, unmeasured variable into the A/B this file exists to
# make readable. `GATHER_PF` is imported rather than re-declared so the two
# files cannot drift.
#
# ⭐ ONE BODY, EIGHT INSTANTIATIONS — the same trick `join_gather_unrolled.mojo`
# documents. `join_deferred_kernels.mojo` must spell its SELECTION four times
# (probe/build x 4-byte/8-byte index) because Mojo 1.0.0 will not bind
# `ref x = a if c else b` over `Column` or `List[Int]`. That constraint is about
# the selection and not about the BODY: a comptime parameter over the index
# element type binds `List[Int32]` and `List[Int]` alike (`Int` is
# `Scalar[DType.index]`), so two bodies here cover four kernels x two widths.
# =============================================================================

from std.memory import UnsafePointer
from std.sys.intrinsics import prefetch, PrefetchOptions

from komira_arrow.column import Column
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_column_kernels.gather_width_counter import gather_note_narrow_typed
from komira_buffer.heap_region import HeapRegion

from komira_dispatch_join_kernels.join_gather_unrolled import GATHER_PF


comptime _RO = PrefetchOptions().for_read().high_locality()


def gather_narrow_rolled[IT: DType, VT: DType, nt: Bool](
    imm src_col: Column[HeapRegion],
    imm idx: List[Scalar[IT]],
    idx_start: Int,
    num: Int,
    dst_row: Int,
    mut dst: OwnedAlignedBuffer,
) raises:
    """`dst[dst_row + i] = src_col[src_col._offset + idx[idx_start + i]]`.

    Value-identical to `_gather_fixed_into_range`'s width-8 and width-4 arms and
    to the per-row copy it replaces; `IT` is the index element type, `VT` the
    payload's (`int16` at width 2, `int8` at width 1). The loop shape — one
    16-ahead prefetch under `i + GATHER_PF < num`, then one typed store — is
    the shipped rolled shape, deliberately, so the only variable between the
    control and treatment fixtures is the STORE.

    ⛔ `VT` MUST MATCH THE CALLER'S `width` EXACTLY. The pointers are bitcast to
    `Scalar[VT]` and indexed in ELEMENTS, so a mismatched `VT` does not copy the
    wrong number of bytes — it addresses the wrong SOURCE ROW, producing a wrong
    answer with a correct row count, a correct schema and a clean null bitmap.
    That is the one failure shape no value oracle in this repo can see, which is
    why the width dispatch lives at the four call sites (where `width` is in
    hand) rather than being re-derived here from `VT`.
    """
    gather_note_narrow_typed(num)
    # SAFETY: module-internal pointer arithmetic. `idx` is borrowed (`read`), so
    # its origin keeps the List alive for this whole body; the views are held in
    # locals for the same reason, and no pointer here escapes the frame. Same
    # idiom, and same argument, as `_gather_fixed_into_range`'s.
    var ip = idx.unsafe_ptr() + idx_start
    var src_view = src_col._data.view_ro()
    var sp = src_view._unsafe_ptr().bitcast[Scalar[VT]]() + src_col._offset
    var dst_view = dst.view_mut()
    var dp = dst_view._unsafe_ptr().bitcast[Scalar[VT]]() + dst_row

    for i in range(num):
        if i + GATHER_PF < num:
            prefetch[params=_RO](
                (sp + Int(ip[i + GATHER_PF])).bitcast[Scalar[DType.int64]]()
            )
        comptime if nt:
            (dp + i).unsafe_store[non_temporal=True](sp[Int(ip[i])])
        else:
            dp[i] = sp[Int(ip[i])]
    _ = ip
    _ = src_view
    _ = dst_view


def gather_pair_narrow_rolled[IT: DType, VT: DType, nt: Bool](
    imm src_a: Column[HeapRegion],
    imm src_b: Column[HeapRegion],
    imm idx: List[Scalar[IT]],
    idx_start: Int,
    num: Int,
    dst_row: Int,
    mut dst_a: OwnedAlignedBuffer,
    mut dst_b: OwnedAlignedBuffer,
) raises:
    """The fused two-column form; value-identical to `gather_narrow_rolled` run
    twice.

    The index is read ONCE for both columns — the fused kernel's whole point,
    and the reason the pair kernel's own width gate has to admit widths 2 and 1
    as well. `_fill_deferred_value_range_pair_impl` guarantees both members are
    on the same side and of the same width before reaching here.
    """
    gather_note_narrow_typed(2 * num)
    # SAFETY: module-internal pointer arithmetic; see `gather_narrow_rolled`.
    var ip = idx.unsafe_ptr() + idx_start
    var va = src_a._data.view_ro()
    var sa = va._unsafe_ptr().bitcast[Scalar[VT]]() + src_a._offset
    var vb = src_b._data.view_ro()
    var sb = vb._unsafe_ptr().bitcast[Scalar[VT]]() + src_b._offset
    var vda = dst_a.view_mut()
    var da = vda._unsafe_ptr().bitcast[Scalar[VT]]() + dst_row
    var vdb = dst_b.view_mut()
    var db = vdb._unsafe_ptr().bitcast[Scalar[VT]]() + dst_row

    for i in range(num):
        if i + GATHER_PF < num:
            var p = Int(ip[i + GATHER_PF])
            prefetch[params=_RO]((sa + p).bitcast[Scalar[DType.int64]]())
            prefetch[params=_RO]((sb + p).bitcast[Scalar[DType.int64]]())
        var ix = Int(ip[i])
        comptime if nt:
            (da + i).unsafe_store[non_temporal=True](sa[ix])
            (db + i).unsafe_store[non_temporal=True](sb[ix])
        else:
            da[i] = sa[ix]
            db[i] = sb[ix]
    _ = ip
    _ = va
    _ = vb
    _ = vda
    _ = vdb
