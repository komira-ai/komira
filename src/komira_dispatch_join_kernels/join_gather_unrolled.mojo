# =============================================================================
# join_gather_unrolled -- the deferred join's gather loops, with the BOOKKEEPING
#                         taken out
# =============================================================================
#
# ⭐ WHAT THIS IS AND WHAT IT IS NOT. It is not a new algorithm, a new memory
# layout, or a change to what the gather touches. It emits the SAME loads, the
# SAME stores and the SAME prefetches, in the same order, over the same
# addresses. What it deletes is the per-element BOOKKEEPING the shipped loop
# pays around them. Every byte of DRAM traffic is unchanged by construction; the
# only quantity that moves is ISSUE SLOTS.
#
# =============================================================================
# THE MEASUREMENT THIS EXISTS TO COLLECT
# =============================================================================
#
# On a high-cardinality join benchmark the output gather was over half of this
# engine's cycle deficit against DuckDB. Disassembled, the two gathers split
# like this (20 workers):
#
#                                 komira       duckdb
#     instructions / element        14           9
#     cycles / element              45.1        25.1
#       -- issue-bound (ins/IPC)    18.7        14.1
#       -- stall residue            26.4        11.0
#
# ⛔ THE STALL RESIDUE IS 77% OF THE GAP AND THIS FILE DOES NOT ADDRESS IT. It
# is a separate, still-open problem (MLP / chain-walk latency). Anything here
# that appears to help it is noise.
# ⭐ THE ISSUE SIDE IS 23% of the gather gap, and that is the whole of what
# this file targets.
#
# =============================================================================
# THE FOUR DEFECTS IN THE SHIPPED LOOP, READ OFF ITS OBJECT CODE
# =============================================================================
#
# The shipped `_gather_fixed_into_range_i32` width-8 arm compiles to a 14-
# instruction body of which THREE do work (`join_deferred_kernels.mojo`):
#
#     .LBB_4:
#       movslq (%r8,%r11,4), %r14      # load the i32 index            WORK
#       movq   (%rsi,%r14,8), %r14     # RANDOM load payload[idx]      WORK
#       movq   %r14, (%rdi,%r11,8)     # store, sequential             WORK
#       leaq   1(%rbx), %r14      \
#       cmpq   %r14, %r10          |   (1) THREE instructions to
#       movq   %rbx, %r11         /        increment ONE counter
#       je     .LBB_5                  # (3) branch 1 of three
#     .LBB_2:
#       movq   %r14, %rbx
#       leaq   16(%r11), %r14     \
#       cmpq   %r9, %r14           |   (3) the prefetch GUARD, in the
#       jge    .LBB_4             /        hot path -- branch 2
#       movslq 64(%r8,%r11,4), %r14    # (2) the index array read a
#       prefetcht0 (%rsi,%r14,8)       #     SECOND time, at +0x40
#       jmp    .LBB_4                  # (3) branch 3
#
#   (1) the induction variable is shuffled between two registers every
#       iteration; DuckDB's counterpart is one `add $0x1,%rbx`.
#   (2) the index array is loaded TWICE per element -- once for the value and
#       once, 16 elements ahead, for the prefetch address.
#   (3) THREE control transfers per element against DuckDB's two, because the
#       `if i + _PF < num` guard forms a diamond inside the loop.
#   (4) no unrolling, so (1) and (3) are paid in full by every element.
#
# =============================================================================
# WHAT THIS FILE DOES INSTEAD, AND WHAT IT DELIBERATELY DOES NOT
# =============================================================================
#
# PEEL the guard: run `[0, num - GATHER_PF)` with an UNCONDITIONAL prefetch and
# `[num - GATHER_PF, num)` with none. That is the SAME SET of prefetches the
# guard selected, issued without asking -- not a re-tuning of the distance.
# UNROLL that body 4x so one `add`/`cmp`/`jb` covers four elements.
#
# ⛔ DEFECT (2) IS NOT FIXED AND CANNOT BE, at this prefetch distance. To use
# one load for both purposes the loop would have to carry 16 indices forward,
# which needs either 16 registers (x86-64 has 16 GPRs total) or a stack ring --
# and a ring pays a store plus a load where the re-read pays a load. The second
# read is an L1 hit on a line the loop touched 16 elements ago; it costs an
# ISSUE SLOT, not a miss. It is 1 of the surviving ~5.75.
#
# ⛔ THE PREFETCH IS KEPT, AT DISTANCE 16, UNCHANGED. The stall residue says 16
# is not sufficient; removing or re-tuning it is a DIFFERENT experiment and
# folding it in here would confound this one. Any distance work belongs in its
# own gated arm.
#
# ⛔ NO HARDWARE GATHER (`vpgatherdq`). It would collapse the instruction count
# and is microcoded at roughly one element per cycle on this class of part, so
# it optimises the number this file reports while plausibly regressing the
# number that matters, the wall. If it is ever tried it must be its own arm
# with its own wall measurement.
#
# =============================================================================
# THE EMITTED CODE -- MEASURED, not predicted
# =============================================================================
#
# x86-64 (`--target-triple x86_64-unknown-linux-gnu`, `-O3`, Mojo 1.0.0), main
# loop only. The baseline column is the SHIPPED loop compiled the same way, and
# it reproduces the profiled binary's 14-instruction body instruction for
# instruction, including the `0x40` displacement on the second index load --
# which is what makes this table an apples-to-apples reading.
#
#     kernel                          before   after   per element
#     ------------------------------------------------------------
#     single column (`gather_unrolled`)   14    5.75    -59%
#     fused pair (`gather_pair_unrolled`) 17    8.75    -49%   (per ELEMENT-PAIR,
#                                                               i.e. two columns)
#
#     .LBB_2:                                   # the 4x body, 23 instructions
#       movslq -12(%r14,%r9,4), %r12  \
#       prefetcht0 (%rdi,%r12,8)       |  4 x (prefetch index + prefetch)
#       ... x4                        /
#       movslq -76(%r14,%r9,4), %r12  \
#       movq   (%rdi,%r12,8), %r12     |  4 x (index + gather + store)
#       movq   %r12, -24(%r15,%r9,8)  /
#       ... x4
#       addq   $4, %r9                 \
#       cmpq   %rbx, %r9                |  ONE increment, ONE branch, per FOUR
#       jb     .LBB_2                  /
#
# The two epilogue loops are 8 instructions/element (the `main` remainder, at
# most 3 iterations) and 6 (the last `GATHER_PF` elements, which carry no
# prefetch in either arm).
#
# ⚠ THE UNROLL FACTOR IS 4 AND WAS CHOSEN AGAINST A MEASUREMENT, not by taste.
# 8x was compiled and counted too: 43/8 = 5.375 instructions/element, i.e. it
# buys a further 0.375 -- ~0.5 cycles/element at the measured IPC, under 1% of
# the gather's 45.1 -- and pays for it with a remainder of up to 7 elements
# instead of 3 on every call. On a slice-heavy workload that is the wrong trade.
# If you change it, re-count the object code; do not assume.
#
# =============================================================================
# ⛔ THE SETTING IS DEFAULT-ON. THE OFF ARM IS THE INCUMBENT
#    LOOP, BYTE FOR BYTE, AND IS THE ROLLBACK
# =============================================================================
#
# Off selects `join_deferred_kernels.mojo`'s existing bodies, untouched; on
# runs the loops here. `join_gather_unroll_enabled()` is read ONCE PER WORK
# ITEM in `_fill_deferred_value_range`, never per record and never per row,
# and is threaded down as a plain `Bool`. The OFF arm therefore pays exactly one
# predictable, perfectly-predicted branch per (record x column x row-range)
# slice -- outside the loop, over a slice of thousands of elements.
#
# ⚠ THAT IS A CLAIM, NOT A MEASUREMENT. An arm verified byte-identical in
# object code can still make its binary slower; `nm -S` proves the code PATH,
# never the TIME.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import alloc, OwnedPointer, UnsafePointer
from std.sys.intrinsics import prefetch, PrefetchOptions

