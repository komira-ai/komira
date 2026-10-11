# =============================================================================
# test_scenarios.mojo: the scenario table (scenarios.mojo) passes on
#   `TestIssuer`, for ES256 and EdDSA and for both token types.
# =============================================================================
#
# Also pins the table itself (its names, in order), a name the runner does
# not know, and `profile_of`. test_runner.mojo shows that each scenario fails
# an issuer with the defect it names.
#
# main runs every test and reports every failure.
# =============================================================================

from std.testing import assert_equal

from komira_test_issuer import (
    TestIssuer,
    issuer_scenarios,
    profile_of,
    run_issuer_scenario,
    run_issuer_scenarios,
)


comptime T0: Int64 = 1000000
comptime ISS = "https://issuer.example/a"


def _issuer(alg: String, typ: String) raises -> TestIssuer:
    return TestIssuer(
        issuer=ISS,
        alg=alg,
        typ=typ,
        max_ttl_s=300,
        leeway_s=30,
        publish_lead_s=600,
        seed="seed-a",
        now=T0,
    )


def test_table() raises:
    var names = issuer_scenarios()
    var joined = String("")
    for i in range(len(names)):
        joined += names[i] + " "
    assert_equal(
        joined,
        "mint_verifies claims jti_unique subject_required publish_before_sign"
        " in_flight_survives_rotation ",
    )


def test_profile_of() raises:
    var iss = _issuer("EdDSA", "JWT")
    var p = profile_of(iss, "service-a", "client-a")
    assert_equal(p.issuer, ISS)
    assert_equal(p.audience, "service-a")
    assert_equal(p.client_id, "client-a")
    assert_equal(p.alg, "EdDSA")
    assert_equal(p.typ, "JWT")
    assert_equal(p.max_ttl_s, 300)
    assert_equal(p.leeway_s, 30)
    assert_equal(p.publish_lead_s, 600)


def test_table_passes_on_test_issuer() raises:
    # Catches: a scenario that refuses a correct issuer (a check off by one,
    # a policy built from the wrong profile member, a verify at the wrong
    # time).
    var report = String("")
    for a in range(2):
        var alg = String("ES256") if a == 0 else String("EdDSA")
        for t in range(2):
            var typ = String("at+jwt") if t == 0 else String("JWT")
            var iss = _issuer(alg, typ)
            var p = profile_of(iss, "service-a", "client-a")
            var r = run_issuer_scenarios(iss, p)
            if r != "":
                report += alg + " " + typ + ":\n" + r
    assert_equal(report, "")


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


def test_unknown_scenario() raises:
    # Catches: a scenario name compared loosely, so a near miss runs a
    # scenario instead of being reported.
    var iss = _issuer("ES256", "at+jwt")
    var p = profile_of(iss, "service-a", "client-a")
    var names = issuer_scenarios()
    var misses = String("")
    for i in range(len(names)):
        var near = _near_misses(names[i])
        for j in range(len(near)):
            var got = run_issuer_scenario(iss, p, near[j])
            if got != String("no scenario is named ") + near[j]:
                misses += near[j] + " -> " + got + "\n"
    assert_equal(misses, "", "near-miss scenario names that ran")


def main() raises:
    var failures = String("")
    try:
        test_table()
    except e:
        failures += String("test_table: ") + String(e) + "\n"
    try:
        test_profile_of()
    except e:
        failures += String("test_profile_of: ") + String(e) + "\n"
    try:
        test_table_passes_on_test_issuer()
    except e:
        failures += String("test_table_passes_on_test_issuer: ") + String(e) + "\n"
    try:
        test_unknown_scenario()
    except e:
        failures += String("test_unknown_scenario: ") + String(e) + "\n"
    if failures != "":
        print(failures)
        raise Error("test_scenarios failed")
    print("PASS komira_test_issuer test_scenarios")
