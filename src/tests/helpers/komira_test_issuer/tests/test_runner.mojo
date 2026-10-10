# =============================================================================
# test_runner.mojo: the scenario runner (scenarios.mojo) on scripted faulty
#   issuers, each failing the scenario that names its fault.
# =============================================================================
#
# A runner that passes everything would make test_scenarios.mojo green on any
# issuer. `Faulty` wraps a `TestIssuer` and conforms to `IssuerUnderTest`;
# with no fault it passes the whole table (so the wrapper itself is
# faithful), and with one fault the report must hold the exact line of the
# scenario that fault breaks:
#
#   drop_at_switch / retire_one_early -> in_flight_survives_rotation
#     (the former key leaves the document at the switch, or 1 s before its
#     tokens' exp plus the leeway: the plan's defect, seen from outside);
#   hide_staged     -> publish_before_sign (no new key published);
#   swap_staged     -> publish_before_sign (another new key published than
#                      the one that signs after the switch);
#   early_switch    -> publish_before_sign (the new key signs during the
#                      lead; the issuer inside has a lead of 0);
#   no_switch       -> publish_before_sign (the old key still signs);
#   kid_not_thumbprint -> mint_verifies (signed by a key whose kid is a
#                      near miss of its RFC 7638 thumbprint);
#   kid_swap        -> mint_verifies (the kid is another served key's
#                      thumbprint, that key served under an unrelated kid
#                      or a near miss of it);
#   wrong_typ       -> mint_verifies (the issuer inside mints `JWT`);
#   sub, client_id, scope -> claims, for every near miss of the value asked
#                      for and, for client_id and scope, the member left out;
#   iat one second early or late -> claims;
#   client_id or jti as a JSON number (whose text equals the client_id
#                      asked for) -> claims, and jti_unique for the jti;
#   jti left out or empty -> claims and jti_unique;
#   repeat_jti      -> jti_unique (jti-1, jti-2, jti-2: the repeat is of the
#                      last jti seen);
#   empty_subject_ok -> subject_required.
#
# main runs every test and reports every failure.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_jose import JwsSigner
from komira_jwks import Jwk, parse_jwk_set, render_jwk_set
from komira_secret_store import SecretValue
from komira_test_issuer import (
    SCENARIO_CLAIMS,
    SCENARIO_IN_FLIGHT,
    SCENARIO_JTI_UNIQUE,
    SCENARIO_MINT_VERIFIES,
    SCENARIO_PUBLISH_BEFORE_SIGN,
    SCENARIO_SCOPE,
    SCENARIO_SUBJECT,
    SCENARIO_SUBJECT_REQUIRED,
    IssuerProfile,
    IssuerUnderTest,
    TestIssuer,
    derived_key,
    run_issuer_scenario,
    run_issuer_scenarios,
)


comptime T0: Int64 = 1000000
comptime TTL: Int64 = 300
comptime LEEWAY: Int64 = 30
comptime LEAD: Int64 = 600
comptime ISS = "https://issuer.example/a"
comptime AUD = "service-a"
comptime CLIENT = "client-a"

comptime F_NONE = 0
comptime F_DROP_AT_SWITCH = 1
comptime F_RETIRE_ONE_EARLY = 2
comptime F_HIDE_STAGED = 3
comptime F_SWAP_STAGED = 4
comptime F_EARLY_SWITCH = 5
comptime F_NO_SWITCH = 6
comptime F_KID_NOT_THUMBPRINT = 7
comptime F_WRONG_TYP = 8
comptime F_SUB = 9
comptime F_CLIENT_ID = 10
comptime F_SCOPE = 11
comptime F_IAT = 12
comptime F_JTI = 13
comptime F_REPEAT_JTI = 14
comptime F_EMPTY_SUBJECT_OK = 15
comptime F_KID_SWAP = 16


def _profile() -> IssuerProfile:
    return IssuerProfile(
        String(ISS),
        String(AUD),
        String(CLIENT),
        String("ES256"),
        String("at+jwt"),
        TTL,
        LEEWAY,
        LEAD,
    )


def _holds(list: List[String], s: String) -> Bool:
    for i in range(len(list)):
        if list[i] == s:
            return True
    return False


def _without(doc: String, drop: List[String]) raises -> String:
    var set = parse_jwk_set(doc)
    var keep = List[Jwk]()
    for i in range(len(set.keys)):
        if not _holds(drop, set.keys[i].kid().value()):
            keep.append(set.keys[i].copy())
    return render_jwk_set(keep)


def _with(doc: String, key: Jwk) raises -> String:
    var set = parse_jwk_set(doc)
    var keys = set.keys.copy()
    keys.append(key.copy())
    return render_jwk_set(keys)


