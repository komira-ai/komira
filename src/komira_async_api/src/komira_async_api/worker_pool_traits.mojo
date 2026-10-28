# =============================================================================
# Worker-pool dispatch traits — KeepAlive + Segment
# =============================================================================
#
# These traits live below the engine so non-engine consumers (for example
# the Parquet reader) can implement / refer to the dispatch surface without
# depending on an engine package.
#
# These are PURE INTERFACES — no implementations, no struct fields,
# no UnsafePointer. The concrete dispatcher that drives
# `run_with_state[State: KeepAlive, T: Segment]` (`LocalDispatcher`) lives
# in `komira_async`.
#
# Background
# ----------
# `run_with_state`'s borrowed-State path does not need a keepalive shield
# for the State shapes exercised so far: the caller's `mut state: State`
# parameter anchors State's lifetime through the standard mut-reference
# tracking, which the compiler DOES follow across the dispatch.
#
# Defence-in-depth: the KeepAlive trait is retained and
# `state.__keep_alive()` is invoked post-drain anyway. This is a cheap typed
# method call that costs one fn-pointer indirection; if a future State shape
# (larger Slab-of-Slab hierarchies, pathological field offsets) is not kept
# alive by the compiler under AOT, the shield is already in place. Removing
# the call is a measurable change and must be justified with a standalone
# repro.
#
# The dispatcher's per-(State, T) wrapper trampoline calls both
# `inner.__keep_alive()` and the State's `__keep_alive()` in one shot.
# =============================================================================


# =============================================================================
# KeepAlive — state-level keepalive trait
# =============================================================================

trait KeepAlive(Deinitable):
    """State-level post-drain keepalive trait for run_with_state.

    Every `State` passed to `run_with_state` must implement this trait.
    The dispatcher's per-(State, T) wrapper keepalive invokes
    `state.__keep_alive()` immediately after the dispatch drain to force
    the compiler to observe State's layout at that program point — a
    use-after-free shield applied to the State slot.

    The default `pass` body is sufficient for POD, nested-heap, and
    per-worker-heap State shapes under AOT. Per-State overrides are
    OPTIONAL.

    Rationale for `Deinitable` (not `Movable`): State is borrowed, never
    moved. Making `Movable` part of the trait would exclude
    FlatHashAggregator, HashJoinBuilder, and other Atomic-bearing states.
    """
    def __keep_alive(mut self):
        """Post-drain keepalive (default). The TYPED trampoline call
        site is load-bearing, not this body."""
        pass


# =============================================================================
# Segment — lightweight per-segment dispatch trait
# =============================================================================
#
# A `Segment` is a leaf unit of work within one segment of a pipeline's
# dispatch (`SegmentExecution` / `PipelineExecution`).
#
# The segment value carries at most a POD dispatch discriminant — the heavy
# per-dispatch state lives on a caller-owned `State` value that is
# borrowed-by-reference through `run_with_state`, the way scoped worker
# threads borrow a scheduler.
#
# Mojo does NOT support parameters on trait declarations
# (`trait Segment[State: KeepAlive]`), so `State` is a parameter of the
# `execute` method instead. Every Segment impl reaches its concrete State
# via one line at the top of `execute`:
#
#     var s = UnsafePointer(to=state).bitcast[MyConcreteState]()
#
# The dispatcher's per-(State, T) trampoline still monomorphizes correctly.
# No loss of type-safety; the bitcast is bound at the
# `run_with_state[State, T]` call site.
#
# INVARIANT: `execute` MUST NOT call `run_with_state` (directly or
# transitively) on ANY dispatcher. The re-entrance CAS in `run_with_state`
# detects violations at dispatch time and raises.
# =============================================================================


trait Segment(Movable, Deinitable):
    """Lightweight per-segment dispatch through a dispatcher's
    `run_with_state` or, idiomatically, through
    `SegmentExecution.dispatch(...)`.

    The unit carries no heavyweight state — at most a POD dispatch
    discriminant (segment_id, partition_idx, etc). The dispatch-wide
    state lives on a caller-owned `State` value borrowed through
    `run_with_state[State, T]`.

    INVARIANT (critical): `execute` MUST NOT call `run_with_state` —
    directly or transitively — on ANY dispatcher. Segments are leaves of
    the dispatch tree; multi-phase algorithms decompose into
    driver-coordinated `run_with_state` sequences at the caller scope that
    owns the dispatcher. The re-entrance CAS in `run_with_state` detects
    violations at dispatch time and raises "nested dispatch detected".

    `State` is a parameter of the `execute` METHOD (not the trait) —
    Mojo does not support parameters on trait declarations.
    Every Segment impl uses a one-line bitcast at entry:

        def execute[State: KeepAlive](
            mut self, mut state: State, wid: Int32, tid: Int64
        ) raises:
            var s = UnsafePointer(to=state).bitcast[MyConcreteState]()
            # ...body reads/writes through s[]...

    `Movable` is required because the unit itself IS moved into the
    dispatcher's task buffer for the duration of the dispatch.
    """
    def execute[State: KeepAlive](
        mut self, mut state: State, worker_id: Int32, task_id: Int64
    ) raises: ...

    def __keep_alive(mut self):
        """Segment-level post-drain keepalive (default). The TYPED
        trampoline call site is load-bearing, not this body."""
        pass
