# =============================================================================
# async_rt.cancellation.token — RE-EXPORT SHIM
# =============================================================================
# The real CancellationToken + _AtomicSlot + Cancellable live in
# `async_api.token` (a clean std-only leaf). Living in
# the core packages avoids a core-package (arrow IPC) -> `async_rt` up-edge:
# the arrow IPC dispatch entries need CancellationToken in their signatures.
#
# This module is a re-export so existing
# `from async_rt.cancellation.token import CancellationToken` (and
# `Cancellable`) sites keep resolving unchanged. New code should import from
# `async_api.token` directly.
# =============================================================================

from async_api.token import *
