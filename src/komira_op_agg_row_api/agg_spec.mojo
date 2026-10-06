"""The aggregate-op tags (`AGG_*`), the per-aggregate descriptor `AggSpec`,
the op predicates every cell-level ladder asks, and the op-to-merge-class map."""


from komira_op_agg_row_api.combine_agg_plan import (
    MC_NONE,
    MC_ADD_U64,
    MC_ADD_F64,
    MC_MIN_I64,
    MC_MAX_I64,
    MC_MIN_F64,
    MC_MAX_F64,
    MC_AVG_F64,
    MC_ADD_I128,
    MC_AVG_I128,
)


# -----------------------------------------------------------------------------
# Agg op tags — mirror Spike 1 + Row Phase 2 dispatch ladder.
#
# Phase C-G.2 v0.4 GA set: SUM/COUNT/MIN/MAX for I64/F64; AVG_F64
# multi-cell (2 cells: sum + count); STDDEV_POP_F64 multi-cell (3 cells:
# mean + m2 + count via Welford). Additional DType variants land via
# Row Phase 2.A dispatch ladder reuse when wired through; the op_tag
# constants below cover what the test gates exercise.
#
# Value sources:
#   - These tags MUST be distinct constants for the inline if/elif
#     dispatch in `_apply_agg_update_inline` / `_init_agg_cells_inline`.
#   - The Row UNTYPED `row_block.mojo` Phase 2.A landed a ~34-op constant
#     set; we mirror the load-bearing subset here. Sharing the exact
#     numerical values is NOT required because dispatch happens on the
#     local constant set; the Phase C-G.5 unified dispatch table will
#     reconcile if needed (op_tag is a private contract between
#     AggSpec and the kernel dispatch).
# -----------------------------------------------------------------------------

comptime AGG_NONE: UInt8 = 0
"""Sentinel: no agg op set."""

comptime AGG_SUM_I64: UInt8 = 1
"""SUM(I64): 1 cell, 8B. Init=0; update=cur+input; finalize=Int64."""

comptime AGG_SUM_F64: UInt8 = 2
"""SUM(F64): 1 cell, 8B (F64 bits). Init=0.0; update=cur+input."""

comptime AGG_COUNT: UInt8 = 3
"""COUNT(*): 1 cell, 8B. Init=0; update=cur+1; ignores input col."""

comptime AGG_MIN_I64: UInt8 = 4
"""MIN(I64): 1 cell, 8B. Init=INT64_MAX; update=min(cur, input)."""

comptime AGG_MAX_I64: UInt8 = 5
"""MAX(I64): 1 cell, 8B. Init=INT64_MIN; update=max(cur, input)."""


comptime AGG_MIN_F64: UInt8 = 6
"""MIN(F64): 1 cell, 8B. Init=+inf; update=min(cur, input)."""

comptime AGG_MAX_F64: UInt8 = 7
"""MAX(F64): 1 cell, 8B. Init=-inf; update=max(cur, input)."""

comptime AGG_AVG_F64: UInt8 = 8
"""AVG(F64): 2 cells, 16B. Cell 0: F64 sum @0; cell 1: I64 count @8.
Finalize: sum / count."""

comptime AGG_STDDEV_POP_F64: UInt8 = 9
"""STDDEV_POP(F64): 3 cells, 24B (Welford).
Cell 0: F64 mean @0; cell 1: F64 m2 @8; cell 2: I64 count @16.
Finalize: sqrt(m2 / count)."""

comptime AGG_STDDEV_SAMP_F64: UInt8 = 10
"""STDDEV_SAMP(F64): 3 cells, 24B (Welford), ddof=1.
Cell 0: F64 mean @0; cell 1: F64 m2 @8; cell 2: I64 count @16.
Finalize: sqrt(m2 / (count - 1)) for count > 1; NaN otherwise.

UNLIKE AGG_STDDEV_POP_F64, this op is COMBINE-STABLE via the
Chan/Welford parallel-merge formula (`_merge_agg_cells`), so it works
on the multi-batch parallel column-native path. Mirrors the concrete
`StddevSampF64` oracle (`agg/agg_state_slab.mojo`): same one-pass
Welford update, same Chan combine, same NaN-for-count<=1 finalize."""

comptime AGG_VAR_SAMP_F64: UInt8 = 11
"""VAR_SAMP(F64): 3 cells, 24B (Welford), ddof=1 — the no-sqrt sibling
of AGG_STDDEV_SAMP_F64.
Cell 0: F64 mean @0; cell 1: F64 m2 @8; cell 2: I64 count @16.
Finalize: m2 / (count - 1) for count > 1; NaN otherwise.

Identical state layout / update / Chan-combine to AGG_STDDEV_SAMP_F64;
only the finalize differs (no sqrt). COMBINE-STABLE."""


