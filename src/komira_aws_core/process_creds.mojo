# =============================================================================
# komira_aws_core/process_creds.mojo -- the default credential source of a
# process: the AWS SDK chain, refreshing, shared by every clone
# =============================================================================
#
# `ProcessCredsSource` is the ONE type that fixes everything but the
# parameters: the standard AWS SDK chain (`DefaultChainCredsSource`) over the
# process's environment and files (`ProcessEnv`, `ProcessFiles`), its HTTP
# transport (`ProcessCredentialTransport`: plain TCP for the instance-metadata
# and container endpoints, TLS for STS) and the system clock, behind a
# `SharedCredsSource`. A caller that needs one concrete type for every value
# (the production S3Fs a surface builds with komira_objectstore_s3's
# `s3_prod_fs`) names it; a type generic over `AwsCredsSource` takes it as
# the default.
#
# FIXED KEYS. A credential stated in `params.credential` wins over every
# provider and carries no expiry, so `process_creds_source` with such params
# is a source that never refreshes, of the same type. `StaticCredsSource`
# stays available for a caller that wants no chain at all.
#
# No environment variable of komira's own is read: the chain reads only the
# standard AWS SDK ones, through the EnvSource seam (credential_chain.mojo).
# =============================================================================

from komira_http_client.client import HttpClientConfig
from komira_http_client.tls_connector import (
    TlsConnector,
    build_unpinned_public_ca_tls_connector,
)
from komira_http_core.transport.kernel_tcp import KernelTcpConnector

from .aws_send import AwsConnectorTransport
from .credential_chain import AwsCredentialParams
from .creds_source import DefaultChainCredsSource
from .http_credential_transport import SchemeSplitCredentialTransport
from .shared_creds import SharedCredsSource
from .sources import ProcessEnv, ProcessFiles, SystemAwsClock


comptime ProcessCredentialTransport = SchemeSplitCredentialTransport[
    AwsConnectorTransport[KernelTcpConnector],
    AwsConnectorTransport[TlsConnector[KernelTcpConnector]],
]

comptime ProcessChainCredsSource = DefaultChainCredsSource[
    ProcessEnv, ProcessFiles, ProcessCredentialTransport, SystemAwsClock
]

comptime ProcessCredsSource = SharedCredsSource[ProcessChainCredsSource]


def process_credential_transport(
    config: HttpClientConfig,
) raises -> ProcessCredentialTransport:
    """The credential providers' transport: `config` bounds each request
    (a short `request_timeout_us` keeps a host that is not on EC2 from
    holding the chain at the instance-metadata endpoint)."""
    return ProcessCredentialTransport(
        AwsConnectorTransport[KernelTcpConnector](
            config, KernelTcpConnector.new()
        ),
        AwsConnectorTransport[TlsConnector[KernelTcpConnector]](
            config, build_unpinned_public_ca_tls_connector()
        ),
    )


def process_creds_source(
    params: AwsCredentialParams, http: HttpClientConfig
) raises -> ProcessCredsSource:
    """The default chain for `params` over the process's environment, files
    and network (`http` bounds each credential request), shared by every
    clone of the result."""
    return ProcessCredsSource(
        ProcessChainCredsSource(
            params,
            ProcessEnv(),
            ProcessFiles(),
            process_credential_transport(http),
            SystemAwsClock(),
        )
    )
