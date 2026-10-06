# =============================================================================
# combine_agg_plan.mojo — AGGCOMBVEC (2026-09-03): the per-AGG constants a
# state-cell merge re-derives on EVERY (source slot, agg) pair.
# =============================================================================
#
# This is `combine_key_plan.mojo`'s sibling on the AGG side, and it exists for
# the same reason: `HashAggTable_Untyped._merge_agg_cells` re-derives, per
# (source slot, agg), a set of facts that are fixed for the whole
# `combine_from` CALL.
#
# ⭐ THE MEASUREMENT THAT MOTIVATED IT, counted from operation counters and not
# inferred (`bench/results/hc2_agg_mechanism_0903/`, on the benchmark host,
# `perf record -e instructions` per-SYMBOL totals, DuckDB v1.5.5):
#
#   | operation                              |  komira | DuckDB | ratio |
#   |----------------------------------------|--------:|-------:|------:|
#   | merge one aggregate cell (one 64-bit +) |    ~50  |   ~8   |  6.3x |
#   | probe one hash slot, combine side       |    238  |   62   |  3.9x |
#
# and COMBINE (merge + probe) is **51.6% of `hc/hc2`'s attributed instruction
# excess over DuckDB and 49.7% of `hc/hc1`'s** — at PARITY operation counts (we
# allocate 0.25% FEWER hash-table states than DuckDB does; the excess is
# entirely per-operation cost, and our IPC is BETTER on three of the four cells
# measured).
#
# What those ~50 instructions do, to perform one 64-bit add:
#
#   * `agg_descriptors[a]` — a bounds-checked `List` index producing a
#     **32-byte `AggSpec` struct copy**;
#   * `self.agg_state_buffers[a]` AND `src.agg_state_buffers[a]` — two more
#     bounds-checked indexes, reloading BOTH buffer base pointers;
#   * `src.agg_touched[src_slot * n_aggs + a]` + a conditional
#     `self.agg_touched[dst_slot * n_aggs + a]` — two more bounds-checked
#     accesses, each with a multiply;
#   * a runtime `op_tag` if/elif ladder **up to 9 deep** (`hc2`'s `AVG_F64` is
#     the 7th arm);
#   * and only then the actual
#     `write_u64_le_at(d, read_u64_le_at(d) + read_u64_le_at(s))`.
#
# Every one of those is loop-invariant per `(combine call, agg)`. DuckDB's
# counterpart is ONE template instantiation of `StateCombine<SumState<...>>`
# over a 2048-wide vector: the state type, the offset and the operation are all
# compile time.
#
# ⭐ THIS IS THE TRANSFORMATION VECFOLD ALREADY MADE ON THE FOLD PATH. The
# combine had no monomorphic or vectorised twin at all. This file is the plan
# half; the kernels are `HashAggTable_Untyped._merge_agg_col_mono[mc, sel]`,
# which must be methods because they address the table's own state buffers.
#
# ⛔ WHERE `merge_cell_class` LIVES, AND WHY IT IS NOT HERE. The op-tag ->
# class MAPPING reads the `AGG_*` aliases, and those are declared in
# `hash_agg_untyped.mojo`, which imports THIS file. Putting the mapper here
# would need the reverse import and close a module cycle; declaring a second
# copy of the tag values here would be two sources of truth that agree with
# each other until one is edited. So the mapper sits beside the aliases it
# reads (`HashAggTable_Untyped`'s file, `_merge_cell_class`), and what lives
# here is the part that depends on NOTHING: the class codes and their widths.
#
# ⚠ THIS FILE IS PURE — no table state, no allocation, every function total.
# Same rule `combine_key_plan.mojo` states: the op -> class mapping is the one
# thing a mutant can silently break (merge a MIN as an ADD and the answer is
# wrong with no crash), so it is testable without building a table.
#
# ⛔ WHAT THIS FILE DOES **NOT** COVER, AND WHY IT MUST NOT.
# `AGG_STDDEV_SAMP_F64` / `AGG_VAR_SAMP_F64` merge through the Chan/Welford
# parallel-merge formula, which is a 3-cell read-modify-write with two early
# exits and a division. `AGG_STDDEV_POP_F64` is NOT combine-stable at all and
# `_merge_agg_cells` RAISES on it. All three map to `MC_NONE`, which makes the
# whole call DECLINE to the unchanged checked arm — so the raise still happens,
# at the same call, with the same message. A class this file has not learned is
# byte-identical by CONSTRUCTION rather than by test, which is the same
# contract `build_key_cell_plan`'s decline carries.
# =============================================================================

