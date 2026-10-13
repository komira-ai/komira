# =============================================================================
# komira_jose/header.mojo: split a JWS compact serialization (RFC 7515
#   section 7.1) and check its protected header, before any key work.
# =============================================================================
#
# A verifier is pinned to ONE algorithm. The header gate below refuses, in
# this order, each with a fixed `JoseError: ...` text:
#
#   1. a token longer than `JWS_MAX_COMPACT_BYTES`; anything but three
#      segments; an empty header or signature segment (an empty payload is
#      allowed, RFC 7515 appendix F); a header segment that is not base64url
#      without padding (RFC 7515 section 2);
#   2. a header that is not a JSON object, or names a member twice at any
#      depth (RFC 7515 section 5.2);
#   3. `alg` missing or not a string; `none` and every `HS*` by name; any
#      other value that is not the pinned algorithm. The pinned algorithm is
#      a gate, never a dispatch key: the verifier runs the pinned algorithm,
#      never one the header names;
#   4. `jwk`, `jku`, `x5u` and `x5c`, whatever their value: the key comes
#      from the verifier's configuration, never from the token;
#   5. `crit`, whatever it lists: this verifier understands no extension
#      (RFC 7515 section 4.1.11);
#   6. when a type is pinned (JWT verification): `typ` missing, not a
#      string, or not the pinned type, compared byte for byte;
#   7. `kid`, when present, that is not a non-empty string of printable
#      ASCII (0x20 to 0x7E); when required, a missing `kid`.
#
# Other members are ignored (RFC 7515 section 4). No message carries any
# byte of the token: an error text may reach a log.
# =============================================================================

from komira_encoding import base64_url_decode_nopad
from komira_json import (
    JSON_OBJECT,
    JSON_STRING,
    JsonValue,
    parse_json_bytes,
    refuse_duplicate_keys,
)


# The longest compact JWS the verifier reads, in bytes.
comptime JWS_MAX_COMPACT_BYTES: Int = 65536
# The nesting limit for the header and payload JSON.
comptime _JOSE_MAX_DEPTH: Int = 16


def _refuse(reason: String) raises:
    raise Error(String("JoseError: ") + reason)


struct JwsCompact(Copyable, Movable):
    """A compact JWS split at its two dots. `signing_input` is the original
    token bytes before the second dot (RFC 7515 section 5.2 step 8), never
    a re-encoding; `header` is the decoded protected header."""

    var signing_input: List[UInt8]
    var payload_b64: String
    var signature_b64: String
    var header: JsonValue

    def __init__(
        out self,
        var signing_input: List[UInt8],
        var payload_b64: String,
        var signature_b64: String,
        var header: JsonValue,
    ):
        self.signing_input = signing_input^
        self.payload_b64 = payload_b64^
        self.signature_b64 = signature_b64^
        self.header = header^


def _member_index(obj: JsonValue, name: String) -> Int:
    for i in range(len(obj.obj_keys)):
        if obj.obj_keys[i] == name:
            return i
    return -1


def header_string(header: JsonValue, name: String) -> Optional[String]:
    """The string value of the top-level member `name`, if it is present and
    a string."""
    var at = _member_index(header, name)
    if at < 0 or header.children[at].kind != JSON_STRING:
        return Optional[String]()
    return Optional[String](header.children[at].text.copy())


def is_printable_ascii(s: String) -> Bool:
    """True when `s` is non-empty and every byte is in 0x20..0x7E."""
    var b = s.as_bytes()
    if len(b) == 0:
        return False
    for i in range(len(b)):
        if b[i] < UInt8(0x20) or b[i] > UInt8(0x7E):
            return False
    return True


def _segment(token: String, start: Int, end: Int) -> String:
    """Bytes [start, end) of an ASCII-checked token."""
    return String(token[byte=start:end])


def split_compact(token: String) raises -> JwsCompact:
    """Step 1 and 2 of the gate: split `token` and decode its header."""
    var b = token.as_bytes()
    var n = len(b)
    if n > JWS_MAX_COMPACT_BYTES:
        _refuse(
            String("the token is longer than ")
            + String(JWS_MAX_COMPACT_BYTES)
            + " bytes"
        )
    var d1 = -1
    var d2 = -1
    for i in range(n):
        if b[i] > UInt8(0x7F):
            # Not base64url; refused here so that byte slicing below never
            # lands inside a multi-byte sequence.
            _refuse("the token is not ASCII")
        if b[i] == UInt8(0x2E):  # '.'
            if d1 < 0:
                d1 = i
            elif d2 < 0:
                d2 = i
            else:
                _refuse("a compact JWS has exactly three segments")
    if d2 < 0:
        _refuse("a compact JWS has exactly three segments")
    if d1 == 0:
        _refuse("the header segment is empty")
    if d2 == n - 1:
        _refuse("the signature segment is empty")
    var header_raw: List[UInt8]
    try:
        header_raw = base64_url_decode_nopad(_segment(token, 0, d1))
    except:
        raise Error(
            "JoseError: the header segment is not base64url without padding"
        )
    var header: JsonValue
    try:
        header = parse_json_bytes(header_raw, _JOSE_MAX_DEPTH)
    except:
        raise Error("JoseError: the header is not JSON")
    if header.kind != JSON_OBJECT:
        _refuse("the header is not a JSON object")
    try:
        refuse_duplicate_keys(header)
    except:
        _refuse("the header names a member twice")
    var si = List[UInt8](capacity=d2)
    for i in range(d2):
        si.append(b[i])
    return JwsCompact(
        si^,
        _segment(token, d1 + 1, d2),
        _segment(token, d2 + 1, n),
        header^,
    )


def check_header(
    header: JsonValue,
    pinned_alg: String,
    pinned_typ: Optional[String],
    require_kid: Bool,
) raises:
    """Steps 3 to 7 of the gate over a decoded header object."""
    var alg = header_string(header, "alg")
    if not alg:
        _refuse("header alg is missing or not a string")
    var a = alg.value()
    if a == "none":
        _refuse("alg none is refused")
    if a.startswith("HS"):
        _refuse("an HMAC alg (HS*) is refused")
    if a != pinned_alg:
        _refuse("alg is not the pinned algorithm")
    for name in ["jwk", "jku", "x5u", "x5c"]:
        if _member_index(header, String(name)) >= 0:
            _refuse(
                String("header member ")
                + name
                + " is refused: the key never comes from the token"
            )
    if _member_index(header, "crit") >= 0:
        _refuse("header member crit is refused: no extension is understood")
    if pinned_typ:
        var typ = header_string(header, "typ")
        if not typ:
            _refuse("header typ is missing or not a string")
        if typ.value() != pinned_typ.value():
            _refuse("header typ is not the pinned type")
    var at = _member_index(header, "kid")
    if at < 0:
        if require_kid:
            _refuse("header kid is missing")
        return
    ref kid = header.children[at]
    if kid.kind != JSON_STRING or not is_printable_ascii(kid.text):
        _refuse("header kid is not a non-empty printable ASCII string")
