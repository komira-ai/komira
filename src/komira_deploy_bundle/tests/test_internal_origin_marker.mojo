# =============================================================================
# komira_deploy_bundle/tests/test_internal_origin_marker.mojo
#   — `VALUE_FROM_INTERNAL_ORIGIN_URL` is DIAGNOSTIC-ONLY, and the schema is what
#     says so.
# =============================================================================
#
# `VALUE_FROM_DEPLOY_URL` denotes the GATEWAY endpoint. That leaves the
# `.run.app` ORIGIN with no name — but a service may deliberately run a direct
# validation step and a gateway validation step as a PAIR precisely so that *"a
# direct-path failure should surface as the DIRECT row, never masked behind the
# edge hop"*. Without a name for the origin the pair collapses into one endpoint
# tested twice.
#
# So the origin gets a name. And the moment it has one, it is a documented way to
# route traffic AROUND the gateway — where auth, quota, the ApiConfig's declared
# surface and the scoped invoker grant all live. A service handed an origin URL
# does not fail; it succeeds, past all four, invisibly.
#
# ⇒ THE ARM IS LEGAL ON A VALIDATE STEP AND REFUSED EVERYWHERE ELSE, and this
#   file is the falsifier of both halves. The five refusal sites are the five
#   places a resolved value reaches a workload that serves or does real work:
#   `spec.env`, `spec.parameters`, `jobs.env`, `waves.env_override`,
#   `waves.parameter_override`.
#
# ⚠ THE POSITIVE CONTROLS ARE NOT DECORATION. A blanket "refuse this token
#   anywhere but a validate step" is trivially satisfiable by refusing the token
#   everywhere, and equally by refusing EVERY `value_from` on a service. Both
#   would pass a refusal-only suite and both are wrong: a service authoring
#   `VALUE_FROM_DEPLOY_URL` / `VALUE_FROM_ENV_PROJECT` is the normal shape and
#   bundles depend on it. The controls pin that the rule keys on the ARM AND the
#   CONTEXT, which is the only thing that makes it safe to land.
#
# Encapsulation: pure parse + validate + list asserts. Mojo 1.0.0b2.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_deploy_bundle.parser import parse_bundle
from komira_deploy_bundle.validate import validate_bundle


def _errs(text: String) raises -> List[String]:
    return validate_bundle(parse_bundle(text))


def _any_contains(errs: List[String], needle: String) -> Bool:
    for ref e in errs:
        if e.find(needle) >= 0:
            return True
    return False


def _render(errs: List[String]) -> String:
    """The whole error list, for an assert message that says WHAT went wrong
    rather than only that something did."""
    var out = String("")
    for ref e in errs:
        out += String("\n    - ") + e
    if out.byte_length() == 0:
        return String(" (the error list was EMPTY)")
    return out


# The refusal's stable substring. Asserted rather than the whole sentence so a
# wording improvement does not red the suite, but specific enough that a
# DIFFERENT refusal (a missing field, a bad enum) cannot satisfy it.
comptime _REFUSAL: String = "VALUE_FROM_INTERNAL_ORIGIN_URL"
comptime _REFUSAL_REASON: String = "past the gateway"


def _bundle(spec_extra: String, wave_extra: String, tail: String) -> String:
    """A minimal, otherwise-VALID API bundle. Every case below differs from every
    other ONLY in where the marker is authored, so a refusal cannot be coming
    from an unrelated defect in the fixture."""
    var out = String(
        "kind: APP_KIND_API\n"
        "tenancy: TENANCY_CONTROL_PLANE\n"
        'name: "orders-api"\n'
        'build { name: "service" dockerfile: "Dockerfile" }\n'
        'build { name: "probe" dockerfile: "Dockerfile.probe" }\n'
        'spec { image { from_build: "service" } port: 8080\n'
    )
    out += spec_extra
    out += String("}\n")
    out += tail
    out += String('waves { env: "gamma"\n')
    out += wave_extra
    out += String("}\n")
    return out^


# ── the marker, authored in each of the six places it can be spelled ──────────
comptime _ORIGIN_ENV: String = (
    '  env { name: "TARGET_URL" value_from: VALUE_FROM_INTERNAL_ORIGIN_URL }\n'
)
comptime _ORIGIN_PARAM: String = (
    "  parameters { name: \"TARGET_URL\" type: PARAM_TYPE_STRING"
    " value_from: VALUE_FROM_INTERNAL_ORIGIN_URL }\n"
)
comptime _ORIGIN_ENV_OVERRIDE: String = (
    "  env_override { name: \"TARGET_URL\""
    " value_from: VALUE_FROM_INTERNAL_ORIGIN_URL }\n"
)
comptime _ORIGIN_PARAM_OVERRIDE: String = (
    "  parameter_override { name: \"TARGET_URL\" type: PARAM_TYPE_STRING"
    " value_from: VALUE_FROM_INTERNAL_ORIGIN_URL }\n"
)
comptime _ORIGIN_JOB: String = (
    'jobs { name: "backfill" image { from_build: "probe" }\n'
    '  env { name: "TARGET_URL" value_from: VALUE_FROM_INTERNAL_ORIGIN_URL }\n'
    "}\n"
)


