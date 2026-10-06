# =============================================================================
# komira_aws_core/signed_request.mojo -- the signing half of a send
# =============================================================================
#
# `build_sigv4_signed_request` turns what a generated client's `send` has in
# hand -- method, credential, region, service, endpoint, path and query,
# content type, body bytes and the operation's extra headers -- into the
# exact SigV4-signed request, at the time the clock says. It opens no
# socket. The transport half, `send_sigv4_signed_request` (aws_send.mojo),
# takes the same arguments plus the connector factory, the caller's
# `HttpClientConfig` and the client's retry quota, calls this once per
# attempt, and hands the request to a komira_http_client built from that
# config. Generated clients call it (emit_aws/mod.rs, a client's `send`):
# `send_sigv4_signed_request[C: Connector](mk_connector, http_config:
# HttpClientConfig, mut retry_quota: AwsRetryQuota, method, cred, region,
# service, endpoint, uri, content_type, body: List[UInt8], extra:
# List[Header], s3_200_error: Bool = False) raises -> HttpResult`. The tests
# cell's stand-in (tools/build/tests/functional/mojo_aws_client/stub/
# komira_aws_core) has that signature, and the generator's goldens pin the
# call's leading arguments (tools/build/tests/functional/aws_codegen,
# `must_contain`); the real one keeps it, or all three change together.
#
# Every operation header in `extra` is SIGNED. awsJson services include
# X-Amz-Target in the canonical request, so an unsigned one is answered
# `SignatureDoesNotMatch`. Content-Length is added after signing and is not
# signed, as the AWS SDKs do, so a transport that rewrites it does not break
# the signature.
#
# The payload hash (`AwsPayloadSigning`):
#   .hashed()          the SHA-256 of the body, computed here (the default);
#   .unsigned()        UNSIGNED-PAYLOAD: the body is not covered;
#   .precomputed(hex)  a SHA-256 the caller already has, 64 lowercase hex.
# The hash is sent and signed as x-amz-content-sha256 for an S3 signing
# name, and for any service whenever it is not `.hashed()`: a service can
# check an unsigned or precomputed hash only from that header. For an S3
# signing name the S3 SigV4 rules apply too: the path is neither normalized
# nor encoded twice.
#
# The S3 signing names are botocore's `S3_SIGNING_NAMES`
# (botocore/handlers.py): s3, s3-outposts, s3-object-lambda and s3express.
# botocore signs a sigv4 request under any of them with `S3SigV4Auth`
# (`set_operation_specific_signer`), and so does this builder
# (`is_s3_signing_name`).
#
# Outside S3 this follows botocore: its base `SigV4Auth` sends
# `X-Amz-Content-SHA256: UNSIGNED-PAYLOAD` for any service whose payload
# signing is turned off, and only `S3SigV4Auth` sends a real hash. Sending a
# precomputed hash outside S3 goes one step further, and is a choice of this
# builder: aws-c-auth makes the header (`signed_body_header`) a setting apart
# from the hash it carries (`signed_body_value`), and a caller who passes
# `.precomputed()` has asked that the hash, not the body, be signed.
#
# `build_unsigned_request` is the same request with no signature: what an
# operation the model marks anonymous (`authtype` `none`, `auth`
# `smithy.api#noAuth`) sends, through `send_unsigned_request`
# (aws_send.mojo). It sends the same headers up to Content-Length, and
# nothing after them. Both builders refuse the same `extra` headers
# (`_request_headers`): CR/LF, an empty name, a name the signer writes in any
# case, and Host, Content-Type or Content-Length.
#
# The result holds the signature and, for a temporary credential, the session
# token. It is not `Writable`; `to_wire()` is for the transport and tests.
# =============================================================================

from komira_crypto import hex_lower_array_32, sha256

from ._text import ascii_lower, has_crlf
from .credential import AwsCredential
from .credential_transport import CredentialHttpRequest
from .endpoint import AwsEndpoint
from .sigv4 import (
    UNSIGNED_PAYLOAD,
    Header,
    SigV4SigningContext,
    _is_signer_owned_header,
    _trim_collapse,
    sigv4_sign_payload_hash,
)
from .sources import AwsClock, amz_date_from_unix


def is_s3_signing_name(name: String) -> Bool:
    """Whether `name` is signed by S3's SigV4 rules: botocore's
    `S3_SIGNING_NAMES` (botocore/handlers.py), the names it signs with
    `S3SigV4Auth` (path neither normalized nor encoded twice, payload hash
    sent as x-amz-content-sha256)."""
    return (
        name == "s3"
        or name == "s3-outposts"
        or name == "s3-object-lambda"
        or name == "s3express"
    )


