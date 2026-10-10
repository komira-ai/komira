# =============================================================================
# komira_objectstore_gcs/grpc_backend.mojo
#   StorageGrpcBackend[C, T, K] — the google.storage.v2 conformer of the
#   GcsStorageBackend seam, over the generated komira_gcp_storage client.
# =============================================================================
#
# WHAT IS GENERATED AND WHAT IS NOT. Every RPC goes through the generated
# `komira_gcp_storage.storage.StorageClient[C, T]`: it sets the call's bearer
# token from `T`, sets `x-goog-request-params` from the method's
# `(google.api.routing)` annotation, and raises a non-OK gRPC status as
# `komira_gcp_core.gcp_grpc_status_error` (the code and the length of the
# server's text, never the text). What stays here, by hand:
#   * WriteObject. It is client streaming and storage.proto gives it no
#     routing annotation, so the routing header is set here, built with
#     komira_grpc's `build_routing_params` (percent-encoded, as the generated
#     methods send it). The payload goes out as messages of at most
#     `WRITE_OBJECT_CHUNK_BYTES`; the first carries the `WriteObjectSpec`
#     with `if_generation_match`, the last `finish_write` and the whole
#     object's CRC-32C; every message states its chunk's CRC-32C, so the
#     service fails a write whose bytes changed on the way.
#   * ReadObject's range and the drain of its server stream into one buffer,
#     checked: the bytes received must add up to the length the first
#     response states (its `content_range`, or the object's size), each
#     chunk must match the CRC-32C it carries, and a whole-object read must
#     match the object's CRC-32C. A short or corrupt read raises; it is never
#     returned as the object. (komira_grpc's `server_stream` does not hand
#     the trailers to its decoder and treats a missing `grpc-status` as OK,
#     so the length check is what catches a truncated stream here.)
#   * The per-call deadline: `CallOptions` carries `call_deadline_ms` from
#     the injected `K: MonotonicClock` (it reaches the peer as
#     `grpc-timeout`), and every call passes a child of this backend's
#     cancellation token, which `cancel` trips. The bound that does not
#     depend on the peer is the transport's `request_timeout_us`
#     (`HttpClientConfig`); see `request_timeout_us()`.
#     ⚠ `request_timeout_us()` and `token_source()` read the generated
#     client's fields (`StorageClient._client`, `GrpcClient._http`,
#     `StorageClient._token_source`): the generator emits no accessor for the
#     first two, so a rename there breaks this file at compile time.
#   * The mapping of a gRPC status onto the seam's `StoreError[<KIND>]`
#     contract (the `GCS_ERR_*` kinds), below.
#
# TRANSPORT. `GcsTlsConnector = TlsConnector[KernelTcpConnector]`, built by
# `build_gcs_tls_connector`: system CA trust, SNI = the host, ALPN `h2`. The
# service speaks gRPC over HTTP/2 over TLS only, and the backend always dials
# `https://`. That default is the only trust the production endpoint needs.
# A peer behind a private CA (an emulator behind TLS, an in-process fake) is
# reached over `build_gcs_tls_connector_trusting(root_pem, server_name)`,
# which trusts `root_pem` alone and still verifies the chain and the name;
# nothing selects it but that call. There is no
# plaintext (h2c) route: komira_grpc routes only unary calls over h2c, so
# WriteObject and ReadObject could not use one. A test drives the backend over
# a scripted connector instead.
#
# CREDENTIALS. The bearer token comes from any `komira_gcp_core.GcpTokenSource`
# (a `CachingTokenSource` over a token fetcher in production, or a fixed
# token, `StaticTokenSource`). The generated client refuses an empty token
# before anything is sent. Nothing here reads the environment.
#
# Nothing here drops a cached token: UNAUTHENTICATED raises
# `StoreError[PERMISSION_DENIED] ... grpc_code=16 (UNAUTHENTICATED)`, and the
# owner of the token source decides to `invalidate` it (`token_source()`).
#
# THE ERROR CONTRACT (backend.mojo). A call that ends in a gRPC status raises
#   StoreError[<KIND>] <Method> gs://<bucket>/<key> status=<http> grpc_code=<n> (<NAME>)
# with the kind from `gcs_error_kind_from_code`:
#   FAILED_PRECONDITION, ALREADY_EXISTS           -> PRECONDITION       412
#   NOT_FOUND                                     -> NOT_FOUND          404
#   PERMISSION_DENIED, UNAUTHENTICATED            -> PERMISSION_DENIED  403
#   RESOURCE_EXHAUSTED, UNAVAILABLE, ABORTED      -> THROTTLED          429
#   UNKNOWN, CANCELLED, DEADLINE_EXCEEDED,
#   INTERNAL, DATA_LOSS                           -> TRANSPORT          500
#   anything else (INVALID_ARGUMENT, OUT_OF_RANGE,
#   UNIMPLEMENTED, ...)                           -> MALFORMED          400
# ABORTED is a concurrency conflict to retry at a higher level (AIP-194), not
# a failed precondition: read as 412, a create-if-absent that lost to a write
# which itself failed would conclude the key exists and never retry.
# An error that carries no status (a fault before any status arrived, a token
# source that failed) raises
#   StoreError[TRANSPORT] <Method> gs://<bucket>/<key> status=500 detail=<class>, error text <n> bytes
# where <class> is the text before its first `:` when that is a short
# identifier (`HttpError[EOF_MID_RESPONSE]`), and otherwise absent: a token
# fetcher may raise with its endpoint's answer in the text, so the rest is
# counted, not kept. No server text reaches any form.
#
# NO RETRY HERE. Each verb is one call (komira_grpc still re-issues a request
# the peer proved it did not process). A conditional write that may have
# landed is not resent; a caller that retries decides that itself.
#
# Ownership: the generated client owns its GrpcClient, which owns the
# HttpClient through an OwnedPointer; the reactor, clock and token are owned
# fields. No UnsafePointer in any signature.
# =============================================================================

