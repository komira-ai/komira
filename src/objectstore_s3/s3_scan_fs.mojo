# =============================================================================
# objectstore_s3/s3_scan_fs.mojo -- the S3 buckets a plan's scans read
# =============================================================================
#
# `S3ScanFs[C, T, K]` is fs's `ScanFsOpener` for S3: it holds what reaching
# the store takes (the `S3Config` with its region and endpoint, the connector
# factory, the HTTP client configuration, the credential source and the
# signing clock) and opens one `S3Fs` per bucket a scan names. A plan names
# the bucket (`FsDescriptorPod`) and never any of these, so the engine that
# runs it is handed this value with the plan.
#
# Opening dials nothing: the file system builds its store on the first read.
# A scheme other than S3, or an empty bucket, is refused with
# `SCAN_FS_UNSERVED`. Nothing here reads the environment.
# =============================================================================

from aws_core import AwsClock, AwsCredsSource
from fs.scan_fs import SCAN_FS_UNSERVED, ScanFsOpener, scan_fs_unserved
from http_client.client import HttpClientConfig
from http_core.transport.io_stream import Connector
from plan_expr.fs_descriptor_pod import FS_SCHEME_S3, FsDescriptorPod

from .config import S3Config
from .s3_fs import S3Fs
from .s3_fs_options import S3FsOptions


struct S3ScanFs[
    C: Connector,
    T: AwsCredsSource & Copyable,
    K: AwsClock & Copyable & Deinitable,
](ScanFsOpener, Movable):
    """Opens an `S3Fs` on each bucket a scan names, all with one
    configuration, connector factory, credential source and clock (module
    header)."""

    comptime FS = S3Fs[Self.C, Self.T, Self.K]

    var _config: S3Config
    var _mk_connector: def () raises thin -> Self.C
    var _http_config: HttpClientConfig
    var _creds: Self.T
    var _clock: Self.K
    var _options: S3FsOptions

    def __init__(
        out self,
        var config: S3Config,
        mk_connector: def () raises thin -> Self.C,
        http_config: HttpClientConfig,
        var creds: Self.T,
        var clock: Self.K,
        options: S3FsOptions = S3FsOptions.standard(),
    ):
        """An opener whose file systems take these arguments (`S3Fs`'s,
        less the bucket)."""
        self._config = config^
        self._mk_connector = mk_connector
        self._http_config = http_config.copy()
        self._creds = creds^
        self._clock = clock^
        self._options = options

    def open_scan_fs(self, scheme: UInt8, bucket: String) raises -> Self.FS:
        """An `S3Fs` on `bucket`, built but not dialed.

        Raises:
            `SCAN_FS_UNSERVED` when `scheme` is not S3 or `bucket` is empty.
        """
        if scheme != FS_SCHEME_S3:
            raise scan_fs_unserved(
                FsDescriptorPod.cloud(scheme, bucket, -1).url_prefix()
            )
        if bucket.byte_length() == 0:
            raise Error(
                String(SCAN_FS_UNSERVED) + ": an S3 scan names no bucket"
            )
        return Self.FS(
            bucket,
            self._config.copy(),
            self._mk_connector,
            self._http_config,
            self._creds.copy(),
            self._clock.copy(),
            self._options,
        )