comptime _HASHED = 0
comptime _UNSIGNED = 1
comptime _PRECOMPUTED = 2


struct AwsPayloadSigning(Copyable, ImplicitlyCopyable, Movable):
    """How a request's payload is covered by its signature: `.hashed()`,
    `.unsigned()` or `.precomputed(hex)` (see the module header)."""

    var _kind: Int
    var _hash: String

    def __init__(out self, kind: Int, hash: String):
        """Construct one through `hashed()`, `unsigned()` or
        `precomputed()`. A value made here directly is checked by
        `build_sigv4_signed_request`, which refuses a kind that is none of
        the three or a hash that does not fit its kind."""
        self._kind = kind
        self._hash = hash

    @staticmethod
    def hashed() -> AwsPayloadSigning:
        """The body's SHA-256, computed by the request builder."""
        return AwsPayloadSigning(_HASHED, String(""))

    @staticmethod
    def unsigned() -> AwsPayloadSigning:
        """UNSIGNED-PAYLOAD: the signature does not cover the body."""
        return AwsPayloadSigning(_UNSIGNED, String(UNSIGNED_PAYLOAD))

    @staticmethod
    def precomputed(hex: String) raises -> AwsPayloadSigning:
        """A SHA-256 of the body the caller computed: exactly 64 lowercase
        hex digits, refused otherwise. The builder does not re-hash the
        body, so a hash that does not match it is answered by the service,
        not here."""
        var p = AwsPayloadSigning(_PRECOMPUTED, hex)
        p.check()
        return p^

    def check(self) raises:
        """Refuses a kind that is none of the three, and a hash that does
        not fit its kind: "" for hashed, UNSIGNED-PAYLOAD for unsigned, 64
        lowercase hex digits for precomputed."""
        if self._kind == _HASHED:
            if self._hash.byte_length() != 0:
                raise Error("a hashed payload carries a hash of its own")
        elif self._kind == _UNSIGNED:
            if self._hash != UNSIGNED_PAYLOAD:
                raise Error("an unsigned payload's hash is not UNSIGNED-PAYLOAD")
        elif self._kind == _PRECOMPUTED:
            if not _is_sha256_hex(self._hash):
                raise Error(
                    "a precomputed payload hash is not 64 lowercase hex digits"
                )
        else:
            raise Error("a payload signing kind is none of hashed, unsigned, precomputed")

    def is_hashed(self) -> Bool:
        return self._kind == _HASHED

    def payload_hash(self, body: Span[UInt8, _]) -> String:
        """The x-amz-content-sha256 value for `body`."""
        if self._kind == _HASHED:
            return hex_lower_array_32(sha256(body))
        return self._hash


def _is_sha256_hex(hex: String) -> Bool:
    var b = hex.as_bytes()
    if len(b) != 64:
        return False
    for i in range(len(b)):
        var c = b[i]
        if not (
            (c >= UInt8(0x30) and c <= UInt8(0x39))
            or (c >= UInt8(0x61) and c <= UInt8(0x66))
        ):
            return False
    return True


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


def _sends_body(method: String, body_len: Int) -> Bool:
    if body_len > 0:
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
    body: Span[UInt8, _],
    extra: List[Header],
    mut clock: K,
    payload: AwsPayloadSigning = AwsPayloadSigning.hashed(),
) raises -> CredentialHttpRequest:
    """The SigV4-signed request, signed at `clock`'s time.

    `uri` is the path and query; the query is signed as it stands (a key
    with no value included). `body` is sent as given, byte for byte.

    Headers, in send order: Host, Content-Type (when not ""), each of
    `extra`, Content-Length (when the request carries a body, and "0" on a
    body-less POST, PUT or PATCH; never signed, as botocore adds it in
    `prepare()` after signing), then the signer's X-Amz-Date,
    x-amz-content-sha256 (a `service` that `is_s3_signing_name`, or a
    `payload` other than `.hashed()`), X-Amz-Security-Token (temporary credentials) and
    Authorization.

    Refuses a malformed method, a `uri` not starting with '/', CR/LF
    anywhere in a header, an `extra` header named Host, Content-Type or
    Content-Length (each has its own argument) or one the signer writes,
    and a `payload` that `AwsPayloadSigning.check` refuses.
    """
    _check_method(method)
    payload.check()
    var headers = _request_headers(endpoint, uri, content_type, extra)
    var target = endpoint.target_for(uri)
    var is_s3 = is_s3_signing_name(service)
    var ctx = SigV4SigningContext(
        cred,
        region,
        service,
        amz_date_from_unix(clock.now_unix_seconds()),
        sign_payload_header=is_s3 or not payload.is_hashed(),
        normalize_path=not is_s3,
        uri_encode_path=not is_s3,
    )
    var signed = sigv4_sign_payload_hash(
        method, target, headers, payload.payload_hash(body), ctx
    )
    var req = _request(method, endpoint, target, headers^, body)
    for i in range(len(signed.headers_to_add)):
        req.headers.append(signed.headers_to_add[i])
    return req^


