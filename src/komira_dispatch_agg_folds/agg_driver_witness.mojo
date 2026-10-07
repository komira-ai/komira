# =============================================================================
# agg_driver_witness — WHICH DRIVER ACTUALLY SERVED THE AGGREGATE
# =============================================================================
#
# ⛔ THE DEFECT THIS EXISTS TO CLOSE (measured).
# The aggregate strategy trace printed ONE line per aggregate site —
# `[AST] door=leaf2 site=_build_and_run_agg ... route=spill_or_strategy` — and
# that line names the DECISION POINT, not the driver that ultimately serves the
# aggregate. A benchmark record: a two-point commit A/B on
# `hc/hc2_agg_100m_multi` moved the wall from 1,602.8 ms to 31,963.3 ms (19.94x,
# zero overlap between the arms' sample ranges) while that trace line printed
# BYTE-IDENTICALLY on both arms. The flip happens BELOW the decision point:
# `route=spill_or_strategy` is the SAME branch whether the grace-hash spill
# envelope then ADMITS the aggregate (spill driver serves it) or DECLINES it
# (fall through to the strategy leaf). A trace that reads identically across a
# 20x regression is worse than no trace, because it gets quoted as evidence of
# sameness — which is exactly what happened for five days.
#
# WHAT THIS MODULE IS. The process-global witness for the DRIVER verdict the
# `[AST-DRIVER]` line prints, recorded ONCE PER AGGREGATE SITE (never per morsel,
# never per row) at the point where the driver has actually been chosen AND has
# returned a result. Two slots, and they are deliberately BOTH here:
#
#   * `route`  — what the decision point said (the pre-existing `route=` field).
#   * `driver` — who actually served it.
#
# Keeping them in one module is what makes the blindness TESTABLE: a regression
# test can assert that two shapes agree on `route` and DISAGREE on `driver`, i.e.
# assert the precise property the old trace lacked. A test that only checked
# "the driver field is present" would pass against a constant.
#
# WHY A COUNTER TOO. The third slot counts driver emissions, so a test can pin
# "exactly one driver verdict per aggregate" — the anti-flood invariant. A trace
# that printed per morsel on a 100M-row cell would be turned off, and then we are
# back to having no trace at all.
#
# MECHANISM: a name-keyed, init-once, cross-compile-unit process-global
# `Atomic[int64]` via the stdlib `_Global` runtime slot — the SAME idiom as
# `mark_semi_anti_route_counter` / `komira_parquet.dict_mat_counter`. ⛔ NO NEW
# ENV VAR (engine behaviour is derived, not configured):
# the recording is unconditional and costs two relaxed atomic stores per
# aggregate, and the aggregate strategy trace — the EXISTING lever — is the only
# thing that gates the PRINT.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, alloc

from komira_dispatch_agg_folds.agg_spill_envelope import SPILL_ENV_NOT_CONSULTED


# -----------------------------------------------------------------------------
# The DRIVER vocabulary — one code per body that can actually fold an aggregate
# to its result. Ordered by the order `_build_and_run_agg` reaches them.
# -----------------------------------------------------------------------------
comptime AGG_DRIVER_NONE: Int = 0
"""No driver has run in this process yet (or the shape declined before one)."""
comptime AGG_DRIVER_VECTOR_DECODE_LEAF: Int = 1
"""`materialize_parquet_untyped_agg_subrg` — the sub-RG fold-and-free leaf."""
comptime AGG_DRIVER_GRACE_HASH_SPILL: Int = 2
"""`run_grace_hash_agg_spill` — the two-phase decode-then-fold spill driver."""
comptime AGG_DRIVER_STRATEGY_LEAF: Int = 3
"""`materialize_parquet_untyped_agg` — the flat/radix/perfect-hash leaf. The
`strategy=` field on the same trace line says WHICH of the three ran; they are
one driver because they are one call with one table family behind it."""
comptime AGG_DRIVER_GRACE_HASH_SPILL_YIELD: Int = 4
"""The bounded-output sibling of the spill driver (`execute_agg_plan_yield`)."""
comptime AGG_DRIVER_INMEM_LEAF: Int = 5
"""`_drive_inmem_agg` — the resident over-a-breaker-child in-mem leaf."""
comptime AGG_DRIVER_RESIDENT_GRACE_HASH_SPILL: Int = 6
"""`run_grace_hash_agg_spill_resident` — the resident spill route."""
comptime AGG_DRIVER_CMTOPK: Int = 7
"""`materialize_parquet_cmtopk_agg` — the certified count-bound top-K: a count
sketch scan, then the strategy leaf's sink over the candidate rows only. It
returns the same rows the strategy leaf would (value-invariant), so this code
and the `CMTOPK` counters are the only way to tell which one served."""


