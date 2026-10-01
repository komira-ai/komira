# =============================================================================
# komira_async.runtime.shared_chunk_work — BACK-COMPAT RE-EXPORT SHIM
# =============================================================================
# RELOCATED the real
# `SharedChunkWork` trait now lives in
# `komira_core/runtime_traits/shared_chunk_work.mojo` (a zero-import clean
# leaf). It moved DOWN because the shared-payload fork-join DRIVER moved down
# with it — `komira_core/helpers/compiler_helpers.gather_batch` (stage 4 of
# every ORDER BY) needed a pooled fork-join it could reach without core taking
# an up-edge to `komira_async`. Same relocation-plus-shim shape as
# `komira_async/cancellation/token.mojo`.
#
# This module is a back-compat re-export so every existing
# `from komira_async.runtime.shared_chunk_work import SharedChunkWork` site
# keeps resolving unchanged. New code should import from
# `komira_core.runtime_traits.shared_chunk_work` directly.
# =============================================================================

from komira_core.runtime_traits.shared_chunk_work import *
