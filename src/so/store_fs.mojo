# =============================================================================
# so/store_fs.mojo -- the object stores a libkomira session reads: S3, Azure
# Blob and Google Cloud Storage behind one file system type
# =============================================================================
#
# An engine run reads through ONE file system type (`ScanFsOpener.FS`), and
# Mojo has no trait objects, so a run that may read S3, Azure and GCS holds
# them in one concrete struct. `StoreFs[S3C, AZC, G, K]` is that struct: it
# holds an `S3Fs[S3C, StaticCredsSource, K]`, an `AzureFs[AZC]` or a
# `GcsFs[LazyGcsBackend[G]]` (exactly one) and every `FileSystem` verb goes to
# the one it holds. `StoreFile` and `StoreWriteFile` hold the matching handle;
# a handle of another store is refused by name (`STORE_FS_HANDLE`), never
# reinterpreted. What the held file system does not serve (a write to Azure or
# GCS, an S3 append) it refuses itself, and the refusal comes through
# unchanged.
#
# `StoreScanFs` is the run's opener. It is told which buckets (S3 and GCS) and
# containers (Azure) the run reads, each with its own endpoint and credential
# (`add_s3`, `add_azure`, `add_gcs`), and opens a file system for exactly
# those: a scan of any other bucket, or of any other scheme, is refused with
# `SCAN_FS_UNSERVED` word for word as `LocalOnlyScanFs` refuses it. Opening
# builds and dials nothing; each file system builds its store on its first
# verb.
#
# `StoreConnectors` is what reaching a store takes besides the per-bucket
# access: the connector factories for a plaintext (`http://`) and a TLS
# (`https://` or the provider's own) endpoint of S3 and Azure, the factory of a
# GCS backend from a bucket's `GcsAccess` (Cloud Storage is read over gRPC on
# TLS only, so there is one), and the signing clock.
# `kernel_store_connectors()` is the production set (kernel TCP, public CA
# roots, the wall clock, google.storage.v2 over gRPC); a test hands in fakes.
# The factory an S3 or Azure bucket uses is picked once, when the bucket is
# added, from its endpoint's scheme.
#
# A GCS bucket's backend is built from its `GcsAccess` (the endpoint's host
# and port and the OAuth access token; `gcs_access.mojo`) by
# `LazyGcsBackend` on the file system's first verb, and again for each clone
# (`StoreFs.clone`): a backend owns a single-thread transport, so two file
# systems never share one.
#
# No credential value is held in any error text, and none of these types is
# Writable. Nothing here reads the environment.
# =============================================================================

from aws_core import (
    AwsClock,
    AwsCredential,
    StaticCredsSource,
    SystemAwsClock,
)
from azure_blob import (
    AzureClientSpec,
    AzureCredential,
    AzureFileHandle,
    AzureFs,
    AzureFsConfig,
    AzureWriteFile,
    azure_fs_for,
)
from byte_buffer.heap_region import HeapRegion
from byte_buffer.shared_aligned_buffer import SharedAlignedBuffer
from containers.slab import Slab
from fs.file_system import FileSystem, WriteMode
from fs.footer_region import FooterRegion
from fs.scan_fs import ScanFsOpener, scan_fs_unserved
from fs.shallow_dir_entry import ShallowDirEntry
from http_client import (
    KernelSchemeConnector,
    kernel_plain_scheme_connector,
    kernel_tls_scheme_connector,
)
from http_client.client import HttpClientConfig
from http_core.transport.io_stream import Connector
from objectstore_gcs import (
    GcsFileHandle,
    GcsFs,
    GcsStorageBackend,
    GcsWriteFile,
)
from objectstore_s3 import (
    S3Config,
    S3FileHandle,
    S3Fs,
    S3WriteFile,
    s3_connector_factory,
)
from plan_expr.fs_descriptor_pod import (
    FS_SCHEME_AZURE,
    FS_SCHEME_GCS,
    FS_SCHEME_S3,
    FsDescriptorPod,
)

