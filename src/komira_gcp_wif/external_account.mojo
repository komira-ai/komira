# =============================================================================
# komira_gcp_wif/external_account.mojo — an `external_account` credentials
#   file read into a komira_gcp_core `AccessTokenFetcher`.
# =============================================================================
#
# An `external_account` file is what Google's workload identity federation
# hands a workload that is not on Google Cloud (a CI job holding an OIDC
# token, a pod holding a projected service-account token):
#
#   {"type": "external_account",
#    "audience": "//iam.googleapis.com/projects/<n>/locations/global/
#                 workloadIdentityPools/<pool>/providers/<provider>",
#    "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
#    "token_url": "https://sts.googleapis.com/v1/token",
#    "service_account_impersonation_url":
#        "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/<account>:generateAccessToken",
#    "credential_source": {"file": "<path>"} or
#                         {"url": "<url>", "headers": {...}},
#                         plus an optional "format":
#                         {"type": "text"} or
#                         {"type": "json", "subject_token_field_name": "<f>"}}
#
# `parse_external_account` reads the file's TEXT; the caller reads the file
# (kci reads the path the provider-standard credentials variable names). This
# package still reads no environment. `ExternalAccountFetcher.fetch` then:
#
#   1. takes the subject token from the file (through komira_gcp_core's
#      `FileSource`) or the URL (one GET with exactly the file's headers)
#      `credential_source` names, as text or as one JSON field;
#   2. exchanges it at the file's `token_url` through sts.mojo's form, with
#      the file's `audience` and the file's `subject_token_type`;
#   3. when the file names a `service_account_impersonation_url`, POSTs
#      `generateAccessToken` there with the federated token as the bearer and
#      returns THAT token; when it names none, returns the federated token.
#
# This follows the reference implementation, Google's auth library for Python
# (`google/auth/external_account.py`, `identity_pool.py`,
# `impersonated_credentials.py`): when impersonating, the exchange asks for
# the `cloud-platform` scope and the impersonation asks for the caller's
# scope. Not read here (each REFUSED by name, never ignored): an AWS source
# (`environment_id`: bind `AwsWifTokenFetcher`), an `executable` source (it
# would run a program), and `workforce_pool_user_project` (a workforce pool's
# exchange carries an extra option this reader does not send).
#
# ⛔ NO TOKEN AND NO BODY IN ANY MESSAGE. A refusal names the file's field, an
# HTTP status, or komira_gcp_core's `parse_gcp_status` text, never a value
# read from the file (its headers can hold a bearer), a subject token, or a
# body byte.
#
# Every endpoint the file names is checked when the file is read, before
# anything is dialed: `token_url` and the impersonation URL are `https` on a
# bare host (`[a-z0-9.-]`, port 443 or none, no user, query or fragment);
# the `credential_source` URL is http or https (a link-local metadata
# service answers in plain http), and each header it names is a token name
# and a value with no control byte.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_datetime import parse_rfc3339
from komira_gcp_core import (
    AccessToken,
    AccessTokenFetcher,
    FileSource,
    WallClock,
    parse_gcp_status,
)
from komira_http_client.client import HttpClient
from komira_http_client.url import Url
from komira_http_core.transport.io_stream import Connector
from komira_json import JsonValue, parse_json_bytes

from ._post import check_host, get, new_runtime, post
from .sign_jwt import JSON_CONTENT_TYPE
from .sts import CLOUD_PLATFORM_SCOPE, exchange_at_sts, sts_exchange_form


comptime EXTERNAL_ACCOUNT_TYPE: String = "external_account"
comptime JWT_SUBJECT_TOKEN_TYPE: String = "urn:ietf:params:oauth:token-type:jwt"
comptime IMPERSONATION_LIFETIME_SECONDS: Int = 3600
"""The impersonated token's lifetime when the file names none (the API's
default, and the reference's)."""
comptime _MIN_LIFETIME_SECONDS: Int = 600
comptime _MAX_LIFETIME_SECONDS: Int = 43200
comptime _GENERATE_ACCESS_TOKEN: String = ":generateAccessToken"
comptime _MAX_DEPTH: Int = 8
comptime _P: String = "komira_gcp_wif: the external_account file "


# =============================================================================
# The file.
# =============================================================================


