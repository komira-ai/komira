"""A stub `komira_aws_core` for the aws_client fixture.

The real core is komira//src/komira_aws_core, and generated code is built
against it in the komira cell (the AWS conformance driver,
komira//tools/build/proto-codegen). A library of this cell cannot depend
on it (a mojo_library of another cell carries another cell's MojoPkgTSet
type), and nothing generates this file: it is kept by hand, in step with
the names and signatures the generator imports (emit_aws/mod.rs AWS_IMPORTS,
the `Always` rows). Only what the fixture's GetLogEvents client calls is
implemented (`AwsRequest`, `AwsResponse` and the scalar `aws_json_*`
encoders); every other name raises or answers empty, so a test that came to
depend on one would fail rather than pass on a stand-in. Bodies are bytes,
as in the real core; `body_text` here refuses any non-ASCII byte rather
than validating UTF-8.
"""

from komira_json import JsonValue

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


def aws_error_code_from_body(body: String) raises -> String:
    raise Error("stub komira_aws_core: aws_error_code_from_body is not implemented")


def aws_error_message_from_body(body: String) raises -> String:
    raise Error("stub komira_aws_core: aws_error_message_from_body is not implemented")
