# =============================================================================
# komira_gcp_wif/aws_subject.mojo — Google's `aws1` subject token.
# =============================================================================
#
# An AWS workload proves who it is to Google by handing Google's STS a
# SigV4-signed `GetCallerIdentity` request that it never sends itself. Google
# issues that request to AWS; the ARN AWS answers with is the identity, and the
# workload identity pool provider's attribute condition decides whether to
# accept it. Nothing long-lived leaves the AWS account: the signature expires
# with its `x-amz-date` window.
#
# This file follows the reference implementation, Google's auth library for
# Python (`google/auth/aws.py`, `RequestSigner.get_request_options` and
# `Credentials.retrieve_subject_token`), field by field:
#
#   * the request is `POST https://sts.<region>.amazonaws.com
#     ?Action=GetCallerIdentity&Version=2011-06-15` with an empty body;
#   * it is signed over `host`, `x-amz-date` and, for a temporary credential,
#     `x-amz-security-token`, with the service scope `sts`;
#   * `x-goog-cloud-target-resource` (the provider's full resource name) is
#     added to the header list AFTER signing, so it is sent and NOT signed.
#     Google reads it itself and does not forward it to AWS; signing it would
#     name a header in `SignedHeaders` that AWS is never given, and AWS would
#     answer `SignatureDoesNotMatch`. The audience is still bound: it is also
#     the exchange's `audience` field, and the provider only accepts tokens
#     its own configuration names;
#   * the header list is in the reference's order: `Authorization`, `host`,
#     `x-amz-date`, `x-amz-security-token` (when there is one),
#     `x-goog-cloud-target-resource`;
#   * the token is that request as compact JSON with sorted object keys
#     (`headers`, `method`, `url`), percent-encoded with `/` left as is
#     (Python's `urllib.parse.quote` default).
#
# The token is percent-encoded here, and the exchange form-encodes it AGAIN
# (sts.mojo). Both layers are the reference's; removing either one changes
# what Google decodes.
#
# Pure: the signing time is a parameter and nothing here opens a socket or
# reads the environment.
# =============================================================================

from komira_aws_core import (
    EMPTY_PAYLOAD_SHA256,
    AwsCredential,
    Header,
    SigV4SigningContext,
    sigv4_sign_payload_hash,
    uri_encode,
)
from komira_json import JsonValue


comptime AWS_SUBJECT_TOKEN_TYPE: String = (
    "urn:ietf:params:aws:token-type:aws4_request"
)
"""The STS `subject_token_type` of an `aws1` subject token."""

comptime GET_CALLER_IDENTITY_QUERY: String = (
    "Action=GetCallerIdentity&Version=2011-06-15"
)
"""The query of the signed request. Both parameters are part of the
signature (they are in the canonical query)."""

comptime AWS_STS_SERVICE: String = "sts"
"""The SigV4 service scope. A wrong one is a signature AWS rejects, which
Google reports as a subject-token error naming neither."""

comptime TARGET_RESOURCE_HEADER: String = "x-goog-cloud-target-resource"
"""The header carrying the provider's resource name. Sent, never signed."""


