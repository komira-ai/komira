# =============================================================================
# src/kci_api/tests/test_result_refusals.mojo
#   The result document's refusals that test_result_document.mojo leaves
#   out, each pinned by its whole message: a value of the wrong JSON type
#   inside an array or object (stage_step_kinds, only, context, steps,
#   artifacts, validations and their checks, new_names, affected_by.units),
#   a non-integer number, a document that is not an object; and the checks
#   the renderer and the parser share (an empty invoked_as, a nameless step,
#   validation or check, an unselected step that probes a credential, an
#   empty affected unit, a context key given twice). An index above 0 is
#   used where the refusal names one, so a refusal naming the wrong element
#   is caught.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from kci_api import (
    CREDENTIAL_PROBE_MINTED,
    ContextEntry,
    OUTCOME_NOOP,
    OUTCOME_SUCCEEDED,
    ResultNewName,
    ResultStep,
    ResultValidation,
    ResultValidationCheck,
    RunIdentity,
    RunResult,
    SCOPE_SELECTIVE,
    STEP_KIND_BUILD,
    STEP_KIND_PUBLISH,
    VALIDATION_KIND_CONDA_INSTALL_SMOKE,
    VALIDATION_NOT_REACHED,
    VALIDATION_VALIDATED,
    VALIDATION_WOULD_VALIDATE,
    VERB_RUN,
    all_validation_effects,
    parse_result,
    render_result,
)

comptime _REV = "0123456789abcdef0123456789abcdef01234567"
comptime _H = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"


def _refusal(text: String) -> String:
    try:
        _ = parse_result(text, String("r.json"))
    except e:
        return String(e)
    return String("<parsed>")


def _render_refusal(r: RunResult) -> String:
    try:
        _ = render_result(r)
    except e:
        return String(e)
    return String("<rendered>")


def _publish() raises -> RunResult:
    """One PUBLISH step `publish` that ran, two context entries, one new name."""
    var r = RunResult(String(VERB_RUN), String(VERB_RUN))
    var run = RunIdentity(String("gh-7"), 2)
    run.add_context(ContextEntry(String("event"), String("push")))
    run.add_context(ContextEntry(String("actor_id"), String("42")))
    r.set_run(run)
    r.stage = String("publish-gamma")
    r.platform = String("linux-x86_64")
    r.channel = String("gamma")
    r.stage_step_kinds.append(String(STEP_KIND_PUBLISH))
    r.steps.append(ResultStep(String("publish"), String(STEP_KIND_PUBLISH), String("linux-x86_64"), String(OUTCOME_NOOP)))
    r.new_names.append(ResultNewName(String("publish-prod"), String("publish"), String("prod"), String("komira_all")))
    return r^


def _smoke(var effect: String, var outcome: String) -> ResultValidation:
    return ResultValidation(
        String("install-smoke"), String("publish"), String(VALIDATION_KIND_CONDA_INSTALL_SMOKE), effect^, outcome^
    )


def _ok_check(var name: String) -> ResultValidationCheck:
    return ResultValidationCheck(name^, String(_H), String(_H), True)


def _with_one_check() raises -> String:
    """A FINISHED document whose one validation ran and holds one check."""
    var r = _publish()
    var v = _smoke(String(VALIDATION_VALIDATED), String(OUTCOME_SUCCEEDED))
    v.checks.append(_ok_check(String("sha256 komira_encoding")))
    r.validations.append(v^)
    return render_result(r.finish_record(String(OUTCOME_SUCCEEDED), 9))


def _affected() raises -> String:
    var r = RunResult(String(VERB_RUN), String(VERB_RUN))
    r.stage = String("pr")
    r.stage_step_kinds.append(String(STEP_KIND_BUILD))
    r.scope = String(SCOPE_SELECTIVE)
    r.has_affected_by = True
    r.affected_base = String(_REV)
    r.affected_verdict = String("AFFECTED")
    r.affected_units.append(String("lib_a"))
    r.affected_units.append(String("lints"))
    r.steps.append(ResultStep(String("check"), String(STEP_KIND_BUILD), String(""), String(OUTCOME_SUCCEEDED)))
    return render_result(r)


def _swap(text: String, old: String, new: String) raises -> String:
    """`text` with the one occurrence of `old` replaced: a forged document
    that differs from a valid one at exactly that place."""
    assert_equal(text.count(old), 1, old)
    return text.replace(old, new)


def test_the_documents_forged_below_parse() raises:
    # the control: each base document parses, so a refusal below is the
    # forged value's and nothing else's
    var g = render_result(_publish().finish_record(String(OUTCOME_NOOP), 2000))
    assert_equal(render_result(parse_result(g, String("r.json"))), g)
    var c = _with_one_check()
    assert_equal(render_result(parse_result(c, String("r.json"))), c)
    var a = _affected()
    assert_equal(render_result(parse_result(a, String("r.json"))), a)


