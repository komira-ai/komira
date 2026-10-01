# =============================================================================
# kci_bundle/tests/test_test_role.mojo
#   — THE FALSIFIER for `RunContainer.test_role` (app_bundle.proto field 9)
#     at the SCHEMA layer: parse, emit, round trip, and every one of
#     the load-time refusals.
# =============================================================================
#
# WHAT THE FIELD IS. One `test_role { … }` block declares ONE EPHEMERAL KOMIRA
# CALLER IDENTITY that a validate step presents to the app under test: created
# before the step-DAG runs, revoked on both of its exit arms. It exists because
# otherwise nothing can ask *"what does this service do when a correctly-scoped
# CUSTOMER caller presents a token?"* — the only way to have such a caller would
# be to leave a PERSISTENT fake service deployed in a test org, which is a
# standing credential nobody rotates.
#
# ⛔ WHY EVERY REFUSAL BELOW IS WORTH A TEST. Provisioning one MINTS A P-256
# KEYPAIR, WRITES A SECRET VERSION and INSERTS A ROW into Komira's own control
# plane. A rule that silently stops firing does not produce a red build; it
# produces a live identity in a real control plane that nobody meant to create,
# and — because the secret handle is derived from `(app, org)` and AWS
# `DeleteSecret` is a soft delete whose NAME STAYS TAKEN for up to 30 days — one
# that cannot simply be deleted afterwards.
#
#   Z1  ★★ THE ZERO-BEHAVIOUR-CHANGE PROPERTY, PROVEN AND NOT ASSERTED. A step
#       that declares NO role parses to an empty list and re-emits with NO
#       `test_role` token — while the SAME bundle plus one role emits DIFFERENTLY.
#       Both halves are needed: the first alone passes an emitter that drops the
#       field entirely, which is the defect that costs a validator its identity.
#   R1  BYTE-IDENTICAL ROUND TRIP: `emit(parse(emit(parse(x)))) == emit(parse(x))`
#       for a bundle that DOES author roles, plus a field-by-field read-back of
#       all eight values on both roles — a fixpoint alone cannot see an emitter
#       and a parser that agree on the wrong thing (e.g. both dropping field 6).
#   R2  AUTHORED ORDER SURVIVES. The argv render walks this list in order, so a
#       sorting emitter would silently swap which identity lands on which flag.
#   V1  ⛔ TENANCY. A `test_role` on a bundle that is not
#       `TENANCY_CONTROL_PLANE` is refused — including the UNSPECIFIED bundle,
#       which is the one a negated predicate would have let through.
#   V2  duplicate role NAME within a step.
#   V3  duplicate FLAG across the step's roles — any of the five, against any
#       other of the four, including the SAME field on two roles.
#   V4  `grants_on_service` naming a service the bundle does not declare.
#   V5  ⛔ the RESERVED KOMIRA ORG, by value.
#   V5b the reserved org is the CALLER's `reserved_org_id`; empty reserves none.
#   V6  a `test_role` on a step carrying `excluded_because`.
#   V7  `level` left UNSPECIFIED.
#   V8  the three required scalars (`name`, `org_id`, `grants_on_service`).
#   V9  ★ THE POSITIVE CONTROL. A fully-authored, legal pair of roles on a
#       control-plane bundle produces ZERO errors. Without it every refusal above
#       could be passing for an unrelated reason and this file would still be
#       green.
#   P1  THE PARSER REJECTS AN UNKNOWN FIELD inside `test_role {}` and names the
#       block — the diagnostic `test_emit_completeness` probes with.
#
# Pure parse + emit + validate. No cloud, no network, no credentials.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from kci_bundle.parser import parse_bundle
from kci_bundle.emit import emit_bundle
from kci_bundle.validate import validate_bundle


comptime _RESERVED_ORG_ID: String = "00000000-0000-7000-8000-000000000001"

# Two DISTINCT real-shaped org ids. Distinct because the first consumer needs two
# roles in two orgs (the acting org is derived from the caller's OWN row, so a
# cross-tenant assertion cannot be made with one).
comptime _ORG_A: String = "11111111-1111-7111-8111-11111111111a"
comptime _ORG_B: String = "11111111-1111-7111-8111-11111111111b"


def _errs(text: String) raises -> List[String]:
    return validate_bundle(parse_bundle(text))


