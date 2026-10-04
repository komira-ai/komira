# =============================================================================
# komira_agent/s3_client.mojo: the agent's S3 client.
# =============================================================================
#
# The three things the agent does with S3 (GET the job binary, PUT each
# streamed log chunk, PUT the terminal logs.txt / crash_report.json) go through
# `AgentS3Client[C]`, a thin owner of komira_objectstore_s3's `S3Store` over the
# transport `C`. `C` is the S3 transport and nothing else: `KernelTcpConnector`
# for MinIO/LocalStack over plaintext, `TlsConnector[KernelTcpConnector]` for
# real S3 or an `https://` endpoint (boot.mojo §4b picks it).
#
# CREDENTIALS: the AWS default chain (`DefaultChainCredsSource`: env ->
# shared profile -> web identity -> container -> instance metadata), resolved
# once at construction so a client with no credential is refused where it is
# built, then cached and refreshed before expiry by the source. Its HTTP
# requests (STS, the container endpoint, IMDS) go through
# `AgentCredentialTransport`: plaintext for an `http` request, TLS over the
# system public-CA trust store for an `https` one.
#
# CLOCK: `AgentAwsClock` signs with the live system clock, unless BOTH
# `MINIO_E2E_AMZ_DATE` and `MINIO_E2E_SHORT_DATE` are set, in which case it is
# stopped at the `MINIO_E2E_AMZ_DATE` instant (the deterministic-test override
# `amz_stamps_now` also honours).
#
# ENCAPSULATION: every request, response and credential stays inside this
# module and the libraries it calls; the public surface is `get_object` /
# `put_object` over owned bytes. No UnsafePointer, no wildcard origin.
# =============================================================================

from komira_aws_core.aws_send import AwsConnectorTransport
from komira_aws_core.credential import AwsCredential
from komira_aws_core.credential_chain import AwsCredentialParams
from komira_aws_core.credential_transport import (
    CredentialHttpRequest,
    CredentialHttpResponse,
    CredentialTransport,
)
from komira_aws_core.creds_source import DefaultChainCredsSource
from komira_aws_core.sources import (
    AwsClock,
    ProcessEnv,
    ProcessFiles,
    SystemAwsClock,
)
from komira_http_client.client import HttpClientConfig
from komira_http_client.tls_connector import (
    TlsConnector,
    build_unpinned_public_ca_tls_connector,
)
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_objectstore.types import WritePrecondition
from komira_objectstore_s3.config import S3Config
from komira_objectstore_s3.store import S3Store

from komira_agent.clock_helper import amz_override_unix_seconds


# =============================================================================
# §1: the credential chain's HTTP transport.
# =============================================================================
struct AgentCredentialTransport(CredentialTransport, Movable, Deinitable):
    """Sends one credential-provider request (STS, the container endpoint,
    instance metadata) on a fresh HTTP client. `http` requests go in the
    clear (the container endpoint and IMDS are link-local / loopback);
    `https` requests go over TLS with peer verification against the system
    public-CA trust store. Any other scheme is refused."""

    def __init__(out self):
        pass

    def send(
        mut self, req: CredentialHttpRequest
    ) raises -> CredentialHttpResponse:
        if req.scheme == "https":
            var tls = AwsConnectorTransport[TlsConnector[KernelTcpConnector]](
                build_unpinned_public_ca_tls_connector()
            )
            var res = tls.send(req)
            return CredentialHttpResponse.of_bytes(res.status, Span(res.body))
        if req.scheme == "http":
            var plain = AwsConnectorTransport[KernelTcpConnector](
                KernelTcpConnector.new()
            )
            var res = plain.send(req)
            return CredentialHttpResponse.of_bytes(res.status, Span(res.body))
        raise Error(
            "agent credentials: a provider asked for scheme "
            + req.scheme
            + ", not http or https"
        )


# =============================================================================
# §2: the signing clock.
# =============================================================================
struct AgentAwsClock(AwsClock, Copyable, Movable, Deinitable):
    """The SigV4 signing clock: the system wall clock, or a stopped clock
    when the `MINIO_E2E_*` override is set (see the module header)."""

    var fixed_unix_seconds: Optional[Int]

    def __init__(out self, fixed_unix_seconds: Optional[Int]):
        self.fixed_unix_seconds = fixed_unix_seconds

    @staticmethod
    def from_env() raises -> AgentAwsClock:
        return AgentAwsClock(amz_override_unix_seconds())

    def now_unix_seconds(mut self) -> Int:
        if self.fixed_unix_seconds:
            return self.fixed_unix_seconds.value()
        var system = SystemAwsClock()
        return system.now_unix_seconds()


comptime AgentCredsSource = DefaultChainCredsSource[
    ProcessEnv, ProcessFiles, AgentCredentialTransport, SystemAwsClock
]
"""The AWS default credential chain over the process environment, the local
filesystem and `AgentCredentialTransport`, expiring on the system clock."""


def agent_creds_source(region: String) raises -> AgentCredsSource:
    """The default chain for `region`, resolved once now: raises when no
    credential can be found (the message names the setting, never a
    secret)."""
    var params = AwsCredentialParams()
    params.region = region
    var source = AgentCredsSource(
        params,
        ProcessEnv(),
        ProcessFiles(),
        AgentCredentialTransport(),
        SystemAwsClock(),
    )
    _ = source.credentials()
    return source^


# =============================================================================
# §3: the client.
# =============================================================================
struct AgentS3Client[C: Connector](Movable):
    """The agent's S3 verbs over transport `C`: whole-object GET and an
    unconditional PUT. A None `endpoint` is AWS's own regional endpoint
    (virtual-hosted, https); a set one is an S3-compatible service addressed
    by path, with the scheme the endpoint string carries."""

    var _store: S3Store[Self.C, AgentCredsSource, AgentAwsClock]

    def __init__(
        out self,
        mk_connector: def () raises thin -> Self.C,
        region: String,
        endpoint: Optional[String],
    ) raises:
        var config: S3Config
        if endpoint:
            config = S3Config.custom_endpoint(region, endpoint.value())
        else:
            config = S3Config.aws(region)
        self._store = S3Store[Self.C, AgentCredsSource, AgentAwsClock](
            config^,
            mk_connector,
            HttpClientConfig.defaults(),
            agent_creds_source(region),
            AgentAwsClock.from_env(),
        )

    def endpoint(self) -> Optional[String]:
        """The custom endpoint this client was built with; None for AWS's
        own regional endpoint."""
        var ep = self._store.config().endpoint
        if ep.byte_length() == 0:
            return None
        return Optional[String](ep^)

    def get_object(mut self, bucket: String, key: String) raises -> List[UInt8]:
        """GetObject: the whole object's bytes. Raises on any failure."""
        return self._store.get(bucket, key)

    def put_object(
        mut self, bucket: String, key: String, var bytes: List[UInt8]
    ) raises:
        """PutObject of `bytes`, unconditionally (create or overwrite).
        Raises on any failure."""
        _ = self._store.conditional_put(
            bucket, key, bytes, WritePrecondition.none()
        )
