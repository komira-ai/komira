# =============================================================================
# komira_aws_core/aws_request.mojo -- an unsigned AWS request, a response
# =============================================================================
#
# `AwsRequest` is what a generated `build_<op>_request` returns: method, path
# and query, the operation's headers (X-Amz-Target, Content-Type, ...), an
# optional operation host prefix and the serialized body. It is NOT signed
# and names no host; `build_sigv4_signed_request` (signed_request.mojo) turns
# it into wire bytes against an endpoint.
#
# `AwsResponse` is what a generated `parse_<op>_response` reads: status,
# response headers and body. It is pure: no transport makes or holds one.
# `HttpResult` is what a transport hands back; `into_response()` moves it
# into an `AwsResponse`, and `to_response()` copies it into one.
#
# Every body is BYTES (`List[UInt8]`): a protocol body need not be text (an
# S3 object, a blob payload). `body_text()` reads one as UTF-8 and refuses
# bytes that are not; `set_body_text()` writes text.
#
# Bodies can hold secrets (a Secrets Manager value, a credential), so none
# of these types is `Writable`, a refusal never quotes body bytes, and an
# error built from a response carries only the status, the parsed error code
# and message, and the request id (`AwsErrorInfo`, aws_error.mojo; the code
# and message readers, aws_codec.mojo).
# =============================================================================

from ._text import ascii_lower, bytes_of, has_crlf, utf8_text
from .sigv4 import Header


def _check_header(name: String, value: String) raises:
    if name.byte_length() == 0:
        raise Error("an AWS request header has an empty name")
    if has_crlf(name) or has_crlf(value):
        raise Error("the AWS request header " + name + " holds CR or LF")
    if name.find(":") >= 0 or name.find(" ") >= 0:
        raise Error("the AWS request header name " + name + " is malformed")


def _first(names: List[String], values: List[String], name: String) -> String:
    var key = ascii_lower(name)
    for i in range(len(names)):
        if ascii_lower(names[i]) == key:
            return values[i]
    return String("")


def _lower_byte(c: UInt8) -> UInt8:
    if c >= UInt8(0x41) and c <= UInt8(0x5A):
        return c + 0x20
    return c


def _ascii_prefix_ci(name: Span[UInt8, _], prefix: Span[UInt8, _]) -> Bool:
    """True when every byte of `name` and `prefix` is ASCII and `name`
    starts with `prefix`, ASCII case ignored."""
    for i in range(len(name)):
        if name[i] >= UInt8(0x80):
            return False
    for i in range(len(prefix)):
        if prefix[i] >= UInt8(0x80) or _lower_byte(name[i]) != _lower_byte(
            prefix[i]
        ):
            return False
    return True


def _has(names: List[String], name: String) -> Bool:
    var key = ascii_lower(name)
    for i in range(len(names)):
        if ascii_lower(names[i]) == key:
            return True
    return False


struct AwsRequest(Copyable, Movable):
    """An unsigned AWS request.

    - `method`: "GET", "POST", ...
    - `uri`: the path and query, "/" for awsJson operations. The query is
      part of it; the signer canonicalizes it (a key with no value too).
    - `header_names` / `header_values`: the operation's headers, in order,
      one name per value. Set through `set_header`.
    - `host_prefix`: the operation's `endpoint.hostPrefix` with its labels
      substituted, "" for none.
    - `body`: the serialized body, bytes.
    """

    var method: String
    var uri: String
    var header_names: List[String]
    var header_values: List[String]
    var host_prefix: String
    var body: List[UInt8]

    def __init__(out self, method: String, uri: String):
        self.method = method
        self.uri = uri
        self.header_names = List[String]()
        self.header_values = List[String]()
        self.host_prefix = String("")
        self.body = List[UInt8]()

    def set_header(mut self, name: String, value: String) raises:
        """Sets `name` (case-insensitive) to `value`, replacing an earlier
        value. Refuses CR/LF and a malformed name."""
        _check_header(name, value)
        var key = ascii_lower(name)
        for i in range(len(self.header_names)):
            if ascii_lower(self.header_names[i]) == key:
                self.header_values[i] = value
                return
        self.header_names.append(name)
        self.header_values.append(value)

    def header(self, name: String) -> String:
        """The value of `name` (case-insensitive), "" when absent."""
        return _first(self.header_names, self.header_values, name)

    def set_body_text(mut self, text: String):
        """Sets the body to the UTF-8 bytes of `text`."""
        self.body = bytes_of(text)

    def body_text(self) raises -> String:
        """The body as text. Refuses a body that is not well-formed UTF-8."""
        return utf8_text(Span(self.body), "the AWS request body")


struct AwsResponse(Copyable, Movable):
    """One AWS response, as a generated `parse_<op>_response` reads it:
    `status`, the response headers in order (one name per value) and the
    `body`. Bodies can hold secrets; never log one."""

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
        """A response whose body is the UTF-8 bytes of `text`."""
        return AwsResponse(status, bytes_of(text))

    def add_header(mut self, name: String, value: String):
        self.header_names.append(name)
        self.header_values.append(value)

    def header(self, name: String) -> String:
        """The first value of `name` (case-insensitive), "" when absent."""
        return _first(self.header_names, self.header_values, name)

    def has_header(self, name: String) -> Bool:
        """True when a header named `name` (case-insensitive) is present,
        with any value, "" included."""
        return _has(self.header_names, name)

    def headers_with_prefix(self, prefix: String) -> List[Header]:
        """Every header whose name starts with `prefix` (case-insensitive),
        in response order, named by the REST of its name in the case it
        arrived in: `x-amz-meta-Color: red` under prefix "x-amz-meta-" is
        ("Color", "red"). A header named exactly `prefix` is not included:
        it names no key. Header names are ASCII tokens (RFC 9110), so a
        name holding a byte at or above 0x80 matches no prefix, and neither
        prefix nor name is cut inside a character."""
        var out = List[Header]()
        var pb = prefix.as_bytes()
        var pn = len(pb)
        for i in range(len(self.header_names)):
            var nb = self.header_names[i].as_bytes()
            if len(nb) <= pn or not _ascii_prefix_ci(nb, pb):
                continue
            out.append(
                Header(
                    String(unsafe_from_utf8=nb[pn : len(nb)]),
                    self.header_values[i],
                )
            )
        return out^

    def body_text(self) raises -> String:
        """The body as text. Refuses a body that is not well-formed UTF-8."""
        return utf8_text(Span(self.body), "the AWS response body")


struct HttpResult(Copyable, Movable):
    """One HTTP response as a transport hands it back: `status`, the
    response headers in order, and the `body`. Bodies can hold secrets;
    never log one."""

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
        return _first(self.header_names, self.header_values, name)

    def body_text(self) raises -> String:
        """The body as text. Refuses a body that is not well-formed UTF-8."""
        return utf8_text(Span(self.body), "the HTTP response body")

    def into_response(deinit self) -> AwsResponse:
        """This result as the `AwsResponse` a generated parser reads, its
        body and headers moved, not copied."""
        var r = AwsResponse(self.status, self.body^)
        r.header_names = self.header_names^
        r.header_values = self.header_values^
        return r^

    def to_response(self) -> AwsResponse:
        """A copy of this result as an `AwsResponse`, for a caller that
        keeps the result; `into_response` does not copy the body."""
        var r = AwsResponse(self.status, self.body.copy())
        r.header_names = self.header_names.copy()
        r.header_values = self.header_values.copy()
        return r^
