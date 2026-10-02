# =============================================================================
# komira_aws_core/aws_json.mojo -- the JsonValue-typed awsJson scalar names
# =============================================================================
#
# The names a generated komira_aws_<svc> module calls to put one scalar into,
# or take one out of, a komira_json `JsonValue` document. Each is a thin wrap
# of the `AwsJsonToken` function in aws_codec.mojo, which holds every rule of
# the encoding (NaN / Infinity as strings, base64 blobs, the three timestamp
# formats); nothing here decides anything about the wire form.
#
# A token becomes a JsonValue by its kind: a number keeps its text verbatim
# (`JsonValue.from_number`), a string its unescaped content, a bool its value.
# The reverse reads a JSON number's source text or a JSON string's content
# back into a token; any other JSON kind is refused, naming the scalar kind
# that was expected and never the value (a response body can hold a secret).
# =============================================================================

from komira_json import JsonValue

from .aws_codec import (
    AWS_JSON_BOOL,
    AWS_JSON_NUMBER,
    AWS_JSON_STRING,
    AwsJsonToken,
    aws_blob_from_text,
    aws_f64_from_token,
    aws_token_blob,
    aws_token_bool,
    aws_token_f32,
    aws_token_f64,
    aws_token_i32,
    aws_token_i64,
    aws_token_string,
    aws_token_ts,
    aws_ts_from_token,
)


def _json_of(var tok: AwsJsonToken) -> JsonValue:
    if tok.kind == AWS_JSON_NUMBER:
        return JsonValue.from_number(tok.text^)
    if tok.kind == AWS_JSON_BOOL:
        return JsonValue.from_bool(tok.text == "true")
    return JsonValue.from_string(tok.text^)


def _token_of(v: JsonValue, what: StaticString) raises -> AwsJsonToken:
    if v.is_number():
        return AwsJsonToken(AWS_JSON_NUMBER, v.text)
    if v.is_string():
        return AwsJsonToken(AWS_JSON_STRING, v.text)
    raise Error(
        "an awsJson " + String(what) + " is neither a JSON number nor a string"
    )


# -----------------------------------------------------------------------------
# Encoding
# -----------------------------------------------------------------------------


def aws_json_string(s: String) -> JsonValue:
    """A string or enum member: a JSON string."""
    return _json_of(aws_token_string(s))


def aws_json_bool(v: Bool) -> JsonValue:
    return _json_of(aws_token_bool(v))


def aws_json_i32(v: Int32) -> JsonValue:
    return _json_of(aws_token_i32(v))


def aws_json_i64(v: Int64) -> JsonValue:
    return _json_of(aws_token_i64(v))


def aws_json_f64(v: Float64) -> JsonValue:
    """A double: a JSON number, or the string "NaN" / "Infinity" /
    "-Infinity"."""
    return _json_of(aws_token_f64(v))


def aws_json_f32(v: Float32) -> JsonValue:
    """A float, written at Float32 precision; NaN / Infinity as strings."""
    return _json_of(aws_token_f32(v))


def aws_json_blob(data: List[UInt8]) -> JsonValue:
    """A blob: a JSON string of its standard padded base64."""
    return _json_of(aws_token_blob(Span(data)))


def aws_ts_to_json(epoch_seconds: Float64, fmt: Int) raises -> JsonValue:
    """A timestamp (epoch seconds) in `fmt`: AWS_TS_UNIX as a JSON number,
    AWS_TS_ISO8601 / AWS_TS_RFC822 as a JSON string."""
    return _json_of(aws_token_ts(epoch_seconds, fmt))


# -----------------------------------------------------------------------------
# Decoding
# -----------------------------------------------------------------------------


def aws_f64_from_json(v: JsonValue) raises -> Float64:
    """A double from a JSON number or from "NaN" / "Infinity" /
    "-Infinity"."""
    return aws_f64_from_token(_token_of(v, "double"))


def aws_ts_from_json(v: JsonValue) raises -> Float64:
    """Epoch seconds from a timestamp in any of the three formats."""
    return aws_ts_from_token(_token_of(v, "timestamp"))


def aws_blob_from_json(v: JsonValue) raises -> List[UInt8]:
    """A blob's bytes from its base64 JSON string."""
    if not v.is_string():
        raise Error("an awsJson blob is not a JSON string")
    return aws_blob_from_text(v.text)
