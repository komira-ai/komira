# =============================================================================
# komira_gcp_wif/sign_jwt.mojo — leg 2: a self-signed service-account JWT
#   through IAM Credentials `signJwt`, authorized by a `GcpTokenSource`.
# =============================================================================
#
# `WifTokenMinter` turns a Google access token into a JWT signed BY a service
# account: `POST https://iamcredentials.googleapis.com/v1/projects/-/
# serviceAccounts/<account>:signJwt` with the claims as `payload`. A receiver
# pinned to that account (an API gateway whose issuer and key set are the
# account's) accepts exactly this token; an ID token from `generateIdToken`
# has Google as its issuer and would not match.
#
# The bearer comes from a komira_gcp_core `GcpTokenSource`. Bound to
# `CachingTokenSource[AwsWifTokenFetcher[...]]` it is the AWS federation of
# sts.mojo, and the two legs compose through the same seam every generated
# Google client uses. The bearer and the subject are different principals: the
# federated identity AUTHORIZES the signing (it needs
# `roles/iam.serviceAccountTokenCreator` on the account), and the account in
# the PATH is who the token is FROM.
#
# ⛔ ORDER IS THE CONTRACT. `mint_delivery_jwt` checks its own inputs, then
# asks the token source, then dials IAM Credentials. A token source that
# raises (leg 1 refused, or answered with no token) stops the mint before
# anything is sent to IAM Credentials; a test asserts that connector is never
# dialed.
#
# ⛔ NO TOKEN IN ANY MESSAGE. Neither the federated token nor the signed JWT is
# stored on the minter, and every raised text is built from statuses, codes
# and byte counts (komira_gcp_core's `parse_gcp_status`), never from a body.
#
# `exp` is always set: `signJwt` signs whatever claims it is given, and a
# payload without `exp` would be a token that never expires.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_aws_core import AwsClock
from komira_gcp_core import GcpTokenSource, parse_gcp_status
from komira_http_client.client import HttpClient
from komira_http_core.transport.io_stream import Connector
from komira_json import JsonValue, parse_json_bytes

from ._post import check_host, new_runtime, post


comptime IAMCREDENTIALS_HOST: String = "iamcredentials.googleapis.com"
comptime SIGNED_JWT_TTL_SECONDS: Int = 600
"""The signed JWT's lifetime: `exp = iat + 600`."""
comptime JSON_CONTENT_TYPE: String = "application/json; charset=utf-8"
comptime _MAX_RESPONSE_DEPTH: Int = 8


