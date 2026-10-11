# =============================================================================
# test_assertion.mojo: RFC 7523 JWT bearer assertions (assertion.mojo):
#   minted with each algorithm and verified by the verify half; the exact
#   claims; the random `jti` that is never omitted, always required, and
#   chosen by no caller (no public function takes one); the 300-second
#   lifetime bound on what verifies; and the client rule `sub == iss`.
# =============================================================================
#
# Keys as in test_signer: RFC 7515 A.3 (ES256), RFC 8037 A.1 (EdDSA) and
# komira_http_core's RSA test key (RS256). The client id is `client-1`, the
# audience the token endpoint `https://issuer.example/token`, the time
# NOW = 1000000. Verifiers are built from the signer's published key,
# rendered and parsed back.
#
# main runs every test and reports every failure.
# =============================================================================

from std.pathlib import Path
from std.testing import assert_equal, assert_true

from komira_crypto import rsa_pkcs8_der_from_pem
from komira_encoding import base64_url_decode_nopad
from komira_jose import (
    JOSE_ASSERTION_MAX_TTL_S,
    JOSE_JTI_BYTES,
    ClaimPolicy,
    JwsSigner,
    JwsVerifier,
    mint_assertion,
    mint_client_assertion,
    new_jti,
    verify_assertion,
    verify_client_assertion,
)
from komira_jose.assertion import _assertion_claims
from komira_jwks import Jwk, parse_jwk_set, render_jwk_set
from komira_secret_store import SecretValue


comptime A3_D = "jpsQnnGQmL-YBIffH1136cspYG6-0iY7X1fCE9-E9LI"
comptime SEED = "nWGxne_9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A"
comptime RSA_PEM = "src/komira_http_core/tests/fixtures/tls/leaf_key.pem"
comptime CLIENT = "client-1"
comptime ENDPOINT = "https://issuer.example/token"
comptime NOW: Int64 = 1000000


def _signer(alg: String) raises -> JwsSigner:
    if alg == "ES256":
        var d = base64_url_decode_nopad(A3_D)
        return JwsSigner.es256(SecretValue(Span(d)))
    if alg == "EdDSA":
        var s = base64_url_decode_nopad(SEED)
        return JwsSigner.eddsa(SecretValue(Span(s)))
    var der = rsa_pkcs8_der_from_pem(Path(RSA_PEM).read_text())
    return JwsSigner.rs256(SecretValue(Span(der)))


def _algs() -> List[String]:
    var out = List[String]()
    out.append("ES256")
    out.append("EdDSA")
    out.append("RS256")
    return out^


def _verifier(s: JwsSigner) raises -> JwsVerifier:
    var keys = List[Jwk]()
    keys.append(s.public_jwk())
    return JwsVerifier(s.alg(), parse_jwk_set(render_jwk_set(keys)))


def _policy(issuer: String = CLIENT, now: Int64 = NOW) raises -> ClaimPolicy:
    return ClaimPolicy(
        issuer=issuer,
        audience=ENDPOINT,
        accept_typ="JWT",
        now=now,
        leeway_s=0,
        max_ttl_s=JOSE_ASSERTION_MAX_TTL_S,
    )


def _payload_of(token: String) raises -> String:
    var b = token.as_bytes()
    var d1 = -1
    var d2 = -1
    for i in range(len(b)):
        if b[i] == UInt8(0x2E):
            if d1 < 0:
                d1 = i
            else:
                d2 = i
    var p = base64_url_decode_nopad(String(token[byte = d1 + 1 : d2]))
    return String(unsafe_from_utf8=Span(p))


def _client_err(token: String, v: JwsVerifier, p: ClaimPolicy) -> String:
    try:
        _ = verify_client_assertion(token, v, p)
    except e:
        return String(e)
    return String("")


def _mint_err(
    issuer: String = CLIENT,
    subject: String = CLIENT,
    audience: String = ENDPOINT,
    now: Int64 = NOW,
    ttl: Int64 = 60,
) raises -> String:
    var s = _signer("EdDSA")
    try:
        _ = mint_assertion(
            s, issuer=issuer, subject=subject, audience=audience, now=now, ttl_s=ttl
        )
    except e:
        return String(e)
    return String("")


