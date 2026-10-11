# =============================================================================
# test_keyring.mojo: `Keyring` (keyring.mojo): publish before sign, retire
#   after the max token TTL plus the leeway, the lifetime bound on what it
#   signs, time that only moves forward, and every refusal at its boundary.
# =============================================================================
#
# Keys are Ed25519 seeds of 32 equal bytes (seed 1, 2, ...) and, for the
# ES256 ring, the scalars 1, 2, ... A ring has max token TTL 300 s and
# publish lead 600 s, starting at T0 = 1000000; its retirement leeway is
# the largest a verifier may have, 60 s. Every token is checked the way a
# relying party would: the document the ring rendered is parsed with
# komira_jwks and a `JwsVerifier` pinned to the ring's algorithm is built
# from it, with a policy at that largest leeway.
#
# main runs every test and reports every failure.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_jose import (
    JOSE_KEYRING_MAX_RETIRING,
    JOSE_MAX_LEEWAY_S,
    JOSE_MAX_PUBLISH_LEAD_S,
    JOSE_MAX_TTL_S,
    ClaimPolicy,
    JwsSigner,
    JwsVerifier,
    Keyring,
    verify_jwt,
)
from komira_jwks import parse_jwk_set
from komira_secret_store import SecretValue


comptime T0: Int64 = 1000000
comptime TTL: Int64 = 300
comptime LEEWAY: Int64 = 60
comptime LEAD: Int64 = 600
comptime ISS = "https://issuer.example/a"
comptime AUD = "service-a"


def _key(i: Int, alg: String = "EdDSA") raises -> JwsSigner:
    if alg == "ES256":
        var d = List[UInt8](length=32, fill=UInt8(0))
        d[31] = UInt8(i)
        return JwsSigner.es256(SecretValue(Span(d)))
    var seed = List[UInt8](length=32, fill=UInt8(i))
    return JwsSigner.eddsa(SecretValue(Span(seed)))


def _kid(i: Int, alg: String = "EdDSA") raises -> String:
    return _key(i, alg).kid()


def _ring(alg: String = "EdDSA", now: Int64 = T0) raises -> Keyring:
    return Keyring(alg=alg, max_token_ttl_s=TTL, publish_lead_s=LEAD, now=now)


def _ring_err(
    alg: String = "EdDSA",
    ttl: Int64 = TTL,
    lead: Int64 = LEAD,
    now: Int64 = T0,
) -> String:
    try:
        _ = Keyring(alg=alg, max_token_ttl_s=ttl, publish_lead_s=lead, now=now)
    except e:
        return String(e)
    return String("")


def _payload(now: Int64, life: Int64 = TTL) -> String:
    return (
        String('{"iss":"')
        + ISS
        + '","aud":"'
        + AUD
        + '","sub":"user-1","iat":'
        + String(now)
        + ',"exp":'
        + String(now + life)
        + "}"
    )


def _sign(mut ring: Keyring, now: Int64) raises -> String:
    return ring.sign(_payload(now), String("at+jwt"), now)


def _sign_err(mut ring: Keyring, payload: String, now: Int64) -> String:
    try:
        _ = ring.sign(payload, String("at+jwt"), now)
    except e:
        return String(e)
    return String("")


def _promote_err(mut ring: Keyring, kid: String, now: Int64) -> String:
    try:
        ring.promote(kid, now)
    except e:
        return String(e)
    return String("")


def _retire_err(mut ring: Keyring, kid: String, now: Int64) -> String:
    try:
        ring.retire(kid, now)
    except e:
        return String(e)
    return String("")


def _rotate_err(mut ring: Keyring, var key: JwsSigner, now: Int64) -> String:
    try:
        ring.rotate(key^, now)
    except e:
        return String(e)
    return String("")