def _any_contains(errs: List[String], needle: String) -> Bool:
    for ref e in errs:
        if e.find(needle) >= 0:
            return True
    return False


def _why(errs: List[String]) -> String:
    """Every error, joined — so a failing assertion below prints what the
    validator ACTUALLY said instead of only that it did not say the expected
    thing."""
    var out = String("")
    for ref e in errs:
        out += String("\n    - ") + e
    if out.byte_length() == 0:
        return String(" (the validator reported NO errors at all)")
    return out^


# =============================================================================
# THE FIXTURE. A control-plane bundle with ONE `run_container` validate step,
# parameterised on the tenancy line, the step's extra lines, and the step's
# `test_role` blocks — so every case below differs from the legal one in exactly
# ONE way, which is what makes a refusal attributable.
# =============================================================================
def _bundle(
    roles: String,
    tenancy: String = String("tenancy: TENANCY_CONTROL_PLANE\n"),
    step_extra: String = String(""),
) -> String:
    return (
        String("kind: APP_KIND_API\n")
        + String('name: "relay"\n')
        + tenancy
        + String('build { name: "service" dockerfile: "Dockerfile" }\n')
        + String('build { name: "integ" dockerfile: "Dockerfile.integ" }\n')
        + String('spec { image { from_build: "service" } port: 8080 }\n')
        + String("waves {\n")
        + String('  env: "gamma"\n')
        + String("  validate {\n")
        + String('    name: "relay-entitlement"\n')
        + step_extra
        + String("    run_container {\n")
        + String('      image { from_build: "integ" }\n')
        + String("      gate_on: GATE_ON_EXIT_CODE\n")
        + roles
        + String("    }\n")
        + String("  }\n")
        + String("}\n")
    )


def _role(
    name: String,
    org: String,
    service: String = String("relay"),
    level: String = String("TEST_ROLE_LEVEL_READ"),
    dep_flag: String = String(""),
    sec_flag: String = String(""),
    org_flag: String = String(""),
    iss_flag: String = String(""),
    # ★ `granted_on_flag` (field 9). DEFAULTED EMPTY so every case authored
    # before it keeps its exact document.
    tgt_flag: String = String(""),
) -> String:
    """One `test_role { … }` block. EMPTY string arguments OMIT their line, which
    is how the required-field and UNSPECIFIED-level cases are stated: the field is
    absent from the document, not present-and-empty."""
    var out = String("      test_role {\n")
    if name.byte_length() > 0:
        out += String('        name: "') + name + String('"\n')
    if org.byte_length() > 0:
        out += String('        org_id: "') + org + String('"\n')
    if service.byte_length() > 0:
        out += (
            String('        grants_on_service: "') + service + String('"\n')
        )
    if level.byte_length() > 0:
        out += String("        level: ") + level + String("\n")
    if dep_flag.byte_length() > 0:
        out += (
            String('        deployment_id_flag: "') + dep_flag + String('"\n')
        )
    if sec_flag.byte_length() > 0:
        out += (
            String('        identity_secret_flag: "')
            + sec_flag
            + String('"\n')
        )
    if org_flag.byte_length() > 0:
        out += String('        org_id_flag: "') + org_flag + String('"\n')
    if iss_flag.byte_length() > 0:
        out += String('        issuer_flag: "') + iss_flag + String('"\n')
    if tgt_flag.byte_length() > 0:
        out += (
            String('        granted_on_flag: "') + tgt_flag + String('"\n')
        )
    out += String("      }\n")
    return out^


def _legal_pair() -> String:
    """The shape the first real consumer needs: two callers, two orgs, disjoint
    flags."""
    return _role(
        String("caller-a"),
        String(_ORG_A),
        level=String("TEST_ROLE_LEVEL_READ"),
        dep_flag=String("caller-a-deployment"),
        sec_flag=String("caller-a-secret"),
        org_flag=String("caller-a-org"),
        iss_flag=String("caller-a-issuer"),
    ) + _role(
        String("caller-b"),
        String(_ORG_B),
        level=String("TEST_ROLE_LEVEL_WRITE"),
        dep_flag=String("caller-b-deployment"),
        sec_flag=String("caller-b-secret"),
        org_flag=String("caller-b-org"),
        iss_flag=String("caller-b-issuer"),
    )


def _the_step_roles(b: String) raises -> List[String]:
    """The parsed step's role NAMES, in parsed order."""
    var parsed = parse_bundle(b)
    var out = List[String]()
    ref rc = parsed.waves[0].validate[0].run_container.value()
    for ref r in rc.test_role:
        out.append(String(r.name))
    return out^


