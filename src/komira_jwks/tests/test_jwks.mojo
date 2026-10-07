# komira_jwks: the deterministic kid, the OKP/Ed25519 JWK Set renderer and the
# publish-only seed -> JWKS derivation.
#
# Vectors: the Ed25519 key of RFC 8037 Appendix A.1 (which is also RFC 8032
# section 7.1 TEST 1) and RFC 8032 section 7.1 TEST 2. The expected `x` members
# are the RFC 8037 A.2 text verbatim; the expected kids are
# base64url_nopad(sha256(raw 32-byte public key)) computed independently of this
# package. The kid is deliberately NOT the RFC 7638 thumbprint of A.3: it hashes
# the raw key, not a canonical JWK, and a test pinning it to A.3 would be wrong.

from komira_jwks import jwks_json_from_seed, kid_for_pubkey, render_jwks_json
from komira_secret_store import SecretValue

from std.testing import assert_equal, assert_false, assert_true


# RFC 8037 A.1 / RFC 8032 TEST 1.
comptime SEED_1 = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
comptime PUB_1 = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
comptime X_1 = "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"
comptime D_1 = "nWGxne_9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A"
comptime KID_1 = "If4x36FUomFia_hUBG_SJxt77UtqvkWqWId-9H-XIbk"

# RFC 8032 TEST 2.
comptime SEED_2 = "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb"
comptime PUB_2 = "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"
comptime X_2 = "PUAXw-hDiVqStwqnTRt-vJyYLM8uxJaMwM1V8Sr0Zgw"
comptime KID_2 = "OfcT0KZEJT8EUpQhufUbmwiXnQgpWVnE85kO5hf1E58"

# The all-zero 32-byte key: sha256 of 32 zero bytes, base64url without padding.
comptime KID_ZERO = "Zmh6rfhivXdsj8GLjp-OIAiXFIVu4jOzkCpZHQ1fKSU"


def _nibble(c: UInt8) raises -> UInt8:
    if c >= 48 and c <= 57:
        return c - 48
    if c >= 97 and c <= 102:
        return c - 87
    raise Error("bad hex digit")


def _hex(s: String) raises -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(0, len(b), 2):
        out.append((_nibble(b[i]) << 4) | _nibble(b[i + 1]))
    return out^


def _key(s: String) raises -> Array[UInt8, 32]:
    var raw = _hex(s)
    if len(raw) != 32:
        raise Error("not a 32-byte key")
    var out = Array[UInt8, 32](fill=UInt8(0))
    for i in range(32):
        out[i] = raw[i]
    return out^


def _jwk(kid: String, x: String) -> String:
    return (
        String('{"kty":"OKP","crv":"Ed25519","alg":"EdDSA","use":"sig","kid":"')
        + kid
        + String('","x":"')
        + x
        + String('"}')
    )


def _kid_of(hex_key: String) raises -> String:
    var raw = _hex(hex_key)
    return kid_for_pubkey(Span[UInt8, origin_of(raw)](raw))


def test_kid_vectors() raises:
    assert_equal(_kid_of(PUB_1), KID_1)
    assert_equal(_kid_of(PUB_2), KID_2)
    var zero = List[UInt8]()
    for _ in range(32):
        zero.append(0)
    assert_equal(kid_for_pubkey(Span[UInt8, origin_of(zero)](zero)), KID_ZERO)


def test_kid_is_full_unpadded_base64url() raises:
    # 32 digest bytes -> 43 characters: the FULL hash, no truncation, no '='.
    var kid = _kid_of(PUB_1)
    assert_equal(kid.byte_length(), 43)
    var b = kid.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        var ok = (
            (c >= 65 and c <= 90)
            or (c >= 97 and c <= 122)
            or (c >= 48 and c <= 57)
            or c == 45
            or c == 95
        )
        assert_true(ok, String("non-base64url byte at ") + String(i))


def test_kid_deterministic_and_bit_sensitive() raises:
    assert_equal(_kid_of(PUB_1), _kid_of(PUB_1))
    var base = _hex(PUB_1)
    var seen = List[String]()
    seen.append(kid_for_pubkey(Span[UInt8, origin_of(base)](base)))
    # Flipping any one bit of the key, first byte to last, yields a new kid.
    for byte in [0, 15, 31]:
        for bit in range(8):
            var k = _hex(PUB_1)
            k[byte] = k[byte] ^ (UInt8(1) << UInt8(bit))
            var kid = kid_for_pubkey(Span[UInt8, origin_of(k)](k))
            for j in range(len(seen)):
                assert_false(kid == seen[j], String("kid collision"))
            seen.append(kid)


