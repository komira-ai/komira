# =============================================================================
# komira_objectstore_gcs/errors.mojo — the GCS StoreError kind reader
# =============================================================================
#
# Every GcsStorageBackend raises `StoreError[<KIND>] <method> gs://<bucket>/
# <key> status=<http> ...`. This module names the kinds and reads one back
# out of a raised message. The mapping from a gRPC status code onto those
# kinds belongs to the gRPC backend (grpc_backend.mojo), not here.
#
# Pure functions over String; no UnsafePointer.
# =============================================================================

comptime GCS_ERR_NONE: UInt8 = 0
comptime GCS_ERR_NOT_FOUND: UInt8 = 1
comptime GCS_ERR_PERMISSION_DENIED: UInt8 = 2
comptime GCS_ERR_THROTTLED: UInt8 = 3
comptime GCS_ERR_PRECONDITION: UInt8 = 4
comptime GCS_ERR_TRANSPORT: UInt8 = 5
comptime GCS_ERR_MALFORMED: UInt8 = 6


def _kind_at(msg: String, at: Int, token: String) -> Bool:
    """True iff `msg` holds `token` starting at byte `at`."""
    var mb = msg.as_bytes()
    var tb = token.as_bytes()
    if at + len(tb) > len(mb):
        return False
    for i in range(len(tb)):
        if mb[at + i] != tb[i]:
            return False
    return True


def gcs_store_error_kind_from_message(msg: String) -> UInt8:
    """The StoreError kind named by the FIRST `StoreError[<KIND>]` token in
    `msg`, or `GCS_ERR_NONE` if it holds none.

    Only the first token counts: a backend message carries the object key
    after its kind (`StoreError[<KIND>] <method> gs://<bucket>/<key> ...`),
    and a key may itself contain `StoreError[...]`, which must not change the
    kind."""
    var at = msg.find(String("StoreError["))
    if at < 0:
        return GCS_ERR_NONE
    if _kind_at(msg, at, String("StoreError[NOT_FOUND]")):
        return GCS_ERR_NOT_FOUND
    if _kind_at(msg, at, String("StoreError[PERMISSION_DENIED]")):
        return GCS_ERR_PERMISSION_DENIED
    if _kind_at(msg, at, String("StoreError[THROTTLED]")):
        return GCS_ERR_THROTTLED
    if _kind_at(msg, at, String("StoreError[PRECONDITION]")):
        return GCS_ERR_PRECONDITION
    if _kind_at(msg, at, String("StoreError[TRANSPORT]")):
        return GCS_ERR_TRANSPORT
    if _kind_at(msg, at, String("StoreError[MALFORMED]")):
        return GCS_ERR_MALFORMED
    return GCS_ERR_NONE
