# =============================================================================
# komira_gcp_wif/sts.mojo — leg 1: the `aws1` subject token for a Google
#   access token, as a komira_gcp_core `AccessTokenFetcher`.
# =============================================================================
#
# `AwsWifTokenFetcher` is ONE round trip to Google's Security Token Service
# (`POST https://sts.googleapis.com/v1/token`, RFC 8693 token exchange). Wrap
# it in komira_gcp_core's `CachingTokenSource` and it is a `GcpTokenSource`:
# the same seam every generated `komira_gcp_<service>` client takes its bearer
# token from, so a federated token is used, cached and refreshed exactly like
# any other Google token.
#
# The form body follows the reference implementation (`google/oauth2/sts.py`,
# `Client.exchange_token`): the fields in its order (`grant_type`,
# `audience`, `scope`, `requested_token_type`, `subject_token`,
# `subject_token_type`), every value form-encoded (`urllib.parse.urlencode`).
# That includes the subject token, which aws_subject.mojo has ALREADY
# percent-encoded once, so its `%` bytes go out as `%25`. Google decodes both
# layers; that is what the reference sends.
#
# ⛔ THE STATUS DECIDES SUCCESS, AND A FAILURE BODY IS NEVER ECHOED. A non-2xx
# answer raises before the body is read for a token, so an error body that
# happens to carry an `access_token` field cannot be mistaken for success.
# The raised text comes from komira_gcp_core's `parse_gcp_status`: the HTTP
# status, the derived code and byte counts, never a body byte (a 4xx from a
# token endpoint can carry the credential it rejected).
#
# Configuration is by parameter. The AWS credential comes from a komira_aws_core
# `AwsCredsSource`, which is where the AWS SDK's standard chain (environment,
# shared files, container and instance endpoints) is read when a caller binds
# `DefaultChainCredsSource`. This file reads no environment.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_aws_core import AwsClock, AwsCredsSource, amz_date_from_unix, uri_encode
from komira_gcp_core import AccessToken, AccessTokenFetcher, parse_gcp_status
from komira_http_client.client import HttpClient
from komira_http_core.transport.io_stream import Connector
from komira_json import parse_json_bytes

from ._post import new_runtime, post
from .aws_subject import AWS_SUBJECT_TOKEN_TYPE, aws1_subject_token, aws_sts_host


comptime GOOGLE_STS_HOST: String = "sts.googleapis.com"
comptime GOOGLE_STS_PATH: String = "/v1/token"
comptime TOKEN_EXCHANGE_GRANT: String = (
    "urn:ietf:params:oauth:grant-type:token-exchange"
)
comptime ACCESS_TOKEN_TYPE: String = (
    "urn:ietf:params:oauth:token-type:access_token"
)
comptime CLOUD_PLATFORM_SCOPE: String = (
    "https://www.googleapis.com/auth/cloud-platform"
)
comptime FORM_CONTENT_TYPE: String = "application/x-www-form-urlencoded"
comptime _MAX_RESPONSE_DEPTH: Int = 8


def sts_exchange_form(
    audience: String, scope: String, subject_token: String
) -> String:
    """The token-exchange form body. Every value is percent-encoded with no
    byte kept but RFC 3986 unreserved ones, which for these values is what
    `urllib.parse.urlencode` writes (none of them holds a space)."""
    var out = String("grant_type=") + uri_encode(String(TOKEN_EXCHANGE_GRANT))
    out += String("&audience=") + uri_encode(audience)
    out += String("&scope=") + uri_encode(scope)
    out += String("&requested_token_type=") + uri_encode(String(ACCESS_TOKEN_TYPE))
    out += String("&subject_token=") + uri_encode(subject_token)
    out += String("&subject_token_type=") + uri_encode(String(AWS_SUBJECT_TOKEN_TYPE))
    return out^


