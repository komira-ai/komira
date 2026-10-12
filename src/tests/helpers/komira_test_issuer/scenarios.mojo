# =============================================================================
# komira_test_issuer/scenarios.mojo: the scenario table an issuer in the
#   HTTP auth design must pass, and the runner that drives any
#   `IssuerUnderTest` through it.
# =============================================================================
#
# Every token is checked the way a relying party checks it: the document the
# issuer served is parsed with komira_jwks, a komira_jose `JwsVerifier` pinned
# to the profile's `alg` is built from it, and `verify_jwt` applies a
# `ClaimPolicy` of the profile's issuer, audience, `typ`, leeway and max
# lifetime at the issuer's time. The scenarios, in table order:
#
#   * mint_verifies: a minted token verifies under the document served just
#     before, and its `kid` is the RFC 7638 thumbprint of the key it names;
#   * claims: `sub`, `client_id` and `scope` are exactly what was asked for,
#     `iat` is the issuer's time, and `jti` is a non-empty string;
#   * jti_unique: 32 tokens minted at one time carry 32 distinct `jti`s;
#   * subject_required: a mint for an empty subject is refused;
#   * publish_before_sign: starting a rotation publishes at least one new key;
#     tokens signed during the publish lead still verify under the document
#     from before the rotation; after the lead and the switch, the token is
#     signed by a new key and verifies under the document served when the
#     rotation started (a relying party that has not refetched since);
#   * in_flight_survives_rotation: a token signed at the switch, with the
#     issuer's lifetime, verifies under the document served at its `exp` plus
#     the leeway minus one second, the last moment a relying party accepts
#     it.
#
# The scenarios run in that order on one issuer and move its clock. A
# scenario's failure is one line of text; `run_issuer_scenarios` collects
# one `<scenario>: <reason>` line per failing scenario, or "" when all pass.
#
# ENCAPSULATION: the issuer is borrowed mutably for the run; values out. No
# pointer crosses this file's API.
# =============================================================================

from komira_jose import ClaimPolicy, JwsVerifier, VerifiedJwt, jwk_thumbprint, verify_jwt
from komira_json import JSON_STRING, JsonValue
from komira_jwks import parse_jwk_set

from komira_test_issuer.issuer import TestIssuer
from komira_test_issuer.under_test import IssuerProfile, IssuerUnderTest

comptime SCENARIO_MINT_VERIFIES: String = "mint_verifies"
comptime SCENARIO_CLAIMS: String = "claims"
comptime SCENARIO_JTI_UNIQUE: String = "jti_unique"
comptime SCENARIO_SUBJECT_REQUIRED: String = "subject_required"
comptime SCENARIO_PUBLISH_BEFORE_SIGN: String = "publish_before_sign"
comptime SCENARIO_IN_FLIGHT: String = "in_flight_survives_rotation"

# The subject and scope every scenario mints for.
comptime SCENARIO_SUBJECT: String = "subject-1"
comptime SCENARIO_SCOPE: String = "read write"
# How many tokens jti_unique mints.
comptime SCENARIO_JTI_SAMPLES: Int = 32


def issuer_scenarios() -> List[String]:
    """The scenario names, in the order `run_issuer_scenarios` runs them."""
    var out = List[String]()
    out.append(SCENARIO_MINT_VERIFIES)
    out.append(SCENARIO_CLAIMS)
    out.append(SCENARIO_JTI_UNIQUE)
    out.append(SCENARIO_SUBJECT_REQUIRED)
    out.append(SCENARIO_PUBLISH_BEFORE_SIGN)
    out.append(SCENARIO_IN_FLIGHT)
    return out^


def profile_of(
    issuer: TestIssuer, audience: String, client_id: String
) -> IssuerProfile:
    """The profile a relying party of `issuer` configures, for `audience`
    and `client_id`."""
    return IssuerProfile(
        issuer.issuer(),
        audience.copy(),
        client_id.copy(),
        issuer.alg(),
        issuer.typ(),
        issuer.max_ttl_s(),
        issuer.leeway_s(),
        issuer.publish_lead_s(),
    )


