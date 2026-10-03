# =============================================================================
# komira_counters.runtime_introspection -- build-define-gated runtime
# introspection hooks
# =============================================================================
#
# Certain Mojo-runtime hot events (per-batch tcmalloc allocs, parallel-task
# trampoline dispatch, ArcPointer ref-count traffic) are invisible to a
# sampling profiler's frame INC% even in a debug build, because they are
# inlined / aggregated / repeated across many small frames.
#
# The hooks below add OPT-IN tracing at the call sites that matter most.
# Each hook is gated by a comptime `is_defined[NAME]()` flag so OFF mode
# is **literally zero overhead** -- the `@parameter if` block produces no
# instructions.
#
# Activation: pass the matching `-D` define at build time
# (`-D KOMIRA_TRACE_TCMALLOC=true`, `-D KOMIRA_TRACE_TRAMPOLINE=true`,
# `-D KOMIRA_TRACE_ARC=true`). A trace build typically sets all three.
#
# Format (per-event, grep-friendly):
#   [TRACE_TCMALLOC]   site=<file>:<line> bytes=<N>
#   [TRACE_TRAMPOLINE] site=<file>:<line> task_type=<comptime-string>
#   [TRACE_ARC]        op=<inc|dec>       type=<comptime-string>
#
# Aggregation is intentionally external -- `grep | awk` collapses the
# stream to per-site totals (e.g. `grep TRACE_TCMALLOC | head -20`). Mojo
# has no global vars (a counter would need a pthread-mutex-protected heap
# singleton), so the hooks emit one line per event.
#
# IMPORTANT: this module is a PURE-STDLIB LEAF (sys.defines + std.reflection
# only). It sits at the bottom of the dep DAG inside `komira_core` so
# hot-path callers (the worker pool, the aggregation hash table, the arrow
# IPC dispatch, etc.) can import it without a layering violation.
# =============================================================================

from std.sys.defines import is_defined
from std.reflection import call_location


# -----------------------------------------------------------------------------
# Comptime gate aliases.
# -----------------------------------------------------------------------------
#
# `is_defined["X"]()` returns `True` when the build was invoked with
# `-D X=true` (or `-D X=1`). Otherwise returns `False`. Resolution is at
# parse-time, so `@parameter if TRACE_TCMALLOC: ...` produces zero code
# in the disabled branch.
#
# Zero-overhead OFF mode is a requirement: do NOT add any runtime check
# (no env read) at the hook call sites. These hooks fire on the per-batch /
# per-dispatch hot path; only comptime gating is acceptable.
# -----------------------------------------------------------------------------

comptime TRACE_TCMALLOC: Bool = is_defined["KOMIRA_TRACE_TCMALLOC"]()
"""True when `-D KOMIRA_TRACE_TCMALLOC=true` was passed at build time."""

comptime TRACE_TRAMPOLINE: Bool = is_defined["KOMIRA_TRACE_TRAMPOLINE"]()
"""True when `-D KOMIRA_TRACE_TRAMPOLINE=true` was passed at build time."""

comptime TRACE_ARC: Bool = is_defined["KOMIRA_TRACE_ARC"]()
"""True when `-D KOMIRA_TRACE_ARC=true` was passed at build time."""


# -----------------------------------------------------------------------------
# Hook 1: tcmalloc allocation tracker.
# -----------------------------------------------------------------------------
#
# Wraps an explicit allocation site. Caller passes the byte count. The
# alloc itself is NOT performed by this hook -- caller does the
# `UnsafePointer[T].alloc(n)` and passes us `n * sizeof(T)`.
#
# Source location capture uses `std.reflection.call_location()`. The
# hook is `@always_inline` so the location resolves to the caller's
# invocation site (per call_location() inline_count=1 contract).
#
# Example caller (opt-in pattern):
#
#     from komira_counters.runtime_introspection import trace_alloc
#     # ... at the alloc site:
#     var p = UnsafePointer[T].alloc(n)
#     trace_alloc(n * sizeof[T]())
#
# OFF mode has zero overhead (the print AND the call_location() are
# both fenced behind `@parameter if`).
# -----------------------------------------------------------------------------

