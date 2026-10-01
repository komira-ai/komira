# =============================================================================
# komira_deploy_bundle/tests/test_validation_set_env_restriction.mojo
#   — ⛔ THE VALIDATION-SET ENV RESTRICTION, AS A FALSIFIER. A pipeline step may
#     not run a validation set in an env that set does not permit, and a set that
#     states NO permission may not be run at all.
# =============================================================================
#
# ── THE HOLE THIS FILE CLOSES ───────────────────────────────────────────────
# A bundle may already AUTHOR the right thing (a production wave that names no
# destructive step, a `STEP_KIND_TEST` step that pins `envs: "gamma"`), but
# without a STRUCTURAL refusal nothing stops a future editor writing
# `envs: "prod"` on that step. A test suite's own guard would still refuse, but
# that is the SUITE's guard, not the bundle's.
#
# WHY IT MATTERS AND NOT ABSTRACTLY: a destructive browser suite (here
# `ui-e2e-stage`) SELF-PROVISIONS a real account on a live front door, seeds
# data, and then CASCADE-DELETES the org. Pointed at prod it does that to prod. A
# suite-side guard fires INSIDE a job the cloud has already been asked to run; a
# bundle-side refusal fires offline, before the first mutation. That is the whole
# difference.
#
# ── ⛔ THE POLARITY, WHICH IS THE DESIGN AND NOT AN IMPLEMENTATION DETAIL ────
# A lone `repeated string envs` CANNOT express the difference between NEVER
# STATED and STATED EMPTY — absent and empty are the same bytes — so its absence
# would have to mean either "permitted nowhere" (which breaks every bundle at
# once) or "permitted everywhere" (which is the hole, rewritten in a new
# field). So the discriminator is its own field, `ValidationSet.env_policy`,
# whose ZERO value is an authoring ERROR rather than a permission: "this set is
# safe anywhere" is `VALIDATION_SET_ENV_POLICY_ANY_ENV`, a sentence somebody has
# to write down and a reviewer can grep for.
#
# ── WHERE IT BITES, AND WHY THE FIELD IS STILL ADDITIVE ─────────────────────
# UNSPECIFIED is refused AT THE JOIN — the moment a `PipelineStep` that RUNS
# sets (`STEP_KIND_DEPLOY_AND_VALIDATE` / `STEP_KIND_TEST`) names the set. That
# is exactly where the absence would otherwise become a silent "any env", and it
# leaves a set no pipeline step references byte-identically legal. Leg (8) below
# is the assertion that keeps that true: it is what stops this from becoming a
# migration every bundle has to answer.
#
# ── ⚠ THE LEG THAT IS **NOT** CLOSED, ASSERTED NOWHERE BECAUSE IT IS NOT TRUE ─
# The release CLI's ad-hoc `test <set> --env <env>` verb resolves the set BY NAME
# (`validation_set_steps(bundle, set_name)` in `kci`), which is handed NO env and
# therefore consults no policy. The AUTHORED path is closed by this file; the
# ad-hoc operator path is held only by the suite's own guard. Do not cite this
# file as covering that leg.
#
# Encapsulation: pure parse + validate over text. Mojo 1.0.0b2.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_deploy_bundle.parser import parse_bundle
from komira_deploy_bundle.validate import validate_bundle
from komira_rpc_bundle.app_bundle import ValidationSetEnvPolicy


def _errs(text: String) raises -> List[String]:
    return validate_bundle(parse_bundle(text))


def _any_contains(errs: List[String], needle: String) -> Bool:
    for ref e in errs:
        if e.find(needle) >= 0:
            return True
    return False


def _show(errs: List[String]) -> String:
    """Every error, joined — so an assertion failure PRINTS what validate_bundle
    actually said instead of just the count."""
    var out = String("")
    for i in range(len(errs)):
        out += String("\n    [") + String(i) + String("] ") + errs[i]
    if out.byte_length() == 0:
        return String(" (no errors)")
    return out^


# The valid head every fixture below shares: an API bundle with one build
# target, a spec, and one wave. Nothing here is about the env restriction — it
# exists so that the ONLY thing a fixture varies is the thing under test.
def _head() -> String:
    return String(
        "kind: APP_KIND_API\n"
        'name: "demo-api"\n'
        'build { name: "service" dockerfile: "Dockerfile" }\n'
        'spec { image { from_build: "service" } port: 8088 }\n'
        'waves { env: "gamma" }\n'
    )


