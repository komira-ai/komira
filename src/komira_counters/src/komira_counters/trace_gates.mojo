"""The build-time gates of the runtime introspection hooks (`-D KOMIRA_TRACE_*=true`)."""

from std.sys.defines import is_defined


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
