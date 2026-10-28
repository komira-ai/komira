# =============================================================================
# test_signer.mojo: `JwsSigner` (signer.mojo) and `jwk_thumbprint`
#   (thumbprint.mojo): the RFC 7638 and RFC 8037 thumbprint vectors, each
#   key form's refusals, the exact header and token bytes, and every token
#   round-tripped through the verify half (`JwsVerifier`, `verify_jwt`)
#   with its exact pins: kid, iss, aud, typ and alg.
# =============================================================================
#
# Keys: ES256 is RFC 7515 appendix A.3's `d`; EdDSA is RFC 8037 appendix
# A.1's seed; RS256 is komira_http_core's 2048-bit test key (PKCS#8 PEM,
# staged by the BUCK file). Each round trip goes through the published
# document: the signer's public JWK is rendered with komira_jwks and parsed
# back before a verifier is built from it.
#
# A near-miss table of a value: a prefix, the value extended at the end and
# at the front, a proper suffix, a case variant, and the same length with
# the first, the middle or the last byte replaced. A prefix, suffix or
# case-folded compare in either direction, or a byte loop that skips one of
# those bytes, accepts at least one of them. Every value is tried and every
# miss is collected into one assert.
#
# main runs every test and reports every failure.
# =============================================================================

from std.pathlib import Path
from std.testing import assert_equal, assert_true

from komira_crypto import ed25519_sign, rsa_pkcs8_der_from_pem
from komira_encoding import base64_url_decode_nopad, base64_url_encode_nopad
from komira_jose import (
    ClaimPolicy,
    JwsSigner,
    JwsVerifier,
    jwk_thumbprint,
    thumbprint_input,
    verify_jwt,
)
from komira_jwks import Jwk, JwkSet, parse_jwk_set, render_jwk_set
from komira_jose.signer import _signature
from komira_jwks.jwk import _JwkParts
from komira_secret_store import SecretValue


comptime A3_D = "jpsQnnGQmL-YBIffH1136cspYG6-0iY7X1fCE9-E9LI"
comptime A3_X = "f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU"
comptime A3_Y = "x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0"
comptime SEED = "nWGxne_9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A"
comptime ED_X = "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"
# RFC 8037 appendix A.3: the thumbprint of the appendix A.1 key.
comptime ED_THUMBPRINT = "kPrK_qmxVWaYVA9wwBF6Iuo3vVzz7TxHCTwXBygrS4k"
# RFC 7638 section 3.1: the example RSA key and its thumbprint.
comptime RFC7638_N = (
    "0vx7agoebGcQSuuPiLJXZptN9nndrQmbXEps2aiAFbWhM78LhWx4cbbfAAtVT86zwu1RK7aPFFxuhDR1L6tSoc_BJECPebWKRXjBZCiFV4n3oknjhMstn64tZ_2W-5JsGY4Hc5n9yBXArwl93lqt7_RN5w6Cf0h4QyQ5v-65YGjQR0_FDW2QvzqY368QQMicAtaSqzs8KJZgnYb9c7d0zgdAZHzu6qMQvRL5hajrn1n91CbOpbISD08qNLyrdkt-bFTWhAI4vMQFh6WeZu0fM4lFd2NcRwr3XPksINHaQ-G_xBniIqbw0Ls1jF44-csFCur-kEgU8awapJzKnqDKgw"
)
comptime RFC7638_THUMBPRINT = "NzbLsXh8uDCcd-6MNwXF4W_7noWXFZAfHkxZsRGC9Xs"
comptime RSA_PEM = "src/komira_http_core/tests/fixtures/tls/leaf_key.pem"
comptime ISS = "https://issuer.example/a"
comptime AUD = "service-a"
comptime NOW: Int64 = 1000000


def _secret(b: List[UInt8]) raises -> SecretValue:
    return SecretValue(Span(b))


def _b64d(s: String) raises -> List[UInt8]:
    return base64_url_decode_nopad(s)


def _rsa_der() raises -> List[UInt8]:
    return rsa_pkcs8_der_from_pem(Path(RSA_PEM).read_text())


def _signer(alg: String) raises -> JwsSigner:
    if alg == "ES256":
        return JwsSigner.es256(_secret(_b64d(A3_D)))
    if alg == "EdDSA":
        return JwsSigner.eddsa(_secret(_b64d(SEED)))
    return JwsSigner.rs256(_secret(_rsa_der()))


def _algs() -> List[String]:
    var out = List[String]()
    out.append("ES256")
    out.append("EdDSA")
    out.append("RS256")
    return out^


def _err_build(alg: String, key: List[UInt8]) -> String:
    try:
        if alg == "ES256":
            _ = JwsSigner.es256(_secret(key))
        elif alg == "EdDSA":
            _ = JwsSigner.eddsa(_secret(key))
        else:
            _ = JwsSigner.rs256(_secret(key))
    except e:
        return String(e)
    return String("")


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _str(b: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(b))


