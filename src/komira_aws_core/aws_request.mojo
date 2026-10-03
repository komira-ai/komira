# =============================================================================
# komira_aws_core/aws_request.mojo -- an unsigned AWS request, an HTTP result
# =============================================================================
#
# `AwsRequest` is what a generated `build_<op>_request` returns: method, path,
# the operation's headers (X-Amz-Target, Content-Type, ...), an optional
# operation host prefix and the serialized body. It is NOT signed and names
# no host; `build_sigv4_signed_request` (signed_request.mojo) turns it into
# wire bytes against an endpoint.
#
# `HttpResult` is what the transport hands back: status, response headers and
# body. Bodies can hold secrets (a Secrets Manager value, a credential), so
# neither type is `Writable`, and an error built from a result carries only
# the status and the parsed error code and message (aws_codec.mojo).
# =============================================================================

from ._text import ascii_lower, has_crlf


def _check_header(name: String, value: String) raises:
    if name.byte_length() == 0:
        raise Error("an AWS request header has an empty name")
    if has_crlf(name) or has_crlf(value):
        raise Error("the AWS request header " + name + " holds CR or LF")
    if name.find(":") >= 0 or name.find(" ") >= 0:
        raise Error("the AWS request header name " + name + " is malformed")


struct AwsRequest(Copyable, Movable):
    """An unsigned AWS request.

    - `method`: "GET", "POST", ...
    - `uri`: the path and query, "/" for awsJson operations.
    - `header_names` / `header_values`: the operation's headers, in order,
      one name per value. Set through `set_header`.
    - `host_prefix`: the operation's `endpoint.hostPrefix` with its labels
      substituted, "" for none.
    - `body`: the serialized body.
    """

    var method: String
    var uri: String
    var header_names: List[String]
    var header_values: List[String]
    var host_prefix: String
    var body: String

    def __init__(out self, method: String, uri: String):
        self.method = method
        self.uri = uri
        self.header_names = List[String]()
        self.header_values = List[String]()
        self.host_prefix = String("")
        self.body = String("")

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
        var key = ascii_lower(name)
        for i in range(len(self.header_names)):
            if ascii_lower(self.header_names[i]) == key:
                return self.header_values[i]
        return String("")


struct HttpResult(Copyable, Movable):
    """One HTTP response: `status`, the response headers in order, and the
    `body`. Bodies can hold secrets; never log one."""

    var status: Int
    var header_names: List[String]
    var header_values: List[String]
    var body: String

    def __init__(out self, status: Int, body: String):
        self.status = status
        self.header_names = List[String]()
        self.header_values = List[String]()
        self.body = body

    def add_header(mut self, name: String, value: String):
        self.header_names.append(name)
        self.header_values.append(value)

    def header(self, name: String) -> String:
        """The first value of `name` (case-insensitive), "" when absent."""
        var key = ascii_lower(name)
        for i in range(len(self.header_names)):
            if ascii_lower(self.header_names[i]) == key:
                return self.header_values[i]
        return String("")