def _check(doc: String, token: String, alg: String, now: Int64) -> String:
    """How a relying party holding `doc` answers `token` at `now`: "" when
    it accepts it, else the refusal."""
    try:
        var v = JwsVerifier(alg, parse_jwk_set(doc))
        var p = ClaimPolicy(
            issuer=ISS,
            audience=AUD,
            accept_typ="at+jwt",
            now=now,
            leeway_s=LEEWAY,
            max_ttl_s=TTL,
        )
        _ = verify_jwt(token, v, p)
    except e:
        return String(e)
    return String("")


def _kids(doc: String) raises -> String:
    """The kids of a rendered document, in order, joined by spaces."""
    var set = parse_jwk_set(doc)
    var out = String("")
    for i in range(len(set.keys)):
        if i > 0:
            out += " "
        out += set.keys[i].kid().value()
    return out


def _near(s: String) -> List[String]:
    """The near-miss table of `s`: a prefix, `s` extended at the end and at
    the front, a proper suffix, a case variant, the same length with the
    first, a middle or the last byte replaced, and "". A prefix, suffix or
    case-folded compare either way, or a byte loop that skips one byte,
    accepts at least one of them."""
    var n = s.byte_length()
    var mid = n // 2
    var out = List[String]()
    out.append(String(s[byte = 0 : n - 1]))
    out.append(s + "x")
    out.append(String("x") + s)
    out.append(String(s[byte = 1 : n]))
    out.append(s.upper() if s.upper() != s else s.lower())
    out.append(String("z") + String(s[byte = 1 : n]))
    out.append(String(s[byte = 0 : mid]) + "z" + String(s[byte = mid + 1 : n]))
    out.append(String(s[byte = 0 : n - 1]) + "z")
    out.append(String(""))
    return out^


def _active_ring(i: Int, alg: String = "EdDSA") raises -> Keyring:
    """A ring at T0 + LEAD whose signing key is key `i`."""
    var r = _ring(alg)
    r.rotate(_key(i, alg), T0)
    _ = r.render_jwks(T0)
    r.promote(_kid(i, alg), T0 + LEAD)
    return r^


def test_bounds() raises:
    # Catches: each bound of the ring moved by one or not checked, and an
    # algorithm compared loosely.
    assert_equal(_ring_err(), "")
    comptime TTL_E = "JoseError: the keyring max token TTL must be 1 to 86400 seconds"
    assert_equal(_ring_err(ttl=0), TTL_E)
    assert_equal(_ring_err(ttl=1), "")
    assert_equal(_ring_err(ttl=JOSE_MAX_TTL_S), "")
    assert_equal(_ring_err(ttl=JOSE_MAX_TTL_S + 1), TTL_E)
    comptime LD = "JoseError: the keyring publish lead must be 0 to 86400 seconds"
    assert_equal(_ring_err(lead=-1), LD)
    assert_equal(_ring_err(lead=0), "")
    assert_equal(_ring_err(lead=JOSE_MAX_PUBLISH_LEAD_S), "")
    assert_equal(_ring_err(lead=JOSE_MAX_PUBLISH_LEAD_S + 1), LD)
    # The bounds are the literals the refusal texts name, not whatever the
    # constants hold.
    assert_equal(JOSE_MAX_PUBLISH_LEAD_S, Int64(86400))
    assert_equal(_ring_err(lead=86400), "")
    assert_equal(_ring_err(lead=86401), LD)
    assert_equal(_ring_err(ttl=86400), "")
    assert_equal(_ring_err(ttl=86401), TTL_E)
    assert_equal(_ring_err(now=-1), "JoseError: the keyring time is negative")
    assert_equal(_ring_err(now=0), "")
    assert_equal(_ring_err(alg="ES256"), "")
    assert_equal(_ring_err(alg="RS256"), "")
    comptime ALG = "JoseError: the keyring algorithm must be ES256, EdDSA or RS256"
    # The near-miss tables of the three names, and two refused names.
    var misses = String("")
    var names = _near("ES256")
    names.extend(_near("EdDSA"))
    names.extend(_near("RS256"))
    names.append("HS256")
    names.append("none")
    for a in names:
        var got = _ring_err(alg=a.copy())
        if got != ALG:
            misses += a + " -> " + got + "; "
    assert_equal(misses, "")
    var r = _ring("ES256")
    assert_equal(r.alg(), "ES256")