# One `validation_sets` block standing in for `ui-e2e-stage`: the destructive,
# self-provisioning browser suite. `policy_lines` is whatever env restriction (if
# any) the fixture is testing.
def _destructive_set(policy_lines: String) -> String:
    return (
        String("validation_sets {\n")
        + String('  name: "ui-e2e-stage"\n')
        + policy_lines
        + String(
            "  steps {\n"
            '    name: "ui-e2e-browser-suite"\n'
            "    run_container {\n"
            '      image { from_build: "service" }\n'
            "      gate_on: GATE_ON_EXIT_CODE\n"
            "    }\n"
            "  }\n"
            "}\n"
        )
    )


def _test_step(env: String) -> String:
    return (
        String("pipeline { steps { step_kind: STEP_KIND_TEST envs: ")
        + String('"')
        + env
        + String('"')
        + String(' validation_set_refs: "ui-e2e-stage" } }\n')
    )


# =============================================================================
# (1) ⛔ THE RED-BEFORE. A `STEP_KIND_TEST` step pointing the destructive
#     self-provisioning set at PROD, with the set stating no env restriction at
#     all.
#
#     Without the `ValidationSet` env restriction this bundle validates CLEAN:
#     a check that the ref NAMES a declared set and nothing else makes "run the
#     org-deleting suite against prod" a legal document.
# =============================================================================
def test_prod_step_naming_an_unrestricted_destructive_set_is_refused() raises:
    var text = _head() + _destructive_set(String("")) + _test_step(
        String("prod")
    )
    var errs = _errs(text)
    assert_true(
        len(errs) > 0,
        String(
            "a STEP_KIND_TEST step running the destructive"
            " self-provisioning set against PROD must be REFUSED at authoring"
            " time. validate_bundle said:"
        )
        + _show(errs),
    )
    assert_true(
        _any_contains(errs, String("states NO `env_policy`")),
        String(
            "the refusal must name the MISSING POLICY as the defect — an unset"
            " policy is not 'any env'. Got:"
        )
        + _show(errs),
    )
    # And the message has to be self-correctable: it must name the set and both
    # spellings that fix it, or the author has to go read the proto.
    assert_true(
        _any_contains(errs, String("ui-e2e-stage")),
        String("the refusal must name the set. Got:") + _show(errs),
    )
    assert_true(
        _any_contains(
            errs, String("VALIDATION_SET_ENV_POLICY_ENV_ALLOWLIST")
        )
        and _any_contains(errs, String("VALIDATION_SET_ENV_POLICY_ANY_ENV")),
        String("the refusal must name BOTH fixes. Got:") + _show(errs),
    )


# =============================================================================
# (2) THE ALLOWLIST BINDS. The set says gamma; a step says prod.
# =============================================================================
def test_allowlist_refuses_an_env_it_does_not_name() raises:
    var policy = String(
        "  env_policy: VALIDATION_SET_ENV_POLICY_ENV_ALLOWLIST\n"
        '  envs: "gamma"\n'
    )
    var errs = _errs(
        _head() + _destructive_set(policy) + _test_step(String("prod"))
    )
    assert_true(
        _any_contains(errs, String("which that set does NOT permit")),
        String(
            "a step naming an allowlisted set against a non-permitted env must"
            " be refused. Got:"
        )
        + _show(errs),
    )
    # The message must carry the ENV that was refused and the LIST that refused
    # it — a bare "not permitted" makes the author open two files.
    assert_true(
        _any_contains(errs, String("against env 'prod'")),
        String("the refusal must name the offending env. Got:") + _show(errs),
    )
    assert_true(
        _any_contains(errs, String("envs: gamma")),
        String("the refusal must print the permitted set. Got:") + _show(errs),
    )


# =============================================================================
# (3) ⭐ THE POSITIVE CONTROL. Without this, (2) is satisfied by a rule that
#     refuses EVERY step — which would be a broken validator, not a gate.
# =============================================================================
def test_allowlist_permits_the_env_it_names() raises:
    var policy = String(
        "  env_policy: VALIDATION_SET_ENV_POLICY_ENV_ALLOWLIST\n"
        '  envs: "gamma"\n'
    )
    var errs = _errs(
        _head() + _destructive_set(policy) + _test_step(String("gamma"))
    )
    assert_equal(
        len(errs),
        0,
        String("a step running the set in a PERMITTED env validates clean. Got:")
        + _show(errs),
    )


# =============================================================================
# (4) "SAFE ANYWHERE" IS A SENTENCE, AND WHEN IT IS WRITTEN IT IS HONOURED.
#     This is the other half of the positive control: the rule keys on the
#     STATEMENT, never on the env's name. Nothing here special-cases "prod".
# =============================================================================
def test_any_env_is_honoured_once_it_is_spelled() raises:
    var policy = String("  env_policy: VALIDATION_SET_ENV_POLICY_ANY_ENV\n")
    var errs = _errs(
        _head() + _destructive_set(policy) + _test_step(String("prod"))
    )
    assert_equal(
        len(errs),
        0,
        String(
            "ANY_ENV, deliberately authored, permits prod — the gate refuses an"
            " UNSTATED permission, not the word 'prod'. Got:"
        )
        + _show(errs),
    )


