# =============================================================================
# komira_objectstore_s3/conditional_store.mojo -- S3ConditionalStore, the
# komira_objectstore conformer for one S3 bucket
# =============================================================================
#
# `S3ConditionalStore[C, T, K]` is S3 as komira_objectstore's
# `CloneableConditionalWriteStore` (and `RangeFetchStore`): bound to ONE
# bucket, the trait's `path` is the object key in it.
#
# VERBS, each over S3Store (store.mojo):
#   head                 -> HeadObject
#   list_with_delimiter  -> ListObjectsV2, delimiter "/", every page
#   conditional_put      -> PutObject with If-None-Match / If-Match
#   compare_and_swap     -> PutObject with If-Match: <etag>
#   put                  -> PutObject, unconditional
#   get_range            -> GetObject with Range (half-open -> closed once)
#   get                  -> GetObject
#   delete               -> DeleteObject (absent is success)
#   get_ranges           -> coalesced ranged GetObjects
#
# THE CAS HANDLE IS THE ETAG, in both `ObjectMeta.etag` and `.version`, as
# S3 returns it (quoted). S3's VersionId is not a CAS handle and is not used.
#
# CLONES. The trait's verbs take `self` immutably, and `clone()` must be
# infallible. So the store is built lazily, behind an `ArcPointer[Optional]`
# reached mutably through the Arc, and a clone gets a NEW empty Arc: no two
# conformers share a store (its connection and HTTP client are not shared
# between threads), and none shares a retry quota. A clone copies the
# configuration, the caller's `HttpClientConfig`, the credential source and
# the clock, so `T` and `K` are Copyable; the connector factory is a thin
# function pointer (a code address, no heap).
#
# CREDENTIALS THAT EXPIRE. A copy of `T` must not be a copy of a credential
# that goes stale. `StaticCredsSource` is one fixed credential and fits keys
# that do not expire. For temporary credentials (an instance or container
# role, STS, SSO, web identity) `T` is komira_aws_core's
# `SharedCredsSource`, whose copies share ONE refreshing chain: every clone
# of this store signs with the credential the chain holds now, refreshed
# before it expires, and the chain is resolved once for all of them.
# `ProcessCredsSource` is that source over the process's environment and
# files.
#
# No UnsafePointer in any signature, no wildcard origin.
# =============================================================================

from std.memory import ArcPointer

from komira_aws_core import AwsClock, AwsCredsSource
from komira_buffer.byte_view import ByteView
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.io_stream import Connector
from komira_objectstore.path import Path
from komira_objectstore.store import (
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    PREFETCH_DEPTH_S3_STANDARD,
    RangeFetchStore,
)
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    RangeFetchResult,
    RangeSet,
    WritePrecondition,
)

from .config import S3Config
from .store import S3Store