def agg_driver_name(code: Int) -> StaticString:
    """The driver name the `[AST-DRIVER]` line prints. ONE definition, shared by
    the print and by every reader of the witness, so the recorded verdict and the
    printed verdict cannot drift apart."""
    if code == AGG_DRIVER_VECTOR_DECODE_LEAF:
        return "vector_decode_leaf"
    if code == AGG_DRIVER_GRACE_HASH_SPILL:
        return "grace_hash_spill"
    if code == AGG_DRIVER_STRATEGY_LEAF:
        return "strategy_leaf"
    if code == AGG_DRIVER_GRACE_HASH_SPILL_YIELD:
        return "grace_hash_spill_yield"
    if code == AGG_DRIVER_INMEM_LEAF:
        return "inmem_leaf"
    if code == AGG_DRIVER_RESIDENT_GRACE_HASH_SPILL:
        return "resident_grace_hash_spill"
    if code == AGG_DRIVER_CMTOPK:
        return "cmtopk_certified_topk"
    return "none"


# -----------------------------------------------------------------------------
# The ROUTE vocabulary — the pre-existing `route=` field of the `[AST]` decision
# line, promoted to a code so the decision and the outcome are comparable. The
# STRINGS are unchanged: existing artifacts and campaign scripts that grep
# `route=vector_decode` / `route=spill_or_strategy` / `route=strategy_leaf`
# keep reading exactly what they read before.
# -----------------------------------------------------------------------------
comptime AGG_ROUTE_NONE: Int = 0
comptime AGG_ROUTE_VECTOR_DECODE: Int = 1
comptime AGG_ROUTE_SPILL_OR_STRATEGY: Int = 2
comptime AGG_ROUTE_STRATEGY_LEAF: Int = 3


def agg_route_name(code: Int) -> StaticString:
    """The `route=` value of the `[AST]` decision line."""
    if code == AGG_ROUTE_VECTOR_DECODE:
        return "vector_decode"
    if code == AGG_ROUTE_SPILL_OR_STRATEGY:
        return "spill_or_strategy"
    if code == AGG_ROUTE_STRATEGY_LEAF:
        return "strategy_leaf"
    return "none"