from komira_arrow.column import Column
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.heap_region import HeapRegion


comptime GATHER_PF: Int = 16
"""Prefetch distance, in OUTPUT ROWS. ⛔ IT IS THE SHIPPED VALUE AND MUST STAY
THE SHIPPED VALUE for as long as this lever is under test: the peel is designed
to issue exactly the prefetches the shipped guard `i + _PF < num` selected, so
that an A/B of this file measures BOOKKEEPING and nothing else. Changing it here
silently converts the experiment into a prefetch-distance experiment whose
result would be attributed to the unroll."""

comptime _RO = PrefetchOptions().for_read().high_locality()

comptime _UNROLL: Int = 4
"""See the header: 4 was counted against 8 in object code."""


# =============================================================================
# The gate
# =============================================================================


def join_gather_unroll_enabled() raises -> Bool:
    """DEFAULT-ON. Off runs the incumbent loops in
    `join_deferred_kernels.mojo` instead. The binary sets it once at startup
    from its flag with `configure_join_gather_unroll`; until then it reads ON.

    ⭐ IT EARNED THE DEFAULT ONLY IN COMPANY, AND THAT IS THE WHOLE FINDING.
    Alone this lever deletes 2.22 G instructions/rep and is worth
    **+0.09% of wall, p=0.92** -- a null so flat that three separate readings
    filed it as refuted. It is not refuted; the gather it accelerates is
    BANDWIDTH bound, so its instructions were already free. Paired with
    non-temporal output stores (which delete the RFO and lift the bandwidth
    wall) the same instruction reduction converts, and the pair measures
    **-3.24% on a high-cardinality join, p=0.0008, per-run DISJOINT**.
    ⛔ DO NOT REVERT ONE WITHOUT THE OTHER, and do not re-price either half
    from a solo reading -- a solo reading of either is a KNOWN null.

    ⚠ THE PER-SLICE COUNTER TAX IS PAID ON BOTH ARMS: `note_gather_rolled` on
    the incumbent body, `note_gather_unrolled` here, one relaxed `fetch_add`
    per (record x column x row-range) slice, so this setting moves which of
    the two lines executes -- not whether one does.

    ⚠ READ ONCE PER WORK ITEM by the caller, never inside a kernel: it is an
    atomic load of a process-global slot, a real cost on a per-slice path.
    """
    # SAFETY: as `note_gather_unrolled`.
    var g = _G_UNROLL_ON.get_or_create_ptr()
    return g[][].load() != Int64(0)


