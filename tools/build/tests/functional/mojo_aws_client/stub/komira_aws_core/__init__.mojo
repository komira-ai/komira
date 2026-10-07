"""A stub `komira_aws_core` for the mojo_aws_client fixture.

The real core is komira//src/komira_aws_core, and generated code is built
against it in the komira cell (the AWS conformance driver,
komira//tools/build/proto-codegen). A library of this cell cannot depend
on it (a mojo_library of another cell carries another cell's MojoPkgTSet
type), and nothing generates this file: it is kept by hand, in step with
the names and signatures the generator imports for an awsJson module
(emit_aws/mod.rs AWS_IMPORTS: the `Always` and `PureOnly` rows, and the
`ClientOnly` rows below). It cannot fall behind that table unnoticed: the GetLogEvents
clients of this package (pure) and of ../aws_client_mode (client) are
compiled against it, from the import block the generator writes out of
AWS_IMPORTS, so a name that table adds to either mode and this file lacks
fails those builds.

Of the pure half only what the fixture's GetLogEvents client calls is
implemented (`AwsRequest`, `AwsResponse` and the scalar `aws_json_*`
encoders); every other name raises or answers empty, so a test that came to
depend on one would fail rather than pass on a stand-in. Bodies are bytes,
as in the real core; `body_text` here refuses any non-ASCII byte rather
than validating UTF-8.

The client half (the end of this file): `AwsCredential`, `AwsCredsSource`,
`AwsEndpoint` (with `with_host_prefix`), `AwsRetryQuota`, `Header`,
`HttpResult`, `AwsErrorInfo`,
`aws_json_error_info`, `resolve_endpoint`, `send_sigv4_signed_request`,
`AwsClock`, `AwsHttpTransport`, `CredentialHttpRequest`,
`aws_request_is_conditional` and `send_sigv4_signed_request_with` have the
real core's types and signatures (bar the last's defaulted payload-signing
argument, which no generated code passes, and `CredentialHttpRequest`'s
methods, of which only `header` and `body_text` are here), and behave as
the real ones do for what a generated client calls (`AwsRetryQuota` here is
not a komira_retry budget: it starts at the real one's 500 and spends);
`AwsEndpoint.https` checks nothing of the host. The seam types
`send_sigv4_signed_request_with` takes from komira_retry come from the stub
komira_retry beside this one. The real
`send_sigv4_signed_request` is komira//src/komira_aws_core/aws_send.mojo
(a connector factory, standard-mode retries, the signed request of
signed_request.mojo); signed_request.mojo's header states the signature,
and this one keeps it, or both change together.

`send_sigv4_signed_request` is a test double, not a transport. It refuses
what the real request builder refuses of its arguments (an `extra` header
named Host, Content-Type or Content-Length, in any case; CR or LF in a
header, the path or the content type), calls the client's connector
factory once, signs nothing, sends nothing and never retries, so it
spends nothing from the retry quota. It answers with one `x-stub-*` header
per argument it was given (of the HTTP config, its `context_ceiling_us` and
`request_timeout_us`; of the credential, the access key id and whether a
session token is set, never a secret; of the retry quota, what it holds;
`s3_200_error` as "true" or "false"), the request body as
`x-stub-body` (ASCII only), then the `extra` headers as given, so that a
caller's test can read what the generated `send` hands the transport. The
status and body come from the endpoint host: `status-<NNN>.invalid`
answers NNN with an awsJson error body (`__type`, `message` and a detail
member no error should echo), `status-<NNN>-html.invalid` answers NNN with
a non-JSON body, `status-<NNN>-errortype.invalid` answers NNN with the code
only in an `X-Amzn-Errortype` header (the body has a message and no
`__type`) and an `x-amzn-RequestId`, and any other host answers 200 with
`{"nextForwardToken":"f/1","events":[]}`.

`send_sigv4_signed_request_with` is a test double too, over the seams it is
given: it sends ONE unsigned request through the caller's transport and
answers the transport's response with what it was given added as
`x-stub-*` headers (its docstring lists them).

The error readers read `__type` (then `code`) and `message` (then
`Message`, `errorMessage`) of a JSON object body, as the real ones do, and
answer "" for any other body; the bytes overloads answer "" for a non-ASCII
body where the real ones validate UTF-8. `aws_error_code` keeps what the
real one keeps of a `__type` value, without its length cap.
`aws_json_error_info` takes the code from `x-amzn-query-error` (the text
before its one `;`), else `X-Amzn-Errortype`, else the body, and the request
id from `x-amzn-RequestId`, as the real one does; the request id here is
not length-capped or checked for control bytes.
"""