@always_inline("nodebug")
def trace_alloc(n_bytes: Int):
    """Record an allocation at the caller's source location.

    OFF mode (default): zero overhead -- the body is `@parameter if`-fenced.
    ON mode: emits one `[TRACE_TCMALLOC]` line per call, with the
    caller's file:line resolved via `std.reflection.call_location()`.

    Args:
        n_bytes: Allocation size in bytes (caller's responsibility to
            multiply by `sizeof[T]()`).
    """
    comptime if TRACE_TCMALLOC:
        var loc = call_location()
        print(
            "[TRACE_TCMALLOC] site=",
            loc.file_name(),
            ":",
            loc.line(),
            " bytes=",
            n_bytes,
            sep="",
        )


# -----------------------------------------------------------------------------
# trace_alloc — labeled overload
# -----------------------------------------------------------------------------
#
# A zero-copy gate over the Arrow IPC decoder needs more than file:line
# attribution -- it groups markers by logical decode site
# (`arrow_ipc.driver_enter`, `arrow_ipc.decode_record_batch_zerocopy`,
# `arrow_ipc.decode_record_batch_copy`, `arrow_ipc.decompress`) so a
# per-codec threshold table can be asserted across nested call paths. The
# labeled overload preserves the unlabeled primitive's wire format
# (`[TRACE_TCMALLOC] site=<...> bytes=<N>`) and prepends a `label=<X>`
# token; a consumer can match either site or label.
#
# The label is comptime (`StaticString`), so the OFF-mode body emits
# zero instructions identically to the unlabeled overload. Both overloads
# co-exist; the dispatch shape is by parameter list:
#
#   trace_alloc(n)                     # site=file:line only
#   trace_alloc["arrow_ipc.X"](n)      # labeled
#
# Mirrors `trace_trampoline[task_type: StaticString]()` (Hook 2).

@always_inline("nodebug")
def trace_alloc[site: StaticString](n_bytes: Int):
    """Record an allocation at the caller's source location, tagged with
    a comptime label.

    OFF mode (default): zero overhead -- the body is `@parameter if`-fenced.
    ON mode: emits one `[TRACE_TCMALLOC]` line per call:

        [TRACE_TCMALLOC] label=<site> site=<file>:<line> bytes=<N>

    The label allows gates to group markers by logical decode path (e.g.
    `arrow_ipc.decode_record_batch_zerocopy`) rather than by file:line, so
    a per-codec threshold table holds across refactors.

    Parameters:
        site: Comptime label describing the logical site (e.g.
            `"arrow_ipc.driver_enter"`).

    Args:
        n_bytes: Allocation size in bytes. Callers labelling a zero-copy
            path pass `0` to record "this site claims no allocation"
            for the strict-zero gate to consume.
    """
    comptime if TRACE_TCMALLOC:
        var loc = call_location()
        print(
            "[TRACE_TCMALLOC] label=",
            site,
            " site=",
            loc.file_name(),
            ":",
            loc.line(),
            " bytes=",
            n_bytes,
            sep="",
        )


# -----------------------------------------------------------------------------
# Hook 2: trampoline dispatch tracker.
# -----------------------------------------------------------------------------
#
# `_state_trampoline_for[State, T]` can be a large inclusive share of a
# profile. Each parallel-task dispatch routes through one trampoline
# specialization per `(State, T)` pair. The hook records each entry into
# the trampoline body; the dispatch count tells whether trampoline-side
# overhead is per-task fixed cost (high count, small body each) or
# amortized (low count, large body each).
#
# Caller (inside the trampoline body, after the bitcasts):
#
#     trace_trampoline["_state_trampoline_for"]()
#
# The `task_type` label is opaque to the hook; passing a `StaticString`
# distinguishes the trampoline shapes in the worker pool.
# -----------------------------------------------------------------------------

