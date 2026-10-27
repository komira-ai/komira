# =============================================================================
# test_header_gate.mojo: every refusal of the header gate (header.mojo), its
#   exact text, its boundaries, and that it fires before any key work.
# =============================================================================
#
# Tokens are minted here with Ed25519 (the RFC 8037 appendix A key), so a
# header the gate should let through also verifies: each refusal below is the
# gate's, not a signature failure in disguise (test_baseline_verifies proves
# the minting). Where a test says "garbage signature", the token's signature
# is four bytes of zero, so only a check before the signature can produce the
# asserted text.
#
# main runs every test and reports every failure, so that one build shows
# each planted mutant's test.
# =============================================================================

from std.testing import assert_equal

from komira_crypto import ed25519_sign
from komira_encoding import base64_url_decode_nopad, base64_url_encode_nopad
from komira_jose import JWS_MAX_COMPACT_BYTES, JwsVerifier
from komira_jwks import Jwk, JwkSet


comptime SEED = "nWGxne_9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A"
comptime X = "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"
comptime GOOD = '{"alg":"EdDSA","kid":"k1"}'


def _b64(s: String) -> String:
    return base64_url_encode_nopad(s.as_bytes())


def _sign(signing_input: String) raises -> String:
    var seed = base64_url_decode_nopad(SEED)
    var sig = ed25519_sign(Span(seed), signing_input.as_bytes())
    var b = List[UInt8]()
    for i in range(64):
        b.append(sig[i])
    return base64_url_encode_nopad(Span(b))


def _mint_raw(header_seg: String, payload_seg: String) raises -> String:
    var si = header_seg + "." + payload_seg
    return si + "." + _sign(si)


def _mint(header: String, payload: String = "{}") raises -> String:
    return _mint_raw(_b64(header), _b64(payload))


def _garbage(header: String) -> String:
    return _b64(header) + "." + _b64("{}") + ".AAAAAA"


def _verifier() raises -> JwsVerifier:
    var x = base64_url_decode_nopad(X)
    var keys = List[Jwk]()
    keys.append(Jwk.ed25519(Span(x), kid=String("k1")))
    keys.append(Jwk.ed25519(Span(x), kid=String(" ~")))
    return JwsVerifier("EdDSA", JwkSet(keys^, List[String]()))


def _err(token: String) raises -> String:
    var v = _verifier()
    try:
        _ = v.verify(token)
    except e:
        return String(e)
    return String("")


comptime THREE = "JoseError: a compact JWS has exactly three segments"
comptime NOT_JSON = "JoseError: the header is not JSON"
comptime TWICE = "JoseError: the header names a member twice"
comptime ALG_MISSING = "JoseError: header alg is missing or not a string"
comptime NONE = "JoseError: alg none is refused"
comptime HMAC = "JoseError: an HMAC alg (HS*) is refused"
comptime NOT_PINNED = "JoseError: alg is not the pinned algorithm"
comptime CRIT = "JoseError: header member crit is refused: no extension is understood"
comptime KID_MISSING = "JoseError: header kid is missing"
comptime KID_BAD = "JoseError: header kid is not a non-empty printable ASCII string"
comptime NO_KEY = "JoseError: kid names no key in the set"


def _key_member(name: String) -> String:
    return (
        String("JoseError: header member ")
        + name
        + " is refused: the key never comes from the token"
    )


def test_baseline_verifies() raises:
    # Catches: a minting helper or verifier that never accepts, which would
    # make every refusal below vacuous.
    var got = _verifier().verify(_mint(GOOD, '{"a":1}'))
    var p = got.payload()
    assert_equal(len(p), 7)
    assert_equal(got.kid().value(), "k1")
    # An empty payload is allowed (RFC 7515 appendix F).
    assert_equal(len(_verifier().verify(_mint(GOOD, "")).payload()), 0)