comptime AGG_MIN_U64: UInt8 = 12
"""MIN(U64): 1 cell, 8B. The UNSIGNED 64-bit sibling of `AGG_MIN_I64`.

⭐⭐ THE CELL, THE INIT, THE COMPARE AND THE COMBINE ARE `AGG_MIN_I64`'S,
UNCHANGED. What differs is ONE thing: the value is written into the cell
through the ORDER-PRESERVING BIAS `v XOR 2**63` (`_u64_to_biased_i64`) and read
back out through its inverse (`_biased_i64_to_u64`). See `_u64_to_biased_i64`
for why that makes the existing SIGNED comparison and the existing SIGNED init
sentinels exactly correct."""

comptime AGG_MAX_U64: UInt8 = 13
"""MAX(U64): 1 cell, 8B. The UNSIGNED 64-bit sibling of `AGG_MAX_I64`. See
`AGG_MIN_U64`."""


comptime AGG_MIN_STR: UInt8 = 14
"""MIN(<utf8>): 2 cells, 16B — the FIRST VARIABLE-WIDTH aggregate cell on this
table (STRMINMAX, 2026-09-20).

⭐⭐ THE CELL IS FIXED-WIDTH; THE **PAYLOAD** IS NOT. Cell 0 (`@off+0`) is a
byte OFFSET into `agg_var_heaps[_agg_var_idx[a]]`, this table's per-agg payload
arena; cell 1 (`@off+8`) packs `SET | cap | len` (see `_strcell_pack`). That
keeps EVERY existing cell-geometry site — `_agg_cell_off`, `_agg_buf_idx`, the
AGGROWSLOT packed row, `grow_to`'s per-agg buffer resize, the state-width
arithmetic — byte-for-byte unchanged, because as far as they are concerned
this is an `AGG_AVG_F64`-shaped 16-byte two-cell state.

⛔ THE **SET** BIT IS NOT REDUNDANT WITH `agg_touched`, AND ASSUMING IT WAS
WOULD BE A WRONG ANSWER ON THE EMPTY STRING. `_apply_agg_update` marks
`agg_touched` BEFORE the op ladder runs, so by the time this arm sees the cell
the mark is already 1; and `''` is a legal aggregand whose `(offset, len)` is
`(0, 0)` — bit-identical to a never-written cell. The set bit is the only thing
separating "no value has folded here yet" from "the running minimum is the
empty string".

⚠ WHY A CAPACITY, NOT A PURE APPEND. A bump-only arena grows by the TOTAL
improvement bytes: on ClickBench Q28 (`min(referer)`, 3,009,017 groups, 82-byte
mean value) that is several record-lows per group PER WORKER TABLE, i.e. a
multiple of the payload for nothing. Recording the allocation's capacity lets a
later winner that FITS overwrite in place, which bounds the arena at (sum over
groups of the longest value that ever won) — the same bound the ANSWER has."""

comptime AGG_MAX_STR: UInt8 = 15
"""MAX(<utf8>): 2 cells, 16B. The order-reversed sibling of `AGG_MIN_STR` —
identical cell, identical arena, identical init, identical merge shape; only
the comparison's direction differs. See `AGG_MIN_STR`."""


comptime AGG_SUM_I128: UInt8 = 16
"""SUM(<INT64>), EXACT: 2 cells, 16B — ONE two's-complement 128-bit total,
`lo` word @0, `hi` word @8 (2026-09-25). Init 0; update and merge are exact 128-bit adds
(`int_sum_overflow.i128_words_add`); readback narrows to INT64 or refuses by
name (`read_agg_i64`, through `int_sum_overflow.exact_sum_cell_fits`).

⭐⭐ WHY NOT THE 8-BYTE `AGG_SUM_I64` CELL. That cell refused at every fold and
every merge the moment a PARTIAL left Int64, so the verdict for one query
depended on how the rows were cut across workers and on the order the combine
read the partials: `sum(a) GROUP BY g` over {MAX, MAX, MIN, MIN} in four row
groups refused in about half the runs and answered DuckDB's -2 in the rest.
A 128-bit total cannot overflow (see `int_sum_overflow`), so the fold and the
merge are associative and commutative again and every order computes the same
number; only the NARROW at readback can refuse, and it sees the exact total.

⚠ THE PLANNER EMITS IT FOR A 64-BIT AGGREGAND ONLY
(`agg_node_exec._agg_op_for`). A narrower integer (i8..i32, u8..u32) keeps the
8-byte checked `AGG_SUM_I64` cell: fewer than 2^31 of its values cannot take
any partial outside Int64, so that cell's verdict is already order-independent
and the wider cell would be paid for nothing."""