from std.sys.info import CompilationTarget

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_gcp_core import (
    CODE_ABORTED,
    CODE_ALREADY_EXISTS,
    CODE_CANCELLED,
    CODE_DATA_LOSS,
    CODE_DEADLINE_EXCEEDED,
    CODE_FAILED_PRECONDITION,
    CODE_INTERNAL,
    CODE_NOT_FOUND,
    CODE_PERMISSION_DENIED,
    CODE_RESOURCE_EXHAUSTED,
    CODE_UNAUTHENTICATED,
    CODE_UNAVAILABLE,
    CODE_UNKNOWN,
    GcpTokenSource,
    code_from_grpc_status,
    code_name,
    gcp_grpc_error_code,
)
from komira_gcp_storage.storage import (
    ChecksummedData,
    DeleteObjectRequest,
    GetObjectRequest,
    ListObjectsRequest,
    ListObjectsResponse,
    Object,
    ObjectChecksums,
    ReadObjectRequest,
    ReadObjectResponse,
    StorageClient,
    WriteObjectRequest,
    WriteObjectResponse,
    WriteObjectSpec,
)
from komira_grpc import (
    CallOptions,
    ClientStreamEncoder,
    GrpcClient,
    ProtocolGrpcProto,
    STREAM_OUTCOME_END_OK,
    STREAM_OUTCOME_MESSAGE,
    STREAM_OUTCOME_PENDING,
    ServerStreamDecoder,
    build_routing_params,
)
from komira_http_client.client import HttpClient, HttpClientConfig
from komira_http_client.pool import VERIFY_PEER
from komira_http_client.tls_connector import (
    TlsConnector,
    build_public_ca_tls_connector,
)
from komira_http_client.url import Url
from komira_http_core.tls import TlsConfig
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_proto_codec import Serializable
from komira_proto_codec.proto_binary import PbDecoder, PbEncoder
from komira_retry import MonotonicClock

from .backend import GcsStorageBackend, ListPageRaw, ObjectMetaRaw
from .crc32c import crc32c, crc32c_extend
from .errors import (
    GCS_ERR_MALFORMED,
    GCS_ERR_NOT_FOUND,
    GCS_ERR_PERMISSION_DENIED,
    GCS_ERR_PRECONDITION,
    GCS_ERR_THROTTLED,
    GCS_ERR_TRANSPORT,
)


# =============================================================================
# §1 — Constants and the transport.
# =============================================================================

comptime GCS_GRPC_HOST = "storage.googleapis.com"
"""The Cloud Storage gRPC endpoint."""

comptime GCS_GRPC_PORT: UInt16 = 443
"""Its port (HTTP/2 over TLS)."""