# =============================================================================
# Z1 — ★★ THE ZERO-BEHAVIOUR-CHANGE PROPERTY, BOTH HALVES.
# =============================================================================
def test_z1_a_step_with_no_role_is_byte_identical_and_one_with_a_role_is_not(
) raises:
    """A step declaring NO `test_role` parses to an EMPTY list and re-emits with
    no `test_role` token anywhere — the property every bundle that authors no
    role relies on.

    ⛔ AND THE SECOND HALF IS WHAT MAKES THE FIRST MEAN ANYTHING. An emitter that
    simply never writes the field satisfies "no token appears" perfectly, and it
    is the WORSE defect: the deploy silently drops an identity the author
    declared, a writer that splices the emitted bytes back over the source
    removes the declaration from disk. So the same bundle PLUS one
    role must emit DIFFERENTLY."""
    var without = _bundle(String(""))
    var with_one = _bundle(
        _role(
            String("caller-a"),
            String(_ORG_A),
            dep_flag=String("caller-a-deployment"),
        )
    )

    var parsed_without = parse_bundle(without)
    assert_equal(
        len(parsed_without.waves[0].validate[0].run_container.value().test_role),
        0,
        "a step that authors no test_role parses to an EMPTY repeated field",
    )

    var emitted_without = emit_bundle(parsed_without)
    assert_true(
        emitted_without.find(String("test_role")) < 0,
        (
            "an unauthored `test_role` must emit NOTHING — not an empty block,"
            " not the bare key. Most bundles author none, so an"
            " emitter that wrote one would change the bytes of every one of them"
            " AND make every one of them refuse validation for a block no author"
            " can find in their own file"
        ),
    )

    var emitted_with = emit_bundle(parse_bundle(with_one))
    assert_true(
        emitted_with.find(String("test_role {")) >= 0,
        (
            "an AUTHORED role must survive to the emitted form. An emitter that"
            " drops it silently deletes the identity the step's whole assertion"
            " is about, and a write-back then puts the loss on disk"
        ),
    )
    assert_true(
        emitted_with != emitted_without,
        (
            "the field must be OBSERVABLE in the emitted form — if the two"
            " documents are equal, `test_role` is carried by nothing and the"
            " first assertion above is vacuous"
        ),
    )
    print("  test_z1_zero_behavior_change: PASS")


# =============================================================================
# R1 — the byte-identical round trip, plus the field-by-field read-back.
# =============================================================================
def test_r1_round_trip_is_a_fixpoint_and_carries_all_eight_fields() raises:
    var src = _bundle(_legal_pair())
    var once = emit_bundle(parse_bundle(src))
    var twice = emit_bundle(parse_bundle(once))
    assert_equal(
        once,
        twice,
        (
            "emit(parse(emit(parse(x)))) == emit(parse(x)) — the emitted form is"
            " a FIXPOINT. This is what catches an emitter writing something this"
            " parser reads back differently"
        ),
    )

    # ⚠ THE FIXPOINT ALONE IS NOT ENOUGH, and this is why the read-back is here:
    # an emitter that drops `identity_secret_flag` and a parser that never looked
    # for it agree perfectly and are a stable fixpoint. The values have to be
    # named.
    var parsed = parse_bundle(once)
    ref rc = parsed.waves[0].validate[0].run_container.value()
    assert_equal(len(rc.test_role), 2, "both roles survive the round trip")

    ref a = rc.test_role[0]
    assert_equal(a.name, String("caller-a"), "role a: name")
    assert_equal(a.org_id, String(_ORG_A), "role a: org_id")
    assert_equal(a.grants_on_service, String("relay"), "role a: grants_on_service")
    assert_equal(
        a.level.json_name(),
        String("TEST_ROLE_LEVEL_READ"),
        "role a: level survives as the AUTHORED value, not the zero default",
    )
    assert_equal(
        a.deployment_id_flag,
        String("caller-a-deployment"),
        "role a: deployment_id_flag",
    )
    assert_equal(
        a.identity_secret_flag,
        String("caller-a-secret"),
        (
            "role a: identity_secret_flag. Losing THIS one means the validator is"
            " never handed the address of its own signing key and self-mints"
            " nothing — behind a green deploy"
        ),
    )
    assert_equal(a.org_id_flag, String("caller-a-org"), "role a: org_id_flag")
    assert_equal(
        a.issuer_flag, String("caller-a-issuer"), "role a: issuer_flag"
    )

    ref b = rc.test_role[1]
    assert_equal(b.name, String("caller-b"), "role b: name")
    assert_equal(b.org_id, String(_ORG_B), "role b: org_id")
    assert_equal(
        b.level.json_name(),
        String("TEST_ROLE_LEVEL_WRITE"),
        (
            "role b: level. The two roles carry DIFFERENT levels on purpose — an"
            " emitter that wrote role a's block twice passes every assertion"
            " above and fails this one"
        ),
    )
    assert_equal(
        b.identity_secret_flag,
        String("caller-b-secret"),
        "role b: identity_secret_flag",
    )
    print("  test_r1_round_trip: PASS")


