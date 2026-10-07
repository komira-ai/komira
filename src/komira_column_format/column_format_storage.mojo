# =============================================================================
# column_format_storage.mojo — Column UNTYPED v0.4 Phase C-G.1 primitive
# =============================================================================
#
# Per-column contiguous hash-slot storage for the Column UNTYPED quadrant.
# Sister primitive to Row UNTYPED's `RowBlock` at
# an internal module; mirrors its encapsulation
# contract (no raw UnsafePointer in any public signature) but differs in
# layout:
#
#   RowBlock          : ONE  fixed-row-stride buffer + ONE  var-storage blob.
#   ColumnFormatStorage: N    per-col fixed buffers   + N    per-var-col
#                              descriptors + N per-var-col data heaps +
#                              N per-col validity bitmaps.
#
# Storage rationale (Column UNTYPED v0.4 §3.3):
#   - Per-col contiguous fixed buffers (`MmapAlignedBuffer[64]`) keep per-batch
#     SIMD kernels firing without per-row stride hopping (the column-format
#     win over RowBlock for streaming).
#   - Var-width cols (STRING / BINARY) hold per-slot `(offset: Int32,
#     length: Int32)` descriptor cells in their fixed buffer slot AND
#     payload bytes in a per-col var-data heap. The descriptor cell is 8B
#     fixed-width regardless of payload length, so the per-slot offset
#     arithmetic stays uniform with the fixed-width path.
#   - Validity bitmaps are per-col 1-bit-per-slot, packed LSB-first
#     (Arrow convention).
#
# Phase C-G.1 scope (this file):
#   - Fixed-DType cells: I64 / F64 / I32 / F32 / I16 / I8 / U8 / U16 /
#     U32 / U64 / Date32 / Date64 / Bool / Timestamp_{ns,us,ms,s} /
#     Decimal128 — all routed through `MmapAlignedBuffer.get_typed/set_typed`
#     + `read_*_at/write_*_at` accessors.
#   - Var-width STRING / BINARY: writer/reader STUBs that raise pending
#     `STRINGCOLUMNVIEW-SUBSTRATE-V04` slot landing (the BatchView
#     `col_str()/col_binary()` accessors aren't published yet). Storage
#     fields ARE pre-allocated so dispatch through `kind == COL_VAR_*`
#     reaches the var-path without out-of-range index errors; only the
#     batch-side encode/decode raises.
#   - Validity bitmap allocation per validity-tracked col; bit
#     read/write helpers are file-internal scaffolding (full validity
#     propagation lands in Phase C-G.2 alongside the dispatch table).
#   - Phase C-G.7 nested types (LIST / STRUCT / MAP) are out of scope
#     for Phase C-G.1.
#
# Encapsulation invariants (mirror RowBlock):
#   * Zero UnsafePointer in any public signature.
#   * Zero wildcard origins (no MutExternalOrigin / MutAnyOrigin).
#   * Zero unsafe_from_address.
#   * Zero ArcPointer.
#   * Storage is Movable, not Copyable (matches MmapAlignedBuffer + Slab).
#   * Per-col fixed-buffer access is bounded by capacity-tracked slot
#     counts; growth is amortized-doubling with copy-on-grow.
#
# Coexistence note: this primitive is the UNTYPED-Column quadrant's
# hash-slot store. The TYPED-Column variadic primitives
# (HashAggTable[KB, *Aggs], JoinBuildTable[KB, *Payload]) continue to
# own the TYPED quadrant and do NOT use this storage. Cost-based
# routing per Column UNTYPED v0.4 §5.3 selects the path.
#
# Sequencing pin: Phase C-G.2 (HashAggTable_Untyped) consumes this
# primitive; Phase C-G.5 (dispatch table) consumes both. Phase C-G.7
# (nested types) extends `kind` enum with COL_NESTED — additive.
#
# References:
#   * Column UNTYPED v0.4 design memo:
#       an internal doc §3.1 + §3.3.
#   * Sister precedent (RowBlock):
#       an internal module.
#   * MmapAlignedBuffer:
#       an internal module.
#   * BatchView typed accessors:
#       an internal module.
#   * Spike 1 e2e POC (HashAggTable_Untyped pattern):
#       the poc_hash_agg_untyped_e2e probe (commit ``).
#   * Phase C-G.1 substrate POC (this file's pattern validation):
#       the poc_column_format_storage probe.
# =============================================================================

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_arrow.batch_view import BatchView
from komira_buffer.byte_view import ByteView
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion
from komira_simd.byte_class.byte_equal import bytes_equal


# -----------------------------------------------------------------------------
# Column-kind constants (Column UNTYPED v0.4 §3.1 ColDescriptor.kind)
#
# Mirror the Row UNTYPED set at `row_block.mojo:84-94` so the SDK
# lowering surface is uniform across both quadrants.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# ⭐⭐ S2-VARGROW4 (2026-09-22) — THE VAR-DATA ARENA GROWTH FACTOR.
#
# WHAT THIS IS AIMED AT, MEASURED. `_grow_var_heap`'s copy-forward is the
# single most expensive INSTRUCTION PAIR in ClickBench cbq34 by DRAM-miss share
# and by long-latency-load share:
#
#   * `bench/results/a5_residual_0922/DERIVED.txt` §1 -- "arena-GROWTH copy
#     0x2bb0880/85  ours 2.10 core-s  duck 0.00  +2.10", the largest of the two
#     MECHANISM-ABSENCE rows in the whole two-engine ledger (DuckDB never
#     copies its heap: fixed 256 KB blocks, `tuple_data_allocator.cpp:242-297`,
#     and `Combine` splices block pointers rather than copying,
#     `tuple_data_collection.cpp:479-491`).
#   * `bench/results/a5_residual_0922/raw/thor_cyc.txt` -- `reserve_var_bytes`
#     is 5.26% of our cycles and **68.67% of the symbol sits on two
#     instructions**: `vmovups %ymm0,(%r14,%rdx,1)` 56.08% and `add $0x20,%rdx`
#     12.59%. That pair IS this memcpy.
#   * `t7_measure_0922/raw/m2` (PEBS `mem_load_uops_retired.l3_miss:pp`) --
#     the copy's READ carries **23.3% of every DRAM load miss in the query**.
#
# ⛔ AND WHY A BIGGER FACTOR IS NOT A "FEWER COPIES" TWEAK. For a geometric
# ladder with factor k from a small floor to a final used size S, the TOTAL
# BYTES COPIED is not dominated by the number of steps -- it is
#
#       total_copied = C/(k-1)   where C is the final capacity, C in [S, kS)
#       E[total_copied] / S = 1/ln k        E[C]/S = (k-1)/ln k
#
# so k=2 copies **1.443 S** and k=4 copies **0.721 S** -- HALF the bytes, not
# "the same last copy with fewer small ones". The theoretical price is the
# other half of the same identity: expected peak CAPACITY goes 1.443 S ->
# 2.164 S, i.e. +50% of the arena's own bytes. That is why the floor exists and
# why this is k=4 rather than k=8 (copy 0.481 S, peak 3.37 S).
#
# ⭐ MEASURED on a 2 x E5-4669 v4 host (20 workers). STATIC FALSIFIER FIRST: the two binaries' `_grow_var_heap`
# differ by exactly `cmp $0x100000,%rax ; setge %dl ; inc %dl ; shlx %rdx,%rax`
# replacing `add %rax,%rax` -- LLVM lowers the floor BRANCHLESSLY, to a variable
# shift of 1 or 2 -- with the 32-byte copy loop itself byte-identical in both.
# Then 4 ABBA rounds x 3 reps, `perf stat` over a TREATED-ONLY manifest so the
# control cannot dilute the counter:
#
#   cbq33+cbq34   cycles -3.952% DISJOINT · instructions -0.669% DISJOINT
#                 task-clock -3.924% DISJOINT · IPC (ins/cyc) 1.0757 -> 1.1125
#                 wall cbq34 -3.88%, cbq33 -2.68% (DISJOINT)
#   base-vs-base  cycles +0.767%, instructions +0.106% -- the instrument FLOOR
#   cbq15 CONTROL (INT64 key, `_grow_var_heap` structurally unreachable):
#                 cycles -0.635% / instructions -0.176%, BOTH overlapping, and
#                 SMALLER than that cell's own base-vs-base drift. INERT.
#   cbq16 (0.607 GB of key bytes vs cbq33's 3.374, i.e. a 5.6x smaller ladder):
#                 cycles -0.747%. The effect SCALES WITH KEY-BYTE VOLUME, which
#                 is the model's own prediction and not something it was fitted
#                 to. cbq21 (var-width MIN(url), the SECOND arena) -0.081%.
#   PEAK RSS      per query, each cell in its OWN process: cbq34 -0.25%,
#                 cbq33 +0.12%, cbq16 -0.21%, cbq21 -3.54%, cbq15 -0.29% --
#                 every one inside its own base-vs-base floor. ⚠ The predicted
#                 +50% DOES NOT APPEAR: arena capacity is a minority of a
#                 query's RSS, and the 2x ladder holds `old + new` live at every
#                 copy while the 4x one does it half as often.
#   ⚠ ONE RESIDUAL, AND IT IS REAL: on a TWELVE-cell single-process manifest the
#                 treated arm's CUMULATIVE process high-water ran 6-13% above
#                 base. Per-query peak is flat; what moves is allocator reuse
#                 ACROSS queries in one process. The corpus scoreboard is such a
#                 process, so a whole-sweep RSS reading will show it.
#
# ⭐ THE WIN IS BIGGER THAN THIS FUNCTION'S OWN SELF-TIME, AND THE PROFILE SAYS
# WHY: HALF OF IT IS IN SYMBOLS THAT NEVER TOUCH THE ARENA. Symbol-level
# `perf record -e cycles` on both binaries (raw/k8/prof_k{2,4}.txt), shares
# converted to ABSOLUTE cycles with each run's own event count first:
#
#   _grow_var_heap                22.321 -> 9.335 Gcyc  -12.986  (52.8% of it)
#   _probevec_pass1_planned       39.114 -> 34.678       -4.436
#   write_slot_str_from_storage   39.378 -> 35.582       -3.796
#   _hash_single_col              55.697 -> 53.197       -2.500
#   _upsert_one_row_prehashed     70.385 -> 68.403       -1.981
#   duckdb_snappy DecompressAllTags 63.278 -> 62.281     -0.997
#
# The last row is the decisive one: the SNAPPY DECOMPRESSOR has no code-level
# coupling to a group-key arena, so it can only have got cheaper through the
# memory system. ⇒ the arena copy costs roughly as much AGAIN in other symbols
# as it costs in itself, and the whole class is ~5 core-s, not the 2.10 a
# non-precise per-instruction attribution could see.
#
# ⛔ k=8 WAS BUILT AND MEASURED AND IS REFUSED. The identity says k=8 copies
# 0.481 S against k=4's 0.721 S, so a linear-in-copied-bytes reading predicts
# another -1.9%. MEASURED (4 ABBA rounds x 3 reps): k=8 is **+1.419% cycles vs
# k=4**, executes **MORE instructions than k=2** (+0.288% DISJOINT), and
# **DOUBLES peak RSS** (14.15 -> 29.65 GB on cbq33). ⇒ **k=4 IS THE KNEE. DO NOT
# RAISE THIS FACTOR.** Buying fewer copies with more memory is exhausted here.
#
# ⚠ THIS BUYS A FRACTION, BY CONSTRUCTION, AND IS NOT THE END STATE -- but its
# residual is UNPRICED, not "about another -4%" (that extrapolation is what k=8
# falsified). The mechanism that removes the remaining 0.721 S is a SEGMENTED
# arena that never moves a byte on growth (DuckDB's shape: fixed blocks,
# bump-allocated, spliced rather than copied on combine). Unlike k=8 it does not
# pay for its bytes with RSS -- an exponentially-segmented arena's expected
# capacity overshoot is the same ~1.44x as doubling's and it never holds
# `old + new` live at once. ⛔ Do not read this landing as a reason to stop, and
# do not read k=8's refusal as a reason not to try that.
# -----------------------------------------------------------------------------

comptime VAR_HEAP_QUAD_GROWTH_FLOOR_BYTES: Int = 1 << 20
"""Arena capacity at or above which `_grow_var_heap` grows by 4x, not 2x.

1 MiB. BELOW it nothing changes: the thousands of small per-partition arenas
in a low-cardinality aggregate (64 sub-tables x N workers, most of them tiny)
keep the shipped 2x ladder and pay no extra capacity at all. The floor is
compared against the CURRENT capacity, so the first growth past it is
1 MiB -> 4 MiB.

⚠ ONE POLICY, TWO ARENAS. `HashAggTable_Untyped._var_arena_reserve` is the
var-width MIN/MAX payload arena and mirrors this function arm for arm on
purpose -- "a second growth policy is a second thing to get wrong". It reads
THIS constant; do not fork it."""


# -----------------------------------------------------------------------------
# ⭐⭐ VARHEAP-OFFSET-CEILING (2026-09-22) — THE 32-BIT FIELD THE 64-BIT ARENA
# CURSOR IS WRITTEN INTO, AND THE ONE PLACE IT IS CHECKED.
#
# A var-width slot is an 8-BYTE DESCRIPTOR CELL, `(length << 32) | (offset &
# 0xFFFFFFFF)`, with the bytes at `var_data_heaps[vi][offset : offset+length]`.
# Both halves are 32 bits. The arena they address is a 64-bit `Int` cursor
# (`var_data_used`) over a 64-bit capacity, and until this constant existed
# NOTHING compared the one against the other at any of the three writers.
#
# ⛔ A WRAP HERE IS A SILENT WRONG ANSWER, NOT A CRASH, AND THAT IS WHY IT IS
# GUARDED RATHER THAN DOCUMENTED. The payload is written at the TRUE cursor, so
# no byte is lost and no read leaves the allocation — a truncated offset is by
# construction SMALLER than the true one, hence always inside the live arena.
# Every bounds check, every `var_data_used` re-validation (the drain's
# `copy_str_run_into`) and every row-count assertion therefore still passes.
# What changes is WHICH BYTES a key cell names: key EQUALITY then compares a
# probe against a DIFFERENT group's payload (so rows join the wrong group, or
# split into a duplicate one), and the DRAIN publishes those other bytes as the
# group's key. Nothing downstream can tell that from a correct run.
#
# ⛔ THIS IS NOT `ARROW_INT32_OFFSET_MAX`. That one is 2_147_483_647 — SIGNED,
# 2**31-1, on the OUTPUT column — and it is already guarded from dozens of call
# sites by `check_int32_offsets` / `should_promote_offsets`, whose failure is a
# loud named `ArrowOffsetOverflow` and whose shipped emit path PROMOTES to
# `large_string` instead. This one is internal, UNSIGNED, 2**32, and had no
# guard at all. Do not "reconcile" the two constants.
#
# WHERE THE CHECK LIVES, AND WHY THERE. `reserve_var_bytes` is the ONE choke
# point all three writers (`write_slot_str`, `write_slot_str_from_byteview`,
# `write_slot_str_from_storage`) call BEFORE they read the cursor, and it
# already computes `used + additional`. Checking there costs one compare
# against a compile-time constant per var-payload APPEND — O(distinct groups),
# not O(rows) — on a branch that is never taken, and it refuses BEFORE the
# multi-GiB allocation the overflowing append would otherwise make.
# `_var_desc_pack` carries the same verdict as the last line of defence for any
# future writer that does not come through `reserve_var_bytes`.
#
# ⚠ THE GUARD IS CONSERVATIVE BY EXACTLY ONE APPEND, DELIBERATELY. It refuses
# when the RESULTING cursor would not fit, not when the offset being recorded
# would not fit, so after every admitted append `used <= VAR_DESC_OFFSET_MAX`
# and therefore BOTH `offset` (the cursor before) and `length` (which is at
# most the cursor after) are exactly representable. Checking only the recorded
# offset would admit one final cell whose `offset + length` no reader could
# address.
#
# ⚠ WHAT THIS IS *NOT* A FIX FOR: the arena stays 4 GiB-bounded PER
# `ColumnFormatStorage`. Raising the bound is a descriptor-layout change (a
# 16-byte cell, or a narrower length field bought against a wider offset, or
# the segmented arena the growth-factor block above argues for) and it has to
# be priced against the key-cell layout this campaign has been measuring. Until
# then a query that genuinely needs more than 4 GiB of key bytes in ONE arena
# gets a loud refusal instead of a wrong answer. That is the trade this makes.
# -----------------------------------------------------------------------------