comptime GCS_DEFAULT_CALL_DEADLINE_MS: Int = 60_000
"""The deadline each call states to the peer (`grpc-timeout`) unless the
caller gives another. It bounds nothing on its own: a peer that accepts the
request and goes silent is bounded by the transport's `request_timeout_us`."""

comptime WRITE_OBJECT_CHUNK_BYTES: Int = 2 * 1024 * 1024
"""Payload bytes per WriteObject message: storage.proto's
`ServiceConstants.MAX_WRITE_CHUNK_BYTES` (2 MiB), the most data one
`WriteObjectRequest` may carry. The object is still held in memory whole:
this keeps each message within the service's limit, it does not stream."""

comptime GcsTlsConnector = TlsConnector[KernelTcpConnector]
"""The connector type of every TLS dial: TLS over kernel TCP, ALPN h2. Its
trust is its `TlsConfig`'s: the system CA store from `build_gcs_tls_connector`,
the caller's root alone from `build_gcs_tls_connector_trusting`."""

comptime _RT = PerCoreAsyncRuntime[NoopSink]

comptime _SVC = "/google.storage.v2.Storage/"


def build_gcs_tls_connector(
    host: String = String(GCS_GRPC_HOST),
) raises -> GcsTlsConnector:
    """A TLS connector for the gRPC endpoint `host`: the system CA trust
    store, SNI = `host`, ALPN offering `h2` (the gRPC transport needs h2).

    The default, and the only connector the production endpoint needs. A peer
    whose certificate chains to no public root (an emulator, a loopback fake)
    fails the handshake: reach one with `build_gcs_tls_connector_trusting`.
    """
    return build_public_ca_tls_connector(host, alpn_h2=True)


def build_gcs_tls_connector_trusting(
    root_pem: String, server_name: String
) raises -> GcsTlsConnector:
    """A TLS connector for a gRPC endpoint whose certificate a private CA
    signed (a storage emulator behind TLS, an in-process fake): the trust
    store is exactly `root_pem` (one or more PEM certificates; the OS's
    public roots are wiped first), SNI is pinned to `server_name`, and the
    connector is `VERIFY_PEER`, so the handshake checks the peer's chain
    against `root_pem` and its name against `server_name`. TLS 1.3
    preferences and ALPN `h2`, `http/1.1`, as `build_gcs_tls_connector`
    offers. The backend's `host` may then be an address (the SNI and the
    name checked stay `server_name`).

    It takes the root, not a `TlsConfig`: verification cannot be turned off
    through it. Raises when `server_name` is empty (there would be no name to
    check) and when `root_pem` holds no certificate s2n can parse."""
    if server_name.byte_length() == 0:
        raise Error(
            "build_gcs_tls_connector_trusting: server_name is empty; the"
            " peer's certificate is checked against it"
        )
    var config = TlsConfig()
    config.set_cipher_preferences(String("default_tls13"))
    config.wipe_trust()
    config.add_trust_pem(root_pem)
    config.enable_verify_default()
    config.set_alpn_protocols(_gcs_alpn())
    var connector = GcsTlsConnector(
        config^, KernelTcpConnector.new(), VERIFY_PEER
    )
    connector.set_server_name_for_next_connect(server_name)
    return connector^


def _gcs_alpn() -> List[String]:
    """The ALPN list every GCS connector offers: `h2` first."""
    var alpn = List[String]()
    alpn.append(String("h2"))
    alpn.append(String("http/1.1"))
    return alpn^


@always_inline
def gcs_bucket_resource_name(bucket: String) -> String:
    """The v2 bucket resource name, `projects/_/buckets/<bucket>` (`_`: the
    service infers the project). Requests name the bucket this way; the
    object name stays the bare key."""
    return String("projects/_/buckets/") + bucket


def gcs_routing_param(bucket: String) -> String:
    """The `x-goog-request-params` value for a call on `bucket`:
    `bucket=projects%2F_%2Fbuckets%2F<bucket>`, encoded by komira_grpc's
    `build_routing_params` exactly as the generated methods encode theirs."""
    var pairs = List[Tuple[StaticString, String]]()
    pairs.append((StaticString("bucket"), gcs_bucket_resource_name(bucket)))
    return build_routing_params(pairs)


