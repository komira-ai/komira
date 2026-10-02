# =============================================================================
# komira_aws_core/container_credentials.mojo -- ECS / EKS container credentials
# =============================================================================
#
# The container credential provider, as the AWS SDKs implement it:
#   https://docs.aws.amazon.com/sdkref/latest/guide/feature-container-credentials.html
#
# Settings (all environment variables, set by ECS, EKS Pod Identity or the
# operator; there is no shared-file form):
#   AWS_CONTAINER_CREDENTIALS_RELATIVE_URI  -- a path on http://169.254.170.2.
#                                              Wins over FULL_URI.
#   AWS_CONTAINER_CREDENTIALS_FULL_URI      -- a full URL. https may name any
#                                              host; plain http only a loopback
#                                              address, the ECS endpoint
#                                              169.254.170.2 or the EKS Pod
#                                              Identity endpoint 169.254.170.23
#                                              / [fd00:ec2::23].
#   AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE  -- a file holding the value of the
#                                              Authorization header; wins over
#   AWS_CONTAINER_AUTHORIZATION_TOKEN       -- the value itself.
# As in the AWS SDKs, the authorization token is sent with FULL_URI only.
#
# This package resolves no host name, so "localhost" is accepted by name and
# other loopback addresses only as literals (127.0.0.0/8, [::1]).
#
# The env reads happen in credential_chain.mojo through the EnvSource; this
# module is pure: endpoint, request, parser.
# =============================================================================

from .credential import AwsCredential
from .credential_transport import (
    CredentialHttpRequest,
    CredentialHttpResponse,
    host_header,
)
from .sigv4 import Header
from .sts_credentials import TemporaryAwsCredential
from ._flat_json import parse_flat_json
from ._text import has_control, has_crlf, sub, trim


comptime ECS_CONTAINER_HOST: StaticString = "169.254.170.2"
comptime EKS_CONTAINER_HOST_V4: StaticString = "169.254.170.23"
comptime EKS_CONTAINER_HOST_V6: StaticString = "[fd00:ec2::23]"


@fieldwise_init
struct ContainerEndpoint(Copyable, Movable):
    """Where to fetch container credentials."""

    var scheme: String
    var host: String
    var port: Int
    var target: String


def _all_digits(s: String) -> Bool:
    var b = s.as_bytes()
    if len(b) == 0:
        return False
    for i in range(len(b)):
        if b[i] < UInt8(0x30) or b[i] > UInt8(0x39):
            return False
    return True


def _small_int(s: String) -> Int:
    """The value of a short all-digit string."""
    var b = s.as_bytes()
    var v = 0
    for i in range(len(b)):
        v = v * 10 + Int(b[i]) - 0x30
    return v


def _is_loopback_v4(host: String) -> Bool:
    var parts = host.split(".")
    if len(parts) != 4:
        return False
    for i in range(4):
        var p = String(parts[i])
        if not _all_digits(p) or p.byte_length() > 3 or _small_int(p) > 255:
            return False
    return String(parts[0]) == "127"


def _http_host_allowed(host: String) -> Bool:
    return (
        host == "localhost"
        or host == "[::1]"
        or host == String(ECS_CONTAINER_HOST)
        or host == String(EKS_CONTAINER_HOST_V4)
        or host == String(EKS_CONTAINER_HOST_V6)
        or _is_loopback_v4(host)
    )


def container_endpoint_relative(relative_uri: String) raises -> ContainerEndpoint:
    """AWS_CONTAINER_CREDENTIALS_RELATIVE_URI on http://169.254.170.2."""
    var r = trim(relative_uri)
    if r.byte_length() == 0 or sub(r, 0, 1) != "/" or has_control(r) or r.find(" ") >= 0:
        raise Error(
            "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI is not a path starting with '/'"
        )
    return ContainerEndpoint(String("http"), String(ECS_CONTAINER_HOST), 80, r)


