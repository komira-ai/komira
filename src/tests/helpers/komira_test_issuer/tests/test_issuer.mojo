# =============================================================================
# test_issuer.mojo: `TestIssuer` (issuer.mojo) against komira_jose's verify
#   half, the way a relying party uses it.
# =============================================================================
#
# An issuer has max lifetime 300 s, leeway 30 s and publish lead 600 s, and
# starts at T0 = 1000000. Every token is checked by `_check`: the document
# the issuer served is parsed with komira_jwks, a `JwsVerifier` pinned to the
# issuer's algorithm is built from it, and `verify_jwt` applies a
# `ClaimPolicy` of the issuer, audience "service-a", the issuer's `typ`, the
# leeway and the max lifetime at the time given. This file does not use the
# package's own `verify_as_relying_party`, so a defect there cannot hide one
# here.
#
# The rotation tests name the plan's defect: a rotation that drops the former
# key before the max lifetime plus the leeway have passed makes a token
# signed before the switch fail while it is still in flight.
#
# main runs every test and reports every failure.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_encoding import base64_url_decode_nopad
from komira_jose import ClaimPolicy, JwsVerifier, VerifiedJwt, verify_jwt
from komira_json import JSON_STRING, JsonValue
from komira_jwks import parse_jwk_set
from komira_test_issuer import TestIssuer, derived_key, user_token_claims


comptime T0: Int64 = 1000000
comptime TTL: Int64 = 300
comptime LEEWAY: Int64 = 30
comptime LEAD: Int64 = 600
comptime ISS = "https://issuer.example/a"
comptime AUD = "service-a"
comptime CLIENT = "client-a"
comptime SEED = "seed-a"


def _issuer(
    alg: String = "ES256", typ: String = "at+jwt", lead: Int64 = LEAD
) raises -> TestIssuer:
    return TestIssuer(
        issuer=ISS,
        alg=alg,
        typ=typ,
        max_ttl_s=TTL,
        leeway_s=LEEWAY,
        publish_lead_s=lead,
        seed=SEED,
        now=T0,
    )


def _issuer_err(
    issuer: String = ISS,
    alg: String = "ES256",
    typ: String = "at+jwt",
    ttl: Int64 = TTL,
    lead: Int64 = LEAD,
    seed: String = SEED,
    now: Int64 = T0,
) -> String:
    try:
        _ = TestIssuer(
            issuer=issuer,
            alg=alg,
            typ=typ,
            max_ttl_s=ttl,
            leeway_s=LEEWAY,
            publish_lead_s=lead,
            seed=seed,
            now=now,
        )
    except e:
        return String(e)
    return String("")


def _check(
    doc: String, token: String, alg: String, typ: String, now: Int64
) raises -> VerifiedJwt:
    var verifier = JwsVerifier(alg, parse_jwk_set(doc))
    var policy = ClaimPolicy(
        issuer=ISS,
        audience=AUD,
        accept_typ=typ,
        now=now,
        leeway_s=LEEWAY,
        max_ttl_s=TTL,
    )
    return verify_jwt(token, verifier, policy)


def _check_err(
    doc: String, token: String, alg: String, typ: String, now: Int64
) -> String:
    try:
        _ = _check(doc, token, alg, typ, now)
    except e:
        return String(e)
    return String("")


def _kids(doc: String) raises -> String:
    var set = parse_jwk_set(doc)
    var out = String("")
    for i in range(len(set.keys)):
        if i > 0:
            out += " "
        out += set.keys[i].kid().value()
    return out


def _kid(index: Int, alg: String = "ES256") raises -> String:
    return derived_key(alg, SEED, index).kid()


def _string_member(obj: JsonValue, name: String) -> String:
    for i in range(len(obj.obj_keys)):
        if obj.obj_keys[i] == name and obj.children[i].kind == JSON_STRING:
            return obj.children[i].text.copy()
    return String("<absent>")


def _mint(mut iss: TestIssuer) raises -> String:
    return iss.mint_user_token("user-1", AUD, CLIENT, "read write")


def _to(mut iss: TestIssuer, at: Int64) raises:
    iss.advance(at - iss.now())