comptime VAR_DESC_OFFSET_MAX: Int = 0xFFFFFFFF
"""Largest byte offset (and largest payload length) a var-width descriptor
cell can represent: 4_294_967_295.

UNSIGNED 32 bits, because the pack masks with `0xFFFFFFFF` and
`read_slot_str_bytes` and friends recover it with the same mask into a
non-negative `Int`. ⛔ NOT `ARROW_INT32_OFFSET_MAX` (2_147_483_647, signed) —
see the block above before reconciling them."""


@no_inline
def _raise_var_heap_offset_ceiling(used: Int, additional: Int) raises:
    """Cold: a var-heap append whose resulting cursor would not fit the
    descriptor's 32-bit offset field."""
    raise Error(
        "ColumnFormatStorage: var-heap append would put the arena cursor at "
        + String(used + additional)
        + " bytes, past the "
        + String(VAR_DESC_OFFSET_MAX)
        + "-byte ceiling of the var-width descriptor cell's 32-bit offset"
        " field (used="
        + String(used)
        + ", additional="
        + String(additional)
        + "). Refused rather than truncated: a wrapped offset stays inside the"
        " live arena, so it would silently name ANOTHER GROUP'S BYTES instead"
        " of raising."
    )


@always_inline
def _var_desc_pack(offset: Int, length: Int) raises -> UInt64:
    """THE var-width descriptor cell: low 4 bytes offset, high 4 bytes length.

    One implementation, shared by all three writers, because two copies of a
    bit-pack is exactly how one of them ends up with a different layout.

    Raises:
        On either half not being representable in its 32-bit field. In a table
        fed through `reserve_var_bytes` this is unreachable (that guard is
        strictly stronger); it is here for any writer that is not.
    """
    if (
        offset < 0
        or length < 0
        or offset > VAR_DESC_OFFSET_MAX
        or length > VAR_DESC_OFFSET_MAX
    ):
        _raise_var_heap_offset_ceiling(offset, length)
    return (UInt64(length) << 32) | (UInt64(offset) & UInt64(0xFFFFFFFF))


comptime COL_FIXED: UInt8 = 1
"""Fixed-width column kind (I64/F64/I32/F32/I16/I8/U8/U16/U32/U64/
Date32/Date64/Bool/Timestamp_*/Decimal128)."""

comptime COL_VAR_STRING: UInt8 = 2
"""Variable-width UTF8 string column kind. Payload bytes live in
`ColumnFormatStorage.var_data_heaps[var_idx]`; per-slot `(offset,
length)` descriptor lives in the per-col fixed buffer."""

comptime COL_VAR_BINARY: UInt8 = 3
"""Variable-width binary blob column kind. Same descriptor + heap
layout as COL_VAR_STRING."""

comptime COL_DECIMAL128: UInt8 = 4
"""128-bit decimal column kind (modeled as 2 sequential UInt64 cells
in the per-col fixed buffer; see Column UNTYPED v0.4 §3.2). Reuses
the BatchView `col_decimal128_lo/hi` accessor pair."""

comptime COL_NESTED: UInt8 = 5
"""Nested column kind (LIST / STRUCT / MAP). Routed via Arrow Row
format encoding per Column UNTYPED v0.4 §3.6.2. Phase C-G.7 scope —
this Phase C-G.1 primitive treats COL_NESTED storage as a STUB that
raises on encode/decode; the dispatch table at Phase C-G.5 wires
nested encoders when Phase C-G.7 lands."""


# -----------------------------------------------------------------------------
# DType-tag constants (Column UNTYPED v0.4 §3.1 ColDescriptor.dtype_tag)
#
# Mirror Row UNTYPED's `row_block.mojo:105-117` set + extension to the
# 21-DType v0.4 coverage. The dtype_tag discriminates within COL_FIXED
# (e.g. COL_FIXED + DT_I64 -> 8B I64 cells; COL_FIXED + DT_DATE32 ->
# 4B i32 cells).
# -----------------------------------------------------------------------------

comptime DT_I64: UInt8 = 1
comptime DT_F64: UInt8 = 2
comptime DT_I32: UInt8 = 3
comptime DT_F32: UInt8 = 4
comptime DT_I16: UInt8 = 5
comptime DT_I8: UInt8 = 6
comptime DT_U8: UInt8 = 7
comptime DT_STRING: UInt8 = 8
comptime DT_U16: UInt8 = 9
comptime DT_U32: UInt8 = 10
comptime DT_U64: UInt8 = 11
comptime DT_DATE32: UInt8 = 12
comptime DT_DECIMAL128: UInt8 = 13
comptime DT_BOOL: UInt8 = 14
comptime DT_DATE64: UInt8 = 15
comptime DT_TIMESTAMP_NS: UInt8 = 16
comptime DT_TIMESTAMP_US: UInt8 = 17
comptime DT_TIMESTAMP_MS: UInt8 = 18
comptime DT_TIMESTAMP_S: UInt8 = 19
comptime DT_BINARY: UInt8 = 20
comptime DT_NONE: UInt8 = 0
"""DT_NONE marks an absent input — e.g. COUNT(*) has no input DType."""


# -----------------------------------------------------------------------------
# ⭐⭐ STRHASH8 (2026-09-21) — THE VAR-WIDTH KEY HASH, EIGHT BYTES PER MULTIPLY.
#
# WHAT IT REPLACES. Every var-width group/join key byte in this engine used to
# go through FNV-1a: `h = (h ^ byte) * PRIME`, ONE 64-bit multiply PER BYTE, a
# fully serialised chain of 3-cycle-latency `mul`s. On a ~70-byte ClickBench
# `url` key that is 70 dependent multiplies per row. DuckDB's `HashBytes`
# (an internal module of DuckDB v1.5.5) consumes EIGHT bytes
# per multiply. Two independent WAVE-6 diagnosis lanes measured our chain as
# the #1 symbol of cbq33/cbq34 (`_hash_single_col` 31.2% of busy CPU) and
# priced the swap at -23..-28% of those cells' wall on the mac
# (`bench/results/q34w6_0921/`, `bench/results/cbq33*`). Neither landed it.
#
# ⛔⛔ EVERY PRODUCER OF THIS HASH MOVES TOGETHER OR A GROUP SPLITS INTO A
# WRONG ANSWER — AND IT IS SILENT. The hash VALUE changes, and two sides of
# every keyed table have to agree on it:
#
#   table                     batch side                     stored side
#   ------------------------  -----------------------------  -----------------
#   HashAggTable_Untyped      `_hash_string_view`,           `slot_str_fnv1a`
#                             `_string_dict_hash_cell`,      (grow rehash)
#                             `_fnv1a_dict_bytes` (cache)
#   JoinBuildTable_Untyped    `_hash_string_view` (join)     `slot_str_fnv1a`
#   DistinctState_Untyped     `_hash_bytes`                  `_hash_bytes`
#
# ⚠ THE PRESERVED DIAGNOSTIC PATCH (`bench/results/q34w6_0921/artifact/
# strhash8.patch`) MOVES FOUR OF THOSE SIX AND IS THEREFORE UNSHIPPABLE: it
# rewrites `slot_str_fnv1a` — which the JOIN build table calls for its
# rehash-on-grow (`join_build_untyped.mojo:_hash_storage_single_col`) — while
# leaving the join's BATCH-side `_hash_string_view` on FNV-1a. A string-keyed
# join that outgrows its directory then rehashes every stored row into a
# bucket the probe never visits: lost matches, no crash, no diagnostic. The
# two lanes that measured the patch could not see it because cbq33/cbq34/
# cbq15/cbq16 contain no string join. That invariant is now pinned by
# `tests/test_strhash8_all_sites_agree.mojo`.
#
# THE ALGORITHM. Length-seeded xor-multiply over little-endian 8-byte words,
# a length-packed little-endian remainder word, and a 3-step avalanche
# finalize. It is the shape DuckDB uses, one multiply per word rather than
# two. Differences cannot cancel (the state multiplier is odd, so the chain
# is a bijection on any fixed length), and the finalize is what carries a
# top-bit difference back down into the directory's bucket bits.
#
# ⚠ NOT A CHECKSUM, NOT SERIALISED, NOT STABLE ACROSS VERSIONS. Nothing may
# persist this value. It is a within-process bucket function only.
# -----------------------------------------------------------------------------

comptime STRHASH8_SEED: UInt64 = 0xCBF29CE484222325
"""Initial state. Carried over from the FNV-1a offset basis it replaces —
an arbitrary odd constant, kept only so a reader can see the lineage."""

comptime STRHASH8_LEN_MUL: UInt64 = 0xC6A4A7935BD1E995
"""Length mixer. Seeding with the LENGTH is what keeps `"a\0"` and `"a"`
apart once the remainder word is zero-padded to 64 bits."""

comptime STRHASH8_MUL: UInt64 = 0xD6E8FEB86659FD93
"""State multiplier. Odd, so `h -> (h ^ w) * MUL` is a bijection at fixed
length and two inputs that differ in one word can never re-converge."""


@always_inline
def strhash8_init(length: Int) -> UInt64:
    """Seed the state for a key of `length` bytes."""
    return STRHASH8_SEED ^ (UInt64(length) * STRHASH8_LEN_MUL)


@always_inline
def strhash8_round(h: UInt64, w: UInt64) -> UInt64:
    """Absorb one little-endian 64-bit word — ONE multiply per 8 bytes."""
    return (h ^ w) * STRHASH8_MUL


@always_inline
def strhash8_final(h: UInt64) -> UInt64:
    """Avalanche the state. Without this a difference confined to the top
    bits of `h` stays there (multiply only propagates low->high) and the
    directory's low bucket bits would never see it."""
    var x = h ^ (h >> 32)
    x = x * STRHASH8_MUL
    return x ^ (x >> 32)


@always_inline
def strhash8_byteview[
    o: Origin[mut=False]
](bv: ByteView[o], start: Int, length: Int) -> UInt64:
    """STRHASH8 over `bv[start : start+length)`.

    THE canonical spelling — every `ByteView`-sourced key hash in the engine
    calls this one body, so the four sites cannot drift from each other.
    The storage-heap site (`slot_str_fnv1a`) reads a
    `SharedAlignedBuffer[HeapRegion]`, not a `ByteView`, so it carries the
    same loop over the same three primitives rather than this function.
    """
    var h = strhash8_init(length)
    var i = 0
    var end = start + length
    while i + 8 <= length:
        h = strhash8_round(h, bv.read_u64_le_at(start + i))
        i += 8
    if i < length:
        var r: UInt64 = UInt64(0)
        var sh: UInt64 = UInt64(0)
        var j = start + i
        while j < end:
            r = r | (UInt64(Int(bv.read_u8_at(j))) << sh)
            sh += UInt64(8)
            j += 1
        h = strhash8_round(h, r)
    return strhash8_final(h)


# -----------------------------------------------------------------------------
# Role constants (Column UNTYPED v0.4 §3.1 ColDescriptor.role)
# -----------------------------------------------------------------------------

comptime ROLE_KEY: UInt8 = 1
"""Hash-agg / join / sort / distinct key column."""

comptime ROLE_PAYLOAD: UInt8 = 2
"""Join payload column (carried through to probe output without
participating in the key)."""

comptime ROLE_AGG_INPUT: UInt8 = 3
"""Aggregate input column (read once per (slot, agg) update)."""

comptime ROLE_SORT_KEY: UInt8 = 4
"""Sort key column (carries `asc/desc` + `nulls_first/last` in a
sibling SortDescriptor; layout fields are identical)."""

comptime ROLE_DISTINCT_KEY: UInt8 = 5
"""Distinct key column (operates as a key under hash-set membership
semantics)."""


# -----------------------------------------------------------------------------
# ColDescriptor (Column UNTYPED v0.4 §3.1 — column-format variant)
#
# Per-column runtime metadata. Distinct from Row UNTYPED's `ColDescriptor`
# at `row_block.mojo:151-194` which carries `offset_in_row` + `fixed_width`;
# this Column-format ColDescriptor carries `col_idx_in_storage`
# (destination col index within `ColumnFormatStorage`) + role + validity
# flag — no row-offset field because the column-format layout addresses
# cells via per-col buffer + slot index.
#
# v0.2 fix-up (Column UNTYPED v0.4 §3.1): NO `TrivialRegisterPassable`
# trait conformance — heap-owning fields are interned to `Int` arena IDs,
# but pending arena lifetime wiring (Phase C-G.2 introduces the
# EngineContext arena Slab), this Phase C-G.1 ColDescriptor stays
# `Copyable + Movable + ImplicitlyCopyable` for `List[ColDescriptor]`
# storage shape. Name interning is captured as `name_id: Int` placeholder;
# Phase C-G.2 wires the arena lookup.
#
# Encoder Variant field is OMITTED at Phase C-G.1: the
# `_ColEncoder = Variant[I64Encoder, ..., StringEncoder]` carrier lands in
# Phase C-G.5 (dispatch_table.mojo). Phase C-G.1 storage only needs the
# metadata; dispatch happens in-line at Phase C-G.1 callers (or via
# Phase C-G.2's HashAggTable_Untyped helpers).
# -----------------------------------------------------------------------------


@fieldwise_init
struct ColDescriptor(
    Copyable, Movable, ImplicitlyCopyable, Deinitable
):
    """Per-column metadata for Column UNTYPED hash-slot storage.

    Storage fields:
        name_id: Interned column name (debug + diagnostics). Phase C-G.1
            placeholder Int; Phase C-G.2 wires to a EngineContext
            `Slab[String]` arena. Negative values reserved for "not yet
            interned".
        kind: One of the COL_* constants. Discriminates fixed vs varlen
            vs nested storage paths.
        dtype_tag: One of the DT_* constants. Within COL_FIXED selects
            cell width + read/write kernel; within COL_VAR_* selects
            STRING vs BINARY decoder.
        role: One of the ROLE_* constants. Engine-side dispatch routes
            on this to choose hash-mix vs payload-copy vs agg-update
            paths.
        col_idx_in_batch: Index into the source `BatchView` for
            per-batch encode. -1 reserved for "no source col" (e.g.
            COUNT(*) agg, RANK() partition counter, ...).
        col_idx_in_storage: Index into `ColumnFormatStorage` for the
            destination buffer (key_buffers, agg_state_buffers, etc. —
            chosen by role). MUST be valid wrt the storage allocation.
        validity_tracked: True iff the source schema marks this column
            nullable. Affects whether the per-slot validity bitmap is
            consulted / updated; non-nullable cols skip bitmap
            allocation entirely.

    Invariants (caller-enforced; Phase C-G.5 dispatch site validates):
        - kind in {COL_FIXED, COL_VAR_STRING, COL_VAR_BINARY,
                   COL_DECIMAL128, COL_NESTED}
        - dtype_tag in {DT_*} consistent with kind (e.g. kind ==
          COL_VAR_STRING -> dtype_tag == DT_STRING).
        - col_idx_in_batch >= -1 (allows COUNT(*)).
        - col_idx_in_storage >= 0.
    """

    var name_id: Int
    var kind: UInt8
    var dtype_tag: UInt8
    var role: UInt8
    var col_idx_in_batch: Int
    var col_idx_in_storage: Int
    var validity_tracked: Bool


# -----------------------------------------------------------------------------
# _dtype_cell_bytes — per-DType fixed-cell byte width (file-internal)
#
# Returns the per-slot byte stride for a given dtype_tag within
# COL_FIXED storage. Lookup happens once per (col, allocation) in
# `_fixed_buffer_bytes_for` and is cached implicitly through the
# Slab[MmapAlignedBuffer[64]] per-col layout. The dispatch table at
# Phase C-G.5 will re-use this helper for per-DType encode/decode
# routing.
#
# COL_DECIMAL128 returns 16 (one 128-bit cell = 2 sequential u64 cells
# but addressed as a single 16B slot per storage slot).
# COL_VAR_* returns 8 (per-slot `(offset, length)` descriptor cell).
# -----------------------------------------------------------------------------