from .gcs_access import (
    GcsAccess,
    KernelGcsBackend,
    LazyGcsBackend,
    _refuse_gcs_clone,
    kernel_gcs_backend,
)


comptime STORE_FS_DUPLICATE = "STORE_FS_DUPLICATE"
"""Refusal: a bucket or container is added twice to one `StoreScanFs`."""

comptime STORE_FS_HANDLE = "STORE_FS_HANDLE"
"""Internal refusal: a `StoreFs` was given a handle of another store."""


# ---- the connectors --------------------------------------------------------


struct StoreConnectors[
    S3C: Connector,
    AZC: Connector,
    G: GcsStorageBackend,
    K: AwsClock & Copyable & Deinitable,
](Copyable, Movable):
    """The connector factories of S3 and Azure, by endpoint kind, the GCS
    backend factory, and the S3 signing clock (module header)."""

    var s3_plain: def () raises thin -> Self.S3C
    var s3_tls: def () raises thin -> Self.S3C
    var az_plain: def () raises thin -> Self.AZC
    var az_tls: def () raises thin -> Self.AZC
    var gcs: def (GcsAccess) raises thin -> Self.G
    var clock: Self.K

    def __init__(
        out self,
        s3_plain: def () raises thin -> Self.S3C,
        s3_tls: def () raises thin -> Self.S3C,
        az_plain: def () raises thin -> Self.AZC,
        az_tls: def () raises thin -> Self.AZC,
        gcs: def (GcsAccess) raises thin -> Self.G,
        var clock: Self.K,
    ):
        """Connectors for an `http://` and an `https://` (or provider-own)
        endpoint of S3 and of Azure, the factory of a GCS bucket's backend
        from its access, and the clock S3 requests are signed at."""
        self.s3_plain = s3_plain
        self.s3_tls = s3_tls
        self.az_plain = az_plain
        self.az_tls = az_tls
        self.gcs = gcs
        self.clock = clock^


comptime KernelStoreConnectors = StoreConnectors[
    KernelSchemeConnector, KernelSchemeConnector, KernelGcsBackend, SystemAwsClock
]


def kernel_store_connectors() -> KernelStoreConnectors:
    """The production connectors: kernel TCP in plaintext or under TLS with
    the public CA roots for S3 and Azure, google.storage.v2 over gRPC on TLS
    for GCS (`kernel_gcs_backend`), and the wall clock."""
    return KernelStoreConnectors(
        kernel_plain_scheme_connector,
        kernel_tls_scheme_connector,
        kernel_plain_scheme_connector,
        kernel_tls_scheme_connector,
        kernel_gcs_backend,
        SystemAwsClock(),
    )


# ---- the handles -----------------------------------------------------------


def _same_store(held: UInt8, handle: UInt8, verb: String) raises:
    """Raises `STORE_FS_HANDLE` when the handle is of another store than the
    file system `verb` was called on."""
    if held != handle:
        raise Error(
            String(STORE_FS_HANDLE)
            + ": StoreFs."
            + verb
            + " was given a handle of another object store"
        )


@fieldwise_init
struct StoreFile(Movable, Deinitable):
    """A read handle of a `StoreFs`: an S3, an Azure or a GCS handle."""

    var _store: UInt8
    var _s3: Optional[S3FileHandle]
    var _az: Optional[AzureFileHandle]
    var _gcs: Optional[GcsFileHandle]

    @staticmethod
    def of_s3(var handle: S3FileHandle) -> StoreFile:
        return StoreFile(
            FS_SCHEME_S3,
            Optional[S3FileHandle](handle^),
            Optional[AzureFileHandle](None),
            Optional[GcsFileHandle](None),
        )

    @staticmethod
    def of_azure(var handle: AzureFileHandle) -> StoreFile:
        return StoreFile(
            FS_SCHEME_AZURE,
            Optional[S3FileHandle](None),
            Optional[AzureFileHandle](handle^),
            Optional[GcsFileHandle](None),
        )

    @staticmethod
    def of_gcs(var handle: GcsFileHandle) -> StoreFile:
        return StoreFile(
            FS_SCHEME_GCS,
            Optional[S3FileHandle](None),
            Optional[AzureFileHandle](None),
            Optional[GcsFileHandle](handle^),
        )