def _init_agg_witness_slot() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn (non-raising): allocate one witness Atomic per process,
    initialised to 0. Mirrors `mark_semi_anti_route_counter`'s init (`alloc` +
    a zero write + `OwnedPointer(unsafe_from_raw_pointer=)`) since
    `Atomic` is not movable-by-value. ONE init fn serves all six slots — they
    differ only in the `_Global` NAME, which is what keys the storage."""
    # SAFETY: `alloc` returns one uninitialised `AtomicI64` slot, owned by
    # this function until the `OwnedPointer` below takes it. The zero write
    # initialises it through an int64 view of the same bytes (an `AtomicI64`
    # holds one int64). From then on the returned `OwnedPointer` owns the
    # slot and frees it when it is destroyed; `_Global` keeps that
    # `OwnedPointer` in its process-global slot.
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _AGG_DRIVER_LAST = _Global[
    "komira_engine_agg_driver_last", _init_agg_witness_slot,
]
comptime _AGG_ROUTE_LAST = _Global[
    "komira_engine_agg_route_last", _init_agg_witness_slot,
]
comptime _AGG_DRIVER_FIRES = _Global[
    "komira_engine_agg_driver_fires", _init_agg_witness_slot,
]
comptime _AGG_SPILL_ENV_LAST = _Global[
    "komira_engine_agg_spill_env_last", _init_agg_witness_slot,
]

# -----------------------------------------------------------------------------
# ⭐ THE STRING-MIN/MAX ARMING WITNESS (2026-09-18).
# -----------------------------------------------------------------------------
# ⛔ THE DEFECT THIS EXISTS TO CLOSE, AND IT IS THE INVERSE OF THE ONE ABOVE.
# `fold_grouped_string_minmax_over_batch` is DECLINE-RETURNING: handed a shape it
# does not serve it returns None and the caller walks on. So a caller that arms
# it on a predicate too WIDE produces the RIGHT ANSWER by a WRONGER ROUTE, and
# there is no value, no row count and no schema anywhere downstream that differs.
# That is exactly what happened: `_run_agg_over_batch` armed the fold on the
# STRUCTURAL `grouped_string_minmax_servable`, which cannot tell
# `min(<varchar>)` from `min(<bigint>)`, so TPC-H q2's NUMERIC grouped MIN
# entered a fold that exists for strings, paid a per-row group-key render, and
# declined. +51.8% wall, VALUE_IDENTICAL on both parity runs.
#
# TWO SLOTS, AND THE PAIR IS THE POINT — one counts the ARMING, the other the
# per-row WORK, and the two halves of the fix are pinned separately:
#   * `calls`      the fold was ENTERED. The CALLER's gate is what moves this,
#                  so "a numeric grouped min/max never enters the string fold"
#                  is `calls == 0` after driving the resident arm.
#   * `row_passes` the fold reached its per-row phase. The FOLD's own internal
#                  order is what moves this, so "a direct call with a numeric
#                  input declines without touching a row" is `calls == 1 and
#                  row_passes == 0`.
# A test that pinned only the first would go green again if someone re-widened
# the fold's internals; one that pinned only the second would go green again if
# someone re-widened the caller's gate. Neither alone is the regression test.
#
# ⛔ NO NEW ENV VAR and no print — same rule as the driver witness above: two
# relaxed atomic adds per aggregate SITE (never per morsel, never per row).
comptime _AGG_STR_MINMAX_CALLS = _Global[
    "komira_engine_agg_str_minmax_calls", _init_agg_witness_slot,
]
comptime _AGG_STR_MINMAX_ROW_PASSES = _Global[
    "komira_engine_agg_str_minmax_row_passes", _init_agg_witness_slot,
]


@always_inline
def agg_driver_record(code: Int, spill_env_code: Int) raises:
    """Record the driver that SERVED this aggregate + the spill envelope's answer,
    and count the emission.

    `spill_env_code` is a `SPILL_ENV_*` code (`SPILL_ENV_NOT_CONSULTED` when this
    aggregate never reached the spill arm) — the ON WHAT TERMS half. It is
    recorded, not only printed, because "the envelope admitted a shape it used to
    decline" is the exact quantity the hc2 regression turned on, and a test that
    could not read it back could not tell an admit from a decline.

    Three relaxed atomic ops, ONCE PER AGGREGATE SITE. `raises` only to propagate
    the stdlib `_Global.get_or_create_ptr` signature — never raises at runtime."""
    # SAFETY: FFI carve-out. `get_or_create_ptr` targets KGEN-runtime-managed
    # static storage (process-lifetime); `MutUntrackedOrigin` is the stdlib
    # `_Global` API's own return type, confined to this helper. The outer deref
    # yields the process-global `OwnedPointer`; the inner deref the `Atomic`.
    var dp = _AGG_DRIVER_LAST.get_or_create_ptr()
    dp[][].store(Scalar[DType.int64](code))
    var ep = _AGG_SPILL_ENV_LAST.get_or_create_ptr()
    ep[][].store(Scalar[DType.int64](spill_env_code))
    var fp = _AGG_DRIVER_FIRES.get_or_create_ptr()
    _ = fp[][].fetch_add(Int64(1))


@always_inline
def agg_route_record(code: Int) raises:
    """Record what the DECISION POINT chose, before any driver has run."""
    # SAFETY: FFI carve-out (see `agg_driver_record`).
    var rp = _AGG_ROUTE_LAST.get_or_create_ptr()
    rp[][].store(Scalar[DType.int64](code))


def agg_driver_last() raises -> Int:
    """The driver code of the most recent aggregate served in this process."""
    # SAFETY: FFI carve-out (see `agg_driver_record`).
    var dp = _AGG_DRIVER_LAST.get_or_create_ptr()
    return Int(dp[][].load())


def agg_route_last() raises -> Int:
    """The route code of the most recent aggregate DECISION in this process."""
    # SAFETY: FFI carve-out (see `agg_driver_record`).
    var rp = _AGG_ROUTE_LAST.get_or_create_ptr()
    return Int(rp[][].load())


def agg_spill_env_last() raises -> Int:
    """The `SPILL_ENV_*` code the most recent driver verdict carried."""
    # SAFETY: FFI carve-out (see `agg_driver_record`).
    var ep = _AGG_SPILL_ENV_LAST.get_or_create_ptr()
    return Int(ep[][].load())


def agg_driver_fire_count() raises -> Int:
    """How many driver verdicts have been recorded — the anti-flood pin."""
    # SAFETY: FFI carve-out (see `agg_driver_record`).
    var fp = _AGG_DRIVER_FIRES.get_or_create_ptr()
    return Int(fp[][].load())


@always_inline
def agg_str_minmax_fold_record_call() raises:
    """Count ONE entry into `fold_grouped_string_minmax_over_batch`. Recorded at
    the top of the fold, before any guard, so it answers "did a caller arm this
    fold on this shape" and nothing else."""
    # SAFETY: FFI carve-out (see `agg_driver_record`).
    var cp = _AGG_STR_MINMAX_CALLS.get_or_create_ptr()
    _ = cp[][].fetch_add(Int64(1))


