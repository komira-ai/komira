# =============================================================================
# test_user_token.mojo: `user_token_claims` (user_token.mojo) and
#   `derived_key` (keys.mojo).
# =============================================================================
#
# The claims: the exact bytes in member order, `scope` left out when empty,
# JSON escaping, and every refusal at its boundary (an empty value refused
# and a one-byte value accepted; time -1 and 0; lifetime 0, 1, 86400 and
# 86401; the largest `now` whose `exp` fits an Int64 and one more).
#
# The keys: key `index` of `seed` under `alg` is the signer of SHA-256 of
# the label the file header of keys.mojo gives, computed here independently;
# another index, seed or algorithm gives another `kid`; the refusals; and
# every near miss of "ES256" and "EdDSA" is refused (a loose compare would
# take one).
#
# main runs every test and reports every failure.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_crypto import sha256
from komira_jose import JwsSigner
from komira_secret_store import SecretValue
from komira_test_issuer import derived_key, user_token_claims


comptime ISS = "https://issuer.example/a"
comptime T0: Int64 = 1000000


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _str(b: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(b))


def _near_misses(s: String) -> List[String]:
    """Prefix, both extensions, suffix, case flipped, the first, middle and
    last byte replaced, and the empty string."""
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
    first[0] = UInt8(0x7A) if b[0] != UInt8(0x7A) else UInt8(0x79)
    out.append(_str(first))
    var middle = b.copy()
    var m = n // 2
    middle[m] = UInt8(0x7A) if b[m] != UInt8(0x7A) else UInt8(0x79)
    out.append(_str(middle))
    var last = b.copy()
    last[n - 1] = UInt8(0x7A) if b[n - 1] != UInt8(0x7A) else UInt8(0x79)
    out.append(_str(last))
    out.append(String(""))
    return out^


def _claims(
    issuer: String = ISS,
    subject: String = "subject-1",
    audience: String = "service-a",
    client_id: String = "client-a",
    scope: String = "read write",
    now: Int64 = T0,
    ttl_s: Int64 = 300,
    jti: String = "jti-1",
) raises -> String:
    return user_token_claims(
        issuer=issuer,
        subject=subject,
        audience=audience,
        client_id=client_id,
        scope=scope,
        now=now,
        ttl_s=ttl_s,
        jti=jti,
    )


def _claims_err(
    issuer: String = ISS,
    subject: String = "subject-1",
    audience: String = "service-a",
    client_id: String = "client-a",
    now: Int64 = T0,
    ttl_s: Int64 = 300,
    jti: String = "jti-1",
) -> String:
    try:
        _ = _claims(issuer, subject, audience, client_id, "s", now, ttl_s, jti)
    except e:
        return String(e)
    return String("")


def test_claims_bytes() raises:
    # Catches: a member left out, renamed, reordered or written from the
    # wrong input; exp not iat plus the lifetime; scope written when empty
    # or dropped when not; an unescaped string.
    assert_equal(
        _claims(),
        String('{"iss":"https://issuer.example/a","sub":"subject-1",')
        + '"aud":"service-a","iat":1000000,"exp":1000300,"jti":"jti-1",'
        + '"client_id":"client-a","scope":"read write"}',
    )
    assert_equal(
        _claims(scope=""),
        String('{"iss":"https://issuer.example/a","sub":"subject-1",')
        + '"aud":"service-a","iat":1000000,"exp":1000300,"jti":"jti-1",'
        + '"client_id":"client-a"}',
    )
    assert_equal(
        _claims(subject='a"b', scope="x", ttl_s=1, now=0),
        String('{"iss":"https://issuer.example/a","sub":"a\\"b",')
        + '"aud":"service-a","iat":0,"exp":1,"jti":"jti-1",'
        + '"client_id":"client-a","scope":"x"}',
    )