@fieldwise_init
struct ExternalAccountConfig(Copyable, Movable, Deinitable):
    """An `external_account` file, checked. Not `Writable`: a source header
    can carry a bearer.

    `impersonation_host` is "" when the file names no impersonation URL.
    `source_file` and `source_url` hold exactly one non-empty value.
    `source_json_field` is "" for a `text` subject."""

    var audience: String
    var subject_token_type: String
    var token_host: String
    var token_path: String
    var impersonation_host: String
    var impersonation_path: String
    var impersonation_lifetime_s: Int
    var source_file: String
    var source_url: String
    var source_header_names: List[String]
    var source_header_values: List[String]
    var source_json_field: String

    def impersonates(self) -> Bool:
        return self.impersonation_host.byte_length() > 0


def _string_field(doc: JsonValue, key: String, what: String) raises -> String:
    """`doc[key]`, a non-empty string. `what` names where `key` is."""
    if not doc.has(key):
        raise Error(_P + "has no \"" + what + "\"")
    var v = doc.get(key)
    if not v.is_string():
        raise Error(_P + "has a \"" + what + "\" that is not a string")
    var s = v.as_string()
    if s.byte_length() == 0:
        raise Error(_P + "has an empty \"" + what + "\"")
    return s^


def _https_endpoint(text: String, what: String) raises -> Url:
    """`text` as an `https` URL on a bare host: no user, no port but 443, no
    query, no fragment. A credential is sent to it."""
    var url: Url
    try:
        url = Url.parse(text)
    except:
        raise Error(_P + "has a \"" + what + "\" that is not a URL")
    if not url.is_https():
        raise Error(_P + "has a \"" + what + "\" that is not https")
    if (
        url.userinfo.byte_length() > 0
        or (url.port != UInt16(0) and url.port != UInt16(443))
        or url.query.byte_length() > 0
        or url.fragment.byte_length() > 0
    ):
        raise Error(
            _P + "has a \"" + what + "\" with a user, a port, a query or a"
            " fragment"
        )
    check_host(what, url.host)
    return url^