@always_inline
def agg_str_minmax_fold_record_row_work() raises:
    """Count ONE entry into the fold's PER-ROW phase — i.e. every decline has
    already been resolved and the fold is about to serve the node. ⛔ This must
    be recorded AFTER the last `return None`, never before one: the whole point
    is that it separates "declined cheaply" from "did O(rows) work"."""
    # SAFETY: FFI carve-out (see `agg_driver_record`).
    var rp = _AGG_STR_MINMAX_ROW_PASSES.get_or_create_ptr()
    _ = rp[][].fetch_add(Int64(1))


def agg_str_minmax_fold_calls() raises -> Int:
    """How many times the STRING MIN/MAX fold has been ENTERED in this process —
    the ARMING witness. A numeric grouped min/max must not move it."""
    # SAFETY: FFI carve-out (see `agg_driver_record`).
    var cp = _AGG_STR_MINMAX_CALLS.get_or_create_ptr()
    return Int(cp[][].load())


def agg_str_minmax_fold_row_passes() raises -> Int:
    """How many of those entries reached the fold's PER-ROW phase — the
    WORK witness. A decline must not move it."""
    # SAFETY: FFI carve-out (see `agg_driver_record`).
    var rp = _AGG_STR_MINMAX_ROW_PASSES.get_or_create_ptr()
    return Int(rp[][].load())


def reset_agg_driver_witness() raises:
    """Clear every slot in this module (test setup) — the four driver/route slots
    and the two STRING MIN/MAX arming slots."""
    # SAFETY: FFI carve-out (see `agg_driver_record`).
    var dp = _AGG_DRIVER_LAST.get_or_create_ptr()
    dp[][].store(Scalar[DType.int64](AGG_DRIVER_NONE))
    var rp = _AGG_ROUTE_LAST.get_or_create_ptr()
    rp[][].store(Scalar[DType.int64](AGG_ROUTE_NONE))
    var ep = _AGG_SPILL_ENV_LAST.get_or_create_ptr()
    ep[][].store(Scalar[DType.int64](SPILL_ENV_NOT_CONSULTED))
    var fp = _AGG_DRIVER_FIRES.get_or_create_ptr()
    fp[][].store(Scalar[DType.int64](0))
    var cp = _AGG_STR_MINMAX_CALLS.get_or_create_ptr()
    cp[][].store(Scalar[DType.int64](0))
    var sp = _AGG_STR_MINMAX_ROW_PASSES.get_or_create_ptr()
    sp[][].store(Scalar[DType.int64](0))