def _validate_step(env_line: String, arg_line: String) -> String:
    var out = String(
        '  validate { name: "api-e2e"\n'
        '    run_container { image { from_build: "probe" }'
        " gate_on: GATE_ON_EXIT_CODE\n"
    )
    out += env_line
    out += arg_line
    out += String("    }\n  }\n")
    return out^


# ═══════════════════════════════════════════════════════════════════════════
#  THE ALLOWED HALF — a DIAGNOSTIC validate step
# ═══════════════════════════════════════════════════════════════════════════


def test_a_validate_step_env_may_source_the_internal_origin() raises:
    """FAILS BEFORE THE ARM EXISTS: `VALUE_FROM_INTERNAL_ORIGIN_URL` is not in
    `parser.value_from_values()`, so `_read_enum_value` REFUSES the token at
    parse and `parse_bundle` RAISES — this test does not reach its assert.

    This is the arm's whole purpose: the step that must keep dialling the origin
    after DEPLOY_URL is re-pointed at the gateway."""
    var errs = _errs(
        _bundle(
            String(""),
            _validate_step(
                String('      env { name: "ORDERS_API_E2E_TARGET_URL"')
                + String(" value_from: VALUE_FROM_INTERNAL_ORIGIN_URL }\n"),
                String(""),
            ),
            String(""),
        )
    )
    assert_equal(
        len(errs),
        0,
        String(
            "a DIAGNOSTIC validate step must be allowed to name the internal"
            " origin — it is the only thing that keeps `api-e2e` a DIRECT-path"
            " test once DEPLOY_URL means the gateway. Errors:"
        )
        + _render(errs),
    )
    print("  test_a_validate_step_env_may_source_the_internal_origin: PASS")


def test_a_validate_step_arg_may_source_the_internal_origin() raises:
    """The SAME permission on the ARGV channel. Both channels or neither: a rule
    that governed `env` and not `args` would be bypassed by moving one line, and
    `--target-url` is the AUTHORITATIVE channel in every CP validator — so argv
    is the MORE dangerous of the two to leave ungoverned, not the less."""
    var errs = _errs(
        _bundle(
            String(""),
            _validate_step(
                String(""),
                String('      args { name: "TARGET_URL" type: PARAM_TYPE_STRING')
                + String(" value_from: VALUE_FROM_INTERNAL_ORIGIN_URL }\n"),
            ),
            String(""),
        )
    )
    assert_equal(
        len(errs),
        0,
        String("a validate step's ARGV may name the internal origin. Errors:")
        + _render(errs),
    )
    print("  test_a_validate_step_arg_may_source_the_internal_origin: PASS")


# ═══════════════════════════════════════════════════════════════════════════
#  THE REFUSED HALF — the five places a resolved value reaches a real workload
# ═══════════════════════════════════════════════════════════════════════════


def _assert_refused(errs: List[String], where: String) raises:
    assert_true(
        _any_contains(errs, _REFUSAL),
        String("the internal-origin marker on ")
        + where
        + String(
            " must be REFUSED by name — an origin URL reaching a workload"
            " routes production traffic around the gateway's auth, quota,"
            " declared surface and scoped invoker grant, and it does so"
            " INVISIBLY (the request succeeds). Errors:"
        )
        + _render(errs),
    )
    # The refusal must say WHY, not merely that. "Illegal here" sends the author
    # hunting for a syntax error; the consequence sends them to the right fix.
    assert_true(
        _any_contains(errs, _REFUSAL_REASON),
        String("the refusal on ")
        + where
        + String(" must state the CONSEQUENCE, not just the rule. Errors:")
        + _render(errs),
    )
    # And it must name the KEY. A bundle carries dozens of envs; "one of them is
    # wrong" is not an actionable message.
    assert_true(
        _any_contains(errs, String("TARGET_URL")),
        String("the refusal on ") + where + String(" must name the offending key"),
    )


def test_the_served_spec_may_not_source_the_internal_origin() raises:
    """⛔ THE ONE THAT MATTERS MOST. `spec.env` is the RUNNING SERVICE's
    environment: a resolved value here is read by production request handling,
    for the life of the revision, by every replica.

    FAILS BEFORE THE GUARD: `_check_env` handles arm 0 (no arm set) and an
    UNSPECIFIED `value_from`, and passes every KNOWN `value_from` through
    unremarked — correctly, because `VALUE_FROM_DEPLOY_URL` on `spec.env` is the
    normal shape. So this bundle produced ZERO errors and would have deployed a
    service configured to talk to itself past its own front door."""
    _assert_refused(
        _errs(_bundle(_ORIGIN_ENV, String(""), String(""))),
        String("the SERVED spec's env"),
    )
    print("  test_the_served_spec_may_not_source_the_internal_origin: PASS")