# =============================================================================
# R2 — AUTHORED ORDER. The argv render walks the list in order.
# =============================================================================
def test_r2_authored_order_survives_the_round_trip() raises:
    """Roles authored b-then-a must read back b-then-a. `_emit_test_role`'s
    caller must not sort: the render walks this list in order, so a sorting
    emitter silently swaps WHICH IDENTITY lands on which flag — and both roles
    still exist, so nothing else in this file would notice."""
    var reversed_pair = _role(
        String("zeta"),
        String(_ORG_A),
        dep_flag=String("zeta-deployment"),
    ) + _role(
        String("alpha"),
        String(_ORG_B),
        dep_flag=String("alpha-deployment"),
    )
    var names = _the_step_roles(_bundle(reversed_pair))
    assert_equal(len(names), 2, "two roles parsed")
    assert_equal(names[0], String("zeta"), "the FIRST authored role is first")
    assert_equal(names[1], String("alpha"), "the SECOND authored role is second")

    var round_tripped = _the_step_roles(
        emit_bundle(parse_bundle(_bundle(reversed_pair)))
    )
    assert_equal(
        round_tripped[0],
        String("zeta"),
        (
            "order survives EMIT too. Authored 'zeta' then 'alpha' — an emitter"
            " that sorted would put 'alpha' first, and every other assertion in"
            " this file would still pass"
        ),
    )
    print("  test_r2_authored_order: PASS")


# =============================================================================
# V9 — ★ THE POSITIVE CONTROL. It comes first because every refusal below is
#      only meaningful against it.
# =============================================================================
def test_v9_a_legal_pair_on_a_control_plane_bundle_validates_clean() raises:
    var errs = _errs(_bundle(_legal_pair()))
    assert_equal(
        len(errs),
        0,
        (
            "a fully-authored, legal pair of test roles on a"
            " TENANCY_CONTROL_PLANE bundle must produce ZERO errors. Without"
            " this control, every refusal below could be firing for an unrelated"
            " reason and this file would still be green."
            + _why(errs)
        ),
    )
    print("  test_v9_positive_control: PASS")


# =============================================================================
# V1 — ⛔ TENANCY, and the UNSPECIFIED arm is the point.
# =============================================================================
def test_v1_a_non_control_plane_bundle_may_not_declare_a_test_role() raises:
    var customer = _errs(
        _bundle(_legal_pair(), tenancy=String("tenancy: TENANCY_CUSTOMER\n"))
    )
    assert_true(
        _any_contains(
            customer, String("not `tenancy: TENANCY_CONTROL_PLANE`")
        ),
        (
            "a TENANCY_CUSTOMER bundle is refused. Its deploy publishes its image"
            " and CREATES NOTHING, so the identity would belong to no workload"
            " at all — and it would be minted in KOMIRA's control plane on behalf"
            " of a bundle that declares it runs in someone else's account."
            + _why(customer)
        ),
    )

    # ⛔ THE ARM A NEGATED PREDICATE WOULD LET THROUGH. `Tenancy` has THREE
    # members and UNSPECIFIED is the proto3 zero — the value a bundle that
    # authored no `tenancy:` line carries. Written as `not is_customer`, THIS
    # bundle would be treated as Komira's own and allowed to mint. It is the only
    # case here that distinguishes the positive test from the negated one.
    var undeclared = _errs(_bundle(_legal_pair(), tenancy=String("")))
    assert_true(
        _any_contains(
            undeclared, String("not `tenancy: TENANCY_CONTROL_PLANE`")
        ),
        (
            "a bundle that authored NO tenancy is refused too. This is the arm a"
            " `not deploy_publishes_only(...)` spelling silently admits, and the"
            " customer case above cannot see it"
            + _why(undeclared)
        ),
    )
    print("  test_v1_tenancy: PASS")


