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
# `aws_json_error_info` reads one from an awsJson response. Its code and
# message are `aws_error_code_from_body` / `aws_error_message_from_body`;
# its request id is the `x-amzn-RequestId` header, which is where botocore's
# JSON parser reads it (`_inject_response_metadata`).
# =============================================================================

from ._text import has_control
from .aws_codec import aws_error_code_from_body, aws_error_message_from_body
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


def aws_json_error_info(resp: AwsResponse) -> AwsErrorInfo:
    """The `AwsErrorInfo` of an awsJson response."""
    return AwsErrorInfo(
        resp.status,
        aws_error_code_from_body(resp.body),
        aws_error_message_from_body(resp.body),
        aws_request_id(resp, String("x-amzn-RequestId")),
    )
