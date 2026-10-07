# =============================================================================
# mark_semi_anti_route_counter — process-global reachability counter for the
# mark-based right-semi/anti kernel
# =============================================================================
#
# BUILD-SIDE ORIENTATION ROUTE-GATE.
# Reachability witness for the SQL-path SEMI/ANTI build-side orientation fix:
# `_try_run_join` (join_node_exec.mojo) now routes a both-parquet single-INT64-key
# SEMI/ANTI whose DECLARED RIGHT (build) footer row_count is STRICTLY larger than
# the LEFT (probe) OFF the fused build-RIGHT parquet leaf and ONTO the resident
# `materialize_inmem_build_inmem_probe_join`, where the DEFAULT-ON mark kernel
# (`_run_mark_semi_anti`) fires (build the SMALL LEFT, 32-way stream-mark the LARGE
# RIGHT, emit LEFT survivors). Before the fix the SQL-q4 SEMI plan fell through to
# the fused leaf and `_run_mark_semi_anti` NEVER ran; after the fix it does.
#
# A COUNTER (not a result assertion) is the correct reachability falsifier: the
# routed mark path and the fused build-RIGHT leaf are byte-identical on the RESULT
# (same survivor rows + order), so a result assertion cannot tell whether the mark
# fired — only the fire count distinguishes "reached the mark kernel" (after) from
# "reached the fused leaf" (before, simulated by `execute_join_plan`'s
# `allow_semi_anti_route=False` test-oracle parameter, which declines the route —
# it replaced an environment kill-switch).
# Incremented ONCE per `_run_mark_semi_anti`
# invocation (a single relaxed atomic add at kernel entry, never per row/morsel), so
# the always-on cost is a few nanoseconds per SEMI/ANTI mark.
#
# Mechanism: a name-keyed, init-once, cross-compile-unit process-global
# `Atomic[int64]` via the stdlib `_Global` runtime slot — the SAME idiom as
# `hbs_key_share_counter.mojo` and the gather counters of
# `join_gather_unrolled.mojo`; no env var, no `unsafe_from_address`
# laundering.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, UnsafePointer, alloc


def _init_mark_semi_anti_route_counter() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn (non-raising): allocate the counter Atomic once per
    process, initialised to 0 (`alloc` + a zero write +
    `OwnedPointer(unsafe_from_raw_pointer=)`) since `Atomic` is not
    movable-by-value."""
    # SAFETY: `alloc` returns one uninitialised `AtomicI64` slot, owned by
    # this function until the `OwnedPointer` below takes it. The zero write
    # initialises it through an int64 view of the same bytes (an `AtomicI64`
    # holds one int64). From then on the returned `OwnedPointer` owns the
    # slot and frees it when it is destroyed; `_Global` keeps that
    # `OwnedPointer` in its process-global slot.
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _MARK_SEMI_ANTI_ROUTE = _Global[
    "komira_dispatch_mark_semi_anti_fire_count",
    _init_mark_semi_anti_route_counter,
]


@always_inline
def mark_semi_anti_fire_incr() raises:
    """Record ONE invocation of the mark-based right-semi/anti kernel
    (`_run_mark_semi_anti`). One relaxed atomic add per SEMI/ANTI mark. `raises`
    only to propagate the stdlib `_Global.get_or_create_ptr` signature — never
    raises at runtime."""
    # SAFETY: `get_or_create_ptr` targets KGEN-runtime-managed
    # static storage (process-lifetime); `MutUntrackedOrigin` is the stdlib
    # `_Global` API's own return type, confined to this helper. The outer deref
    # yields the process-global `OwnedPointer`; the inner deref the `Atomic`.
    var gp = _MARK_SEMI_ANTI_ROUTE.get_or_create_ptr()
    _ = gp[][].fetch_add(Int64(1))


def mark_semi_anti_fire_count() raises -> Int:
    """Read the process-wide count of `_run_mark_semi_anti` invocations."""
    # SAFETY: as `mark_semi_anti_fire_incr`.
    var gp = _MARK_SEMI_ANTI_ROUTE.get_or_create_ptr()
    return Int(gp[][].load())


def reset_mark_semi_anti_fire_count() raises:
    """Reset the process-wide mark fire count to 0 (test setup)."""
    # SAFETY: as `mark_semi_anti_fire_incr`.
    var gp = _MARK_SEMI_ANTI_ROUTE.get_or_create_ptr()
    gp[][].store(Scalar[DType.int64](0))
