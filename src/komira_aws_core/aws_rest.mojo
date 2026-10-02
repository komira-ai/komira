# =============================================================================
# komira_aws_core/aws_rest.mojo -- the HTTP binding runtime of a REST client
# =============================================================================
#
# What a generated restJson1 / restXml client calls to put members on, and
# take them off, the parts of an HTTP message the Smithy HTTP binding traits
# name (https://smithy.io/2.0/spec/http-bindings.html). The scalar TEXT of a
# member is aws_text.mojo's; this module places that text.
#
# URI (`http` trait `uri`, `httpLabel`, `httpQuery`, `httpQueryParams`):
#
#   `AwsRestUri.expand(pattern, names, values)` substitutes each `{Name}` and
#   greedy `{Name+}` label of the operation's URI pattern. A label value is
#   percent-encoded as RFC 3986 section 2 says: every byte but the
#   unreserved set A-Z a-z 0-9 - . _ ~ becomes %XX, uppercase hex, over the
#   UTF-8 bytes. A greedy label keeps '/' (it spans segments); a plain label
#   encodes it. A label value is never normalized: "a/../b" and "/k" stay as
#   written, which is what S3 object keys need (an S3 key is a greedy
#   `{Key+}`; "." and ".." are ordinary key bytes). An empty label value is
#   refused (aws-sdk-go-v2 and smithy-rs refuse it: it would leave an empty
#   segment or collapse the path). The literal query of the pattern
#   ("?uploads", "?x-id=GetObject") is kept first, as written.
#
#   `add_query` appends an `httpQuery` member (once per element for a list);
#   `add_query_param` appends an `httpQueryParams` map entry, unless a
#   literal or an `httpQuery` member already binds that key -- those take
#   precedence (the httpQueryParams trait, "serialization rules"). Keys and
#   values are percent-encoded as labels are, '/' included.
#
#   `aws_host_label` / `aws_host_prefix` do the same for the `endpoint`
#   trait's hostPrefix, whose labels must be host labels.
#
# Headers (`httpHeader`, `httpPrefixHeaders`):
#
#   A list member is one header whose value is its elements joined by ", "
#   (RFC 9110 section 5.6.1). An element that is empty, holds ',' or '"',
#   or starts or ends with a space or tab is written as a quoted-string with
#   '"' and '\' backslash-escaped (section 5.6.4); without the quotes it
#   would not read back. A list of http-dates is the exception: each date
#   already holds a comma, and it is written bare -- every date is
#   "Www, ..." -- and read back two comma-separated pieces at a time.
#
#   A response field that arrives on several lines is one value, the lines
#   joined by ", " (RFC 9110 section 5.3); leading and trailing spaces and
#   tabs are not part of a value (section 5.5).
#
#   A prefix-header map writes one header per entry, named prefix + key, and
#   reads every response header whose name starts with the prefix, ASCII
#   case ignored, keyed by the rest of its name.
#
# Status (`httpResponseCode`): `aws_response_code`.
#
# restJson1 errors: `aws_rest_json_error`.
# =============================================================================

from ._flat_json import parse_top_level_strings
from ._text import ascii_lower, utf8_valid
from .aws_codec import (
    AWS_TS_RFC822,
    aws_error_code,
    aws_error_message_from_body,
)
from .aws_error import AwsErrorInfo, aws_request_id
from .aws_request import AwsRequest, AwsResponse
from .aws_text import aws_http_date_from_text, aws_text_ts
from .sigv4 import Header, uri_encode


comptime _SP = UInt8(0x20)
comptime _HT = UInt8(0x09)
comptime _COMMA = UInt8(0x2C)
comptime _DQUOTE = UInt8(0x22)
comptime _BSLASH = UInt8(0x5C)
comptime _LBRACE = UInt8(0x7B)
comptime _RBRACE = UInt8(0x7D)
comptime _PLUS = UInt8(0x2B)


def _bytes_text(b: Span[UInt8, _], lo: Int, hi: Int) -> String:
    """Bytes [lo, hi) of `b`, cut only at ASCII bytes by every caller."""
    return String(unsafe_from_utf8=b[lo:hi])


def _find_label(names: List[String], name: String) -> Int:
    for i in range(len(names)):
        if names[i] == name:
            return i
    return -1


# -----------------------------------------------------------------------------
# URI
# -----------------------------------------------------------------------------