def verify_as_relying_party(
    document: String, token: String, profile: IssuerProfile, now: Int64
) raises -> VerifiedJwt:
    """`token` checked under the served `document` the way the scenarios
    check it (see the file header). Raises `JwksError: ...` or
    `JoseError: ...` as komira_jwks and komira_jose do."""
    var keys = parse_jwk_set(document)
    var verifier = JwsVerifier(profile.alg, keys)
    var policy = ClaimPolicy(
        issuer=profile.issuer,
        audience=profile.audience,
        accept_typ=profile.typ,
        now=now,
        leeway_s=profile.leeway_s,
        max_ttl_s=profile.max_ttl_s,
    )
    return verify_jwt(token, verifier, policy)


def _string_member(obj: JsonValue, name: String) -> Optional[String]:
    for i in range(len(obj.obj_keys)):
        if obj.obj_keys[i] == name:
            if obj.children[i].kind == JSON_STRING:
                return Optional[String](obj.children[i].text.copy())
            return Optional[String]()
    return Optional[String]()


def _kids(document: String) raises -> List[String]:
    var keys = parse_jwk_set(document)
    var out = List[String]()
    for i in range(len(keys.keys)):
        out.append(keys.keys[i].kid().or_else(String("")))
    return out^


def _holds(list: List[String], s: String) -> Bool:
    for i in range(len(list)):
        if list[i] == s:
            return True
    return False


def _mint[I: IssuerUnderTest](mut issuer: I, p: IssuerProfile) raises -> String:
    return issuer.mint_user_token(
        SCENARIO_SUBJECT, p.audience, p.client_id, SCENARIO_SCOPE
    )


def _mint_verifies[I: IssuerUnderTest](mut issuer: I, p: IssuerProfile) raises:
    var document = issuer.jwks_document()
    var token = _mint(issuer, p)
    var jwt = verify_as_relying_party(document, token, p, issuer.now())
    var keys = parse_jwk_set(document)
    var thumbprint = False
    for i in range(len(keys.keys)):
        if keys.keys[i].kid().or_else(String("")) == jwt.kid:
            if jwk_thumbprint(keys.keys[i]) == jwt.kid:
                thumbprint = True
    if not thumbprint:
        raise Error("the token's kid is not the RFC 7638 thumbprint of its key")


def _claims[I: IssuerUnderTest](mut issuer: I, p: IssuerProfile) raises:
    var document = issuer.jwks_document()
    var token = _mint(issuer, p)
    var now = issuer.now()
    var jwt = verify_as_relying_party(document, token, p, now)
    if jwt.subject != SCENARIO_SUBJECT:
        raise Error("sub is not the subject the token was minted for")
    var client_id = _string_member(jwt.claims, "client_id")
    if not client_id or client_id.value() != p.client_id:
        raise Error("client_id is not the client the token was minted for")
    var scope = _string_member(jwt.claims, "scope")
    if not scope or scope.value() != SCENARIO_SCOPE:
        raise Error("scope is not the scope the token was minted for")
    if jwt.iat != now:
        raise Error("iat is not the issuer's time")
    var jti = _string_member(jwt.claims, "jti")
    if not jti or jti.value().byte_length() == 0:
        raise Error("jti is not a non-empty string")


def _jti_unique[I: IssuerUnderTest](mut issuer: I, p: IssuerProfile) raises:
    var document = issuer.jwks_document()
    var seen = List[String]()
    for _ in range(SCENARIO_JTI_SAMPLES):
        var token = _mint(issuer, p)
        var jwt = verify_as_relying_party(document, token, p, issuer.now())
        var jti = _string_member(jwt.claims, "jti")
        if not jti or jti.value().byte_length() == 0:
            raise Error("jti is not a non-empty string")
        if _holds(seen, jti.value()):
            raise Error("two tokens carry one jti")
        seen.append(jti.value())