comptime AGG_SUM_U128: UInt8 = 17
"""SUM(<UINT64>), EXACT: the unsigned sibling of `AGG_SUM_I128` — the SAME
16-byte cell, init, merge and 128-bit add; the addend is ZERO-extended (its
raw 64 bits are the value) and readback narrows to UINT64, handing back the
unsigned total's RAW BITS the way the biased MIN/MAX U64 cells do.

⛔ THE DEFECT IT CLOSES WAS A SILENT WRONG ANSWER: the
UINT64 aggregand used to enter the signed 8-byte `AGG_SUM_I64` cell as its raw
bits, i.e. as a NEGATIVE addend at or above 2^63, so the signed overflow
predicate never fired and {1, 3, 2^64-1} answered 3."""


comptime AGG_AVG_I128: UInt8 = 18
"""AVG(<INT64> / <UINT64>), EXACT: 3 cells, 24B — the exact 128-bit total
(`lo` @0, `hi` @8, `AGG_SUM_I128`'s layout) and the u64 non-null count @16.
Finalize divides the exact total ONCE (`Scalar[int128].cast[float64]` /
count). The addend's extension is chosen by the SOURCE dtype (a UINT64 value
zero-extends) — AVG's output is FLOAT64 either way, so unlike SUM it needs no
second tag.

⛔ THE DEFECT IT CLOSES: `AGG_AVG_F64`
summed an INT64 source in FLOAT64, which rounds every partial past 2^53, so the
grouped `avg(a)` over {2^53, 1, 1} answered ...330.5 or ...331.5 depending on
the order the partials merged (DuckDB: ...331.5). A narrower integer source
keeps `AGG_AVG_F64`: its partial sums stay exact in FLOAT64 below 2^53."""


@always_inline
def _is_exact_sum_op(op_tag: UInt8) -> Bool:
    """True iff `op_tag` is one of the two EXACT 128-bit SUM cells.

    ⚠ THE ONE PREDICATE EVERY CELL-LEVEL LADDER MUST ASK before it treats a
    16-byte cell: the state has `AGG_AVG_F64`'s WIDTH, and a ladder falling
    through to an F64 arm would read the low word of an integer as a double."""
    return op_tag == AGG_SUM_I128 or op_tag == AGG_SUM_U128


@always_inline
def _is_minmax_str_op(op_tag: UInt8) -> Bool:
    """True iff `op_tag` is a VAR-WIDTH (utf8) MIN/MAX cell.

    ⚠ THE ONE PREDICATE EVERY CELL-LEVEL LADDER MUST ASK BEFORE IT TREATS A
    16-BYTE CELL AS TWO NUMBERS. The state is the same WIDTH as `AGG_AVG_F64`'s
    and nothing about the geometry distinguishes them; a ladder that falls
    through to an F64 arm reads an arena offset as a double."""
    return op_tag == AGG_MIN_STR or op_tag == AGG_MAX_STR


@always_inline
def _is_minmax_u64_op(op_tag: UInt8) -> Bool:
    """True iff `op_tag` is one of the two BIASED unsigned MIN/MAX cells.

    ⚠ THE ONE PREDICATE EVERY READBACK MUST ASK. A drain that reads a biased
    cell without un-biasing publishes a number that is off by 2**63 — a
    plausible-looking wrong answer, not a crash."""
    return op_tag == AGG_MIN_U64 or op_tag == AGG_MAX_U64


@always_inline
def _is_minmax_i64_family(op_tag: UInt8) -> Bool:
    """True iff `op_tag` is a SIGNED-CELL MIN/MAX — the I64 pair or its BIASED
    U64 pair. Every cell-level operation (init, compare, merge, spill, byte
    compare) is identical across all four; only ingest and readback differ."""
    return (
        op_tag == AGG_MIN_I64 or op_tag == AGG_MAX_I64
        or op_tag == AGG_MIN_U64 or op_tag == AGG_MAX_U64
    )