def test_claims_refusals() raises:
    # Catches: each emptiness check removed or loosened to refuse one byte;
    # each bound moved by one or removed; the overflow check removed (a
    # negative exp) or off by one.
    assert_equal(_claims_err(issuer=""), "TestIssuerError: the token issuer is empty")
    assert_equal(_claims_err(subject=""), "TestIssuerError: the token subject is empty")
    assert_equal(_claims_err(audience=""), "TestIssuerError: the token audience is empty")
    assert_equal(_claims_err(client_id=""), "TestIssuerError: the token client_id is empty")
    assert_equal(_claims_err(jti=""), "TestIssuerError: the token jti is empty")
    assert_equal(_claims_err(issuer="i", subject="s", audience="a", client_id="c", jti="j"), "")
    assert_equal(_claims_err(now=-1), "TestIssuerError: the token time is negative")
    assert_equal(_claims_err(now=0), "")
    comptime LIFE = "TestIssuerError: the token lifetime must be 1 to 86400 seconds"
    assert_equal(_claims_err(ttl_s=0), LIFE)
    assert_equal(_claims_err(ttl_s=1), "")
    assert_equal(_claims_err(ttl_s=86400), "")
    assert_equal(_claims_err(ttl_s=86401), LIFE)
    comptime FIT = "TestIssuerError: the token expiry does not fit a 64-bit integer"
    assert_equal(_claims_err(now=Int64.MAX - 300, ttl_s=300), "")
    assert_equal(_claims_err(now=Int64.MAX - 299, ttl_s=300), FIT)
    assert_equal(_claims_err(now=Int64.MAX, ttl_s=1), FIT)
    var top = _claims(now=Int64.MAX - 300, scope="s")
    assert_true(
        top.find(String(',"exp":') + String(Int64.MAX) + ",") >= 0,
        "the latest accepted time writes exp = Int64.MAX",
    )


def _expected_signer(alg: String, seed: String, index: Int) raises -> JwsSigner:
    var label = String("komira_test_issuer ") + alg + " " + String(index) + " " + seed
    var digest = sha256(label.as_bytes())
    var d = List[UInt8](length=32, fill=UInt8(0))
    for i in range(32):
        d[i] = digest[i]
    if alg == "ES256":
        return JwsSigner.es256(SecretValue(Span(d)))
    return JwsSigner.eddsa(SecretValue(Span(d)))


def _key_err(alg: String, seed: String, index: Int) -> String:
    try:
        _ = derived_key(alg, seed, index)
    except e:
        return String(e)
    return String("")


def test_derived_keys() raises:
    # Catches: a different label (word, order, separator), a digest byte not
    # copied, the algorithms swapped, the index or seed ignored.
    for a in range(2):
        var alg = String("ES256") if a == 0 else String("EdDSA")
        for index in range(3):
            var got = derived_key(alg, "seed-a", index)
            assert_equal(got.alg(), alg)
            assert_equal(got.kid(), _expected_signer(alg, "seed-a", index).kid())
            assert_equal(got.kid(), derived_key(alg, "seed-a", index).kid())
        assert_true(
            derived_key(alg, "seed-a", 0).kid() != derived_key(alg, "seed-a", 1).kid()
        )
        assert_true(
            derived_key(alg, "seed-a", 0).kid() != derived_key(alg, "seed-b", 0).kid()
        )
    # One byte of seed and index 0 are accepted.
    assert_equal(_key_err("ES256", "s", 0), "")
    # Every byte of the digest reaches the key: a key built from the digest
    # with any one byte changed has another kid.
    var label = String("komira_test_issuer EdDSA 0 seed-a")
    var digest = sha256(label.as_bytes())
    var want = derived_key("EdDSA", "seed-a", 0).kid()
    var misses = String("")
    for i in range(32):
        var d = List[UInt8](length=32, fill=UInt8(0))
        for j in range(32):
            d[j] = digest[j]
        d[i] ^= UInt8(1)
        if JwsSigner.eddsa(SecretValue(Span(d))).kid() == want:
            misses += String(i) + " "
    assert_equal(misses, "", "digest bytes that do not change the key")


def test_derived_key_refusals() raises:
    # Catches: the seed or index check removed or moved by one; an algorithm
    # compare loosened (prefix, suffix, case, one byte).
    assert_equal(_key_err("ES256", "", 0), "TestIssuerError: the key seed is empty")
    assert_equal(_key_err("ES256", "seed-a", -1), "TestIssuerError: the key index is negative")
    comptime ONLY = "TestIssuerError: the test issuer derives ES256 and EdDSA keys only"
    assert_equal(_key_err("RS256", "seed-a", 0), ONLY)
    var misses = String("")
    for a in range(2):
        var near = _near_misses(String("ES256") if a == 0 else String("EdDSA"))
        for i in range(len(near)):
            if _key_err(near[i], "seed-a", 0) != ONLY:
                misses += near[i] + " "
    assert_equal(misses, "", "near-miss algorithms accepted")


def main() raises:
    var failures = String("")
    try:
        test_claims_bytes()
    except e:
        failures += String("test_claims_bytes: ") + String(e) + "\n"
    try:
        test_claims_refusals()
    except e:
        failures += String("test_claims_refusals: ") + String(e) + "\n"
    try:
        test_derived_keys()
    except e:
        failures += String("test_derived_keys: ") + String(e) + "\n"
    try:
        test_derived_key_refusals()
    except e:
        failures += String("test_derived_key_refusals: ") + String(e) + "\n"
    if failures != "":
        print(failures)
        raise Error("test_user_token failed")
    print("PASS komira_test_issuer test_user_token")