struct AwsRestUri(Copyable, Movable):
    """A request target being built: the expanded `path` and the query
    parameters in order (the pattern's literal ones first)."""

    var path: String
    var _keys: List[String]
    var _pairs: List[String]
    var _bound: List[Bool]

    def __init__(out self, path: String):
        self.path = path
        self._keys = List[String]()
        self._pairs = List[String]()
        self._bound = List[Bool]()

    @staticmethod
    def expand(
        pattern: String, names: List[String], values: List[String]
    ) raises -> AwsRestUri:
        """The pattern with every `{Name}` / `{Name+}` replaced by the
        encoded value at the same index of `values` as `Name` in `names`
        (each value already in its aws_text form). Refuses a pattern that
        does not start with '/', an unterminated or empty label, a label in
        the query, a label with no value, and an empty value."""
        if len(names) != len(values):
            raise Error("AWS URI labels: names and values differ in length")
        var pb = pattern.as_bytes()
        if len(pb) == 0 or pb[0] != UInt8(0x2F):
            raise Error("an AWS URI pattern does not start with '/'")
        var q = len(pb)
        for i in range(len(pb)):
            if pb[i] == UInt8(0x3F):
                q = i
                break
        var path = String("")
        var i = 0
        var lit = 0
        while i < q:
            if pb[i] == _RBRACE:
                raise Error("an AWS URI pattern has '}' outside a label")
            if pb[i] != _LBRACE:
                i += 1
                continue
            path += _bytes_text(pb, lit, i)
            var start = i + 1
            var end = start
            while end < q and pb[end] != _RBRACE and pb[end] != _LBRACE:
                end += 1
            if end >= q or pb[end] != _RBRACE:
                raise Error("an AWS URI pattern has an unterminated label")
            var greedy = end > start and pb[end - 1] == _PLUS
            var name = _bytes_text(pb, start, end - 1 if greedy else end)
            if name.byte_length() == 0:
                raise Error("an AWS URI pattern has an empty label")
            var at = _find_label(names, name)
            if at < 0:
                raise Error("the AWS URI label " + name + " has no value")
            if values[at].byte_length() == 0:
                raise Error("the AWS URI label " + name + " is empty")
            path += uri_encode(values[at], keep_slash=greedy)
            i = end + 1
            lit = i
        path += _bytes_text(pb, lit, q)
        var out = AwsRestUri(path)
        # The literal query: `k=v` or a bare `k`, '&'-separated, kept as
        # written (the signer canonicalizes the encoding).
        var s = q + 1
        var j = s
        while j <= len(pb):
            if j < len(pb) and (pb[j] == _LBRACE or pb[j] == _RBRACE):
                raise Error("an AWS URI pattern has a label in its query")
            if j == len(pb) or pb[j] == UInt8(0x26):
                if j > s:
                    var eq = s
                    while eq < j and pb[eq] != UInt8(0x3D):
                        eq += 1
                    out._keys.append(_bytes_text(pb, s, eq))
                    out._pairs.append(_bytes_text(pb, s, j))
                    out._bound.append(True)
                s = j + 1
            j += 1
        return out^

    def add_query(mut self, key: String, value: String):
        """Appends an `httpQuery` member: `key=value`, both encoded. Call
        once per element for a list; an empty value is written `key=`."""
        self._keys.append(key)
        self._pairs.append(uri_encode(key) + "=" + uri_encode(value))
        self._bound.append(True)

    def add_query_param(mut self, key: String, value: String):
        """Appends an `httpQueryParams` map entry, unless the pattern's
        literal query or an `httpQuery` member binds `key`. Call once per
        element for a map of lists; call after every `add_query`."""
        for i in range(len(self._keys)):
            if self._bound[i] and self._keys[i] == key:
                return
        self._keys.append(key)
        self._pairs.append(uri_encode(key) + "=" + uri_encode(value))
        self._bound.append(False)

    def has_query(self, key: String) -> Bool:
        for i in range(len(self._keys)):
            if self._keys[i] == key:
                return True
        return False

    def query(self) -> String:
        """The query, without '?': the parameters joined by '&'."""
        var out = String("")
        for i in range(len(self._pairs)):
            if i > 0:
                out += "&"
            out += self._pairs[i]
        return out^

    def target(self) -> String:
        """The request target for `AwsRequest.uri`: the path, then '?' and
        the query when there is one."""
        if len(self._pairs) == 0:
            return self.path
        return self.path + "?" + self.query()


def aws_host_label(value: String) raises -> String:
    """`value` when it is a host label as the Smithy rules engine's
    `isValidHostLabel` defines one -- `[A-Za-z0-9][A-Za-z0-9-]{0,62}` --
    and refused otherwise (the `endpoint` trait requires every hostPrefix
    label value to be one)."""
    var b = value.as_bytes()
    if len(b) == 0 or len(b) > 63:
        raise Error("an AWS host label is empty or longer than 63 bytes")
    for i in range(len(b)):
        var c = b[i]
        var alnum = (
            (c >= UInt8(0x41) and c <= UInt8(0x5A))
            or (c >= UInt8(0x61) and c <= UInt8(0x7A))
            or (c >= UInt8(0x30) and c <= UInt8(0x39))
        )
        if not alnum and (i == 0 or c != UInt8(0x2D)):
            raise Error(
                "an AWS host label holds a byte outside [A-Za-z0-9-] or"
                " starts with '-'"
            )
    return value


