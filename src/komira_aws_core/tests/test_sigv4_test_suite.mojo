# =============================================================================
# komira_aws_core/tests/test_sigv4_test_suite.mojo
# =============================================================================
#
# Runs every case of the official AWS SigV4 signing test suite
# (tools/vendor/aws_sigv4_test_suite, staged at aws_sigv4_test_suite/), in
# both signing modes, byte for byte:
#
#   header signing: canonical request, string to sign, signature, and the
#     signed request (the headers added, the Authorization header among them)
#   query signing:  canonical request, string to sign, signature, and the
#     signed request (the presigned request target)
#
# The clock is fixed: each case's signing time is its context.json
# timestamp. Before any case runs, every staged file is checked against the
# sha256 lines of the suite's PIN, and the staged tree must hold exactly the
# files PIN lists, so the test cannot run a changed or a shrunken suite.
# =============================================================================

from std.os import listdir
from std.os.path import isdir

from komira_crypto import hex_lower_array_32, sha256

from komira_aws_core import (
    AwsCredential,
    Header,
    SigV4SigningContext,
    sigv4_presign,
    sigv4_sign,
)


comptime _ROOT = "aws_sigv4_test_suite/"


# The number of cases at the PIN'd commit. Update it with PIN.
comptime _EXPECTED_CASES = 38


def _case_files() -> List[String]:
    var out = List[String]()
    out.append(String("context.json"))
    out.append(String("header-canonical-request.txt"))
    out.append(String("header-signature.txt"))
    out.append(String("header-signed-request.txt"))
    out.append(String("header-string-to-sign.txt"))
    out.append(String("query-canonical-request.txt"))
    out.append(String("query-signature.txt"))
    out.append(String("query-signed-request.txt"))
    out.append(String("query-string-to-sign.txt"))
    out.append(String("request.txt"))
    return out^


# Every key a context.json may hold. A key outside this set is a signing
# option this test does not apply, so it fails rather than ignore it.
def _context_keys() -> List[String]:
    var out = List[String]()
    out.append(String("credentials"))
    out.append(String("access_key_id"))
    out.append(String("secret_access_key"))
    out.append(String("token"))
    out.append(String("expiration_in_seconds"))
    out.append(String("normalize"))
    out.append(String("region"))
    out.append(String("service"))
    out.append(String("sign_body"))
    out.append(String("timestamp"))
    out.append(String("omit_session_token"))
    return out^


