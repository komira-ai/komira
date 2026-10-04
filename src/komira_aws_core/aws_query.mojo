# =============================================================================
# komira_aws_core/aws_query.mojo -- the awsQuery and ec2Query runtime
# =============================================================================
#
# What a generated awsQuery (`query`) or ec2Query (`ec2`) client calls to put
# an operation's input into a request body and to read its response. Both
# protocols send every input member as one form parameter of an
# `application/x-www-form-urlencoded` POST body, and answer in XML; the
# naming of the parameters (dotted names, `member` / `entry` segments, list
# indexes) is the generator's, and nothing here reads a model.
#
# Request. `AwsQueryWriter` holds the body as botocore's QuerySerializer
# builds it (botocore/serialize.py): `Action=<operation>` and
# `Version=<apiVersion>` first, then each parameter in the order it is
# added, joined by '&'. Keys and values are percent-encoded as botocore's
# `percent_encode_sequence` encodes them (Python's `quote` with
# `safe='-._~'`): every byte of the UTF-8 text outside A-Z a-z 0-9 '-' '.'
# '_' '~' is %XX with uppercase hex, so a space is %20 (never '+') and '/'
# is %2F. The scalar text is aws_text.mojo's (`aws_text_*`), as botocore
# writes it: "true" / "false", a decimal integer, a number or "NaN" /
# "Infinity" / "-Infinity", standard padded base64, and a timestamp in the
# member's format (date-time by default).
#
# Response. A successful awsQuery response is
#
#   <OpResponse><OpResult>...members...</OpResult><ResponseMetadata/></OpResponse>
#
# and `aws_query_result` hands the generated parser the result element, the
# one the operation's `resultWrapper` names (botocore's QueryParser,
# `_find_result_wrapped_shape`). An ec2Query response has no wrapper: its
# members are the root's children, which `aws_xml_parse` hands over. The
# members are read with aws_xml.mojo's readers.
#
# Errors. `aws_query_error` reads both protocols' error documents
# (https://smithy.io/2.0/aws/protocols/aws-query-protocol.html and
# aws-ec2-query-protocol.html, "Error response serialization"):
#
#   <ErrorResponse><Error><Type/><Code/><Message/></Error><RequestId/></ErrorResponse>   (query)
#   <Response><Errors><Error><Code/><Message/></Error></Errors><RequestID/></Response>   (ec2)
#
# and a bare <Error> root, read as aws_xml.mojo's restXml reader reads one
# (no awsQuery service answers with it; komira_aws_core's AwsEchoConnector
# does, and so a test can read the request through a generated client).
#
# Its code is the <Code> text, cleaned and capped as aws_codec.mojo cleans
# it; for an empty body or one that is not XML it is the HTTP status as
# text, as botocore's generic error parsing makes it; for an XML body
# naming no code it is "". The request id is the `x-amzn-RequestId` header,
# else the body's <RequestId> (query) or <RequestID> (ec2). Nothing else is
# read from the body, which can hold a secret.
# =============================================================================

from komira_xml import XmlNode

from ._text import bytes_of
from .aws_codec import _clean_message, aws_error_code
from .aws_error import AwsErrorInfo, aws_request_id
from .aws_request import AwsRequest, AwsResponse
from .aws_xml import (
    _child_trimmed,
    _request_id_text,
    aws_xml_child,
    aws_xml_parse,
)
from .sigv4 import uri_encode


# The Content-Type of every awsQuery and ec2Query request, as botocore's
# QuerySerializer sets it.
comptime AWS_QUERY_CONTENT_TYPE = "application/x-www-form-urlencoded; charset=utf-8"


struct AwsQueryWriter(Movable):
    """The form body of one awsQuery / ec2Query request: `Action` and
    `Version` first, then each parameter `add` is given, in order."""

    var _body: String

    def __init__(out self, action: String, version: String):
        """Starts the body with `Action=<action>&Version=<version>`."""
        self._body = String("Action=") + uri_encode(action)
        self._body += String("&Version=") + uri_encode(version)

    def add(mut self, key: String, value: String):
        """Appends `&<key>=<value>`, both percent-encoded. An empty value
        is written as `key=` (an empty list in awsQuery)."""
        self._body += String("&") + uri_encode(key) + String("=")
        self._body += uri_encode(value)

    def text(self) -> String:
        """The body as written so far."""
        return self._body.copy()