def _near_misses(s: String) -> List[String]:
    """The near-miss table of `s` (see the file header)."""
    var b = _bytes_of(s)
    var n = len(b)
    var out = List[String]()
    var pre = List[UInt8]()
    for i in range(n - 1):
        pre.append(b[i])
    out.append(_str(pre))
    out.append(s + "x")
    out.append(String("x") + s)
    var suf = List[UInt8]()
    for i in range(1, n):
        suf.append(b[i])
    out.append(_str(suf))
    var flipped = List[UInt8]()
    for i in range(n):
        var c = b[i]
        if c >= UInt8(0x61) and c <= UInt8(0x7A):
            c -= 0x20
        elif c >= UInt8(0x41) and c <= UInt8(0x5A):
            c += 0x20
        flipped.append(c)
    out.append(_str(flipped))
    var first = b.copy()
    first[0] = UInt8(0x7A) if b[0] != UInt8(0x7A) else UInt8(0x79)  # z / y
    out.append(_str(first))
    var middle = b.copy()
    var m = n // 2
    middle[m] = UInt8(0x7A) if b[m] != UInt8(0x7A) else UInt8(0x79)
    out.append(_str(middle))
    var last = b.copy()
    last[n - 1] = UInt8(0x7A) if b[n - 1] != UInt8(0x7A) else UInt8(0x79)
    out.append(_str(last))
    return out^


def _published_set(key: Jwk) raises -> JwkSet:
    """`key` rendered as a one-key JWK Set and parsed back."""
    var keys = List[Jwk]()
    keys.append(key.copy())
    return parse_jwk_set(render_jwk_set(keys))


def _verifier(s: JwsSigner) raises -> JwsVerifier:
    return JwsVerifier(s.alg(), _published_set(s.public_jwk()))


def _policy(typ: String = "at+jwt") raises -> ClaimPolicy:
    return ClaimPolicy(
        issuer=ISS, audience=AUD, accept_typ=typ, now=NOW, leeway_s=0, max_ttl_s=300
    )


def _claims(iss: String = ISS, aud: String = AUD) -> String:
    return (
        String('{"iss":"')
        + iss
        + '","aud":"'
        + aud
        + '","sub":"user-1","exp":1000100,"iat":1000000}'
    )


def _verify_err(token: String, v: JwsVerifier, p: ClaimPolicy) -> String:
    try:
        _ = verify_jwt(token, v, p)
    except e:
        return String(e)
    return String("")


def test_thumbprint_vectors() raises:
    # Catches: a member left out, added (kid, alg, use), out of order, or a
    # value encoded other than base64url without padding.
    var x = _b64d(ED_X)
    assert_equal(jwk_thumbprint(Jwk.ed25519(Span(x))), ED_THUMBPRINT)
    # kid, alg and use are not part of the thumbprint.
    assert_equal(
        jwk_thumbprint(
            Jwk.ed25519(
                Span(x), kid=String("k"), alg=String("EdDSA"), key_use=String("sig")
            )
        ),
        ED_THUMBPRINT,
    )
    var n = _b64d(RFC7638_N)
    var e = _b64d("AQAB")
    assert_equal(jwk_thumbprint(Jwk.rsa(Span(n), Span(e))), RFC7638_THUMBPRINT)
    assert_equal(
        thumbprint_input(Jwk.rsa(Span(n), Span(e))),
        String('{"e":"AQAB","kty":"RSA","n":"') + RFC7638_N + '"}',
    )
    assert_equal(
        thumbprint_input(Jwk.ed25519(Span(x))),
        String('{"crv":"Ed25519","kty":"OKP","x":"') + ED_X + '"}',
    )
    var ex = _b64d(A3_X)
    var ey = _b64d(A3_Y)
    assert_equal(
        thumbprint_input(Jwk.ec_p256(Span(ex), Span(ey))),
        String('{"crv":"P-256","kty":"EC","x":"') + A3_X + '","y":"' + A3_Y + '"}',
    )
    # A key type the package does not sign with has no thumbprint here.
    var odd = Jwk(
        _parts=_JwkParts(
            kty=String("oct"),
            crv=String(""),
            x=List[UInt8](),
            y=List[UInt8](),
            n=List[UInt8](),
            e=List[UInt8](),
            kid=None,
            alg=None,
            key_use=None,
            key_ops=None,
        )
    )
    var got = String("")
    try:
        _ = jwk_thumbprint(odd)
    except err:
        got = String(err)
    assert_equal(got, "JoseError: the key type has no thumbprint here")


