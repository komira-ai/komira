# =============================================================================
# komira_aws_core/imds_credentials.mojo -- EC2 instance metadata (IMDSv2)
# =============================================================================
#
# The instance profile credential provider, as the AWS SDKs implement it:
#   https://docs.aws.amazon.com/sdkref/latest/guide/feature-imds-credentials.html
#   https://docs.aws.amazon.com/sdkref/latest/guide/feature-imds-client.html
#   https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-metadata-security-credentials.html
#
# Three requests, IMDSv2 only:
#   1. PUT /latest/api/token with X-aws-ec2-metadata-token-ttl-seconds -> a
#      session token (plain text);
#   2. GET /latest/meta-data/iam/security-credentials/ with
#      X-aws-ec2-metadata-token -> the role name (first line);
#   3. GET /latest/meta-data/iam/security-credentials/<role> -> JSON with
#      Code "Success", AccessKeyId, SecretAccessKey, Token, Expiration.
# There is no IMDSv1 fallback: this provider behaves as the SDKs do with
# AWS_EC2_METADATA_V1_DISABLED=true.
#
# Settings (feature-imds-client.html), read in credential_chain.mojo through
# the EnvSource:
#   AWS_EC2_METADATA_DISABLED              -- "true" turns this provider off.
#   AWS_EC2_METADATA_SERVICE_ENDPOINT      -- the endpoint URL; wins over
#   AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE -- "IPv4" (http://169.254.169.254,
#                                             the default) or "IPv6"
#                                             (http://[fd00:ec2::254]).
# =============================================================================

from .credential import AwsCredential
from .credential_transport import (
    CredentialHttpRequest,
    CredentialHttpResponse,
    host_header,
)
from .container_credentials import ContainerEndpoint, parse_http_url
from .sigv4 import Header
from .sts_credentials import TemporaryAwsCredential
from ._flat_json import parse_flat_json
from ._text import ascii_lower, has_control, split_lines, sub, trim


comptime IMDS_IPV4_HOST: StaticString = "169.254.169.254"
comptime IMDS_IPV6_HOST: StaticString = "[fd00:ec2::254]"
comptime IMDS_TOKEN_PATH: StaticString = "/latest/api/token"
comptime IMDS_CREDENTIALS_PATH: StaticString = (
    "/latest/meta-data/iam/security-credentials/"
)
comptime IMDS_TOKEN_TTL_SECONDS = 21600


def imds_endpoint(endpoint: String, mode: String) raises -> ContainerEndpoint:
    """The metadata endpoint from AWS_EC2_METADATA_SERVICE_ENDPOINT (wins) or
    AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE. `target` is the base path."""
    if trim(endpoint).byte_length() > 0:
        var ep = parse_http_url(endpoint, "AWS_EC2_METADATA_SERVICE_ENDPOINT")
        var t = ep.target
        while t.byte_length() > 0 and t.endswith("/"):
            t = sub(t, 0, t.byte_length() - 1)
        return ContainerEndpoint(ep.scheme, ep.host, ep.port, t)
    var m = ascii_lower(trim(mode))
    if m.byte_length() == 0 or m == "ipv4":
        return ContainerEndpoint(String("http"), String(IMDS_IPV4_HOST), 80, String(""))
    if m == "ipv6":
        return ContainerEndpoint(String("http"), String(IMDS_IPV6_HOST), 80, String(""))
    raise Error("AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE must be IPv4 or IPv6")


def _imds_request(
    ep: ContainerEndpoint, method: String, path: String
) -> CredentialHttpRequest:
    var req = CredentialHttpRequest(
        method, ep.scheme, ep.host, ep.port, ep.target + path
    )
    req.headers.append(
        Header(String("Host"), host_header(ep.host, ep.port, ep.scheme))
    )
    return req^


def build_imds_token_request(ep: ContainerEndpoint) -> CredentialHttpRequest:
    var req = _imds_request(ep, String("PUT"), String(IMDS_TOKEN_PATH))
    req.headers.append(
        Header(
            String("X-aws-ec2-metadata-token-ttl-seconds"),
            String(IMDS_TOKEN_TTL_SECONDS),
        )
    )
    req.headers.append(Header(String("Content-Length"), String("0")))
    return req^


def _check_session_token(token: String) raises:
    if token.byte_length() == 0 or has_control(token):
        raise Error("the instance metadata session token is empty or malformed")


def build_imds_role_request(
    ep: ContainerEndpoint, session_token: String
) raises -> CredentialHttpRequest:
    _check_session_token(session_token)
    var req = _imds_request(ep, String("GET"), String(IMDS_CREDENTIALS_PATH))
    req.headers.append(Header(String("X-aws-ec2-metadata-token"), session_token))
    return req^


def build_imds_credentials_request(
    ep: ContainerEndpoint, session_token: String, role: String
) raises -> CredentialHttpRequest:
    _check_session_token(session_token)
    var b = role.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        var ok = (
            (c >= UInt8(0x61) and c <= UInt8(0x7A))
            or (c >= UInt8(0x41) and c <= UInt8(0x5A))
            or (c >= UInt8(0x30) and c <= UInt8(0x39))
            or c == UInt8(0x2B) or c == UInt8(0x3D) or c == UInt8(0x2C)
            or c == UInt8(0x2E) or c == UInt8(0x40) or c == UInt8(0x5F)
            or c == UInt8(0x2D)
        )
        if not ok:
            raise Error("the instance profile role name is not an IAM role name")
    if len(b) == 0:
        raise Error("the instance has no IAM role attached")
    var req = _imds_request(
        ep, String("GET"), String(IMDS_CREDENTIALS_PATH) + role
    )
    req.headers.append(Header(String("X-aws-ec2-metadata-token"), session_token))
    return req^


def parse_imds_token(resp: CredentialHttpResponse) raises -> String:
    """The session token. Refuses a non-200 answer naming the status."""
    if resp.status != 200:
        raise Error(
            "the instance metadata token request answered HTTP "
            + String(resp.status)
        )
    var t = trim(resp.body)
    _check_session_token(t)
    return t


def parse_imds_role(resp: CredentialHttpResponse) raises -> String:
    """The first role name listed. 404 means no role is attached."""
    if resp.status == 404:
        raise Error("the instance has no IAM role attached")
    if resp.status != 200:
        raise Error(
            "the instance metadata role list answered HTTP " + String(resp.status)
        )
    var lines = split_lines(resp.body)
    for i in range(len(lines)):
        var r = trim(lines[i])
        if r.byte_length() > 0:
            return r
    raise Error("the instance has no IAM role attached")


def parse_imds_credentials(
    resp: CredentialHttpResponse,
) raises -> TemporaryAwsCredential:
    """Parses the role credentials JSON. Refuses a non-200 answer and a Code
    other than "Success", naming the status or the code."""
    if resp.status != 200:
        raise Error(
            "the instance metadata credentials request answered HTTP "
            + String(resp.status)
        )
    var j = parse_flat_json(resp.body)
    var code = j.get("Code")
    if code != "Success":
        raise Error(
            "the instance metadata credentials have Code '" + code
            + "', not 'Success'"
        )
    var key = j.get("AccessKeyId")
    var secret = j.get("SecretAccessKey")
    if key.byte_length() == 0 or secret.byte_length() == 0:
        raise Error(
            "the instance metadata credentials lack AccessKeyId or"
            " SecretAccessKey"
        )
    return TemporaryAwsCredential(
        AwsCredential(key, secret, j.get("Token")), j.get("Expiration")
    )
