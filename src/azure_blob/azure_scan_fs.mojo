# =============================================================================
# azure_blob/azure_scan_fs.mojo -- the Azure containers a plan's scans read
# =============================================================================
#
# `AzureScanFs[C]` is fs's `ScanFsOpener` for Azure Blob: it holds the
# `AzureClientSpec[C]` (the account's endpoint, the credential and the
# connector factory) and opens one `AzureFs` per container a scan names. A
# plan names the container (`FsDescriptorPod`, whose bucket is the container
# for Azure) and never the account or the credential, so the engine that
# runs it is handed this value with the plan. Every container an opener opens
# is in the one account its spec names.
#
# Opening builds and dials nothing: the file system builds its client from
# the spec on its first verb, and so does each clone a scan's workers take.
# A scheme other than Azure, or an empty container, is refused with
# `SCAN_FS_UNSERVED`; a container name Azure would not accept is refused as
# `azure_fs_for` refuses it. Nothing here reads the environment.
# =============================================================================

from fs.scan_fs import SCAN_FS_UNSERVED, ScanFsOpener, scan_fs_unserved
from http_core.transport.io_stream import Connector
from plan_expr.fs_descriptor_pod import FS_SCHEME_AZURE, FsDescriptorPod

from .azure_client_spec import AzureClientSpec
from .azure_fs import AzureFs
from .azure_url import _check_container


struct AzureScanFs[C: Connector](ScanFsOpener, Movable):
    """Opens an `AzureFs` on each container a scan names, all with one
    client spec (module header)."""

    comptime FS = AzureFs[Self.C]

    var _spec: AzureClientSpec[Self.C]

    def __init__(out self, var spec: AzureClientSpec[Self.C]):
        """An opener whose file systems build their clients from `spec`."""
        self._spec = spec^

    def open_scan_fs(self, scheme: UInt8, bucket: String) raises -> Self.FS:
        """An `AzureFs` on the container `bucket`, its client not yet built.

        Raises:
            `SCAN_FS_UNSERVED` when `scheme` is not Azure or `bucket` is
            empty; `azure_url: '<bucket>' is not an Azure container name ...`
            when Azure would not accept the name.
        """
        if scheme != FS_SCHEME_AZURE:
            raise scan_fs_unserved(
                FsDescriptorPod.cloud(scheme, bucket, -1).url_prefix()
            )
        if bucket.byte_length() == 0:
            raise Error(
                String(SCAN_FS_UNSERVED) + ": an Azure scan names no container"
            )
        _check_container(bucket)
        return Self.FS(bucket, self._spec.copy())
