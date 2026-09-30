# =============================================================================
# komira_core.cancellation — cancellation primitives
# =============================================================================
# Houses the CancellationToken + Cancellable trait. The token is a clean leaf
# (std.memory + std.atomic only), and the arrow IPC dispatch entries in
# `komira_core/arrow/` need it in their signatures, so it lives here rather
# than in the async runtime. ExecutionBudget + CancelledError belong to the
# async runtime.
# =============================================================================

from .token import CancellationToken, Cancellable