def _signed(s: JwsSigner, claims: String) raises -> String:
    return s.sign(claims.as_bytes(), String("JWT"))


def test_round_trip_each_algorithm() raises:
    # Catches: an assertion the verify half refuses, a jti dropped by the
    # mint, the claims written other than in the documented form.
    for alg in _algs():
        var s = _signer(alg)
        var v = _verifier(s)
        var t = mint_client_assertion(
            s, client_id=CLIENT, audience=ENDPOINT, now=NOW, ttl_s=JOSE_ASSERTION_MAX_TTL_S
        )
        var a = verify_client_assertion(t, v, _policy())
        assert_equal(a.jwt.issuer, CLIENT)
        assert_equal(a.jwt.subject, CLIENT)
        assert_equal(a.jwt.kid, s.kid())
        assert_equal(a.jwt.iat, NOW)
        assert_equal(a.jwt.exp, NOW + JOSE_ASSERTION_MAX_TTL_S)
        assert_equal(a.jti.byte_length(), 22)
        assert_equal(len(base64_url_decode_nopad(a.jti)), JOSE_JTI_BYTES)
        assert_equal(
            _payload_of(t),
            _assertion_claims(
                issuer=CLIENT,
                subject=CLIENT,
                audience=ENDPOINT,
                now=NOW,
                ttl_s=JOSE_ASSERTION_MAX_TTL_S,
                jti=a.jti,
            ),
        )
        # A general assertion (RFC 7523 section 2.1): sub need not be iss.
        var g = mint_assertion(
            s, issuer=CLIENT, subject="user-1", audience=ENDPOINT, now=NOW, ttl_s=60
        )
        var ga = verify_assertion(g, v, _policy())
        assert_equal(ga.jwt.subject, "user-1")


def test_claims_bytes() raises:
    # Catches: a claim added, dropped, reordered, or written unescaped.
    assert_equal(
        _assertion_claims(
            issuer="i", subject="s", audience="a", now=0, ttl_s=1, jti="j"
        ),
        '{"iss":"i","sub":"s","aud":"a","iat":0,"exp":1,"jti":"j"}',
    )
    assert_equal(
        _assertion_claims(
            issuer='a"b', subject="s\\", audience="a", now=7, ttl_s=300, jti="j"
        ),
        '{"iss":"a\\"b","sub":"s\\\\","aud":"a","iat":7,"exp":307,"jti":"j"}',
    )


def test_jti_is_random() raises:
    # Catches: a fixed or repeated jti, or one of another length.
    var s = _signer("EdDSA")
    var v = _verifier(s)
    var seen = List[String]()
    for _ in range(8):
        var t = mint_client_assertion(
            s, client_id=CLIENT, audience=ENDPOINT, now=NOW, ttl_s=60
        )
        var j = verify_client_assertion(t, v, _policy()).jti
        for k in seen:
            assert_true(k != j)
        seen.append(j)
    assert_true(new_jti() != new_jti())
    assert_equal(len(base64_url_decode_nopad(new_jti())), JOSE_JTI_BYTES)


def test_jti_bits() raises:
    # Catches: a jti with fewer than 128 random bits, e.g. one byte of the
    # 16 never filled (left 0) or filled with a constant. 32 minted jtis;
    # every byte position must take at least two values. A position of a
    # truly random jti stays constant over 32 draws with probability
    # 256^-31 (no false red in practice).
    var s = _signer("EdDSA")
    var v = _verifier(s)
    var draws = List[List[UInt8]]()
    for _ in range(32):
        var t = mint_client_assertion(
            s, client_id=CLIENT, audience=ENDPOINT, now=NOW, ttl_s=60
        )
        var j = verify_client_assertion(t, v, _policy()).jti
        var b = base64_url_decode_nopad(j)
        assert_equal(len(b), JOSE_JTI_BYTES)
        draws.append(b^)
    var fixed = String("")
    for i in range(JOSE_JTI_BYTES):
        var varies = False
        for k in range(1, len(draws)):
            if draws[k][i] != draws[0][i]:
                varies = True
        if not varies:
            fixed += String(i) + " "
    assert_equal(fixed, "", "jti byte positions that never varied")