def test_es256_key_checks() raises:
    # Catches: a short or long scalar accepted, or a scalar of 0 or at or
    # above the group order n accepted (AWS-LC derives no public key).
    comptime LEN = "JoseError: an ES256 private key is 32 bytes"
    comptime RANGE = "JoseError: the ES256 private key is not a scalar from 1 to n - 1"
    var d = _b64d(A3_D)
    var short = List[UInt8]()
    for i in range(31):
        short.append(d[i])
    var long = d.copy()
    long.append(UInt8(1))
    assert_equal(_err_build("ES256", short), LEN)
    assert_equal(_err_build("ES256", long), LEN)
    assert_equal(_err_build("ES256", d), "")
    var order = _b64d("_____wAAAAD__________7zm-q2nF56E87nKwvxjJVE")
    var zero = List[UInt8](length=32, fill=UInt8(0))
    var ones = List[UInt8](length=32, fill=UInt8(0xFF))
    # Refused: 0, n, n + 1, 2^256 - 1, n with its first, a middle or its
    # last byte raised, and 0 with a one in its first byte past n.
    var misses = String("")
    var refused = List[List[UInt8]]()
    refused.append(zero.copy())
    refused.append(order.copy())
    var n1 = order.copy()
    n1[31] = n1[31] + 1
    refused.append(n1^)
    refused.append(ones.copy())
    var mid = order.copy()
    mid[4] = UInt8(1)  # FFFFFFFF01...
    refused.append(mid^)
    var mid2 = order.copy()
    mid2[16] = UInt8(0xBD)
    refused.append(mid2^)
    for i in range(len(refused)):
        var got = _err_build("ES256", refused[i])
        if got != RANGE:
            misses += String("refused[") + String(i) + "] -> " + got + "; "
    # Accepted: 1, n - 1, a value below n only in its first, a middle or its
    # last byte, and 2^255 (a one in the first byte, below n).
    var accepted = List[List[UInt8]]()
    var one = zero.copy()
    one[31] = UInt8(1)
    accepted.append(one^)
    var below = order.copy()
    below[31] = below[31] - 1
    accepted.append(below^)
    var first = ones.copy()
    first[0] = UInt8(0xFE)
    accepted.append(first^)
    var middle = order.copy()
    middle[10] = UInt8(0xFE)
    for j in range(11, 32):
        middle[j] = UInt8(0xFF)
    accepted.append(middle^)
    var low16 = order.copy()
    low16[16] = UInt8(0xBB)
    for j in range(17, 32):
        low16[j] = UInt8(0xFF)
    accepted.append(low16^)
    var top = zero.copy()
    top[0] = UInt8(0x80)
    accepted.append(top^)
    var last_one = zero.copy()
    last_one[0] = UInt8(1)
    accepted.append(last_one^)
    # Every byte position decides: for each i, a scalar whose only nonzero
    # byte is byte i is accepted; n with byte i lowered (later bytes 0xFF)
    # is accepted, and n with byte i raised (later bytes 0x00) refused. A
    # loop that skips any one byte misjudges one of these.
    for i in range(32):
        var only = zero.copy()
        only[i] = UInt8(1)
        accepted.append(only^)
        if order[i] > UInt8(0):
            var lo = order.copy()
            lo[i] = order[i] - 1
            for j in range(i + 1, 32):
                lo[j] = UInt8(0xFF)
            accepted.append(lo^)
        if order[i] < UInt8(0xFF):
            var hi = order.copy()
            hi[i] = order[i] + 1
            for j in range(i + 1, 32):
                hi[j] = UInt8(0)
            var got = _err_build("ES256", hi)
            if got != RANGE:
                misses += String("raised byte ") + String(i) + " -> " + got + "; "
    for i in range(len(accepted)):
        var got = _err_build("ES256", accepted[i])
        if got != "":
            misses += String("accepted[") + String(i) + "] -> " + got + "; "
    assert_equal(misses, "")
    # The public half is RFC 7515 A.3's x and y.
    var pub = _signer("ES256").public_jwk()
    var px = pub.x()
    var py = pub.y()
    assert_equal(base64_url_encode_nopad(Span(px)), A3_X)
    assert_equal(base64_url_encode_nopad(Span(py)), A3_Y)


def test_eddsa_key_checks() raises:
    # Catches: a seed of another length accepted, or the public half not
    # derived from the seed.
    comptime LEN = "JoseError: an Ed25519 seed is 32 bytes"
    var d = _b64d(SEED)
    var short = List[UInt8]()
    for i in range(31):
        short.append(d[i])
    var long = d.copy()
    long.append(UInt8(1))
    assert_equal(_err_build("EdDSA", short), LEN)
    assert_equal(_err_build("EdDSA", long), LEN)
    var s = _signer("EdDSA")
    var px = s.public_jwk().x()
    assert_equal(base64_url_encode_nopad(Span(px)), ED_X)
    assert_equal(s.kid(), ED_THUMBPRINT)