def test_publish_before_sign() raises:
    # Catches: a staged key that signs before any document held it, or
    # before the publish lead passed; the lead counted from a later
    # document; a promote of another key than the one named; and a promoted
    # key left out of the documents its tokens are checked against.
    var r = _ring()
    assert_equal(
        _sign_err(r, _payload(T0), T0), "JoseError: the keyring has no signing key"
    )
    assert_equal(_promote_err(r, _kid(1), T0), "JoseError: no key is staged")
    r.rotate(_key(1), T0)
    assert_equal(r.staged_kid().value(), _kid(1))
    assert_true(not r.signing_kid())
    comptime UNPUBLISHED = "JoseError: the staged key has not been in a rendered key set"
    assert_equal(_promote_err(r, _kid(1), T0 + 5), UNPUBLISHED)
    var first = r.render_jwks(T0 + 10)
    assert_equal(_kids(first), _kid(1))
    # A second document does not restart the lead.
    _ = r.render_jwks(T0 + 500)
    comptime EARLY = "JoseError: the staged key has not been published for the publish lead"
    assert_equal(_promote_err(r, _kid(1), T0 + 10 + LEAD - 1), EARLY)
    # Only the staged key's exact kid promotes it.
    comptime OTHER = "JoseError: kid does not name the staged key"
    var misses = String("")
    var near = _near(_kid(1))
    near.append(_kid(2))
    for k in near:
        var got = _promote_err(r, k.copy(), T0 + 10 + LEAD)
        if got != OTHER:
            misses += k + " -> " + got + "; "
    assert_equal(misses, "")
    assert_equal(_promote_err(r, _kid(1), T0 + 10 + LEAD), "")
    assert_equal(r.signing_kid().value(), _kid(1))
    assert_true(not r.staged_kid())
    # Every token verifies under the document rendered before it was
    # signed, and under the first document that held the key.
    var now = T0 + 10 + LEAD + 1
    var doc = r.render_jwks(now)
    assert_equal(_kids(doc), _kid(1))
    var t = _sign(r, now)
    assert_equal(_check(doc, t, "EdDSA", now), "")
    assert_equal(_check(first, t, "EdDSA", now), "")


def test_publication_is_per_staged_key() raises:
    # Catches: a publication record that survives the key it was made for,
    # so a newly staged key signs without ever being published.
    var r = _ring()
    r.rotate(_key(1), T0)
    _ = r.render_jwks(T0)
    r.retire(_kid(1), T0 + 1)
    assert_true(not r.staged_kid())
    assert_equal(_kids(r.render_jwks(T0 + 2)), "")
    r.rotate(_key(2), T0 + 2)
    assert_equal(
        _promote_err(r, _kid(2), T0 + 2 * LEAD),
        "JoseError: the staged key has not been in a rendered key set",
    )
    # The same after a promote: the next key starts unpublished.
    var a = _active_ring(1)
    a.rotate(_key(2), T0 + LEAD)
    assert_equal(
        _promote_err(a, _kid(2), T0 + 3 * LEAD),
        "JoseError: the staged key has not been in a rendered key set",
    )
    # A lead of 0 still needs the key in a document first.
    var z = Keyring(alg="EdDSA", max_token_ttl_s=TTL, publish_lead_s=0, now=T0)
    z.rotate(_key(1), T0)
    assert_equal(
        _promote_err(z, _kid(1), T0),
        "JoseError: the staged key has not been in a rendered key set",
    )
    _ = z.render_jwks(T0)
    assert_equal(_promote_err(z, _kid(1), T0), "")