@fieldwise_init
struct StoreWriteFile(Movable, Deinitable):
    """A write handle of a `StoreFs`: an S3, an Azure or a GCS handle."""

    var _store: UInt8
    var _s3: Optional[S3WriteFile]
    var _az: Optional[AzureWriteFile]
    var _gcs: Optional[GcsWriteFile]

    @staticmethod
    def of_s3(var handle: S3WriteFile) -> StoreWriteFile:
        return StoreWriteFile(
            FS_SCHEME_S3,
            Optional[S3WriteFile](handle^),
            Optional[AzureWriteFile](None),
            Optional[GcsWriteFile](None),
        )

    @staticmethod
    def of_azure(var handle: AzureWriteFile) -> StoreWriteFile:
        return StoreWriteFile(
            FS_SCHEME_AZURE,
            Optional[S3WriteFile](None),
            Optional[AzureWriteFile](handle^),
            Optional[GcsWriteFile](None),
        )

    @staticmethod
    def of_gcs(var handle: GcsWriteFile) -> StoreWriteFile:
        return StoreWriteFile(
            FS_SCHEME_GCS,
            Optional[S3WriteFile](None),
            Optional[AzureWriteFile](None),
            Optional[GcsWriteFile](handle^),
        )


# ---- the file system -------------------------------------------------------


struct _GcsEntry[G: GcsStorageBackend](Copyable, Movable):
    """One GCS bucket a run reads: its access and the factory its backends
    are built with."""

    var bucket: String
    var access: GcsAccess
    var mk: def (GcsAccess) raises thin -> Self.G

    def __init__(
        out self,
        var bucket: String,
        var access: GcsAccess,
        mk: def (GcsAccess) raises thin -> Self.G,
    ):
        self.bucket = bucket^
        self.access = access^
        self.mk = mk