def _tlv(tag: UInt8, content: List[UInt8]) -> List[UInt8]:
    """One DER TLV, short or two-byte long form length."""
    var out = List[UInt8]()
    out.append(tag)
    var n = len(content)
    if n < 128:
        out.append(UInt8(n))
    elif n < 256:
        out.append(UInt8(0x81))
        out.append(UInt8(n))
    else:
        out.append(UInt8(0x82))
        out.append(UInt8(n >> 8))
        out.append(UInt8(n & 0xFF))
    out.extend(Span(content))
    return out^


def _cat(a: List[UInt8], b: List[UInt8]) -> List[UInt8]:
    var out = a.copy()
    out.extend(Span(b))
    return out^


def _nibble(c: UInt8) -> UInt8:
    if c >= UInt8(0x61):
        return c - 0x61 + 10
    return c - 0x30


def _hex(s: String) -> List[UInt8]:
    """Lower-case hex text to bytes."""
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(0, len(b), 2):
        out.append((_nibble(b[i]) << 4) | _nibble(b[i + 1]))
    return out^


def _with(pub: Jwk, alg: String, kid: String, key_alg: String) raises -> Jwk:
    """`pub`'s key material with another `kid` and `alg`."""
    if alg == "ES256":
        var x = pub.x()
        var y = pub.y()
        return Jwk.ec_p256(Span(x), Span(y), kid=kid, alg=key_alg)
    if alg == "EdDSA":
        var x = pub.x()
        return Jwk.ed25519(Span(x), kid=kid, alg=key_alg)
    var n = pub.n()
    var e = pub.e()
    return Jwk.rsa(Span(n), Span(e), kid=kid, alg=key_alg)


def _pkcs8(oid: List[UInt8], n: List[UInt8]) -> List[UInt8]:
    """A PKCS#8 envelope around an RSAPrivateKey-shaped SEQUENCE holding
    version 0, `n` and e = 65537 and nothing else: the shape the walk reads,
    and not a key AWS-LC accepts."""
    var alg = _tlv(0x30, _cat(_tlv(0x06, oid), _tlv(0x05, List[UInt8]())))
    var zero = List[UInt8]()
    zero.append(UInt8(0))
    var e = List[UInt8]()
    e.append(UInt8(1))
    e.append(UInt8(0))
    e.append(UInt8(1))
    var rsa = _tlv(0x30, _cat(_cat(_tlv(0x02, zero), _tlv(0x02, n)), _tlv(0x02, e)))
    return _tlv(0x30, _cat(_cat(_tlv(0x02, zero), alg), _tlv(0x04, rsa)))


def test_rs256_key_checks() raises:
    # Catches: a key of another algorithm signed with, the OID compared on
    # part of its bytes, a modulus outside 2048 to 4096 bits accepted, or a
    # key AWS-LC refuses accepted until the first token.
    comptime NOT_RSA = "JoseError: the key is not a PKCS#8 RSA private key"
    comptime RANGE = "JoseError: the RSA key's modulus or exponent is outside the supported range"
    comptime AWSLC = "JoseError: AWS-LC does not sign with the RSA key"
    var der = _rsa_der()
    assert_equal(_err_build("RS256", der), "")
    # An Ed25519 PKCS#8 key (RFC 8410 section 7 shape) that AWS-LC would
    # sign with: refused for its algorithm.
    var ed = _cat(_hex("302e020100300506032b657004220420"), _b64d(SEED))
    assert_equal(_err_build("RS256", ed), NOT_RSA)
    # The rsaEncryption OID one byte longer or shorter.
    var rsa_oid = _hex("2a864886f70d010101")
    var n256 = List[UInt8](length=256, fill=UInt8(0))
    n256[0] = UInt8(0x01)
    var misses = String("")
    for o in ["2a864886f70d01010101", "2a864886f70d0101"]:
        var got = _err_build("RS256", _pkcs8(_hex(String(o)), n256))
        if got != NOT_RSA:
            misses += String(o) + " -> " + got + "; "
    # Each of the nine OID bytes with one bit flipped in turn: a compare
    # that skips any one byte accepts one of them. (The real key with its
    # last OID byte made RSASSA-PSS's follows.)
    for i in range(9):
        var o = rsa_oid.copy()
        o[i] = o[i] ^ UInt8(0x08)
        var got = _err_build("RS256", _pkcs8(o, n256))
        if got != NOT_RSA:
            misses += String("OID byte ") + String(i) + " -> " + got + "; "
    assert_equal(misses, "")
    # The real key with its OID's last byte replaced.
    var pss = der.copy()
    var at = -1
    for i in range(len(der) - 9):
        var hit = True
        for j in range(9):
            if der[i + j] != rsa_oid[j]:
                hit = False
        if hit and at < 0:
            at = i
    assert_true(at > 0)
    pss[at + 8] = UInt8(0x0A)
    assert_equal(_err_build("RS256", pss), NOT_RSA)
    # Truncated: the walk leaves the buffer.
    var cut = List[UInt8]()
    for i in range(40):
        cut.append(der[i])
    assert_equal(_err_build("RS256", cut), NOT_RSA)
    assert_equal(_err_build("RS256", List[UInt8]()), NOT_RSA)
    # The walk passes and komira_jwks's range refuses: a 2040-bit modulus.
    var n255 = List[UInt8](length=255, fill=UInt8(0xC5))
    assert_equal(_err_build("RS256", _pkcs8(rsa_oid, n255)), RANGE)
    # The walk and the range pass; AWS-LC refuses the key.
    var n_ok = List[UInt8](length=256, fill=UInt8(0xC5))
    var padded = List[UInt8]()
    padded.append(UInt8(0))
    padded.extend(Span(n_ok))
    assert_equal(_err_build("RS256", _pkcs8(rsa_oid, padded)), AWSLC)
    var s = _signer("RS256")
    assert_equal(s.kid(), jwk_thumbprint(s.public_jwk()))
    assert_equal(len(s.public_jwk().n()), 256)


