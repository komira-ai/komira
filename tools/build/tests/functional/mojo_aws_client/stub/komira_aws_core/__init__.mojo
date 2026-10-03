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

The client half (the end of this file) has the real core's types and
signatures. `AwsCredential`, `Header`, `AwsCredsSource`, `HttpResult` and
`resolve_endpoint` behave as the real ones do for what a generated client
calls; `AwsEndpoint.https` checks nothing of the host.
`send_sigv4_signed_request` is a test double, not a transport: it calls the
client's connector factory, signs nothing and sends nothing, and answers
200 with the body `{}` and one `x-stub-*` header per argument it was given
(of the credential, the access key id only), followed by the `extra`
headers as given, so that a caller's test can read what the generated
`send` hands the transport. The real transport half is not in
komira//src/komira_aws_core yet; it lands with the HTTP client.
"""

from komira_json import JsonValue
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


def aws_error_code(
    error_type_header: String, body: String, query_error_header: String = String("")
) raises -> String:
    raise Error("stub komira_aws_core: aws_error_code is not implemented")


# The error readers answer empty: the real ones read `__type`/`code` and
# `message` and never raise, each over a body held as text or as bytes.
def aws_error_code_from_body(body: String) -> String:
    return String("")


def aws_error_code_from_body(body: List[UInt8]) -> String:
    return String("")


def aws_error_message_from_body(body: String) -> String:
    return String("")


def aws_error_message_from_body(body: List[UInt8]) -> String:
    return String("")


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
    _ = mk_connector()
    var body_ = List[UInt8]()
    body_.append(UInt8(ord("{")))
    body_.append(UInt8(ord("}")))
    var res = HttpResult(200, body_^)
    res.add_header(String("x-stub-method"), method)
    res.add_header(String("x-stub-access-key-id"), cred.access_key_id)
    res.add_header(String("x-stub-region"), region)
    res.add_header(String("x-stub-service"), service)
    res.add_header(String("x-stub-scheme"), endpoint.scheme)
    res.add_header(String("x-stub-host"), endpoint.host)
    res.add_header(String("x-stub-port"), String(endpoint.port))
    res.add_header(String("x-stub-uri"), uri)
    res.add_header(String("x-stub-content-type"), content_type)
    res.add_header(String("x-stub-body-bytes"), String(len(body)))
    res.add_header(String("x-stub-extra-count"), String(len(extra)))
    for i in range(len(extra)):
        res.add_header(extra[i].name, extra[i].value)
    return res^
