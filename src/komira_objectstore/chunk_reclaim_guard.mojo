# =============================================================================
# komira_objectstore/chunk_reclaim_guard.mojo
#   The rules that keep chunk reclamation off live chunks.
# =============================================================================
#
# `_LOG_START.log_start_seq` is the lowest LIVE chunk: every reader and every
# replay starts there. A chunk at or above it is live, whatever tombstone it
# carries. Callers retire a chunk in this order:
#
#   1. advance `_LOG_START` past it,
#   2. tombstone it (or tombstone first: a tombstone on a live chunk is
#      harmless, see below),
#   3. reap it after the grace window.
#
# A tombstone on a chunk at or above `_LOG_START` (an advance that failed
# after the tombstone, or a crash between the two) is STRANDED, not
# reclaimable. `CasManifestStore.reap` refuses such a chunk (`reap_is_refused`)
# and the broker's `ReapWorker` skips and counts it before it deletes anything.
# A later pass that advances `_LOG_START` makes the tombstone reclaimable.
#
# `CasManifestStore.rewrite_chunk_body` overwrites a chunk with an If-Match on
# the etag it read, so a chunk reaped between its read and its write is never
# recreated (`rewrite_target_deleted_error`). The message carries `not_found`,
# the absence token `is_not_found` matches, so a caller that tolerates a chunk
# that is already gone keeps doing so.
#
# `CasManifestStore.purge_all` is outside these rules: it reclaims a WHOLE
# lineage (every chunk and `_LOG_START` itself) once its caller has decided
# that nothing reads the lineage any more.
#
# This module holds decisions and error text only; it does no I/O, so
# `cas_manifest.mojo` imports it without a cycle.
# =============================================================================


@always_inline
def reap_is_refused(chunk_seq: Int64, log_start_seq: Int64) -> Bool:
    """True iff reaping `chunk_seq` would delete a live chunk: it is at or
    above the lowest live chunk `log_start_seq`."""
    return chunk_seq >= log_start_seq


def reap_refused_error(chunk_seq: Int64, log_start_seq: Int64) -> Error:
    """The error `CasManifestStore.reap` raises for a live chunk. It carries no
    absence or precondition token, so no caller mistakes it for a lost race or
    an already-reaped chunk."""
    return Error(
        "CasManifestStore.reap: refused, chunk "
        + String(chunk_seq)
        + " is at or above log_start_seq "
        + String(log_start_seq)
        + "; advance the log start past a chunk before reaping it"
    )


def rewrite_target_deleted_error(chunk_seq: Int64) -> Error:
    """The error `CasManifestStore.rewrite_chunk_body` raises when the chunk
    was deleted (reaped) between its read and its conditional write. The
    write did not recreate the chunk."""
    return Error(
        "CasManifestStore.rewrite_chunk_body: chunk "
        + String(chunk_seq)
        + " not_found: it was deleted during the rewrite and was not recreated"
    )