def test_rs256_modulus_counted_in_bits() raises:
    # Catches: the RSA minimum counted in bytes (komira_jwks's 256-byte
    # floor), which takes a 2041- to 2047-bit modulus. A 256-byte modulus
    # whose first byte is 0x01, 0x02, 0x04, ..., 0x40 or 0x7F (2041 to 2047
    # bits) is refused for its length before AWS-LC sees it; 0x80 and 0xFF
    # (2048 bits) pass the length check and reach the AWS-LC probe, which
    # refuses these made-up keys. The real 2048-bit key signs (above).
    comptime SHORT = "JoseError: the RSA modulus is shorter than 2048 bits"
    comptime AWSLC = "JoseError: AWS-LC does not sign with the RSA key"
    var rsa_oid = _hex("2a864886f70d010101")
    var misses = String("")
    for top in [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x7F, 0x80, 0xFF]:
        var n = List[UInt8](length=256, fill=UInt8(0xC5))
        n[0] = UInt8(top)
        var enc = List[UInt8]()
        if top >= 0x80:
            enc.append(UInt8(0))  # the DER sign pad of a positive INTEGER
        enc.extend(Span(n))
        var want = String(SHORT) if top < 0x80 else String(AWSLC)
        var got = _err_build("RS256", _pkcs8(rsa_oid, enc))
        if got != want:
            misses += String(top) + " -> " + got + "; "
    assert_equal(misses, "")


def _jws_signer_constructors(text: String) -> List[String]:
    """The signatures (from `def` to the first line ending in `:`, lines
    stripped and joined by a space) of every `__init__` in `text`'s
    `struct JwsSigner`, and of every method there whose return type (the
    text after `->`) names `JwsSigner` or `Self`, plus `@fieldwise_init`
    wherever `text` has that decorator (it would add a constructor taking
    the fields as given)."""
    var out = List[String]()
    if text.find("@fieldwise_init") >= 0:
        out.append("@fieldwise_init")
    var inside = False
    var sig = String("")
    var in_sig = False
    for line in text.split("\n"):
        var l = String(line)
        if l.startswith("struct JwsSigner"):
            inside = True
            continue
        if not inside:
            continue
        if l.byte_length() > 0 and not l.startswith(" ") and not l.startswith("#"):
            break
        var s = String(l.strip())
        if not in_sig and s.startswith("def "):
            sig = ""
            in_sig = True
        if in_sig:
            sig += (" " if sig != "" else "") + s
            if s.endswith(":"):
                in_sig = False
                var arrow = sig.find("->")
                var ret = String(sig[byte = arrow : sig.byte_length()]) if arrow >= 0 else String("")
                if (
                    sig.startswith("def __init__")
                    or ret.find("JwsSigner") >= 0
                    or ret.find("Self") >= 0
                ):
                    out.append(sig)
    return out^


def _public_writes_outside_init(text: String) -> List[String]:
    """Every line of `text` (stripped) that assigns to a `._public` field
    (`._public` then optional spaces then `=` not followed by `=`), except
    inside the body of `struct JwsSigner`'s `__init__`. The enclosing
    function is the last `def` line above, at any indentation."""
    var out = List[String]()
    var inside = False
    var in_init = False
    for line in text.split("\n"):
        var l = String(line)
        if l.startswith("struct JwsSigner"):
            inside = True
            in_init = False
            continue
        if l.byte_length() > 0 and not l.startswith(" ") and not l.startswith("#"):
            inside = False
            in_init = False
        var s = String(l.strip())
        if s.startswith("def "):
            in_init = inside and s.startswith("def __init__")
        var at = s.find("._public")
        while at >= 0:
            var b = s.as_bytes()
            var i = at + 8
            while i < len(b) and b[i] == UInt8(0x20):
                i += 1
            var assigns = i < len(b) and b[i] == UInt8(0x3D) and (
                i + 1 >= len(b) or b[i + 1] != UInt8(0x3D)
            )
            if assigns and not in_init:
                out.append(s)
                break
            at = s.find("._public", at + 8)
    return out^