def aws_query_key(prefix: String, name: String) -> String:
    """The parameter name of `name` under `prefix`: `prefix.name`, or
    `name` alone when `prefix` is empty (a member of the input itself)."""
    if prefix.byte_length() == 0:
        return name.copy()
    return prefix + String(".") + name


def aws_query_rename_last(key: String, name: String) -> String:
    """`key` with its last dotted segment replaced by `name`: what botocore
    does to the prefix of a flattened awsQuery list whose member has a
    locationName (`Hi` becomes `item`, `A.Hi` becomes `A.item`)."""
    var b = key.as_bytes()
    var i = len(b) - 1
    while i >= 0:
        if b[i] == UInt8(0x2E):
            return String(StringSlice(unsafe_from_utf8=b[0 : i + 1])) + name
        i -= 1
    return name.copy()


def aws_query_set_body(mut req: AwsRequest, w: AwsQueryWriter) raises:
    """Sets `req`'s body to the form `w` holds, and its Content-Type to
    AWS_QUERY_CONTENT_TYPE."""
    req.body = bytes_of(w.text())
    req.set_header(String("Content-Type"), String(AWS_QUERY_CONTENT_TYPE))


def aws_query_result(body: List[UInt8], wrapper: String) raises -> XmlNode:
    """The result element `wrapper` (`<OpResult>`) of an awsQuery response
    body, which the output's members are the children of. An empty body is
    an empty element (no members). Refuses a body that is not well-formed
    UTF-8 or XML, and one whose root holds no `wrapper` element, as
    botocore's QueryParser refuses one."""
    var root = aws_xml_parse(body)
    if len(body) == 0:
        return root^
    var i = aws_xml_child(root, wrapper)
    if i < 0:
        raise Error(
            "the awsQuery response <" + root.local + "> holds no <" + wrapper
            + "> element"
        )
    return root.children[i].copy()


def _parse_or_none(body: List[UInt8]) -> Optional[XmlNode]:
    """The root element of `body`, `None` when it is not well-formed."""
    try:
        return aws_xml_parse(body)
    except:
        return None


def aws_query_error(resp: AwsResponse) -> AwsErrorInfo:
    """The `AwsErrorInfo` of an awsQuery or ec2Query error response: see
    the module header."""
    var rid = String("")
    if resp.has_header(String("x-amzn-RequestId")):
        rid = aws_request_id(resp, String("x-amzn-RequestId"))
    if len(resp.body) == 0:
        return AwsErrorInfo(resp.status, String(resp.status), String(""), rid)
    var parsed = _parse_or_none(resp.body)
    if not parsed:
        return AwsErrorInfo(resp.status, String(resp.status), String(""), rid)
    ref root = parsed.value()
    var err = XmlNode()
    var have = False
    var i = aws_xml_child(root, String("Error"))
    if root.local == "Error":
        err = root.copy()
        have = True
    elif i >= 0:
        err = root.children[i].copy()
        have = True
    else:
        var e = aws_xml_child(root, String("Errors"))
        if e >= 0:
            var j = aws_xml_child(root.children[e], String("Error"))
            if j >= 0:
                err = root.children[e].children[j].copy()
                have = True
    var code = String("")
    var message = String("")
    if have:
        code = aws_error_code(_child_trimmed(err, String("Code")))
        message = _clean_message(_child_trimmed(err, String("Message")))
    if rid.byte_length() == 0:
        var body_rid = _child_trimmed(root, String("RequestId"))
        if body_rid.byte_length() == 0:
            body_rid = _child_trimmed(root, String("RequestID"))
        rid = _request_id_text(body_rid)
    return AwsErrorInfo(resp.status, code, message, rid)