@always_inline
def _merge_cell_class(op_tag: UInt8) -> Int:
    """AGGCOMBVEC: map an `AGG_*` op tag to its `MC_*` merge-cell class, or
    `MC_NONE` when this op has no monomorphic combine kernel.

    ⭐ THIS FUNCTION IS THE ENVELOPE, AND IT MUST AGREE WITH
    `_merge_agg_cells` ARM FOR ARM. Every tag it returns non-`MC_NONE` for is
    one whose per-cell merge is reproduced by `_merge_agg_col_mono`; every tag
    it returns `MC_NONE` for makes the WHOLE combine call decline to the
    unchanged checked ladder. A tag added to `_merge_agg_cells` and forgotten
    here declines — the safe direction. A tag mapped to the WRONG class here
    computes a wrong number with no crash, which is why
    `test_agg_combvec_byte_equiv.mojo` pins the whole table by value.

    ⚠ IT LIVES HERE, NOT IN `combine_agg_plan.mojo`, BECAUSE OF A MODULE
    CYCLE: it reads the `AGG_*` aliases declared above, and that file is
    imported BY this one. The class codes and their widths — the half that
    depends on nothing — are over there. See that file's header.

    ⛔ `AGG_STDDEV_POP_F64` / `AGG_STDDEV_SAMP_F64` / `AGG_VAR_SAMP_F64` and
    `AGG_NONE` fall through to `MC_NONE` DELIBERATELY. The two Chan-stable ones
    merge through a 3-cell Welford formula with two early exits and a division;
    `STDDEV_POP` is not combine-stable at all and `_merge_agg_cells` RAISES on
    it. Declining keeps that raise at the same call site with the same message.
    """
    if op_tag == AGG_SUM_I64 or op_tag == AGG_COUNT:
        return MC_ADD_U64
    if _is_exact_sum_op(op_tag):
        return MC_ADD_I128
    if op_tag == AGG_AVG_I128:
        return MC_AVG_I128
    if op_tag == AGG_SUM_F64:
        return MC_ADD_F64
    # UINT64-MINMAX-DOMAIN: the biased U64 cells merge with the SAME signed
    # comparator on the SAME bytes — the bias is order-preserving, so
    # `_merge_agg_col_mono`'s MC_MIN_I64 kernel is literally the right one.
    if op_tag == AGG_MIN_I64 or op_tag == AGG_MIN_U64:
        return MC_MIN_I64
    if op_tag == AGG_MAX_I64 or op_tag == AGG_MAX_U64:
        return MC_MAX_I64
    if op_tag == AGG_MIN_F64:
        return MC_MIN_F64
    if op_tag == AGG_MAX_F64:
        return MC_MAX_F64
    if op_tag == AGG_AVG_F64:
        return MC_AVG_F64
    return MC_NONE


@always_inline
def _dtype_is_integer(dt: DType) -> Bool:
    """AGG-OVER-CODES eligibility helper: True iff `dt` is a fixed-width signed
    or unsigned integer. Used to gate AVG-over-codes to INTEGER aggregands
    (exact int->f64 sum -> order-independent under the dense-then-combine fold
    reorder)."""
    return (
        dt == DType.int8 or dt == DType.int16 or dt == DType.int32
        or dt == DType.int64 or dt == DType.uint8 or dt == DType.uint16
        or dt == DType.uint32 or dt == DType.uint64
    )


# -----------------------------------------------------------------------------
# AggSpec — per Column UNTYPED v0.4 §4.5.
#
# Multi-cell state via `state_byte_width`: per-op kernel knows its own
# cell layout; AggSpec carries only the byte budget for storage
# allocation. v0.2 fix-up (mojo-expert #5): state_dtype made
# kernel-internal so the dispatch site can pivot on op_tag alone.
#
# v0.3+ adds `state_offset_in_slot` so multiple aggs can share ONE
# MmapAlignedBuffer storage (offset cell within slot). Phase C-G.2 uses
# one buffer per agg (parallel Slab) so state_offset_in_slot is unused
# at C-G.2 (set to 0); Phase C-G.5 SoA hoist will activate per-buffer
# packing if perf-engineer measurements justify it.
# -----------------------------------------------------------------------------


@fieldwise_init
struct AggSpec(Copyable, Movable, ImplicitlyCopyable, Deinitable):
    """Per-agg metadata bag — runtime-determined per query.

    Storage fields:
        op_tag: One of the AGG_* constants. Discriminates the kernel
            (init + update + finalize) at dispatch time.
        src_col_idx: Source col index in the input BatchView for the
            agg input. -1 reserved for COUNT(*) (no input col).
        state_byte_width: Total per-slot state byte width. 8 for
            SUM/MIN/MAX/COUNT (1 cell); 16 for AVG (sum+count, 2 cells);
            24 for STDDEV_POP (mean+m2+count, 3 cells). Per Spike 5 POC.
        state_offset_in_slot: Byte offset within the per-agg buffer cell
            where this agg's state cells begin. C-G.2 uses one buffer
            per agg so this is 0; Phase C-G.5 SoA hoist will pack
            multiple aggs into one buffer at non-zero offsets.

    Invariants (caller-enforced at upsert_batch):
        - op_tag in {AGG_*} (NOT AGG_NONE).
        - src_col_idx >= -1.
        - state_byte_width in {8, 16, 24} for the C-G.2 GA set.
        - state_offset_in_slot == 0 at C-G.2 (Phase C-G.5 relaxes).
    """

    var op_tag: UInt8
    var src_col_idx: Int
    var state_byte_width: UInt16
    var state_offset_in_slot: Int