def _check_service_account(service_account: String) raises:
    """A service account email or unique id: non-empty, and only bytes that
    cannot leave the path segment it is spliced into (`[A-Za-z0-9@._-]`)."""
    var b = service_account.as_bytes()
    if len(b) == 0:
        raise Error("komira_gcp_wif: the service account is empty")
    for i in range(len(b)):
        var c = b[i]
        var ok = (
            (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
            or (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
            or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
            or c == UInt8(ord("@"))
            or c == UInt8(ord("."))
            or c == UInt8(ord("_"))
            or c == UInt8(ord("-"))
        )
        if not ok:
            raise Error(
                "komira_gcp_wif: the service account holds a byte outside"
                " [A-Za-z0-9@._-]"
            )


def sign_jwt_path(service_account: String) raises -> String:
    """`/v1/projects/-/serviceAccounts/<account>:signJwt`."""
    _check_service_account(service_account)
    return (
        String("/v1/projects/-/serviceAccounts/")
        + service_account
        + String(":signJwt")
    )


def sign_jwt_claims(
    service_account: String, audience: String, issued_at_s: Int
) raises -> String:
    """The claims as compact JSON: `iss` and `sub` the account (that is what
    self-signed means), `aud`, `iat`, and `exp = iat + SIGNED_JWT_TTL_SECONDS`."""
    var c = JsonValue.empty_object()
    c.set_member(String("iss"), JsonValue.from_string(service_account.copy()))
    c.set_member(String("sub"), JsonValue.from_string(service_account.copy()))
    c.set_member(String("aud"), JsonValue.from_string(audience.copy()))
    c.set_member(String("iat"), JsonValue.from_i64(Int64(issued_at_s)))
    c.set_member(
        String("exp"),
        JsonValue.from_i64(Int64(issued_at_s + SIGNED_JWT_TTL_SECONDS)),
    )
    return c.serialize()


def sign_jwt_request_body(claims: String) raises -> String:
    """`{"payload":"<claims>"}`: the claims are a JSON STRING here, so they
    are escaped a second time. That is the API's shape, not an accident."""
    var b = JsonValue.empty_object()
    b.set_member(String("payload"), JsonValue.from_string(claims.copy()))
    return b.serialize()


def parse_sign_jwt_response(body: List[UInt8]) raises -> String:
    """The `signedJwt` of a 2xx `signJwt` answer (`{"keyId", "signedJwt"}`).
    Refused, never quoting the body, when it is not a JSON object or has no
    non-empty `signedJwt` string."""
    var doc = parse_json_bytes(body, _MAX_RESPONSE_DEPTH)
    if not doc.is_object():
        raise Error("komira_gcp_wif: the signJwt answer is not a JSON object")
    if not doc.has(String("signedJwt")) or not doc.get(String("signedJwt")).is_string():
        raise Error("komira_gcp_wif: the signJwt answer has no signedJwt string")
    var jwt = doc.get(String("signedJwt")).as_string()
    if jwt.byte_length() == 0:
        raise Error("komira_gcp_wif: the signJwt answer's signedJwt is empty")
    return jwt^


struct WifTokenMinter[
    C: Connector,
    T: GcpTokenSource,
    W: AwsClock & Movable & Deinitable,
](Movable, Deinitable):
    """Mint a JWT self-signed by a service account, authorized by the bearer
    `T` gives.

    - `C`: the connector the IAM Credentials client dials. Its own client,
      not the token source's: "IAM Credentials was never dialed" is then a
      connector that saw no bytes, which a test can check without trusting
      the minter's report.
    - `T`: the bearer's source (`CachingTokenSource[AwsWifTokenFetcher]` for
      AWS federation, or any other `GcpTokenSource`).
    - `W`: the wall clock `iat` is read from.

    ⚠ A cached bearer the server stops accepting is not dropped here:
    `GcpTokenSource` has no way to say so, and a `CachingTokenSource` keeps
    serving its token until the refresh margin. An HTTP 401 from signJwt
    raises with `bearer rejected (HTTP 401)` in the text; a caller that sees
    it calls `tokens().invalidate()` (on a `CachingTokenSource`) so the next
    mint exchanges again. Any other refusal leaves the token in place."""

    var _iam: HttpClient[Self.C]
    var _rt: BlockingRuntime[NoopSink]
    var _tokens: Self.T
    var _wall: Self.W
    var _iam_host: String

    def __init__(
        out self, var iam: HttpClient[Self.C], var tokens: Self.T, var wall: Self.W
    ) raises:
        self._iam = iam^
        self._rt = new_runtime()
        self._tokens = tokens^
        self._wall = wall^
        self._iam_host = String(IAMCREDENTIALS_HOST)

    def set_iam_host(mut self, var host: String) raises:
        """The IAM Credentials host (default
        `iamcredentials.googleapis.com`). Refused unless it is a non-empty run
        of `[a-z0-9.-]`: the bearer is sent to it."""
        check_host(String("IAM Credentials"), host)
        self._iam_host = host^

    def tokens(mut self) -> ref [self._tokens] Self.T:
        """The bearer's source (a caller drops a cached token through it)."""
        return self._tokens

    def mint_delivery_jwt(
        mut self, service_account: String, jwt_audience: String
    ) raises -> String:
        """The signed JWT for `jwt_audience`, or a raise. Never "": an empty
        token would reach the receiver as an unauthenticated request, and its
        refusal would read as the receiver's fault rather than ours."""
        var path = sign_jwt_path(service_account)
        if jwt_audience.byte_length() == 0:
            raise Error("komira_gcp_wif: the JWT audience is empty")
        var bearer = self._tokens.access_token()
        if bearer.byte_length() == 0:
            raise Error("komira_gcp_wif: the token source returned an empty token")
        var claims = sign_jwt_claims(
            service_account, jwt_audience, self._wall.now_unix_seconds()
        )
        var reply = post(
            self._iam,
            self._rt,
            self._iam_host,
            path,
            String(JSON_CONTENT_TYPE),
            String("Bearer ") + bearer,
            sign_jwt_request_body(claims),
        )
        if not reply.is_success():
            var what = String("komira_gcp_wif: signJwt refused: ")
            if reply.status == 401:
                what = String(
                    "komira_gcp_wif: signJwt refused, bearer rejected (HTTP 401;"
                    " drop the cached token through tokens().invalidate()): "
                )
            raise Error(
                what
                + parse_gcp_status(
                    String("POST"),
                    String("IAMCredentials.SignJwt"),
                    reply.status,
                    reply.body,
                ).message()
            )
        return parse_sign_jwt_response(reply.body)
