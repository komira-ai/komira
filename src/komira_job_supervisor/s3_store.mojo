# =============================================================================
# komira_job_supervisor/s3_store.mojo: S3 (or S3-compatible) object stores for
# the supervisor, from flags.
# =============================================================================
#
# The supervisor takes its binary store and log store as any komira_objectstore
# `ConditionalWriteStore`. This file is the ready-made S3 choice: an
# `S3ConditionalStore` (komira_objectstore_s3) per bucket, signed with the AWS
# default credential chain (environment, shared profile, web identity,
# container endpoint, instance metadata), resolved when the store is built so
# a supervisor with no credential is refused before it spawns anything.
#
#   --s3-binary-bucket=NAME  the bucket --binary-key is read from
#   --s3-log-bucket=NAME     the bucket logs and crash reports are written to
#   --s3-endpoint=URL        an S3-compatible endpoint (path-style addressing);
#                            ABSENT means AWS's own regional endpoint, which is
#                            HTTPS-only, so absence selects TLS. A given
#                            endpoint's scheme selects the transport.
#   --s3-region=REGION       the signing region (default us-east-1)
#
# `run_job_supervisor_on_s3` builds the stores the flags name over the
# transport the endpoint selects and runs `run_job_supervisor`.
#
# The credential chain's own inputs (AWS_ACCESS_KEY_ID and the rest) stay on
# the environment and the filesystem, where the AWS SDKs put them: they are
# secret material, and argv is readable by every user on the host.
#
# No pointer type crosses a boundary; the shared credential cache is an
# ArcPointer field, because every clone of a store must sign with the one
# cached credential.
# =============================================================================

from std.memory import ArcPointer

from komira_aws_core.aws_send import AwsConnectorTransport
from komira_aws_core.credential import AwsCredential
from komira_aws_core.credential_chain import AwsCredentialParams
from komira_aws_core.credential_transport import (
    CredentialHttpRequest,
    CredentialHttpResponse,
    CredentialTransport,
)
from komira_aws_core.creds_source import AwsCredsSource, DefaultChainCredsSource
from komira_aws_core.sources import ProcessEnv, ProcessFiles, SystemAwsClock
from komira_http_client.client import HttpClientConfig
from komira_http_client.tls_connector import (
    TlsConnector,
    build_unpinned_public_ca_tls_connector,
)
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_objectstore_s3.conditional_store import S3ConditionalStore
from komira_objectstore_s3.config import S3Config

from komira_job_supervisor.job_supervisor import run_job_supervisor
from komira_job_supervisor.job_supervisor_config import (
    JobSupervisorConfig,
    scan_flags,
)
from komira_job_supervisor.job_supervisor_state import JobSupervisorPhase
from komira_job_supervisor.heartbeat_client import HeartbeatReporter


comptime FLAG_S3_BINARY_BUCKET: StaticString = "--s3-binary-bucket"
comptime FLAG_S3_LOG_BUCKET: StaticString = "--s3-log-bucket"
comptime FLAG_S3_ENDPOINT: StaticString = "--s3-endpoint"
comptime FLAG_S3_REGION: StaticString = "--s3-region"


def s3_store_flag_names() -> List[String]:
    """Every flag `S3StoreFlags.from_args` reads."""
    var out = List[String]()
    out.append(String(FLAG_S3_BINARY_BUCKET))
    out.append(String(FLAG_S3_LOG_BUCKET))
    out.append(String(FLAG_S3_ENDPOINT))
    out.append(String(FLAG_S3_REGION))
    return out^


# =============================================================================
# §1: the credential chain.
# =============================================================================
struct S3CredentialTransport(CredentialTransport, Movable, Deinitable):
    """Sends one credential-provider request (STS, the container endpoint,
    instance metadata): `http` in the clear (those endpoints are link-local
    or loopback), `https` over TLS verified against the system public-CA
    trust store, any other scheme refused."""

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
            "job supervisor credentials: a provider asked for scheme "
            + req.scheme
            + ", not http or https"
        )


comptime ChainCredsSource = DefaultChainCredsSource[
    ProcessEnv, ProcessFiles, S3CredentialTransport, SystemAwsClock
]


struct SharedChainCreds(AwsCredsSource, Copyable, Movable, Deinitable):
    """The AWS default chain behind a shared handle: every copy (every clone
    of a store) signs with the one cached, refreshed credential."""

    var _chain: ArcPointer[ChainCredsSource]

    def __init__(out self, var chain: ChainCredsSource):
        self._chain = ArcPointer[ChainCredsSource](chain^)

    def credentials(mut self) raises -> AwsCredential:
        return self._chain[].credentials()


def shared_chain_creds(region: String) raises -> SharedChainCreds:
    """The default chain for `region`, resolved once now: raises when no
    credential can be found (the message names the setting, never a
    secret)."""
    var params = AwsCredentialParams()
    params.region = region
    var chain = ChainCredsSource(
        params,
        ProcessEnv(),
        ProcessFiles(),
        S3CredentialTransport(),
        SystemAwsClock(),
    )
    _ = chain.credentials()
    return SharedChainCreds(chain^)