# =============================================================================
# V2 — duplicate role NAME within a step.
# =============================================================================
def test_v2_duplicate_role_name_is_refused() raises:
    var dup = _role(
        String("caller"), String(_ORG_A), dep_flag=String("a-deployment")
    ) + _role(String("caller"), String(_ORG_B), dep_flag=String("b-deployment"))
    var errs = _errs(_bundle(dup))
    assert_true(
        _any_contains(errs, String("duplicate 'test_role' name")),
        (
            "two roles named alike key ONE `app_deployment` row, so the second"
            " ADOPTS the first and the step presents a single caller under two"
            " names — a cross-tenant assertion built on that passes for a reason"
            " unrelated to its claim"
            + _why(errs)
        ),
    )
    print("  test_v2_duplicate_name: PASS")


# =============================================================================
# V3 — duplicate FLAG across roles. Three arms: the SAME field on two roles, a
#      DIFFERENT field on two roles, and two fields on the SAME role.
# =============================================================================
def test_v3_duplicate_flag_is_refused_across_fields_and_across_roles() raises:
    var same_field = _role(
        String("a"), String(_ORG_A), dep_flag=String("shared")
    ) + _role(String("b"), String(_ORG_B), dep_flag=String("shared"))
    var e1 = _errs(_bundle(same_field))
    assert_true(
        _any_contains(e1, String("already claimed by")),
        (
            "the SAME flag field on two roles collides. Two values rendering onto"
            " one flag means the container silently takes ONE, and what is"
            " dropped is WHICH IDENTITY the validator presents"
            + _why(e1)
        ),
    )

    # ⚠ THE CROSS-FIELD ARM. A check that only compared like fields (every
    # `deployment_id_flag` against every other) would pass this — and it is a
    # realistic authoring slip, since all four flags are free-form strings.
    var cross_field = _role(
        String("a"), String(_ORG_A), dep_flag=String("shared")
    ) + _role(String("b"), String(_ORG_B), org_flag=String("shared"))
    var e2 = _errs(_bundle(cross_field))
    assert_true(
        _any_contains(e2, String("already claimed by")),
        (
            "one role's `deployment_id_flag` collides with another role's"
            " `org_id_flag`. A per-field duplicate check passes this and is"
            " wrong: the collision is on the FLAG, not on the field name"
            + _why(e2)
        ),
    )

    # And within ONE role — two of its own four values aimed at one flag.
    var same_role = _role(
        String("a"),
        String(_ORG_A),
        dep_flag=String("shared"),
        org_flag=String("shared"),
    )
    var e3 = _errs(_bundle(same_role))
    assert_true(
        _any_contains(e3, String("already claimed by")),
        (
            "one role's own two values may not aim at one flag either"
            + _why(e3)
        ),
    )
    # ★ THE FOURTH ARM — `granted_on_flag` JOINS THE SAME NAMESPACE.
    #
    # ⛔ THIS IS NOT "one more of the same" AND IT IS THE CASE MOST LIKELY TO BE
    # AUTHORED. Two roles that share a target both WANT to render it, and the
    # obvious authoring is to write the flag on both — at which point the
    # container silently takes one and the step still runs. It is refused for the
    # identical reason as the other four, and this arm is what proves the new
    # field was added to the CHECK and not only to the parser and the emitter: a
    # field wired through parse/emit/render but absent from `_check_test_role_flag`
    # passes every other test in this file.
    var dup_target = _role(
        String("a"), String(_ORG_A), tgt_flag=String("relay-audience")
    ) + _role(String("b"), String(_ORG_B), tgt_flag=String("relay-audience"))
    var e4 = _errs(_bundle(dup_target))
    assert_true(
        _any_contains(e4, String("already claimed by")),
        (
            "two roles may not both claim the TARGET flag. Roles sharing a target"
            " author it ONCE — the shape `issuer_flag` already has"
            + _why(e4)
        ),
    )
    assert_true(
        _any_contains(e4, String("granted_on_flag")),
        (
            "and the refusal NAMES the new field, not a sibling. A message that"
            " named `issuer_flag` here would send the author to the wrong line"
            + _why(e4)
        ),
    )
    print("  test_v3_duplicate_flag: PASS")