def build_unsigned_request(
    method: String,
    endpoint: AwsEndpoint,
    uri: String,
    content_type: String,
    body: Span[UInt8, _],
    extra: List[Header],
) raises -> CredentialHttpRequest:
    """The request sent UNSIGNED, as botocore sends an operation its model
    marks anonymous (`authtype` `none`, `auth` `smithy.api#noAuth`).

    Headers, in send order: Host, Content-Type (when not ""), each of
    `extra`, and Content-Length, exactly as `build_sigv4_signed_request`
    sends them before its signature; then nothing: no X-Amz-Date,
    x-amz-content-sha256, X-Amz-Security-Token or Authorization. `body` is
    sent as given, byte for byte.

    Refuses the `extra` headers that builder refuses: CR/LF in a name or
    value, an empty name, a name the signer writes (Authorization,
    X-Amz-Date, X-Amz-Security-Token, x-amz-content-sha256, in any case)
    and Host, Content-Type or Content-Length; and a malformed method, a
    `uri` not starting with '/', and CR/LF in the path or content type.
    """
    _check_method(method)
    var headers = _request_headers(endpoint, uri, content_type, extra)
    return _request(method, endpoint, endpoint.target_for(uri), headers^, body)


def _request_headers(
    endpoint: AwsEndpoint,
    uri: String,
    content_type: String,
    extra: List[Header],
) raises -> List[Header]:
    """The checks of the path, the content type and `extra` both builders
    make, and the headers both send ahead of Content-Length: Host,
    Content-Type (when not "") and each of `extra`. An `extra` header is
    refused for CR/LF in its name or value, an empty name (after trimming
    spaces and tabs), a name the signer writes, in any case
    (`_is_signer_owned_header`), and Host, Content-Type or Content-Length,
    which have their own arguments. The signer refuses the first three too
    (`_canonical_header_pairs`); here they hold for the unsigned request."""
    if not uri.startswith("/"):
        raise Error("an AWS request path does not start with '/'")
    if has_crlf(uri) or has_crlf(content_type):
        raise Error("an AWS request path or content type holds CR or LF")
    var headers = List[Header]()
    headers.append(Header(String("Host"), endpoint.host_header()))
    if content_type.byte_length() > 0:
        headers.append(Header(String("Content-Type"), content_type))
    for i in range(len(extra)):
        if has_crlf(extra[i].name) or has_crlf(extra[i].value):
            raise Error("an AWS request header holds CR or LF")
        var name = _trim_collapse(ascii_lower(extra[i].name))
        if name.byte_length() == 0:
            raise Error("an AWS request header has an empty name")
        if _is_signer_owned_header(name):
            raise Error(
                "the extra header "
                + extra[i].name
                + " is a signature header; the signer writes it"
            )
        if _is_reserved(extra[i].name):
            raise Error(
                "the extra header "
                + extra[i].name
                + " is set by the request builder; pass it as its argument"
            )
        headers.append(extra[i])
    return headers^


def _request(
    method: String,
    endpoint: AwsEndpoint,
    target: String,
    var headers: List[Header],
    body: Span[UInt8, _],
) -> CredentialHttpRequest:
    """`headers`, then Content-Length when the request carries a body (and
    "0" on a body-less POST, PUT or PATCH), and `body`, for `target` at
    `endpoint`."""
    var req = CredentialHttpRequest(
        method, endpoint.scheme, endpoint.host, endpoint.port, target
    )
    req.headers = headers^
    if _sends_body(method, len(body)):
        req.headers.append(Header(String("Content-Length"), String(len(body))))
    req.body = List[UInt8](capacity=len(body))
    req.body.extend(body)
    return req^
