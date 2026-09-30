# =============================================================================
# komira_core.obs — observability leaf primitives
# =============================================================================
# Houses the build-define-gated runtime-introspection trace primitives. They
# are a pure-stdlib leaf (sys.defines + std.reflection only), so the arrow
# IPC dispatch entries in `komira_core/arrow/` can call `trace_alloc`
# without `komira_core` depending on a higher-level observability package.
# =============================================================================

from .runtime_introspection import (
    trace_alloc,
    trace_trampoline,
    trace_arc_inc,
    trace_arc_dec,
    TRACE_TCMALLOC,
    TRACE_TRAMPOLINE,
    TRACE_ARC,
)
