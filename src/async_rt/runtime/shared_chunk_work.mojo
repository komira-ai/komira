# =============================================================================
# async_rt.runtime.shared_chunk_work — BACK-COMPAT RE-EXPORT SHIM
# =============================================================================
# RELOCATED the real
# `SharedChunkWork` trait now lives in
# `async_api/shared_chunk_work.mojo` (a zero-import clean
# leaf). It moved DOWN because the shared-payload fork-join DRIVER moved down
# with it — `column_kernels/compiler_helpers.mojo.gather_batch` (stage 4 of
# every ORDER BY) needed a pooled fork-join it could reach without core taking
# an up-edge to `async_rt`. Same relocation-plus-shim shape as
# `async_rt/cancellation/token.mojo`.
#
# This module is a back-compat re-export so every existing
# `from async_rt.runtime.shared_chunk_work import SharedChunkWork` site
# keeps resolving unchanged. New code should import from
# `async_api.shared_chunk_work` directly.
# =============================================================================

from async_api.shared_chunk_work import *
