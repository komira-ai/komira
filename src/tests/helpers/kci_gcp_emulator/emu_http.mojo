# =============================================================================
# kci_gcp_emulator/emu_http.mojo: the emulator's HTTP/1.1, server side.
# =============================================================================
#
# What a request the generated GCP clients send looks like to the emulator
# (`EmuRequest`: the method, the path percent-decoded, the query pairs, the
# Host and Authorization headers, the body), and what it answers
# (`EmuResponse`, written by `response_bytes` with `Connection: close`, so
# the client never reuses the connection). A request is complete when its
# head has ended and `Content-Length` bytes of body follow (a chunked body
# is decoded too). The error envelope is Google's `google.rpc.Status` JSON
# shape (`{"error":{"code":..,"message":..,"status":..}}`), which
# komira_gcp_core's `gcp_status_error` reads, so a client raises what a
# real service's refusal raises.
#
# JSON helpers the routes share live here too: a member read with a
# default, and an object rebuilt with one member replaced (komira_json's
# `set_member` appends).
# =============================================================================

from komira_json import JsonValue, parse_json_value


struct EmuRequest(Copyable, Movable):
    """One parsed request."""

    var method: String
    var path: String
    var query_keys: List[String]
    var query_values: List[String]
    var host: String
    var authorization: String
    var body: String

    def __init__(out self):
        self.method = String("")
        self.path = String("")
        self.query_keys = List[String]()
        self.query_values = List[String]()
        self.host = String("")
        self.authorization = String("")
        self.body = String("")

    def __init__(out self, *, copy: Self):
        self.method = copy.method.copy()
        self.path = copy.path.copy()
        self.query_keys = copy.query_keys.copy()
        self.query_values = copy.query_values.copy()
        self.host = copy.host.copy()
        self.authorization = copy.authorization.copy()
        self.body = copy.body.copy()

    def query(self, key: String) -> String:
        """The first value of query parameter `key`, or empty."""
        for i in range(len(self.query_keys)):
            if self.query_keys[i] == key:
                return self.query_values[i].copy()
        return String("")


struct EmuResponse(Copyable, Movable):
    """One answer: the status, its reason phrase and a JSON body."""

    var status: Int
    var reason: String
    var body: String

    def __init__(out self, status: Int, reason: String, body: String):
        self.status = status
        self.reason = reason
        self.body = body

    def __init__(out self, *, copy: Self):
        self.status = copy.status
        self.reason = copy.reason.copy()
        self.body = copy.body.copy()


def ok(body: String) -> EmuResponse:
    return EmuResponse(200, String("OK"), body)


def _status_word(code: Int) -> String:
    if code == 400:
        return String("INVALID_ARGUMENT")
    if code == 401:
        return String("UNAUTHENTICATED")
    if code == 403:
        return String("PERMISSION_DENIED")
    if code == 404:
        return String("NOT_FOUND")
    if code == 504:
        return String("DEADLINE_EXCEEDED")
    return String("INTERNAL")


def failure(code: Int, message: String, status: String = String("")) -> EmuResponse:
    """A `google.rpc.Status` envelope with HTTP status `code`; `status` is
    the code's name (derived from `code` when empty: 409 needs it said,
    ALREADY_EXISTS or ABORTED)."""
    var word = status.copy() if status.byte_length() > 0 else _status_word(code)
    var env = JsonValue.empty_object()
    var err = JsonValue.empty_object()
    try:
        err.set_member(String("code"), JsonValue.from_i64(Int64(code)))
        err.set_member(String("message"), JsonValue.from_string(message.copy()))
        err.set_member(String("status"), JsonValue.from_string(word.copy()))
        env.set_member(String("error"), err^)
    except:
        pass
    var reason = String("Error")
    if code == 404:
        reason = String("Not Found")
    elif code == 409:
        reason = String("Conflict")
    return EmuResponse(code, reason, env.serialize())


def response_bytes(r: EmuResponse) -> List[UInt8]:
    var text = (
        String("HTTP/1.1 ")
        + String(r.status)
        + String(" ")
        + r.reason
        + String("\r\nContent-Type: application/json\r\nContent-Length: ")
        + String(r.body.byte_length())
        + String("\r\nConnection: close\r\n\r\n")
        + r.body
    )
    var out = List[UInt8]()
    out.extend(Span(text.as_bytes()))
    return out^


def _hex(c: Int) -> Int:
    if c >= ord("0") and c <= ord("9"):
        return c - ord("0")
    if c >= ord("a") and c <= ord("f"):
        return c - ord("a") + 10
    if c >= ord("A") and c <= ord("F"):
        return c - ord("A") + 10
    return -1


def percent_decode(s: String, plus_is_space: Bool = False) -> String:
    """`%XX` escapes decoded (and `+` as a space in a query value)."""
    var b = s.as_bytes()
    var out = List[UInt8]()
    var i = 0
    while i < len(b):
        var c = Int(b[i])
        if c == ord("%") and i + 2 < len(b):
            var hi = _hex(Int(b[i + 1]))
            var lo = _hex(Int(b[i + 2]))
            if hi >= 0 and lo >= 0:
                out.append(UInt8(hi * 16 + lo))
                i += 3
                continue
        if plus_is_space and c == ord("+"):
            out.append(UInt8(ord(" ")))
        else:
            out.append(b[i])
        i += 1
    return String(unsafe_from_utf8=Span(out))