@always_inline
def _dtype_cell_bytes(kind: UInt8, dtype_tag: UInt8) -> Int:
    """Per-slot byte stride for the COL_FIXED / COL_DECIMAL128 / COL_VAR_*
    cells in the per-col fixed buffer.

    Var-width cols use 8B per slot for the `(offset: Int32, length:
    Int32)` descriptor; payload bytes live in `var_data_heaps[var_idx]`.

    Returns 0 for COL_NESTED (Phase C-G.7 will install a 16B descriptor
    once the Arrow Row encoder lands).
    """
    if kind == COL_VAR_STRING or kind == COL_VAR_BINARY:
        return 8  # (offset: Int32) + (length: Int32) descriptor cell.
    if kind == COL_DECIMAL128:
        return 16  # 128-bit cell as a single 16B storage slot.
    if kind == COL_NESTED:
        return 0  # Phase C-G.7 — STUB until Arrow Row encoder lands.
    # COL_FIXED: discriminate on dtype_tag.
    if dtype_tag == DT_I64:
        return 8
    if dtype_tag == DT_F64:
        return 8
    if dtype_tag == DT_I32:
        return 4
    if dtype_tag == DT_F32:
        return 4
    if dtype_tag == DT_I16:
        return 2
    if dtype_tag == DT_U16:
        return 2
    if dtype_tag == DT_I8:
        return 1
    if dtype_tag == DT_U8:
        return 1
    if dtype_tag == DT_U32:
        return 4
    if dtype_tag == DT_U64:
        return 8
    if dtype_tag == DT_DATE32:
        return 4
    if dtype_tag == DT_DATE64:
        return 8
    if dtype_tag == DT_BOOL:
        return 1  # one byte per slot in storage (bit-packing reserved for the validity bitmap path).
    if dtype_tag == DT_TIMESTAMP_NS:
        return 8
    if dtype_tag == DT_TIMESTAMP_US:
        return 8
    if dtype_tag == DT_TIMESTAMP_MS:
        return 8
    if dtype_tag == DT_TIMESTAMP_S:
        return 8
    # Unknown DType — return 0 so caller-side `_validate_layout` can
    # raise. We do NOT raise here so this helper stays `@always_inline`.
    return 0


# -----------------------------------------------------------------------------
# ColumnFormatStorage — primary primitive
#
# Per Column UNTYPED v0.4 §3.3:
#   - Per-col fixed buffers (one MmapAlignedBuffer[64] per col, regardless of
#     fixed vs varlen). Var cols store an 8B descriptor cell per slot.
#   - Per-var-col data heap (one MmapAlignedBuffer[64] per varlen col;
#     payload bytes appended on insert).
#   - Per-col validity bitmap (one MmapAlignedBuffer[64] per validity-tracked
#     col; 1 bit per slot, LSB-first within byte).
#   - Layout descriptors (List[ColDescriptor]) parallel to col_buffers.
#
# Per-col Slab indexing (canonical): the i-th col's fixed buffer lives at
#   `col_buffers[i]` regardless of kind. Var-col i's data heap lives at
#   `var_data_heaps[col_descriptors[i]_var_idx]` (sparse lookup).
#
# Growth contract: `grow_to(new_capacity)` doubles per-col fixed and
# validity buffer capacity in lock-step. Var-data heaps grow
# independently driven by per-payload appends. Slot indices remain
# valid across growth (only capacity changes; n_slots is preserved).
# -----------------------------------------------------------------------------