def _is_token_byte(c: UInt8) -> Bool:
    """RFC 9110 `tchar`."""
    if (
        (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
        or (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
        or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
    ):
        return True
    var punct = String("!#$%&'*+-.^_`|~")
    var pb = punct.as_bytes()
    for i in range(len(pb)):
        if c == pb[i]:
            return True
    return False


def _check_header(name: String, value: String) raises:
    """A source header: a token name the client does not write itself, and a
    value with no control byte but a tab. Neither is quoted on refusal."""
    var n = name.as_bytes()
    if len(n) == 0:
        raise Error(_P + "names an empty credential_source header")
    for i in range(len(n)):
        if not _is_token_byte(n[i]):
            raise Error(
                _P + "names a credential_source header whose name is not an"
                " HTTP token"
            )
    var lower = name.lower()
    if (
        lower == "host"
        or lower == "content-length"
        or lower == "transfer-encoding"
        or lower == "connection"
    ):
        raise Error(
            _P + "names a credential_source header the client writes itself"
        )
    var v = value.as_bytes()
    for i in range(len(v)):
        if (v[i] < UInt8(0x20) and v[i] != UInt8(0x09)) or v[i] == UInt8(0x7F):
            raise Error(
                _P + "names a credential_source header whose value holds a"
                " control byte"
            )


def _lifetime(doc: JsonValue) raises -> Int:
    """`service_account_impersonation.token_lifetime_seconds`, or the
    default; 600 to 43200 as the API allows."""
    if not doc.has(String("service_account_impersonation")):
        return IMPERSONATION_LIFETIME_SECONDS
    var opts = doc.get(String("service_account_impersonation"))
    if not opts.is_object():
        raise Error(
            _P + "has a \"service_account_impersonation\" that is not an object"
        )
    if not opts.has(String("token_lifetime_seconds")):
        return IMPERSONATION_LIFETIME_SECONDS
    var v = opts.get(String("token_lifetime_seconds"))
    if not v.is_integral_number():
        raise Error(
            _P + "has a \"token_lifetime_seconds\" that is not an integer"
        )
    var s = Int(v.as_int64())
    if s < _MIN_LIFETIME_SECONDS or s > _MAX_LIFETIME_SECONDS:
        raise Error(
            _P + "has a \"token_lifetime_seconds\" outside 600 to 43200"
        )
    return s


def parse_external_account(text: String) raises -> ExternalAccountConfig:
    """Read and check an `external_account` file's text.

    Refused, naming the field and never a value: text that is not a JSON
    object; a `type` other than `external_account`; an absent, non-string or
    empty `audience`, `subject_token_type`, `token_url`; an absent or
    non-object `credential_source`, one naming both or neither of `file` and
    `url`, an AWS (`environment_id`) or `executable` one, a bad header or
    `format`; a `workforce_pool_user_project`; and any endpoint that fails
    the checks of this file's header."""
    var b = List[UInt8]()
    b.extend(Span(text.as_bytes()))
    var doc: JsonValue
    try:
        doc = parse_json_bytes(b, _MAX_DEPTH)
    except:
        raise Error(_P + "is not JSON")
    if not doc.is_object():
        raise Error(_P + "is not a JSON object")
    if _string_field(doc, String("type"), String("type")) != EXTERNAL_ACCOUNT_TYPE:
        raise Error(_P + "has a \"type\" other than external_account")
    var audience = _string_field(doc, String("audience"), String("audience"))
    var token_type = _string_field(
        doc, String("subject_token_type"), String("subject_token_type")
    )
    var token_url = _https_endpoint(
        _string_field(doc, String("token_url"), String("token_url")),
        String("token_url"),
    )
    if not doc.has(String("credential_source")):
        raise Error(_P + "has no \"credential_source\"")
    var source = doc.get(String("credential_source"))
    if not source.is_object():
        raise Error(_P + "has a \"credential_source\" that is not an object")
    if doc.has(String("workforce_pool_user_project")):
        raise Error(
            _P + "names a \"workforce_pool_user_project\", which this reader"
            " does not send"
        )

    var imp_host = String("")
    var imp_path = String("")
    if doc.has(String("service_account_impersonation_url")):
        var imp = _https_endpoint(
            _string_field(
                doc,
                String("service_account_impersonation_url"),
                String("service_account_impersonation_url"),
            ),
            String("service_account_impersonation_url"),
        )
        if not imp.path.endswith(_GENERATE_ACCESS_TOKEN):
            raise Error(
                _P + "has a \"service_account_impersonation_url\" that does"
                " not end in :generateAccessToken"
            )
        imp_host = imp.host.copy()
        imp_path = imp.path.copy()
    var lifetime = _lifetime(doc)

    if source.has(String("environment_id")):
        raise Error(
            _P + "has an AWS credential_source (\"environment_id\"); bind"
            " AwsWifTokenFetcher for it"
        )
    if source.has(String("executable")):
        raise Error(
            _P + "has an \"executable\" credential_source, which this reader"
            " does not run"
        )
    var has_file = source.has(String("file"))
    var has_url = source.has(String("url"))
    if has_file and has_url:
        raise Error(_P + "has a credential_source naming both \"file\" and \"url\"")
    if not has_file and not has_url:
        raise Error(_P + "has a credential_source naming neither \"file\" nor \"url\"")
    var source_file = String("")
    var source_url = String("")
    var names = List[String]()
    var values = List[String]()
    if has_file:
        source_file = _string_field(source, String("file"), String("credential_source.file"))
    else:
        source_url = _string_field(source, String("url"), String("credential_source.url"))
        try:
            _ = Url.parse(source_url)
        except:
            raise Error(_P + "has a \"credential_source.url\" that is not an http or https URL")
        if source.has(String("headers")):
            var h = source.get(String("headers"))
            if not h.is_object():
                raise Error(_P + "has a \"credential_source.headers\" that is not an object")
            for i in range(h.num_members()):
                var v = h.value_at(i)
                if not v.is_string():
                    raise Error(
                        _P + "names a credential_source header whose value is"
                        " not a string"
                    )
                var name = h.key_at(i)
                var value = v.as_string()
                _check_header(name, value)
                names.append(name^)
                values.append(value^)

    var json_field = String("")
    if source.has(String("format")):
        var f = source.get(String("format"))
        if not f.is_object():
            raise Error(_P + "has a \"credential_source.format\" that is not an object")
        var kind = String("text")
        if f.has(String("type")):
            kind = _string_field(f, String("type"), String("credential_source.format.type"))
        if kind == "json":
            json_field = _string_field(
                f,
                String("subject_token_field_name"),
                String("credential_source.format.subject_token_field_name"),
            )
        elif kind != "text":
            raise Error(
                _P + "has a \"credential_source.format.type\" other than text"
                " or json"
            )

    return ExternalAccountConfig(
        audience=audience^,
        subject_token_type=token_type^,
        token_host=token_url.host.copy(),
        token_path=token_url.path.copy(),
        impersonation_host=imp_host^,
        impersonation_path=imp_path^,
        impersonation_lifetime_s=lifetime,
        source_file=source_file^,
        source_url=source_url^,
        source_header_names=names^,
        source_header_values=values^,
        source_json_field=json_field^,
    )


# =============================================================================
# The pure parts of the wire.
# =============================================================================


def subject_token_from(raw: List[UInt8], json_field: String) raises -> String:
    """The subject token in what the source gave: the whole text when
    `json_field` is "", else that field of a JSON object, a non-empty
    string. The text is used as given (the reference strips nothing).
    Refused without quoting a byte of `raw` or the field's name."""
    if json_field.byte_length() == 0:
        var text: String
        try:
            text = String(StringSlice(from_utf8=Span(raw)))
        except:
            raise Error("komira_gcp_wif: the subject token is not UTF-8")
        if text.byte_length() == 0:
            raise Error("komira_gcp_wif: the subject token is empty")
        return text^
    var doc: JsonValue
    try:
        doc = parse_json_bytes(raw, _MAX_DEPTH)
    except:
        raise Error("komira_gcp_wif: the subject token source is not JSON")
    if not doc.is_object() or not doc.has(json_field):
        raise Error(
            "komira_gcp_wif: the subject token source has no field named by"
            " subject_token_field_name"
        )
    var v = doc.get(json_field)
    if not v.is_string() or v.as_string().byte_length() == 0:
        raise Error(
            "komira_gcp_wif: the subject token source's field named by"
            " subject_token_field_name is not a non-empty string"
        )
    return v.as_string()


def generate_access_token_body(scope: String, lifetime_s: Int) raises -> String:
    """`{"scope":["<scope>"],"lifetime":"<n>s"}`: the generateAccessToken
    request (no `delegates`: the file names none)."""
    var scopes = JsonValue.empty_array()
    scopes.push(JsonValue.from_string(scope.copy()))
    var b = JsonValue.empty_object()
    b.set_member(String("scope"), scopes^)
    b.set_member(
        String("lifetime"), JsonValue.from_string(String(lifetime_s) + "s")
    )
    return b.serialize()


def parse_generate_access_token_response(
    body: List[UInt8], wall_now_s: Int64, now_ms: Int64
) raises -> AccessToken:
    """A 2xx generateAccessToken answer (`{"accessToken", "expireTime"}`)
    read into an `AccessToken`. `expireTime` is an RFC 3339 wall time, so the
    token expires `expireTime - wall_now_s` seconds after `now_ms` (the
    monotonic instant the cache compares against). Refused, naming the field
    and never its value: a body that is not a JSON object, an absent or empty
    `accessToken`, an `expireTime` that is absent or not RFC 3339, and one
    not after `wall_now_s`."""
    var doc = parse_json_bytes(body, _MAX_DEPTH)
    if not doc.is_object():
        raise Error(
            "komira_gcp_wif: the generateAccessToken answer is not a JSON object"
        )
    if not doc.has(String("accessToken")) or not doc.get(
        String("accessToken")
    ).is_string():
        raise Error(
            "komira_gcp_wif: the generateAccessToken answer has no accessToken"
            " string"
        )
    var token = doc.get(String("accessToken")).as_string()
    if token.byte_length() == 0:
        raise Error(
            "komira_gcp_wif: the generateAccessToken answer's accessToken is"
            " empty"
        )
    if not doc.has(String("expireTime")) or not doc.get(
        String("expireTime")
    ).is_string():
        raise Error(
            "komira_gcp_wif: the generateAccessToken answer has no expireTime"
            " string"
        )
    var expire_s: Int
    try:
        expire_s = parse_rfc3339(doc.get(String("expireTime")).as_string()).seconds
    except:
        raise Error(
            "komira_gcp_wif: the generateAccessToken answer's expireTime is"
            " not RFC 3339"
        )
    var expires_in = Int64(expire_s) - wall_now_s
    if expires_in <= 0:
        raise Error(
            "komira_gcp_wif: the generateAccessToken answer's expireTime is not"
            " in the future"
        )
    return AccessToken.expiring_in(token^, now_ms, expires_in)


# =============================================================================
# The fetcher.
# =============================================================================


struct ExternalAccountFetcher[
    CS: Connector,
    C: Connector,
    F: FileSource & Movable & Deinitable,
    W: WallClock,
](AccessTokenFetcher, Movable, Deinitable):
    """An `external_account` file's credential flow, one token per `fetch`.
    Wrap it in komira_gcp_core's `CachingTokenSource` and it is a
    `GcpTokenSource`.

    - `CS`: the connector the `credential_source` URL is fetched over
      (plaintext for an `http` URL, TLS for `https`: a `SchemeConnector`
      chosen from the URL's scheme). Never dialed for a file source.
    - `C`: the TLS connector the token URL and the impersonation URL are
      dialed over, one client each.
    - `F`: where a file source is read (`ProcessFiles`, or `MapFiles` in a
      test). Read once per fetch, so a rotated token file is used.
    - `W`: the wall clock an impersonated token's `expireTime` is read
      against."""

    var _config: ExternalAccountConfig
    var _subject: HttpClient[Self.CS]
    var _sts: HttpClient[Self.C]
    var _iam: HttpClient[Self.C]
    var _rt: BlockingRuntime[NoopSink]
    var _files: Self.F
    var _wall: Self.W
    var _scope: String

    def __init__(
        out self,
        var config: ExternalAccountConfig,
        var subject_client: HttpClient[Self.CS],
        var sts: HttpClient[Self.C],
        var iam: HttpClient[Self.C],
        var files: Self.F,
        var wall: Self.W,
    ) raises:
        self._config = config^
        self._subject = subject_client^
        self._sts = sts^
        self._iam = iam^
        self._rt = new_runtime()
        self._files = files^
        self._wall = wall^
        self._scope = String(CLOUD_PLATFORM_SCOPE)

    def set_scope(mut self, var scope: String):
        """The OAuth scope the returned token is asked for (default
        `cloud-platform`). When the file impersonates, the exchange still
        asks for `cloud-platform` and this scope goes to generateAccessToken,
        as the reference does."""
        self._scope = scope^

    def _subject_token(mut self) raises -> String:
        var raw = List[UInt8]()
        if self._config.source_file.byte_length() > 0:
            var text: String
            try:
                text = self._files.read(self._config.source_file)
            except:
                raise Error(
                    "komira_gcp_wif: the credential_source file cannot be read"
                )
            raw.extend(Span(text.as_bytes()))
        else:
            var reply = get(
                self._subject,
                self._rt,
                Url.parse(self._config.source_url),
                self._config.source_header_names,
                self._config.source_header_values,
            )
            if not reply.is_success():
                raise Error(
                    "komira_gcp_wif: the credential_source url answered HTTP "
                    + String(reply.status)
                )
            raw = reply.body.copy()
        return subject_token_from(raw, self._config.source_json_field)

    def fetch(mut self, now_ms: Int64) raises -> AccessToken:
        var subject = self._subject_token()
        var sts_scope = self._scope.copy()
        if self._config.impersonates():
            sts_scope = String(CLOUD_PLATFORM_SCOPE)
        var federated = exchange_at_sts(
            self._sts,
            self._rt,
            self._config.token_host,
            self._config.token_path,
            sts_exchange_form(
                self._config.audience,
                sts_scope,
                subject,
                self._config.subject_token_type,
            ),
            String("external account federation"),
            now_ms,
        )
        if not self._config.impersonates():
            return federated^
        var reply = post(
            self._iam,
            self._rt,
            self._config.impersonation_host,
            self._config.impersonation_path,
            String(JSON_CONTENT_TYPE),
            String("Bearer ") + federated.token,
            generate_access_token_body(
                self._scope, self._config.impersonation_lifetime_s
            ),
        )
        if not reply.is_success():
            raise Error(
                "komira_gcp_wif: service account impersonation refused: "
                + parse_gcp_status(
                    String("POST"),
                    String("IAMCredentials.GenerateAccessToken"),
                    reply.status,
                    reply.body,
                ).message()
            )
        return parse_generate_access_token_response(
            reply.body, self._wall.now_unix_seconds(), now_ms
        )