def test_minted_token_verifies() raises:
    # The plan's test: a token the issuer mints verifies under komira_jose's
    # verifier with the document it serves, for each algorithm and type.
    # Catches: a token signed by a key the document lacks; the wrong typ,
    # iss, sub, aud or lifetime; claims written from the wrong input.
    for a in range(2):
        var alg = String("ES256") if a == 0 else String("EdDSA")
        for t in range(2):
            var typ = String("at+jwt") if t == 0 else String("JWT")
            var iss = _issuer(alg, typ)
            assert_equal(iss.issuer(), ISS)
            assert_equal(iss.alg(), alg)
            assert_equal(iss.typ(), typ)
            assert_equal(iss.max_ttl_s(), TTL)
            assert_equal(iss.leeway_s(), LEEWAY)
            assert_equal(iss.publish_lead_s(), LEAD)
            assert_equal(iss.now(), T0)
            var doc = iss.jwks()
            assert_equal(_kids(doc), _kid(0, alg))
            assert_equal(iss.signing_kid(), _kid(0, alg))
            var token = _mint(iss)
            var jwt = _check(doc, token, alg, typ, T0)
            assert_equal(jwt.subject, "user-1")
            assert_equal(jwt.kid, _kid(0, alg))
            assert_equal(jwt.iat, T0)
            assert_equal(jwt.exp, T0 + TTL)
            # The other type is refused: the header carries this issuer's.
            var other = String("JWT") if t == 0 else String("at+jwt")
            assert_equal(
                _check_err(doc, token, alg, other, T0),
                "JoseError: header typ is not the pinned type",
            )
            # The signed payload is exactly user_token_claims of the inputs.
            var parts = token.split(".")
            var payload = base64_url_decode_nopad(String(parts[1]))
            assert_equal(
                String(unsafe_from_utf8=Span(payload)),
                user_token_claims(
                    issuer=ISS,
                    subject="user-1",
                    audience=AUD,
                    client_id=CLIENT,
                    scope="read write",
                    now=T0,
                    ttl_s=TTL,
                    jti=_string_member(jwt.claims, "jti"),
                ),
            )


def test_mint_lifetime() raises:
    # Catches: mint ignoring ttl_s, or minting past the max lifetime.
    var iss = _issuer()
    var doc = iss.jwks()
    var short = iss.mint(subject="u", audience=AUD, client_id=CLIENT, scope="", ttl_s=1)
    assert_equal(_check(doc, short, "ES256", "at+jwt", T0).exp, T0 + 1)
    var err = String("")
    try:
        _ = iss.mint(subject="u", audience=AUD, client_id=CLIENT, scope="", ttl_s=TTL + 1)
    except e:
        err = String(e)
    assert_equal(err, "JoseError: the token would outlive the keyring's max token TTL")
    var empty = String("")
    try:
        _ = iss.mint_user_token("", AUD, CLIENT, "s")
    except e:
        empty = String(e)
    assert_equal(empty, "TestIssuerError: the token subject is empty")


def test_jti_carries_128_random_bits() raises:
    # Catches: a jti shorter than 16 bytes, a constant jti, or one whose
    # byte at any position never changes (fewer than 128 random bits).
    var iss = _issuer()
    var doc = iss.jwks()
    var jtis = List[List[UInt8]]()
    var texts = List[String]()
    for _ in range(32):
        var jwt = _check(doc, _mint(iss), "ES256", "at+jwt", T0)
        var text = _string_member(jwt.claims, "jti")
        var raw = base64_url_decode_nopad(text)
        assert_equal(len(raw), 16)
        for k in range(len(texts)):
            assert_true(texts[k] != text, "two tokens carry one jti")
        texts.append(text)
        jtis.append(raw^)
    var fixed = String("")
    for pos in range(16):
        var varies = False
        for k in range(1, len(jtis)):
            if jtis[k][pos] != jtis[0][pos]:
                varies = True
        if not varies:
            fixed += String(pos) + " "
    assert_equal(fixed, "", "jti byte positions that never change")


def test_in_flight_token_survives_rotation() raises:
    # The plan's mutant: a rotation that drops the former key before the max
    # lifetime plus the leeway have passed. A token signed at the switch must
    # verify under the document served at every moment until its exp plus
    # the leeway minus 1 s; the former key leaves the document at exactly
    # the switch plus the max lifetime plus the leeway.
    var iss = _issuer()
    iss.begin_rotation()
    _ = iss.jwks()
    iss.advance(LEAD)
    var switch = T0 + LEAD
    var token = _mint(iss)
    iss.finish_rotation()
    assert_equal(iss.signing_kid(), _kid(1))
    var after = _mint(iss)
    var points = List[Int64]()
    points.append(switch)
    points.append(switch + 1)
    points.append(switch + TTL)
    points.append(switch + TTL + LEEWAY - 1)
    var misses = String("")
    for i in range(len(points)):
        _to(iss, points[i])
        var doc = iss.jwks()
        var why = _check_err(doc, token, "ES256", "at+jwt", points[i])
        if why != "":
            misses += String(points[i] - switch) + ": " + why + "\n"
        if _check_err(doc, after, "ES256", "at+jwt", points[i]) != "":
            misses += String(points[i] - switch) + ": the new key's token\n"
    assert_equal(misses, "", "seconds after the switch at which a token failed")
    _to(iss, switch + TTL + LEEWAY - 1)
    assert_equal(_kids(iss.jwks()), _kid(1) + " " + _kid(0))
    assert_equal(len(iss.retiring_kids()), 1)
    _to(iss, switch + TTL + LEEWAY)
    assert_equal(_kids(iss.jwks()), _kid(1))
    assert_equal(len(iss.retiring_kids()), 0)


