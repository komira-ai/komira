# =============================================================================
# komira_aws_core/sts_credentials.mojo -- STS AssumeRole and
# AssumeRoleWithWebIdentity, hand-written
# =============================================================================
#
# The two STS calls the credential chain makes, as request builders and one
# response parser. They stay hand-written here: komira_aws_core never imports
# a generated komira_aws_<svc> module, so the generated STS client can depend
# on this package without a cycle.
#
# Wire format: the AWS Query protocol, version 2011-06-15. A form-encoded POST
# to "/" whose answer is XML:
#   https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRoleWithWebIdentity.html
#   https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRole.html
#
# Endpoint: the regional endpoint sts.<region>.amazonaws.com when a region is
# known, else the global sts.amazonaws.com (signing region us-east-1):
#   https://docs.aws.amazon.com/sdkref/latest/guide/feature-sts-regionalized-endpoints.html
# That host is right only in the 'aws' and 'aws-us-gov' partitions; a region in
# any other partition (aws-cn, the ISO partitions, ...) is REFUSED, naming the
# setting it came from, rather than sent to a host that does not exist or to
# the wrong partition. Partition and endpoint resolution is not here yet.
#
# AssumeRoleWithWebIdentity is unsigned (the web identity token is the
# proof); AssumeRole is SigV4-signed with the source credential.
#
# The request holds the web identity token or a signature; the response holds
# the new secret. Refusals name the STS error code and message, which carry no
# secret, and never quote a token or a key.
# =============================================================================

from komira_xml import XmlNode, parse_xml

from .credential import AwsCredential
from .credential_transport import (
    CredentialHttpRequest,
    CredentialHttpResponse,
    host_header,
)
from .sigv4 import Header, SigV4SigningContext, sigv4_sign, uri_encode
from ._text import has_control


comptime STS_API_VERSION: StaticString = "2011-06-15"
comptime _FORM_CONTENT_TYPE: StaticString = (
    "application/x-www-form-urlencoded; charset=utf-8"
)


@fieldwise_init
struct TemporaryAwsCredential(Copyable, Movable):
    """A credential with its expiry, as STS and the metadata endpoints return
    it. `expiration` is the ISO 8601 UTC time the service sent ("" when the
    credential does not expire). Not `Writable`."""

    var credential: AwsCredential
    var expiration: String


def _region_ok(region: String) -> Bool:
    var b = region.as_bytes()
    if len(b) == 0 or len(b) > 64:
        return False
    for i in range(len(b)):
        var c = b[i]
        var ok = (
            (c >= UInt8(0x61) and c <= UInt8(0x7A))
            or (c >= UInt8(0x30) and c <= UInt8(0x39))
            or c == UInt8(0x2D)
        )
        if not ok:
            return False
    return True


def check_region(region: String, setting: String) raises:
    """Refuses a region that is not lowercase letters, digits and '-', naming
    the setting it came from."""
    if not _region_ok(region):
        raise Error(
            "the region from " + setting + " is not a valid AWS region name"
        )


def _region_parts(region: String) -> List[String]:
    var out = List[String]()
    var cur = String("")
    var b = region.as_bytes()
    for i in range(len(b)):
        if b[i] == UInt8(0x2D):
            out.append(cur^)
            cur = String("")
        else:
            cur += chr(Int(b[i]))
    out.append(cur^)
    return out^


def _all_in(s: String, lo: UInt8, hi: UInt8) -> Bool:
    var b = s.as_bytes()
    if len(b) == 0:
        return False
    for i in range(len(b)):
        if b[i] < lo or b[i] > hi:
            return False
    return True