def aws_host_prefix(
    pattern: String, names: List[String], values: List[String]
) raises -> String:
    """The `endpoint` trait's hostPrefix with each `{Name}` replaced by its
    value, checked by `aws_host_label`, for `AwsRequest.host_prefix`."""
    if len(names) != len(values):
        raise Error("AWS host labels: names and values differ in length")
    var pb = pattern.as_bytes()
    var out = String("")
    var i = 0
    var lit = 0
    while i < len(pb):
        if pb[i] == _RBRACE:
            raise Error("an AWS host prefix has '}' outside a label")
        if pb[i] != _LBRACE:
            i += 1
            continue
        out += _bytes_text(pb, lit, i)
        var end = i + 1
        while end < len(pb) and pb[end] != _RBRACE:
            end += 1
        if end >= len(pb):
            raise Error("an AWS host prefix has an unterminated label")
        var name = _bytes_text(pb, i + 1, end)
        var at = _find_label(names, name)
        if at < 0:
            raise Error("the AWS host label " + name + " has no value")
        out += aws_host_label(values[at])
        i = end + 1
        lit = i
    out += _bytes_text(pb, lit, len(pb))
    return out^


# -----------------------------------------------------------------------------
# Header lists
# -----------------------------------------------------------------------------


def _is_ows(c: UInt8) -> Bool:
    return c == _SP or c == _HT


def _trim_ows(s: String) -> String:
    var b = s.as_bytes()
    var lo = 0
    var hi = len(b)
    while lo < hi and _is_ows(b[lo]):
        lo += 1
    while hi > lo and _is_ows(b[hi - 1]):
        hi -= 1
    return _bytes_text(b, lo, hi)


def _needs_quotes(v: String) -> Bool:
    var b = v.as_bytes()
    if len(b) == 0 or _is_ows(b[0]) or _is_ows(b[len(b) - 1]):
        return True
    for i in range(len(b)):
        if b[i] == _COMMA or b[i] == _DQUOTE:
            return True
    return False


def _quoted(v: String) -> String:
    var b = v.as_bytes()
    var out = List[UInt8](capacity=len(b) + 2)
    out.append(_DQUOTE)
    for i in range(len(b)):
        if b[i] == _DQUOTE or b[i] == _BSLASH:
            out.append(_BSLASH)
        out.append(b[i])
    out.append(_DQUOTE)
    return String(unsafe_from_utf8=Span(out))


def aws_header_list(values: List[String]) -> String:
    """A list header's value: the elements joined by ", ", each quoted when
    it would not otherwise read back (see the module header). An empty
    list is ""; a generated client sends no header for it."""
    var out = String("")
    for i in range(len(values)):
        if i > 0:
            out += ", "
        if _needs_quotes(values[i]):
            out += _quoted(values[i])
        else:
            out += values[i]
    return out^


def aws_header_http_date_list(epochs: List[Float64]) raises -> String:
    """A list of timestamps as http-dates, joined by ", ", unquoted."""
    var out = String("")
    for i in range(len(epochs)):
        if i > 0:
            out += ", "
        out += aws_text_ts(epochs[i], AWS_TS_RFC822)
    return out^


def aws_header_list_from(text: String) raises -> List[String]:
    """The elements of a list header (RFC 9110 section 5.6.1): split at
    commas outside quoted-strings, spaces and tabs around each element
    dropped, a quoted-string unquoted with its backslash escapes undone.
    Empty elements are skipped, as that section says a recipient does; an
    empty quoted-string ("") is an empty element that is kept. Refuses an
    unterminated quoted-string and text after a closing quote."""
    var out = List[String]()
    var b = text.as_bytes()
    var n = len(b)
    var i = 0
    while i <= n:
        while i < n and _is_ows(b[i]):
            i += 1
        if i < n and b[i] == _DQUOTE:
            var val = List[UInt8]()
            i += 1
            var closed = False
            while i < n:
                var c = b[i]
                if c == _BSLASH and i + 1 < n:
                    val.append(b[i + 1])
                    i += 2
                    continue
                if c == _DQUOTE:
                    closed = True
                    i += 1
                    break
                val.append(c)
                i += 1
            if not closed:
                raise Error("an AWS list header has an unterminated quote")
            while i < n and _is_ows(b[i]):
                i += 1
            if i < n and b[i] != _COMMA:
                raise Error("an AWS list header has text after a quote")
            out.append(String(unsafe_from_utf8=Span(val)))
            i += 1
            continue
        var s = i
        while i < n and b[i] != _COMMA:
            i += 1
        var e = i
        while e > s and _is_ows(b[e - 1]):
            e -= 1
        if e > s:
            out.append(_bytes_text(b, s, e))
        i += 1
    return out^