def test_publish_before_sign() raises:
    # Catches: a staged key that signs before it was served for the lead; a
    # switch that does not take effect; a rotation that skips the publication
    # check; a token after the switch that a relying party holding the
    # document from the rotation's start cannot verify;
    # a refused `begin_rotation` that still uses up a key index.
    var iss = _issuer()
    iss.begin_rotation()
    assert_equal(iss.staged_kid().value(), _kid(1))
    var unserved = String("")
    try:
        iss.finish_rotation()
    except e:
        unserved = String(e)
    assert_equal(unserved, "JoseError: the staged key has not been in a rendered key set")
    var during = iss.jwks()
    assert_equal(_kids(during), _kid(0) + " " + _kid(1))
    iss.advance(LEAD - 1)
    var early = String("")
    try:
        iss.finish_rotation()
    except e:
        early = String(e)
    assert_equal(
        early, "JoseError: the staged key has not been published for the publish lead"
    )
    assert_equal(_check(during, _mint(iss), "ES256", "at+jwt", T0 + LEAD - 1).kid, _kid(0))
    iss.advance(1)
    iss.finish_rotation()
    assert_true(not iss.staged_kid())
    var jwt = _check(during, _mint(iss), "ES256", "at+jwt", T0 + LEAD)
    assert_equal(jwt.kid, _kid(1))
    # A second rotation stages key 2.
    iss.begin_rotation()
    assert_equal(iss.staged_kid().value(), _kid(2))
    var twice = String("")
    try:
        iss.begin_rotation()
    except e:
        twice = String(e)
    assert_equal(twice, "JoseError: a staged key is waiting: promote or retire it first")
    # The refused call used up no key: key 2 is still the one that switches,
    # and the next rotation stages key 3 (the order is key 0, 1, 2, ...).
    _ = iss.jwks()
    iss.advance(LEAD)
    iss.finish_rotation()
    assert_equal(iss.signing_kid(), _kid(2))
    iss.begin_rotation()
    assert_equal(iss.staged_kid().value(), _kid(3))


def test_finish_without_rotation() raises:
    var iss = _issuer()
    var err = String("")
    try:
        iss.finish_rotation()
    except e:
        err = String(e)
    assert_equal(err, "TestIssuerError: no rotation is in progress")
    assert_equal(iss.signing_kid(), _kid(0))


def test_two_retirements_in_one_step() raises:
    # Catches: a retirement loop that skips the entry after one it removed,
    # or removes a key before its time.
    var iss = _issuer(lead=0)
    for _ in range(2):
        iss.begin_rotation()
        _ = iss.jwks()
        iss.finish_rotation()
        iss.advance(1)
    assert_equal(_kids(iss.jwks()), _kid(2) + " " + _kid(0) + " " + _kid(1))
    # Key 0 leaves at T0 + 330, key 1 at T0 + 331; one step past both.
    iss.advance(TTL + LEEWAY + 10)
    assert_equal(_kids(iss.jwks()), _kid(2))


def test_sign_claims() raises:
    # Any claims and typ, signed by the signing key; the lifetime bound
    # still holds.
    var iss = _issuer()
    var doc = iss.jwks()
    var claims = (
        String('{"iss":"') + ISS + '","sub":"","aud":"' + AUD + '","iat":'
        + String(T0) + ',"exp":' + String(T0 + 10) + "}"
    )
    var token = iss.sign_claims(claims, Optional[String]())
    var plain = JwsVerifier("ES256", parse_jwk_set(doc)).verify(token)
    assert_true(not plain.typ())
    assert_equal(plain.kid().value(), _kid(0))
    var payload = plain.payload()
    assert_equal(String(unsafe_from_utf8=Span(payload)), claims)
    var typed = iss.sign_claims(claims, Optional[String]("JWT"))
    assert_equal(JwsVerifier("ES256", parse_jwk_set(doc)).verify(typed).typ().value(), "JWT")
    var long = (
        String('{"exp":') + String(T0 + TTL + 1) + "}"
    )
    var err = String("")
    try:
        _ = iss.sign_claims(long, Optional[String]())
    except e:
        err = String(e)
    assert_equal(err, "JoseError: the token would outlive the keyring's max token TTL")