def test_rotation_and_retirement() raises:
    # Catches: a former key that still signs after promote; a former key
    # dropped from the document before every token it signed has expired
    # (leeway included), or kept after; the signing key retired; and the
    # document's order.
    var r = _active_ring(1)
    var t1_at = T0 + LEAD + 5
    var t1 = _sign(r, t1_at)
    r.rotate(_key(2), t1_at)
    var staged_doc = r.render_jwks(t1_at)
    assert_equal(_kids(staged_doc), _kid(1) + " " + _kid(2))
    var p = t1_at + LEAD
    r.promote(_kid(2), p)
    assert_equal(r.signing_kid().value(), _kid(2))
    assert_equal(len(r.retiring_kids()), 1)
    assert_equal(r.retiring_kids()[0], _kid(1))
    # The former key never signs again.
    var t2 = _sign(r, p)
    var doc = r.render_jwks(p)
    assert_equal(_kids(doc), _kid(2) + " " + _kid(1))
    assert_equal(_check(doc, t2, "EdDSA", p), "")
    # t2 names key 2: a document holding only key 1 refuses it.
    var r1 = _active_ring(1)
    var doc1 = r1.render_jwks(p)
    assert_equal(_check(doc1, t2, "EdDSA", p), "JoseError: kid names no key in the set")
    # The signing key cannot be retired.
    assert_equal(
        _retire_err(r, _kid(2), p),
        "JoseError: the signing key cannot be retired: promote a successor first",
    )
    # Key 1 stays published until its last token has expired with leeway.
    comptime EARLY = "JoseError: a retiring key stays published for the max token TTL plus the leeway"
    assert_equal(_retire_err(r, _kid(1), p + TTL + LEEWAY - 1), EARLY)
    assert_equal(_check(r.render_jwks(p + TTL + LEEWAY - 1), t1, "EdDSA", t1_at + TTL + LEEWAY - 1), "")
    assert_equal(_retire_err(r, _kid(1), p + TTL + LEEWAY), "")
    assert_equal(_kids(r.render_jwks(p + TTL + LEEWAY)), _kid(2))
    assert_equal(len(r.retiring_kids()), 0)
    assert_equal(
        _retire_err(r, _kid(1), p + TTL + LEEWAY),
        "JoseError: kid names no key in the keyring",
    )
    # A staged key has signed nothing: it is removed at once.
    var q = p + TTL + LEEWAY
    r.rotate(_key(3), q)
    assert_equal(_kids(r.render_jwks(q)), _kid(2) + " " + _kid(3))
    assert_equal(_retire_err(r, _kid(3), q), "")
    assert_true(not r.staged_kid())
    assert_equal(_kids(r.render_jwks(q)), _kid(2))


def test_retirement_outlasts_every_verifier_leeway() raises:
    # Catches: a retirement bound below the largest leeway a verifier may
    # have (a keyring leeway of its own, such as 0 or 30, under verifiers
    # at 60), so the former key leaves the set while its last token still
    # verifies; and the bound moved past it. Key 1's last token is signed
    # the second key 1 stops signing, with the full TTL: a verifier at
    # leeway 60 accepts it until p + TTL + 60.
    assert_equal(JOSE_MAX_LEEWAY_S, Int64(60))
    assert_equal(LEEWAY, JOSE_MAX_LEEWAY_S)
    var r = _active_ring(1)
    r.rotate(_key(2), T0 + LEAD)
    _ = r.render_jwks(T0 + LEAD)
    var p = T0 + 2 * LEAD
    var last = _sign(r, p)
    r.promote(_kid(2), p)
    comptime EARLY = "JoseError: a retiring key stays published for the max token TTL plus the leeway"
    var late = p + 300 + 59
    var doc = r.render_jwks(late)
    assert_equal(_kids(doc), _kid(2) + " " + _kid(1))
    assert_equal(_check(doc, last, "EdDSA", late), "")
    assert_equal(_retire_err(r, _kid(1), late), EARLY)
    assert_equal(_retire_err(r, _kid(1), p + 300 + 60), "")
    assert_equal(
        _check(doc, last, "EdDSA", p + 300 + 60), "JoseError: the token has expired"
    )