# =============================================================================
# The firing observable -- TWO counters, because ONE cannot be falsified
# =============================================================================
#
# ⛔⛔ A SINGLE COUNTER ON THE ARM UNDER TEST CANNOT TELL "THE LEVER DID NOT
# FIRE" FROM "THE ROUTE WAS NEVER ENTERED" -- for example a counter with
# exactly one caller on a route the benchmark does not take. So both arms
# count, in the same unit, at
# the same place -- the point where a loop is entered -- and the readings are
# interpreted as a PAIR:
#
#     unrolled    rolled    reading
#     ---------------------------------------------------------------
#        0          0       ⛔ VOID. No fixed-width gather ran at all;
#                              this says NOTHING about the lever.
#        0         > 0      the lever did not fire. A real negative.
#      > 0          0       the lever served every gathered column-row.
#      > 0        > 0       PARTIAL -- some slice took the other arm.
#                              Investigate; it should not happen, since
#                              the arm is chosen once per work item.
#
# ⭐ AND THE CROSS-ARM CHECK, WHICH IS THE STRONG ONE: over the same query,
# `unrolled` on this file's arm must EQUAL `rolled` on the incumbent. A lever
# that quietly gathered a different number of column-rows is then unstateable,
# which no single-arm counter can achieve.
#
# ⚠ THE UNIT IS COLUMN-ROWS, NOT ROWS. A single-column gather of `n` rows adds
# `n`; the fused pair adds `2n`, because it fills two output columns. Summed
# over a query the total is `sum over gathered columns of that column's rows` --
# which is NOT `defer_out_rows()`, and must not be compared to it directly.
#
# ⚠ ONE RELAXED `fetch_add` PER SLICE, never per element -- AND BOTH ARMS PAY
# IT, SO HERE IS ITS ARITHMETIC RATHER THAN AN ASSURANCE. A slice is a
# (record x column-or-pair x row-range) intersection. `join_deferred_assemble`
# sets `tiles = worker_count * 4`; at 20 workers, 6,511 deferred records over
# 2 index passes give
#
#     slices ~ passes * (records + tiles) = 2 * (6511 + 80) ~ 13,200 per run
#
# i.e. ~13 k contended RMWs on two cache lines, spread across 20 workers,
# against a 1.24 s query -- under 0.1%, and paid IDENTICALLY by both arms, so
# it cannot bias an A/B. It is a permanent cost on the shipped path, one
# `fetch_add` per slice on whichever arm runs. Compare
# `join_deferred_idx.mojo`'s counters, which are per ASSEMBLY (~1) rather than
# per slice.