def test_every_constructor_derives_the_kid() raises:
    # Catches: a constructor that takes the algorithm without checking it,
    # or one whose kid is not its own key's thumbprint (the raw
    # constructor took a public key as given, so a Keyring could stage a
    # signer naming another key's kid). `JwsSigner(alg=, private_key=)`
    # gives each algorithm the same signer as its named constructor, and
    # refuses every other algorithm name. The staged signer.mojo has exactly
    # these four constructors: one `__init__`, no `@fieldwise_init`, and no
    # other JwsSigner method whose return type names `JwsSigner` or `Self`;
    # and no line in signer.mojo assigns to `._public` outside that
    # `__init__`. It does not see a JwsSigner built through an `out`
    # parameter, a `_public` changed without a `._public =` assignment
    # (swap, a `ref` binding), or code in another file.
    var ctors = _jws_signer_constructors(
        Path("src/komira_jose/signer.mojo").read_text()
    )
    var joined = String("")
    for c in ctors:
        joined += c + "\n"
    assert_equal(
        joined,
        "def __init__(out self, *, alg: String, var private_key: SecretValue) raises:\n"
        + "def es256(var private_key: SecretValue) raises -> JwsSigner:\n"
        + "def eddsa(var seed: SecretValue) raises -> JwsSigner:\n"
        + "def rs256(var pkcs8_der: SecretValue) raises -> JwsSigner:\n",
    )
    var writes = String("")
    for w in _public_writes_outside_init(
        Path("src/komira_jose/signer.mojo").read_text()
    ):
        writes += w + "\n"
    assert_equal(writes, "")
    var ed = JwsSigner(alg="EdDSA", private_key=_secret(_b64d(SEED)))
    assert_equal(ed.kid(), ED_THUMBPRINT)
    assert_equal(ed.alg(), "EdDSA")
    var es = JwsSigner(alg="ES256", private_key=_secret(_b64d(A3_D)))
    assert_equal(es.kid(), _signer("ES256").kid())
    var px = es.public_jwk().x()
    assert_equal(base64_url_encode_nopad(Span(px)), A3_X)
    var rs = JwsSigner(alg="RS256", private_key=_secret(_rsa_der()))
    assert_equal(rs.kid(), _signer("RS256").kid())
    assert_equal(rs.kid(), jwk_thumbprint(rs.public_jwk()))
    # The key checks run under the general constructor too.
    var bad = String("")
    try:
        _ = JwsSigner(alg="ES256", private_key=_secret(List[UInt8](length=32, fill=UInt8(0))))
    except e:
        bad = String(e)
    assert_equal(bad, "JoseError: the ES256 private key is not a scalar from 1 to n - 1")
    comptime ALG = "JoseError: a signer's algorithm must be ES256, EdDSA or RS256"
    var misses = String("")
    var names = _near_misses("ES256")
    names.extend(_near_misses("EdDSA"))
    names.extend(_near_misses("RS256"))
    names.append("HS256")
    names.append("none")
    for a in names:
        # Each key form under each wrong name: none is taken as another
        # algorithm's key.
        for k in ["ES256", "EdDSA", "RS256"]:
            var key: List[UInt8]
            if String(k) == "ES256":
                key = _b64d(A3_D)
            elif String(k) == "EdDSA":
                key = _b64d(SEED)
            else:
                key = _rsa_der()
            var got = String("")
            try:
                _ = JwsSigner(alg=a.copy(), private_key=_secret(key))
            except e:
                got = String(e)
            if got != ALG:
                misses += a + "/" + String(k) + " -> " + got + "; "
    assert_equal(misses, "")


def test_crypto_failures_are_jose_errors() raises:
    # Catches: a komira_crypto failure raised through `sign` with its own
    # text instead of a JoseError. A signer's key always signs (its
    # constructor checked it), so the failure is driven through the private
    # `_signature` with keys komira_crypto refuses: a 31-byte Ed25519 seed
    # and RSA bytes that are not a PKCS#8 key.
    comptime FAIL = "JoseError: komira_crypto could not sign"
    var msg = _bytes_of("a.b")
    var misses = String("")
    var short = List[UInt8](length=31, fill=UInt8(7))
    try:
        _ = _signature("EdDSA", Span(short), Span(msg))
        misses += "EdDSA signed; "
    except e:
        if String(e) != FAIL:
            misses += String("EdDSA -> ") + String(e) + "; "
    var junk = List[UInt8](length=64, fill=UInt8(0x30))
    try:
        _ = _signature("RS256", Span(junk), Span(msg))
        misses += "RS256 signed; "
    except e:
        if String(e) != FAIL:
            misses += String("RS256 -> ") + String(e) + "; "
    assert_equal(misses, "")
    # The good keys sign through the same function.
    var seed = _b64d(SEED)
    assert_equal(len(_signature("EdDSA", Span(seed), Span(msg))), 64)


