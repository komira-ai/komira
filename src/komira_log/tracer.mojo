# =============================================================================
# komira_log.tracer — the TYPED `ctx.tracer.start_span[name](wid)` surface (P4a).
# =============================================================================
#
# The span twin of `Logger[origin]` (logger.mojo). The unified engine carries
# logs AND spans on the same per-core ring; this is the typed, concrete-origin
# handle that reaches the engine's span surface the SAME way `Logger` reaches
# the log surface — so the eventual `ctx.tracer` (P4b) is NanoLog-class
# (concrete-origin dispatch inlines, no wildcard-handle resolve penalty),
# exactly like `ctx.logger`.
#
# # The shape (identical to Logger[origin])
#
#   var tracer = ctx.tracer()                          # typed borrow
#   var sid = tracer.start_span["query.execute"](wid)  # comptime span name
#   var inner = tracer.start_span["segment.scan"](wid) # nested (parent=sid)
#   tracer.end_span(inner, wid)
#   tracer.end_span(sid, wid)
#
# `Tracer[origin]` holds a `Pointer[SharedEngine, origin]` — a CONCRETE origin
# (NOT a wildcard, NOT `unsafe_from_address=Int`), constructed from a live
# `ref [origin] SharedEngine`. This is the SAME proven shape as `Logger[origin]`
# and `komira_trace.TracerHandle[origin]`. In P4a it is exposed on the engine +
# a standalone `Tracer.borrow(engine)` handle; P4b adds the `ctx.tracer`
# accessor (no source change to this struct — just a new accessor on the
# forever-root, mirroring how `ctx.logger()` returns `Logger[...]`).
#
# # RAII span scope (deferred)
#
# A `SpanScope[origin]` RAII guard (open-on-construct / close-on-`__del__`) was
# prototyped for `with`-style auto-close. Under Mojo 1.0.0b1, returning a
# destructor-bearing struct that owns a `Pointer[SharedEngine, origin]` from the
# `@always_inline span()` factory hangs the compiler's move/destructor lowering
# (the same origin-tracking-through-a-returned-guard shape that the obs tracer
# likewise leaves as a Phase-1.1 follow-up). The explicit `start_span` /
# `end_span` pair is the canonical hot-path form anyway (it is what the obs
# tracer ships), so P4a exposes that pair only; the RAII sugar is deferred to
# P4b alongside the `ctx.tracer` accessor. No correctness is lost — a caller
# brackets work with `start_span(...)` / `end_span(...)` exactly as the obs
# tracer does.
#
# # Encapsulation
#
# `Tracer[origin]` holds a `Pointer[SharedEngine, origin]` — a CONCRETE origin.
# No `UnsafePointer` crosses the public API; `start_span` takes the comptime
# `name` + a typed `worker_id`, `end_span` takes typed scalars. The field is a
# concrete-origin Pointer, not a wildcard.
# =============================================================================

from std.memory import Pointer

from komira_log.engine.shared_engine import SharedEngine


# -----------------------------------------------------------------------------
# Tracer[origin] — the typed, concrete-origin span handle.
# -----------------------------------------------------------------------------


struct Tracer[origin: MutOrigin](Movable, Deinitable):
    """The typed, concrete-origin trace handle (the span twin of `Logger`).

    `let tracer = ctx.tracer` aliases the SAME typed borrow; `start_span[name]`
    / `end_span` reach the engine through the concrete `_eng` origin so the
    span emit inlines (~1ns dispatch) instead of paying an ambient
    wildcard-handle resolve. Carries the exact `Pointer[SharedEngine, origin]`
    shape `Logger[origin]` uses."""

    # CONCRETE-origin borrow of the forever-root's engine field. NOT a wildcard,
    # NOT `unsafe_from_address=Int` — a `Pointer(to=referent)` of a live ref.
    var _eng: Pointer[SharedEngine, Self.origin]

    @staticmethod
    @always_inline
    def borrow(ref [Self.origin] engine: SharedEngine) -> Tracer[Self.origin]:
        """Construct a typed tracer borrowing `engine` through its concrete
        origin. The accessor (`ctx.tracer()` in P4b) is the idiomatic reach;
        this is the primitive it wraps."""
        return Tracer[Self.origin](Pointer(to=engine))

    @always_inline
    def __init__(out self, var eng: Pointer[SharedEngine, Self.origin]):
        self._eng = eng

    @always_inline
    def start_span[
        name: StringLiteral, module: StringLiteral = "komira"
    ](self, worker_id: Int) -> UInt64:
        """Open a span; returns its span_id. The parent is the worker's current
        innermost span (nested correlation); a fresh trace_id is minted for a
        root span. `name` is comptime — the digest is a literal at the call
        site, zero runtime hash (the NanoLog property)."""
        return self._eng[].start_span[name, module](worker_id)

    @always_inline
    def end_span(self, span_id: UInt64, worker_id: Int):
        """Close `span_id` on this worker's ring."""
        self._eng[].end_span(span_id, worker_id)

    @always_inline
    def current_span(self, worker_id: Int) -> UInt64:
        """The innermost in-flight span_id for `worker_id` (0 if none)."""
        return self._eng[].current_span(worker_id)