def test_mint_bounds() raises:
    # Catches: an empty claim minted, a negative time, or the lifetime
    # bound moved by one.
    assert_equal(_mint_err(), "")
    assert_equal(_mint_err(issuer=""), "JoseError: the assertion issuer is empty")
    assert_equal(_mint_err(subject=""), "JoseError: the assertion subject is empty")
    assert_equal(_mint_err(audience=""), "JoseError: the assertion audience is empty")
    assert_equal(_mint_err(now=-1), "JoseError: the assertion time is negative")
    assert_equal(_mint_err(now=0), "")
    comptime TTL = "JoseError: the assertion lifetime must be 1 to 300 seconds"
    assert_equal(_mint_err(ttl=0), TTL)
    assert_equal(_mint_err(ttl=1), "")
    assert_equal(_mint_err(ttl=JOSE_ASSERTION_MAX_TTL_S), "")
    assert_equal(_mint_err(ttl=JOSE_ASSERTION_MAX_TTL_S + 1), TTL)
    # The bound is the literal 300 the refusal text and RFC 7523 profile
    # name, not whatever the constant holds.
    assert_equal(JOSE_ASSERTION_MAX_TTL_S, Int64(300))
    assert_equal(_mint_err(ttl=300), "")
    assert_equal(_mint_err(ttl=301), TTL)
    # A negative lifetime is refused as a lifetime before any arithmetic on
    # it: Int64.MAX - ttl would overflow for ttl < 0.
    assert_equal(_mint_err(ttl=-1), TTL)
    # exp = now + ttl must fit an Int64: at the largest time the sum would
    # wrap to a negative exp.
    comptime LATE = "JoseError: the assertion expiry is past the largest time"
    assert_equal(_mint_err(now=Int64.MAX - 300, ttl=300), "")
    assert_equal(_mint_err(now=Int64.MAX - 299, ttl=300), LATE)
    assert_equal(_mint_err(now=Int64.MAX, ttl=1), LATE)
    # The bound follows this call's ttl, not the largest allowed ttl.
    assert_equal(_mint_err(now=Int64.MAX - 1, ttl=1), "")
    assert_equal(_mint_err(now=Int64.MAX - 1, ttl=2), LATE)
    var got = String("")
    try:
        _ = _assertion_claims(
            issuer="i", subject="s", audience="a", now=0, ttl_s=1, jti=""
        )
    except e:
        got = String(e)
    assert_equal(got, "JoseError: the assertion jti is empty")
    # Single-byte values are not empty.
    assert_equal(_mint_err(issuer="i", subject="s", audience="a"), "")


def test_jti_required() raises:
    # Catches: an assertion without jti, with an empty or non-string jti,
    # or with jti only under a near name, accepted.
    comptime NO_JTI = "JoseError: claim jti is missing, empty or not a string"
    var s = _signer("ES256")
    var v = _verifier(s)
    var base = String('{"iss":"client-1","sub":"client-1","aud":"') + ENDPOINT + '","iat":1000000,"exp":1000060'
    assert_equal(_client_err(_signed(s, base + ',"jti":"j"}'), v, _policy()), "")
    var misses = String("")
    var tail = List[String]()
    tail.append("}")
    tail.append(',"jti":""}')
    tail.append(',"jti":1}')
    tail.append(',"jti":null}')
    tail.append(',"jti":["j"]}')
    for m in ["jt", "jtix", "xjti", "ti", "JTI", "zti", "jtz"]:
        tail.append(String(',"') + String(m) + '":"j"}')
    for t in tail:
        var got = _client_err(_signed(s, base + t), v, _policy())
        if got != NO_JTI:
            misses += t + " -> " + got + "; "
        try:
            _ = verify_assertion(_signed(s, base + t), v, _policy())
            misses += String("verify_assertion ") + t + " accepted; "
        except e:
            if String(e) != NO_JTI:
                misses += String("verify_assertion ") + t + " -> " + String(e) + "; "
    assert_equal(misses, "")