# =============================================================================
# §2 — gRPC status -> StoreError.
# =============================================================================


def gcs_error_kind_from_code(code: Int) -> UInt8:
    """The `GCS_ERR_*` kind a call ending in `google.rpc.Code` `code` raises
    (the table in the module header)."""
    if code == CODE_FAILED_PRECONDITION or code == CODE_ALREADY_EXISTS:
        # ALREADY_EXISTS is how a create-if-absent race can come back: the
        # 412 a CAS loop reads.
        return GCS_ERR_PRECONDITION
    if code == CODE_NOT_FOUND:
        return GCS_ERR_NOT_FOUND
    if code == CODE_PERMISSION_DENIED or code == CODE_UNAUTHENTICATED:
        return GCS_ERR_PERMISSION_DENIED
    if (
        code == CODE_RESOURCE_EXHAUSTED
        or code == CODE_UNAVAILABLE
        or code == CODE_ABORTED
    ):
        # ABORTED: a concurrency conflict, retried by the caller (AIP-194).
        return GCS_ERR_THROTTLED
    if (
        code == CODE_UNKNOWN
        or code == CODE_CANCELLED
        or code == CODE_DEADLINE_EXCEEDED
        or code == CODE_INTERNAL
        or code == CODE_DATA_LOSS
    ):
        return GCS_ERR_TRANSPORT
    return GCS_ERR_MALFORMED


def _kind_token(kind: UInt8) -> String:
    if kind == GCS_ERR_PRECONDITION:
        return String("PRECONDITION")
    if kind == GCS_ERR_NOT_FOUND:
        return String("NOT_FOUND")
    if kind == GCS_ERR_PERMISSION_DENIED:
        return String("PERMISSION_DENIED")
    if kind == GCS_ERR_THROTTLED:
        return String("THROTTLED")
    if kind == GCS_ERR_TRANSPORT:
        return String("TRANSPORT")
    return String("MALFORMED")


def _kind_http(kind: UInt8) -> Int:
    if kind == GCS_ERR_PRECONDITION:
        return 412
    if kind == GCS_ERR_NOT_FOUND:
        return 404
    if kind == GCS_ERR_PERMISSION_DENIED:
        return 403
    if kind == GCS_ERR_THROTTLED:
        return 429
    if kind == GCS_ERR_TRANSPORT:
        return 500
    return 400


def gcs_store_error_from_code(
    method: String, bucket: String, key: String, code: Int
) -> Error:
    """`StoreError[<KIND>] <method> gs://<bucket>/<key> status=<http>
    grpc_code=<code> (<NAME>)` for a call that ended in `google.rpc.Code`
    `code`."""
    var kind = gcs_error_kind_from_code(code)
    return Error(
        String("StoreError[")
        + _kind_token(kind)
        + "] "
        + method
        + " gs://"
        + bucket
        + "/"
        + key
        + " status="
        + String(_kind_http(kind))
        + " grpc_code="
        + String(code)
        + " ("
        + code_name(code)
        + ")"
    )


comptime _ERROR_CLASS_MAX_BYTES = 64