def sts_region_in_supported_partition(region: String) -> Bool:
    """True when `region` is in the 'aws' or 'aws-us-gov' partition, the two
    whose STS host is sts.<region>.amazonaws.com. The shapes are the
    partitions' regionRegex in the AWS SDKs' partitions.json:
      aws         ^(us|eu|ap|sa|ca|me|af|il|mx)-\\w+-\\d+$
      aws-us-gov  ^us-gov-\\w+-\\d+$
    Everything else -- aws-cn (cn-*, host suffix amazonaws.com.cn), the ISO
    partitions (us-iso-*, us-isob-*, us-isof-*, eu-isoe-*), aws-eusc and any
    partition added later -- is outside, fail-closed: endpoint and partition
    resolution is not in this package yet."""
    var p = _region_parts(region)
    var a = UInt8(0x61)
    var z = UInt8(0x7A)
    var d0 = UInt8(0x30)
    var d9 = UInt8(0x39)
    if len(p) == 4:
        return (
            p[0] == "us" and p[1] == "gov" and _all_in(p[2], a, z)
            and _all_in(p[3], d0, d9)
        )
    if len(p) != 3 or not _all_in(p[1], a, z) or not _all_in(p[2], d0, d9):
        return False
    var prefixes: List[String] = [
        "us", "eu", "ap", "sa", "ca", "me", "af", "il", "mx"
    ]
    for i in range(len(prefixes)):
        if p[0] == prefixes[i]:
            return True
    return False


def check_sts_region(region: String, setting: String) raises:
    """check_region, then refuses a region outside the 'aws' and 'aws-us-gov'
    partitions, naming the region and the setting it came from. A region
    that passed check_region is lowercase letters, digits and '-', so it is
    safe to quote."""
    check_region(region, setting)
    if not sts_region_in_supported_partition(region):
        raise Error(
            "the region '" + region + "' from " + setting
            + " is not in the 'aws' or 'aws-us-gov' partition; komira_aws_core"
            " builds STS hosts (sts.<region>.amazonaws.com) only for those two"
        )


def sts_host(region: String) raises -> String:
    if region.byte_length() == 0:
        return String("sts.amazonaws.com")
    check_sts_region(region, "the resolved region")
    return "sts." + region + ".amazonaws.com"


def sts_signing_region(region: String) -> String:
    if region.byte_length() == 0:
        return String("us-east-1")
    return region


def check_role_session_name(name: String, setting: String) raises:
    """STS RoleSessionName: 2 to 64 of [A-Za-z0-9+=,.@_-]."""
    var b = name.as_bytes()
    var ok = len(b) >= 2 and len(b) <= 64
    for i in range(len(b)):
        var c = b[i]
        var good = (
            (c >= UInt8(0x61) and c <= UInt8(0x7A))
            or (c >= UInt8(0x41) and c <= UInt8(0x5A))
            or (c >= UInt8(0x30) and c <= UInt8(0x39))
            or c == UInt8(0x2B)
            or c == UInt8(0x3D)
            or c == UInt8(0x2C)
            or c == UInt8(0x2E)
            or c == UInt8(0x40)
            or c == UInt8(0x5F)
            or c == UInt8(0x2D)
        )
        if not good:
            ok = False
    if not ok:
        raise Error(
            "the role session name from " + setting
            + " must be 2 to 64 of A-Z a-z 0-9 + = , . @ _ -"
        )


def _check_role_arn(role_arn: String, setting: String) raises:
    if role_arn.byte_length() == 0 or has_control(role_arn):
        raise Error("the role ARN from " + setting + " is empty or malformed")


def _form(mut body: String, key: String, value: String):
    if body.byte_length() > 0:
        body += "&"
    body += key + "=" + uri_encode(value)


def _sts_request(
    region: String, var body: String
) raises -> CredentialHttpRequest:
    var host = sts_host(region)
    var req = CredentialHttpRequest(
        String("POST"), String("https"), host, 443, String("/")
    )
    req.headers.append(Header(String("Host"), host_header(host, 443, "https")))
    req.headers.append(
        Header(String("Content-Type"), String(_FORM_CONTENT_TYPE))
    )
    req.body = body^
    return req^


def build_assume_role_with_web_identity(
    role_arn: String,
    role_session_name: String,
    web_identity_token: String,
    region: String,
) raises -> CredentialHttpRequest:
    """The unsigned STS AssumeRoleWithWebIdentity request."""
    _check_role_arn(role_arn, "the web identity role ARN setting")
    check_role_session_name(role_session_name, "the role session name setting")
    if web_identity_token.byte_length() == 0 or has_control(web_identity_token):
        raise Error("the web identity token file is empty or holds control bytes")
    var body = String("")
    _form(body, "Action", "AssumeRoleWithWebIdentity")
    _form(body, "Version", String(STS_API_VERSION))
    _form(body, "RoleArn", role_arn)
    _form(body, "RoleSessionName", role_session_name)
    _form(body, "WebIdentityToken", web_identity_token)
    var req = _sts_request(region, body^)
    req.headers.append(
        Header(String("Content-Length"), String(req.body.byte_length()))
    )
    return req^