def container_endpoint_full(full_uri: String) raises -> ContainerEndpoint:
    """AWS_CONTAINER_CREDENTIALS_FULL_URI, with the SDKs' host rule for http."""
    var setting = String("AWS_CONTAINER_CREDENTIALS_FULL_URI")
    var ep = parse_http_url(full_uri, setting)
    if ep.scheme == "http" and not _http_host_allowed(ep.host):
        raise Error(
            setting
            + " uses plain http to a host that is not loopback, the ECS"
            " endpoint or the EKS Pod Identity endpoint; use https"
        )
    return ep^


def parse_http_url(url: String, setting: String) raises -> ContainerEndpoint:
    """Splits an http:// or https:// URL into scheme, host (an IPv6 literal
    keeps its brackets), port and target. Refusals name `setting`."""
    var u = trim(url)
    if has_control(u) or u.find(" ") >= 0:
        raise Error(setting + " holds whitespace or control bytes")
    var scheme: String
    var rest: String
    if sub(u, 0, 7) == "http://":
        scheme = String("http")
        rest = sub(u, 7, u.byte_length())
    elif sub(u, 0, 8) == "https://":
        scheme = String("https")
        rest = sub(u, 8, u.byte_length())
    else:
        raise Error(setting + " is not an http:// or https:// URL")
    var slash = rest.find("/")
    var authority = rest if slash < 0 else sub(rest, 0, slash)
    var target = String("/") if slash < 0 else sub(rest, slash, rest.byte_length())
    if authority.find("@") >= 0:
        raise Error(setting + " must not carry user information")
    var host = authority
    var port = 80 if scheme == "http" else 443
    var port_at = -1
    if sub(authority, 0, 1) == "[":
        var close = authority.find("]")
        if close < 0:
            raise Error(setting + " has an unterminated IPv6 literal")
        host = sub(authority, 0, close + 1)
        if close + 1 < authority.byte_length():
            if sub(authority, close + 1, close + 2) != ":":
                raise Error(setting + " has text after its IPv6 literal")
            port_at = close + 1
    else:
        port_at = authority.find(":")
        if port_at >= 0:
            host = sub(authority, 0, port_at)
    if port_at >= 0:
        var p = sub(authority, port_at + 1, authority.byte_length())
        if not _all_digits(p) or p.byte_length() > 5 or _small_int(p) == 0 or _small_int(p) > 65535:
            raise Error(setting + " has an invalid port")
        port = _small_int(p)
    if host.byte_length() == 0:
        raise Error(setting + " has no host")
    return ContainerEndpoint(scheme, host, port, target)


def build_container_request(
    endpoint: ContainerEndpoint, authorization: String
) raises -> CredentialHttpRequest:
    """GET the endpoint; `authorization` ("" for none) is the Authorization
    header value."""
    if has_crlf(authorization) or has_control(authorization):
        raise Error("the container authorization token holds control bytes")
    var req = CredentialHttpRequest(
        String("GET"), endpoint.scheme, endpoint.host, endpoint.port,
        endpoint.target,
    )
    req.headers.append(
        Header(
            String("Host"),
            host_header(endpoint.host, endpoint.port, endpoint.scheme),
        )
    )
    req.headers.append(Header(String("Accept"), String("application/json")))
    if authorization.byte_length() > 0:
        req.headers.append(Header(String("Authorization"), authorization))
    return req^


def parse_container_credentials(
    resp: CredentialHttpResponse,
) raises -> TemporaryAwsCredential:
    """Parses {"AccessKeyId", "SecretAccessKey", "Token", "Expiration"}. A
    non-200 answer is refused naming the status and the endpoint's error
    code, never the body."""
    if resp.status != 200:
        var code = String("")
        try:
            var j = parse_flat_json(resp.body)
            code = j.get("code") if j.has("code") else j.get("Code")
        except:
            pass
        raise Error(
            "the container credentials endpoint answered HTTP "
            + String(resp.status)
            + (": " + code if code.byte_length() > 0 else String(""))
        )
    var j = parse_flat_json(resp.body)
    var key = j.get("AccessKeyId")
    var secret = j.get("SecretAccessKey")
    if key.byte_length() == 0 or secret.byte_length() == 0:
        raise Error(
            "the container credentials response lacks AccessKeyId or"
            " SecretAccessKey"
        )
    return TemporaryAwsCredential(
        AwsCredential(key, secret, j.get("Token")), j.get("Expiration")
    )