def test_client_sub_is_iss() raises:
    # Catches: a client assertion whose sub is not exactly its iss
    # accepted: the near-miss table of the client id as sub (a prefix, the
    # id extended at the end and at the front, a proper suffix, a case
    # variant, and the first, a middle or the last byte replaced).
    comptime NOT_CLIENT = "JoseError: claim sub is not the client (iss)"
    var s = _signer("EdDSA")
    var v = _verifier(s)
    var misses = String("")
    for sub in ["client-", "client-1x", "xclient-1", "lient-1", "CLIENT-1", "zlient-1", "cliezt-1", "client-z"]:
        var c = (
            String('{"iss":"client-1","sub":"')
            + String(sub)
            + '","aud":"'
            + ENDPOINT
            + '","iat":1000000,"exp":1000060,"jti":"j"}'
        )
        var got = _client_err(_signed(s, c), v, _policy())
        if got != NOT_CLIENT:
            misses += String(sub) + " -> " + got + "; "
    assert_equal(misses, "")


def test_policy_still_applies() raises:
    # Catches: an assertion path that skips the JWT checks (iss, aud, typ,
    # lifetime).
    var s = _signer("EdDSA")
    var v = _verifier(s)
    var t = mint_client_assertion(
        s, client_id=CLIENT, audience=ENDPOINT, now=NOW, ttl_s=60
    )
    assert_equal(
        _client_err(t, v, _policy(issuer="client-2")),
        "JoseError: claim iss is not the issuer",
    )
    assert_equal(
        _client_err(t, v, _policy(now=NOW + 60)), "JoseError: the token has expired"
    )
    var at = ClaimPolicy(
        issuer=CLIENT, audience=ENDPOINT, accept_typ="at+jwt", now=NOW, leeway_s=0, max_ttl_s=300
    )
    assert_equal(_client_err(t, v, at), "JoseError: header typ is not the pinned type")
    var other = ClaimPolicy(
        issuer=CLIENT, audience="https://issuer.example/", accept_typ="JWT", now=NOW, leeway_s=0, max_ttl_s=300
    )
    assert_equal(
        _client_err(t, v, other), "JoseError: claim aud does not name the audience"
    )


def _policy_ttl(max_ttl: Int64) raises -> ClaimPolicy:
    return ClaimPolicy(
        issuer=CLIENT,
        audience=ENDPOINT,
        accept_typ="JWT",
        now=NOW,
        leeway_s=0,
        max_ttl_s=max_ttl,
    )


def test_verify_bounds_the_lifetime() raises:
    # Catches: an assertion that lives longer than 300 s accepted because
    # the policy's max TTL allows it (a caller's replay cache would then
    # hold its jti for up to a day), and the bound moved by one. Policies
    # at 301 s, an hour and a day; exp - iat of 300 passes and 301 is
    # refused under each, by both verify functions.
    comptime LONG = "JoseError: the assertion lives longer than 300 seconds"
    var s = _signer("EdDSA")
    var v = _verifier(s)
    var head = String('{"iss":"client-1","sub":"client-1","aud":"') + ENDPOINT + '","iat":1000000,"exp":'
    var misses = String("")
    for max_ttl in [Int64(301), Int64(3600), Int64(86400)]:
        var p = _policy_ttl(max_ttl)
        for life in [Int64(1), Int64(299), Int64(300), Int64(301), Int64(3600)]:
            var t = _signed(s, head + String(NOW + life) + ',"jti":"j"}')
            var want = String("") if life <= 300 else String(LONG)
            if life > max_ttl:
                want = "JoseError: the token lives longer than the max TTL"
            var got = _client_err(t, v, p)
            if got != want:
                misses += String(max_ttl) + "/" + String(life) + " client -> " + got + "; "
            var got2 = String("")
            try:
                _ = verify_assertion(t, v, p)
            except e:
                got2 = String(e)
            if got2 != want:
                misses += String(max_ttl) + "/" + String(life) + " -> " + got2 + "; "
    assert_equal(misses, "")
    # The bound is the literal 300 the refusal text names.
    assert_equal(JOSE_ASSERTION_MAX_TTL_S, Int64(300))


