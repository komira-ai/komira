# =============================================================================
# komira_obs.runtime_introspection — re-export of the runtime trace primitives
# =============================================================================
# The trace primitives (trace_alloc + the labeled overload, trace_trampoline,
# trace_arc_inc/dec, and the TRACE_* comptime gates) live in
# `komira_core.obs.runtime_introspection`, a pure-stdlib leaf. They sit in
# `komira_core` because core code calls them, and `komira_obs` depends on
# `komira_core`: defining them here would make a core <-> obs cycle.
#
# This module re-exports them so `from komira_obs.runtime_introspection import
# trace_alloc` (and `trace_arc_inc`, etc.) resolves. New code should import
# from `komira_core.obs.runtime_introspection` directly.
# =============================================================================

from komira_core.obs.runtime_introspection import *