from komira_json import JsonValue, parse_json_value
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.io_stream import Connector
from komira_retry import MonotonicClock, RetryBudget, RetryLoop, RetryRng, Sleeper

comptime AWS_TS_UNIX: Int = 0
comptime AWS_TS_ISO8601: Int = 1
comptime AWS_TS_RFC822: Int = 2


struct AwsRequest(Copyable, Movable):
    """One request, serialised and not signed: method, URI, headers, body
    bytes."""

    var method: String
    var uri: String
    var body: List[UInt8]
    var header_names: List[String]
    var header_values: List[String]
    var host_prefix: String

    def __init__(out self, var method: String, var uri: String):
        self.method = method^
        self.uri = uri^
        self.body = List[UInt8]()
        self.header_names = List[String]()
        self.header_values = List[String]()
        self.host_prefix = String("")

    def set_body_text(mut self, text: String):
        self.body = _bytes(text)

    def body_text(self) raises -> String:
        return _ascii_text(self.body)

    def set_header(mut self, var name: String, var value: String):
        self.header_names.append(name^)
        self.header_values.append(value^)

    def header(self, name: String) -> String:
        """The first value of `name` (exact match), or empty."""
        for i in range(len(self.header_names)):
            if self.header_names[i] == name:
                return self.header_values[i].copy()
        return String("")


struct AwsResponse(Copyable, Movable):
    """One response: status, headers, body bytes."""

    var status: Int
    var header_names: List[String]
    var header_values: List[String]
    var body: List[UInt8]

    def __init__(out self, status: Int, var body: List[UInt8]):
        self.status = status
        self.header_names = List[String]()
        self.header_values = List[String]()
        self.body = body^

    @staticmethod
    def of_text(status: Int, text: String) -> AwsResponse:
        return AwsResponse(status, _bytes(text))

    def add_header(mut self, var name: String, var value: String):
        self.header_names.append(name^)
        self.header_values.append(value^)

    def header(self, name: String) -> String:
        """The first value of `name` (case-insensitive), "" when absent."""
        var want = name.lower()
        for i in range(len(self.header_names)):
            if self.header_names[i].lower() == want:
                return self.header_values[i].copy()
        return String("")

    def has_header(self, name: String) -> Bool:
        """True when a header named `name` (case-insensitive) is set."""
        var want = name.lower()
        for i in range(len(self.header_names)):
            if self.header_names[i].lower() == want:
                return True
        return False

    def body_text(self) raises -> String:
        return _ascii_text(self.body)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _ascii_text(b: List[UInt8]) raises -> String:
    for i in range(len(b)):
        if b[i] > UInt8(0x7F):
            raise Error("stub komira_aws_core: a non-ASCII body byte")
    return String(unsafe_from_utf8=Span(b))


def aws_json_i64(v: Int64) -> JsonValue:
    return JsonValue.from_i64(v)


def aws_json_i32(v: Int32) -> JsonValue:
    return JsonValue.from_i64(Int64(v))


def aws_json_f64(v: Float64) -> JsonValue:
    return JsonValue.from_f64(v)


def aws_json_f32(v: Float32) -> JsonValue:
    return JsonValue.from_f64(Float64(v))


def aws_json_bool(v: Bool) -> JsonValue:
    return JsonValue.from_bool(v)


def aws_json_string(v: String) -> JsonValue:
    return JsonValue.from_string(v.copy())


def aws_json_blob(v: Span[UInt8, _]) raises -> JsonValue:
    raise Error("stub komira_aws_core: aws_json_blob is not implemented")


def aws_blob_from_json(v: JsonValue) raises -> List[UInt8]:
    raise Error("stub komira_aws_core: aws_blob_from_json is not implemented")


def aws_f64_from_json(v: JsonValue) raises -> Float64:
    raise Error("stub komira_aws_core: aws_f64_from_json is not implemented")


def aws_ts_to_json(v: Float64, format: Int) raises -> JsonValue:
    raise Error("stub komira_aws_core: aws_ts_to_json is not implemented")


def aws_ts_from_json(v: JsonValue) raises -> Float64:
    raise Error("stub komira_aws_core: aws_ts_from_json is not implemented")


