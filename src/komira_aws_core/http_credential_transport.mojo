# =============================================================================
# komira_aws_core/http_credential_transport.mojo -- the credential providers'
# transport over komira_http_client
# =============================================================================
#
# `CredentialTransport` (credential_transport.mojo) is the seam the STS,
# container and instance-metadata providers send through. This file is its
# production implementation: a request goes out over komira_http_client, on a
# connector chosen by the request's scheme. The instance-metadata and
# container endpoints are plain `http`, STS is `https`, and one connector does
# not serve both (a TLS connector refuses an `http` URL and a plain one an
# `https` URL), so `SchemeSplitCredentialTransport` holds one transport for
# each and picks per request.
#
# The tests drive it over scripted `AwsHttpTransport`s. The production pair is
# built by `process_credential_transport` (process_creds.mojo).
# =============================================================================

from .aws_send import AwsHttpTransport
from .credential_transport import (
    CredentialHttpRequest,
    CredentialHttpResponse,
    CredentialTransport,
)


struct SchemeSplitCredentialTransport[
    P: AwsHttpTransport,
    T: AwsHttpTransport,
](CredentialTransport, Movable, Deinitable):
    """`CredentialTransport` that sends an `http` request over `P` and an
    `https` request over `T`, and refuses any other scheme."""

    var _plain: Self.P
    var _tls: Self.T

    def __init__(out self, var plain: Self.P, var tls: Self.T):
        self._plain = plain^
        self._tls = tls^

    def send(
        mut self, req: CredentialHttpRequest
    ) raises -> CredentialHttpResponse:
        if req.scheme == "http":
            var res = self._plain.send(req)
            return CredentialHttpResponse.of_bytes(res.status, Span(res.body))
        if req.scheme == "https":
            var res = self._tls.send(req)
            return CredentialHttpResponse.of_bytes(res.status, Span(res.body))
        raise Error(
            "a credential request names a scheme that is neither http nor"
            " https"
        )
