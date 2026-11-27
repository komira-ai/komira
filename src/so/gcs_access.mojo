# =============================================================================
# so/gcs_access.mojo -- how a libkomira session reaches one GCS bucket
# =============================================================================
#
# `GcsAccess` is a GCS bucket's access as `StoreScanFs.add_gcs` takes it: the
# gRPC endpoint's host and port and the OAuth access token each call carries.
# `GcsAccess.at(endpoint, token)` reads the endpoint a source names ("" for
# Google's own, `storage.googleapis.com:443`, or `https://host[:port]`), and
# `gcs_endpoint_refusal` says why one is not read. There is no `http://`
# endpoint: Cloud Storage is read over gRPC on TLS, and grpc carries only
# unary calls over plaintext h2c, so ReadObject's stream could not use one.
#
# `LazyGcsBackend[G]` is the backend a `StoreFs`'s `GcsFs` reads through: it
# builds its `G` from the access with a factory on its first verb, so opening
# a file system, and cloning one, builds and dials nothing.
# `kernel_gcs_backend` is the production factory: objectstore_gcs's
# `StorageGrpcBackend` over a public-CA TLS connector, with the token fixed
# for the run (`StaticTokenSource`). A test hands in a fake factory instead
# (`StoreConnectors.gcs`).
#
# No refusal here echoes the endpoint or the token, and `GcsAccess` is not
# Writable. Nothing here reads the environment.
# =============================================================================

from gcp_core import StaticTokenSource
from http_client.client import HttpClientConfig
from objectstore_gcs import (
    GCS_GRPC_HOST,
    GCS_GRPC_PORT,
    GcsStorageBackend,
    GcsTlsConnector,
    ListPageRaw,
    ObjectMetaRaw,
    StorageGrpcBackend,
    build_gcs_tls_connector,
)
from retry import SystemClock

comptime _URL_REFUSED = "STORAGE_URL_REFUSED"
"""The code of a GCS endpoint refused by `GcsAccess.at`: the one the bindings
give a location or endpoint no store reads."""


# ---- a GCS bucket's access -------------------------------------------------


@fieldwise_init
struct GcsAccess(Copyable, Movable):
    """How one GCS bucket is reached: the gRPC endpoint's host and port, and
    the OAuth access token each call carries. Not Writable: the token is a
    credential value."""

    var host: String
    """The endpoint's host: `storage.googleapis.com`, or the source's own."""
    var port: UInt16
    """The endpoint's port: 443, or the source's own."""
    var token: String
    """The bearer token (a `GcpToken`'s value), without a `Bearer ` prefix."""

    @staticmethod
    def at(endpoint: String, var token: String) raises -> GcsAccess:
        """The access of a bucket at `endpoint` ("" for Google's own) read with
        `token`.

        Raises:
            `STORAGE_URL_REFUSED: gcs endpoint: <reason>` when
            `gcs_endpoint_refusal(endpoint)` names a reason; the endpoint is
            not echoed.
        """
        var parsed = _parse_gcs_endpoint(endpoint)
        if parsed.problem.byte_length() > 0:
            raise Error(
                String(_URL_REFUSED) + ": gcs endpoint: " + parsed.problem
            )
        return GcsAccess(parsed.host.copy(), parsed.port, token^)


@fieldwise_init
struct _GcsEndpoint(Movable):
    """An endpoint read: its host and port, or the reason it is refused."""

    var host: String
    var port: UInt16
    var problem: String


def _bad_endpoint(reason: String) -> _GcsEndpoint:
    return _GcsEndpoint(String(""), UInt16(0), String(reason))


def _parse_port(digits: String) -> Int:
    """The port `digits` spells, 1 to 65535, or -1."""
    var bytes = digits.as_bytes()
    if len(bytes) == 0 or len(bytes) > 5:
        return -1
    var n = 0
    for i in range(len(bytes)):
        var b = Int(bytes[i])
        if b < ord("0") or b > ord("9"):
            return -1
        n = n * 10 + (b - ord("0"))
    if n < 1 or n > 65535:
        return -1
    return n


def _is_host_name(host: String) -> Bool:
    """Whether every byte of `host` is a letter, a digit, `.` or `-`, so the
    name the TLS handshake checks is the name the request is sent to."""
    var bytes = host.as_bytes()
    for i in range(len(bytes)):
        var b = Int(bytes[i])
        var letter = (b >= ord("a") and b <= ord("z")) or (
            b >= ord("A") and b <= ord("Z")
        )
        var digit = b >= ord("0") and b <= ord("9")
        if not (letter or digit or b == ord(".") or b == ord("-")):
            return False
    return True


