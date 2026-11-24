# =============================================================================
# objectstore_gcs/gcs_scan_fs.mojo -- the GCS buckets a plan's scans read
# =============================================================================
#
# `GcsScanFs[B]` is fs's `ScanFsOpener` for Google Cloud Storage: it holds the
# factory that builds a `GcsStorageBackend` (the credentials, the endpoint
# and the transport ride on the backend it builds) and opens one `GcsFs` per
# bucket a scan names. A plan names the bucket (`FsDescriptorPod`) and never
# the backend, so the engine that runs it is handed this value with the plan.
#
# Opening builds and dials nothing: the file system builds its backend from
# the factory on its first read, and so does each clone a scan's workers
# take. A scheme other than GCS, or an empty bucket, is refused with
# `SCAN_FS_UNSERVED`. Nothing here reads the environment.
# =============================================================================

from fs.scan_fs import SCAN_FS_UNSERVED, ScanFsOpener, scan_fs_unserved
from plan_expr.fs_descriptor_pod import FS_SCHEME_GCS, FsDescriptorPod

from .backend import GcsStorageBackend
from .gcs_fs import GcsFs


struct GcsScanFs[B: GcsStorageBackend](ScanFsOpener, Movable):
    """Opens a `GcsFs` on each bucket a scan names, all over backends one
    factory builds (module header)."""

    comptime FS = GcsFs[Self.B]

    var _mk_backend: def () raises thin -> Self.B

    def __init__(out self, mk_backend: def () raises thin -> Self.B):
        """An opener whose file systems build their backends with
        `mk_backend`."""
        self._mk_backend = mk_backend

    def open_scan_fs(self, scheme: UInt8, bucket: String) raises -> Self.FS:
        """A `GcsFs` on `bucket`, its backend not yet built.

        Raises:
            `SCAN_FS_UNSERVED` when `scheme` is not GCS or `bucket` is empty.
        """
        if scheme != FS_SCHEME_GCS:
            raise scan_fs_unserved(
                FsDescriptorPod.cloud(scheme, bucket, -1).url_prefix()
            )
        if bucket.byte_length() == 0:
            raise Error(
                String(SCAN_FS_UNSERVED) + ": a GCS scan names no bucket"
            )
        return Self.FS(bucket, self._mk_backend)