def aws_header_http_date_list_from(text: String) raises -> List[Float64]:
    """The timestamps of a list header of http-dates: each element either
    a whole quoted http-date or, unquoted, the two comma-separated pieces
    "Www" and "DD Mmm YYYY HH:MM:SS GMT"."""
    var parts = aws_header_list_from(text)
    var out = List[Float64]()
    var i = 0
    while i < len(parts):
        if parts[i].byte_length() > 3:
            out.append(aws_http_date_from_text(parts[i]))
            i += 1
            continue
        if i + 1 >= len(parts):
            raise Error("an AWS http-date list ends inside a date")
        out.append(aws_http_date_from_text(parts[i] + ", " + parts[i + 1]))
        i += 2
    return out^


# -----------------------------------------------------------------------------
# Response fields and prefix headers
# -----------------------------------------------------------------------------


def aws_header_field(resp: AwsResponse, name: String) -> String:
    """The value of field `name` (case-insensitive): every line of it, each
    trimmed of spaces and tabs, joined by ", ". "" when absent; tell absent
    from empty with `resp.has_header`."""
    var key = ascii_lower(name)
    var out = String("")
    var first = True
    for i in range(len(resp.header_names)):
        if ascii_lower(resp.header_names[i]) != key:
            continue
        if not first:
            out += ", "
        out += _trim_ows(resp.header_values[i])
        first = False
    return out^


def aws_set_prefix_headers(
    mut req: AwsRequest,
    prefix: String,
    keys: List[String],
    values: List[String],
) raises:
    """Sets header prefix + keys[i] to values[i] for every entry of an
    `httpPrefixHeaders` map. Refuses an empty key (it would name the
    prefix alone, which no reader maps back) and whatever `set_header`
    refuses."""
    if len(keys) != len(values):
        raise Error("AWS prefix headers: keys and values differ in length")
    for i in range(len(keys)):
        if keys[i].byte_length() == 0:
            raise Error("an AWS prefix-header map has an empty key")
        req.set_header(prefix + keys[i], values[i])


def aws_prefix_headers(resp: AwsResponse, prefix: String) -> List[Header]:
    """The `httpPrefixHeaders` map of a response: every header whose name
    starts with `prefix` (ASCII case ignored), keyed by the rest of its
    name in the case it first arrived in. Lines whose names differ only in
    case are one field (RFC 9110 section 5.1): their values are joined by
    ", " in arrival order. Values are trimmed of spaces and tabs."""
    var raw = resp.headers_with_prefix(prefix)
    var out = List[Header]()
    var lowered = List[String]()
    for i in range(len(raw)):
        var key = ascii_lower(raw[i].name)
        var value = _trim_ows(raw[i].value)
        var at = -1
        for k in range(len(lowered)):
            if lowered[k] == key:
                at = k
                break
        if at < 0:
            lowered.append(key)
            out.append(Header(raw[i].name, value))
        else:
            out[at].value = out[at].value + ", " + value
    return out^


# -----------------------------------------------------------------------------
# Status and restJson1 errors
# -----------------------------------------------------------------------------


def aws_response_code(resp: AwsResponse) -> Int32:
    """The value of an `httpResponseCode` output member: the status."""
    return Int32(resp.status)


def aws_rest_json_error(resp: AwsResponse) -> AwsErrorInfo:
    """The `AwsErrorInfo` of a restJson1 response
    (https://smithy.io/2.0/aws/protocols/aws-restjson1-protocol.html,
    "Operation error serialization"): the code is the `X-Amzn-Errortype`
    header when present and non-empty, else the body's top-level `code`,
    else its `__type`, each cut at the first ':' and after the last '#'
    by `aws_error_code`; "" when none names one. The message is the body's
    `message` / `Message` / `errorMessage`, the request id the
    `x-amzn-RequestId` header. Nothing else from the body is read."""
    var code = String("")
    if resp.has_header(String("X-Amzn-Errortype")):
        code = aws_error_code(resp.header(String("X-Amzn-Errortype")))
    if code.byte_length() == 0 and utf8_valid(Span(resp.body)):
        try:
            var j = parse_top_level_strings(
                String(unsafe_from_utf8=Span(resp.body))
            )
            if j.has("code"):
                code = aws_error_code(j.get("code"))
            elif j.has("__type"):
                code = aws_error_code(j.get("__type"))
        except:
            pass
    return AwsErrorInfo(
        resp.status,
        code,
        aws_error_message_from_body(resp.body),
        aws_request_id(resp, String("x-amzn-RequestId")),
    )