def _parse_gcs_endpoint(endpoint: String) -> _GcsEndpoint:
    """`endpoint` as `https://host[:port][/]`; "" is Google's own."""
    if endpoint.byte_length() == 0:
        return _GcsEndpoint(String(GCS_GRPC_HOST), GCS_GRPC_PORT, String(""))
    if not endpoint.lower().startswith("https://"):
        return _bad_endpoint(
            "a gs:// endpoint must start with https://: Cloud Storage is read"
            " over gRPC on TLS, with no plaintext route"
        )
    if endpoint.find("?") >= 0 or endpoint.find("#") >= 0:
        return _bad_endpoint("a gs:// endpoint must not carry a query or a fragment")
    var authority = String(endpoint[byte = 8 : endpoint.byte_length()])
    var slash = authority.find("/")
    if slash >= 0:
        if slash + 1 != authority.byte_length():
            return _bad_endpoint("a gs:// endpoint must not carry a path")
        authority = String(authority[byte=0:slash])
    if authority.find("@") >= 0:
        return _bad_endpoint("a gs:// endpoint must not carry user information")
    var host = authority.copy()
    var port = Int(GCS_GRPC_PORT)
    var colon = authority.find(":")
    if colon >= 0:
        host = String(authority[byte=0:colon])
        port = _parse_port(
            String(authority[byte = colon + 1 : authority.byte_length()])
        )
    if host.byte_length() == 0:
        return _bad_endpoint("a gs:// endpoint names no host")
    if not _is_host_name(host):
        return _bad_endpoint(
            "a gs:// endpoint's host must be a DNS name or an IPv4 address:"
            " letters, digits, '.' and '-'"
        )
    if port < 0:
        return _bad_endpoint(
            "a gs:// endpoint's port must be a number from 1 to 65535"
        )
    return _GcsEndpoint(host^, UInt16(port), String(""))


def gcs_endpoint_refusal(endpoint: String) -> String:
    """Why `endpoint` is not a GCS endpoint this library reads, or "" when it
    is: "" (Google's own) or `https://host[:port]` with an optional final
    `/`, no path, user information, query or fragment, a host of letters,
    digits, `.` and `-` (no IPv6 literal), and a port from 1 to 65535 (443
    when absent). The reason never echoes the endpoint."""
    return _parse_gcs_endpoint(endpoint).problem.copy()


# ---- the GCS backend, built on its first verb -------------------------------


struct LazyGcsBackend[G: GcsStorageBackend](
    GcsStorageBackend, Movable, Deinitable
):
    """A `GcsStorageBackend` that builds its `G` from a bucket's `GcsAccess`
    on its first verb and passes every verb to it (module header). Building
    it builds and dials nothing."""

    var _access: GcsAccess
    var _mk: def (GcsAccess) raises thin -> Self.G
    var _backend: Optional[Self.G]

    def __init__(
        out self,
        var access: GcsAccess,
        mk: def (GcsAccess) raises thin -> Self.G,
    ):
        """A backend that `mk(access)` builds on the first verb."""
        self._access = access^
        self._mk = mk
        self._backend = Optional[Self.G](None)

    def built(self) -> Bool:
        """Whether a verb has built the backend yet."""
        return Bool(self._backend)

    def _build(mut self) raises:
        if not self._backend:
            self._backend = Optional[Self.G](self._mk(self._access))

    def conditional_create(
        mut self, bucket: String, key: String, data: List[UInt8]
    ) raises -> Int64:
        self._build()
        return self._backend.value().conditional_create(bucket, key, data)

    def compare_and_swap(
        mut self,
        bucket: String,
        key: String,
        data: List[UInt8],
        expected_generation: Int64,
    ) raises -> Int64:
        self._build()
        return self._backend.value().compare_and_swap(
            bucket, key, data, expected_generation
        )

    def read_range(
        mut self,
        bucket: String,
        key: String,
        read_offset: Int64,
        read_limit: Int64,
    ) raises -> List[UInt8]:
        self._build()
        return self._backend.value().read_range(
            bucket, key, read_offset, read_limit
        )

    def get_object(mut self, bucket: String, key: String) raises -> ObjectMetaRaw:
        self._build()
        return self._backend.value().get_object(bucket, key)

    def delete_object(mut self, bucket: String, key: String) raises:
        self._build()
        self._backend.value().delete_object(bucket, key)

    def list_objects(
        mut self,
        bucket: String,
        prefix: String,
        page_token: String,
        delimiter: String = String(""),
    ) raises -> ListPageRaw:
        self._build()
        return self._backend.value().list_objects(
            bucket, prefix, page_token, delimiter
        )


def _refuse_gcs_clone[G: GcsStorageBackend]() raises -> LazyGcsBackend[G]:
    """The factory a `StoreFs`'s `GcsFs` is given for `GcsFs.clone`, which
    `StoreFs` never calls: a thin factory has no access to build from, so
    `StoreFs.clone` builds a new `GcsFs` from the bucket's access instead."""
    raise Error(
        "StoreFs: a GCS file system is cloned through StoreFs.clone, from its"
        " bucket's access; GcsFs.clone has no access to build a backend from"
    )


comptime KernelGcsBackend = StorageGrpcBackend[
    GcsTlsConnector, StaticTokenSource, SystemClock
]
"""The production GCS backend: google.storage.v2 over gRPC, on TLS with the
public CA roots, a fixed bearer token, and the monotonic system clock."""


def kernel_gcs_backend(access: GcsAccess) raises -> KernelGcsBackend:
    """The production backend of a bucket at `access`'s endpoint, sending
    `access.token` with each call. Dials nothing: the first verb does."""
    return KernelGcsBackend(
        build_gcs_tls_connector(access.host),
        StaticTokenSource(access.token.copy()),
        SystemClock(),
        HttpClientConfig.defaults(),
        host=access.host,
        port=access.port,
    )