def _odd_scalar() -> List[UInt8]:
    var d = List[UInt8](length=32, fill=UInt8(0))
    d[31] = UInt8(7)
    return d^


def _odd_signer(kid: String) raises -> JwsSigner:
    """An ES256 signer whose published kid is `kid`, not its thumbprint."""
    var real = JwsSigner.es256(SecretValue(Span(_odd_scalar())))
    var x = real.public_jwk().x()
    var y = real.public_jwk().y()
    var public = Jwk.ec_p256(
        Span(x), Span(y), kid=kid, alg=String("ES256"), key_use=String("sig")
    )
    return JwsSigner(
        _alg=String("ES256"),
        _secret=SecretValue(Span(_odd_scalar())),
        _public=public^,
    )


def _member(name: String, value: String) -> String:
    """`,"name":value`, with `value` quoted unless it starts with `#` (then
    the rest is written as raw JSON)."""
    if value.startswith("#"):
        return String(',"') + name + '":' + String(value[byte = 1 : value.byte_length()])
    return String(',"') + name + '":"' + value + '"'


def _claims(
    sub: String,
    iat: Int64,
    exp: Int64,
    jti: Optional[String],
    client_id: Optional[String],
    scope: Optional[String],
) -> String:
    var out = (
        String('{"iss":"') + ISS + '","sub":"' + sub + '","aud":"' + AUD
        + '","iat":' + String(iat) + ',"exp":' + String(exp)
    )
    if jti:
        out += _member("jti", jti.value())
    if client_id:
        out += _member("client_id", client_id.value())
    if scope:
        out += _member("scope", scope.value())
    return out + "}"


struct Faulty(IssuerUnderTest, Movable, Deinitable):
    """A `TestIssuer` with one scripted fault (see the file header)."""

    var inner: TestIssuer
    var fault: Int
    var alt: Optional[String]
    var alt2: String
    var minted: Int
    var former: String
    var switched_at: Int64

    def __init__(
        out self, fault: Int, alt: Optional[String] = None, alt2: String = ""
    ) raises:
        self.inner = TestIssuer(
            issuer=ISS,
            alg="ES256",
            typ="JWT" if fault == F_WRONG_TYP else "at+jwt",
            max_ttl_s=TTL,
            leeway_s=LEEWAY,
            publish_lead_s=0 if fault == F_EARLY_SWITCH else LEAD,
            seed="seed-a",
            now=T0,
        )
        self.fault = fault
        self.alt = alt
        self.alt2 = alt2
        self.minted = 0
        self.former = String("")
        self.switched_at = -1

    def now(self) -> Int64:
        return self.inner.now()

    def advance(mut self, seconds: Int64) raises:
        self.inner.advance(seconds)

    def jwks_document(mut self) raises -> String:
        var doc = self.inner.jwks()
        var staged = self.inner.staged_kid()
        if self.fault == F_DROP_AT_SWITCH:
            return _without(doc, self.inner.retiring_kids())
        if self.fault == F_RETIRE_ONE_EARLY and self.switched_at >= 0:
            if self.inner.now() >= self.switched_at + TTL + LEEWAY - 1:
                var drop = List[String]()
                drop.append(self.former)
                return _without(doc, drop)
        if self.fault == F_HIDE_STAGED and staged:
            var drop = List[String]()
            drop.append(staged.value())
            return _without(doc, drop)
        if self.fault == F_SWAP_STAGED and staged:
            var drop = List[String]()
            drop.append(staged.value())
            var other = derived_key("ES256", "seed-other", 0).public_jwk()
            return _with(_without(doc, drop), other)
        if self.fault == F_KID_NOT_THUMBPRINT:
            return _with(doc, _odd_signer(self.alt.value()).public_jwk())
        if self.fault == F_KID_SWAP:
            # Key 0 published under another kid, and the odd key under key
            # 0's thumbprint: the kid a token names is some key's thumbprint,
            # but not the thumbprint of the key it names.
            var drop = List[String]()
            drop.append(self.alt.value())
            var a = derived_key("ES256", "seed-a", 0).public_jwk()
            var x = a.x()
            var y = a.y()
            var renamed = Jwk.ec_p256(
                Span(x), Span(y), kid=self.alt2, alg=String("ES256"), key_use=String("sig")
            )
            var swapped = _with(_without(doc, drop), renamed)
            return _with(swapped, _odd_signer(self.alt.value()).public_jwk())
        return doc

    def mint_user_token(
        mut self,
        subject: String,
        audience: String,
        client_id: String,
        scope: String,
    ) raises -> String:
        if self.fault < F_KID_NOT_THUMBPRINT or self.fault == F_WRONG_TYP:
            return self.inner.mint_user_token(subject, audience, client_id, scope)
        if subject == "" and self.fault != F_EMPTY_SUBJECT_OK:
            return self.inner.mint_user_token(subject, audience, client_id, scope)
        var now = self.inner.now()
        var typ = Optional[String](self.inner.typ())
        var sub = subject if subject != "" else String("anonymous")
        self.minted += 1
        var jti = Optional[String](String("jti-") + String(self.minted))
        if self.fault == F_KID_NOT_THUMBPRINT or self.fault == F_KID_SWAP:
            var c = _claims(sub, now, now + TTL, jti, client_id, scope)
            return _odd_signer(self.alt.value()).sign(c.as_bytes(), typ)
        if self.fault == F_SUB:
            sub = self.alt.value()
        var cid = Optional[String](client_id)
        if self.fault == F_CLIENT_ID:
            cid = self.alt
        var sc = Optional[String](scope)
        if self.fault == F_SCOPE:
            sc = self.alt
        var iat = now
        if self.fault == F_IAT:
            iat = now + self.alt_shift()
        if self.fault == F_JTI:
            jti = self.alt
        if self.fault == F_REPEAT_JTI:
            # jti-1, jti-2, jti-2, ...: the repeat matches the LAST jti seen.
            jti = Optional[String](String("jti-") + String(min(self.minted, 2)))
        var exp = now + TTL - 1
        return self.inner.sign_claims(_claims(sub, iat, exp, jti, cid, sc), typ)

    def alt_shift(self) -> Int64:
        return -1 if self.alt.value() == "early" else 1

    def begin_rotation(mut self) raises:
        if self.fault == F_EARLY_SWITCH:
            self.inner.begin_rotation()
            _ = self.inner.jwks()
            self._switch()
            return
        self.inner.begin_rotation()

    def finish_rotation(mut self) raises:
        if self.fault == F_EARLY_SWITCH or self.fault == F_NO_SWITCH:
            return
        self._switch()

    def _switch(mut self) raises:
        self.former = self.inner.signing_kid()
        self.switched_at = self.inner.now()
        self.inner.finish_rotation()