struct ColumnFormatStorage(Movable, Deinitable):
    """Per-column contiguous storage for the Column UNTYPED quadrant's
    hash-slot back-ends.

    Each "slot" is a row index into per-col arrays:
      - Slot K of fixed col C lives at byte offset `K * cell_bytes(C)`
        in `col_buffers[C.col_idx_in_storage]`.
      - Slot K of var col C: descriptor cell `(offset, length)` at
        byte offset `K * 8` in `col_buffers[C.col_idx_in_storage]`;
        payload bytes at `var_data_heaps[var_idx_of(C)][offset :
        offset + length]`.
      - Slot K validity bit: bit K & 7 of byte K >> 3 in
        `validity_buffers[C.col_idx_in_storage]` (only if
        C.validity_tracked is True).

    Construction is via `ColumnFormatStorage.alloc(layout,
    initial_capacity)` — the one public ctor; callers MUST NOT
    instantiate via default. After alloc, `n_slots == 0`; `capacity` is
    set per the layout's cell-byte sums; per-col-and-per-slot access is
    capacity-safe by precondition (callers honor `n_slots < capacity`
    OR call `grow_to(new_cap)` first).

    Fields:
        n_slots: Logical slot count (number of groups / build rows /
            sort rows installed). Caller-maintained on insert.
        capacity: Slot capacity (max slots before regrow). The per-col
            buffers are sized to hold `capacity * cell_bytes(col)`
            bytes each. Var-data heaps have independent capacity.
        col_descriptors: Parallel to `col_buffers`; one entry per col.
            Immutable after alloc (no live use case for runtime
            descriptor mutation).
        col_buffers: Per-col fixed buffer (one per col regardless of
            kind). Stored under Slab[MmapAlignedBuffer[64]] because
            MmapAlignedBuffer is Movable-not-Copyable; Slab is the
            canonical container for that constraint (precedent at
            an internal module).
        validity_buffers: Per-col validity bitmap (one per
            validity-tracked col, EMPTY MmapAlignedBuffer for non-tracked
            cols — keeps Slab indexing parallel to col_buffers).
        var_data_heaps: Per-varlen-col payload heap. Indexed by the
            descriptor's own `_var_idx_for(desc)` (set at alloc time).
        var_data_used: Bytes consumed per var-data heap (parallel to
            var_data_heaps). Caller-maintained on var-payload appends.
        var_idx_for_col: Sparse map: col_idx_in_storage -> index into
            var_data_heaps (-1 for fixed cols). One Int per col.

    Encapsulation:
        - All read/write APIs return / accept typed scalars or refs.
        - No UnsafePointer in any public signature.
        - Slot index is bounds-checked via `debug_assert` in the read
          path; the write path is bounds-asserted at the cell-byte
          level by MmapAlignedBuffer.set_typed.
    """

    var n_slots: Int
    """Logical slot count (number of groups/rows installed)."""

    var capacity: Int
    """Slot capacity (max slots before regrow). Per-col fixed buffers
    sized to `capacity * cell_bytes(col)` bytes each."""

    var col_descriptors: List[ColDescriptor]
    """One ColDescriptor per col; parallel to col_buffers."""

    # R3.3.E.4 Batch 5: the three `Slab[MmapAlignedBuffer[64]]`
    # fields flipped to `Slab[SharedAlignedBuffer[HeapRegion]]`. SAB is
    # Movable + Deinitable (the trait bound Slab requires);
    # its public method surface (read_uXX_le_at / write_uXX_le_at /
    # read_iXX_le_at / write_iXX_le_at / read_fXX_le_at / write_fXX_le_at /
    # cap / set_length / copy_from_aligned_buffer_at) is a superset of
    # OLD AB for the read/write call sites in this file. Ctor sites build
    # via `OwnedAlignedBuffer(size) + SharedAlignedBuffer.from_owned(...)`.
    var col_buffers: Slab[SharedAlignedBuffer[HeapRegion]]
    """Per-col fixed buffer storage. Var cols use the 8B-per-slot
    `(offset, length)` descriptor cell here; payload lives in
    `var_data_heaps`."""

    var validity_buffers: Slab[SharedAlignedBuffer[HeapRegion]]
    """Per-col validity bitmap; empty SharedAlignedBuffer slot for cols
    where `validity_tracked == False` (kept parallel to col_buffers for
    uniform Slab indexing)."""

    var var_data_heaps: Slab[SharedAlignedBuffer[HeapRegion]]
    """Per-varlen-col payload heap; sparse — one entry per varlen col.
    Indexed via `var_idx_for_col[col_idx_in_storage]`."""

    var var_data_used: List[Int]
    """Bytes consumed per var-data heap; parallel to var_data_heaps."""

    var var_idx_for_col: List[Int]
    """Sparse map col_idx_in_storage -> index into var_data_heaps.
    -1 marks fixed cols. Set once at alloc; immutable thereafter."""

    # ─────────────────────────────────────────────────────────────────────
    # Construction
    # ─────────────────────────────────────────────────────────────────────

    def __init__(out self):
        """Empty-shell ctor; callers MUST use `alloc(layout,
        initial_capacity)` for usable storage. This ctor exists only to
        satisfy Mojo's `Movable` storage requirements (e.g. when a
        `ColumnFormatStorage` is held under `Optional[OwnedPointer[...]]`
        and needs a placeholder before alloc).
        """
        self.n_slots = 0
        self.capacity = 0
        self.col_descriptors = List[ColDescriptor]()
        self.col_buffers = Slab[SharedAlignedBuffer[HeapRegion]]()
        self.validity_buffers = Slab[SharedAlignedBuffer[HeapRegion]]()
        self.var_data_heaps = Slab[SharedAlignedBuffer[HeapRegion]]()
        self.var_data_used = List[Int]()
        self.var_idx_for_col = List[Int]()

    @staticmethod
    def alloc(
        var layout: List[ColDescriptor], initial_capacity: Int
    ) raises -> ColumnFormatStorage:
        """Allocate per-col fixed buffers + per-var-col data heaps +
        per-col validity buffers for the given layout.

        Per-col fixed buffer size = `initial_capacity * cell_bytes(col)`.
        Per-var-col data heap starts at a default heuristic
        (`initial_capacity * AVG_VAR_BYTES`); callers can `grow_to`
        the heap independently via `reserve_var_bytes`.

        Per-col validity buffer is allocated only for `validity_tracked`
        cols; the corresponding Slab slot for non-tracked cols holds an
        EMPTY MmapAlignedBuffer (capacity 0) so Slab indexing remains
        parallel to `col_buffers`.

        Raises:
            On unknown DType in any layout entry.

        Args:
            layout: One ColDescriptor per col. MUST honor field
                invariants documented on ColDescriptor.
            initial_capacity: Number of slots to pre-size; >0 allocates,
                <=0 produces an empty allocation that requires `grow_to`
                before use.

        Returns:
            ColumnFormatStorage with the given layout, n_slots=0, ready
            for slot inserts via `write_slot_*` helpers.
        """
        var n_cols = layout.__len__()
        var rb = ColumnFormatStorage()
        rb.capacity = initial_capacity if initial_capacity > 0 else 0

        # ─── Per-col fixed buffers + validity buffers + var-idx map ─────
        # Walk the layout, allocate per-col buffers, and build the sparse
        # var_idx_for_col map. Var cols also reserve a data heap below.
        var n_var_cols = 0
        for i in range(n_cols):
            var desc = layout[i]
            var cell_bytes = _dtype_cell_bytes(desc.kind, desc.dtype_tag)
            if cell_bytes == 0 and desc.kind != COL_NESTED:
                raise Error(
                    "ColumnFormatStorage.alloc: unknown DType for col "
                    + String(i)
                    + " (kind="
                    + String(Int(desc.kind))
                    + ", dtype_tag="
                    + String(Int(desc.dtype_tag))
                    + ")"
                )
            # Fixed buffer: capacity * cell_bytes bytes. Even for varlen
            # cols this holds the per-slot 8B descriptor cell.
            var fixed_bytes = rb.capacity * cell_bytes
            var fixed_buf = OwnedAlignedBuffer(fixed_bytes)
            if fixed_bytes > 0:
                fixed_buf.set_length(Int64(fixed_bytes))
            rb.col_buffers.append(
                SharedAlignedBuffer[HeapRegion].from_owned(fixed_buf^)
            )

            # Validity buffer: ceil(capacity / 8) bytes if tracked, else
            # empty (capacity-0 SharedAlignedBuffer placeholder).
            #
            # ⚠ INITIALISED ALL-VALID (0xFF), and that default is load-bearing
            #. It makes ABSENT INFORMATION MEAN VALID, which is
            # already this struct's documented convention for a NON-tracked col
            # (`is_slot_valid` returns True with no buffer at all) and Arrow's
            # own ("no validity buffer = all valid") — so the tracked and
            # untracked cases now say the same thing.
            #
            # WHY IT HAD TO BECOME EXPLICIT. A slot's key cell is written by
            # exactly one of several writers, and only two of them speak about
            # validity: `_encode_key_cell` and `_copy_key_cell_storage`, which
            # set the bit BOTH ways from the source. The rest — the vectorised
            # / monomorphised int-key writer, the dense per-code seeder, the
            # perfect-hash partial's key seeder — write BYTES ONLY, because
            # they only ever run on a batch proven to contain no null key.
            # While the fast folds declined on DECLARED nullability those
            # writers never touched a tracked column, so a zero-filled buffer
            # was harmless. Once the gate became OBSERVED nullability they do,
            # and a zero default would have rendered EVERY group they insert as
            # NULL on drain — with the group count and every aggregate still
            # exactly right, so no total would have shown it. Defaulting to
            # valid states the invariant ONCE here instead of asking each
            # writer to remember it.
            if desc.validity_tracked:
                var valid_bytes = (rb.capacity + 7) // 8
                var valid_buf = OwnedAlignedBuffer(valid_bytes)
                if valid_bytes > 0:
                    valid_buf.set_length(Int64(valid_bytes))
                    for b in range(valid_bytes):
                        valid_buf.write_u8_at(b, UInt8(0xFF))
                rb.validity_buffers.append(
                    SharedAlignedBuffer[HeapRegion].from_owned(valid_buf^)
                )
            else:
                rb.validity_buffers.append(
                    SharedAlignedBuffer[HeapRegion].from_owned(
                        OwnedAlignedBuffer(0)
                    )
                )

            # Var-idx map: -1 for fixed; index into var_data_heaps for var.
            if desc.kind == COL_VAR_STRING or desc.kind == COL_VAR_BINARY:
                rb.var_idx_for_col.append(n_var_cols)
                n_var_cols += 1
            else:
                rb.var_idx_for_col.append(-1)

        # ─── Per-var-col data heaps ────────────────────────────────────
        # Heuristic: 16 bytes per slot per varlen col (≈ short-string
        # average). Callers may `grow_var_data_heap_to` for known-larger
        # workloads. Var heaps grow independently of per-col fixed
        # buffers because per-slot payload length varies.
        comptime VAR_HEAP_INITIAL_BYTES_PER_SLOT: Int = 16
        var var_heap_init_bytes = rb.capacity * VAR_HEAP_INITIAL_BYTES_PER_SLOT
        for _ in range(n_var_cols):
            var heap = OwnedAlignedBuffer(var_heap_init_bytes)
            if var_heap_init_bytes > 0:
                heap.set_length(Int64(var_heap_init_bytes))
            rb.var_data_heaps.append(
                SharedAlignedBuffer[HeapRegion].from_owned(heap^)
            )
            rb.var_data_used.append(0)

        # Move layout into self last (var-param contract: read locals
        # before move).
        rb.col_descriptors = layout^
        return rb^

    # ─────────────────────────────────────────────────────────────────────
    # Capacity contract — slot count + growth
    # ─────────────────────────────────────────────────────────────────────

    @always_inline
    def set_n_slots(mut self, n: Int):
        """Set the logical slot count after an insert pass.

        Caller invariant: `n <= self.capacity`. Capacity is guaranteed by
        a pre-insert `grow_to` call (callers honor this).
        """
        self.n_slots = n

    def grow_to(mut self, new_capacity: Int) raises:
        """Amortized-doubling regrow: extend per-col fixed buffers +
        validity buffers to hold at least `new_capacity` slots each.

        Per-col fixed-buffer growth: each `col_buffers[i]` reallocates
        to `new_capacity * cell_bytes(col_descriptors[i])` bytes; the
        old `n_slots * cell_bytes` bytes are PRESERVED via a copy-on-
        grow path (the in-tree `MmapAlignedBuffer.reserve(...)` reallocates
        but zero-initializes, so we explicitly copy old bytes into the
        new buffer before swapping).

        Var-data heaps are NOT touched here — they grow independently
        on per-payload appends. Var-descriptor cells in the per-col
        fixed buffer ARE preserved by the same copy-on-grow path.

        Validity bitmaps grow to `(new_capacity + 7) // 8` bytes per
        validity-tracked col; existing bits preserved.

        No-op if `new_capacity <= self.capacity`.

        Raises:
            On unknown DType in any layout entry (defensive — alloc
            already validated this).

        Args:
            new_capacity: New slot capacity. MUST be >= 0.
        """
        if new_capacity <= self.capacity:
            return
        var n_cols = self.col_descriptors.__len__()

        for i in range(n_cols):
            var desc = self.col_descriptors[i]
            var cell_bytes = _dtype_cell_bytes(desc.kind, desc.dtype_tag)
            if cell_bytes == 0 and desc.kind != COL_NESTED:
                raise Error(
                    "ColumnFormatStorage.grow_to: unknown DType for col "
                    + String(i)
                )

            # Fixed buffer: alloc fresh + copy live bytes from old.
            var new_fixed_bytes = new_capacity * cell_bytes
            var new_fixed_oab = OwnedAlignedBuffer(new_fixed_bytes)
            if new_fixed_bytes > 0:
                new_fixed_oab.set_length(Int64(new_fixed_bytes))
            var new_fixed = SharedAlignedBuffer[HeapRegion].from_owned(
                new_fixed_oab^
            )
            var old_live_bytes = self.n_slots * cell_bytes
            if old_live_bytes > 0:
                new_fixed.copy_from_aligned_buffer_at(
                    0, self.col_buffers[i], 0, old_live_bytes
                )
            self.col_buffers[i] = new_fixed^

            # Validity buffer: same shape; (new_capacity + 7) // 8 bytes.
            # ALL-VALID default on the GROWN region, for the reason spelled out
            # at the `alloc` site above — a slot the fast key writers fill must
            # not read as NULL. Filled first, then the live prefix is copied
            # over it, so every already-written bit survives verbatim and only
            # the newly exposed slots take the default. (The partial last live
            # byte carries bits for slots past `n_slots`; those came from the
            # OLD buffer's identical default, so the two agree.)
            if desc.validity_tracked:
                var new_valid_bytes = (new_capacity + 7) // 8
                var new_valid_oab = OwnedAlignedBuffer(new_valid_bytes)
                if new_valid_bytes > 0:
                    new_valid_oab.set_length(Int64(new_valid_bytes))
                    for b in range(new_valid_bytes):
                        new_valid_oab.write_u8_at(b, UInt8(0xFF))
                var new_valid = SharedAlignedBuffer[HeapRegion].from_owned(
                    new_valid_oab^
                )
                var old_valid_bytes = (self.n_slots + 7) // 8
                if old_valid_bytes > 0:
                    new_valid.copy_from_aligned_buffer_at(
                        0, self.validity_buffers[i], 0, old_valid_bytes
                    )
                self.validity_buffers[i] = new_valid^

        self.capacity = new_capacity

    def var_bytes_used_for_col(
        self, col_idx_in_storage: Int
    ) raises -> Int:
        """Payload bytes currently CONSUMED in the var-data heap backing
        varlen column `col_idx_in_storage`.

        The running total `write_slot_str` / `write_slot_str_from_storage`
        advance by exactly `length` on every append — no padding, no alignment
        slack, and CAPACITY is a different number (`reserve_var_bytes` grows
        the heap without moving this cursor). So for a container whose every
        live slot had its payload written once, this is the same total a
        per-slot length walk computes, in O(1) instead of O(n_slots).

        ⚠ "EVERY LIVE SLOT" IS THE LOAD-BEARING HALF. A walk that SKIPS some
        slots — an aggregate drain skipping its NULL groups is the live case —
        gets a SMALLER number, because a null slot's payload is written here
        like any other. Against such a walk this is an upper bound.

        ⛔ IT IS A CURSOR, NOT A LIVE-SLOT SUM. If a caller can REWRITE an
        already-written varlen slot, the orphaned first payload is still
        counted here and is not counted by a walk. Callers that need "bytes
        the reader will see" rather than "bytes this heap holds" must walk.

        Raises:
            On col_idx_in_storage out of range, or on the col not being a
            varlen col (`var_idx_for_col[col] < 0`).
        """
        if (
            col_idx_in_storage < 0
            or col_idx_in_storage >= self.col_buffers.len()
        ):
            raise Error(
                "ColumnFormatStorage.var_bytes_used_for_col: col_idx out of"
                " range"
            )
        var var_idx = self.var_idx_for_col[col_idx_in_storage]
        if var_idx < 0:
            raise Error(
                "ColumnFormatStorage.var_bytes_used_for_col: col is not varlen"
                " (var_idx_for_col == -1); ensure ColDescriptor.kind is"
                " COL_VAR_STRING or COL_VAR_BINARY"
            )
        return self.var_data_used[var_idx]

    # ─────────────────────────────────────────────────────────────────────
    # ⭐ S1B-NOARGCOPY (2026-09-22) — `reserve_var_bytes` is called ONCE PER
    # VAR-PAYLOAD APPEND and on the overwhelmingly common path it only
    # compares two integers and returns. As a `@no_inline` `mut self` method
    # on a 208-byte `Movable`-not-`Copyable` struct, Mojo 1.0.0 passes
    # `ColumnFormatStorage` BY VALUE and returns the mutated value BY VALUE
    # through an sret slot: the caller reads 208 B out of the struct, spills
    # it to the outgoing argument area, and on return reloads 208-216 B and
    # stores it back. That is ~832 B of memory traffic to answer
    # `used + additional <= cap`.
    #
    # ⛔ THIS IS NOT A `raises` COST AND IT IS NOT THE FIELD PROJECTION.
    # Both were tested and refuted: a NON-raising `mut s: <208 B struct>`
    # free function called on a plain LOCAL round-trips identically, and
    # `ref [Origin[mut=True]]` lowers to a byte-identical body. What removes
    # it is (a) removing the CALL, or (b) passing only the fields the callee
    # touches. A 40/56-byte struct does not pay it at all (registers), so the
    # cost is a function of `size_of(Self)`, not of what the body does.
    #
    # The split below is (a) for the hot half only. `_grow_var_heap` keeps the
    # `mut self` round trip and that is correct: it runs O(log n) times per
    # column, so its marshalling amortises to nothing, and inlining its
    # allocation + arena memcpy into every append site would be the
    # OFFARM-TAX defect (`hash_agg_untyped.mojo:9002`).
    # ─────────────────────────────────────────────────────────────────────
    @always_inline
    def reserve_var_bytes(mut self, var_col_idx: Int, additional: Int) raises:
        """Amortized-doubling regrow for a per-varlen-col data heap.

        Called BEFORE appending a var payload that would exceed current
        capacity. Mirrors `RowBlock.reserve_var_bytes` at
        `row_block.mojo:396-410`.

        Args:
            var_col_idx: Index into `var_data_heaps` (NOT
                col_idx_in_storage). Resolve via `var_idx_for_col`.
            additional: Bytes to make room for, beyond the current
                `var_data_used[var_col_idx]`.

        Raises:
            On var_col_idx out of range.
        """
        if var_col_idx < 0 or var_col_idx >= self.var_data_heaps.len():
            _raise_reserve_var_bytes_oob()
            return
        var need = self.var_data_used[var_col_idx] + additional
        # VARHEAP-OFFSET-CEILING. One compare against a comptime constant, on
        # a branch that is never taken, BEFORE the growth allocation — see the
        # `VAR_DESC_OFFSET_MAX` block for why the refusal has to be here and
        # why it is stated on the RESULTING cursor rather than on the offset
        # this append will record.
        if need > VAR_DESC_OFFSET_MAX:
            _raise_var_heap_offset_ceiling(
                self.var_data_used[var_col_idx], additional
            )
            return
        if need <= self.var_data_heaps[var_col_idx].cap():
            return
        self._grow_var_heap(var_col_idx, additional)

    @no_inline
    def _grow_var_heap(mut self, var_col_idx: Int, additional: Int) raises:
        """COLD half of `reserve_var_bytes`: the actual geometric regrow.

        Preconditions (established by the `@always_inline` caller, NOT
        re-checked here): `0 <= var_col_idx < var_data_heaps.len()` and
        `var_data_used[var_col_idx] + additional > cap()`. The copied prefix
        is `used` bytes, exactly as before; the only thing S2-VARGROW4 changed
        is the NEW CAPACITY chosen once the arena is already past
        `VAR_HEAP_QUAD_GROWTH_FLOOR_BYTES` — see that constant's block for the
        arithmetic, the measurement it is aimed at, and its memory price.
        """
        var used = self.var_data_used[var_col_idx]
        var cur_cap = self.var_data_heaps[var_col_idx].cap()
        var needed = used + additional
        # S2-VARGROW4. `cur_cap * 2` below the floor is the SHIPPED policy,
        # unchanged, and it is what every small arena in the engine takes:
        # the floor is a comparison against a compile-time constant, so a
        # table whose key bytes never reach 1 MiB executes the identical
        # ladder it did before. Above the floor the factor is 4.
        var new_cap = cur_cap * 2
        if cur_cap >= VAR_HEAP_QUAD_GROWTH_FLOOR_BYTES:
            new_cap = cur_cap * 4
        if new_cap < needed:
            new_cap = needed
        if new_cap < 64:
            new_cap = 64
        var new_heap_oab = OwnedAlignedBuffer(new_cap)
        new_heap_oab.set_length(Int64(new_cap))
        var new_heap = SharedAlignedBuffer[HeapRegion].from_owned(
            new_heap_oab^
        )
        if used > 0:
            new_heap.copy_from_aligned_buffer_at(
                0, self.var_data_heaps[var_col_idx], 0, used
            )
        self.var_data_heaps[var_col_idx] = new_heap^

    # ─────────────────────────────────────────────────────────────────────
    # Per-DType write_slot_* methods — fixed-width
    #
    # Each takes a runtime `col_idx_in_storage` and a `slot` index plus
    # the typed scalar. Storage cell offset is computed from the
    # per-col cell width via `_dtype_cell_bytes(kind, dtype_tag)`.
    #
    # Phase C-G.1 scope: scalar single-slot writers. The Phase C-G.2
    # dispatch table will add per-batch `write_slot_*_batch[bo]` methods
    # that take `(BatchView[bo], src_col_idx, slot_indices)` for SIMD
    # encoding paths.
    # ─────────────────────────────────────────────────────────────────────

    @always_inline
    def _slot_byte_offset(self, col_idx_in_storage: Int, slot: Int) -> Int:
        """Compute byte offset within `col_buffers[col_idx]` for slot.

        File-internal — every typed writer/reader uses this to centralize
        the cell-byte-stride lookup. The `@always_inline` discipline keeps
        the per-(slot, col) cost at one indexed load + one multiply.
        """
        var desc = self.col_descriptors[col_idx_in_storage]
        var cell_bytes = _dtype_cell_bytes(desc.kind, desc.dtype_tag)
        return slot * cell_bytes

    @always_inline
    def write_slot_i64(
        mut self, col_idx_in_storage: Int, slot: Int, value: Int64
    ):
        """Write a single Int64 cell at (col, slot)."""
        var byte_off = self._slot_byte_offset(col_idx_in_storage, slot)
        self.col_buffers[col_idx_in_storage].write_i64_le_at(byte_off, value)

    @always_inline
    def write_slot_f64(
        mut self, col_idx_in_storage: Int, slot: Int, value: Float64
    ):
        """Write a single Float64 cell at (col, slot)."""
        var byte_off = self._slot_byte_offset(col_idx_in_storage, slot)
        self.col_buffers[col_idx_in_storage].write_f64_le_at(byte_off, value)

    @always_inline
    def write_slot_i32(
        mut self, col_idx_in_storage: Int, slot: Int, value: Int32
    ):
        """Write a single Int32 cell at (col, slot)."""
        var byte_off = self._slot_byte_offset(col_idx_in_storage, slot)
        self.col_buffers[col_idx_in_storage].write_i32_le_at(byte_off, value)

    @always_inline
    def write_slot_f32(
        mut self, col_idx_in_storage: Int, slot: Int, value: Float32
    ):
        """Write a single Float32 cell at (col, slot)."""
        var byte_off = self._slot_byte_offset(col_idx_in_storage, slot)
        self.col_buffers[col_idx_in_storage].write_f32_le_at(byte_off, value)

    @always_inline
    def write_slot_u8(
        mut self, col_idx_in_storage: Int, slot: Int, value: UInt8
    ):
        """Write a single UInt8 cell at (col, slot). Doubles as Bool cell
        (stored byte-wide, NOT bit-packed; bit-packing reserved for
        validity bitmaps)."""
        var byte_off = self._slot_byte_offset(col_idx_in_storage, slot)
        self.col_buffers[col_idx_in_storage].write_u8_at(byte_off, value)

    @always_inline
    def write_slot_u16(
        mut self, col_idx_in_storage: Int, slot: Int, value: UInt16
    ):
        """Write a single UInt16 cell at (col, slot)."""
        var byte_off = self._slot_byte_offset(col_idx_in_storage, slot)
        self.col_buffers[col_idx_in_storage].write_u16_le_at(byte_off, value)

    @always_inline
    def write_slot_u32(
        mut self, col_idx_in_storage: Int, slot: Int, value: UInt32
    ):
        """Write a single UInt32 cell at (col, slot)."""
        var byte_off = self._slot_byte_offset(col_idx_in_storage, slot)
        self.col_buffers[col_idx_in_storage].write_u32_le_at(byte_off, value)

    @always_inline
    def write_slot_u64(
        mut self, col_idx_in_storage: Int, slot: Int, value: UInt64
    ):
        """Write a single UInt64 cell at (col, slot). Also the canonical
        writer for Date64 / Timestamp_* cells (Arrow stores Date64 +
        Timestamp_* as Int64). For a DECIMAL128 cell use
        `write_slot_decimal128` — writing only the LOW word silently drops
        the HIGH 64 bits and collapses distinct decimals into one group."""
        var byte_off = self._slot_byte_offset(col_idx_in_storage, slot)
        self.col_buffers[col_idx_in_storage].write_u64_le_at(byte_off, value)

    @always_inline
    def write_slot_decimal128(
        mut self,
        col_idx_in_storage: Int,
        slot: Int,
        lo: UInt64,
        hi: UInt64,
    ):
        """Write a full 128-bit DECIMAL128 cell at (col, slot) as two LE u64
        words: LO at the slot base, HI at slot base + 8.

        The COL_DECIMAL128 slot stride is 16B (`_dtype_cell_bytes`), so both
        words fit in-slot. Carrying BOTH words is REQUIRED for correctness:
        two distinct 128-bit decimals that share their low 64 bits (e.g. 5 and
        (1<<64)+5) MUST NOT collide into the same group / dedup bucket / join
        match. The prior encode wrote only the LOW word via `write_slot_u64`,
        a silent group-collision hazard on GROUP BY / DISTINCT / JOIN over
        decimal keys."""
        var byte_off = self._slot_byte_offset(col_idx_in_storage, slot)
        self.col_buffers[col_idx_in_storage].write_u64_le_at(byte_off, lo)
        self.col_buffers[col_idx_in_storage].write_u64_le_at(byte_off + 8, hi)

    # ─────────────────────────────────────────────────────────────────────
    # FAST-KEY-EQ — hoisted-stride raw key-cell read.
    #
    # Every `read_slot_*` above pays `_slot_byte_offset`, which per CALL does
    # (a) a `col_descriptors[col]` List index + a 40-byte `ColDescriptor` COPY
    # and (b) a `_dtype_cell_bytes(kind, dtype_tag)` if-chain up to ~20 compares
    # deep. On the key-equality hot path that inner chain runs once per key per
    # row — nested INSIDE `_key_eq_single_col`'s own 8-deep dtype chain.
    #
    # The two primitives below split that cost in half: `slot_cell_bytes` is the
    # SAME stride lookup, callable ONCE per (col, batch) so the caller can cache
    # it; `read_slot_key_bits` then reads the cell with the stride SUPPLIED, so
    # the per-row read is one multiply + one indexed load + one width switch.
    #
    # `read_slot_key_bits` returns the cell's raw bytes ZERO-EXTENDED into a
    # UInt64. For every fixed-width INTEGER dtype the existing `_key_eq_single_col`
    # arm is already a raw-bit compare at the declared width (see that method's
    # DT_I16 / DT_I8 unsigned-domain notes), so comparing two zero-extended cells
    # yields a BIT-IDENTICAL verdict. FLOAT dtypes are NOT raw-bit comparable
    # (NaN != NaN, +0.0 == -0.0) and BOOL reads the batch VALIDITY bitmap rather
    # than a data cell — callers must exclude both.
    # ─────────────────────────────────────────────────────────────────────

    @always_inline
    def slot_cell_bytes(self, col_idx_in_storage: Int) -> Int:
        """Per-slot byte stride of `col_buffers[col_idx_in_storage]`.

        FAST-KEY-EQ: the hoistable half of `_slot_byte_offset`. Returns exactly
        what `_slot_byte_offset` divides by `slot`, so
        `slot * slot_cell_bytes(c) == _slot_byte_offset(c, slot)` holds by
        construction — a caller that caches this value reads the identical cell.
        """
        var desc = self.col_descriptors[col_idx_in_storage]
        return _dtype_cell_bytes(desc.kind, desc.dtype_tag)

    @always_inline
    def read_slot_key_bits(
        self, col_idx_in_storage: Int, slot: Int, cell_bytes: Int
    ) raises -> UInt64:
        """Read the fixed-width cell at (col, slot) as raw bytes zero-extended
        into a UInt64, using the CALLER-SUPPLIED `cell_bytes` stride.

        `cell_bytes` MUST equal `slot_cell_bytes(col_idx_in_storage)` — the
        caller caches it per (col, batch). Widths other than 8/4/2/1 return 0
        (no fixed-int key dtype has such a width; the caller's eligibility gate
        excludes them).
        """
        var byte_off = slot * cell_bytes
        if cell_bytes == 8:
            return self.col_buffers[col_idx_in_storage].read_u64_le_at(byte_off)
        if cell_bytes == 4:
            return UInt64(
                Int(self.col_buffers[col_idx_in_storage].read_u32_le_at(byte_off))
            )
        if cell_bytes == 2:
            return UInt64(
                Int(self.col_buffers[col_idx_in_storage].read_u16_le_at(byte_off))
            )
        if cell_bytes == 1:
            return UInt64(
                Int(self.col_buffers[col_idx_in_storage].read_u8_at(byte_off))
            )
        return UInt64(0)

    # ─────────────────────────────────────────────────────────────────────
    # Per-DType read_slot_* methods — fixed-width
    # ─────────────────────────────────────────────────────────────────────

    @always_inline
    def read_slot_i64(self, col_idx_in_storage: Int, slot: Int) raises -> Int64:
        """Read a single Int64 cell at (col, slot)."""
        var byte_off = self._slot_byte_offset(col_idx_in_storage, slot)
        return self.col_buffers[col_idx_in_storage].read_i64_le_at(byte_off)

    @always_inline
    def read_slot_f64(self, col_idx_in_storage: Int, slot: Int) raises -> Float64:
        """Read a single Float64 cell at (col, slot)."""
        var byte_off = self._slot_byte_offset(col_idx_in_storage, slot)
        return self.col_buffers[col_idx_in_storage].read_f64_le_at(byte_off)

    @always_inline
    def read_slot_i32(self, col_idx_in_storage: Int, slot: Int) raises -> Int32:
        """Read a single Int32 cell at (col, slot)."""
        var byte_off = self._slot_byte_offset(col_idx_in_storage, slot)
        return self.col_buffers[col_idx_in_storage].read_i32_le_at(byte_off)

    @always_inline
    def read_slot_f32(self, col_idx_in_storage: Int, slot: Int) raises -> Float32:
        """Read a single Float32 cell at (col, slot)."""
        var byte_off = self._slot_byte_offset(col_idx_in_storage, slot)
        return self.col_buffers[col_idx_in_storage].read_f32_le_at(byte_off)

    @always_inline
    def read_slot_u8(self, col_idx_in_storage: Int, slot: Int) raises -> UInt8:
        """Read a single UInt8 cell at (col, slot)."""
        var byte_off = self._slot_byte_offset(col_idx_in_storage, slot)
        return self.col_buffers[col_idx_in_storage].read_u8_at(byte_off)

    @always_inline
    def read_slot_u16(self, col_idx_in_storage: Int, slot: Int) raises -> UInt16:
        """Read a single UInt16 cell at (col, slot)."""
        var byte_off = self._slot_byte_offset(col_idx_in_storage, slot)
        return self.col_buffers[col_idx_in_storage].read_u16_le_at(byte_off)

    @always_inline
    def read_slot_u32(self, col_idx_in_storage: Int, slot: Int) raises -> UInt32:
        """Read a single UInt32 cell at (col, slot)."""
        var byte_off = self._slot_byte_offset(col_idx_in_storage, slot)
        return self.col_buffers[col_idx_in_storage].read_u32_le_at(byte_off)

    @always_inline
    def read_slot_u64(self, col_idx_in_storage: Int, slot: Int) raises -> UInt64:
        """Read a single UInt64 cell at (col, slot). Also the canonical
        reader for Date64 / Timestamp_* cells, and the DECIMAL128-LOW word
        (slot base + 0). Read the DECIMAL128-HIGH word via
        `read_slot_decimal128_hi`."""
        var byte_off = self._slot_byte_offset(col_idx_in_storage, slot)
        return self.col_buffers[col_idx_in_storage].read_u64_le_at(byte_off)

    # ─────────────────────────────────────────────────────────────────────
    # KEYW — PRE-RESOLVED-WIDTH readers (, `objcode`).
    #
    # Every `read_slot_*` above routes through `_slot_byte_offset`, which loads
    # `col_descriptors[col]` (a 40-BYTE-STRIDE indexed load) and then computes
    # `_dtype_cell_bytes(kind, dtype_tag)` — a `cmove` cascade plus a lookup
    # table. That is correct and cheap when the caller reads ONE cell. It is
    # NOT cheap in a hash-probe candidate loop, where `col` is fixed for the
    # table's whole lifetime and the descriptor walk is therefore recomputed
    # per key column PER PROBE CANDIDATE.
    #
    # MEASURED (`bench/results/objcode/PROFILE.md`,
    # `cycles:pp`, Mojo 1.0.0):
    # in `_upsert_one_row_prehashed_vec`'s hot loop on `clickbench/cb17` —
    # 61.7% of the symbol, itself 34.79% of the cell — the descriptor walk +
    # cell-byte computation is **58.6% of the loop**, against 25.6% for the
    # payload load and compare the loop exists to perform.
    #
    # These readers take the byte offset ALREADY COMPUTED by the caller, so a
    # caller that has hoisted `cell_bytes` out of its loop pays one multiply.
    # They are deliberately NOT a second way to read a cell: they are the same
    # `col_buffers[col]` typed load the `read_slot_*` methods end in, with the
    # offset argument moved to the caller.
    #
    # ⚠ NO POINTER CROSSES A MODULE BOUNDARY. The alternative — handing the
    # probe loop a raw base pointer — is banned by the project pointer rules
    # and would also be WRONG here: the probe loop runs across
    # `_grow_if_needed`, and `grow_to` reallocates every `col_buffers[i]`, so a
    # hoisted base pointer would dangle exactly when the table grows.
    # `cell_bytes`, by contrast, is invariant across growth — the buffer moves,
    # the stride does not.
    # ─────────────────────────────────────────────────────────────────────

    @always_inline
    def cell_bytes_of(self, col_idx_in_storage: Int) -> Int:
        """Bytes per cell for `col_idx_in_storage` — the quantity
        `_slot_byte_offset` recomputes on every call. Hoist this out of a probe
        loop and pair it with the `read_*_at_off` readers below."""
        var desc = self.col_descriptors[col_idx_in_storage]
        return _dtype_cell_bytes(desc.kind, desc.dtype_tag)

    @always_inline
    def read_i64_at_off(
        self, col_idx_in_storage: Int, byte_off: Int
    ) raises -> Int64:
        """`read_slot_i64` with the byte offset pre-computed by the caller."""
        return self.col_buffers[col_idx_in_storage].read_i64_le_at(byte_off)

    @always_inline
    def read_i32_at_off(
        self, col_idx_in_storage: Int, byte_off: Int
    ) raises -> Int32:
        """`read_slot_i32` with the byte offset pre-computed by the caller."""
        return self.col_buffers[col_idx_in_storage].read_i32_le_at(byte_off)

    @always_inline
    def read_u32_at_off(
        self, col_idx_in_storage: Int, byte_off: Int
    ) raises -> UInt32:
        """`read_slot_u32` with the byte offset pre-computed by the caller."""
        return self.col_buffers[col_idx_in_storage].read_u32_le_at(byte_off)

    @always_inline
    def read_u16_at_off(
        self, col_idx_in_storage: Int, byte_off: Int
    ) raises -> UInt16:
        """`read_slot_u16` with the byte offset pre-computed by the caller."""
        return self.col_buffers[col_idx_in_storage].read_u16_le_at(byte_off)

    @always_inline
    def read_u8_at_off(
        self, col_idx_in_storage: Int, byte_off: Int
    ) raises -> UInt8:
        """`read_slot_u8` with the byte offset pre-computed by the caller."""
        return self.col_buffers[col_idx_in_storage].read_u8_at(byte_off)

    # DRAINOUT completes the KEYW set above: the parallel radix
    # drain reads F64 / F32 / U64 cells per element too, and those three
    # readers were the only members of the fixed-width family without a
    # pre-computed-offset twin. Same contract, same ban on handing out a base
    # pointer, same reason: the stride is invariant, the buffer is not.

    @always_inline
    def read_f64_at_off(
        self, col_idx_in_storage: Int, byte_off: Int
    ) raises -> Float64:
        """`read_slot_f64` with the byte offset pre-computed by the caller."""
        return self.col_buffers[col_idx_in_storage].read_f64_le_at(byte_off)

    @always_inline
    def read_f32_at_off(
        self, col_idx_in_storage: Int, byte_off: Int
    ) raises -> Float32:
        """`read_slot_f32` with the byte offset pre-computed by the caller."""
        return self.col_buffers[col_idx_in_storage].read_f32_le_at(byte_off)

    @always_inline
    def read_u64_at_off(
        self, col_idx_in_storage: Int, byte_off: Int
    ) raises -> UInt64:
        """`read_slot_u64` with the byte offset pre-computed by the caller."""
        return self.col_buffers[col_idx_in_storage].read_u64_le_at(byte_off)

    # ─────────────────────────────────────────────────────────────────────
    # COMBINEHOIST — the WRITE twins of the readers above.
    #
    # Every `read_*_at_off` above has existed since FAST-KEY-EQ / KEYW /
    # DRAINOUT because those callers only READ. The combine path COPIES: it
    # reads one table's cell and writes another's, and the write side was still
    # paying `_slot_byte_offset` (a 40-byte `ColDescriptor` load + the
    # `_dtype_cell_bytes` cascade) per cell — ONE derivation for the source and
    # a SECOND for the destination.
    #
    # ⚠ THE WRITE SIDE IS WHY A SOURCE-LEVEL HOIST DOES NOT WORK AND THESE
    # HAVE TO EXIST. A loop that stores through `col_buffers[col]` invalidates
    # LLVM's cached load of `col_buffers[col]._ptr` on every iteration (Mojo
    # has no `noalias`), so the invariant derivation is RE-EXECUTED per cell no
    # matter how the source hoists it. Moving the arithmetic to the caller as a
    # VALUE is the only thing that removes it. See `combine_key_plan.mojo` for
    # the disassembly this claim is read from.
    #
    # Same contract as the readers: `byte_off` MUST be
    # `slot * cell_bytes_of(col)`, no pointer is handed out, and the caller
    # hoists the STRIDE only — never a base pointer, which `grow_to`
    # invalidates.
    # ─────────────────────────────────────────────────────────────────────

    @always_inline
    def write_u8_at_off(
        mut self, col_idx_in_storage: Int, byte_off: Int, value: UInt8
    ):
        """`write_slot_u8` with the byte offset pre-computed by the caller."""
        self.col_buffers[col_idx_in_storage].write_u8_at(byte_off, value)

    @always_inline
    def write_u16_at_off(
        mut self, col_idx_in_storage: Int, byte_off: Int, value: UInt16
    ):
        """`write_slot_u16` with the byte offset pre-computed by the caller."""
        self.col_buffers[col_idx_in_storage].write_u16_le_at(byte_off, value)

    @always_inline
    def write_u32_at_off(
        mut self, col_idx_in_storage: Int, byte_off: Int, value: UInt32
    ):
        """`write_slot_u32` with the byte offset pre-computed by the caller."""
        self.col_buffers[col_idx_in_storage].write_u32_le_at(byte_off, value)

    @always_inline
    def write_u64_at_off(
        mut self, col_idx_in_storage: Int, byte_off: Int, value: UInt64
    ):
        """`write_slot_u64` with the byte offset pre-computed by the caller.
        Also the Date64 / Timestamp_* writer, exactly as `write_slot_u64` is —
        and, paired at `byte_off` and `byte_off + 8`, the DECIMAL128 writer
        `write_slot_decimal128` decomposes into."""
        self.col_buffers[col_idx_in_storage].write_u64_le_at(byte_off, value)

    @always_inline
    def write_i64_at_off(
        mut self, col_idx_in_storage: Int, byte_off: Int, value: Int64
    ):
        """`write_slot_i64` with the byte offset pre-computed by the caller.

        The SIGNED pair of `write_u64_at_off`, and separate from it for the same
        reason `write_f64_at_off` is separate: the hoisted arm then executes the
        IDENTICAL instruction on the IDENTICAL typed value that the checked arm
        does, so "byte-identical" needs no argument about a reinterpretation."""
        self.col_buffers[col_idx_in_storage].write_i64_le_at(byte_off, value)

    @always_inline
    def write_i32_at_off(
        mut self, col_idx_in_storage: Int, byte_off: Int, value: Int32
    ):
        """`write_slot_i32` with the byte offset pre-computed by the caller."""
        self.col_buffers[col_idx_in_storage].write_i32_le_at(byte_off, value)

    @always_inline
    def write_f64_at_off(
        mut self, col_idx_in_storage: Int, byte_off: Int, value: Float64
    ):
        """`write_slot_f64` with the byte offset pre-computed by the caller.

        The float cells are moved through the TYPED pair rather than as raw
        words so the hoisted arm executes the identical instruction on the
        value that the checked arm does — no argument about NaN payloads has to
        be made for the two arms to be provably byte-identical."""
        self.col_buffers[col_idx_in_storage].write_f64_le_at(byte_off, value)

    @always_inline
    def write_f32_at_off(
        mut self, col_idx_in_storage: Int, byte_off: Int, value: Float32
    ):
        """`write_slot_f32` with the byte offset pre-computed by the caller."""
        self.col_buffers[col_idx_in_storage].write_f32_le_at(byte_off, value)

    @always_inline
    def read_slot_decimal128_hi(
        self, col_idx_in_storage: Int, slot: Int
    ) raises -> UInt64:
        """Read the HIGH 64 bits of a DECIMAL128 cell at (col, slot), i.e. the
        u64 word at slot base + 8. The LOW 64 bits are read via
        `read_slot_u64` (slot base + 0). See `write_slot_decimal128` for why
        both words are load-bearing."""
        var byte_off = self._slot_byte_offset(col_idx_in_storage, slot)
        return self.col_buffers[col_idx_in_storage].read_u64_le_at(byte_off + 8)

    # ─────────────────────────────────────────────────────────────────────
    # Variable-width STRING / BINARY accessors
    #
    # Phase C-G.1 STUB: write/read raise pending
    # `STRINGCOLUMNVIEW-SUBSTRATE-V04` slot landing (BatchView's
    # `col_str()/col_binary()` accessors aren't published yet, so the
    # batch-side encode/decode hot loop can't be wired).
    #
    # The storage shape IS allocated (`var_data_heaps` + per-col 8B
    # descriptor cells in `col_buffers`), so dispatch through
    # `kind == COL_VAR_*` reaches the var-path without out-of-range
    # index errors; only the encode/decode raises. Phase C-G.2 wires
    # the BatchView side when STRINGCOLUMNVIEW lands.
    #
    # Stub signature reflects the final write API: takes a length +
    # `List[UInt8]` payload; production version takes
    # `BatchView[bo].col_str(idx)`. Production swap-in retains the
    # `(offset, length)` descriptor layout.
    # ─────────────────────────────────────────────────────────────────────

    def write_slot_str(
        mut self,
        col_idx_in_storage: Int,
        slot: Int,
        payload: List[UInt8],
    ) raises:
        """Phase C-G.1 STUB: write a STRING / BINARY payload at (col,
        slot).

        Writes the `(offset, length)` 8B descriptor cell in the per-col
        fixed buffer + appends payload bytes to the per-var-col data
        heap. Resizes the heap on overflow.

        Raises:
            On col_idx_in_storage out of range OR on the col not being
            a varlen col (`var_idx_for_col[col] < 0`).
        """
        if col_idx_in_storage < 0 or col_idx_in_storage >= self.col_buffers.len():
            raise Error(
                "ColumnFormatStorage.write_slot_str: col_idx out of range"
            )
        var var_idx = self.var_idx_for_col[col_idx_in_storage]
        if var_idx < 0:
            raise Error(
                "ColumnFormatStorage.write_slot_str: col is not varlen"
                " (var_idx_for_col == -1); ensure ColDescriptor.kind is"
                " COL_VAR_STRING or COL_VAR_BINARY"
            )
        var length = payload.__len__()
        # Reserve var-heap capacity + write the payload bytes.
        self.reserve_var_bytes(var_idx, length)
        var offset = self.var_data_used[var_idx]
        # `ref` to the heap slot — MmapAlignedBuffer is Movable-not-Copyable;
        # the Slab.__getitem__ returns `ref [self._bytes] T` per its
        # canonical pattern (slab.mojo:296-313).
        ref heap = self.var_data_heaps[var_idx]
        for i in range(length):
            heap.write_u8_at(offset + i, payload[i])
        self.var_data_used[var_idx] = offset + length
        # Write the 8B descriptor cell at (col, slot): low 4 bytes = offset,
        # high 4 bytes = length (little-endian). One u64 write keeps the
        # per-slot cost at one memory operation. `_var_desc_pack` is THE
        # layout — see `VAR_DESC_OFFSET_MAX` for the ceiling it enforces.
        var desc_cell: UInt64 = _var_desc_pack(offset, length)
        var byte_off = self._slot_byte_offset(col_idx_in_storage, slot)
        self.col_buffers[col_idx_in_storage].write_u64_le_at(
            byte_off, desc_cell
        )

    # ⭐ S1B-NOARGCOPY (2026-09-22) — `@always_inline` is LOAD-BEARING, not a
    # hint. See the block above `reserve_var_bytes`: as an out-of-line
    # `mut self` method this call cost the CALLER a 208-byte read out of
    # `self.slots`, a 208-byte spill into the outgoing argument area, a
    # 216-byte reload of the by-value-returned struct and a 216-byte store
    # back. MEASURED on the shipped binary (cbq34, on the benchmark
    # host): that marshalling is
    # **74.37% of `_encode_key_cell`'s cycles** at the dict-encoded key call
    # site (`0x208309f`) and 11.92% at the plain one (`0x2082aa3`) — 86.3% of
    # the symbol between them. Removing the CALL removes the marshalling,
    # which is the converting class (ADR §1.5: an instruction removal
    # converts to cycles when it removes a call boundary or a memory access).
    # ⚠ Do NOT "clean this up" back to an ordinary method.
    # ADR: an internal doc §S1.
    @always_inline
    def write_slot_str_from_byteview[
        mut: Bool, //, origin: Origin[mut=mut]
    ](
        mut self,
        col_idx_in_storage: Int,
        slot: Int,
        bytes: ByteView[origin],
        start: Int,
        end: Int,
    ) raises:
        """STRING-ARENA P0 ALLOC-HOIST: write a STRING / BINARY
        payload at (col, slot) DIRECTLY from a borrowed `ByteView` window
        `[start, end)` — NO intermediate `List[UInt8]` allocation.

        Byte-for-byte equivalent to `write_slot_str` over the same bytes: it
        reserves the same heap capacity, writes the same descriptor cell, and
        copies the same `end - start` bytes — it just sources them from a
        borrowed view instead of an owned `List`. Used by the agg key-encode
        hot path (`HashAggTable_Untyped._string_dict_encode_cell`) where the
        cell bytes live in the dict payload at the per-row code's window; the
        prior path materialized a per-group `List[UInt8]` solely to satisfy
        `write_slot_str`'s owned-payload signature (one heap alloc + one copy
        per distinct group on the probe-MISS). This hoists that alloc out.

        Raises:
            On col_idx_in_storage out of range OR on the col not being a
            varlen col (`var_idx_for_col[col] < 0`), matching `write_slot_str`.
        """
        # S1B-NOARGCOPY: the two preconditions keep their exact verdicts and
        # their exact messages, but the `raise Error(...)` bodies move to
        # `@no_inline` free functions. An `@always_inline` body carrying two
        # `String` constructions and two `StackTrace::collect_if_enabled`
        # sites would be copied into every call site; the verdict is what the
        # caller needs inlined, the diagnostic is not.
        if col_idx_in_storage < 0 or col_idx_in_storage >= self.col_buffers.len():
            _raise_wssfb_col_oob()
            return
        var var_idx = self.var_idx_for_col[col_idx_in_storage]
        if var_idx < 0:
            _raise_wssfb_not_varlen()
            return
        var length = max(end - start, 0)
        # Reserve var-heap capacity + copy the payload bytes from the borrowed
        # view directly into the heap (no List intermediary).
        self.reserve_var_bytes(var_idx, length)
        var offset = self.var_data_used[var_idx]
        ref heap = self.var_data_heaps[var_idx]
        # ⭐ STRKEY-BULK (2026-09-19): ONE memcpy, not `length` bounds-checked
        # single-byte stores. The byte loop this replaces ran once per
        # DISTINCT GROUP per key col (18,342,019 times on ClickBench cbq33,
        # `GROUP BY url`), each iteration re-entering `write_u8_at` on a
        # `SharedAlignedBuffer` reached through a `Slab` index. Byte-for-byte
        # identical: same source window, same destination window, same length.
        if length > 0:
            heap.view_range_mut(offset, length).copy_from_view_at(
                0, bytes.sub(start, length)
            )
        self.var_data_used[var_idx] = offset + length
        # Write the 8B descriptor cell (low 4B = offset, high 4B = length) —
        # identical layout to `write_slot_str`.
        var desc_cell: UInt64 = _var_desc_pack(offset, length)
        var byte_off = self._slot_byte_offset(col_idx_in_storage, slot)
        self.col_buffers[col_idx_in_storage].write_u64_le_at(
            byte_off, desc_cell
        )

    def read_slot_str_bytes(
        self, col_idx_in_storage: Int, slot: Int
    ) raises -> List[UInt8]:
        """Phase C-G.1 STUB: read a STRING / BINARY payload at (col,
        slot) as a copied `List[UInt8]`.

        Production form (Phase C-G.2) will return a `StringView` /
        `BinaryView` over the per-var-col data heap once
        `STRINGCOLUMNVIEW-SUBSTRATE-V04` lands. Phase C-G.1 returns a
        copied `List[UInt8]` so the read path is testable today
        without depending on the as-yet-unpublished view types.

        Raises:
            On col_idx out of range OR on the col not being varlen.
        """
        if col_idx_in_storage < 0 or col_idx_in_storage >= self.col_buffers.len():
            raise Error(
                "ColumnFormatStorage.read_slot_str_bytes: col_idx out of range"
            )
        var var_idx = self.var_idx_for_col[col_idx_in_storage]
        if var_idx < 0:
            raise Error(
                "ColumnFormatStorage.read_slot_str_bytes: col is not varlen"
            )
        # Read the 8B descriptor cell at (col, slot).
        var byte_off = self._slot_byte_offset(col_idx_in_storage, slot)
        var desc_cell = self.col_buffers[col_idx_in_storage].read_u64_le_at(
            byte_off
        )
        var offset = Int(desc_cell & UInt64(0xFFFFFFFF))
        var length = Int(desc_cell >> 32)
        # `ref` to read-only access the heap slot — MmapAlignedBuffer is
        # Movable-not-Copyable; Slab returns `ref [self._bytes] T`.
        ref heap = self.var_data_heaps[var_idx]
        var out = List[UInt8]()
        for i in range(length):
            out.append(heap.read_u8_at(offset + i))
        return out^

    # ─────────────────────────────────────────────────────────────────────
    # PERF-CRITICAL (perf #1 RC2): in-place STRING slot length +
    # byte readback. The prior hot path materialized a fresh `List[UInt8]`
    # per row per STRING key (via `read_slot_str_bytes`) just to hash /
    # compare against the batch cell — ~24M transient allocs on q1's
    # (l_returnflag, l_linestatus) group-by. These two accessors let the
    # HashAggTable_Untyped hash + key-eq kernels walk the stored bytes in
    # place (no allocation), comparing directly against the batch
    # `StringView`. Byte-for-byte equivalent to the List[UInt8] path.
    # ─────────────────────────────────────────────────────────────────────

    @always_inline
    def read_slot_str_len(
        self, col_idx_in_storage: Int, slot: Int
    ) raises -> Int:
        """Length (bytes) of the STRING / BINARY payload at (col, slot),
        read from the 8B descriptor cell without materializing the bytes."""
        if col_idx_in_storage < 0 or col_idx_in_storage >= self.col_buffers.len():
            raise Error(
                "ColumnFormatStorage.read_slot_str_len: col_idx out of range"
            )
        var byte_off = self._slot_byte_offset(col_idx_in_storage, slot)
        var desc_cell = self.col_buffers[col_idx_in_storage].read_u64_le_at(
            byte_off
        )
        return Int(desc_cell >> 32)

    @always_inline
    def read_slot_str_byte_at(
        self, col_idx_in_storage: Int, slot: Int, i: Int
    ) raises -> UInt8:
        """Read byte `i` of the STRING / BINARY payload at (col, slot) from
        the per-var-col data heap, in place (no List materialization)."""
        var var_idx = self.var_idx_for_col[col_idx_in_storage]
        if var_idx < 0:
            raise Error(
                "ColumnFormatStorage.read_slot_str_byte_at: col is not varlen"
            )
        var byte_off = self._slot_byte_offset(col_idx_in_storage, slot)
        var desc_cell = self.col_buffers[col_idx_in_storage].read_u64_le_at(
            byte_off
        )
        var offset = Int(desc_cell & UInt64(0xFFFFFFFF))
        # SAFETY: `i` is bounded by the caller (length read from the same
        # descriptor cell); the var heap region for this slot is
        # [offset, offset+length).
        return self.var_data_heaps[var_idx].read_u8_at(offset + i)

    # ─────────────────────────────────────────────────────────────────────
    # ⭐⭐ STRKEY-BULK (2026-09-19) — THE TWO BULK STRING-SLOT PRIMITIVES.
    #
    # WHAT WAS WRONG. `read_slot_str_byte_at` is `@always_inline` and looks
    # cheap, but EVERY CALL re-does the whole address resolution:
    #
    #     var_idx_for_col[col]            (List index)
    #     _slot_byte_offset(col, slot)    (col_descriptors[col] + a multiply)
    #     col_buffers[col].read_u64_le_at (Slab index + an 8-BYTE LOAD, to
    #                                      recover a descriptor that does not
    #                                      change across the loop)
    #     var_data_heaps[var_idx]         (Slab index)
    #     .read_u8_at(offset + i)         (the one load the caller wanted)
    #
    # Its only two callers are group-key EQUALITY loops, which run that chain
    # ONCE PER KEY BYTE, on every probe that reaches a compare — O(rows), not
    # O(groups). ClickBench cbq33 (`GROUP BY url`, 99,997,497 rows) is the
    # worked case: ~75 key bytes per row means ~7.5e9 executions of a chain
    # whose loop-invariant prefix is five of its six steps.
    #
    # `slot_str_first_diff` hoists that prefix out of the loop AND compares
    # EIGHT BYTES PER ITERATION. It is not an approximation of the byte loop:
    # it returns the index of the FIRST differing byte, exactly as the byte
    # loop's break index did, so the `keyeq_census` `bytes_touched` statistic
    # is preserved to the byte. The word compare can only be entered when a
    # full 8 bytes remain inside the payload, so it never reads past the cell.
    #
    # `slot_str_fnv1a` is the same hoist for the rehash-on-grow path, which
    # additionally allocated a `List[UInt8]` PER SLOT (`read_slot_str_bytes`)
    # solely to hand it to `_hash_bytes`. Bit-identical hash, zero allocation.
    # ─────────────────────────────────────────────────────────────────────

    @always_inline
    def slot_str_first_diff[
        o: Origin[mut=False]
    ](
        self,
        col_idx_in_storage: Int,
        slot: Int,
        bytes: ByteView[o],
        start: Int,
        length: Int,
    ) raises -> Int:
        """Compare `bytes[start : start+length)` against the first `length`
        bytes of the STRING / BINARY payload stored at (col, slot).

        Returns `-1` when all `length` bytes are equal, otherwise the index
        (relative to the start of the cell) of the FIRST differing byte —
        byte-for-byte the value a forward scalar loop would break at.

        The caller is responsible for having already established that the
        stored payload is at least `length` bytes long (every caller compares
        `read_slot_str_len` first, because unequal lengths are unequal keys).

        Raises:
            On the col not being a varlen col (`var_idx_for_col[col] < 0`),
            matching `read_slot_str_byte_at`.
        """
        var var_idx = self.var_idx_for_col[col_idx_in_storage]
        if var_idx < 0:
            raise Error(
                "ColumnFormatStorage.slot_str_first_diff: col is not varlen"
            )
        # Descriptor cell read ONCE for the whole comparison.
        var byte_off = self._slot_byte_offset(col_idx_in_storage, slot)
        var desc_cell = self.col_buffers[col_idx_in_storage].read_u64_le_at(
            byte_off
        )
        var offset = Int(desc_cell & UInt64(0xFFFFFFFF))
        ref heap = self.var_data_heaps[var_idx]
        # ⭐ STRCMP32 (2026-09-22) — THE WHOLE-SPAN VERDICT FIRST, VECTOR
        # WIDTH AT A TIME. `bytes_equal` is the shared byte_class kernel:
        # AVX2 `vmovdqu` / `vpxor <mem>` / `vptest` / `jcc` plus an
        # OVERLAPPING 32/16/8/4/2/1 tail ladder that reads nothing outside
        # the span. MEASURED in the shipped runner's object code, this
        # function's bulk loop went from NINE instructions per EIGHT bytes
        # — two of them a loop-invariant heap-base reload through memory,
        # because `ref heap` re-reads `SharedAlignedBuffer._ptr` and nothing
        # proves it does not alias the probe load — to EIGHT per THIRTY-TWO,
        # with the stored side folded into the `vpxor` memory operand.
        #
        # The scalar ladder below survives UNCHANGED as the COLD narrowing
        # path: it runs only when the spans already differ, and it is what
        # keeps the return value the exact index a forward byte scan would
        # have broken at (so `keyeq_census`'s `bytes_touched` is unmoved).
        #
        # ⚠ THAT LAYERING IS FAIL-SAFE IN EXACTLY ONE DIRECTION, AND ANY
        # TEST WRITTEN AGAINST THIS FUNCTION HAS TO KNOW WHICH. A wrongly
        # FALSE verdict from `bytes_equal` falls through to the ladder and is
        # CORRECTED (slower, never wrong); a wrongly TRUE one short-circuits
        # and IS a wrong answer. So a defect in the WINDOW arithmetic below
        # (`start`, `offset`) is a performance defect, invisible to a
        # correctness test, while a defect in the compared LENGTH or in the
        # byte domain is a correctness defect. The two isolating mutants in
        # `tests/test_strkey_*_byte_equiv.mojo` are both wrongly-TRUE ones
        # for that reason.
        if bytes_equal(
            bytes.sub(start, length).into_span(),
            heap.view_range_ro(offset, length).into_span(),
        ):
            return -1
        var i = 0
        # Word arm: only while a FULL 8 bytes remain inside the compared span.
        while i + 8 <= length:
            if bytes.read_u64_le_at(start + i) != heap.read_u64_le_at(
                offset + i
            ):
                # Narrow to the exact byte, so `bytes_touched` is unchanged.
                var j = i
                while j < i + 8:
                    if bytes.read_u8_at(start + j) != heap.read_u8_at(
                        offset + j
                    ):
                        return j
                    j += 1
                return i
            i += 8
        while i < length:
            if bytes.read_u8_at(start + i) != heap.read_u8_at(offset + i):
                return i
            i += 1
        return -1

    @always_inline
    def slot_str_slot_first_diff(
        self,
        col_idx_in_storage: Int,
        slot_a: Int,
        slot_b: Int,
        length: Int,
    ) raises -> Int:
        """Compare the first `length` bytes of the STRING / BINARY payloads
        stored at (col, `slot_a`) and (col, `slot_b`), BOTH read in place.

        The STORAGE-vs-STORAGE sister of `slot_str_first_diff`, which compares
        one slot against a BATCH cell. Used by the join build table's rehash,
        which groups same-key slots into one chain and therefore compares two
        stored keys rather than a key against an incoming row.

        Returns `-1` when all `length` bytes are equal, otherwise the index
        (relative to the start of each cell) of the FIRST differing byte —
        byte-for-byte the value a forward scalar loop over two materialized
        `List[UInt8]`s would have broken at, which is what the `keyeq_census`
        `bytes_touched` statistic records.

        The caller is responsible for having already established that both
        payloads are at least `length` bytes long (every caller compares
        `read_slot_str_len` on both slots first, because unequal lengths are
        unequal keys). The word arm is entered only while a full 8 bytes remain
        inside the compared span, so it never reads past either cell.

        Raises:
            On the col not being a varlen col (`var_idx_for_col[col] < 0`),
            matching `slot_str_first_diff`.
        """
        var var_idx = self.var_idx_for_col[col_idx_in_storage]
        if var_idx < 0:
            raise Error(
                "ColumnFormatStorage.slot_str_slot_first_diff: col is not"
                " varlen"
            )
        # BOTH descriptor cells read ONCE for the whole comparison — the
        # resolve that `read_slot_str_bytes` paid twice, plus two heap
        # allocations, to answer the same question.
        var cell_a = self.col_buffers[col_idx_in_storage].read_u64_le_at(
            self._slot_byte_offset(col_idx_in_storage, slot_a)
        )
        var cell_b = self.col_buffers[col_idx_in_storage].read_u64_le_at(
            self._slot_byte_offset(col_idx_in_storage, slot_b)
        )
        var off_a = Int(cell_a & UInt64(0xFFFFFFFF))
        var off_b = Int(cell_b & UInt64(0xFFFFFFFF))
        ref heap = self.var_data_heaps[var_idx]
        # ⭐ STRCMP32 (2026-09-22) — see `slot_str_first_diff`. Whole-span
        # verdict first; the scalar ladder below is the COLD narrowing path.
        if bytes_equal(
            heap.view_range_ro(off_a, length).into_span(),
            heap.view_range_ro(off_b, length).into_span(),
        ):
            return -1
        var i = 0
        # Word arm: only while a FULL 8 bytes remain inside the compared span.
        while i + 8 <= length:
            if heap.read_u64_le_at(off_a + i) != heap.read_u64_le_at(
                off_b + i
            ):
                # Narrow to the exact byte, so `bytes_touched` is unchanged.
                var j = i
                while j < i + 8:
                    if heap.read_u8_at(off_a + j) != heap.read_u8_at(
                        off_b + j
                    ):
                        return j
                    j += 1
                return i
            i += 8
        while i < length:
            if heap.read_u8_at(off_a + i) != heap.read_u8_at(off_b + i):
                return i
            i += 1
        return -1

    # ─────────────────────────────────────────────────────────────────────
    # ⭐⭐ STRKEY-XCOMBINE (2026-09-20) — THE CROSS-STORAGE PAIR.
    #
    # `slot_str_slot_first_diff` / `copy_slot_str_into` above already removed
    # the `List[UInt8]` from the SAME-storage rehash and from the drain. The
    # aggregate's storage-to-storage COMBINE — merging one worker's table into
    # another's — was left on `read_slot_str_bytes` + `_bytes_eq` and
    # `read_slot_str_bytes` + `write_slot_str`, i.e. TWO owned heap allocations
    # per var-key COMPARE and one alloc + a bounds-checked per-byte store loop
    # per var-key INSERT. That path runs ONCE PER MERGED GROUP, so its cost is
    # O(distinct groups x workers), not O(rows) — which is why it is invisible
    # on a low-cardinality string group-by and dominant on a high-cardinality
    # one.
    #
    # These two are the cross-storage siblings: same descriptor decode, same
    # bytes, same verdict, ZERO allocation. `slot_str_cross_first_diff` returns
    # the FIRST differing byte index exactly as a forward scalar loop over two
    # materialized Lists would have broken at, so any `bytes_touched` statistic
    # is preserved to the byte.
    # ─────────────────────────────────────────────────────────────────────

    @always_inline
    def slot_str_cross_first_diff(
        self,
        col_idx_in_storage: Int,
        slot: Int,
        src: ColumnFormatStorage,
        src_col_idx_in_storage: Int,
        src_slot: Int,
        length: Int,
    ) raises -> Int:
        """Compare the first `length` bytes of the STRING / BINARY payload at
        (`col_idx_in_storage`, `slot`) in THIS storage against the payload at
        (`src_col_idx_in_storage`, `src_slot`) in `src`, both read in place.

        The CROSS-STORAGE sister of `slot_str_slot_first_diff` (which compares
        two slots of the SAME storage). Returns `-1` when all `length` bytes
        are equal, otherwise the index of the FIRST differing byte.

        The caller is responsible for having established that both payloads are
        at least `length` bytes long (every caller compares `read_slot_str_len`
        on both sides first, because unequal lengths are unequal keys). The
        word arm is entered only while a full 8 bytes remain inside the
        compared span, so it never reads past either cell.

        Raises:
            On either col not being a varlen col.
        """
        var var_idx = self.var_idx_for_col[col_idx_in_storage]
        var src_var_idx = src.var_idx_for_col[src_col_idx_in_storage]
        if var_idx < 0 or src_var_idx < 0:
            raise Error(
                "ColumnFormatStorage.slot_str_cross_first_diff: col is not"
                " varlen"
            )
        # BOTH descriptor cells read ONCE for the whole comparison — the
        # resolve that `read_slot_str_bytes` paid twice, plus two heap
        # allocations, to answer the same question.
        var cell_a = self.col_buffers[col_idx_in_storage].read_u64_le_at(
            self._slot_byte_offset(col_idx_in_storage, slot)
        )
        var cell_b = src.col_buffers[src_col_idx_in_storage].read_u64_le_at(
            src._slot_byte_offset(src_col_idx_in_storage, src_slot)
        )
        var off_a = Int(cell_a & UInt64(0xFFFFFFFF))
        var off_b = Int(cell_b & UInt64(0xFFFFFFFF))
        ref heap_a = self.var_data_heaps[var_idx]
        ref heap_b = src.var_data_heaps[src_var_idx]
        # ⭐ STRCMP32 (2026-09-22) — see `slot_str_first_diff`. Whole-span
        # verdict first; the scalar ladder below is the COLD narrowing path.
        if bytes_equal(
            heap_a.view_range_ro(off_a, length).into_span(),
            heap_b.view_range_ro(off_b, length).into_span(),
        ):
            return -1
        var i = 0
        # Word arm: only while a FULL 8 bytes remain inside the compared span.
        while i + 8 <= length:
            if heap_a.read_u64_le_at(off_a + i) != heap_b.read_u64_le_at(
                off_b + i
            ):
                # Narrow to the exact byte, so `bytes_touched` is unchanged.
                var j = i
                while j < i + 8:
                    if heap_a.read_u8_at(off_a + j) != heap_b.read_u8_at(
                        off_b + j
                    ):
                        return j
                    j += 1
                return i
            i += 8
        while i < length:
            if heap_a.read_u8_at(off_a + i) != heap_b.read_u8_at(off_b + i):
                return i
            i += 1
        return -1

    def write_slot_str_from_storage(
        mut self,
        col_idx_in_storage: Int,
        slot: Int,
        src: ColumnFormatStorage,
        src_col_idx_in_storage: Int,
        src_slot: Int,
    ) raises:
        """Copy the STRING / BINARY payload at (`src_col_idx_in_storage`,
        `src_slot`) of `src` into (`col_idx_in_storage`, `slot`) of THIS
        storage — ONE `memcpy` heap-to-heap, no `List[UInt8]` intermediary.

        Byte-for-byte equivalent to
        `write_slot_str(col, slot, src.read_slot_str_bytes(src_col, src_slot))`:
        it reserves the same heap capacity, copies the same `length` bytes, and
        writes the same `(offset, length)` descriptor cell. It just sources
        them from the other storage's heap directly instead of round-tripping
        through an owned `List` and a per-byte store loop.

        Raises:
            On either col_idx out of range OR on either col not being a varlen
            col, matching `write_slot_str`.
        """
        if (
            col_idx_in_storage < 0
            or col_idx_in_storage >= self.col_buffers.len()
        ):
            raise Error(
                "ColumnFormatStorage.write_slot_str_from_storage: col_idx out"
                " of range"
            )
        if (
            src_col_idx_in_storage < 0
            or src_col_idx_in_storage >= src.col_buffers.len()
        ):
            raise Error(
                "ColumnFormatStorage.write_slot_str_from_storage: src col_idx"
                " out of range"
            )
        var var_idx = self.var_idx_for_col[col_idx_in_storage]
        var src_var_idx = src.var_idx_for_col[src_col_idx_in_storage]
        if var_idx < 0 or src_var_idx < 0:
            raise Error(
                "ColumnFormatStorage.write_slot_str_from_storage: col is not"
                " varlen (var_idx_for_col == -1)"
            )
        var src_cell = src.col_buffers[src_col_idx_in_storage].read_u64_le_at(
            src._slot_byte_offset(src_col_idx_in_storage, src_slot)
        )
        var src_off = Int(src_cell & UInt64(0xFFFFFFFF))
        var length = Int(src_cell >> 32)
        # Reserve FIRST — `reserve_var_bytes` may regrow (and therefore move)
        # this storage's heap, so no `ref` into it may be live across it.
        self.reserve_var_bytes(var_idx, length)
        var offset = self.var_data_used[var_idx]
        if length > 0:
            ref dst_heap = self.var_data_heaps[var_idx]
            dst_heap.copy_from_view_at(
                offset,
                src.var_data_heaps[src_var_idx].view_range_ro(
                    src_off, length
                ),
            )
        self.var_data_used[var_idx] = offset + length
        # Same descriptor layout as `write_slot_str` (low 4B offset, high 4B
        # length, one u64 store).
        var desc_cell: UInt64 = _var_desc_pack(offset, length)
        var byte_off = self._slot_byte_offset(col_idx_in_storage, slot)
        self.col_buffers[col_idx_in_storage].write_u64_le_at(
            byte_off, desc_cell
        )

    @always_inline
    def slot_str_fnv1a(
        self, col_idx_in_storage: Int, slot: Int
    ) raises -> UInt64:
        """STRHASH8 over the STRING / BINARY payload at (col, slot), read IN
        PLACE.

        Bit-identical to `_hash_bytes(read_slot_str_bytes(col, slot))` and to
        `strhash8_byteview` over the same bytes — but allocates nothing.

        ⚠ THE NAME IS HISTORICAL. This has not been FNV-1a since STRHASH8
        (2026-09-21); it is kept because it is the STORED-SIDE half of an
        agreement with four batch-side hashes, and renaming it would have
        touched every one of those call sites in the same commit that changed
        what they compute. See the STRHASH8 block at the top of this file for
        the full producer list and why they move together.

        Raises:
            On the col not being a varlen col (`var_idx_for_col[col] < 0`).
        """
        var var_idx = self.var_idx_for_col[col_idx_in_storage]
        if var_idx < 0:
            raise Error(
                "ColumnFormatStorage.slot_str_fnv1a: col is not varlen"
            )
        var byte_off = self._slot_byte_offset(col_idx_in_storage, slot)
        var desc_cell = self.col_buffers[col_idx_in_storage].read_u64_le_at(
            byte_off
        )
        var offset = Int(desc_cell & UInt64(0xFFFFFFFF))
        var length = Int(desc_cell >> 32)
        ref heap = self.var_data_heaps[var_idx]
        var h = strhash8_init(length)
        var i = 0
        while i + 8 <= length:
            h = strhash8_round(h, heap.read_u64_le_at(offset + i))
            i += 8
        if i < length:
            var r: UInt64 = UInt64(0)
            var sh: UInt64 = UInt64(0)
            while i < length:
                r = r | (UInt64(Int(heap.read_u8_at(offset + i))) << sh)
                sh += UInt64(8)
                i += 1
            h = strhash8_round(h, r)
        return strhash8_final(h)

    # ─────────────────────────────────────────────────────────────────────
    # ⭐⭐ MW-STRDRAIN (2026-09-19) — THE TWO BULK PRIMITIVES A *PARALLEL*
    # STRING DRAIN NEEDS, AND WHY NEITHER EXISTING READER CAN SERVE IT.
    #
    # The MULTIWAVE parallel finalize writes every radix partition's finalized
    # groups DIRECTLY into the FINAL Arrow buffers at a prefix-sum offset. A
    # var-width key needs two things from storage that no per-slot reader here
    # could give it without allocating:
    #
    #   1. the EXACT byte total of a partition's live slots, read from the
    #      8-byte descriptor cells only — the driver must prefix-sum the
    #      per-partition BYTE ranges before the fork, exactly as it already
    #      prefix-sums the ROW ranges, or two workers would write the same
    #      bytes of the shared `data` buffer;
    #   2. a payload copy that lands in a CALLER-OWNED buffer at a
    #      CALLER-CHOSEN offset.
    #
    # `read_slot_str_bytes` — the only byte-level reader that existed — returns
    # a freshly allocated `List[UInt8]`, i.e. ONE malloc/free pair per GROUP,
    # and the serial drain above it then built one owned `String` per group on
    # top of that. On ClickBench cbq33 (`GROUP BY url`, 18,342,019 groups,
    # 3,374,058,173 key bytes) that is 18.3M allocations and three full copies
    # of 3.37 GB, on ONE thread. These two primitives make it one copy, on N.
    # ─────────────────────────────────────────────────────────────────────

    def sum_slot_str_lens(
        self, col_idx_in_storage: Int, n_slots: Int
    ) raises -> Int:
        """Total byte length of the STRING / BINARY payloads of slots
        `[0, n_slots)` of column `col_idx_in_storage`.

        Reads ONLY the 8-byte descriptor cells (`length` is their high half),
        so no payload byte is touched and nothing is allocated — the same
        quantity `read_slot_str_len` returns per slot, summed, with the
        column/stride resolution hoisted out of the loop.

        Raises:
            On col_idx out of range OR on the col not being varlen.
        """
        if (
            col_idx_in_storage < 0
            or col_idx_in_storage >= self.col_buffers.len()
        ):
            raise Error(
                "ColumnFormatStorage.sum_slot_str_lens: col_idx out of range"
            )
        if self.var_idx_for_col[col_idx_in_storage] < 0:
            raise Error(
                "ColumnFormatStorage.sum_slot_str_lens: col is not varlen"
            )
        var desc = self.col_descriptors[col_idx_in_storage]
        var stride = _dtype_cell_bytes(desc.kind, desc.dtype_tag)
        ref buf = self.col_buffers[col_idx_in_storage]
        var total = 0
        for s in range(n_slots):
            total += Int(buf.read_u64_le_at(s * stride) >> 32)
        return total

    def copy_slot_str_into(
        self,
        col_idx_in_storage: Int,
        slot: Int,
        mut dst: OwnedAlignedBuffer,
        dst_offset: Int,
    ) raises -> Int:
        """Copy the STRING / BINARY payload at (col, slot) into `dst` starting
        at `dst_offset`, and return its byte length.

        ONE `memcpy` of the stored window into the caller's buffer — no
        `List[UInt8]`, no `String`, no per-byte accessor. Byte-for-byte the
        same bytes `read_slot_str_bytes` would have returned.

        The caller is responsible for `dst` being large enough at
        `dst_offset` (the parallel drain pre-sizes it to the exact prefix-sum
        total before the fork and never grows it).

        Raises:
            On col_idx out of range OR on the col not being varlen.
        """
        if (
            col_idx_in_storage < 0
            or col_idx_in_storage >= self.col_buffers.len()
        ):
            raise Error(
                "ColumnFormatStorage.copy_slot_str_into: col_idx out of range"
            )
        var var_idx = self.var_idx_for_col[col_idx_in_storage]
        if var_idx < 0:
            raise Error(
                "ColumnFormatStorage.copy_slot_str_into: col is not varlen"
            )
        var byte_off = self._slot_byte_offset(col_idx_in_storage, slot)
        var desc_cell = self.col_buffers[col_idx_in_storage].read_u64_le_at(
            byte_off
        )
        var offset = Int(desc_cell & UInt64(0xFFFFFFFF))
        var length = Int(desc_cell >> 32)
        if length > 0:
            dst.copy_from_view_at(
                dst_offset,
                self.var_data_heaps[var_idx].view_range_ro(offset, length),
            )
        return length

    # ─────────────────────────────────────────────────────────────────────
    # ⭐⭐ VARSTR-DRAINOUT (2026-09-20) — THE PER-GROUP ABI COST, REMOVED.
    #
    # `copy_slot_str_into` above is the correct primitive and stays. What it
    # is NOT is a primitive a 24,070,560-iteration loop can afford. Measured
    # on ClickBench `cbq16_user_phrase_topn` (`GROUP BY user_id,
    # search_phrase`, 99,997,497 rows, 24,070,560 groups) on the benchmark host:
    # `_RadixMwDrainTask::execute` is **42.85% of the whole query's cycles**;
    # 99.4% of that symbol's samples sit in ONE 0x1C0-byte window; and ~90% of
    # that window is MARSHALLING — a ~160-byte aggregate spilled to and
    # reloaded from the stack, per group, to move a mean payload of **25.2
    # bytes** (607,395,205 key bytes / 24,070,560 groups). A single
    # `vmovups ymm6,[r15+0x20]` carried 52% of the drain symbol on its own: a
    # loop-carried store->load in which a 32-byte load overlaps narrower recent
    # stores, i.e. a store-forwarding failure.
    #
    # ⭐ THE CAUSE IS THE CALL, NOT THE COPY. `copy_slot_str_into` is an
    # out-of-line `raises` function that takes `mut` of a big buffer struct and
    # inlines the whole `fast_copy_bytes` size ladder into itself; per group it
    # re-derives `var_idx_for_col[col]`, a 40-byte `ColDescriptor` copy, the
    # `_dtype_cell_bytes` cascade, two bounds checks and an sret error flag —
    # every one of them INVARIANT for the whole partition.
    #
    # ⭐ AND THE FIXED-WIDTH KEY COLUMNS ARE ALREADY CHEAP FOR EXACTLY THIS
    # REASON. DRAINOUT (, `hash_agg_untyped.mojo`) hoisted the same
    # re-derivation for them behind `drain_key_col` / `drain_key_stride` /
    # `read_key_i64_at`; VAR_STRING never got that treatment. `drain_str_stride`
    # + `slot_str_cell` below are that treatment — same shape, same argument.
    #
    # ⭐⭐ AND ONE THING THE FIXED PATH HAS NO NEED OF. A partition's var
    # payloads are APPENDED to `var_data_heaps[var_idx]` in slot order and
    # never rewritten — `write_slot_str` and `write_slot_str_from_storage` both
    # take `offset = var_data_used[var_idx]` and then advance it — so a
    # partition's live slots normally form ONE CONTIGUOUS RUN of the heap.
    # When they do, the whole partition is ONE memcpy instead of `n_slots` of
    # them.
    #
    # ⛔ THAT CONTIGUITY IS NOT ASSUMED. IT IS PROVEN, PER COLUMN, PER
    # PARTITION, PER DRAIN. The caller accumulates
    # `bad |= (offset[s] ^ running_end)` across the same descriptor-cell walk
    # it must already make to write the `offsets` entries, and takes the bulk
    # arm only on `bad == 0`. `offset[s] == running_end` for every s is the
    # EXACT per-slot contract, so a run that passes emits output byte-identical
    # to the per-slot arm BY CONSTRUCTION, not by resemblance. A never-written
    # slot (cell == 0) fails it and takes the per-slot arm. The check is free:
    # it rides a walk the caller owes anyway.
    # ─────────────────────────────────────────────────────────────────────

    def drain_str_stride(self, col_idx_in_storage: Int) raises -> Int:
        """VARSTR-DRAINOUT: the per-slot descriptor-cell stride of VARLEN
        column `col_idx_in_storage`, validated ONCE against the SAME predicate
        `copy_slot_str_into` applies per element — in range, and varlen.

        The VAR_STRING twin of `drain_key_stride`. The returned value is
        exactly what `_slot_byte_offset` divides by `slot`, so
        `slot * drain_str_stride(c) == _slot_byte_offset(c, slot)` holds by
        construction and `slot_str_cell` addresses the identical cell.

        Raises:
            On col_idx out of range OR on the col not being varlen.
        """
        if (
            col_idx_in_storage < 0
            or col_idx_in_storage >= self.col_buffers.len()
        ):
            raise Error(
                "ColumnFormatStorage.drain_str_stride: col_idx out of range"
            )
        if self.var_idx_for_col[col_idx_in_storage] < 0:
            raise Error(
                "ColumnFormatStorage.drain_str_stride: col is not varlen"
            )
        var desc = self.col_descriptors[col_idx_in_storage]
        return _dtype_cell_bytes(desc.kind, desc.dtype_tag)

    @always_inline
    def slot_str_cell(
        self, col_idx_in_storage: Int, slot: Int, stride: Int
    ) -> UInt64:
        """VARSTR-DRAINOUT: the raw 8-byte `(offset, length)` descriptor cell
        at (col, slot), with the stride SUPPLIED by the caller.

        `stride` MUST be `drain_str_stride(col_idx_in_storage)`. Low 4 bytes
        are the heap offset, high 4 the byte length — the layout
        `write_slot_str` writes and `copy_slot_str_into` reads, unchanged.

        ⚠ NON-RAISING AND `@always_inline` ON PURPOSE, and that is the whole
        point: this is the only thing a drain loop needs per group, and an
        out-of-line `raises` call to get it is the cost the block comment above
        measures. The validation it drops is not skipped — it is HOISTED into
        `drain_str_stride`, which the caller runs once per (column, partition).
        """
        return self.col_buffers[col_idx_in_storage].read_u64_le_at(
            slot * stride
        )

    def copy_str_run_into(
        self,
        col_idx_in_storage: Int,
        run_offset: Int,
        run_bytes: Int,
        mut dst: OwnedAlignedBuffer,
        dst_offset: Int,
    ) raises:
        """VARSTR-DRAINOUT: copy `run_bytes` of VARLEN column
        `col_idx_in_storage`'s payload heap, starting at heap byte
        `run_offset`, into `dst` at `dst_offset` — ONE `memcpy`.

        The bulk arm of the drain. The caller must have PROVEN, over the same
        descriptor-cell walk that wrote the `offsets` entries, that slots
        `[0, n_slots)` occupy exactly `[run_offset, run_offset + run_bytes)`
        of the heap in slot order. Under that proof this writes byte-for-byte
        what `copy_slot_str_into` would have written slot by slot.

        Called ONCE per (column, partition) — ~64 times per query against
        24,070,560 per-slot calls — so it validates in full and raises rather
        than trusting the caller, at a cost the drain cannot measure.

        Raises:
            On col_idx out of range, on the col not being varlen, or on the
            requested window not lying inside the heap's WRITTEN region
            (`var_data_used`), which is what makes a caller bug a refusal
            instead of a read of somebody else's bytes.
        """
        if (
            col_idx_in_storage < 0
            or col_idx_in_storage >= self.col_buffers.len()
        ):
            raise Error(
                "ColumnFormatStorage.copy_str_run_into: col_idx out of range"
            )
        var var_idx = self.var_idx_for_col[col_idx_in_storage]
        if var_idx < 0:
            raise Error(
                "ColumnFormatStorage.copy_str_run_into: col is not varlen"
            )
        if run_bytes <= 0:
            return
        if (
            run_offset < 0
            or run_offset + run_bytes > self.var_data_used[var_idx]
        ):
            raise Error(
                "ColumnFormatStorage.copy_str_run_into: run ["
                + String(run_offset)
                + ", "
                + String(run_offset + run_bytes)
                + ") is outside the written heap region [0, "
                + String(self.var_data_used[var_idx])
                + ")"
            )
        dst.copy_from_view_at(
            dst_offset,
            self.var_data_heaps[var_idx].view_range_ro(run_offset, run_bytes),
        )

    # ─────────────────────────────────────────────────────────────────────
    # Validity bitmap helpers
    #
    # Phase C-G.1 scaffolding: per-slot bit read/write. The dispatch
    # table at Phase C-G.5 wires per-batch validity propagation
    # (encode_batch reads source validity, sets dest bits in
    # validity_buffers[col]).
    # ─────────────────────────────────────────────────────────────────────

    @always_inline
    def set_slot_valid(
        mut self, col_idx_in_storage: Int, slot: Int, valid: Bool
    ) raises:
        """Set the validity bit for (col, slot).

        No-op if `validity_tracked == False` for this col (the validity
        buffer is empty — silently skipped to allow uniform-loop callers
        regardless of per-col validity tracking).

        Raises:
            On col_idx out of range.
        """
        if col_idx_in_storage < 0 or col_idx_in_storage >= self.col_buffers.len():
            raise Error(
                "ColumnFormatStorage.set_slot_valid: col_idx out of range"
            )
        var desc = self.col_descriptors[col_idx_in_storage]
        if not desc.validity_tracked:
            return
        var byte_idx = slot >> 3
        var bit_off = slot & 7
        var cur = self.validity_buffers[col_idx_in_storage].read_u8_at(byte_idx)
        if valid:
            cur = cur | (UInt8(1) << UInt8(bit_off))
        else:
            cur = cur & (~(UInt8(1) << UInt8(bit_off)))
        self.validity_buffers[col_idx_in_storage].write_u8_at(byte_idx, cur)

    @always_inline
    def is_slot_valid(
        self, col_idx_in_storage: Int, slot: Int
    ) raises -> Bool:
        """Return the validity bit for (col, slot).

        Returns True for non-tracked cols (no-null fast path; matches
        Arrow's "no validity buffer = all valid" convention).

        Raises:
            On col_idx out of range.
        """
        if col_idx_in_storage < 0 or col_idx_in_storage >= self.col_buffers.len():
            raise Error(
                "ColumnFormatStorage.is_slot_valid: col_idx out of range"
            )
        var desc = self.col_descriptors[col_idx_in_storage]
        if not desc.validity_tracked:
            return True
        var byte_idx = slot >> 3
        var bit_off = slot & 7
        var byte = self.validity_buffers[col_idx_in_storage].read_u8_at(byte_idx)
        return ((byte >> UInt8(bit_off)) & UInt8(1)) == UInt8(1)

    def any_slot_invalid(
        self, col_idx_in_storage: Int, n_slots: Int
    ) raises -> Bool:
        """True iff ANY of slots `[0, n_slots)` of `col_idx_in_storage` is NULL.

        The BULK form of `is_slot_valid`, and the distinction is the whole
        reason it exists. Asking the same question one slot at a time costs a
        bounds check, a descriptor load and a byte read PER SLOT; a caller with
        1.5 M live groups pays that 1.5 M times, which is the same order as the
        drain it is trying to enable. This reads the bitmap a BYTE at a time —
        8 slots per load, hoisting the bounds check and the descriptor out of
        the loop — so the same question costs ~1/8 the loads and no per-slot
        dispatch.

        Returns False for a non-tracked col (Arrow's "no validity buffer = all
        valid" convention, matching `is_slot_valid`) and for `n_slots <= 0`.

        ⚠ The tail byte is MASKED to the live bit count. The buffer is sized in
        bytes, so bits `[n_slots, 8*ceil(n_slots/8))` are whatever the
        allocation left there — reading them unmasked would report a NULL that
        no group has, and the caller's contract is exactness in BOTH directions
        (a false positive costs the fast path, a false negative renders a real
        NULL group as its byte twin).
        """
        if col_idx_in_storage < 0 or col_idx_in_storage >= self.col_buffers.len():
            raise Error(
                "ColumnFormatStorage.any_slot_invalid: col_idx out of range"
            )
        if n_slots <= 0:
            return False
        var desc = self.col_descriptors[col_idx_in_storage]
        if not desc.validity_tracked:
            return False
        ref buf = self.validity_buffers[col_idx_in_storage]
        var full_bytes = n_slots >> 3
        for b in range(full_bytes):
            if buf.read_u8_at(b) != UInt8(0xFF):
                return True
        var rem = n_slots & 7
        if rem != 0:
            var mask = UInt8((1 << rem) - 1)
            if (buf.read_u8_at(full_bytes) & mask) != mask:
                return True
        return False

    # ─────────────────────────────────────────────────────────────────────
    # Read-only diagnostic accessors
    # ─────────────────────────────────────────────────────────────────────

    @always_inline
    def n_cols(self) -> Int:
        """Number of cols in the layout."""
        return self.col_descriptors.__len__()

    @always_inline
    def col_descriptor(self, col_idx_in_storage: Int) -> ColDescriptor:
        """Return the ColDescriptor for `col_idx_in_storage`. Returns by
        value — ColDescriptor is POD-ish (Copyable + Movable)."""
        return self.col_descriptors[col_idx_in_storage]


