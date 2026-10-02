# =============================================================================
# tracer_handle.mojo — engine-side gating shim for the Tracer
# =============================================================================
#
# Engine wiring helper. The engine threads `Optional[Tracer]`
# semantics through `execute_segments` / `_apply_operators` without the
# Mojo 0.26.3 lifetime gymnastics that `Optional[ref Tracer]` would
# require. The handle is a thin Movable POD that the engine constructs
# once per query (from `EngineContext.tracer_mut()` if `has_tracer()`
# is true) and passes by `mut` ref.
#
# The handle's enabled-state is checked by the inline `start_span_named`
# helper. When disabled, every wrapper compiles to a check + early
# return (zero ring traffic). When enabled, the wrapper resolves to a
# direct `tracer.start_span[name]` / `end_span` call.
#
# This complements (does NOT replace) the comptime gate on `TRACES_ENABLED`
# in `tracer.mojo`: comptime decides whether the tracer body exists at
# all; the runtime handle's `enabled` flag decides whether *this query*
# emits.
#
# Lifetime: the handle is a borrow over `EngineContext._tracer`. The
# engine holds the EngineContext borrow for the duration of
# `execute_segments`, which is the same duration this handle carries
# the tracer pointer for. There is no destroy-recreate window.
# =============================================================================

from std.memory import Pointer

from komira_trace.tracer import Tracer


struct TracerHandle[origin: MutOrigin](Movable, Deinitable):
    """Engine-side lifetime-gated tracer borrow.

    Construct via `TracerHandle.disabled()` (no-op handle) or
    `TracerHandle.borrow(ctx.tracer_mut())` (live handle).

    When `enabled == False`, every span helper short-circuits without
    touching the tracer pointer. When `enabled == True`, callers reach
    the underlying tracer via the helper methods on this type.
    """

    var _enabled: Bool
    # Pointer-to-tracer captured from the EngineContext borrow. When
    # `_enabled == False` this is the dummy null (never dereferenced).
    var _tp: Pointer[Tracer, Self.origin]

    @staticmethod
    @always_inline
    def borrow(
        ref [Self.origin] tracer: Tracer,
    ) -> TracerHandle[Self.origin]:
        return TracerHandle[Self.origin](True, Pointer(to=tracer))

    @staticmethod
    @always_inline
    def disabled(
        ref [Self.origin] tracer: Tracer,
    ) -> TracerHandle[Self.origin]:
        """Construct a no-op handle that still borrows the tracer
        (necessary because Mojo cannot construct a parameterized
        `Pointer[Tracer, origin]` without an actual referent of that
        origin). Callers should prefer `borrow` when emission is
        wanted; `disabled` exists for the
        `EngineContext.has_tracer() == False` arm.
        """
        return TracerHandle[Self.origin](False, Pointer(to=tracer))

    def __init__(
        out self, enabled: Bool, var tp: Pointer[Tracer, Self.origin]
    ):
        self._enabled = enabled
        self._tp = tp

    @always_inline
    def enabled(self) -> Bool:
        return self._enabled

    @always_inline
    def start_span[name: StringLiteral](
        mut self, worker_id: Int, parent_id: UInt64 = UInt64(0)
    ) -> UInt64:
        """Open a span if the handle is enabled; return the new span_id
        (or 0 if disabled).
        """
        if not self._enabled:
            return UInt64(0)
        return self._tp[].start_span[name](
            worker_id=worker_id, parent_id=parent_id
        )

    @always_inline
    def end_span(mut self, span_id: UInt64, worker_id: Int):
        """Close a span if the handle is enabled. Caller passes the
        `span_id` it received from `start_span`. The handle is a no-op
        when disabled.
        """
        if not self._enabled:
            return
        self._tp[].end_span(span_id, worker_id)

    @always_inline
    def current_span(self, worker_id: Int) -> UInt64:
        if not self._enabled:
            return UInt64(0)
        return self._tp[].current_span(worker_id)


struct ScopedSpan[origin: MutOrigin](Deinitable):
    """RAII span — opens on construction, closes on destruction.

    Use as `var _sp = ScopedSpan[name](handle, worker_id, parent)` —
    when `_sp` falls out of scope the span end is emitted. Useful for
    closures with many early-exit (`continue` / `return`) paths.

    The handle's `enabled` flag is captured at construction; subsequent
    flips (rare) do not affect this span. `span_id()` returns the
    underlying span_id (0 if disabled).
    """

    var _enabled: Bool
    var _span_id: UInt64
    var _worker_id: Int
    var _tp: Pointer[Tracer, Self.origin]

    def __init__[name: StringLiteral](
        out self,
        mut handle: TracerHandle[Self.origin],
        worker_id: Int,
        parent_id: UInt64 = UInt64(0),
    ):
        self._enabled = handle._enabled
        self._worker_id = worker_id
        self._tp = handle._tp
        if self._enabled:
            self._span_id = self._tp[].start_span[name](
                worker_id=worker_id, parent_id=parent_id
            )
        else:
            self._span_id = UInt64(0)

    def __deinit__(deinit self):
        if self._enabled:
            self._tp[].end_span(self._span_id, self._worker_id)

    @always_inline
    def span_id(self) -> UInt64:
        return self._span_id