def test_document_order() raises:
    # Catches: a rendered set that is not the signing key, then the staged
    # key, then the retiring keys oldest first (the order the keyring
    # header documents): the staged key after the retiring keys, or the
    # retiring keys newest first. One set holds all three roles and two
    # retiring keys.
    var r = _active_ring(1)
    var t = T0 + LEAD
    r.rotate(_key(2), t)
    _ = r.render_jwks(t)
    t += LEAD
    r.promote(_kid(2), t)
    r.rotate(_key(3), t)
    _ = r.render_jwks(t)
    t += LEAD
    r.promote(_kid(3), t)
    r.rotate(_key(4), t)
    assert_equal(r.signing_kid().value(), _kid(3))
    assert_equal(r.staged_kid().value(), _kid(4))
    var kids = r.retiring_kids()
    assert_equal(len(kids), 2)
    assert_equal(kids[0], _kid(1))
    assert_equal(kids[1], _kid(2))
    assert_equal(
        _kids(r.render_jwks(t)),
        _kid(3) + " " + _kid(4) + " " + _kid(1) + " " + _kid(2),
    )


def test_retire_names_one_key() raises:
    # Catches: a retiring key found by a loose compare, or only the first
    # retiring key looked at; the grace measured from another key.
    var r = _active_ring(1)
    var now = T0 + LEAD
    for i in range(2, 5):
        r.rotate(_key(i), now)
        _ = r.render_jwks(now)
        now += LEAD
        r.promote(_kid(i), now)
    # Retiring: 1 (since T0+2*LEAD), 2 (T0+3*LEAD), 3 (T0+4*LEAD); 4 signs.
    var kids = r.retiring_kids()
    assert_equal(len(kids), 3)
    assert_equal(kids[0], _kid(1))
    assert_equal(kids[2], _kid(3))
    comptime EARLY = "JoseError: a retiring key stays published for the max token TTL plus the leeway"
    # The last retiring key is still in its grace when the first is out.
    var t = now + TTL + LEEWAY - 1
    assert_equal(_retire_err(r, _kid(3), t), EARLY)
    assert_equal(_retire_err(r, _kid(1), t), "")
    var misses = String("")
    comptime NONE = "JoseError: kid names no key in the keyring"
    for k in _near(_kid(3)):
        var got = _retire_err(r, k.copy(), now + TTL + LEEWAY)
        if got != NONE:
            misses += String("retiring ") + k + " -> " + got + "; "
    # Near misses of the signing key and of a staged key name no key
    # either: neither is refused as the signing key nor retired.
    for k in _near(_kid(4)):
        var got = _retire_err(r, k.copy(), now + TTL + LEEWAY)
        if got != NONE:
            misses += String("signing ") + k + " -> " + got + "; "
    r.rotate(_key(5), now + TTL + LEEWAY)
    for k in _near(_kid(5)):
        var got = _retire_err(r, k.copy(), now + TTL + LEEWAY)
        if got != NONE:
            misses += String("staged ") + k + " -> " + got + "; "
    assert_equal(misses, "")
    assert_equal(r.staged_kid().value(), _kid(5))
    assert_equal(r.signing_kid().value(), _kid(4))
    assert_equal(_retire_err(r, _kid(3), now + TTL + LEEWAY), "")
    assert_equal(r.retiring_kids()[0], _kid(2))