def aws_host_label(value: String) raises -> String:
    raise Error("stub komira_aws_core: aws_host_label is not implemented")


def aws_is_error_status(status: Int) -> Bool:
    return status < 200 or status >= 300


def aws_error_code(raw: String) -> String:
    """The short error code of a `__type` value: cut at the first ':', then
    after the last '#'; only [A-Za-z0-9_.-] kept."""
    var s = raw
    var colon = s.find(":")
    if colon >= 0:
        s = _sub(s, 0, colon)
    var hash = s.rfind("#")
    if hash >= 0:
        s = _sub(s, hash + 1, s.byte_length())
    var out = String("")
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if (
            (c >= UInt8(0x41) and c <= UInt8(0x5A))
            or (c >= UInt8(0x61) and c <= UInt8(0x7A))
            or (c >= UInt8(0x30) and c <= UInt8(0x39))
            or c == UInt8(0x5F)
            or c == UInt8(0x2E)
            or c == UInt8(0x2D)
        ):
            out += chr(Int(c))
    return out^


def _error_member(body: String, keys: List[String]) -> String:
    """The first of `keys` a JSON object `body` holds as a string, "" when
    none or when the body is not a JSON object."""
    try:
        var j = parse_json_value(body)
        for k in range(len(keys)):
            if j.has(keys[k]):
                return j.get(keys[k]).as_string()
    except:
        pass
    return String("")


def _is_ascii(body: List[UInt8]) -> Bool:
    for i in range(len(body)):
        if body[i] > UInt8(0x7F):
            return False
    return True


def aws_error_code_from_body(body: String) -> String:
    var keys: List[String] = ["__type", "code"]
    return aws_error_code(_error_member(body, keys))


def aws_error_code_from_body(body: List[UInt8]) -> String:
    if not _is_ascii(body):
        return String("")
    return aws_error_code_from_body(String(unsafe_from_utf8=Span(body)))


def aws_error_message_from_body(body: String) -> String:
    var keys: List[String] = ["message", "Message", "errorMessage"]
    return _error_member(body, keys)


def aws_error_message_from_body(body: List[UInt8]) -> String:
    if not _is_ascii(body):
        return String("")
    return aws_error_message_from_body(String(unsafe_from_utf8=Span(body)))


# -----------------------------------------------------------------------------
# The client half: the `ClientOnly` rows of AWS_IMPORTS.
# -----------------------------------------------------------------------------


