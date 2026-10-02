# =============================================================================
# test_encoding_byte_identity.mojo -- the encodings komira_crypto's callers
# rely on, pinned byte for byte.
# =============================================================================
#
# komira_crypto's base64 and base32 come from komira_encoding. What callers
# of this library depend on is the exact text: a PEM body, the members of a
# JWK, a JWS segment, an otpauth:// secret. This test pins that text:
#
#   1. Literal vectors from the standards that define those formats: an RFC
#      8410 Ed25519 public key as the base64 body of a PEM block, the RFC 8037
#      Ed25519 JWK `x` member, the RSA exponent `e` = "AQAB" of RFC 7517
#      Appendix A, and the RFC 7515 Appendix A.1 JWS header segment.
#   2. A corpus digest per encoder: every length 0..257 of a fixed byte
#      pattern, each output followed by a newline, hashed with SHA-256. The
#      expected digests are those of the RFC 4648 encodings (base64, base64url
#      padded, base64url without padding, base32 without padding) of the same
#      corpus, so one changed byte anywhere in the roughly 45 KB of output
#      per encoder turns the test red.
#   3. Decoding inverts each of those encodings over the same corpus.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_crypto import sha256, hex_lower_array_32
from komira_encoding import (
    base64_encode,
    base64_decode,
    base64_url_encode,
    base64_url_encode_nopad,
    base64_url_decode,
    base32_encode_nopad,
    base32_decode,
)


comptime _ENC_BASE64 = 0
comptime _ENC_BASE64URL = 1
comptime _ENC_BASE64URL_NOPAD = 2
comptime _ENC_BASE32_NOPAD = 3

comptime _CORPUS_MAX_LEN = 257


def _corpus_item(n: Int) -> List[UInt8]:
    """The corpus entry of length `n`: byte i is (7i + 13n + 5) mod 256."""
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(UInt8((i * 7 + n * 13 + 5) & 0xFF))
    return out^


def _encode(which: Int, data: Span[UInt8, _]) -> String:
    if which == _ENC_BASE64:
        return base64_encode(data)
    if which == _ENC_BASE64URL:
        return base64_url_encode(data)
    if which == _ENC_BASE64URL_NOPAD:
        return base64_url_encode_nopad(data)
    return base32_encode_nopad(data)


def _decode(which: Int, s: String) raises -> List[UInt8]:
    if which == _ENC_BASE64:
        return base64_decode(s)
    if which == _ENC_BASE32_NOPAD:
        return base32_decode(s)
    return base64_url_decode(s)


def _same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _from_hex(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(0, len(b), 2):
        var hi = Int(b[i])
        var lo = Int(b[i + 1])
        hi = hi - 48 if hi <= 57 else hi - 87
        lo = lo - 48 if lo <= 57 else lo - 87
        out.append(UInt8(hi * 16 + lo))
    return out^


def _corpus_digest(which: Int) -> String:
    var all = List[UInt8]()
    for n in range(_CORPUS_MAX_LEN + 1):
        var item = _corpus_item(n)
        var enc = _encode(which, Span[UInt8](item))
        var eb = enc.as_bytes()
        for i in range(len(eb)):
            all.append(eb[i])
        all.append(UInt8(10))
    return hex_lower_array_32(sha256(Span[UInt8](all)))


# --- 1. literal vectors -------------------------------------------------------


def test_pem_body_ed25519_spki() raises:
    """RFC 8410 section 10.1: the Ed25519 SubjectPublicKeyInfo whose PEM body
    is the base64 text below."""
    var der = _from_hex(
        "302a300506032b657003210019bf44096984cdfe8541bac167dc3b96c85086aa30b6b6cb0c5c38ad703166e1"
    )
    var body = String(
        "MCowBQYDK2VwAyEAGb9ECWmEzf6FQbrBZ9w7lshQhqowtrbLDFw4rXAxZuE="
    )
    assert_equal(base64_encode(Span[UInt8](der)), body)
    assert_true(_same(base64_decode(body), der))


def test_jwk_ed25519_x() raises:
    """RFC 8037 Appendix A.2: the Ed25519 public key as the JWK `x` member."""
    var pk = _from_hex(
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
    )
    var x = String("11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo")
    assert_equal(base64_url_encode_nopad(Span[UInt8](pk)), x)
    assert_true(_same(base64_url_decode(x), pk))


def test_jwk_rsa_e() raises:
    """RFC 7517 Appendix A.1: the RSA public exponent 65537 as `e`."""
    var e = List[UInt8]()
    e.append(1)
    e.append(0)
    e.append(1)
    assert_equal(base64_url_encode_nopad(Span[UInt8](e)), String("AQAB"))
    assert_true(_same(base64_url_decode(String("AQAB")), e))


def test_jws_header_segment() raises:
    """RFC 7515 Appendix A.1: the JWS Protected Header segment."""
    var hdr = String('{"typ":"JWT",\r\n "alg":"HS256"}')
    var seg = String("eyJ0eXAiOiJKV1QiLA0KICJhbGciOiJIUzI1NiJ9")
    assert_equal(base64_url_encode_nopad(hdr.as_bytes()), seg)
    var want = List[UInt8]()
    var hb = hdr.as_bytes()
    for i in range(len(hb)):
        want.append(hb[i])
    assert_true(_same(base64_url_decode(seg), want))


# --- 2. corpus digests --------------------------------------------------------


def test_corpus_digest_base64() raises:
    assert_equal(
        _corpus_digest(_ENC_BASE64),
        String(
            "7f3e9dc6deaa80ff0764016320dabd2e96f39ec4d1df4074f79d495c5401eecb"
        ),
    )


def test_corpus_digest_base64url() raises:
    assert_equal(
        _corpus_digest(_ENC_BASE64URL),
        String(
            "978a520ad9b8b3cd6bd85f8914fe8089f180a04d68e0d2cbccc0ee308a451a3e"
        ),
    )


def test_corpus_digest_base64url_nopad() raises:
    assert_equal(
        _corpus_digest(_ENC_BASE64URL_NOPAD),
        String(
            "f265851706b77283277b6b7c9864eb69b5ac8563008751d00a31dca5be79f61b"
        ),
    )


def test_corpus_digest_base32_nopad() raises:
    assert_equal(
        _corpus_digest(_ENC_BASE32_NOPAD),
        String(
            "982e39302f08ad58c9d95acdb464bcf0bedd73def96627a1552017984b55313d"
        ),
    )


# --- 3. decoding inverts each encoding ----------------------------------------


def test_corpus_round_trip() raises:
    for which in range(4):
        for n in range(_CORPUS_MAX_LEN + 1):
            var item = _corpus_item(n)
            var enc = _encode(which, Span[UInt8](item))
            assert_true(_same(_decode(which, enc), item))


def main() raises:
    test_pem_body_ed25519_spki()
    test_jwk_ed25519_x()
    test_jwk_rsa_e()
    test_jws_header_segment()
    test_corpus_digest_base64()
    test_corpus_digest_base64url()
    test_corpus_digest_base64url_nopad()
    test_corpus_digest_base32_nopad()
    test_corpus_round_trip()