def test_public_jwk_and_header() raises:
    # Catches: a kid other than the thumbprint, alg or use missing from the
    # published key, a header member added, dropped or reordered, or a typ
    # written without escaping or accepted empty or unprintable.
    for alg in _algs():
        var s = _signer(alg)
        var pub = s.public_jwk()
        assert_equal(s.alg(), alg)
        assert_equal(pub.kid().value(), s.kid())
        assert_equal(pub.alg().value(), alg)
        assert_equal(pub.key_use().value(), "sig")
        assert_true(not pub.key_ops())
        # The kid is the thumbprint of the bare key material.
        var bare: Jwk
        var x = pub.x()
        var y = pub.y()
        var n = pub.n()
        var e = pub.e()
        if alg == "ES256":
            bare = Jwk.ec_p256(Span(x), Span(y))
        elif alg == "EdDSA":
            bare = Jwk.ed25519(Span(x))
        else:
            bare = Jwk.rsa(Span(n), Span(e))
        assert_equal(s.kid(), jwk_thumbprint(bare))
        var kid = s.kid()
        assert_equal(
            s.header_json(None),
            String('{"alg":"') + alg + '","kid":"' + kid + '"}',
        )
        assert_equal(
            s.header_json(String("at+jwt")),
            String('{"alg":"') + alg + '","kid":"' + kid + '","typ":"at+jwt"}',
        )
    var s = _signer("EdDSA")
    assert_equal(
        s.header_json(String('a"b\\c')),
        String('{"alg":"EdDSA","kid":"') + ED_THUMBPRINT + '","typ":"a\\"b\\\\c"}',
    )
    comptime TYP = "JoseError: typ must be a non-empty printable ASCII string"
    var misses = String("")
    var bad = List[String]()
    bad.append("")
    bad.append(_str(_hex("610962")))  # a TAB b
    bad.append(_str(_hex("617f62")))  # a DEL b
    bad.append(_str(_hex("1f")))
    bad.append(_str(_hex("7f")))
    bad.append(_str(_hex("6162c3a9")))  # a b e-acute (UTF-8)
    for t in bad:
        var got = String("")
        try:
            _ = s.sign(String("{}").as_bytes(), t.copy())
        except e:
            got = String(e)
        if got != TYP:
            misses += String("[") + t + "] -> " + got + "; "
    assert_equal(misses, "")
    assert_equal(s.header_json(String(" ")), String('{"alg":"EdDSA","kid":"') + ED_THUMBPRINT + '","typ":" "}')
    assert_equal(s.header_json(String("~")), String('{"alg":"EdDSA","kid":"') + ED_THUMBPRINT + '","typ":"~"}')


def test_token_bytes() raises:
    # Catches: a signing input other than b64url(header).b64url(payload),
    # a payload re-encoded, or a signature over other bytes.
    var s = _signer("EdDSA")
    var payload = String('{"a":1}')
    var t = s.sign(payload.as_bytes(), String("JWT"))
    var h = base64_url_encode_nopad(s.header_json(String("JWT")).as_bytes())
    var si = h + "." + base64_url_encode_nopad(payload.as_bytes())
    var seed = _b64d(SEED)
    var sig = ed25519_sign(Span(seed), si.as_bytes())
    var sb = List[UInt8]()
    for i in range(64):
        sb.append(sig[i])
    assert_equal(t, si + "." + base64_url_encode_nopad(Span(sb)))
    # Without typ, the header has no typ; an empty payload is an empty
    # segment.
    var t2 = s.sign(String("").as_bytes(), None)
    var h2 = base64_url_encode_nopad(s.header_json(None).as_bytes())
    assert_true(t2.startswith(h2 + ".."))
    # ES256 nonces are deterministic (RFC 6979): the same input signs the
    # same; RS256 is deterministic by construction.
    var e = _signer("ES256")
    assert_equal(e.sign(payload.as_bytes(), None), e.sign(payload.as_bytes(), None))


def test_round_trip_each_algorithm() raises:
    # Catches: a token a verifier pinned to the signer's algorithm, built
    # from the signer's published key, refuses; a header or claims the
    # verifier reads differently; one algorithm's token accepted by a
    # verifier pinned to another.
    for alg in _algs():
        var s = _signer(alg)
        var v = _verifier(s)
        var t = s.sign(_claims().as_bytes(), String("at+jwt"))
        var got = verify_jwt(t, v, _policy())
        assert_equal(got.kid, s.kid())
        assert_equal(got.issuer, ISS)
        assert_equal(got.subject, "user-1")
        var jws = v.verify(s.sign(String("raw bytes").as_bytes(), None))
        assert_equal(_str(jws.payload()), "raw bytes")
        assert_equal(jws.alg(), alg)
        for other in _algs():
            if other == alg:
                continue
            var ov = _verifier(_signer(other))
            assert_equal(
                _verify_err(t, ov, _policy()),
                "JoseError: alg is not the pinned algorithm",
            )


