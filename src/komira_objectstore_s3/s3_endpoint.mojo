# =============================================================================
# komira_objectstore_s3/s3_endpoint.mojo -- the connector an S3Fs dials:
# plaintext or TLS, as the endpoint's scheme says
# =============================================================================
#
# komira_http_client sends an `https` URL only over a connector whose
# `is_tls()` is True and an `http` URL only over one whose `is_tls()` is
# False. Which one an S3Fs dials is decided by its endpoint, once, when the
# file system is made: `s3_endpoint_is_plaintext` reads the scheme of
# `S3Config.endpoint` ("" is AWS's own endpoint, https), and
# `s3_connector_factory` hands back the plaintext factory only for an
# `http://` endpoint (a local MinIO or an emulator). An `https://` endpoint,
# or AWS's, gets the TLS factory, and any other scheme is refused, so a
# plaintext connection is made only when the endpoint itself says `http`.
#
# `s3_prod_fs` builds the production S3Fs that way, over komira_http_client's
# `KernelSchemeConnector` (a kernel TCP dial, plaintext or under TLS) with the
# process's wall clock for signing. An S3Fs built directly over a factory
# dials what that factory makes: a TLS connector refuses an http:// endpoint
# on the first request (`HttpError[URL_INVALID]`).
#
# Nothing here reads the environment: the endpoint is the caller's
# `S3Config` and the credential source the caller's value.
# =============================================================================

from komira_aws_core import AwsCredsSource, SystemAwsClock
from komira_http_client.client import HttpClientConfig
from komira_http_client.scheme_connector import (
    KernelSchemeConnector,
    kernel_plain_scheme_connector,
    kernel_tls_scheme_connector,
)
from komira_http_core.transport.io_stream import Connector

from .config import S3Config
from .s3_fs import S3Fs
from .s3_fs_options import S3FsOptions


def _ascii_prefix_is(s: String, lower_prefix: StringLiteral) -> Bool:
    """Whether `s` starts with `lower_prefix` (lowercase ASCII), comparing
    ASCII letters case-insensitively."""
    var a = s.as_bytes()
    var b = lower_prefix.as_bytes()
    if len(a) < len(b):
        return False
    for i in range(len(b)):
        var c = Int(a[i])
        if c >= ord("A") and c <= ord("Z"):
            c += 32
        if c != Int(b[i]):
            return False
    return True


def s3_endpoint_is_plaintext(endpoint: String) raises -> Bool:
    """True for an `http://` endpoint, False for an `https://` one or for
    "" (AWS's own endpoint, which is https). The scheme is compared ASCII
    case-insensitively (RFC 3986 section 3.1), so `HTTP://` is plaintext and
    `HTTPS://` is TLS. Raises `s3_endpoint: an S3 endpoint must start with
    http:// or https://, got '<endpoint>'` for anything else."""
    if endpoint.byte_length() == 0 or _ascii_prefix_is(endpoint, "https://"):
        return False
    if _ascii_prefix_is(endpoint, "http://"):
        return True
    raise Error(
        "s3_endpoint: an S3 endpoint must start with http:// or https://, got '"
        + endpoint
        + "'"
    )


def s3_connector_factory[
    C: Connector
](
    endpoint: String,
    mk_plain: def () raises thin -> C,
    mk_tls: def () raises thin -> C,
) raises -> def () raises thin -> C:
    """`mk_plain` for an `http://` endpoint, else `mk_tls`; refuses any other
    scheme (`s3_endpoint_is_plaintext`)."""
    if s3_endpoint_is_plaintext(endpoint):
        return mk_plain
    return mk_tls


def s3_prod_fs[
    T: AwsCredsSource & Copyable
](
    var bucket: String,
    var config: S3Config,
    http_config: HttpClientConfig,
    var creds: T,
    options: S3FsOptions = S3FsOptions.standard(),
) raises -> S3Fs[KernelSchemeConnector, T, SystemAwsClock]:
    """The production S3Fs on `bucket`, dialing plaintext when
    `config.endpoint` is `http://` and TLS otherwise (module header).
    Dials nothing here."""
    var mk = s3_connector_factory[KernelSchemeConnector](
        config.endpoint, kernel_plain_scheme_connector, kernel_tls_scheme_connector
    )
    return S3Fs[KernelSchemeConnector, T, SystemAwsClock](
        bucket^, config^, mk, http_config, creds^, SystemAwsClock(), options
    )