def test_a_value_of_the_wrong_json_type_is_refused() raises:
    var g = render_result(_publish().finish_record(String(OUTCOME_NOOP), 2000))
    assert_equal(_refusal(String("[1]")), String("result 'r.json': not a JSON object"))
    assert_equal(
        _refusal(_swap(g, String('"stage_step_kinds":["PUBLISH"]'), String('"stage_step_kinds":["PUBLISH",1]'))),
        String("result 'r.json': stage_step_kinds[1] is not a string"),
    )
    assert_equal(
        _refusal(_swap(g, String('"only":[]'), String('"only":["step:publish",2]'))),
        String("result 'r.json': only[1] is not a string"),
    )
    assert_equal(
        _refusal(_swap(g, String('"actor_id":"42"'), String('"actor_id":42'))),
        String("result 'r.json': context 'actor_id' is not a string"),
    )
    assert_equal(
        _refusal(_swap(g, String('"attempt":2,'), String('"attempt":2.5,'))),
        String("result 'r.json': 'attempt' is not an integer"),
    )
    assert_equal(
        _refusal(_swap(g, String('"steps":['), String('"steps":[1,'))),
        String("result 'r.json': steps[0]: not an object"),
    )
    assert_equal(
        _refusal(_swap(g, String('"artifacts":[]'), String('"artifacts":["x"]'))),
        String("result 'r.json': artifacts[0]: not an object"),
    )
    assert_equal(
        _refusal(_swap(g, String('"validations":[]'), String('"validations":[[]]'))),
        String("result 'r.json': validations[0]: not an object"),
    )
    assert_equal(
        _refusal(_swap(g, String('"new_names":['), String('"new_names":[true,'))),
        String("result 'r.json': new_names[0]: not an object"),
    )


def test_a_nested_value_of_the_wrong_json_type_is_refused() raises:
    var c = _with_one_check()
    assert_equal(
        _refusal(_swap(c, String('"checks":['), String('"checks":[1,'))),
        String("result 'r.json': validations[0]: checks[0]: not an object"),
    )
    var a = _affected()
    assert_equal(
        _refusal(_swap(a, String('"units":["lib_a","lints"]'), String('"units":["lib_a",7]'))),
        String("result 'r.json': affected_by: units[1] is not a string"),
    )


def test_invoked_as_is_never_empty() raises:
    var r = RunResult(String(VERB_RUN), String(""))
    assert_equal(_render_refusal(r), String("result: 'invoked_as' is EMPTY"))
    var g = render_result(_publish())
    assert_equal(
        _refusal(_swap(g, String('"invoked_as":"run"'), String('"invoked_as":""'))),
        String("result 'r.json': result: 'invoked_as' is EMPTY"),
    )


def test_a_step_names_itself() raises:
    var r = _publish()
    r.steps.append(ResultStep(String(""), String(STEP_KIND_PUBLISH), String("linux-x86_64"), String(OUTCOME_NOOP)))
    assert_equal(_render_refusal(r), String("result: steps[1] has no name"))


def test_an_unselected_step_probes_no_credential() raises:
    var r = RunResult(String(VERB_RUN), String(VERB_RUN))
    r.stage = String("release")
    r.plan = True
    r.scope = String(SCOPE_SELECTIVE)
    r.only.append(String("step:build"))
    r.stage_step_kinds.append(String(STEP_KIND_BUILD))
    r.stage_step_kinds.append(String(STEP_KIND_PUBLISH))
    r.steps.append(ResultStep(String("build"), String(STEP_KIND_BUILD), String(""), String(OUTCOME_SUCCEEDED)))
    var s = ResultStep.unselected(String("publish"), String(STEP_KIND_PUBLISH), String(""))
    assert_equal(_render_refusal(r), String("<rendered>"))
    s.credential_probe = String(CREDENTIAL_PROBE_MINTED)
    r.steps.append(s^)
    assert_equal(_render_refusal(r), String("result: steps[1] 'publish': an unselected step probes no credential"))


def test_an_affected_unit_is_never_empty() raises:
    var a = _affected()
    assert_equal(
        _refusal(_swap(a, String('"units":["lib_a","lints"]'), String('"units":["lib_a",""]'))),
        String("result 'r.json': result: affected_by: units[1] is empty"),
    )


def test_a_validation_and_its_checks_are_named() raises:
    var r = _publish()
    r.validations.append(_smoke(String(VALIDATION_NOT_REACHED), String("")))
    assert_equal(_render_refusal(r), String("<rendered>"))
    r.validations.append(
        ResultValidation(String(""), String("publish"), String(VALIDATION_KIND_CONDA_INSTALL_SMOKE), String(VALIDATION_NOT_REACHED), String(""))
    )
    assert_equal(_render_refusal(r), String("result: validations[1] has no name"))
    var c = _publish()
    var v = _smoke(String(VALIDATION_VALIDATED), String(OUTCOME_SUCCEEDED))
    v.checks.append(_ok_check(String("sha256 komira_encoding")))
    v.checks.append(_ok_check(String("")))
    c.validations.append(v^)
    assert_equal(_render_refusal(c), String("result: validations[0] 'install-smoke': checks[1] has no name"))


def test_a_context_key_is_given_once() raises:
    var r = _publish()
    r.context.append(ContextEntry(String("actor_id"), String("43")))
    # the duplicate is entries 1 and 2: neither is the first entry
    assert_equal(_render_refusal(r), String("result: context key 'actor_id' is given twice"))
    var g = render_result(_publish())
    assert_equal(
        _refusal(_swap(g, String('"actor_id":"42"'), String('"actor_id":"42","actor_id":"43"'))),
        String("result 'r.json': result: context key 'actor_id' is given twice"),
    )


def test_validation_effects_table() raises:
    var t = all_validation_effects()
    assert_equal(len(t), 3)
    assert_equal(t[0], String(VALIDATION_VALIDATED))
    assert_equal(t[1], String(VALIDATION_WOULD_VALIDATE))
    assert_equal(t[2], String(VALIDATION_NOT_REACHED))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