def test_compact_form() raises:
    # Catches: a split that accepts two or four segments, an empty header or
    # signature, or a padded or non-base64url header.
    var t = _mint(GOOD)
    assert_equal(_err(""), THREE)
    assert_equal(_err("abc"), THREE)
    assert_equal(_err("a.b"), THREE)
    assert_equal(_err(t + ".x"), THREE)
    assert_equal(_err(t + "."), THREE)
    assert_equal(_err(".e30.AAAA"), "JoseError: the header segment is empty")
    assert_equal(
        _err(_b64(GOOD) + ".e30."), "JoseError: the signature segment is empty"
    )
    comptime NOT_B64 = "JoseError: the header segment is not base64url without padding"
    assert_equal(_err(_b64(GOOD) + "=.e30.AAAA"), NOT_B64)
    assert_equal(_err("eyJ+.e30.AAAA"), NOT_B64)
    assert_equal(_err("eyJ/.e30.AAAA"), NOT_B64)


def test_ascii_boundary() raises:
    # Catches: the ASCII check moved below 0x80. 0x7F (DEL) is ASCII and
    # passes it (then fails base64url); U+0080 (bytes C2 80) does not.
    var del_tok = String("e") + chr(0x7F) + ".e30.AAAA"
    assert_equal(
        _err(del_tok),
        "JoseError: the header segment is not base64url without padding",
    )
    var hi_tok = String("e") + chr(0x80) + ".e30.AAAA"
    assert_equal(_err(hi_tok), "JoseError: the token is not ASCII")


def test_length_boundary() raises:
    # Catches: the cap moved by one either way.
    var at_cap = String("")
    for _ in range(JWS_MAX_COMPACT_BYTES):
        at_cap += "A"
    assert_equal(_err(at_cap), THREE)
    assert_equal(
        _err(at_cap + "A"),
        String("JoseError: the token is longer than ")
        + String(JWS_MAX_COMPACT_BYTES)
        + " bytes",
    )


def test_header_json() raises:
    # Catches: a header read with a lenient or first-match reader.
    assert_equal(_err(_garbage('{"alg":"EdDSA","kid":"k1"')), NOT_JSON)
    assert_equal(_err(_garbage(" ")), NOT_JSON)
    assert_equal(
        _err(_garbage('["alg","EdDSA"]')), "JoseError: the header is not a JSON object"
    )
    # Ill-formed UTF-8 inside a string member.
    var raw = List[UInt8]()
    raw.extend(String('{"alg":"EdDSA","kid":"').as_bytes())
    raw.append(0xFF)
    raw.extend(String('"}').as_bytes())
    assert_equal(
        _err(base64_url_encode_nopad(Span(raw)) + ".e30.AAAA"), NOT_JSON
    )


def test_duplicate_members() raises:
    # Catches: duplicates kept (RFC 7515 section 5.2), at the top or nested.
    assert_equal(_err(_mint('{"alg":"EdDSA","alg":"EdDSA","kid":"k1"}')), TWICE)
    assert_equal(_err(_mint('{"alg":"none","kid":"k1","alg":"EdDSA"}')), TWICE)
    assert_equal(
        _err(_mint('{"alg":"EdDSA","kid":"k1","x":{"a":1,"a":2}}')), TWICE
    )