# =============================================================================
# (5) ANY_ENV BESIDE A NON-EMPTY `envs` — dead text that reads as a restriction.
# =============================================================================
def test_any_env_beside_an_allowlist_is_refused() raises:
    var policy = String(
        "  env_policy: VALIDATION_SET_ENV_POLICY_ANY_ENV\n" '  envs: "gamma"\n'
    )
    var errs = _errs(
        _head() + _destructive_set(policy) + _test_step(String("gamma"))
    )
    assert_true(
        _any_contains(errs, String("DEAD TEXT")),
        String(
            "an `envs` list under ANY_ENV binds nothing and must be refused as"
            " dead text. Got:"
        )
        + _show(errs),
    )


# =============================================================================
# (6) ENV_ALLOWLIST WITH NO `envs` — permitted nowhere, referenced anyway.
# =============================================================================
def test_allowlist_with_no_envs_is_refused() raises:
    var policy = String(
        "  env_policy: VALIDATION_SET_ENV_POLICY_ENV_ALLOWLIST\n"
    )
    var errs = _errs(
        _head() + _destructive_set(policy) + _test_step(String("gamma"))
    )
    assert_true(
        _any_contains(errs, String("permitted in NO env")),
        String(
            "an ALLOWLIST with an empty `envs` permits nothing and must be"
            " refused rather than read as a vacuous restriction. Got:"
        )
        + _show(errs),
    )


# =============================================================================
# (7) `envs` AUTHORED UNDER NO POLICY — the file LOOKS restricted and is not.
#     Silently the worst of the three, because a reviewer scanning for the
#     restriction finds one.
# =============================================================================
def test_envs_without_a_policy_is_refused() raises:
    var policy = String('  envs: "gamma"\n')
    var errs = _errs(
        _head() + _destructive_set(policy) + _test_step(String("gamma"))
    )
    assert_true(
        _any_contains(errs, String("binds NOTHING")),
        String(
            "an `envs` list with no `env_policy` arms nothing and must be"
            " refused. Got:"
        )
        + _show(errs),
    )


# =============================================================================
# (8) ⭐ ADDITIVE SAFETY — THE ASSERTION THAT KEEPS THIS A FIELD AND NOT A
#     MIGRATION. A set that NO pipeline step references needs no policy, because
#     there is no join at which the absence could become a silent "any env".
#     Bundles that author sets under no pipeline at all depend on this; if this
#     leg ever goes red, every one of them broke.
# =============================================================================
def test_an_unreferenced_set_needs_no_policy() raises:
    var errs = _errs(_head() + _destructive_set(String("")))
    assert_equal(
        len(errs),
        0,
        String(
            "a validation_set no pipeline step references stays legal with no"
            " env restriction. Got:"
        )
        + _show(errs),
    )


# =============================================================================
# (9) THE OTHER SET-RUNNING KIND. `STEP_KIND_DEPLOY_AND_VALIDATE` runs sets too,
#     and covering only `STEP_KIND_TEST` would leave the identical hole one enum
#     value over.
# =============================================================================
def test_deploy_and_validate_is_covered_too() raises:
    var policy = String(
        "  env_policy: VALIDATION_SET_ENV_POLICY_ENV_ALLOWLIST\n"
        '  envs: "gamma"\n'
    )
    var tail = String(
        "pipeline { steps { step_kind: STEP_KIND_DEPLOY_AND_VALIDATE"
        ' envs: "prod" validation_set_refs: "ui-e2e-stage" } }\n'
    )
    var errs = _errs(_head() + _destructive_set(policy) + tail)
    assert_true(
        _any_contains(errs, String("which that set does NOT permit")),
        String(
            "DEPLOY_AND_VALIDATE runs the named set exactly as TEST does and"
            " must be refused identically. Got:"
        )
        + _show(errs),
    )


def main() raises:
    print("=== ValidationSet env restriction ===")
    test_prod_step_naming_an_unrestricted_destructive_set_is_refused()
    test_allowlist_refuses_an_env_it_does_not_name()
    test_allowlist_permits_the_env_it_names()
    test_any_env_is_honoured_once_it_is_spelled()
    test_any_env_beside_an_allowlist_is_refused()
    test_allowlist_with_no_envs_is_refused()
    test_envs_without_a_policy_is_refused()
    test_an_unreferenced_set_needs_no_policy()
    test_deploy_and_validate_is_covered_too()
    print("PASS test_validation_set_env_restriction")