struct StoreFs[
    S3C: Connector,
    AZC: Connector,
    G: GcsStorageBackend,
    K: AwsClock & Copyable & Deinitable,
](FileSystem, Movable, Deinitable):
    """One object-store file system: an `S3Fs[S3C, StaticCredsSource, K]`,
    an `AzureFs[AZC]` or a `GcsFs[LazyGcsBackend[G]]` (module header). Every
    verb goes to the one held."""

    comptime File = StoreFile
    comptime WriteFile = StoreWriteFile
    # No store has a disjoint-range concurrent write or an mmap, and (here)
    # no lazy Hive discovery: the scans of a bound source list their files.
    comptime SUPPORTS_PARALLEL_WRITES: Bool = False
    comptime IS_MMAP_BACKED: Bool = False
    comptime SUPPORTS_LAZY_HIVE: Bool = False

    comptime S3Backend = S3Fs[Self.S3C, StaticCredsSource, Self.K]
    comptime AzureBackend = AzureFs[Self.AZC]
    comptime GcsBackend = GcsFs[LazyGcsBackend[Self.G]]

    var _store: UInt8
    var _s3: Optional[Self.S3Backend]
    var _az: Optional[Self.AzureBackend]
    var _gcs: Optional[Self.GcsBackend]
    var _gcs_entry: Optional[_GcsEntry[Self.G]]

    def __init__(
        out self,
        store: UInt8,
        var s3: Optional[Self.S3Backend],
        var az: Optional[Self.AzureBackend],
        var gcs: Optional[Self.GcsBackend],
        var gcs_entry: Optional[_GcsEntry[Self.G]],
    ):
        """The file system of store `store` (`FS_SCHEME_S3`, `_AZURE` or
        `_GCS`), holding the matching one of `s3`, `az` and `gcs`."""
        self._store = store
        self._s3 = s3^
        self._az = az^
        self._gcs = gcs^
        self._gcs_entry = gcs_entry^

    @staticmethod
    def of_s3(var fs: Self.S3Backend) -> Self:
        """A file system over the S3 bucket `fs` reads."""
        return Self(
            FS_SCHEME_S3,
            Optional[Self.S3Backend](fs^),
            Optional[Self.AzureBackend](None),
            Optional[Self.GcsBackend](None),
            Optional[_GcsEntry[Self.G]](None),
        )

    @staticmethod
    def of_azure(var fs: Self.AzureBackend) -> Self:
        """A file system over the Azure container `fs` reads."""
        return Self(
            FS_SCHEME_AZURE,
            Optional[Self.S3Backend](None),
            Optional[Self.AzureBackend](fs^),
            Optional[Self.GcsBackend](None),
            Optional[_GcsEntry[Self.G]](None),
        )

    @staticmethod
    def of_gcs(
        var bucket: String,
        var access: GcsAccess,
        mk: def (GcsAccess) raises thin -> Self.G,
    ) -> Self:
        """A file system over GCS `bucket`, whose backend `mk(access)` builds
        on its first verb."""
        var fs = GcsFs[LazyGcsBackend[Self.G]](
            bucket=bucket.copy(),
            backend=LazyGcsBackend[Self.G](access.copy(), mk),
            mk_backend=_refuse_gcs_clone[Self.G],
        )
        return Self(
            FS_SCHEME_GCS,
            Optional[Self.S3Backend](None),
            Optional[Self.AzureBackend](None),
            Optional[Self.GcsBackend](fs^),
            Optional[_GcsEntry[Self.G]](
                _GcsEntry[Self.G](bucket^, access^, mk)
            ),
        )

    def clone(self) -> Self:
        if self._store == FS_SCHEME_S3:
            return Self.of_s3(self._s3.value().clone())
        if self._store == FS_SCHEME_AZURE:
            return Self.of_azure(self._az.value().clone())
        ref e = self._gcs_entry.value()
        return Self.of_gcs(e.bucket.copy(), e.access.copy(), e.mk)

    def key_prefix(self) -> String:
        if self._store == FS_SCHEME_S3:
            return self._s3.value().key_prefix()
        if self._store == FS_SCHEME_AZURE:
            return self._az.value().key_prefix()
        return self._gcs.value().key_prefix()

    def list(self, prefix: String) raises -> List[String]:
        if self._store == FS_SCHEME_S3:
            return self._s3.value().list(prefix)
        if self._store == FS_SCHEME_AZURE:
            return self._az.value().list(prefix)
        return self._gcs.value().list(prefix)

    def open(self, path: String) raises -> Self.File:
        if self._store == FS_SCHEME_S3:
            return StoreFile.of_s3(self._s3.value().open(path))
        if self._store == FS_SCHEME_AZURE:
            return StoreFile.of_azure(self._az.value().open(path))
        return StoreFile.of_gcs(self._gcs.value().open(path))

    def read_at(
        self,
        mut file: Self.File,
        offset: Int64,
        length: Int64,
    ) raises -> SharedAlignedBuffer[HeapRegion]:
        _same_store(self._store, file._store, "read_at")
        if self._store == FS_SCHEME_S3:
            return self._s3.value().read_at(file._s3.value(), offset, length)
        if self._store == FS_SCHEME_AZURE:
            return self._az.value().read_at(file._az.value(), offset, length)
        return self._gcs.value().read_at(file._gcs.value(), offset, length)

    def read_ranges_prefetched(
        self,
        mut file: Self.File,
        ranges: List[Tuple[Int64, Int64]],
    ) raises -> Slab[SharedAlignedBuffer[HeapRegion]]:
        _same_store(self._store, file._store, "read_ranges_prefetched")
        if self._store == FS_SCHEME_S3:
            return self._s3.value().read_ranges_prefetched(
                file._s3.value(), ranges
            )
        if self._store == FS_SCHEME_AZURE:
            return self._az.value().read_ranges_prefetched(
                file._az.value(), ranges
            )
        return self._gcs.value().read_ranges_prefetched(
            file._gcs.value(), ranges
        )

    def prefetch_depth(self) -> Int:
        if self._store == FS_SCHEME_S3:
            return self._s3.value().prefetch_depth()
        if self._store == FS_SCHEME_AZURE:
            return self._az.value().prefetch_depth()
        return self._gcs.value().prefetch_depth()

    def supports_random_read(self) -> Bool:
        if self._store == FS_SCHEME_S3:
            return self._s3.value().supports_random_read()
        if self._store == FS_SCHEME_AZURE:
            return self._az.value().supports_random_read()
        return self._gcs.value().supports_random_read()

    def read_footer(self, path: String, window: Int) raises -> FooterRegion:
        if self._store == FS_SCHEME_S3:
            return self._s3.value().read_footer(path, window)
        if self._store == FS_SCHEME_AZURE:
            return self._az.value().read_footer(path, window)
        return self._gcs.value().read_footer(path, window)

    def is_dir(self, path: String) raises -> Bool:
        if self._store == FS_SCHEME_S3:
            return self._s3.value().is_dir(path)
        if self._store == FS_SCHEME_AZURE:
            return self._az.value().is_dir(path)
        return self._gcs.value().is_dir(path)

    def list_dir_shallow(self, dir: String) raises -> List[ShallowDirEntry]:
        if self._store == FS_SCHEME_S3:
            return self._s3.value().list_dir_shallow(dir)
        if self._store == FS_SCHEME_AZURE:
            return self._az.value().list_dir_shallow(dir)
        return self._gcs.value().list_dir_shallow(dir)

    def file_size(self, path: String) raises -> Int:
        if self._store == FS_SCHEME_S3:
            return self._s3.value().file_size(path)
        if self._store == FS_SCHEME_AZURE:
            return self._az.value().file_size(path)
        return self._gcs.value().file_size(path)

    def delete(self, path: String) raises -> None:
        if self._store == FS_SCHEME_S3:
            self._s3.value().delete(path)
        elif self._store == FS_SCHEME_AZURE:
            self._az.value().delete(path)
        else:
            self._gcs.value().delete(path)

    def fsync_file(self, path: String) raises -> None:
        if self._store == FS_SCHEME_S3:
            self._s3.value().fsync_file(path)
        elif self._store == FS_SCHEME_AZURE:
            self._az.value().fsync_file(path)
        else:
            self._gcs.value().fsync_file(path)

    def fsync_dir(self, dir: String) raises -> None:
        if self._store == FS_SCHEME_S3:
            self._s3.value().fsync_dir(dir)
        elif self._store == FS_SCHEME_AZURE:
            self._az.value().fsync_dir(dir)
        else:
            self._gcs.value().fsync_dir(dir)

    def open_write(
        self, path: String, mode: WriteMode
    ) raises -> Self.WriteFile:
        if self._store == FS_SCHEME_S3:
            return StoreWriteFile.of_s3(self._s3.value().open_write(path, mode))
        if self._store == FS_SCHEME_AZURE:
            return StoreWriteFile.of_azure(
                self._az.value().open_write(path, mode)
            )
        return StoreWriteFile.of_gcs(self._gcs.value().open_write(path, mode))

    def write_at(
        self,
        mut file: Self.WriteFile,
        data: Span[UInt8, _],
    ) raises -> Int64:
        _same_store(self._store, file._store, "write_at")
        if self._store == FS_SCHEME_S3:
            return self._s3.value().write_at(file._s3.value(), data)
        if self._store == FS_SCHEME_AZURE:
            return self._az.value().write_at(file._az.value(), data)
        return self._gcs.value().write_at(file._gcs.value(), data)

    def pwrite_at(
        self,
        file: Self.WriteFile,
        offset: Int64,
        data: Span[UInt8, _],
    ) raises -> Int64:
        _same_store(self._store, file._store, "pwrite_at")
        if self._store == FS_SCHEME_S3:
            return self._s3.value().pwrite_at(file._s3.value(), offset, data)
        if self._store == FS_SCHEME_AZURE:
            return self._az.value().pwrite_at(file._az.value(), offset, data)
        return self._gcs.value().pwrite_at(file._gcs.value(), offset, data)

    def close_write(self, var file: Self.WriteFile) raises -> None:
        _same_store(self._store, file._store, "close_write")
        if self._store == FS_SCHEME_S3:
            self._s3.value().close_write(file._s3.take())
        elif self._store == FS_SCHEME_AZURE:
            self._az.value().close_write(file._az.take())
        else:
            self._gcs.value().close_write(file._gcs.take())

    def abort_write(self, var file: Self.WriteFile) raises -> None:
        _same_store(self._store, file._store, "abort_write")
        if self._store == FS_SCHEME_S3:
            self._s3.value().abort_write(file._s3.take())
        elif self._store == FS_SCHEME_AZURE:
            self._az.value().abort_write(file._az.take())
        else:
            self._gcs.value().abort_write(file._gcs.take())


