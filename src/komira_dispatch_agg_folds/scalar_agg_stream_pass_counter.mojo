# =============================================================================
# scalar_agg_stream_pass_counter — process-global PASS counter for the 0-key
# scalar-agg STREAMING route
# =============================================================================
#
# Reachability witness for `agg_scalar_fold
# ._try_stream_scalar_agg_fanout` — incremented ONCE PER PASS, so its value
# answers BOTH questions a fan-out raises with one number:
#
#   0   the STREAMING sink did not serve this plan at all (route 2b's resident
#       collect did, or the walker did);
#   1   the streaming sink served it in ONE pass;
#   >=2 the FAN-OUT fired, and the count IS `ceil(n_aggs / MAX_AGGS)`.
#
# ⭐ WHY A COUNTER AND NOT A RESULT ASSERTION. Without the fan-out, a
# 90-aggregate 0-key computed-project plan does NOT fail — it falls to route
# 2b, which RESIDENTLY COLLECTS the leaf and folds it, and under
# `_SCALAR_FOLD_COLLECT_MAX_ROWS` that answers CORRECTLY. So every value
# assertion a fan-out test can make is green whether or not the fan-out
# serves the plan. What differs is the MEMORY SHAPE, and the two things that
# can see it are this counter and a peak-RSS measurement. A test that asserted
# only values would prove nothing about the route.
#
# Mechanism: a name-keyed, init-once, cross-compile-unit process-global
# `Atomic[int64]` via the stdlib `_Global` runtime slot — the SAME idiom as
# `computed_project_agg_route_counter.mojo`,
# `semi_count_only_route_counter.mojo` and `grouped_cd_parallel_counter.mojo`;
# no env var, no `unsafe_from_address` laundering.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, alloc


def _init_scalar_agg_stream_pass_counter() -> OwnedPointer[
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


comptime _SCALAR_AGG_STREAM_PASS = _Global[
    "komira_dispatch_scalar_agg_stream_pass_count",
    _init_scalar_agg_stream_pass_counter,
]


@always_inline
def scalar_agg_stream_pass_incr() raises:
    """Record ONE streaming pass of the 0-key scalar-agg route. One relaxed
    atomic add per PASS (not per query). `raises` only to propagate the stdlib
    `_Global.get_or_create_ptr` signature — never raises at runtime."""
    # SAFETY: FFI carve-out. `get_or_create_ptr` targets KGEN-runtime-managed
    # static storage (process-lifetime); `MutUntrackedOrigin` is the stdlib
    # `_Global` API's own return type, confined to this helper. The outer deref
    # yields the process-global `OwnedPointer`; the inner deref the `Atomic`.
    var gp = _SCALAR_AGG_STREAM_PASS.get_or_create_ptr()
    _ = gp[][].fetch_add(Int64(1))


def scalar_agg_stream_pass_count() raises -> Int:
    """Read the process-wide count of 0-key streaming passes."""
    # SAFETY: FFI carve-out (see `scalar_agg_stream_pass_incr`).
    var gp = _SCALAR_AGG_STREAM_PASS.get_or_create_ptr()
    return Int(gp[][].load())


def reset_scalar_agg_stream_pass_count() raises:
    """Reset the process-wide pass count to 0 (test setup)."""
    # SAFETY: FFI carve-out (see `scalar_agg_stream_pass_incr`).
    var gp = _SCALAR_AGG_STREAM_PASS.get_or_create_ptr()
    gp[][].store(Scalar[DType.int64](0))