def build_assume_role(
    role_arn: String,
    role_session_name: String,
    external_id: String,
    duration_seconds: String,
    region: String,
    source: AwsCredential,
    amz_date: String,
) raises -> CredentialHttpRequest:
    """The SigV4-signed STS AssumeRole request, signed with `source` at
    `amz_date`. `external_id` and `duration_seconds` are omitted when ""."""
    _check_role_arn(role_arn, "the profile's role_arn")
    check_role_session_name(role_session_name, "the role session name setting")
    if has_control(external_id):
        raise Error("the profile's external_id holds control bytes")
    var dur = duration_seconds.as_bytes()
    for i in range(len(dur)):
        if dur[i] < UInt8(0x30) or dur[i] > UInt8(0x39):
            raise Error("the profile's duration_seconds is not a whole number")
    var body = String("")
    _form(body, "Action", "AssumeRole")
    _form(body, "Version", String(STS_API_VERSION))
    _form(body, "RoleArn", role_arn)
    _form(body, "RoleSessionName", role_session_name)
    if external_id.byte_length() > 0:
        _form(body, "ExternalId", external_id)
    if duration_seconds.byte_length() > 0:
        _form(body, "DurationSeconds", duration_seconds)
    var req = _sts_request(region, body^)
    var ctx = SigV4SigningContext(
        source, sts_signing_region(region), String("sts"), amz_date
    )
    var signed = sigv4_sign(
        req.method, req.target, req.headers, req.body.as_bytes(), ctx
    )
    req.headers.append(
        Header(String("Content-Length"), String(req.body.byte_length()))
    )
    for i in range(len(signed.headers_to_add)):
        req.headers.append(signed.headers_to_add[i])
    return req^


def _child_text(node: XmlNode, name: String, what: String) raises -> String:
    if not node.has_child(name):
        raise Error("the STS " + what + " response has no " + name)
    return node.first_child(name).text


def _parse_body(action: String, resp: CredentialHttpResponse) raises -> XmlNode:
    try:
        return parse_xml(resp.body)
    except:
        raise Error(
            "STS " + action + " answered HTTP " + String(resp.status)
            + " with a body that is not XML"
        )


def parse_sts_credentials(
    action: String, resp: CredentialHttpResponse
) raises -> TemporaryAwsCredential:
    """Parses the answer to `action` ("AssumeRole" or
    "AssumeRoleWithWebIdentity"). An STS ErrorResponse, or any non-200
    status, is refused naming the STS error code and message."""
    var root = _parse_body(action, resp)
    if root.local == "ErrorResponse" or resp.status != 200:
        var code = String("")
        var message = String("")
        if root.has_child("Error"):
            var err = root.first_child("Error")
            if err.has_child("Code"):
                code = err.first_child("Code").text
            if err.has_child("Message"):
                message = err.first_child("Message").text
        raise Error(
            "STS " + action + " refused (HTTP " + String(resp.status) + "): "
            + code + ": " + message
        )
    if root.local != action + "Response":
        raise Error("STS " + action + " answered with a " + root.local)
    var result = root.first_child(action + "Result")
    if not result.has_child("Credentials"):
        raise Error("the STS " + action + " response has no Credentials")
    var c = result.first_child("Credentials")
    var key = _child_text(c, "AccessKeyId", action)
    var secret = _child_text(c, "SecretAccessKey", action)
    var token = _child_text(c, "SessionToken", action)
    var exp = _child_text(c, "Expiration", action)
    if key.byte_length() == 0 or secret.byte_length() == 0:
        raise Error("the STS " + action + " response has an empty key")
    return TemporaryAwsCredential(AwsCredential(key, secret, token), exp)
