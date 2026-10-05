# =============================================================================
# komira_async.cancellation.token — RE-EXPORT SHIM
# =============================================================================
# The real CancellationToken + _AtomicSlot + Cancellable live in
# `komira_async_api.token` (a clean std-only leaf). Living in
# `komira_core` avoids a `komira_core` (arrow IPC) -> `komira_async` up-edge:
# the arrow IPC dispatch entries need CancellationToken in their signatures.
#
# This module is a re-export so existing
# `from komira_async.cancellation.token import CancellationToken` (and
# `Cancellable`) sites keep resolving unchanged. New code should import from
# `komira_async_api.token` directly.
# =============================================================================

from komira_async_api.token import *
