# =============================================================================
# komira_objectstore_gcs/errors.mojo — the GCS StoreError kind reader
# =============================================================================
#
# Every GcsStorageBackend raises `StoreError[<KIND>] <method> gs://<bucket>/
# <key> status=<http> ...`. This module names the kinds and reads one back
# out of a raised message. The mapping from a gRPC status code onto those
# kinds belongs to the gRPC backend, not here.
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


def gcs_store_error_kind_from_message(msg: String) -> UInt8:
    """The StoreError kind named by a `StoreError[<KIND>]` token in `msg`, or
    `GCS_ERR_NONE` if it holds none."""
    if msg.find(String("StoreError[NOT_FOUND]")) >= 0:
        return GCS_ERR_NOT_FOUND
    if msg.find(String("StoreError[PERMISSION_DENIED]")) >= 0:
        return GCS_ERR_PERMISSION_DENIED
    if msg.find(String("StoreError[THROTTLED]")) >= 0:
        return GCS_ERR_THROTTLED
    if msg.find(String("StoreError[PRECONDITION]")) >= 0:
        return GCS_ERR_PRECONDITION
    if msg.find(String("StoreError[TRANSPORT]")) >= 0:
        return GCS_ERR_TRANSPORT
    if msg.find(String("StoreError[MALFORMED]")) >= 0:
        return GCS_ERR_MALFORMED
    return GCS_ERR_NONE