def _top_level_public_defs(text: String) -> List[String]:
    """The names of the `def`s at column 0 of `text` whose name does not
    start with `_`."""
    var out = List[String]()
    for line in text.split("\n"):
        var l = String(line)
        if not l.startswith("def "):
            continue
        var b = l.as_bytes()
        var end = 4
        while end < len(b) and b[end] != UInt8(0x28) and b[end] != UInt8(0x5B):  # ( [
            end += 1
        var name = String(l[byte = 4 : end])
        if not name.startswith("_"):
            out.append(name)
    return out^


def _joined(names: List[String]) -> String:
    var out = String("")
    for i in range(len(names)):
        if i > 0:
            out += " "
        out += names[i]
    return out


def test_no_public_function_takes_a_jti() raises:
    # Catches: a public function that writes assertion claims with a jti
    # the caller chooses (assertion_claims was one): the file header and
    # README say a caller cannot choose or omit the jti. The public defs of
    # assertion.mojo are exactly the documented five, none takes a `jti`
    # parameter, and the package re-exports nothing with `claims` in its
    # name from assertion.mojo. Reads the library sources staged by the
    # BUCK file.
    var src = Path("src/komira_jose/assertion.mojo").read_text()
    assert_equal(
        _joined(_top_level_public_defs(src)),
        "new_jti mint_assertion mint_client_assertion verify_assertion"
        " verify_client_assertion",
    )
    var init = Path("src/komira_jose/__init__.mojo").read_text()
    var at = init.find("from komira_jose.assertion import (")
    assert_true(at >= 0)
    var rest = String(init[byte = at : init.byte_length()])
    var close = rest.find(")")
    var block = String(rest[byte = 0 : close])
    assert_equal(block.find("claims"), -1, "__init__ re-exports a claims writer")
    # No line of a public def (its parameters or body) declares a `jti`
    # parameter.
    var in_public = False
    var bad = String("")
    for line in src.split("\n"):
        var l = String(line)
        if l.startswith("def "):
            in_public = not l.startswith("def _")
        elif not l.startswith(" ") and l.byte_length() > 0:
            in_public = False
        if in_public and l.strip().startswith("jti:"):
            bad += l + "; "
    assert_equal(bad, "")


def main() raises:
    var failures = String("")
    try:
        test_round_trip_each_algorithm()
    except e:
        failures += String("test_round_trip_each_algorithm: ") + String(e) + "\n"
    try:
        test_claims_bytes()
    except e:
        failures += String("test_claims_bytes: ") + String(e) + "\n"
    try:
        test_jti_is_random()
    except e:
        failures += String("test_jti_is_random: ") + String(e) + "\n"
    try:
        test_jti_bits()
    except e:
        failures += String("test_jti_bits: ") + String(e) + "\n"
    try:
        test_mint_bounds()
    except e:
        failures += String("test_mint_bounds: ") + String(e) + "\n"
    try:
        test_verify_bounds_the_lifetime()
    except e:
        failures += String("test_verify_bounds_the_lifetime: ") + String(e) + "\n"
    try:
        test_no_public_function_takes_a_jti()
    except e:
        failures += String("test_no_public_function_takes_a_jti: ") + String(e) + "\n"
    try:
        test_jti_required()
    except e:
        failures += String("test_jti_required: ") + String(e) + "\n"
    try:
        test_client_sub_is_iss()
    except e:
        failures += String("test_client_sub_is_iss: ") + String(e) + "\n"
    try:
        test_policy_still_applies()
    except e:
        failures += String("test_policy_still_applies: ") + String(e) + "\n"
    if failures != "":
        print(failures)
        raise Error("test_assertion: FAILED\n" + failures)
    print("test_assertion: OK")