# =============================================================================
# V4 — `grants_on_service` must resolve.
# =============================================================================
def test_v4_grants_on_service_must_name_a_declared_service() raises:
    var errs = _errs(
        _bundle(
            _role(
                String("caller"),
                String(_ORG_A),
                service=String("no-such-service"),
                dep_flag=String("d"),
            )
        )
    )
    assert_true(
        _any_contains(
            errs, String("'grants_on_service' names 'no-such-service'")
        ),
        (
            "a grant whose resource does not exist is a row nothing reads, so"
            " the step asserts an entitlement it never held and the DENY reads as"
            " an application defect"
            + _why(errs)
        ),
    )
    print("  test_v4_grants_on_service: PASS")


# =============================================================================
# V5 — ⛔ THE RESERVED KOMIRA ORG.
# =============================================================================
def test_v5_the_reserved_komira_org_is_refused() raises:
    var errs = _errs(
        _bundle(
            _role(
                String("caller"),
                String(_RESERVED_ORG_ID),
                dep_flag=String("d"),
            )
        )
    )
    assert_true(
        _any_contains(errs, String("THE RESERVED KOMIRA ORG")),
        (
            "a test role exists to present a CUSTOMER caller; provisioning one"
            " into Komira's own tenancy COLLAPSES the tenancy axis, so every"
            " cross-tenant row the step asserts becomes vacuous while still"
            " reporting PASS"
            + _why(errs)
        ),
    )

    # The CONTROL: a different, real-shaped org is accepted. Without it this
    # test would also pass against a validator that refused every org.
    var ok = _errs(
        _bundle(
            _role(String("caller"), String(_ORG_A), dep_flag=String("d"))
        )
    )
    assert_false(
        _any_contains(ok, String("THE RESERVED KOMIRA ORG")),
        "an ordinary org is NOT refused — the refusal is by VALUE, not blanket",
    )
    print("  test_v5_reserved_org: PASS")


def test_v5b_the_reserved_org_is_the_callers() raises:
    """The reserved org is the CALLER's: `validate_bundle(reserved_org_id=...)`
    refuses the id it is given and no other, and an empty id refuses none."""
    var at_b = _bundle(
        _role(String("caller"), String(_ORG_B), dep_flag=String("d"))
    )
    var errs = validate_bundle(parse_bundle(at_b), reserved_org_id=String(_ORG_B))
    assert_true(
        _any_contains(errs, String("THE RESERVED KOMIRA ORG (") + String(_ORG_B)),
        "a caller-supplied reserved org is refused by value" + _why(errs),
    )
    var at_default = _bundle(
        _role(String("caller"), String(_RESERVED_ORG_ID), dep_flag=String("d"))
    )
    var moved = validate_bundle(
        parse_bundle(at_default), reserved_org_id=String(_ORG_B)
    )
    assert_false(
        _any_contains(moved, String("THE RESERVED KOMIRA ORG")),
        "with another id supplied, the default id is an ordinary org" + _why(moved),
    )
    var none = validate_bundle(parse_bundle(at_default), reserved_org_id=String(""))
    assert_false(
        _any_contains(none, String("THE RESERVED KOMIRA ORG")),
        "an empty reserved_org_id means no org is reserved" + _why(none),
    )
    print("  test_v5b_reserved_org_is_the_callers: PASS")


# =============================================================================
# V6 — an EXCLUDED step may not declare a role.
# =============================================================================
def test_v6_an_excluded_step_may_not_declare_a_test_role() raises:
    var errs = _errs(
        _bundle(
            _role(String("caller"), String(_ORG_A), dep_flag=String("d")),
            step_extra=String(
                '    excluded_because: "the integ image is not built yet"\n'
            ),
        )
    )
    assert_true(
        _any_contains(errs, String("on a step that is EXCLUDED")),
        (
            "an excluded step places no job, so the role would be provisioned — a"
            " real key, a real row, a real grant — and then presented to nothing."
            " The same rule the secret and telemetry grant nodes already follow"
            " ('places no job, buys no grant'), and sharper: those waste a grant,"
            " this mints an identity"
            + _why(errs)
        ),
    )
    print("  test_v6_excluded_step: PASS")