def _init_ctr() -> OwnedPointer[AtomicI64]:
    # SAFETY: `alloc` returns one uninitialised `AtomicI64` slot, owned by
    # this function until the `OwnedPointer` below takes it. The zero write
    # initialises it through an int64 view of the same bytes (an `AtomicI64`
    # holds one int64). From then on the returned `OwnedPointer` owns the
    # slot and frees it when it is destroyed; `_Global` keeps that
    # `OwnedPointer` in its process-global slot.
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _G_UNROLLED = _Global["komira_join_gather_unrolled_rows", _init_ctr]
comptime _G_ROLLED = _Global["komira_join_gather_rolled_rows", _init_ctr]


def _init_on() -> OwnedPointer[AtomicI64]:
    # SAFETY: as `_init_ctr`, with 1 (ON) written instead of 0.
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](1))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _G_UNROLL_ON = _Global["komira_join_gather_unroll_on", _init_on]


def configure_join_gather_unroll(enabled: Bool) raises:
    """Set `join_gather_unroll_enabled` for this process from the binary's
    flag. Call it once at startup, before any join runs; a later call changes
    the arm of every work item that reads the setting after it."""
    # SAFETY: as `note_gather_unrolled`.
    var g = _G_UNROLL_ON.get_or_create_ptr()
    g[][].store(Int64(1) if enabled else Int64(0))


def note_gather_unrolled(colrows: Int) raises:
    """Column-rows gathered by the loops in THIS file."""
    # SAFETY: `get_or_create_ptr` targets KGEN-runtime
    # static storage; the untracked origin is the stdlib API's own return type
    # and never leaves this frame.
    var g = _G_UNROLLED.get_or_create_ptr()
    _ = g[][].fetch_add(Int64(colrows))


def note_gather_rolled(colrows: Int) raises:
    """Column-rows gathered by the incumbent loops in `join_deferred_kernels`.

    ★ The counter on the arm this file did not change. Read the block above
    before deleting it: without it a zero on the other counter is VOID rather
    than negative."""
    # SAFETY: as `note_gather_unrolled`.
    var g = _G_ROLLED.get_or_create_ptr()
    _ = g[][].fetch_add(Int64(colrows))


def join_gather_unrolled_colrows() raises -> Int:
    """Column-rows served by the unrolled loops."""
    # SAFETY: as `note_gather_unrolled`.
    var g = _G_UNROLLED.get_or_create_ptr()
    return Int(g[][].load())


def join_gather_rolled_colrows() raises -> Int:
    """Column-rows served by the incumbent loops."""
    # SAFETY: as `note_gather_unrolled`.
    var g = _G_ROLLED.get_or_create_ptr()
    return Int(g[][].load())