def _line(report: String, scenario: String, reason: String) -> Bool:
    """Whether `report` has a line `<scenario>: <reason>...`."""
    var lines = report.split("\n")
    for i in range(len(lines)):
        if String(lines[i]).startswith(scenario + ": " + reason):
            return True
    return False


def test_faithful_wrapper_passes() raises:
    var f = Faulty(F_NONE)
    assert_equal(run_issuer_scenarios(f, _profile()), "")


def _expect(
    mut misses: String, fault: Int, scenario: String, reason: String
) raises:
    var f = Faulty(fault)
    var report = run_issuer_scenarios(f, _profile())
    if not _line(report, scenario, reason):
        misses += String("fault ") + String(fault) + " did not fail " + scenario + ":\n" + report


def test_rotation_faults() raises:
    var misses = String("")
    comptime GONE = "a token signed at the switch fails under the document served at its exp plus the leeway minus 1 s: "
    _expect(misses, F_DROP_AT_SWITCH, SCENARIO_IN_FLIGHT, GONE)
    _expect(misses, F_RETIRE_ONE_EARLY, SCENARIO_IN_FLIGHT, GONE)
    _expect(misses, F_HIDE_STAGED, SCENARIO_PUBLISH_BEFORE_SIGN, "starting a rotation published no new key")
    _expect(
        misses,
        F_SWAP_STAGED,
        SCENARIO_PUBLISH_BEFORE_SIGN,
        "a token signed after the switch fails under the document served when the rotation started: ",
    )
    _expect(
        misses,
        F_EARLY_SWITCH,
        SCENARIO_PUBLISH_BEFORE_SIGN,
        "a token signed during the publish lead fails under the document from before the rotation: ",
    )
    _expect(misses, F_NO_SWITCH, SCENARIO_PUBLISH_BEFORE_SIGN, "after the switch the token is not signed by a new key")
    _expect(misses, F_WRONG_TYP, SCENARIO_MINT_VERIFIES, "JoseError: header typ is not the pinned type")
    _expect(misses, F_REPEAT_JTI, SCENARIO_JTI_UNIQUE, "two tokens carry one jti")
    _expect(misses, F_EMPTY_SUBJECT_OK, SCENARIO_SUBJECT_REQUIRED, "a token was minted for an empty subject")
    assert_equal(misses, "")


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