def parse_sts_token_response(body: List[UInt8], now_ms: Int64) raises -> AccessToken:
    """Read a 2xx token-exchange answer (`{"access_token", "issued_token_type",
    "token_type", "expires_in"}`) into an `AccessToken` expiring `expires_in`
    seconds after `now_ms`.

    Refused, naming the field and never its value: a body that is not a JSON
    object, an `access_token` that is absent, not a string or empty, and an
    `expires_in` that is absent, not an integer or not positive."""
    var doc = parse_json_bytes(body, _MAX_RESPONSE_DEPTH)
    if not doc.is_object():
        raise Error("komira_gcp_wif: the STS answer is not a JSON object")
    if not doc.has(String("access_token")) or not doc.get(
        String("access_token")
    ).is_string():
        raise Error("komira_gcp_wif: the STS answer has no access_token string")
    var token = doc.get(String("access_token")).as_string()
    if token.byte_length() == 0:
        raise Error("komira_gcp_wif: the STS answer's access_token is empty")
    if not doc.has(String("expires_in")) or not doc.get(
        String("expires_in")
    ).is_integral_number():
        raise Error("komira_gcp_wif: the STS answer has no integer expires_in")
    var expires_in = doc.get(String("expires_in")).as_int64()
    if expires_in <= 0:
        raise Error("komira_gcp_wif: the STS answer's expires_in is not positive")
    return AccessToken.expiring_in(token^, now_ms, expires_in)


struct AwsWifTokenFetcher[
    C: Connector,
    S: AwsCredsSource,
    W: AwsClock & Movable & Deinitable,
](AccessTokenFetcher, Movable, Deinitable):
    """Leg 1: sign `GetCallerIdentity` with the credential `S` gives, exchange
    it at Google STS, return the federated access token.

    - `C`: the connector the STS client dials (`TlsConnector[KernelTcpConnector]`
      in production, `ScriptedConnector` in a test).
    - `S`: where the AWS credential comes from, asked once per fetch so a
      rotated role credential is used as soon as the source has it.
    - `W`: the WALL clock the signature is dated with (`SystemAwsClock`, or a
      `FixedClock` in a test). The `now_ms` `fetch` is given is the
      monotonic one the token cache compares against; the two are separate on
      purpose."""

    var _client: HttpClient[Self.C]
    var _rt: BlockingRuntime[NoopSink]
    var _creds: Self.S
    var _wall: Self.W
    var _region: String
    var _audience: String
    var _scope: String
    var _sts_host: String

    def __init__(
        out self,
        var client: HttpClient[Self.C],
        var creds: Self.S,
        var wall: Self.W,
        var region: String,
        var audience: String,
    ) raises:
        """`audience` is the provider's full resource name
        (`//iam.googleapis.com/projects/.../providers/<provider>`). An empty
        audience and a malformed region are refused here, before anything
        can be dialed."""
        if audience.byte_length() == 0:
            raise Error("komira_gcp_wif: the workload identity audience is empty")
        _ = aws_sts_host(region)
        self._client = client^
        self._rt = new_runtime()
        self._creds = creds^
        self._wall = wall^
        self._region = region^
        self._audience = audience^
        self._scope = String(CLOUD_PLATFORM_SCOPE)
        self._sts_host = String(GOOGLE_STS_HOST)

    def set_scope(mut self, var scope: String):
        """The OAuth scope the federated token is asked for
        (default `cloud-platform`)."""
        self._scope = scope^

    def set_sts_host(mut self, var host: String):
        """The STS host (default `sts.googleapis.com`): an emulator's, or a
        private endpoint's."""
        self._sts_host = host^

    def audience(self) -> String:
        return self._audience.copy()

    def fetch(mut self, now_ms: Int64) raises -> AccessToken:
        var amz_date = amz_date_from_unix(self._wall.now_unix_seconds())
        var subject = aws1_subject_token(
            self._creds.credentials(), self._region, self._audience, amz_date
        )
        var reply = post(
            self._client,
            self._rt,
            self._sts_host,
            String(GOOGLE_STS_PATH),
            String(FORM_CONTENT_TYPE),
            String(""),
            sts_exchange_form(self._audience, self._scope, subject),
        )
        if not reply.is_success():
            raise Error(
                "komira_gcp_wif: AWS to Google federation refused: "
                + parse_gcp_status(
                    String("POST"), String("sts.v1.token"), reply.status, reply.body
                ).message()
            )
        return parse_sts_token_response(reply.body, now_ms)