def reset_join_gather_counters() raises:
    """Reset both counters (test setup)."""
    # SAFETY: as `note_gather_unrolled`.
    var a = _G_UNROLLED.get_or_create_ptr()
    a[][].store(Scalar[DType.int64](0))
    var b = _G_ROLLED.get_or_create_ptr()
    b[][].store(Scalar[DType.int64](0))


# =============================================================================
# The kernels
# =============================================================================
#
# ⭐ ONE BODY, FOUR INSTANTIATIONS. `join_deferred_kernels.mojo` spells its
# gather four times (probe/build x 4-byte/8-byte index) and its file header
# records why: Mojo 1.0.0 will not bind `ref x = a if c else b` over a
# non-ImplicitlyCopyable type, so the SELECTION cannot be hoisted. That
# constraint is about the SELECTION and not about the BODY -- a comptime
# parameter over the index element type binds `List[Int32]` and `List[Int]`
# alike (`Int` is `Scalar[DType.index]`), so the body can be written once. That
# is why this file adds ~2 loops where a spelled-out version would add 8, and
# why editing one arm here cannot leave another behind.


# ⚠ THE PREFETCH IS SPELLED OUT AT ALL SIX SITES RATHER THAN WRAPPED IN A
# ONE-LINE HELPER. A helper would take an `UnsafePointer` across a FUNCTION
# boundary, which the pointer rules ban, and it would be the only new
# raw-pointer parameter site in this file. The stdlib `prefetch` itself takes
# one, which is the same FFI-shaped exception `memcpy` already gets in
# `join_deferred_kernels.mojo` -- so calling it directly is both compliant and
# one indirection shorter.


def gather_unrolled[IT: DType, VT: DType, nt: Bool](
    imm src_col: Column[HeapRegion],
    imm idx: List[Scalar[IT]],
    idx_start: Int,
    num: Int,
    dst_row: Int,
    mut dst: OwnedAlignedBuffer,
) raises:
    """`dst[dst_row + i] = src_col[src_col._offset + idx[idx_start + i]]`.

    Value-identical to `_gather_fixed_into_range`'s typed arms and to
    `_gather_fixed_into_range_i32`'s; see the file header for the loop shape and
    the instruction counts. `IT` is the index element type, `VT` the payload's.

    ⛔ THE PREFETCH SET IS THE SHIPPED ONE. The peel runs `[0, num - GATHER_PF)`
    with a prefetch and the remainder without, which is exactly the partition
    `if i + GATHER_PF < num` induced. If `num <= GATHER_PF` nothing is
    prefetched -- also exactly what the shipped guard did.
    """
    note_gather_unrolled(num)
    # SAFETY: module-internal pointer arithmetic. `idx` is borrowed (`read`), so
    # its origin keeps the List alive for this whole body; the views are held in
    # locals for the same reason, and no pointer here escapes the frame. Same
    # idiom, and same argument, as `_gather_fixed_into_range`'s.
    var ip = idx.unsafe_ptr() + idx_start
    var src_view = src_col._data.view_ro()
    var sp = src_view._unsafe_ptr().bitcast[Scalar[VT]]() + src_col._offset
    var dst_view = dst.view_mut()
    var dp = dst_view._unsafe_ptr().bitcast[Scalar[VT]]() + dst_row

    var main = num - GATHER_PF
    if main < 0:
        main = 0
    var body = main - (main & (_UNROLL - 1))
    var i = 0
    while i < body:
        comptime for k in range(_UNROLL):
            prefetch[params=_RO](
                (sp + Int(ip[i + GATHER_PF + k])).bitcast[
                    Scalar[DType.int64]
                ]()
            )
        comptime for k in range(_UNROLL):
            comptime if nt:
                (dp + i + k).unsafe_store[non_temporal=True](sp[Int(ip[i + k])])
            else:
                dp[i + k] = sp[Int(ip[i + k])]
        i += _UNROLL
    while i < main:
        prefetch[params=_RO](
            (sp + Int(ip[i + GATHER_PF])).bitcast[Scalar[DType.int64]]()
        )
        comptime if nt:
            (dp + i).unsafe_store[non_temporal=True](sp[Int(ip[i])])
        else:
            dp[i] = sp[Int(ip[i])]
        i += 1
    while i < num:
        comptime if nt:
            (dp + i).unsafe_store[non_temporal=True](sp[Int(ip[i])])
        else:
            dp[i] = sp[Int(ip[i])]
        i += 1
    _ = ip
    _ = src_view
    _ = dst_view