@always_inline("nodebug")
def trace_trampoline[task_type: StaticString]():
    """Record a parallel-task trampoline dispatch.

    OFF mode (default): zero overhead -- the body is `@parameter if`-fenced.
    ON mode: emits one `[TRACE_TRAMPOLINE]` line per dispatch with the
    caller's source location.

    Parameters:
        task_type: Comptime label for the trampoline specialization
            (e.g. `"_state_trampoline_for"` or `"_task_trampoline"`).
    """
    comptime if TRACE_TRAMPOLINE:
        var loc = call_location()
        print(
            "[TRACE_TRAMPOLINE] site=",
            loc.file_name(),
            ":",
            loc.line(),
            " task_type=",
            task_type,
            sep="",
        )


# -----------------------------------------------------------------------------
# Hook 3: ArcPointer ref-count tracker.
# -----------------------------------------------------------------------------
#
# Mojo's stdlib `ArcPointer` is a leaf-package type that we cannot patch
# from this side. The realistic instrumentation path is opt-in: at
# call sites where we construct / clone an Arc, the caller emits a
# trace event. This is a coverage-limited tool (only opted-in sites
# show up) -- but it answers the operational question "does our agg
# join carry refcount traffic on the per-batch hot path?" by
# instrumenting the suspected sites and grepping.
#
# Caller pattern at an Arc clone:
#
#     trace_arc_inc["AggLayout"]()
#     var clone = my_arc_pointer.copy()
#
# At drop:
#
#     trace_arc_dec["AggLayout"]()
#
# A future enhancement could swap stdlib ArcPointer for a
# `TrackedArcPointer[T]` wrapper that records every inc/dec without the
# caller annotating each site.
# -----------------------------------------------------------------------------

@always_inline("nodebug")
def trace_arc_inc[type_name: StaticString]():
    """Record an ArcPointer increment for the given type label.

    OFF mode (default): zero overhead. ON mode: one log line per call.

    Parameters:
        type_name: Comptime label (e.g. `"AggLayout"`,
            `"_VyukovMpmcQueue"`).
    """
    comptime if TRACE_ARC:
        print("[TRACE_ARC] op=inc type=", type_name, sep="")


@always_inline("nodebug")
def trace_arc_dec[type_name: StaticString]():
    """Record an ArcPointer decrement for the given type label.

    OFF mode (default): zero overhead. ON mode: one log line per call.

    Parameters:
        type_name: Comptime label.
    """
    comptime if TRACE_ARC:
        print("[TRACE_ARC] op=dec type=", type_name, sep="")


# -----------------------------------------------------------------------------
# Hook 4: implicit-copy tracker -- not provided.
# -----------------------------------------------------------------------------
#
# Mojo synthesizes `__copyinit__` for any `T: Copyable & Movable &
# ImplicitlyCopyable` struct that does not provide one explicitly. The
# synthesized body is opaque -- there is no compiler hook for the user to
# intercept, and no `-D` flag to inject instrumentation into it.
#
# The two structurally-feasible workarounds are both costly:
#   (a) Inject manual `__copyinit__` overrides on the suspect types
#       (each one calls a `trace_copy[T]()` helper and then explicitly
#       copies every field). Risk: any new field added later silently
#       bypasses the count, AND we lose the implicit-copy synthesis path
#       that interacts with Movable trait derivation.
#   (b) Swap problem types to `OwnedPointer[T]` ownership and pay an
#       indirection per access in exchange for the compiler refusing
#       to copy (no Copyable conformance). That is a refactor, not an
#       instrumentation hook.
#
# Compiler features that would make it possible:
#   - `@compiler_hook(on_implicit_copy)` decorator on the type
#   - a build define that emits a counter bump in every synthesized
#     `__copyinit__`
#   - Stdlib trait `TraceableCopyable: Copyable` that the user opts
#     into; synthesized body calls a user hook