def test_alg() raises:
    # Catches: `none` or `HS*` reaching key work, a case-insensitive or
    # prefix match, or a missing alg read as a default.
    assert_equal(_err(_mint('{"kid":"k1"}')), ALG_MISSING)
    assert_equal(_err(_mint('{"alg":1,"kid":"k1"}')), ALG_MISSING)
    assert_equal(_err(_mint('{"alg":null,"kid":"k1"}')), ALG_MISSING)
    assert_equal(_err(_garbage('{"alg":"none","kid":"k1"}')), NONE)
    assert_equal(_err(_garbage('{"alg":"HS256","kid":"k1"}')), HMAC)
    assert_equal(_err(_garbage('{"alg":"HS512","kid":"k1"}')), HMAC)
    assert_equal(_err(_garbage('{"alg":"HS","kid":"k1"}')), HMAC)
    assert_equal(_err(_garbage('{"alg":"None","kid":"k1"}')), NOT_PINNED)
    assert_equal(_err(_mint('{"alg":"ES256","kid":"k1"}')), NOT_PINNED)
    assert_equal(_err(_mint('{"alg":"eddsa","kid":"k1"}')), NOT_PINNED)
    assert_equal(_err(_mint('{"alg":"EdDSA ","kid":"k1"}')), NOT_PINNED)
    assert_equal(_err(_mint('{"alg":"Ed25519","kid":"k1"}')), NOT_PINNED)
    # A prefix of the pinned alg, down to the empty string, is not it.
    assert_equal(_err(_mint('{"alg":"EdDS","kid":"k1"}')), NOT_PINNED)
    assert_equal(_err(_mint('{"alg":"","kid":"k1"}')), NOT_PINNED)
    # The pinned alg with something in front of it is not it.
    assert_equal(_err(_mint('{"alg":"xEdDSA","kid":"k1"}')), NOT_PINNED)
    # A proper suffix of the pinned alg is not it.
    assert_equal(_err(_mint('{"alg":"dDSA","kid":"k1"}')), NOT_PINNED)
    # The same length with the first or the last byte replaced is not it
    # (catches a byte loop that skips either end), and the same holds for
    # `none`: `zone` and `nonz` are merely unpinned.
    var misses = String("")
    for a in ["FdDSA", "EdDSB", "zone", "nonz"]:
        var h = String('{"alg":"') + String(a) + '","kid":"k1"}'
        var got = _err(_mint(h))
        if got != NOT_PINNED:
            misses += String(a) + " -> " + got + "; "
    # The member is named `alg` exactly: a header whose only near name is
    # another member (a prefix, an extension at either end, a suffix, a case
    # variant, the first or last byte replaced) has no alg.
    for m in ["al", "algx", "xalg", "lg", "ALG", "zlg", "alz"]:
        var h = String('{"') + String(m) + '":"EdDSA","kid":"k1"}'
        var got = _err(_mint(h))
        if got != ALG_MISSING:
            misses += String("member ") + String(m) + " -> " + got + "; "
    assert_equal(misses, "")


def test_crit_cannot_hide_alg() raises:
    # Catches: a substring or first-match header read, where an `alg` inside
    # another member hides the real one.
    assert_equal(_err(_garbage('{"crit":{"alg":"EdDSA"},"alg":"none"}')), NONE)
    assert_equal(
        _err(_garbage('{"x":"\\"alg\\":\\"EdDSA\\"","alg":"HS256"}')), HMAC
    )


def test_key_members_refused() raises:
    # Catches: a key taken from the token. Whatever the value, even null, and
    # with a valid signature, each is refused.
    for name in ["jwk", "jku", "x5u", "x5c"]:
        var n = String(name)
        assert_equal(
            _err(_mint(String('{"alg":"EdDSA","kid":"k1","') + n + '":null}')),
            _key_member(n),
        )
        assert_equal(
            _err(_garbage(String('{"alg":"EdDSA","kid":"k1","') + n + '":"x"}')),
            _key_member(n),
        )
    # x5t names a certificate thumbprint, not a key: it selects nothing here
    # and is ignored like any other unknown member.
    _ = _verifier().verify(_mint('{"alg":"EdDSA","kid":"k1","x5t":"AA"}'))


def test_crit_refused() raises:
    # Catches: an unknown critical extension ignored (RFC 7515 4.1.11).
    assert_equal(
        _err(_mint('{"alg":"EdDSA","kid":"k1","crit":["exp"],"exp":1}')), CRIT
    )
    assert_equal(_err(_mint('{"alg":"EdDSA","kid":"k1","crit":[]}')), CRIT)
    assert_equal(_err(_mint('{"alg":"EdDSA","kid":"k1","crit":["b64"],"b64":false}')), CRIT)


def test_order() raises:
    # Catches: the gate's order changed (alg, key members, crit, kid).
    assert_equal(_err(_garbage('{"alg":"none","jwk":{}}')), NONE)
    assert_equal(_err(_garbage('{"alg":"EdDSA","crit":[],"jku":"x"}')), _key_member("jku"))
    assert_equal(_err(_garbage('{"alg":"EdDSA","kid":"","crit":[]}')), CRIT)
    assert_equal(_err(_garbage('{"alg":"EdDSA","crit":[]}')), CRIT)


