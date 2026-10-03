"""A stub `komira_aws_core` for the mojo_aws_client fixture.

The real core is komira//src/komira_aws_core, and generated code is built
against it in the komira cell (the AWS conformance driver,
komira//tools/build/proto-codegen). A library of this cell cannot depend
on it (a mojo_library of another cell carries another cell's MojoPkgTSet
type), and nothing generates this file: it is kept by hand, in step with
the names and signatures the generator imports for an awsJson module
(emit_aws/mod.rs AWS_IMPORTS: the `Always` rows, and the `ClientOnly` rows
below). It cannot fall behind that table unnoticed: the GetLogEvents
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
`AwsEndpoint`, `Header`, `HttpResult` and `resolve_endpoint` have the real
core's types and signatures, and behave as the real ones do for what a
generated client calls; `AwsEndpoint.https` checks nothing of the host.
`send_sigv4_signed_request` is not in komira//src/komira_aws_core yet (its
signed_request.mojo builds the signed request; the transport half lands
with the HTTP library). Its signature here is the call the generator emits
(emit_aws/mod.rs, the client's `send`): the contract the real transport
has to meet, and the line to re-check this stub against when it lands.

`send_sigv4_signed_request` is a test double, not a transport. It refuses
what the real request builder refuses of its arguments (an `extra` header
named Host, Content-Type or Content-Length, in any case; CR or LF in a
header, the path or the content type), calls the client's connector
factory, signs nothing and sends nothing. It answers with one `x-stub-*`
header per argument it was given (of the credential, the access key id and
whether a session token is set, never a secret), the request body as
`x-stub-body` (ASCII only), then the `extra` headers as given, so that a
caller's test can read what the generated `send` hands the transport. The
status and body come from the endpoint host: `status-<NNN>.invalid`
answers NNN with an awsJson error body (`__type`, `message` and a detail
member no error should echo), `status-<NNN>-html.invalid` answers NNN with
a non-JSON body, and any other host answers 200 with
`{"nextForwardToken":"f/1","events":[]}`.

The error readers read `__type` (then `code`) and `message` (then
`Message`, `errorMessage`) of a JSON object body, as the real ones do, and
answer "" for any other body; the bytes overloads answer "" for a non-ASCII
body where the real ones validate UTF-8. `aws_error_code` keeps what the
real one keeps of a `__type` value, without its length cap.
"""

from komira_json import JsonValue, parse_json_value
from komira_http_core.transport.io_stream import Connector

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

    def __init__(out self, var method: String, var uri: String):
        self.method = method^
        self.uri = uri^
        self.body = List[UInt8]()
        self.header_names = List[String]()
        self.header_values = List[String]()

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


def send_sigv4_signed_request[
    C: Connector
](
    mk_connector: def () raises thin -> C,
    method: String,
    cred: AwsCredential,
    region: String,
    service: String,
    endpoint: AwsEndpoint,
    uri: String,
    content_type: String,
    var body: List[UInt8],
    var extra: List[Header],
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
    if endpoint.host.startswith("status-") and endpoint.host.endswith(".invalid"):
        var label = _sub(endpoint.host, 7, endpoint.host.byte_length() - 8)
        if label.endswith("-html"):
            status = Int(_sub(label, 0, label.byte_length() - 5))
            reply = String("<html>upstream detail /private/x</html>")
        else:
            status = Int(label)
            reply = String(
                '{"__type":"com.amazonaws.logs#ResourceNotFoundException",'
                + '"message":"no such group","detail":"/private/x"}'
            )
    var res = HttpResult(status, _bytes(reply))
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
    res.add_header(String("x-stub-extra-count"), String(len(extra)))
    for i in range(len(extra)):
        res.add_header(extra[i].name, extra[i].value)
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