def _read_text(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def _read_bytes(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def _sorted(var xs: List[String]) -> List[String]:
    for i in range(1, len(xs)):
        var cur = xs[i]
        var j = i - 1
        while j >= 0 and xs[j] > cur:
            xs[j + 1] = xs[j]
            j -= 1
        xs[j + 1] = cur
    return xs^


def _join(xs: List[String], sep: String) -> String:
    var out = String()
    for i in range(len(xs)):
        if i > 0:
            out += sep
        out += xs[i]
    return out^


def _contains(xs: List[String], x: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == x:
            return True
    return False


# -----------------------------------------------------------------------------
# PIN
# -----------------------------------------------------------------------------


def _verify_pin() raises -> List[String]:
    """Checks every staged file against PIN; returns the case names."""
    var lines = _read_text(_ROOT + "PIN").split("\n")
    var paths = List[String]()
    var cases = List[String]()
    for i in range(len(lines)):
        var line = String(lines[i])
        if not line.startswith("sha256 "):
            continue
        var parts = line.split(" ")
        if len(parts) != 3:
            raise Error("PIN: malformed line: " + line)
        var want = String(parts[1])
        var path = String(parts[2])
        var data = _read_bytes(_ROOT + path)
        var got = hex_lower_array_32(sha256(Span(data)))
        if got != want:
            raise Error("PIN: " + path + " has sha256 " + got + ", PIN says " + want)
        paths.append(path)
        var segs = path.split("/")
        if len(segs) != 3 or String(segs[0]) != "v4":
            raise Error("PIN: unexpected path " + path)
        var cname = String(segs[1])
        if not _contains(cases, cname):
            cases.append(cname)

    # The staged tree holds exactly the files PIN lists.
    var staged = List[String]()
    for name in listdir(_ROOT + "v4"):
        var cname = String(name)
        if not isdir(_ROOT + "v4/" + cname):
            raise Error("staged v4/" + cname + " is not a case directory")
        for f in listdir(_ROOT + "v4/" + cname):
            staged.append("v4/" + cname + "/" + String(f))
    var a = _join(_sorted(paths^), "\n")
    var b = _join(_sorted(staged^), "\n")
    if a != b:
        raise Error("staged files differ from PIN:\nPIN:\n" + a + "\nstaged:\n" + b)

    for i in range(len(cases)):
        var files = _case_files()
        for k in range(len(files)):
            if not _contains_path(a, "v4/" + cases[i] + "/" + files[k]):
                raise Error("case " + cases[i] + " has no " + files[k])
    if len(cases) != _EXPECTED_CASES:
        raise Error(
            "suite has "
            + String(len(cases))
            + " cases, expected "
            + String(_EXPECTED_CASES)
        )
    return _sorted(cases^)


def _contains_path(joined: String, path: String) -> Bool:
    return ("\n" + joined + "\n").find("\n" + path + "\n") >= 0


# -----------------------------------------------------------------------------
# context.json (flat keys, string / bool / integer values, no escapes)
# -----------------------------------------------------------------------------


def _json_value_start(text: String, key: String) -> Int:
    """Index of the value after `"key":`, or -1 when the key is absent."""
    var at = text.find('"' + key + '"')
    if at < 0:
        return -1
    var b = text.as_bytes()
    var i = at + key.byte_length() + 2
    while i < len(b) and (b[i] == UInt8(0x20) or b[i] == UInt8(0x0A)):
        i += 1
    if i >= len(b) or b[i] != UInt8(0x3A):
        return -1
    i += 1
    while i < len(b) and (b[i] == UInt8(0x20) or b[i] == UInt8(0x0A)):
        i += 1
    return i


def _json_raw(text: String, key: String) raises -> String:
    var i = _json_value_start(text, key)
    if i < 0:
        raise Error("context.json has no " + key)
    var b = text.as_bytes()
    if b[i] == UInt8(0x22):
        var j = i + 1
        while j < len(b) and b[j] != UInt8(0x22):
            if b[j] == UInt8(0x5C):
                raise Error("context.json: escaped string in " + key)
            j += 1
        return String(StringSlice(unsafe_from_utf8=b[i + 1 : j]))
    var j = i
    while j < len(b) and b[j] != UInt8(0x2C) and b[j] != UInt8(0x0A) and b[j] != UInt8(0x7D):
        j += 1
    return String(StringSlice(unsafe_from_utf8=b[i:j]))


def _json_bool(text: String, key: String, default: Bool) raises -> Bool:
    if _json_value_start(text, key) < 0:
        return default
    var v = _json_raw(text, key)
    if v == "true":
        return True
    if v == "false":
        return False
    raise Error("context.json: " + key + " is not a bool: " + v)


def _json_int(text: String, key: String) raises -> Int:
    var v = _json_raw(text, key)
    var b = v.as_bytes()
    if len(b) == 0:
        raise Error("context.json: " + key + " is empty")
    var n = 0
    for i in range(len(b)):
        if b[i] < UInt8(0x30) or b[i] > UInt8(0x39):
            raise Error("context.json: " + key + " is not an integer: " + v)
        n = n * 10 + Int(b[i]) - 0x30
    return n


def _check_context_keys(text: String) raises:
    var b = text.as_bytes()
    var i = 0
    while i < len(b):
        if b[i] == UInt8(0x22):
            var j = i + 1
            while j < len(b) and b[j] != UInt8(0x22):
                j += 1
            var k = j + 1
            while k < len(b) and b[k] == UInt8(0x20):
                k += 1
            if k < len(b) and b[k] == UInt8(0x3A):
                var key = String(StringSlice(unsafe_from_utf8=b[i + 1 : j]))
                if not _contains(_context_keys(), key):
                    raise Error("context.json has an unknown key: " + key)
            i = j + 1
        else:
            i += 1


@fieldwise_init
struct _Context(Movable):
    var ctx: SigV4SigningContext
    var expires: Int


def _load_context(text: String) raises -> _Context:
    _check_context_keys(text)
    var token = String("")
    if _json_value_start(text, "token") >= 0:
        token = _json_raw(text, "token")
    var ts = _json_raw(text, "timestamp")
    # The fixed clock: "YYYY-MM-DDTHH:MM:SSZ" -> "YYYYMMDDTHHMMSSZ".
    var amz_date = ts.replace("-", "").replace(":", "")
    var ctx = SigV4SigningContext(
        AwsCredential(
            _json_raw(text, "access_key_id"),
            _json_raw(text, "secret_access_key"),
            token,
        ),
        _json_raw(text, "region"),
        _json_raw(text, "service"),
        amz_date,
        sign_payload_header=_json_bool(text, "sign_body", False),
        normalize_path=_json_bool(text, "normalize", True),
        uri_encode_path=True,
        omit_session_token=_json_bool(text, "omit_session_token", False),
    )
    return _Context(ctx^, _json_int(text, "expiration_in_seconds"))


# -----------------------------------------------------------------------------
# request.txt / *-signed-request.txt
# -----------------------------------------------------------------------------


@fieldwise_init
struct _Request(Movable):
    var method: String
    var target: String
    var headers: List[Header]
    var body: String


def _parse_request(text: String) raises -> _Request:
    var head = text
    var body = String("")
    var sep = text.find("\n\n")
    if sep >= 0:
        head = String(StringSlice(unsafe_from_utf8=text.as_bytes()[0:sep]))
        var tb = text.as_bytes()
        body = String(StringSlice(unsafe_from_utf8=tb[sep + 2 : len(tb)]))
    var lines = head.split("\n")
    var first = String(lines[0])
    var sp = first.find(" ")
    if sp < 0 or not first.endswith(" HTTP/1.1"):
        raise Error("bad request line: " + first)
    var fb = first.as_bytes()
    var method = String(StringSlice(unsafe_from_utf8=fb[0:sp]))
    var target = String(StringSlice(unsafe_from_utf8=fb[sp + 1 : len(fb) - 9]))
    var headers = List[Header]()
    for i in range(1, len(lines)):
        var line = String(lines[i])
        if line.byte_length() == 0:
            continue
        if line.startswith(" ") or line.startswith("\t"):
            # obs-fold: a continuation line joins the previous value with SP.
            if len(headers) == 0:
                raise Error("continuation line before any header")
            headers[len(headers) - 1].value += " " + line
            continue
        var colon = line.find(":")
        if colon < 0:
            raise Error("bad header line: " + line)
        var lb = line.as_bytes()
        headers.append(
            Header(
                String(StringSlice(unsafe_from_utf8=lb[0:colon])),
                String(StringSlice(unsafe_from_utf8=lb[colon + 1 : len(lb)])),
            )
        )
    return _Request(method^, target^, headers^, body^)


def _header_lines(headers: List[Header]) -> String:
    """Headers as sorted "lowercase-name:value" lines (header names are case
    insensitive; the order of distinct headers carries no meaning)."""
    var xs = List[String]()
    for i in range(len(headers)):
        var n = headers[i].name
        var lower = n.lower()
        xs.append(lower + ":" + headers[i].value)
    return _join(_sorted(xs^), "\n")


# -----------------------------------------------------------------------------
# The cases
# -----------------------------------------------------------------------------


def _expect(
    mut failures: List[String], cname: String, what: String, got: String, want: String
):
    if got != want:
        failures.append(
            cname + ": " + what + "\n--- got ---\n" + got + "\n--- want ---\n" + want
        )


def _run_case(cname: String, mut failures: List[String]) raises:
    var dir = _ROOT + "v4/" + cname + "/"
    var c = _load_context(_read_text(dir + "context.json"))
    var req = _parse_request(_read_text(dir + "request.txt"))
    var body = req.body.as_bytes()

    # Header signing.
    var h = sigv4_sign(req.method, req.target, req.headers, body, c.ctx)
    _expect(failures, cname, "header canonical request", h.canonical_request, _read_text(dir + "header-canonical-request.txt"))
    _expect(failures, cname, "header string to sign", h.string_to_sign, _read_text(dir + "header-string-to-sign.txt"))
    _expect(failures, cname, "header signature", h.signature, _read_text(dir + "header-signature.txt"))
    var hs = _parse_request(_read_text(dir + "header-signed-request.txt"))
    var auth = String("")
    for i in range(len(hs.headers)):
        if hs.headers[i].name == "Authorization":
            auth = hs.headers[i].value
    _expect(failures, cname, "Authorization header", h.authorization, auth)
    var with_added = req.headers.copy()
    for i in range(len(h.headers_to_add)):
        with_added.append(h.headers_to_add[i])
    _expect(failures, cname, "header-signed request headers", _header_lines(with_added), _header_lines(hs.headers))
    _expect(failures, cname, "header-signed target", req.target, hs.target)
    _expect(failures, cname, "header-signed body", req.body, hs.body)

    # Query signing (presigned URL).
    var q = sigv4_presign(
        req.method,
        req.target,
        req.headers,
        hex_lower_array_32(sha256(body)),
        c.ctx,
        c.expires,
    )
    _expect(failures, cname, "query canonical request", q.canonical_request, _read_text(dir + "query-canonical-request.txt"))
    _expect(failures, cname, "query string to sign", q.string_to_sign, _read_text(dir + "query-string-to-sign.txt"))
    _expect(failures, cname, "query signature", q.signature, _read_text(dir + "query-signature.txt"))
    var qs = _parse_request(_read_text(dir + "query-signed-request.txt"))
    _expect(failures, cname, "presigned target", q.signed_target, qs.target)
    _expect(failures, cname, "query-signed request headers", _header_lines(req.headers), _header_lines(qs.headers))
    _expect(failures, cname, "query-signed body", req.body, qs.body)


def main() raises:
    var cases = _verify_pin()
    var failures = List[String]()
    for i in range(len(cases)):
        _run_case(cases[i], failures)
    for i in range(len(failures)):
        print("FAIL", failures[i])
    if len(failures) > 0:
        raise Error(String(len(failures)) + " SigV4 test-suite checks failed")
    print(
        "aws sigv4 test suite:",
        len(cases),
        "cases, header and query signing, all byte-identical",
    )
    print("OK")