# ---- the opener ------------------------------------------------------------


struct _S3Entry[C: Connector](Copyable, Movable):
    """One S3 bucket a run reads: its configuration, the credential its
    requests are signed with, and the connector factory its endpoint's scheme
    picked."""

    var bucket: String
    var config: S3Config
    var credential: AwsCredential
    var mk_connector: def () raises thin -> Self.C

    def __init__(
        out self,
        var bucket: String,
        var config: S3Config,
        var credential: AwsCredential,
        mk_connector: def () raises thin -> Self.C,
    ):
        self.bucket = bucket^
        self.config = config^
        self.credential = credential^
        self.mk_connector = mk_connector


struct _AzureEntry[C: Connector](Copyable, Movable):
    """One Azure container a run reads: the client spec (endpoint,
    credential, connector factory) its file systems build their clients
    from."""

    var container: String
    var spec: AzureClientSpec[Self.C]

    def __init__(
        out self, var container: String, var spec: AzureClientSpec[Self.C]
    ):
        self.container = container^
        self.spec = spec^


struct StoreScanFs[
    S3C: Connector,
    AZC: Connector,
    G: GcsStorageBackend,
    K: AwsClock & Copyable & Deinitable,
](ScanFsOpener, Movable):
    """Opens a `StoreFs` on each S3 bucket, Azure container and GCS bucket a
    run was told of (module header)."""

    comptime FS = StoreFs[Self.S3C, Self.AZC, Self.G, Self.K]

    var _connectors: StoreConnectors[Self.S3C, Self.AZC, Self.G, Self.K]
    var _s3: List[_S3Entry[Self.S3C]]
    var _az: List[_AzureEntry[Self.AZC]]
    var _gcs: List[_GcsEntry[Self.G]]

    def __init__(
        out self,
        var connectors: StoreConnectors[Self.S3C, Self.AZC, Self.G, Self.K],
    ):
        """An opener that serves nothing until `add_s3`, `add_azure` or
        `add_gcs`."""
        self._connectors = connectors^
        self._s3 = List[_S3Entry[Self.S3C]]()
        self._az = List[_AzureEntry[Self.AZC]]()
        self._gcs = List[_GcsEntry[Self.G]]()

    def add_s3(
        mut self,
        bucket: String,
        var config: S3Config,
        var credential: AwsCredential,
    ) raises:
        """Serve S3 `bucket` at `config`'s endpoint, signed with
        `credential`. The connector is the plaintext factory for an `http://`
        endpoint and the TLS one for "" or `https://`.

        Raises:
            `STORE_FS_DUPLICATE` when `bucket` is already served; the
            endpoint refusal of `s3_endpoint_is_plaintext` for another
            scheme.
        """
        self._refuse_duplicate(FS_SCHEME_S3, bucket)
        var mk = s3_connector_factory[Self.S3C](
            config.endpoint,
            self._connectors.s3_plain,
            self._connectors.s3_tls,
        )
        self._s3.append(
            _S3Entry[Self.S3C](bucket.copy(), config^, credential^, mk)
        )

    def add_azure(
        mut self,
        container: String,
        config: AzureFsConfig,
        credential: AzureCredential,
    ) raises:
        """Serve Azure `container` of `config`'s account and endpoint,
        authorized by `credential`. The connector is the plaintext factory
        for an `http://` endpoint and the TLS one otherwise.

        Raises:
            `STORE_FS_DUPLICATE` when `container` is already served; the
            refusals of `azure_fs_for` for a container name Azure would not
            accept, an invalid account or endpoint, or a Shared Key of
            another account.
        """
        self._refuse_duplicate(FS_SCHEME_AZURE, container)
        var fs = azure_fs_for[Self.AZC](
            container.copy(),
            config,
            credential,
            self._connectors.az_plain,
            self._connectors.az_tls,
        )
        self._az.append(_AzureEntry[Self.AZC](container.copy(), fs.spec()))

    def add_gcs(mut self, bucket: String, var access: GcsAccess) raises:
        """Serve GCS `bucket` at `access`'s endpoint, each call carrying its
        token; its backends are built by the connectors' `gcs` factory.

        Raises:
            `STORE_FS_DUPLICATE` when `bucket` is already served.
        """
        self._refuse_duplicate(FS_SCHEME_GCS, bucket)
        self._gcs.append(
            _GcsEntry[Self.G](bucket.copy(), access^, self._connectors.gcs)
        )

    def serves(self, scheme: UInt8, bucket: String) -> Bool:
        """Whether a scan of `bucket` of store `scheme` can be opened."""
        if scheme == FS_SCHEME_S3:
            return self._s3_at(bucket) >= 0
        if scheme == FS_SCHEME_AZURE:
            return self._az_at(bucket) >= 0
        if scheme == FS_SCHEME_GCS:
            return self._gcs_at(bucket) >= 0
        return False

    def open_scan_fs(self, scheme: UInt8, bucket: String) raises -> Self.FS:
        """The file system on `bucket` of store `scheme`, built but not
        dialed.

        Raises:
            `SCAN_FS_UNSERVED` (word for word as `LocalOnlyScanFs`) when
            `serves(scheme, bucket)` is False.
        """
        if scheme == FS_SCHEME_S3:
            var at = self._s3_at(bucket)
            if at >= 0:
                ref e = self._s3[at]
                return Self.FS.of_s3(
                    S3Fs[Self.S3C, StaticCredsSource, Self.K](
                        bucket.copy(),
                        e.config.copy(),
                        e.mk_connector,
                        HttpClientConfig.defaults(),
                        StaticCredsSource(e.credential.copy()),
                        self._connectors.clock.copy(),
                    )
                )
        elif scheme == FS_SCHEME_AZURE:
            var at = self._az_at(bucket)
            if at >= 0:
                return Self.FS.of_azure(
                    AzureFs[Self.AZC](bucket.copy(), self._az[at].spec.copy())
                )
        elif scheme == FS_SCHEME_GCS:
            var at = self._gcs_at(bucket)
            if at >= 0:
                ref g = self._gcs[at]
                return Self.FS.of_gcs(bucket.copy(), g.access.copy(), g.mk)
        raise scan_fs_unserved(
            FsDescriptorPod.cloud(scheme, bucket, -1).url_prefix()
        )

    def _s3_at(self, bucket: String) -> Int:
        for i in range(len(self._s3)):
            if self._s3[i].bucket == bucket:
                return i
        return -1

    def _az_at(self, container: String) -> Int:
        for i in range(len(self._az)):
            if self._az[i].container == container:
                return i
        return -1

    def _gcs_at(self, bucket: String) -> Int:
        for i in range(len(self._gcs)):
            if self._gcs[i].bucket == bucket:
                return i
        return -1

    def _refuse_duplicate(self, scheme: UInt8, bucket: String) raises:
        if self.serves(scheme, bucket):
            raise Error(
                String(STORE_FS_DUPLICATE)
                + ": "
                + FsDescriptorPod.cloud(scheme, bucket, -1).url_prefix()
                + " is already served by this run's file systems"
            )