def _claims_fault(
    mut misses: String,
    fault: Int,
    alt: Optional[String],
    scenario: String,
    reason: String,
    client_id: String = CLIENT,
    alt2: String = "",
) raises:
    var f = Faulty(fault, alt, alt2)
    var p = _profile()
    p.client_id = client_id
    var got = run_issuer_scenario(f, p, scenario)
    if got != reason:
        var shown = alt.value() if alt else String("<absent>")
        misses += String("fault ") + String(fault) + " " + shown + ": " + got + "\n"


def test_claim_faults() raises:
    var misses = String("")
    comptime SUB = "sub is not the subject the token was minted for"
    comptime CID = "client_id is not the client the token was minted for"
    comptime SCOPE = "scope is not the scope the token was minted for"
    var subs = _near_misses(SCENARIO_SUBJECT)
    for i in range(len(subs) - 1):  # an empty sub is the verifier's refusal
        _claims_fault(misses, F_SUB, subs[i], SCENARIO_CLAIMS, SUB)
    var cids = _near_misses(CLIENT)
    for i in range(len(cids)):
        _claims_fault(misses, F_CLIENT_ID, cids[i], SCENARIO_CLAIMS, CID)
    _claims_fault(misses, F_CLIENT_ID, None, SCENARIO_CLAIMS, CID)
    var scopes = _near_misses(SCENARIO_SCOPE)
    for i in range(len(scopes)):
        _claims_fault(misses, F_SCOPE, scopes[i], SCENARIO_CLAIMS, SCOPE)
    _claims_fault(misses, F_SCOPE, None, SCENARIO_CLAIMS, SCOPE)
    comptime IAT = "iat is not the issuer's time"
    _claims_fault(misses, F_IAT, String("early"), SCENARIO_CLAIMS, IAT)
    _claims_fault(misses, F_IAT, String("late"), SCENARIO_CLAIMS, IAT)
    comptime JTI = "jti is not a non-empty string"
    _claims_fault(misses, F_JTI, None, SCENARIO_CLAIMS, JTI)
    _claims_fault(misses, F_JTI, String(""), SCENARIO_CLAIMS, JTI)
    _claims_fault(misses, F_JTI, None, SCENARIO_JTI_UNIQUE, JTI)
    # A member that is not a string, even one whose JSON text equals the
    # expected value, is refused.
    _claims_fault(misses, F_CLIENT_ID, String("#12345"), SCENARIO_CLAIMS, CID, "12345")
    _claims_fault(misses, F_JTI, String("#5"), SCENARIO_CLAIMS, JTI)
    _claims_fault(misses, F_JTI, String("#5"), SCENARIO_JTI_UNIQUE, JTI)
    _claims_fault(misses, F_JTI, String(""), SCENARIO_JTI_UNIQUE, JTI)
    assert_equal(misses, "")


def test_kid_not_thumbprint() raises:
    # Every near miss of the odd key's real thumbprint (the empty kid is
    # refused by komira_jwks before any token exists).
    var real = JwsSigner.es256(SecretValue(Span(_odd_scalar()))).kid()
    var near = _near_misses(real)
    var misses = String("")
    comptime WHY = "the token's kid is not the RFC 7638 thumbprint of its key"
    for i in range(len(near) - 1):
        _claims_fault(misses, F_KID_NOT_THUMBPRINT, near[i], SCENARIO_MINT_VERIFIES, WHY)
    # Key 0's thumbprint named by the odd key, key 0 served under another
    # kid: an unrelated one and every near miss of its thumbprint (so a
    # loose kid match cannot pick key 0 and find its thumbprint).
    var a = derived_key("ES256", "seed-a", 0).kid()
    var renames = _near_misses(a)
    renames[len(renames) - 1] = String("swapped-a")  # in place of ""
    for i in range(len(renames)):
        _claims_fault(
            misses, F_KID_SWAP, a, SCENARIO_MINT_VERIFIES, WHY, CLIENT, renames[i]
        )
    # With its real thumbprint as kid the same key passes.
    _claims_fault(misses, F_KID_NOT_THUMBPRINT, real, SCENARIO_MINT_VERIFIES, "")
    assert_equal(misses, "")


def main() raises:
    var failures = String("")
    try:
        test_faithful_wrapper_passes()
    except e:
        failures += String("test_faithful_wrapper_passes: ") + String(e) + "\n"
    try:
        test_rotation_faults()
    except e:
        failures += String("test_rotation_faults: ") + String(e) + "\n"
    try:
        test_claim_faults()
    except e:
        failures += String("test_claim_faults: ") + String(e) + "\n"
    try:
        test_kid_not_thumbprint()
    except e:
        failures += String("test_kid_not_thumbprint: ") + String(e) + "\n"
    if failures != "":
        print(failures)
        raise Error("test_runner failed")
    print("PASS komira_test_issuer test_runner")