def test_clock() raises:
    var iss = _issuer()
    var err = String("")
    try:
        iss.advance(-1)
    except e:
        err = String(e)
    assert_equal(err, "TestIssuerError: the clock only moves forward")
    iss.advance(0)
    assert_equal(iss.now(), T0)
    iss.advance(7)
    assert_equal(iss.now(), T0 + 7)


def _near_misses(s: String) -> List[String]:
    """Prefix, both extensions, suffix, case flipped, the first, middle and
    last byte replaced, and the empty string."""
    var b = List[UInt8]()
    b.extend(Span(s.as_bytes()))
    var n = len(b)
    var out = List[String]()
    out.append(String(s[byte = 0 : n - 1]))
    out.append(s + "x")
    out.append(String("x") + s)
    out.append(String(s[byte = 1 : n]))
    out.append(s.upper() if s.upper() != s else s.lower())
    for k in range(3):
        var at = 0 if k == 0 else (n // 2 if k == 1 else n - 1)
        var c = b.copy()
        c[at] = UInt8(0x7A) if b[at] != UInt8(0x7A) else UInt8(0x79)
        out.append(String(unsafe_from_utf8=Span(c)))
    out.append(String(""))
    return out^


def test_constructor_refusals() raises:
    # Catches: each check removed or loosened, the lead bound off by one,
    # an algorithm or typ compare that accepts a near miss.
    assert_equal(_issuer_err(issuer=""), "TestIssuerError: the issuer is empty")
    assert_equal(_issuer_err(seed=""), "TestIssuerError: the key seed is empty")
    assert_equal(_issuer_err(issuer="i", seed="s"), "")
    comptime EARLY = "TestIssuerError: the start time is earlier than the publish lead"
    assert_equal(_issuer_err(now=LEAD - 1), EARLY)
    assert_equal(_issuer_err(now=LEAD), "")
    assert_equal(_issuer_err(lead=0, now=0), "")
    assert_equal(
        _issuer_err(ttl=0), "JoseError: the keyring max token TTL must be 1 to 86400 seconds"
    )
    assert_equal(_issuer_err(alg="RS256"), "TestIssuerError: the test issuer signs ES256 or EdDSA")
    comptime ALG = "TestIssuerError: the test issuer signs ES256 or EdDSA"
    comptime TYP = "TestIssuerError: the token typ must be at+jwt or JWT"
    var misses = String("")
    for a in range(2):
        var near = _near_misses(String("ES256") if a == 0 else String("EdDSA"))
        for i in range(len(near)):
            if _issuer_err(alg=near[i]) != ALG:
                misses += String("alg ") + near[i] + "\n"
    for t in range(2):
        var near = _near_misses(String("at+jwt") if t == 0 else String("JWT"))
        for i in range(len(near)):
            if _issuer_err(typ=near[i]) != TYP:
                misses += String("typ ") + near[i] + "\n"
    assert_equal(misses, "", "near misses the constructor accepted")


def main() raises:
    var failures = String("")
    try:
        test_minted_token_verifies()
    except e:
        failures += String("test_minted_token_verifies: ") + String(e) + "\n"
    try:
        test_mint_lifetime()
    except e:
        failures += String("test_mint_lifetime: ") + String(e) + "\n"
    try:
        test_jti_carries_128_random_bits()
    except e:
        failures += String("test_jti_carries_128_random_bits: ") + String(e) + "\n"
    try:
        test_in_flight_token_survives_rotation()
    except e:
        failures += String("test_in_flight_token_survives_rotation: ") + String(e) + "\n"
    try:
        test_publish_before_sign()
    except e:
        failures += String("test_publish_before_sign: ") + String(e) + "\n"
    try:
        test_finish_without_rotation()
    except e:
        failures += String("test_finish_without_rotation: ") + String(e) + "\n"
    try:
        test_two_retirements_in_one_step()
    except e:
        failures += String("test_two_retirements_in_one_step: ") + String(e) + "\n"
    try:
        test_sign_claims()
    except e:
        failures += String("test_sign_claims: ") + String(e) + "\n"
    try:
        test_clock()
    except e:
        failures += String("test_clock: ") + String(e) + "\n"
    try:
        test_constructor_refusals()
    except e:
        failures += String("test_constructor_refusals: ") + String(e) + "\n"
    if failures != "":
        print(failures)
        raise Error("test_issuer failed")
    print("PASS komira_test_issuer test_issuer")
