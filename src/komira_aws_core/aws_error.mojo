# =============================================================================
# komira_aws_core/aws_error.mojo -- a failed AWS response, as data
# =============================================================================
#
# `AwsErrorInfo` is what a caller gets from a non-2xx response: the HTTP
# status, the service's short error code, its message and the request id.
# Nothing else from the response rides in it: a body can hold a secret, so
# the code and message are the cleaned, length-capped readings of
# aws_codec.mojo and the request id is a header.
#
# `aws_json_error_info` reads one from an awsJson response. Its code is the
# `X-Amzn-Errortype` header when the response has one, else
# `aws_error_code_from_body` (`__type`, then `code`), as the Smithy
# awsJson1_0 / awsJson1_1 error rules allow; both are cleaned by
# `aws_error_code`. Its message is `aws_error_message_from_body`, and its
# request id the `x-amzn-RequestId` header, which is where botocore's JSON
# parser reads it (`_inject_response_metadata`).
#
# An awsQueryCompatible service (SQS) also names an error's legacy query
# code in an `x-amzn-query-error` header, `<code>;<Sender|Receiver>`, and
# that code, `aws_query_error_code`, wins over both when the header has
# that form: an error whose `__type` is `QueueDoesNotExist` has code
# `AWS.SimpleQueueService.NonExistentQueue`. botocore's JSON parser does
# the same (`_do_query_compatible_error_parsing`), and it is the Go v2
# SDK's error code. The shape name stays readable from the body through
# `aws_error_code_from_body`.
#
# A response that names no code has code "". botocore's JSON parser puts
# the status there instead (`str(status_code)`); here the status is already
# `status`, and a code that is a number would match no modeled error.
#
# `aws_client_error_code` reads the code back out of the text a generated
# client raises for a non-2xx answer (`<Service>.<Op> failed: HTTP <status>
# <code> <message>`, the form tools/build/proto-codegen emits; not
# `AwsErrorInfo.to_error`'s), so a caller that maps an error code onto its
# own outcome (a missing resource answered False, a taken name treated as
# done) reads it here instead of parsing the text itself.
# =============================================================================

from ._text import has_control, sub
from .aws_codec import (
    aws_error_code,
    aws_error_code_from_body,
    aws_error_message_from_body,
)
from .aws_request import AwsResponse


# The longest request id an error carries. A longer or malformed one is "".
comptime AWS_REQUEST_ID_MAX_BYTES = 128


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
        and request id. Nothing else from the response is in it."""
        var s = what + " failed: HTTP " + String(self.status)
        if self.code.byte_length() > 0:
            s += " " + self.code
        if self.message.byte_length() > 0:
            s += ": " + self.message
        if self.request_id.byte_length() > 0:
            s += " (request id " + self.request_id + ")"
        return Error(s)


def aws_request_id(resp: AwsResponse, header: String) -> String:
    """The request id in header `header`, "" when absent, longer than
    AWS_REQUEST_ID_MAX_BYTES or holding a control byte or a space."""
    var v = resp.header(header)
    if v.byte_length() > AWS_REQUEST_ID_MAX_BYTES or has_control(v):
        return String("")
    if v.find(" ") >= 0:
        return String("")
    return v


def aws_query_error_code(resp: AwsResponse) -> String:
    """The legacy query code of an awsQueryCompatible error: the cleaned
    text before the `;` of an `x-amzn-query-error` header of the form
    `<code>;<type>`, "" when the header is absent or has another form."""
    if not resp.has_header(String("x-amzn-query-error")):
        return String("")
    var v = resp.header(String("x-amzn-query-error"))
    var semi = v.find(";")
    if semi <= 0 or v.find(";", semi + 1) >= 0:
        return String("")
    return aws_error_code(sub(v, 0, semi))


def aws_json_error_info(resp: AwsResponse) -> AwsErrorInfo:
    """The `AwsErrorInfo` of an awsJson response: the code from
    `x-amzn-query-error`, else `X-Amzn-Errortype`, else the body, "" when
    none names one."""
    var code = aws_query_error_code(resp)
    if code.byte_length() == 0 and resp.has_header(String("X-Amzn-Errortype")):
        code = aws_error_code(resp.header(String("X-Amzn-Errortype")))
    if code.byte_length() == 0:
        code = aws_error_code_from_body(resp.body)
    return AwsErrorInfo(
        resp.status,
        code,
        aws_error_message_from_body(resp.body),
        aws_request_id(resp, String("x-amzn-RequestId")),
    )


def aws_client_error_code(operation: String, text: String) -> String:
    """The error code in `text`, an error a generated client raised for
    `operation` (`<Service>.<Op>`, as in `SecretsManager.PutSecretValue`):
    `<operation> failed: HTTP <status> <code> <message>`. "" when `text`
    is not such an error (a transport failure, a request the client
    refused before sending, another operation's error) or the answer named
    no code."""
    var head = operation + " failed: HTTP "
    if not text.startswith(head):
        return String("")
    var b = text.as_bytes()
    var i = head.byte_length()
    var digits = 0
    while i < len(b) and b[i] >= UInt8(ord("0")) and b[i] <= UInt8(ord("9")):
        i += 1
        digits += 1
    if digits == 0 or i >= len(b) or b[i] != UInt8(ord(" ")):
        return String("")
    i += 1
    var start = i
    while i < len(b) and b[i] != UInt8(ord(" ")):
        i += 1
    return String(text[byte=start:i])