# =============================================================================
# V7 — `level` UNSPECIFIED is refused, not defaulted.
# =============================================================================
def test_v7_an_unspecified_level_is_refused() raises:
    # The field OMITTED entirely — the proto3 zero.
    var omitted = _errs(
        _bundle(
            _role(
                String("caller"),
                String(_ORG_A),
                level=String(""),
                dep_flag=String("d"),
            )
        )
    )
    assert_true(
        _any_contains(omitted, String("TEST_ROLE_LEVEL_UNSPECIFIED")),
        (
            "an omitted `level` is the proto3 zero and is REFUSED. Reading it as"
            " READ would make 'the author said nothing' and 'the author asked for"
            " READ' the same bytes — the absent-vs-empty confusion this enum was"
            " given its own UNSPECIFIED member to end"
            + _why(omitted)
        ),
    )

    # ...and the same value written OUT LOUD, which must behave identically.
    var explicit = _errs(
        _bundle(
            _role(
                String("caller"),
                String(_ORG_A),
                level=String("TEST_ROLE_LEVEL_UNSPECIFIED"),
                dep_flag=String("d"),
            )
        )
    )
    assert_true(
        _any_contains(explicit, String("TEST_ROLE_LEVEL_UNSPECIFIED")),
        (
            "the explicitly-authored UNSPECIFIED is refused too — a check keyed"
            " on 'the line is absent' rather than on the VALUE would miss it"
            + _why(explicit)
        ),
    )
    print("  test_v7_unspecified_level: PASS")


# =============================================================================
# V8 — the three required scalars.
# =============================================================================
def test_v8_name_org_and_service_are_required() raises:
    var no_name = _errs(
        _bundle(
            _role(String(""), String(_ORG_A), dep_flag=String("d"))
        )
    )
    assert_true(
        _any_contains(no_name, String("'name' is required")),
        "a role with no name" + _why(no_name),
    )

    var no_org = _errs(
        _bundle(_role(String("caller"), String(""), dep_flag=String("d")))
    )
    assert_true(
        _any_contains(no_org, String("'org_id' is required")),
        (
            "a role with no org would be provisioned into whatever `--org-id` the"
            " deploy was invoked with — the operator's org, and the subject of no"
            " test"
            + _why(no_org)
        ),
    )

    var no_service = _errs(
        _bundle(
            _role(
                String("caller"),
                String(_ORG_A),
                service=String(""),
                dep_flag=String("d"),
            )
        )
    )
    assert_true(
        _any_contains(no_service, String("'grants_on_service' is required")),
        "a role with no target service" + _why(no_service),
    )
    print("  test_v8_required_scalars: PASS")


# =============================================================================
# P1 — the parser names the block on an unknown field.
# =============================================================================
def test_p1_an_unknown_field_inside_test_role_is_rejected() raises:
    var raised = False
    var msg = String("")
    try:
        _ = parse_bundle(
            _bundle(
                String("      test_role {\n")
                + String('        nmae: "typo"\n')
                + String("      }\n")
            )
        )
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, "an unknown field inside `test_role {}` is a parse error")
    assert_true(
        msg.find(String("TestRole")) >= 0,
        (
            "the diagnostic names the BLOCK. `test_emit_completeness` probes the"
            " parser's legal field set out of exactly this message at run time,"
            " so a diagnostic that named the wrong message would take that gate"
            " with it. Got: "
            + msg
        ),
    )
    print("  test_p1_unknown_field: PASS")


def main() raises:
    test_z1_a_step_with_no_role_is_byte_identical_and_one_with_a_role_is_not()
    test_r1_round_trip_is_a_fixpoint_and_carries_all_eight_fields()
    test_r2_authored_order_survives_the_round_trip()
    test_v9_a_legal_pair_on_a_control_plane_bundle_validates_clean()
    test_v1_a_non_control_plane_bundle_may_not_declare_a_test_role()
    test_v2_duplicate_role_name_is_refused()
    test_v3_duplicate_flag_is_refused_across_fields_and_across_roles()
    test_v4_grants_on_service_must_name_a_declared_service()
    test_v5_the_reserved_komira_org_is_refused()
    test_v5b_the_reserved_org_is_the_callers()
    test_v6_an_excluded_step_may_not_declare_a_test_role()
    test_v7_an_unspecified_level_is_refused()
    test_v8_name_org_and_service_are_required()
    test_p1_an_unknown_field_inside_test_role_is_rejected()
    print("test_test_role: ALL PASS")