@fieldwise_init
struct AwsCredential(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """An access key id, secret access key and session token."""

    var access_key_id: String
    var secret_access_key: String
    var session_token: String

    def has_session_token(self) -> Bool:
        return self.session_token.byte_length() > 0


trait AwsCredsSource(Movable, Deinitable):
    """A source of the credential to sign the next request with."""

    def credentials(mut self) raises -> AwsCredential:
        ...


@fieldwise_init
struct Header(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """One HTTP header."""

    var name: String
    var value: String


struct AwsEndpoint(Copyable, Movable):
    """Where requests go: scheme, host, port and base path."""

    var scheme: String
    var host: String
    var port: Int
    var base_path: String
    var root_slash: Bool

    def __init__(
        out self,
        scheme: String,
        host: String,
        port: Int,
        base_path: String,
        root_slash: Bool,
    ):
        self.scheme = scheme
        self.host = host
        self.port = port
        self.base_path = base_path
        self.root_slash = root_slash

    @staticmethod
    def https(host: String) raises -> AwsEndpoint:
        """`https://<host>` on port 443, the host lower-cased."""
        return AwsEndpoint(String("https"), host.lower(), 443, String(""), True)

    def with_host_prefix(self, prefix: String) raises -> AwsEndpoint:
        """This endpoint with `prefix` lower-cased ahead of its host; ""
        returns it unchanged. The real one also checks the host it makes."""
        var e = self.copy()
        if prefix.byte_length() > 0:
            e.host = prefix.lower() + self.host
        return e^


def resolve_endpoint(
    override: Optional[AwsEndpoint], default_host: String
) raises -> AwsEndpoint:
    """`override` when set, else `https://<default_host>`."""
    if override:
        return override.value().copy()
    return AwsEndpoint.https(default_host)


struct HttpResult(Copyable, Movable):
    """One HTTP response as a transport hands it back."""

    var status: Int
    var header_names: List[String]
    var header_values: List[String]
    var body: List[UInt8]

    def __init__(out self, status: Int, var body: List[UInt8]):
        self.status = status
        self.header_names = List[String]()
        self.header_values = List[String]()
        self.body = body^

    def add_header(mut self, name: String, value: String):
        self.header_names.append(name)
        self.header_values.append(value)

    def header(self, name: String) -> String:
        """The first value of `name` (case-insensitive), "" when absent."""
        var want = name.lower()
        for i in range(len(self.header_names)):
            if self.header_names[i].lower() == want:
                return self.header_values[i].copy()
        return String("")

    def into_response(deinit self) -> AwsResponse:
        """This result as the `AwsResponse` a generated parser reads."""
        var r = AwsResponse(self.status, self.body^)
        r.header_names = self.header_names^
        r.header_values = self.header_values^
        return r^

    def to_response(self) -> AwsResponse:
        """A copy of this result as an `AwsResponse`, for a caller that
        keeps the result (a client's error builder)."""
        var r = AwsResponse(self.status, self.body.copy())
        r.header_names = self.header_names.copy()
        r.header_values = self.header_values.copy()
        return r^


struct AwsErrorInfo(Copyable, Movable):
    """A failed AWS response: `status`, the error `code` ("" when the
    response names none), the `message` ("" when it carries none) and the
    `request_id` ("" when absent)."""

    var status: Int
    var code: String
    var message: String
    var request_id: String

    def __init__(
        out self,
        status: Int,
        code: String,
        message: String,
        request_id: String,
    ):
        self.status = status
        self.code = code
        self.message = message
        self.request_id = request_id

    def to_error(self, what: String) -> Error:
        """An `Error` saying `what` failed, with the status, code, message
        and request id."""
        var s = what + " failed: HTTP " + String(self.status)
        if self.code.byte_length() > 0:
            s += " " + self.code
        if self.message.byte_length() > 0:
            s += ": " + self.message
        if self.request_id.byte_length() > 0:
            s += " (request id " + self.request_id + ")"
        return Error(s)


def aws_json_error_info(resp: AwsResponse) -> AwsErrorInfo:
    """The `AwsErrorInfo` of an awsJson response: the code from
    `x-amzn-query-error`, else `X-Amzn-Errortype`, else the body."""
    var code = String("")
    if resp.has_header(String("x-amzn-query-error")):
        var v = resp.header(String("x-amzn-query-error"))
        var semi = v.find(";")
        if semi > 0 and v.find(";", semi + 1) < 0:
            code = aws_error_code(_sub(v, 0, semi))
    if code.byte_length() == 0 and resp.has_header(String("X-Amzn-Errortype")):
        code = aws_error_code(resp.header(String("X-Amzn-Errortype")))
    if code.byte_length() == 0:
        code = aws_error_code_from_body(resp.body)
    var request_id = resp.header(String("x-amzn-RequestId"))
    if request_id.find(" ") >= 0:
        request_id = String("")
    return AwsErrorInfo(
        resp.status,
        code,
        aws_error_message_from_body(resp.body),
        request_id,
    )


struct AwsRetryQuota(Movable, Deinitable):
    """The retry quota a generated client keeps and hands its sends: 500 at
    the start, as the real one (komira_aws_core's aws_retry.mojo)."""

    var _available: Int

    def __init__(out self):
        self._available = 500

    def available(self) -> Int:
        return self._available

    def try_spend(mut self, cost: Int) -> Bool:
        if cost < 0 or cost > self._available:
            return False
        self._available -= cost
        return True


def send_sigv4_signed_request[
    C: Connector
](
    mk_connector: def () raises thin -> C,
    http_config: HttpClientConfig,
    mut retry_quota: AwsRetryQuota,
    method: String,
    cred: AwsCredential,
    region: String,
    service: String,
    endpoint: AwsEndpoint,
    uri: String,
    content_type: String,
    body: List[UInt8],
    extra: List[Header],
    s3_200_error: Bool = False,
) raises -> HttpResult:
    """The test double described in the module docstring."""
    if _has_crlf(uri) or _has_crlf(content_type):
        raise Error("an AWS request path or content type holds CR or LF")
    for i in range(len(extra)):
        var n = extra[i].name.lower()
        if n == "host" or n == "content-type" or n == "content-length":
            raise Error(
                "the extra header "
                + extra[i].name
                + " is set by the request builder; pass it as its argument"
            )
        if _has_crlf(extra[i].name) or _has_crlf(extra[i].value):
            raise Error("the AWS request header " + extra[i].name + " holds CR or LF")
    _ = mk_connector()
    var status = 200
    var reply = String('{"nextForwardToken":"f/1","events":[]}')
    var errortype = False
    if endpoint.host.startswith("status-") and endpoint.host.endswith(".invalid"):
        var label = _sub(endpoint.host, 7, endpoint.host.byte_length() - 8)
        if label.endswith("-html"):
            status = Int(_sub(label, 0, label.byte_length() - 5))
            reply = String("<html>upstream detail /private/x</html>")
        elif label.endswith("-errortype"):
            status = Int(_sub(label, 0, label.byte_length() - 10))
            reply = String('{"message":"no such group","detail":"/private/x"}')
            errortype = True
        else:
            status = Int(label)
            reply = String(
                '{"__type":"com.amazonaws.logs#ResourceNotFoundException",'
                + '"message":"no such group","detail":"/private/x"}'
            )
    var res = HttpResult(status, _bytes(reply))
    if errortype:
        res.add_header(
            String("X-Amzn-Errortype"),
            String("ResourceNotFoundException:http://internal.amazon.com/"),
        )
        res.add_header(String("x-amzn-RequestId"), String("req-0001"))
    res.add_header(
        String("x-stub-context-ceiling-us"), String(http_config.context_ceiling_us)
    )
    res.add_header(
        String("x-stub-request-timeout-us"), String(http_config.request_timeout_us)
    )
    res.add_header(String("x-stub-method"), method)
    res.add_header(String("x-stub-access-key-id"), cred.access_key_id)
    res.add_header(
        String("x-stub-has-session-token"),
        String("true") if cred.has_session_token() else String("false"),
    )
    res.add_header(String("x-stub-region"), region)
    res.add_header(String("x-stub-service"), service)
    res.add_header(String("x-stub-scheme"), endpoint.scheme)
    res.add_header(String("x-stub-host"), endpoint.host)
    res.add_header(String("x-stub-port"), String(endpoint.port))
    res.add_header(String("x-stub-base-path"), endpoint.base_path)
    res.add_header(
        String("x-stub-root-slash"),
        String("true") if endpoint.root_slash else String("false"),
    )
    res.add_header(String("x-stub-uri"), uri)
    res.add_header(String("x-stub-content-type"), content_type)
    res.add_header(String("x-stub-body"), _ascii_text(body))
    res.add_header(String("x-stub-retry-quota"), String(retry_quota.available()))
    res.add_header(
        String("x-stub-s3-200-error"),
        String("true") if s3_200_error else String("false"),
    )
    res.add_header(String("x-stub-extra-count"), String(len(extra)))
    for i in range(len(extra)):
        res.add_header(extra[i].name, extra[i].value)
    return res^


# -----------------------------------------------------------------------------
# The send over injected seams: `send_sigv4_signed_request_with`, the seams
# it takes (`AwsHttpTransport`, `AwsClock`) and the request a transport is
# handed (`CredentialHttpRequest`). The real ones are
# komira//src/komira_aws_core/aws_send.mojo, sources.mojo and
# credential_transport.mojo.
# -----------------------------------------------------------------------------


struct CredentialHttpRequest(Copyable, Movable):
    """One HTTP request handed to a transport: method, scheme, host, port,
    target (path and query), headers in send order (Host first) and body
    bytes. The real one carries the signature headers too; this one is not
    signed."""

    var method: String
    var scheme: String
    var host: String
    var port: Int
    var target: String
    var headers: List[Header]
    var body: List[UInt8]

    def __init__(
        out self,
        method: String,
        scheme: String,
        host: String,
        port: Int,
        target: String,
    ):
        self.method = method
        self.scheme = scheme
        self.host = host
        self.port = port
        self.target = target
        self.headers = List[Header]()
        self.body = List[UInt8]()

    def header(self, name: String) -> String:
        """The first header named `name` (exact case), "" when absent."""
        for i in range(len(self.headers)):
            if self.headers[i].name == name:
                return self.headers[i].value
        return String("")

    def body_text(self) raises -> String:
        return _ascii_text(self.body)


trait AwsHttpTransport(Movable, Deinitable):
    """Sends one request and returns the response; raises when no response
    arrives."""

    def send(mut self, req: CredentialHttpRequest) raises -> HttpResult:
        ...


trait AwsClock:
    """The wall clock, in whole seconds since the Unix epoch (UTC)."""

    def now_unix_seconds(mut self) -> Int:
        ...


def aws_request_is_conditional(method: String, headers: List[Header]) -> Bool:
    """Whether a request is a conditional write: its method is not GET or
    HEAD and it carries an `If-Match` or `If-None-Match` header (the name
    in any case). The real rule, as komira//src/komira_aws_core/aws_retry.mojo
    states it."""
    if method == "GET" or method == "HEAD":
        return False
    for i in range(len(headers)):
        var name = headers[i].name.lower()
        if name == "if-match" or name == "if-none-match":
            return True
    return False


def send_sigv4_signed_request_with[
    X: AwsHttpTransport,
    K: AwsClock,
    L: MonotonicClock,
    S: Sleeper,
    R: RetryRng,
    B: RetryBudget,
](
    mut transport: X,
    mut clock: K,
    mut retry: RetryLoop[L, S, R],
    mut budget: B,
    method: String,
    cred: AwsCredential,
    region: String,
    service: String,
    endpoint: AwsEndpoint,
    uri: String,
    content_type: String,
    body: List[UInt8],
    extra: List[Header],
    s3_200_error: Bool = False,
) raises -> HttpResult:
    """A test double of the real send over seams (the real one also takes
    a payload-signing mode, defaulted, which no generated code passes).

    It refuses what `send_sigv4_signed_request` refuses, starts `retry`,
    reads `clock` once, and hands `transport` ONE request: `method`, the
    endpoint's scheme, host and port, `uri` as the target, the headers
    Host, Content-Type and then `extra` as given, and `body`. It signs
    nothing and never resends. On a response it calls `retry`'s
    `after_success` with `budget` and answers the transport's response
    with these headers added: `x-stub-region`, `x-stub-service`,
    `x-stub-access-key-id`, `x-stub-clock` (the clock's reading),
    `x-stub-attempts` (the loop's count), `x-stub-s3-200-error` as
    given, and `x-stub-conditional`
    (`aws_request_is_conditional` of `method` and `extra`), each "true" or
    "false"."""
    if _has_crlf(uri) or _has_crlf(content_type):
        raise Error("an AWS request path or content type holds CR or LF")
    for i in range(len(extra)):
        var n = extra[i].name.lower()
        if n == "host" or n == "content-type" or n == "content-length":
            raise Error(
                "the extra header "
                + extra[i].name
                + " is set by the request builder; pass it as its argument"
            )
        if _has_crlf(extra[i].name) or _has_crlf(extra[i].value):
            raise Error("the AWS request header " + extra[i].name + " holds CR or LF")
    var conditional = aws_request_is_conditional(method, extra)
    retry.start()
    var now = clock.now_unix_seconds()
    var req = CredentialHttpRequest(
        method, endpoint.scheme, endpoint.host, endpoint.port, uri
    )
    req.headers.append(Header(String("Host"), endpoint.host))
    req.headers.append(Header(String("Content-Type"), content_type))
    for i in range(len(extra)):
        req.headers.append(extra[i])
    req.body = body.copy()
    var res = transport.send(req)
    retry.after_success(budget)
    res.add_header(String("x-stub-region"), region)
    res.add_header(String("x-stub-service"), service)
    res.add_header(String("x-stub-access-key-id"), cred.access_key_id)
    res.add_header(String("x-stub-clock"), String(now))
    res.add_header(String("x-stub-attempts"), String(retry.attempts()))
    res.add_header(
        String("x-stub-s3-200-error"),
        String("true") if s3_200_error else String("false"),
    )
    res.add_header(
        String("x-stub-conditional"),
        String("true") if conditional else String("false"),
    )
    return res^


def _has_crlf(s: String) -> Bool:
    var b = s.as_bytes()
    for i in range(len(b)):
        if b[i] == UInt8(0x0D) or b[i] == UInt8(0x0A):
            return True
    return False


def _sub(s: String, i: Int, j: Int) -> String:
    """Bytes [i, j) of `s`, clamped."""
    var b = s.as_bytes()
    var lo = max(0, min(i, len(b)))
    var hi = max(lo, min(j, len(b)))
    return String(StringSlice(unsafe_from_utf8=b[lo:hi]))