def test_pins_kid() raises:
    # Catches: a verifier that finds the signer's key under a near-miss of
    # its kid (the thumbprint), for each algorithm.
    var misses = String("")
    for alg in _algs():
        var s = _signer(alg)
        var t = s.sign(_claims().as_bytes(), String("at+jwt"))
        var pub = s.public_jwk()
        for k in _near_misses(s.kid()):
            var other = _with(pub, alg, k.copy(), alg)
            var v = JwsVerifier(alg, _published_set(other))
            var got = _verify_err(t, v, _policy())
            if got != "JoseError: kid names no key in the set":
                misses += alg + " " + k + " -> " + got + "; "
    assert_equal(misses, "")


def test_pins_alg_of_the_published_key() raises:
    # Catches: a published key whose alg member is a near miss of the
    # signer's algorithm still used to verify its tokens.
    var misses = String("")
    for alg in _algs():
        var s = _signer(alg)
        var pub = s.public_jwk()
        for a in _near_misses(alg):
            var other = _with(pub, alg, s.kid(), a.copy())
            var got = String("")
            try:
                _ = JwsVerifier(alg, _published_set(other))
            except e:
                got = String(e)
            if got != String("JoseError: the key set holds no key for ") + alg:
                misses += alg + " " + a + " -> " + got + "; "
    assert_equal(misses, "")


def test_pins_iss_aud_typ() raises:
    # Catches: a signed token whose iss, aud or header typ is a near miss
    # of the policy's accepted, for each algorithm.
    var misses = String("")
    for alg in _algs():
        var s = _signer(alg)
        var v = _verifier(s)
        for i in _near_misses(ISS):
            var c = _claims(iss=i.copy())
            var got = _verify_err(s.sign(c.as_bytes(), String("at+jwt")), v, _policy())
            if got != "JoseError: claim iss is not the issuer":
                misses += alg + " iss " + i + " -> " + got + "; "
        for a in _near_misses(AUD):
            var c = _claims(aud=a.copy())
            var got = _verify_err(s.sign(c.as_bytes(), String("at+jwt")), v, _policy())
            if got != "JoseError: claim aud does not name the audience":
                misses += alg + " aud " + a + " -> " + got + "; "
        for t in _near_misses("at+jwt"):
            var c = _claims()
            var got = _verify_err(s.sign(c.as_bytes(), t.copy()), v, _policy())
            if got != "JoseError: header typ is not the pinned type":
                misses += alg + " typ " + t + " -> " + got + "; "
        for t in _near_misses("JWT"):
            var c = _claims()
            var got = _verify_err(s.sign(c.as_bytes(), t.copy()), v, _policy("JWT"))
            if got != "JoseError: header typ is not the pinned type":
                misses += alg + " typ " + t + " -> " + got + "; "
    assert_equal(misses, "")


def main() raises:
    var failures = String("")
    try:
        test_thumbprint_vectors()
    except e:
        failures += String("test_thumbprint_vectors: ") + String(e) + "\n"
    try:
        test_es256_key_checks()
    except e:
        failures += String("test_es256_key_checks: ") + String(e) + "\n"
    try:
        test_eddsa_key_checks()
    except e:
        failures += String("test_eddsa_key_checks: ") + String(e) + "\n"
    try:
        test_rs256_key_checks()
    except e:
        failures += String("test_rs256_key_checks: ") + String(e) + "\n"
    try:
        test_rs256_modulus_counted_in_bits()
    except e:
        failures += String("test_rs256_modulus_counted_in_bits: ") + String(e) + "\n"
    try:
        test_every_constructor_derives_the_kid()
    except e:
        failures += String("test_every_constructor_derives_the_kid: ") + String(e) + "\n"
    try:
        test_crypto_failures_are_jose_errors()
    except e:
        failures += String("test_crypto_failures_are_jose_errors: ") + String(e) + "\n"
    try:
        test_public_jwk_and_header()
    except e:
        failures += String("test_public_jwk_and_header: ") + String(e) + "\n"
    try:
        test_token_bytes()
    except e:
        failures += String("test_token_bytes: ") + String(e) + "\n"
    try:
        test_round_trip_each_algorithm()
    except e:
        failures += String("test_round_trip_each_algorithm: ") + String(e) + "\n"
    try:
        test_pins_kid()
    except e:
        failures += String("test_pins_kid: ") + String(e) + "\n"
    try:
        test_pins_alg_of_the_published_key()
    except e:
        failures += String("test_pins_alg_of_the_published_key: ") + String(e) + "\n"
    try:
        test_pins_iss_aud_typ()
    except e:
        failures += String("test_pins_iss_aud_typ: ") + String(e) + "\n"
    if failures != "":
        print(failures)
        raise Error("test_signer: FAILED\n" + failures)
    print("test_signer: OK")