def aws_sts_host(region: String) raises -> String:
    """The regional AWS STS host the signed request names,
    `sts.<region>.amazonaws.com`.

    The region is refused unless it is a non-empty run of `[a-z0-9-]`: it is
    spliced into the host Google will call, so a `.`, `/`, `#` or `@` in it
    would point Google's request somewhere else."""
    var b = region.as_bytes()
    if len(b) == 0:
        raise Error("komira_gcp_wif: the AWS region is empty")
    for i in range(len(b)):
        var c = b[i]
        var ok = (
            (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
            or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
            or c == UInt8(ord("-"))
        )
        if not ok:
            raise Error(
                "komira_gcp_wif: the AWS region holds a byte outside [a-z0-9-]"
            )
    return String("sts.") + region + String(".amazonaws.com")


struct Aws1SignedRequest(Copyable, Movable, Deinitable):
    """The signed `GetCallerIdentity` request an `aws1` subject token
    describes.

    - `url`: `https://sts.<region>.amazonaws.com?Action=...&Version=...`.
    - `headers`: the header list, in the reference's order, names as the
      reference spells them.
    - `canonical_request`, `signed_headers`: what was signed, for tests and
      diagnostics. Neither holds the secret key; `headers` holds the session
      token, so this value is a credential and is not `Writable`."""

    var url: String
    var headers: List[Header]
    var canonical_request: String
    var signed_headers: String

    def __init__(
        out self,
        var url: String,
        var headers: List[Header],
        var canonical_request: String,
        var signed_headers: String,
    ):
        self.url = url^
        self.headers = headers^
        self.canonical_request = canonical_request^
        self.signed_headers = signed_headers^

    def to_json(self) raises -> String:
        """The request as compact JSON with sorted object keys:
        `{"headers":[{"key":..,"value":..},...],"method":"POST","url":..}`."""
        var list = JsonValue.empty_array()
        for i in range(len(self.headers)):
            var h = JsonValue.empty_object()
            h.set_member(String("key"), JsonValue.from_string(self.headers[i].name.copy()))
            h.set_member(
                String("value"), JsonValue.from_string(self.headers[i].value.copy())
            )
            list.push(h^)
        var doc = JsonValue.empty_object()
        doc.set_member(String("headers"), list^)
        doc.set_member(String("method"), JsonValue.from_string(String("POST")))
        doc.set_member(String("url"), JsonValue.from_string(self.url.copy()))
        return doc.serialize()

    def subject_token(self) raises -> String:
        """The `aws1` subject token: `to_json()`, percent-encoded with `/`
        kept (RFC 3986 unreserved bytes and `/` are left as they are)."""
        return uri_encode(self.to_json(), keep_slash=True)


def aws1_signed_request(
    cred: AwsCredential, region: String, audience: String, amz_date: String
) raises -> Aws1SignedRequest:
    """Sign `GetCallerIdentity` for `region` at `amz_date`
    ("YYYYMMDDTHHMMSSZ", UTC) and attach `audience` as the unsigned
    `x-goog-cloud-target-resource`.

    `audience` is the workload identity pool provider's full resource name,
    `//iam.googleapis.com/projects/<number>/locations/global/
    workloadIdentityPools/<pool>/providers/<provider>`; it is refused when
    empty."""
    if audience.byte_length() == 0:
        raise Error("komira_gcp_wif: the workload identity audience is empty")
    var host = aws_sts_host(region)
    var to_sign = List[Header]()
    to_sign.append(Header(String("host"), host.copy()))
    var ctx = SigV4SigningContext(cred, region, String(AWS_STS_SERVICE), amz_date)
    var signed = sigv4_sign_payload_hash(
        String("POST"),
        String("/?") + GET_CALLER_IDENTITY_QUERY,
        to_sign,
        String(EMPTY_PAYLOAD_SHA256),
        ctx,
    )

    var headers = List[Header]()
    headers.append(Header(String("Authorization"), signed.authorization.copy()))
    headers.append(Header(String("host"), host.copy()))
    headers.append(Header(String("x-amz-date"), amz_date.copy()))
    if cred.has_session_token():
        headers.append(
            Header(String("x-amz-security-token"), cred.session_token.copy())
        )
    headers.append(Header(String(TARGET_RESOURCE_HEADER), audience.copy()))

    var url = String("https://") + host + String("?") + GET_CALLER_IDENTITY_QUERY
    return Aws1SignedRequest(
        url^, headers^, signed.canonical_request.copy(), signed.signed_headers.copy()
    )


def aws1_subject_token(
    cred: AwsCredential, region: String, audience: String, amz_date: String
) raises -> String:
    """`aws1_signed_request(...).subject_token()`."""
    return aws1_signed_request(cred, region, audience, amz_date).subject_token()