def _subject_required[I: IssuerUnderTest](mut issuer: I, p: IssuerProfile) raises:
    var minted = True
    try:
        _ = issuer.mint_user_token(
            String(""), p.audience, p.client_id, SCENARIO_SCOPE
        )
    except:
        minted = False
    if minted:
        raise Error("a token was minted for an empty subject")


def _publish_before_sign[I: IssuerUnderTest](mut issuer: I, p: IssuerProfile) raises:
    var before = issuer.jwks_document()
    var old_kids = _kids(before)
    issuer.begin_rotation()
    var during = issuer.jwks_document()
    var new_kids = _kids(during)
    var added = List[String]()
    for i in range(len(new_kids)):
        if not _holds(old_kids, new_kids[i]):
            added.append(new_kids[i])
    if len(added) == 0:
        raise Error("starting a rotation published no new key")
    var lead_token = _mint(issuer, p)
    try:
        _ = verify_as_relying_party(before, lead_token, p, issuer.now())
    except e:
        raise Error(
            String("a token signed during the publish lead fails under the")
            + " document from before the rotation: "
            + String(e)
        )
    issuer.advance(p.publish_lead_s)
    issuer.finish_rotation()
    var token = _mint(issuer, p)
    var jwt: VerifiedJwt
    try:
        jwt = verify_as_relying_party(during, token, p, issuer.now())
    except e:
        raise Error(
            String("a token signed after the switch fails under the document")
            + " served when the rotation started: "
            + String(e)
        )
    if not _holds(added, jwt.kid):
        raise Error("after the switch the token is not signed by a new key")


def _in_flight[I: IssuerUnderTest](mut issuer: I, p: IssuerProfile) raises:
    issuer.begin_rotation()
    _ = issuer.jwks_document()
    issuer.advance(p.publish_lead_s)
    var token = _mint(issuer, p)
    var start = issuer.now()
    var jwt = verify_as_relying_party(issuer.jwks_document(), token, p, start)
    issuer.finish_rotation()
    var last = jwt.exp + p.leeway_s - 1
    issuer.advance(last - start)
    try:
        _ = verify_as_relying_party(issuer.jwks_document(), token, p, last)
    except e:
        raise Error(
            String("a token signed at the switch fails under the document")
            + " served at its exp plus the leeway minus 1 s: "
            + String(e)
        )


def run_issuer_scenario[I: IssuerUnderTest](
    mut issuer: I, profile: IssuerProfile, name: String
) -> String:
    """Run scenario `name` on `issuer`: "" when it passes, else the reason
    it failed (or that no scenario has that name)."""
    try:
        if name == SCENARIO_MINT_VERIFIES:
            _mint_verifies(issuer, profile)
        elif name == SCENARIO_CLAIMS:
            _claims(issuer, profile)
        elif name == SCENARIO_JTI_UNIQUE:
            _jti_unique(issuer, profile)
        elif name == SCENARIO_SUBJECT_REQUIRED:
            _subject_required(issuer, profile)
        elif name == SCENARIO_PUBLISH_BEFORE_SIGN:
            _publish_before_sign(issuer, profile)
        elif name == SCENARIO_IN_FLIGHT:
            _in_flight(issuer, profile)
        else:
            return String("no scenario is named ") + name
    except e:
        return String(e)
    return String("")


def run_issuer_scenarios[I: IssuerUnderTest](
    mut issuer: I, profile: IssuerProfile
) -> String:
    """Every scenario in table order on one issuer: one
    `<scenario>: <reason>` line per failure, "" when all pass."""
    var names = issuer_scenarios()
    var report = String("")
    for i in range(len(names)):
        var why = run_issuer_scenario(issuer, profile, names[i])
        if why != "":
            report += names[i] + ": " + why + "\n"
    return report
