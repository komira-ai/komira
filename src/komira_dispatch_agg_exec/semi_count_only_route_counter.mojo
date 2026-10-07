# =============================================================================
# semi_count_only_route_counter — process-global reachability counter for the
# scalar-COUNT(*)-over-SEMI/ANTI-join count-only intercept
# =============================================================================
#
# R2 CB20 SINGLE-DECODE COUNT-ONLY. Reachability
# witness for the SQL-path scalar-COUNT(*)-over-SEMI/ANTI-join intercept in
# `execute_agg_plan` (agg_node_exec.mojo). cb20 (`count(*) FROM hits WHERE
# user_id IN (SELECT user_id FROM hits WHERE region_id=229)`) is a scalar
# COUNT(*) over a self-SEMI join. Before the fix the agg exec `_materialize_
# subplan_local`'d the whole SEMI join to a resident batch (GATHERING the
# ~18.78M survivors) just to read `num_rows()`; after the fix the intercept
# drives the count-only path (`materialize_inmem_build_inmem_probe_join`'s
# `count_only=True` branch — tally via `probe_semi_count`/`probe_anti_count`, NO
# survivor gather) and returns a 0-column `RecordBatch.count_only(N)`.
#
# A COUNTER (not a result assertion) is the correct reachability falsifier: the
# count-only path and the gather-then-count walker path are byte-identical on the
# RESULT (the same scalar count), so a result assertion cannot tell whether the
# gather was skipped — only the fire count distinguishes "drove the count-only
# intercept" (after) from "fell through to the gather walker" (before, simulated
# by `execute_agg_plan`'s `allow_semi_count_only=False` test-oracle parameter,
# which declines the intercept — it replaced an environment kill-switch).
# Incremented ONCE per intercept firing (a single relaxed atomic add), so the
# always-on cost is a few nanoseconds per scalar-COUNT(*)-over-SEMI/ANTI query.
#
# Mechanism: a name-keyed, init-once, cross-compile-unit process-global
# `Atomic[int64]` via the stdlib `_Global` runtime slot — the SAME idiom as
# `mark_semi_anti_route_counter.mojo`,
# `komira_engine_operators/residual_latemat_counter.mojo`, and
# `komira_parquet/dict_mat_counter.mojo`; no env var, no `unsafe_from_address`
# laundering.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, alloc


def _init_semi_count_only_route_counter() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn (non-raising): allocate the counter Atomic once per
    process, initialised to 0. Mirrors
    `mark_semi_anti_route_counter._init_mark_semi_anti_route_counter` (`alloc` +
    a zero write + `OwnedPointer(unsafe_from_raw_pointer=)`) since `Atomic`
    is not movable-by-value."""
    # SAFETY: `alloc` returns one uninitialised `AtomicI64` slot, owned by
    # this function until the `OwnedPointer` below takes it. The zero write
    # initialises it through an int64 view of the same bytes (an `AtomicI64`
    # holds one int64). From then on the returned `OwnedPointer` owns the
    # slot and frees it when it is destroyed; `_Global` keeps that
    # `OwnedPointer` in its process-global slot.
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _SEMI_COUNT_ONLY_ROUTE = _Global[
    "komira_dispatch_semi_count_only_fire_count",
    _init_semi_count_only_route_counter,
]


@always_inline
def semi_count_only_fire_incr() raises:
    """Record ONE firing of the scalar-COUNT(*)-over-SEMI/ANTI-join count-only
    intercept. One relaxed atomic add per query that routes through the count-only
    path. `raises` only to propagate the stdlib `_Global.get_or_create_ptr`
    signature — never raises at runtime."""
    # SAFETY: FFI carve-out. `get_or_create_ptr` targets KGEN-runtime-managed
    # static storage (process-lifetime); `MutUntrackedOrigin` is the stdlib
    # `_Global` API's own return type, confined to this helper. The outer deref
    # yields the process-global `OwnedPointer`; the inner deref the `Atomic`.
    var gp = _SEMI_COUNT_ONLY_ROUTE.get_or_create_ptr()
    _ = gp[][].fetch_add(Int64(1))


def semi_count_only_fire_count() raises -> Int:
    """Read the process-wide count of count-only-intercept firings."""
    # SAFETY: FFI carve-out (see `semi_count_only_fire_incr`).
    var gp = _SEMI_COUNT_ONLY_ROUTE.get_or_create_ptr()
    return Int(gp[][].load())


def reset_semi_count_only_fire_count() raises:
    """Reset the process-wide count-only-intercept fire count to 0 (test setup)."""
    # SAFETY: FFI carve-out (see `semi_count_only_fire_incr`).
    var gp = _SEMI_COUNT_ONLY_ROUTE.get_or_create_ptr()
    gp[][].store(Scalar[DType.int64](0))