def test_retiring_cap() raises:
    # Catches: the cap moved by one, or checked after the old key is
    # dropped (the ring then has no signing key).
    var r = _active_ring(1)
    var now = T0 + LEAD
    for i in range(2, 2 + JOSE_KEYRING_MAX_RETIRING):
        r.rotate(_key(i), now)
        _ = r.render_jwks(now)
        now += LEAD
        r.promote(_kid(i), now)
    assert_equal(len(r.retiring_kids()), JOSE_KEYRING_MAX_RETIRING)
    var last = 2 + JOSE_KEYRING_MAX_RETIRING
    r.rotate(_key(last), now)
    _ = r.render_jwks(now)
    now += LEAD
    assert_equal(
        _promote_err(r, _kid(last), now),
        "JoseError: the keyring holds the most retiring keys: retire one first",
    )
    assert_equal(r.signing_kid().value(), _kid(last - 1))
    assert_equal(_sign_err(r, _payload(now), now), "")
    r.retire(_kid(1), now)
    assert_equal(_promote_err(r, _kid(last), now), "")


def test_rotate_refusals() raises:
    # Catches: a key of another algorithm staged, a second staged key, and
    # a kid the ring holds (the signing key, or the LAST retiring key)
    # staged again.
    comptime ALG = "JoseError: the key's algorithm is not the keyring's"
    var e = _ring()
    assert_equal(_rotate_err(e, _key(1, "ES256"), T0), ALG)
    var s = _ring("ES256")
    assert_equal(_rotate_err(s, _key(1), T0), ALG)
    assert_equal(_rotate_err(s, _key(1, "ES256"), T0), "")
    assert_equal(
        _rotate_err(s, _key(2, "ES256"), T0),
        "JoseError: a staged key is waiting: promote or retire it first",
    )
    comptime HELD = "JoseError: the key is already in the keyring"
    var r = _active_ring(1)
    assert_equal(_rotate_err(r, _key(1), T0 + LEAD), HELD)
    var now = T0 + LEAD
    for i in range(2, 4):
        r.rotate(_key(i), now)
        _ = r.render_jwks(now)
        now += LEAD
        r.promote(_kid(i), now)
    # Retiring 1, 2; key 3 signs. Key 2 is the last retiring key.
    assert_equal(_rotate_err(r, _key(2), now), HELD)
    assert_equal(_rotate_err(r, _key(4), now), "")


def test_sign_bounds_the_lifetime() raises:
    # Catches: a token that outlives the max token TTL signed (so a former
    # key's last token outlives its publication), the bound moved by one,
    # and a payload that is not a claims object signed.
    var r = _active_ring(1)
    var now = T0 + LEAD
    assert_equal(_sign_err(r, _payload(now, TTL), now), "")
    assert_equal(
        _sign_err(r, _payload(now, TTL + 1), now),
        "JoseError: the token would outlive the keyring's max token TTL",
    )
    assert_equal(_sign_err(r, _payload(now, 1), now), "")
    assert_equal(_sign_err(r, '{"exp":1,"iat":0}', now), "")
    assert_equal(_sign_err(r, "{", now), "JoseError: the payload is not JSON")
    assert_equal(_sign_err(r, "", now), "JoseError: the payload is not JSON")
    assert_equal(_sign_err(r, "[]", now), "JoseError: the payload is not a JSON object")
    assert_equal(
        _sign_err(r, '{"exp":1,"exp":2}', now),
        "JoseError: the payload names a member twice",
    )
    assert_equal(_sign_err(r, '{"iat":1}', now), "JoseError: claim exp is missing")
    assert_equal(
        _sign_err(r, '{"exp":"1"}', now),
        "JoseError: claim exp is not a non-negative integer",
    )
    # iat is required as verify_jwt requires it: a token every relying
    # party refuses is not signed.
    assert_equal(_sign_err(r, '{"exp":1}', now), "JoseError: claim iat is missing")
    var no_iat = _payload(now).replace(String('"iat":'), String('"iax":'))
    assert_equal(_sign_err(r, no_iat, now), "JoseError: claim iat is missing")
    assert_equal(
        _sign_err(r, '{"exp":1,"iat":"0"}', now),
        "JoseError: claim iat is not a non-negative integer",
    )
    assert_equal(
        _sign_err(r, '{"exp":1,"iat":-1}', now),
        "JoseError: claim iat is not a non-negative integer",
    )
    # The token a ring signs is the payload it was given.
    var t = r.sign(_payload(now), String("at+jwt"), now)
    assert_equal(_check(r.render_jwks(now), t, "EdDSA", now), "")


