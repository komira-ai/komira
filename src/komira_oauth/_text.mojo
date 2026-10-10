# =============================================================================
# komira_oauth/_text.mojo: the checks several wire codecs of this package
#   share: the refusal text, an https URL, an OAuth scope, and the strict
#   reading of a JSON object.
# =============================================================================
#
# `_https_url_refusal(url, allow_query)` is "" for an `https://` URL whose
# host is not empty and whose every byte is printable ASCII other than a
# space, with no `#` (no fragment) and, unless `allow_query`, no `?` (no
# query); otherwise it names the first problem.
#
# `_scope_refusal(scope)` is "" for a scope as RFC 6749 section 3.3 writes it:
# scope tokens of the bytes 0x21, 0x23 to 0x5B and 0x5D to 0x7E, each
# separated from the next by exactly one space, with no space at either end.
# The empty string is not a scope (a caller with no scope passes none).
#
# ENCAPSULATION: `String` and `komira_json` values in and out. No pointer
# crosses this file's API.
# =============================================================================

from komira_json import (
    JSON_ARRAY,
    JSON_OBJECT,
    JSON_STRING,
    JsonValue,
    parse_json_bytes,
    refuse_duplicate_keys,
    write_json_string,
)


# The nesting limit handed to the JSON parser: the deepest document of this
# package is a registration record holding a JWK Set (four levels).
comptime _OAUTH_MAX_DEPTH: Int = 16


def _refuse(reason: String) raises:
    raise Error(String("OAuthError: ") + reason)


def _lit(mut buf: List[UInt8], s: String):
    buf.extend(Span(s.as_bytes()))


def _https_url_refusal(url: String, allow_query: Bool) -> String:
    var b = url.as_bytes()
    var prefix = String("https://").as_bytes()
    if len(b) < len(prefix):
        return String("is not an https URL")
    for i in range(len(prefix)):
        if b[i] != prefix[i]:
            return String("is not an https URL")
    for i in range(len(b)):
        if b[i] < 0x21 or b[i] > 0x7E:
            return String("holds a byte that is not printable ASCII")
        if b[i] == 0x23:  # '#'
            return String("has a fragment")
        if b[i] == 0x3F and not allow_query:  # '?'
            return String("has a query")
    var host_end = len(prefix)
    while host_end < len(b) and b[host_end] != 0x2F and b[host_end] != 0x3F:
        host_end += 1
    if host_end == len(prefix):
        return String("has no host")
    return String("")


def _is_scope_byte(c: UInt8) -> Bool:
    return c == 0x21 or (c >= 0x23 and c <= 0x5B) or (c >= 0x5D and c <= 0x7E)


def _scope_refusal(scope: String) -> String:
    var b = scope.as_bytes()
    if len(b) == 0:
        return String("is empty")
    var after_space = True
    for i in range(len(b)):
        if b[i] == 0x20:
            if after_space:
                return String("has an empty scope token")
            after_space = True
        elif _is_scope_byte(b[i]):
            after_space = False
        else:
            return String("holds a byte a scope token cannot hold")
    if after_space:
        return String("has an empty scope token")
    return String("")


def _scope_tokens(scope: String) -> List[String]:
    """The space-separated tokens of a scope `_scope_refusal` passed."""
    var out = List[String]()
    for t in scope.split(" "):
        out.append(String(t))
    return out^


def _parse_object(doc: String, max_bytes: Int, what: String) raises -> JsonValue:
    """`doc` as a JSON object with no member named twice at any depth, or a
    refusal naming `what` (never a byte of `doc`)."""
    if doc.byte_length() > max_bytes:
        _refuse(what + " is longer than " + String(max_bytes) + " bytes")
    var bytes = List[UInt8]()
    bytes.extend(Span(doc.as_bytes()))
    var v: JsonValue
    try:
        v = parse_json_bytes(bytes, _OAUTH_MAX_DEPTH)
    except:
        raise Error(String("OAuthError: ") + what + " is not JSON")
    if v.kind != JSON_OBJECT:
        _refuse(what + " is not a JSON object")
    try:
        refuse_duplicate_keys(v)
    except:
        _refuse(what + " names a member twice")
    return v^


def _member(obj: JsonValue, name: String) -> Int:
    for i in range(len(obj.obj_keys)):
        if obj.obj_keys[i] == name:
            return i
    return -1


def _optional_string(obj: JsonValue, name: String) raises -> Optional[String]:
    """The member's string, None when absent; refused when present and not a
    non-empty string."""
    var at = _member(obj, name)
    if at < 0:
        return Optional[String]()
    if obj.children[at].kind != JSON_STRING:
        _refuse(String("member ") + name + " is not a string")
    if obj.children[at].text.byte_length() == 0:
        _refuse(String("member ") + name + " is empty")
    return Optional[String](obj.children[at].text.copy())


def _required_string(obj: JsonValue, name: String) raises -> String:
    var v = _optional_string(obj, name)
    if not v:
        _refuse(String("member ") + name + " is missing")
    return v.value()


def _string_list(obj: JsonValue, name: String) raises -> Optional[List[String]]:
    """The member's array of non-empty strings, None when absent; refused
    when present and not a non-empty array of distinct non-empty strings."""
    var at = _member(obj, name)
    if at < 0:
        return Optional[List[String]]()
    ref arr = obj.children[at]
    if arr.kind != JSON_ARRAY or len(arr.children) == 0:
        _refuse(String("member ") + name + " is not a non-empty array of strings")
    var out = List[String]()
    for i in range(len(arr.children)):
        if arr.children[i].kind != JSON_STRING:
            _refuse(String("member ") + name + " is not a non-empty array of strings")
        var s = arr.children[i].text.copy()
        if s.byte_length() == 0:
            _refuse(String("member ") + name + " holds an empty string")
        for j in range(len(out)):
            if out[j] == s:
                _refuse(String("member ") + name + " names a value twice")
        out.append(s^)
    return Optional[List[String]](out^)


def _write_string_list(mut buf: List[UInt8], values: List[String]):
    buf.append(0x5B)  # '['
    for i in range(len(values)):
        if i > 0:
            buf.append(0x2C)  # ','
        write_json_string(buf, values[i])
    buf.append(0x5D)  # ']'


def _distinct_nonempty_refusal(values: List[String]) -> String:
    for i in range(len(values)):
        if values[i].byte_length() == 0:
            return String("holds an empty string")
        for j in range(i):
            if values[j] == values[i]:
                return String("names a value twice")
    return String("")