def test_render_empty_set() raises:
    var keys = List[Tuple[String, Array[UInt8, 32]]]()
    assert_equal(render_jwks_json(keys), String('{"keys":[]}'))


def test_render_refuses_empty_kid() raises:
    # Defect: an empty kid rendered as `"kid":""` publishes a document this
    # package's own parser refuses, and builds a `Jwk` whose `kid()` is empty.
    var keys = List[Tuple[String, Array[UInt8, 32]]]()
    keys.append((String(""), Array[UInt8, 32](fill=7)))
    var got = String("")
    try:
        _ = render_jwks_json(keys)
    except e:
        got = String(e)
    assert_equal(got, "JwksError: member \"kid\" is empty")


def test_render_one_key_rfc8037_x() raises:
    var keys = List[Tuple[String, Array[UInt8, 32]]]()
    keys.append((String(KID_1), _key(PUB_1)))
    assert_equal(
        render_jwks_json(keys),
        String('{"keys":[') + _jwk(KID_1, X_1) + String("]}"),
    )


def test_render_two_keys_in_order() raises:
    # Rotation is a data change: both keys appear, in the given order, comma
    # separated, and swapping the input swaps the output.
    var keys = List[Tuple[String, Array[UInt8, 32]]]()
    keys.append((String(KID_1), _key(PUB_1)))
    keys.append((String(KID_2), _key(PUB_2)))
    assert_equal(
        render_jwks_json(keys),
        String('{"keys":[')
        + _jwk(KID_1, X_1)
        + String(",")
        + _jwk(KID_2, X_2)
        + String("]}"),
    )
    var swapped = List[Tuple[String, Array[UInt8, 32]]]()
    swapped.append((String(KID_2), _key(PUB_2)))
    swapped.append((String(KID_1), _key(PUB_1)))
    assert_equal(
        render_jwks_json(swapped),
        String('{"keys":[')
        + _jwk(KID_2, X_2)
        + String(",")
        + _jwk(KID_1, X_1)
        + String("]}"),
    )


def test_from_seed_rfc8037_vector() raises:
    var seed_bytes = _hex(SEED_1)
    var doc = jwks_json_from_seed(
        SecretValue(Span[UInt8, origin_of(seed_bytes)](seed_bytes))
    )
    assert_equal(doc, String('{"keys":[') + _jwk(KID_1, X_1) + String("]}"))


def test_from_seed_matches_public_derivation() raises:
    # Seed-derived equals the renderer over the public key alone.
    var seed_bytes = _hex(SEED_2)
    var doc = jwks_json_from_seed(
        SecretValue(Span[UInt8, origin_of(seed_bytes)](seed_bytes))
    )
    var keys = List[Tuple[String, Array[UInt8, 32]]]()
    keys.append((_kid_of(PUB_2), _key(PUB_2)))
    assert_equal(doc, render_jwks_json(keys))


def test_from_seed_never_publishes_the_seed() raises:
    var seed_bytes = _hex(SEED_1)
    var doc = jwks_json_from_seed(
        SecretValue(Span[UInt8, origin_of(seed_bytes)](seed_bytes))
    )
    assert_false(String('"d"') in doc, "a private d member was rendered")
    assert_false(String(D_1) in doc, "the seed's base64url was rendered")
    assert_false(String(SEED_1) in doc, "the seed's hex was rendered")


def test_from_seed_refuses_short_seeds() raises:
    for n in [0, 1, 16, 31]:
        var short = List[UInt8]()
        for i in range(n):
            short.append(UInt8(i + 1))
        var raised = False
        try:
            _ = jwks_json_from_seed(
                SecretValue(Span[UInt8, origin_of(short)](short))
            )
        except e:
            raised = True
            assert_true(
                String("got ") + String(n) + String(")") in String(e),
                String(e),
            )
        assert_true(raised, String("a ") + String(n) + " byte seed was accepted")


def main() raises:
    test_kid_vectors()
    test_kid_is_full_unpadded_base64url()
    test_kid_deterministic_and_bit_sensitive()
    test_render_empty_set()
    test_render_refuses_empty_kid()
    test_render_one_key_rfc8037_x()
    test_render_two_keys_in_order()
    test_from_seed_rfc8037_vector()
    test_from_seed_matches_public_derivation()
    test_from_seed_never_publishes_the_seed()
    test_from_seed_refuses_short_seeds()
    print("test_jwks: OK")