struct S3ConditionalStore[
    C: Connector,
    T: AwsCredsSource & Copyable,
    K: AwsClock & Copyable & Deinitable,
](
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    RangeFetchStore,
    Movable,
    Deinitable,
):
    """A `ConditionalWriteStore` over one S3 bucket (module header).

        var store = S3ConditionalStore[KernelTcpConnector, ProcessCredsSource, SystemAwsClock](
            "lake", S3Config.custom_endpoint("us-east-1", "http://127.0.0.1:9000"),
            mk_connector, HttpClientConfig.defaults(), creds, SystemAwsClock(),
        )
        var meta = store.conditional_put(
            Path.parse("manifest/v1.json"), bytes,
            WritePrecondition.if_none_match_star(),
        )
        _ = store.compare_and_swap(Path.parse("manifest/v1.json"), bytes2, meta.etag)
    """

    var _bucket: String
    var _config: S3Config
    var _mk_connector: def () raises thin -> Self.C
    var _http_config: HttpClientConfig
    var _creds: Self.T
    var _clock: Self.K
    var _store: ArcPointer[Optional[S3Store[Self.C, Self.T, Self.K]]]

    def __init__(
        out self,
        var bucket: String,
        var config: S3Config,
        mk_connector: def () raises thin -> Self.C,
        http_config: HttpClientConfig,
        var creds: Self.T,
        var clock: Self.K,
    ):
        """A store bound to `bucket`. Nothing is built or dialed here: the
        S3 store is built on the first verb."""
        self._bucket = bucket^
        self._config = config^
        self._mk_connector = mk_connector
        self._http_config = http_config.copy()
        self._creds = creds^
        self._clock = clock^
        self._store = ArcPointer[Optional[S3Store[Self.C, Self.T, Self.K]]](
            Optional[S3Store[Self.C, Self.T, Self.K]](None)
        )

    @staticmethod
    def built(
        var bucket: String,
        var config: S3Config,
        mk_connector: def () raises thin -> Self.C,
        http_config: HttpClientConfig,
        var creds: Self.T,
        var clock: Self.K,
    ) raises -> Self:
        """A store whose S3 store is built now, so a failure to build it (a
        bad endpoint, a connector that cannot be made) raises here rather
        than on the first verb."""
        var s = Self(bucket^, config^, mk_connector, http_config, creds^, clock^)
        s._build_if_absent()
        return s^

    def clone(self) -> Self:
        """A store on the same bucket and configuration with its OWN, not
        yet built, S3 store (a new Arc). Infallible."""
        return Self(
            self._bucket.copy(),
            self._config.copy(),
            self._mk_connector,
            self._http_config,
            self._creds.copy(),
            self._clock.copy(),
        )

    def bucket(self) -> String:
        """The bucket this store is bound to."""
        return self._bucket.copy()

    def _build_if_absent(self) raises:
        ref slot = self._store[]
        if not slot:
            slot = Optional[S3Store[Self.C, Self.T, Self.K]](
                S3Store[Self.C, Self.T, Self.K](
                    self._config.copy(),
                    self._mk_connector,
                    self._http_config,
                    self._creds.copy(),
                    self._clock.copy(),
                )
            )

    # ---- ObjectStore ----------------------------------------------------

    def head(self, path: Path) raises -> ObjectMeta:
        """Size, ETag and last-modified time of the object at `path`."""
        self._build_if_absent()
        return self._store[].value().head(self._bucket, path.raw())

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        """The `/`-delimited listing under `prefix`, every page drained."""
        self._build_if_absent()
        return self._store[].value().list(self._bucket, prefix.raw(), String("/"))

    def coalesce_policy(self) -> CoalescePolicy:
        """The default policy, its concurrency bounded by `max_inflight`."""
        var p = CoalescePolicy.default()
        p.max_concurrency = min(p.max_concurrency, self._config.max_inflight)
        return p

    # ---- ConditionalWriteStore ----------------------------------------------

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        """PutObject under `precond`. A lost condition raises
        `StoreError[PRECONDITION]` (S3Store.conditional_put)."""
        self._build_if_absent()
        return self._store[].value().conditional_put(
            self._bucket, path.raw(), bytes, precond
        )

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        """Write `bytes` only if the object's ETag is `expected_version`."""
        return self.conditional_put(
            path, bytes, WritePrecondition.if_match(expected_version)
        )

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        """Create or overwrite `path`: one unconditional PutObject."""
        return self.conditional_put(path, bytes, WritePrecondition.none())

    def get_range(self, path: Path, start: Int64, length: Int64) raises -> List[UInt8]:
        """Exactly `length` bytes from `start` (half-open). A zero length
        reads nothing; a negative start or length, or fewer bytes than
        asked for (the object ends first), raises."""
        if start < 0 or length < 0:
            raise Error(
                String("S3ConditionalStore.get_range: negative start (")
                + String(start)
                + ") or length ("
                + String(length)
                + ") (key: "
                + path.raw()
                + ")"
            )
        if length == 0:
            return List[UInt8]()
        self._build_if_absent()
        var bytes = self._store[].value().get_range(self._bucket, path.raw(), start, length)
        if Int64(len(bytes)) != length:
            raise Error(
                String("S3ConditionalStore.get_range: short read: asked for ")
                + String(length)
                + " bytes, got "
                + String(len(bytes))
                + " (key: "
                + path.raw()
                + ")"
            )
        return bytes^

    def get(self, path: Path) raises -> List[UInt8]:
        """The whole object at `path`."""
        self._build_if_absent()
        return self._store[].value().get(self._bucket, path.raw())

    def delete(self, path: Path) raises -> None:
        """Delete the object at `path`; an absent one is not an error."""
        self._build_if_absent()
        self._store[].value().delete(self._bucket, path.raw())

    # ---- RangeFetchStore --------------------------------------------------

    def get_ranges[
        dst_origin: Origin[mut=True]
    ](
        mut self,
        path: Path,
        ranges: RangeSet,
        dst: ByteView[mut=True, dst_origin],
        max_concurrency: Int = PREFETCH_DEPTH_S3_STANDARD,
    ) raises -> RangeFetchResult:
        """Every range of `ranges` into `dst` (S3Store.get_ranges_into)."""
        self._build_if_absent()
        return self._store[].value().get_ranges_into(
            self._bucket, path.raw(), ranges, dst, max_concurrency
        )