def test_kid() raises:
    # Catches: a set-built verifier without kid, an empty or non-string kid,
    # and the printable-ASCII bounds (0x20 and 0x7E pass the gate and reach
    # key selection; 0x1F and 0x7F do not).
    assert_equal(_err(_mint('{"alg":"EdDSA"}')), KID_MISSING)
    assert_equal(_err(_mint('{"alg":"EdDSA","kid":""}')), KID_BAD)
    assert_equal(_err(_mint('{"alg":"EdDSA","kid":7}')), KID_BAD)
    assert_equal(_err(_mint('{"alg":"EdDSA","kid":null}')), KID_BAD)
    assert_equal(_err(_mint('{"alg":"EdDSA","kid":"k\\u001f"}')), KID_BAD)
    assert_equal(_err(_mint('{"alg":"EdDSA","kid":"k\\u007f"}')), KID_BAD)
    assert_equal(_err(_mint('{"alg":"EdDSA","kid":"k\\u00e9"}')), KID_BAD)
    assert_equal(_err(_mint('{"alg":"EdDSA","kid":" "}')), NO_KEY)
    assert_equal(_err(_mint('{"alg":"EdDSA","kid":"~"}')), NO_KEY)
    # " ~" (0x20 then 0x7E) is a key's kid, so it selects and verifies.
    _ = _verifier().verify(_mint('{"alg":"EdDSA","kid":" ~"}'))


def test_after_the_gate() raises:
    # Catches: a malformed signature or payload segment not refused, or a
    # wrong-length signature passed to the primitive.
    var h = _b64(GOOD)
    assert_equal(
        _err(h + ".e30.AA+A"),
        "JoseError: the signature segment is not base64url without padding",
    )
    comptime LEN = "JoseError: the signature has the wrong length"
    var b63 = List[UInt8]()
    for _ in range(63):
        b63.append(1)
    assert_equal(_err(h + ".e30." + base64_url_encode_nopad(Span(b63))), LEN)
    b63.append(1)
    b63.append(1)
    assert_equal(_err(h + ".e30." + base64_url_encode_nopad(Span(b63))), LEN)
    b63.pop()
    assert_equal(
        _err(h + ".e30." + base64_url_encode_nopad(Span(b63))),
        "JoseError: the signature does not verify",
    )
    # A validly signed token whose payload segment is not base64url: the
    # signature verifies over the segment's bytes, the decode refuses.
    assert_equal(
        _err(_mint_raw(h, "e30=")),
        "JoseError: the payload segment is not base64url without padding",
    )


def main() raises:
    var failures = String("")
    try:
        test_baseline_verifies()
    except e:
        failures += String("test_baseline_verifies: ") + String(e) + "\n"
    try:
        test_compact_form()
    except e:
        failures += String("test_compact_form: ") + String(e) + "\n"
    try:
        test_ascii_boundary()
    except e:
        failures += String("test_ascii_boundary: ") + String(e) + "\n"
    try:
        test_length_boundary()
    except e:
        failures += String("test_length_boundary: ") + String(e) + "\n"
    try:
        test_header_json()
    except e:
        failures += String("test_header_json: ") + String(e) + "\n"
    try:
        test_duplicate_members()
    except e:
        failures += String("test_duplicate_members: ") + String(e) + "\n"
    try:
        test_alg()
    except e:
        failures += String("test_alg: ") + String(e) + "\n"
    try:
        test_crit_cannot_hide_alg()
    except e:
        failures += String("test_crit_cannot_hide_alg: ") + String(e) + "\n"
    try:
        test_key_members_refused()
    except e:
        failures += String("test_key_members_refused: ") + String(e) + "\n"
    try:
        test_crit_refused()
    except e:
        failures += String("test_crit_refused: ") + String(e) + "\n"
    try:
        test_order()
    except e:
        failures += String("test_order: ") + String(e) + "\n"
    try:
        test_kid()
    except e:
        failures += String("test_kid: ") + String(e) + "\n"
    try:
        test_after_the_gate()
    except e:
        failures += String("test_after_the_gate: ") + String(e) + "\n"
    if failures != "":
        print(failures)
        raise Error("test_header_gate: FAILED\n" + failures)
    print("test_header_gate: OK")