def _lower(s: String) -> String:
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        var c = b[i]
        if c >= UInt8(0x41) and c <= UInt8(0x5A):
            c += 0x20
        out.append(c)
    return String(unsafe_from_utf8=Span(out))


def _find(b: List[UInt8], needle: String, start: Int) -> Int:
    var n = needle.as_bytes()
    var i = start
    while i + len(n) <= len(b):
        var hit = True
        for k in range(len(n)):
            if b[i + k] != n[k]:
                hit = False
                break
        if hit:
            return i
        i += 1
    return -1


def _text(b: List[UInt8], start: Int, end: Int) -> String:
    var out = List[UInt8]()
    for i in range(start, end):
        out.append(b[i])
    return String(unsafe_from_utf8=Span(out))


def _dechunk(b: List[UInt8], start: Int) -> Optional[String]:
    """A chunked body from `start`, or None while it is incomplete."""
    var out = List[UInt8]()
    var at = start
    while True:
        var eol = _find(b, String("\r\n"), at)
        if eol < 0:
            return None
        var size_text = _text(b, at, eol)
        var semi = size_text.find(";")
        if semi >= 0:
            var head = String(size_text[byte=0:semi])
            size_text = head^
        var size = 0
        var sb = size_text.as_bytes()
        for i in range(len(sb)):
            var h = _hex(Int(sb[i]))
            if h < 0:
                return None
            size = size * 16 + h
        at = eol + 2
        if size == 0:
            return String(unsafe_from_utf8=Span(out))
        if at + size + 2 > len(b):
            return None
        for i in range(size):
            out.append(b[at + i])
        at += size + 2


def parse_request(b: List[UInt8]) raises -> Optional[EmuRequest]:
    """The request `b` holds, or None while it is incomplete; raises for a
    head that is not HTTP/1.1."""
    var end = _find(b, String("\r\n\r\n"), 0)
    if end < 0:
        return None
    var head = _text(b, 0, end)
    var lines = head.split("\r\n")
    var first = String(lines[0])
    var sp1 = first.find(" ")
    var sp2 = first.rfind(" ")
    if sp1 <= 0 or sp2 <= sp1:
        raise Error(String("emulator: a request line that is not HTTP/1.1: ") + first)
    var req = EmuRequest()
    req.method = String(first[byte=0:sp1])
    var target = String(first[byte = sp1 + 1 : sp2])
    var q = target.find("?")
    var raw_path = target.copy()
    if q >= 0:
        raw_path = String(target[byte=0:q])
        var query = String(target[byte = q + 1 : target.byte_length()])
        var pairs = query.split("&")
        for i in range(len(pairs)):
            var pair = String(pairs[i])
            if pair.byte_length() == 0:
                continue
            var eq = pair.find("=")
            if eq < 0:
                req.query_keys.append(percent_decode(pair, True))
                req.query_values.append(String(""))
            else:
                req.query_keys.append(percent_decode(String(pair[byte=0:eq]), True))
                req.query_values.append(percent_decode(String(pair[byte = eq + 1 : pair.byte_length()]), True))
    req.path = percent_decode(raw_path)
    var length = 0
    var chunked = False
    for i in range(1, len(lines)):
        var line = String(lines[i])
        var colon = line.find(":")
        if colon <= 0:
            continue
        var name = _lower(String(line[byte=0:colon]))
        var value = String(String(line[byte = colon + 1 : line.byte_length()]).strip())
        if name == "host":
            req.host = value.copy()
        elif name == "authorization":
            req.authorization = value.copy()
        elif name == "content-length":
            length = atol(value)
        elif name == "transfer-encoding" and _lower(value).find("chunked") >= 0:
            chunked = True
    var body_start = end + 4
    if chunked:
        var body = _dechunk(b, body_start)
        if not body:
            return None
        req.body = body.value().copy()
        return req^
    if body_start + length > len(b):
        return None
    req.body = _text(b, body_start, body_start + length)
    return req^


# --- JSON helpers -------------------------------------------------------------


def parse_object(text: String) raises -> JsonValue:
    """`text` as a JSON object (an empty body reads as `{}`)."""
    if text.byte_length() == 0:
        return JsonValue.empty_object()
    var v = parse_json_value(text)
    if not v.is_object():
        raise Error("emulator: the body is not a JSON object")
    return v^


def str_member(obj: JsonValue, key: String) -> String:
    """String member `key`, or empty when absent or not a string."""
    try:
        if obj.has(key):
            var v = obj.get(key)
            if v.is_string():
                return v.as_string()
    except:
        pass
    return String("")


def with_member(obj: JsonValue, key: String, var value: JsonValue) raises -> JsonValue:
    """`obj` with member `key` set to `value` (replaced in place where it
    was, else appended)."""
    var out = JsonValue.empty_object()
    var done = False
    for i in range(obj.num_members()):
        var k = obj.key_at(i)
        if k == key:
            if not done:
                out.set_member(k^, value.copy())
                done = True
            continue
        out.set_member(k^, obj.value_at(i))
    if not done:
        out.set_member(key.copy(), value^)
    return out^


def without_member(obj: JsonValue, key: String) raises -> JsonValue:
    """`obj` with member `key` removed."""
    var out = JsonValue.empty_object()
    for i in range(obj.num_members()):
        var k = obj.key_at(i)
        if k == key:
            continue
        out.set_member(k^, obj.value_at(i))
    return out^