def test_time_only_moves_forward() raises:
    # Catches: a call that does not read the time, or accepts an earlier
    # one (a clock step back would shorten a retirement).
    comptime BACK = "JoseError: the keyring time went backwards"
    var now = T0 + LEAD
    var r = _active_ring(1)
    assert_equal(_sign_err(r, _payload(now), now - 1), BACK)
    var r2 = _active_ring(1)
    assert_equal(_rotate_err(r2, _key(2), now - 1), BACK)
    var r3 = _active_ring(1)
    var got = String("")
    try:
        _ = r3.render_jwks(now - 1)
    except e:
        got = String(e)
    assert_equal(got, BACK)
    var r4 = _active_ring(1)
    r4.rotate(_key(2), now)
    _ = r4.render_jwks(now)
    assert_equal(_promote_err(r4, _kid(2), now + LEAD), "")
    assert_equal(_retire_err(r4, _kid(1), now + LEAD - 1), BACK)
    var r5 = _active_ring(1)
    r5.rotate(_key(2), now + LEAD)
    assert_equal(_promote_err(r5, _kid(2), now + LEAD - 1), BACK)
    # Each call moves the ring's time: an equal time is accepted, and a
    # call at a later time sets the floor for the next.
    var r6 = _active_ring(1)
    assert_equal(_sign_err(r6, _payload(now), now), "")
    assert_equal(_sign_err(r6, _payload(now + 5), now + 5), "")
    assert_equal(_sign_err(r6, _payload(now + 4), now + 4), BACK)


def test_es256_ring() raises:
    # Catches: a ring that only works for one algorithm.
    var r = _active_ring(1, "ES256")
    var now = T0 + LEAD
    var t = _sign(r, now)
    assert_equal(_check(r.render_jwks(now), t, "ES256", now), "")
    assert_equal(r.signing_kid().value(), _kid(1, "ES256"))


def main() raises:
    var failures = String("")
    try:
        test_bounds()
    except e:
        failures += String("test_bounds: ") + String(e) + "\n"
    try:
        test_publish_before_sign()
    except e:
        failures += String("test_publish_before_sign: ") + String(e) + "\n"
    try:
        test_publication_is_per_staged_key()
    except e:
        failures += String("test_publication_is_per_staged_key: ") + String(e) + "\n"
    try:
        test_rotation_and_retirement()
    except e:
        failures += String("test_rotation_and_retirement: ") + String(e) + "\n"
    try:
        test_retirement_outlasts_every_verifier_leeway()
    except e:
        failures += String("test_retirement_outlasts_every_verifier_leeway: ") + String(e) + "\n"
    try:
        test_document_order()
    except e:
        failures += String("test_document_order: ") + String(e) + "\n"
    try:
        test_retire_names_one_key()
    except e:
        failures += String("test_retire_names_one_key: ") + String(e) + "\n"
    try:
        test_retiring_cap()
    except e:
        failures += String("test_retiring_cap: ") + String(e) + "\n"
    try:
        test_rotate_refusals()
    except e:
        failures += String("test_rotate_refusals: ") + String(e) + "\n"
    try:
        test_sign_bounds_the_lifetime()
    except e:
        failures += String("test_sign_bounds_the_lifetime: ") + String(e) + "\n"
    try:
        test_time_only_moves_forward()
    except e:
        failures += String("test_time_only_moves_forward: ") + String(e) + "\n"
    try:
        test_es256_ring()
    except e:
        failures += String("test_es256_ring: ") + String(e) + "\n"
    if failures != "":
        print(failures)
        raise Error("test_keyring: FAILED\n" + failures)
    print("test_keyring: OK")