def gather_pair_unrolled[IT: DType, VT: DType, nt: Bool](
    imm src_a: Column[HeapRegion],
    imm src_b: Column[HeapRegion],
    imm idx: List[Scalar[IT]],
    idx_start: Int,
    num: Int,
    dst_row: Int,
    mut dst_a: OwnedAlignedBuffer,
    mut dst_b: OwnedAlignedBuffer,
) raises:
    """The fused two-column form; value-identical to `_gather_pair_into_range*`.

    The index is read ONCE for both columns -- which is the fused kernel's whole
    point and is preserved here -- and the two prefetches for element `i +
    GATHER_PF` are issued off ONE index load, exactly as the shipped loop does.
    """
    note_gather_unrolled(2 * num)
    # SAFETY: as `gather_unrolled` above -- borrowed origins, views in locals,
    # nothing escapes the frame.
    var ip = idx.unsafe_ptr() + idx_start
    var va = src_a._data.view_ro()
    var sa = va._unsafe_ptr().bitcast[Scalar[VT]]() + src_a._offset
    var vb = src_b._data.view_ro()
    var sb = vb._unsafe_ptr().bitcast[Scalar[VT]]() + src_b._offset
    var wa = dst_a.view_mut()
    var da = wa._unsafe_ptr().bitcast[Scalar[VT]]() + dst_row
    var wb = dst_b.view_mut()
    var db = wb._unsafe_ptr().bitcast[Scalar[VT]]() + dst_row

    var main = num - GATHER_PF
    if main < 0:
        main = 0
    var body = main - (main & (_UNROLL - 1))
    var i = 0
    while i < body:
        comptime for k in range(_UNROLL):
            var p = Int(ip[i + GATHER_PF + k])
            prefetch[params=_RO]((sa + p).bitcast[Scalar[DType.int64]]())
            prefetch[params=_RO]((sb + p).bitcast[Scalar[DType.int64]]())
        comptime for k in range(_UNROLL):
            var ix = Int(ip[i + k])
            comptime if nt:
                (da + i + k).unsafe_store[non_temporal=True](sa[ix])
                (db + i + k).unsafe_store[non_temporal=True](sb[ix])
            else:
                da[i + k] = sa[ix]
                db[i + k] = sb[ix]
        i += _UNROLL
    while i < main:
        var p2 = Int(ip[i + GATHER_PF])
        prefetch[params=_RO]((sa + p2).bitcast[Scalar[DType.int64]]())
        prefetch[params=_RO]((sb + p2).bitcast[Scalar[DType.int64]]())
        var ix2 = Int(ip[i])
        comptime if nt:
            (da + i).unsafe_store[non_temporal=True](sa[ix2])
            (db + i).unsafe_store[non_temporal=True](sb[ix2])
        else:
            da[i] = sa[ix2]
            db[i] = sb[ix2]
        i += 1
    while i < num:
        var ix3 = Int(ip[i])
        comptime if nt:
            (da + i).unsafe_store[non_temporal=True](sa[ix3])
            (db + i).unsafe_store[non_temporal=True](sb[ix3])
        else:
            da[i] = sa[ix3]
            db[i] = sb[ix3]
        i += 1
    _ = ip
    _ = va
    _ = vb
    _ = wa
    _ = wb