# ─────────────────────────────────────────────────────────────────────────
# S1B-NOARGCOPY cold raise helpers (2026-09-22)
#
# These exist so the `@always_inline` hot writers above carry the PRECONDITION
# TEST inline and the DIAGNOSTIC out of line. They are free functions, not
# methods, deliberately: a `mut self`/`self` method on `ColumnFormatStorage`
# would re-introduce the 208-byte by-value argument marshal this stage exists
# to delete — even on a path that never executes, the marshal is emitted at
# the call site unconditionally.
#
# ⛔ Messages are byte-identical to the `raise Error(...)` bodies they replace.
# Tests assert on them.
# ─────────────────────────────────────────────────────────────────────────


@no_inline
def _raise_reserve_var_bytes_oob() raises:
    """Cold: `reserve_var_bytes` var_col_idx out of range."""
    raise Error(
        "ColumnFormatStorage.reserve_var_bytes: var_col_idx out of range"
    )


@no_inline
def _raise_wssfb_col_oob() raises:
    """Cold: `write_slot_str_from_byteview` col_idx out of range."""
    raise Error(
        "ColumnFormatStorage.write_slot_str_from_byteview: col_idx"
        " out of range"
    )


@no_inline
def _raise_wssfb_not_varlen() raises:
    """Cold: `write_slot_str_from_byteview` col is not varlen."""
    raise Error(
        "ColumnFormatStorage.write_slot_str_from_byteview: col is not"
        " varlen (var_idx_for_col == -1); ensure ColDescriptor.kind is"
        " COL_VAR_STRING or COL_VAR_BINARY"
    )