# -----------------------------------------------------------------------------
# The merge-cell classes. One per DISTINCT per-cell kernel, NOT one per op —
# `AGG_SUM_I64` and `AGG_COUNT` are the same 64-bit add over the same 8-byte
# cell and share `MC_ADD_U64`, exactly as `_merge_agg_cells`' first arm already
# tests both tags together.
# -----------------------------------------------------------------------------

comptime MC_NONE: Int = 0
"""Not vectorisable by this file — the caller DECLINES to the checked arm."""

comptime MC_ADD_U64: Int = 1
"""`AGG_SUM_I64` / `AGG_COUNT`: one 8-byte cell, wrapping u64 add."""

comptime MC_ADD_F64: Int = 2
"""`AGG_SUM_F64`: one 8-byte cell, f64 add through the u64 wire encoding."""

comptime MC_MIN_I64: Int = 3
"""`AGG_MIN_I64`: one 8-byte cell, signed compare, store the source's BITS."""

comptime MC_MAX_I64: Int = 4
"""`AGG_MAX_I64`: one 8-byte cell, signed compare, store the source's BITS."""

comptime MC_MIN_F64: Int = 5
"""`AGG_MIN_F64`: one 8-byte cell, f64 compare."""

comptime MC_MAX_F64: Int = 6
"""`AGG_MAX_F64`: one 8-byte cell, f64 compare."""

comptime MC_AVG_F64: Int = 7
"""`AGG_AVG_F64`: TWO cells — f64 sum at `off`, u64 count at `off + 8`."""

comptime MC_ADD_I128: Int = 8
"""`AGG_SUM_I128` / `AGG_SUM_U128`: ONE two's-complement 128-bit value in two
words — `lo` at `off`, `hi` at `off + 8` — merged by an exact 128-bit add
(`int_sum_overflow.i128_words_add`). It cannot overflow, so unlike the 8-byte
`MC_ADD_U64` cell it has no check to make and no order to depend on."""

comptime MC_AVG_I128: Int = 9
"""`AGG_AVG_I128`: the exact 128-bit total (`lo` @off, `hi` @off+8) plus a
u64 non-null count @off+16 — `MC_ADD_I128`'s add on the first two words and an
integer add on the third."""


@always_inline
def merge_cell_class_bytes(mc: Int) -> Int:
    """The per-slot state width the class ADDRESSES, in bytes.

    ⭐ THE WIDTH AGREEMENT CHECK IS THE SAFETY PROPERTY, and it is the same one
    `build_key_cell_plan` makes for key cells. The monomorphic kernel addresses
    `slot * spec.state_byte_width + spec.state_offset_in_slot` and then reads
    8 (or 16) bytes from there. If a spec's declared `state_byte_width` is
    SMALLER than what the class reads, the kernel reads across into the NEXT
    SLOT's state — which merges a neighbouring group's partial into this one
    and produces a wrong number with no crash and no bounds trap.

    Returning the class's requirement here lets the caller compare it against
    the descriptor's own `state_byte_width` and DECLINE on disagreement,
    instead of trusting an invariant stated only in a docstring.

    ⚠ `MC_AVG_F64` and `MC_ADD_I128` need 16, not 8: their second word lives
    at `off + 8`.
    """
    if mc == MC_AVG_I128:
        return 24
    if mc == MC_AVG_F64 or mc == MC_ADD_I128:
        return 16
    if mc == MC_NONE:
        return 0
    return 8
