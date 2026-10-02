# =============================================================================
# komira_aws_core/signed_request.mojo -- the signing half of a send
# =============================================================================
#
# `build_sigv4_signed_request` turns what a generated client's `send` has in
# hand -- method, credential, region, service, endpoint, path, content type,
# body and the operation's extra headers -- into the exact SigV4-signed
# request, at the time the clock says. It opens no socket. The transport
# half, `send_sigv4_signed_request`, takes the same arguments plus the HTTP
# client and its configuration, calls this, and hands the bytes to the HTTP
# client; it lands with the HTTP library.
#
# Every operation header in `extra` is SIGNED. awsJson services include
# X-Amz-Target in the canonical request, so an unsigned one is answered
# `SignatureDoesNotMatch`. Content-Length is added after signing and is not
# signed, as the AWS SDKs do, so a transport that rewrites it does not break
# the signature.
#
# For service "s3" the S3 SigV4 rules apply: the payload hash is sent and
# signed as x-amz-content-sha256, and the path is neither normalized nor
# encoded twice.
#
# The result holds the signature and, for a temporary credential, the session
# token. It is not `Writable`; `to_wire()` is for the transport and tests.
# =============================================================================

from ._text import ascii_lower, has_crlf
from .credential import AwsCredential
from .credential_transport import CredentialHttpRequest
from .endpoint import AwsEndpoint
from .sigv4 import Header, SigV4SigningContext, sigv4_sign
from .sources import AwsClock, amz_date_from_unix


def _is_token_byte(c: UInt8) -> Bool:
    return (c >= UInt8(0x41) and c <= UInt8(0x5A)) or (
        c >= UInt8(0x61) and c <= UInt8(0x7A)
    )


def _check_method(method: String) raises:
    var b = method.as_bytes()
    if len(b) == 0:
        raise Error("an AWS request has an empty method")
    for i in range(len(b)):
        if not _is_token_byte(b[i]):
            raise Error("an AWS request method is not letters only")


def _is_reserved(name: String) -> Bool:
    var n = ascii_lower(name)
    return n == "host" or n == "content-type" or n == "content-length"


def _sends_body(method: String, body: String) -> Bool:
    if body.byte_length() > 0:
        return True
    return method == "POST" or method == "PUT" or method == "PATCH"


def build_sigv4_signed_request[
    K: AwsClock
](
    method: String,
    cred: AwsCredential,
    region: String,
    service: String,
    endpoint: AwsEndpoint,
    uri: String,
    content_type: String,
    body: String,
    extra: List[Header],
    mut clock: K,
) raises -> CredentialHttpRequest:
    """The SigV4-signed request, signed at `clock`'s time.

    Headers, in send order: Host, Content-Type (when not ""), each of
    `extra`, Content-Length (when the request carries a body, and "0" on a
    body-less POST, PUT or PATCH; never signed, as botocore adds it in
    `prepare()` after signing), then the
    signer's X-Amz-Date, x-amz-content-sha256 (S3), X-Amz-Security-Token
    (temporary credentials) and Authorization.

    Refuses a malformed method, a `uri` not starting with '/', CR/LF
    anywhere in a header, and an `extra` header named Host, Content-Type or
    Content-Length (each has its own argument) or one the signer writes.
    """
    _check_method(method)
    if not uri.startswith("/"):
        raise Error("an AWS request path does not start with '/'")
    if has_crlf(uri) or has_crlf(content_type):
        raise Error("an AWS request path or content type holds CR or LF")
    var target = endpoint.target_for(uri)
    var headers = List[Header]()
    headers.append(Header(String("Host"), endpoint.host_header()))
    if content_type.byte_length() > 0:
        headers.append(Header(String("Content-Type"), content_type))
    for i in range(len(extra)):
        if _is_reserved(extra[i].name):
            raise Error(
                "the extra header "
                + extra[i].name
                + " is set by the request builder; pass it as its argument"
            )
        headers.append(extra[i])
    var is_s3 = service == "s3"
    var ctx = SigV4SigningContext(
        cred,
        region,
        service,
        amz_date_from_unix(clock.now_unix_seconds()),
        sign_payload_header=is_s3,
        normalize_path=not is_s3,
        uri_encode_path=not is_s3,
    )
    var signed = sigv4_sign(method, target, headers, body.as_bytes(), ctx)
    var req = CredentialHttpRequest(
        method, endpoint.scheme, endpoint.host, endpoint.port, target
    )
    req.headers = headers^
    if _sends_body(method, body):
        req.headers.append(
            Header(String("Content-Length"), String(body.byte_length()))
        )
    for i in range(len(signed.headers_to_add)):
        req.headers.append(signed.headers_to_add[i])
    req.body = body
    return req^