def test_a_spec_parameter_may_not_source_the_internal_origin() raises:
    """`spec.parameters` is the same reach one channel over — it renders onto the
    service container's ARGV. Governing `env` alone would leave a one-line move
    as the bypass."""
    _assert_refused(
        _errs(_bundle(_ORIGIN_PARAM, String(""), String(""))),
        String("the SERVED spec's parameters"),
    )
    print("  test_a_spec_parameter_may_not_source_the_internal_origin: PASS")


def test_a_job_may_not_source_the_internal_origin() raises:
    """A `jobs {}` container is not a diagnostic: it ships an image into a project
    under an identity with secrets bound to it and DOES REAL WORK (a backfill, a
    bootstrap). That it exits afterwards changes the LIFETIME of the workload,
    not its nature — so it is governed exactly like a service."""
    _assert_refused(
        _errs(_bundle(String(""), String(""), _ORIGIN_JOB)),
        String("a run-to-completion JOB's env"),
    )
    print("  test_a_job_may_not_source_the_internal_origin: PASS")


def test_a_wave_env_override_may_not_source_the_internal_origin() raises:
    """`waves.env_override` overrides the SERVICE's spec-level env for one env.
    It is the per-ENV form of the same reach, and it is the shape an author would
    naturally try after the spec-level refusal — 'fine, I will do it per-wave'.
    A rule that stops the general form and not the per-env one stops nobody."""
    _assert_refused(
        _errs(_bundle(String(""), _ORIGIN_ENV_OVERRIDE, String(""))),
        String("a wave's env_override"),
    )
    print("  test_a_wave_env_override_may_not_source_the_internal_origin: PASS")


def test_a_wave_parameter_override_may_not_source_the_internal_origin() raises:
    """The fourth corner of the same 2x2 (env|argv) x (spec|per-wave)."""
    _assert_refused(
        _errs(_bundle(String(""), _ORIGIN_PARAM_OVERRIDE, String(""))),
        String("a wave's parameter_override"),
    )
    print("  test_a_wave_parameter_override_may_not_source_the_internal_origin: PASS")


# ═══════════════════════════════════════════════════════════════════════════
#  THE POSITIVE CONTROLS — the rule keys on the ARM, not on the CONTEXT alone
# ═══════════════════════════════════════════════════════════════════════════


def test_a_service_may_still_source_the_deploy_url() raises:
    """★ THE CONTROL THAT MAKES THE REFUSAL SAFE TO LAND, AND THE ONE A LAZY
    IMPLEMENTATION FAILS.

    'Refuse a `value_from` on a service' passes every refusal test above and
    breaks every service that sources its own deploy URL. The
    difference this pins is that the guard keys on WHICH arm, in WHICH context —
    the same narrow distinction the `service_ref` refusal already had to make."""
    var errs = _errs(
        _bundle(
            String(
                '  env { name: "SELF_URL" value_from: VALUE_FROM_DEPLOY_URL }\n'
            ),
            String(""),
            String(""),
        )
    )
    assert_equal(
        len(errs),
        0,
        String(
            "`VALUE_FROM_DEPLOY_URL` on a SERVED spec is the normal shape and"
            " must stay legal — served bundles depend on it. Errors:"
        )
        + _render(errs),
    )
    print("  test_a_service_may_still_source_the_deploy_url: PASS")


def test_a_service_may_still_source_the_env_derived_arms() raises:
    """The second control, on the OTHER family of arms. `VALUE_FROM_ENV_PROJECT`
    exists BECAUSE the literal form was a silent lie; a guard that swept it up
    would reinstate that lie under a new name."""
    var errs = _errs(
        _bundle(
            String(
                '  env { name: "GCP_PROJECT" value_from: VALUE_FROM_ENV_PROJECT }\n'
                '  env { name: "GCP_REGION" value_from: VALUE_FROM_ENV_REGION }\n'
            ),
            String(""),
            String(""),
        )
    )
    assert_equal(
        len(errs),
        0,
        String("the ENV-DERIVED arms stay legal on a service. Errors:")
        + _render(errs),
    )
    print("  test_a_service_may_still_source_the_env_derived_arms: PASS")


def main() raises:
    test_a_validate_step_env_may_source_the_internal_origin()
    test_a_validate_step_arg_may_source_the_internal_origin()
    test_the_served_spec_may_not_source_the_internal_origin()
    test_a_spec_parameter_may_not_source_the_internal_origin()
    test_a_job_may_not_source_the_internal_origin()
    test_a_wave_env_override_may_not_source_the_internal_origin()
    test_a_wave_parameter_override_may_not_source_the_internal_origin()
    test_a_service_may_still_source_the_deploy_url()
    test_a_service_may_still_source_the_env_derived_arms()
    print("PASS test_internal_origin_marker")
