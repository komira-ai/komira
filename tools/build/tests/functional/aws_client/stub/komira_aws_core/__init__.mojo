"""A stub `komira_aws_core` for the aws_client fixture.

komira's komira_aws_core does not yet hold the request and codec surface
that generated pure-mode code imports (`AwsRequest` and the `aws_*`
helpers), so this stub declares each name that code imports, with the
signature the generator expects. Only what the fixture's GetLogEvents
client calls is implemented (`AwsRequest` and the scalar `aws_json_*`
encoders); every other name raises or answers empty, so a test that came to
depend on one would fail rather than pass on a stand-in.
"""

from komira_serde.json_value import JsonValue

comptime AWS_TS_UNIX: Int = 0
comptime AWS_TS_ISO8601: Int = 1
comptime AWS_TS_RFC822: Int = 2


struct AwsRequest(Copyable, Movable):
    """One request, serialised and not signed: method, URI, headers, body."""

    var method: String
    var uri: String
    var body: String
    var header_names: List[String]
    var header_values: List[String]

    def __init__(out self, var method: String, var uri: String):
        self.method = method^
        self.uri = uri^
        self.body = String("")
        self.header_names = List[String]()
        self.header_values = List[String]()

    def set_header(mut self, var name: String, var value: String):
        self.header_names.append(name^)
        self.header_values.append(value^)

    def header(self, name: String) -> String:
        """The first value of `name` (exact match), or empty."""
        for i in range(len(self.header_names)):
            if self.header_names[i] == name:
                return self.header_values[i].copy()
        return String("")


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