# =============================================================================
# §2: the stores.
# =============================================================================
comptime SupervisorS3Store[C: Connector] = S3ConditionalStore[
    C, SharedChainCreds, SystemAwsClock
]
"""A supervisor object store: one S3 bucket over transport `C`."""


def s3_plain_connector() raises -> KernelTcpConnector:
    return KernelTcpConnector.new()


def s3_tls_connector() raises -> TlsConnector[KernelTcpConnector]:
    """The unpinned public-CA TLS connector, verification on. Unpinned
    because AWS addresses a bucket in the HOST name: a connector pinned to
    one server name could reach one bucket. There is no verify-skipping
    variant: this transport carries the binary the supervisor executes."""
    return build_unpinned_public_ca_tls_connector()


def make_s3_store[
    C: Connector,
](
    mk_connector: def () raises thin -> C,
    bucket: String,
    region: String,
    endpoint: Optional[String],
) raises -> SupervisorS3Store[C]:
    """A store on `bucket`: AWS's regional endpoint when `endpoint` is None,
    else that S3-compatible endpoint. Built now, so a bad endpoint or a
    missing credential raises here."""
    var config: S3Config
    if endpoint:
        config = S3Config.custom_endpoint(region, endpoint.value())
    else:
        config = S3Config.aws(region)
    return SupervisorS3Store[C].built(
        String(bucket),
        config^,
        mk_connector,
        HttpClientConfig.defaults(),
        shared_chain_creds(region),
        SystemAwsClock(),
    )


# =============================================================================
# §3: the flags, and the run.
# =============================================================================
struct S3StoreFlags(Movable):
    """The S3 store flags (module header)."""

    var binary_bucket: Optional[String]
    var log_bucket: Optional[String]
    var endpoint: Optional[String]
    var region: String

    def __init__(
        out self,
        var binary_bucket: Optional[String],
        var log_bucket: Optional[String],
        var endpoint: Optional[String],
        var region: String,
    ):
        self.binary_bucket = binary_bucket^
        self.log_bucket = log_bucket^
        self.endpoint = endpoint^
        self.region = region^

    @staticmethod
    def from_args(
        args: List[String], other_flags: List[String] = List[String]()
    ) raises -> S3StoreFlags:
        """Parse the S3 store flags out of `args` (without the program
        name); `other_flags` (e.g. `job_supervisor_flag_names()`) are
        skipped rather than refused. A flag given empty is refused."""
        var known = s3_store_flag_names()
        for i in range(len(other_flags)):
            known.append(other_flags[i])
        var f = scan_flags(args, known)
        var names = s3_store_flag_names()
        for i in range(len(names)):
            var v = f.get(names[i])
            if v and v.value().byte_length() == 0:
                raise Error(String("job supervisor: ") + names[i] + " is empty")
        var region = f.get(String(FLAG_S3_REGION))
        return S3StoreFlags(
            f.get(String(FLAG_S3_BINARY_BUCKET)),
            f.get(String(FLAG_S3_LOG_BUCKET)),
            f.get(String(FLAG_S3_ENDPOINT)),
            region.value() if region else String("us-east-1"),
        )

    def uses_tls(self) -> Bool:
        """True iff the stores must dial TLS: no endpoint (AWS itself, HTTPS
        only) or an https:// endpoint."""
        if not self.endpoint:
            return True
        return self.endpoint.value().lower().startswith(String("https://"))


def _store_or_none[
    C: Connector,
](
    mk_connector: def () raises thin -> C,
    bucket: Optional[String],
    s3: S3StoreFlags,
) raises -> Optional[SupervisorS3Store[C]]:
    if not bucket:
        return None
    return Optional[SupervisorS3Store[C]](
        make_s3_store[C](mk_connector, bucket.value(), s3.region, s3.endpoint)
    )


def run_job_supervisor_on_s3[
    R: HeartbeatReporter,
](
    var config: JobSupervisorConfig, var reporter: R, s3: S3StoreFlags
) raises -> JobSupervisorPhase:
    """`run_job_supervisor` with the S3 stores `s3` names, over the transport
    its endpoint selects (the branch monomorphises the whole run, so no path
    can mix the two)."""
    if s3.uses_tls():
        comptime T = TlsConnector[KernelTcpConnector]
        return run_job_supervisor[R, SupervisorS3Store[T]](
            config^,
            reporter^,
            _store_or_none[T](s3_tls_connector, s3.binary_bucket, s3),
            _store_or_none[T](s3_tls_connector, s3.log_bucket, s3),
        )
    comptime P = KernelTcpConnector
    return run_job_supervisor[R, SupervisorS3Store[P]](
        config^,
        reporter^,
        _store_or_none[P](s3_plain_connector, s3.binary_bucket, s3),
        _store_or_none[P](s3_plain_connector, s3.log_bucket, s3),
    )