def _error_class(text: String) -> String:
    """The text before the first `:` of `text` when it is a short identifier
    (letters, digits, `_`, `.`, `[`, `]`, `-`), else empty. What follows is
    never kept: it may hold a token endpoint's answer."""
    var b = text.as_bytes()
    var i = 0
    while i < len(b) and i < _ERROR_CLASS_MAX_BYTES:
        var c = b[i]
        if c == UInt8(ord(":")):
            break
        var ok = (
            (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
            or (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
            or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
            or c == UInt8(ord("_"))
            or c == UInt8(ord("."))
            or c == UInt8(ord("["))
            or c == UInt8(ord("]"))
            or c == UInt8(ord("-"))
        )
        if not ok:
            return String("")
        i += 1
    if i == 0 or i >= len(b) or b[i] != UInt8(ord(":")):
        return String("")
    var out = String()
    for k in range(i):
        out += chr(Int(b[k]))
    return out^


def gcs_store_error_from_raised(
    method: String, bucket: String, key: String, text: String
) -> Error:
    """The StoreError for an Error the generated client raised on a call to
    `method`. A gRPC status (read back with komira_gcp_core's
    `gcp_grpc_error_code`) maps through `gcs_store_error_from_code`; an error
    with no status (raised before any status arrived, or by the token source)
    is `StoreError[TRANSPORT] ... status=500 detail=<class>, error text <n>
    bytes`: the class when the text starts with one, and the length of the
    whole text, never the rest of its bytes."""
    var code = gcp_grpc_error_code(String(_SVC) + method, text)
    if code >= 0:
        return gcs_store_error_from_code(method, bucket, key, code)
    var cls = _error_class(text)
    var detail = String("")
    if cls.byte_length() > 0:
        detail = cls + ", "
    return Error(
        String("StoreError[TRANSPORT] ")
        + method
        + " gs://"
        + bucket
        + "/"
        + key
        + " status=500 detail="
        + detail
        + "error text "
        + String(text.byte_length())
        + " bytes"
    )


def _read_fault(bucket: String, key: String, why: String) -> Error:
    """A ReadObject whose stream did not deliver what it stated."""
    return Error(
        String("StoreError[TRANSPORT] ReadObject gs://")
        + bucket
        + "/"
        + key
        + " status=500 detail="
        + why
    )


def _refused(method: String, bucket: String, key: String, why: String) -> Error:
    """A call refused before anything was sent."""
    return Error(
        String("StoreError[MALFORMED] ")
        + method
        + " gs://"
        + bucket
        + "/"
        + key
        + " status=400 detail="
        + why
    )


# =============================================================================
# §3 — Zero-valued messages.
# =============================================================================


def _zero[M: Serializable & Movable]() raises -> M:
    """`M` with every field at its proto3 default, decoded from no bytes, so
    a verb sets only the fields it means and a field added upstream cannot
    break a constructor call here."""
    var dec = PbDecoder(List[UInt8]())
    return M.decode(dec)


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


def _expected_read_len(
    bucket: String,
    key: String,
    first: ReadObjectResponse,
    read_offset: Int64,
    read_limit: Int64,
) raises -> Int:
    """The bytes a ReadObject stream states it carries, from its first
    response: `content_range.end - content_range.start` (whose start must be
    the offset asked for), else what the object's `metadata.size` leaves
    after the offset, up to `read_limit`. A first response that states
    neither cannot be checked for truncation, so it raises."""
    if first.content_range:
        ref r = first.content_range.value()
        if r.start != read_offset or r.end < r.start:
            raise _read_fault(
                bucket,
                key,
                String("the stream states the range [")
                + String(r.start)
                + ", "
                + String(r.end)
                + ") for offset "
                + String(read_offset),
            )
        return Int(r.end - r.start)
    if first.metadata:
        var avail = first.metadata.value().size - read_offset
        if avail < Int64(0):
            avail = Int64(0)
        if read_limit > Int64(0) and read_limit < avail:
            return Int(read_limit)
        return Int(avail)
    raise _read_fault(
        bucket,
        key,
        String(
            "the first response states neither the range nor the object, so"
            " the read cannot be checked for truncation"
        ),
    )


# =============================================================================
# §4 — StorageGrpcBackend.
# =============================================================================


struct StorageGrpcBackend[C: Connector, T: GcpTokenSource, K: MonotonicClock](
    GcsStorageBackend, Movable, Deinitable
):
    """The google.storage.v2 `GcsStorageBackend`: the seam's object verbs over
    the generated `StorageClient[C, T]`.

    `C` is the connector (`GcsTlsConnector` in production), `T` where each
    call's bearer token comes from, `K` the monotonic clock the per-call
    deadline is read from (komira_retry's `SystemClock` in production).

    One backend per worker: it owns its HTTP pool, reactor and clock, and is
    not shared between threads.
    """

    var _stub: StorageClient[Self.C, Self.T]
    var _reactor: Reactor[NoopSink]
    var _clock: Self.K
    var _call_deadline_us: Int
    var _cancel: CancellationToken

    def __init__(
        out self,
        var connector: Self.C,
        var token_source: Self.T,
        var clock: Self.K,
        config: HttpClientConfig,
        host: String = String(GCS_GRPC_HOST),
        port: UInt16 = GCS_GRPC_PORT,
        call_deadline_ms: Int = GCS_DEFAULT_CALL_DEADLINE_MS,
    ) raises:
        """A backend calling `https://<host>:<port>` over `connector`.

        `config` is the transport's: its `request_timeout_us` is the bound on
        any one request whose peer stops answering, so a caller running
        inside a budget sets it (`HttpClientConfig.defaults()` has the
        generous default; a serving process derives it with
        `HttpClientConfig.for_serving_ceiling`). `call_deadline_ms` is the
        deadline each call states to the peer; it must be positive."""
        if call_deadline_ms <= 0:
            raise Error(
                String("StorageGrpcBackend: call_deadline_ms must be > 0, got ")
                + String(call_deadline_ms)
            )
        var http = HttpClient[Self.C](config=config, connector=connector^)
        var grpc = GrpcClient[Self.C](http^, Url.https(host, port, String("/")))
        self._stub = StorageClient[Self.C, Self.T](grpc^, token_source^)
        self._reactor = _make_reactor()
        self._clock = clock^
        self._call_deadline_us = call_deadline_ms * 1000
        self._cancel = CancellationToken.new()

    # ---- Accessors ----

    def token_source(mut self) -> ref [self._stub._token_source] Self.T:
        """The token source, for example to drop a cached token after a
        PERMISSION_DENIED that was an UNAUTHENTICATED."""
        return self._stub.token_source()

    def clock(mut self) -> ref [self._clock] Self.K:
        """The clock the per-call deadline is read from."""
        return self._clock

    def request_timeout_us(self) -> Int:
        """The per-request bound the transport actually carries, read back
        from the HttpClient inside the generated client rather than from a
        copy, so it can only report what the drive loop will honour."""
        return self._stub._client._http[].config().request_timeout_us

    def cancel(mut self, reason: String):
        """Trip this backend's cancellation token. A call in flight stops at
        its next cancellation check, and every later call starts cancelled
        and raises `StoreError[TRANSPORT]`."""
        self._cancel.cancel(reason)

    # ---- Per call ----

    def _opts(self, now_us: Int) -> CallOptions:
        """The call's options: a deadline `call_deadline_ms` after `now_us`,
        the same reading the call is then given, so the `grpc-timeout` it
        states is exactly that deadline."""
        var opts = CallOptions()
        opts.with_relative_deadline_us(now_us, self._call_deadline_us)
        return opts^

    @always_inline
    def _now_us(mut self) -> Int:
        return Int(self._clock.now_ms()) * 1000

    # ---- GcsStorageBackend ----

    def conditional_create(
        mut self, bucket: String, key: String, data: List[UInt8]
    ) raises -> Int64:
        """WriteObject with `if_generation_match = 0`."""
        return self._write_object(bucket, key, data, Int64(0))

    def compare_and_swap(
        mut self,
        bucket: String,
        key: String,
        data: List[UInt8],
        expected_generation: Int64,
    ) raises -> Int64:
        """WriteObject with `if_generation_match = expected_generation`. A
        generation below 1 is refused before anything is sent: 0 on the wire
        means "create only if absent" and would turn the swap into a create."""
        if expected_generation < Int64(1):
            raise _refused(
                String("WriteObject"),
                bucket,
                key,
                String("compare-and-swap needs a generation >= 1, got ")
                + String(expected_generation),
            )
        return self._write_object(bucket, key, data, expected_generation)

    def _write_object(
        mut self,
        bucket: String,
        key: String,
        data: List[UInt8],
        if_generation_match: Int64,
    ) raises -> Int64:
        """One WriteObject call: ceil(len / WRITE_OBJECT_CHUNK_BYTES)
        messages (one when `data` is empty). Message 0 carries the spec; each
        carries its `write_offset` and its chunk's CRC-32C; only the last
        sets `finish_write` and the whole object's CRC-32C."""
        var encoder = ClientStreamEncoder[ProtocolGrpcProto].new()
        var total = len(data)
        var offset = 0
        var whole_crc = UInt32(0)
        while True:
            var end = offset + WRITE_OBJECT_CHUNK_BYTES
            if end > total:
                end = total
            var is_last = end >= total
            var chunk = List[UInt8](capacity=end - offset)
            for i in range(offset, end):
                chunk.append(data[i])
            var chunk_crc = crc32c(Span(chunk))
            whole_crc = crc32c_extend(whole_crc, Span(chunk))
            var req = _zero[WriteObjectRequest]()
            req.write_offset = Int64(offset)
            req.finish_write = is_last
            if offset == 0:
                var resource = _zero[Object]()
                resource.name = key
                resource.bucket = gcs_bucket_resource_name(bucket)
                var spec = _zero[WriteObjectSpec]()
                spec.resource = Optional[Object](resource^)
                spec.if_generation_match = Optional[Int64](if_generation_match)
                req._oneof0_case = 2  # first_message = write_object_spec
                req.write_object_spec = Optional[WriteObjectSpec](spec^)
            req._oneof1_case = 1  # data = checksummed_data
            req.checksummed_data = Optional[ChecksummedData](
                ChecksummedData(content=chunk^, crc32c=Optional[UInt32](chunk_crc))
            )
            if is_last:
                var sums = _zero[ObjectChecksums]()
                sums.crc32c = Optional[UInt32](whole_crc)
                req.object_checksums = Optional[ObjectChecksums](sums^)
            var enc = PbEncoder()
            req.encode(enc)
            encoder.encode_message(Span(enc.into_buf()))
            offset = end
            if is_last:
                break
        encoder.mark_close()

        var now = self._now_us()
        var opts = self._opts(now)
        # No routing annotation upstream: the header is set here.
        opts.raw_metadata.set(
            String("x-goog-request-params"), gcs_routing_param(bucket)
        )
        var token = self._cancel.child()
        var resp: WriteObjectResponse
        try:
            resp = self._stub.write_object[_RT](
                encoder^, opts^, now, self._reactor, token
            )
        except e:
            raise gcs_store_error_from_raised(
                String("WriteObject"), bucket, key, String(e)
            )
        # A finished write answers with the object (write_status arm 2); its
        # generation is the CAS handle.
        if resp._oneof0_case == 2 and resp.resource:
            return resp.resource.value().generation
        raise Error(
            String("StoreError[TRANSPORT] WriteObject gs://")
            + bucket
            + "/"
            + key
            + " status=500 detail=the finished write answered without the"
            " object resource, so no generation"
        )

    def read_range(
        mut self,
        bucket: String,
        key: String,
        read_offset: Int64,
        read_limit: Int64,
    ) raises -> List[UInt8]:
        """ReadObject of `[read_offset, read_offset + read_limit)`
        (`read_limit = 0`: to the end), every response's data concatenated.
        A negative offset or limit is refused before anything is sent: the
        wire reads a negative offset as a suffix.

        The result is checked before it is returned: its length against the
        first response's `content_range` (or, without one, the object's size
        in its `metadata`), each chunk against its CRC-32C, and a read of the
        whole object against the object's CRC-32C. A stream that ends short
        (a cut-off message, a missing status) or corrupt raises TRANSPORT.

        Memory: komira_grpc loads the whole response stream before the
        generated method returns, so a read holds about twice its size at
        its peak (the drained stream and the result)."""
        if read_offset < Int64(0) or read_limit < Int64(0):
            raise _refused(
                String("ReadObject"),
                bucket,
                key,
                String("negative read_offset (")
                + String(read_offset)
                + ") or read_limit ("
                + String(read_limit)
                + ")",
            )
        var req = _zero[ReadObjectRequest]()
        req.bucket = gcs_bucket_resource_name(bucket)
        req.object = key
        req.read_offset = read_offset
        req.read_limit = read_limit
        var now = self._now_us()
        var opts = self._opts(now)
        var token = self._cancel.child()
        var decoder: ServerStreamDecoder[ProtocolGrpcProto]
        try:
            decoder = self._stub.read_object[_RT](
                req, opts^, now, self._reactor, token
            )
        except e:
            raise gcs_store_error_from_raised(
                String("ReadObject"), bucket, key, String(e)
            )

        var out = List[UInt8]()
        var responses = 0
        var expected = -1
        var whole_crc = Optional[UInt32]()
        while True:
            var outcome = decoder.try_next_message()
            if outcome.kind == STREAM_OUTCOME_MESSAGE:
                var bytes = List[UInt8]()
                swap(bytes, outcome.message_bytes)
                var dec = PbDecoder(bytes^)
                var resp = ReadObjectResponse.decode(dec)
                responses += 1
                if responses == 1:
                    expected = _expected_read_len(
                        bucket, key, resp, read_offset, read_limit
                    )
                    if resp.object_checksums:
                        whole_crc = resp.object_checksums.value().crc32c.copy()
                if resp.checksummed_data:
                    ref cd = resp.checksummed_data.value()
                    if cd.crc32c and cd.crc32c.value() != crc32c(Span(cd.content)):
                        raise _read_fault(
                            bucket,
                            key,
                            String("response ")
                            + String(responses)
                            + " does not match its CRC-32C",
                        )
                    for i in range(len(cd.content)):
                        out.append(cd.content[i])
            elif (
                outcome.kind == STREAM_OUTCOME_END_OK
                or outcome.kind == STREAM_OUTCOME_PENDING
            ):
                # The stream is loaded whole before the generated method
                # returns, and a non-OK status in it has already been
                # raised; PENDING is its end. Bytes of a cut-off message stay
                # in the decoder, so the length check below is what catches
                # one.
                break
            else:
                # The decoder ended the stream itself: an envelope it cannot
                # read (a compressed message, a flags byte gRPC does not
                # define). Its code is komira_grpc's, not the server's.
                raise gcs_store_error_from_code(
                    String("ReadObject"),
                    bucket,
                    key,
                    code_from_grpc_status(Int(outcome.error.code)),
                )
        if responses == 0:
            raise _read_fault(
                bucket, key, String("the stream ended without a response")
            )
        if len(out) != expected:
            raise _read_fault(
                bucket,
                key,
                String("short read: ")
                + String(len(out))
                + " of "
                + String(expected)
                + " stated bytes",
            )
        if read_offset == Int64(0) and read_limit == Int64(0) and whole_crc:
            if whole_crc.value() != crc32c(Span(out)):
                raise _read_fault(
                    bucket, key, String("the object does not match its CRC-32C")
                )
        return out^

    def get_object(mut self, bucket: String, key: String) raises -> ObjectMetaRaw:
        """GetObject: the object's name, size, generation and etag."""
        var req = _zero[GetObjectRequest]()
        req.bucket = gcs_bucket_resource_name(bucket)
        req.object = key
        var now = self._now_us()
        var opts = self._opts(now)
        var token = self._cancel.child()
        var obj: Object
        try:
            obj = self._stub.get_object[_RT](
                req, opts^, now, self._reactor, token
            )
        except e:
            raise gcs_store_error_from_raised(
                String("GetObject"), bucket, key, String(e)
            )
        return ObjectMetaRaw(
            key=obj.name, size=obj.size, generation=obj.generation, etag=obj.etag
        )

    def delete_object(mut self, bucket: String, key: String) raises:
        """DeleteObject (the live generation, no precondition). An absent
        object raises NOT_FOUND."""
        var req = _zero[DeleteObjectRequest]()
        req.bucket = gcs_bucket_resource_name(bucket)
        req.object = key
        var now = self._now_us()
        var opts = self._opts(now)
        var token = self._cancel.child()
        try:
            _ = self._stub.delete_object[_RT](
                req, opts^, now, self._reactor, token
            )
        except e:
            raise gcs_store_error_from_raised(
                String("DeleteObject"), bucket, key, String(e)
            )

    def list_objects(
        mut self,
        bucket: String,
        prefix: String,
        page_token: String,
        delimiter: String = String(""),
    ) raises -> ListPageRaw:
        """ListObjects, one page: `delimiter = "/"` folds deeper names into
        `common_prefixes` (the service's `prefixes`)."""
        var req = _zero[ListObjectsRequest]()
        req.parent = gcs_bucket_resource_name(bucket)
        req.prefix = prefix
        req.page_token = page_token
        req.delimiter = delimiter
        var now = self._now_us()
        var opts = self._opts(now)
        var token = self._cancel.child()
        var resp: ListObjectsResponse
        try:
            resp = self._stub.list_objects[_RT](
                req, opts^, now, self._reactor, token
            )
        except e:
            raise gcs_store_error_from_raised(
                String("ListObjects"), bucket, prefix, String(e)
            )
        var objects = List[ObjectMetaRaw]()
        for i in range(len(resp.objects)):
            ref o = resp.objects[i]
            objects.append(
                ObjectMetaRaw(
                    key=o.name, size=o.size, generation=o.generation, etag=o.etag
                )
            )
        var common = List[String]()
        for i in range(len(resp.prefixes)):
            common.append(resp.prefixes[i].copy())
        return ListPageRaw(objects^, common^, resp.next_page_token.copy())
