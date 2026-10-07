# =============================================================================
# computed_project_agg_route_counter — process-global reachability counter for
# the COMPUTED-PROJECT agg leaf route
# =============================================================================
#
# Stage 1 of the ClickBench Q28/Q29 route work.
# Reachability witness for the `AGGREGATE -> PLAN_PROJECT(computed) -> FILTER?
# -> SCAN(parquet)` intercept in `execute_agg_plan` / `try_execute_agg_plan`.
#
# ⭐ A COUNTER IS THE ONLY FALSIFIER THAT WORKS HERE, AND THAT IS THE POINT.
# The new streaming/collect route and the pre-existing RESIDENT WALKER route are
# BYTE-IDENTICAL on the result — the walker is deliberately kept reachable as
# the value ORACLE (`execute_agg_plan(..., allow_computed_project_leaf=False)`,
# the same test-oracle shape `allow_semi_count_only` already uses). So a result
# assertion CANNOT distinguish "the new route drove the query" from "the new
# route declined and the walker silently served it". Only the fire count can,
# which is why the stage-1 observable is stated as "byte-identical AND the
# counter goes 0 -> >=1".
#
# Incremented ONCE per intercept firing (a single relaxed atomic add).
#
# Mechanism: a name-keyed, init-once, cross-compile-unit process-global
# `Atomic[int64]` via the stdlib `_Global` runtime slot — the SAME idiom as
# `semi_count_only_route_counter.mojo`, `mark_semi_anti_route_counter.mojo` and
# `grouped_cd_parallel_counter.mojo`; no env var, no `unsafe_from_address`
# laundering.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, alloc


def _init_computed_project_agg_route_counter() -> OwnedPointer[
    AtomicI64
]:
    """`_Global` init_fn (non-raising): allocate the counter Atomic once per
    process, initialised to 0. `alloc` + a zero write +
    `OwnedPointer(unsafe_from_raw_pointer=)` because `Atomic` is not
    movable-by-value — the same shape as every sibling counter here."""
    # SAFETY: `alloc` returns one uninitialised `AtomicI64` slot, owned by
    # this function until the `OwnedPointer` below takes it. The zero write
    # initialises it through an int64 view of the same bytes (an `AtomicI64`
    # holds one int64). From then on the returned `OwnedPointer` owns the
    # slot and frees it when it is destroyed; `_Global` keeps that
    # `OwnedPointer` in its process-global slot.
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _COMPUTED_PROJECT_AGG_ROUTE = _Global[
    "komira_dispatch_computed_project_agg_route_fire_count",
    _init_computed_project_agg_route_counter,
]


@always_inline
def computed_project_agg_route_fire_incr() raises:
    """Record ONE firing of the computed-PROJECT agg leaf route. One relaxed
    atomic add per query that the route SERVES. `raises` only to propagate the
    stdlib `_Global.get_or_create_ptr` signature — never raises at runtime."""
    # SAFETY: FFI carve-out. `get_or_create_ptr` targets KGEN-runtime-managed
    # static storage (process-lifetime); `MutUntrackedOrigin` is the stdlib
    # `_Global` API's own return type, confined to this helper. The outer deref
    # yields the process-global `OwnedPointer`; the inner deref the `Atomic`.
    var gp = _COMPUTED_PROJECT_AGG_ROUTE.get_or_create_ptr()
    _ = gp[][].fetch_add(Int64(1))


def computed_project_agg_route_fire_count() raises -> Int:
    """Read the process-wide count of computed-PROJECT-route firings."""
    # SAFETY: FFI carve-out (see `computed_project_agg_route_fire_incr`).
    var gp = _COMPUTED_PROJECT_AGG_ROUTE.get_or_create_ptr()
    return Int(gp[][].load())


def reset_computed_project_agg_route_fire_count() raises:
    """Reset the process-wide fire count to 0 (test setup)."""
    # SAFETY: FFI carve-out (see `computed_project_agg_route_fire_incr`).
    var gp = _COMPUTED_PROJECT_AGG_ROUTE.get_or_create_ptr()
    gp[][].store(Scalar[DType.int64](0))
