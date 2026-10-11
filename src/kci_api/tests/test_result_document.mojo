# =============================================================================
# src/kci_api/tests/test_result_document.mojo
#   The result document: a byte-exact golden, render/parse round trips, the
#   RUNNING-then-FINISHED records, unknown keys ignored, every refusal, the
#   FULL / SELECTIVE scope (a selective run never reads as a full one), and
#   the one-command keys: validations[] (a --plan validation never reads as
#   a pass), new_names[], workflow and steps[].credential_probe.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_api import (
    ARTIFACT_ALREADY_PRESENT,
    ARTIFACT_WOULD_BUILD,
    CREDENTIAL_PROBE_MINTED,
    CREDENTIAL_PROBE_NOT_UNDER_CI,
    ContextEntry,
    credential_probe_note,
    ERROR_PUBLISH_READ_BACK,
    ERROR_SELECTOR,
    ERROR_SELECTOR_NO_MATCH,
    ERROR_USAGE,
    MemoryRecorder,
    OUTCOME_INDETERMINATE,
    OUTCOME_NOOP,
    OUTCOME_PARTIAL,
    OUTCOME_REFUSED,
    OUTCOME_SUCCEEDED,
    OUTCOME_VALIDATION_FAILED,
    RETRY_NEEDS_HUMAN,
    RETRY_SAFE,
    ResultArtifact,
    ResultNewName,
    ResultStep,
    ResultValidation,
    ResultValidationCheck,
    RunIdentity,
    RunRecorder,
    RunResult,
    SCOPE_SELECTIVE,
    STEP_KIND_BUILD,
    STEP_KIND_PUBLISH,
    VALIDATION_ENVIRONMENT_ENV,
    VALIDATION_KIND_CONDA_INSTALL_ENV,
    VALIDATION_KIND_CONDA_INSTALL_SMOKE,
    VALIDATION_NOT_REACHED,
    VALIDATION_VALIDATED,
    VALIDATION_WOULD_VALIDATE,
    VERB_RUN,
    parse_result,
    render_result,
    reserved_result_keys,
)

comptime _REV = "0123456789abcdef0123456789abcdef01234567"
comptime _H = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"


def _publish_result() raises -> RunResult:
    var r = RunResult(String(VERB_RUN), String(VERB_RUN))
    var run = RunIdentity(String("gh-7"), 2)
    run.add_context(ContextEntry(String("event"), String("push")))
    run.add_context(ContextEntry(String("actor_id"), String("42")))
    r.set_run(run)
    r.machine_path = String("release/machine.textproto")
    r.machine_sha256 = String(_H)
    r.stage = String("publish-gamma")
    r.stage_step_kinds.append(String(STEP_KIND_PUBLISH))
    r.revision = String(_REV)
    r.platform = String("linux-x86_64")
    r.started_at_ms = 1000
    r.channel = String("gamma")
    r.set_hash = String(_H)
    r.workflow_checked = True
    r.workflow_path = String(".github/workflows/kci.yml")
    r.workflow_sha = String(_REV)
    r.workflow_reason = String("")
    # the stage after this one publishes to prod, which has no komira_all yet
    r.new_names.append(ResultNewName(String("publish-prod"), String("publish"), String("prod"), String("komira_all")))
    r.has_release_produced_by = True
    r.release_produced_by_run_id = String("gh-6")
    r.release_produced_by_attempt = 1
    r.steps.append(ResultStep(String("publish"), String(STEP_KIND_PUBLISH), String("linux-x86_64"), String(OUTCOME_NOOP)))
    var a = ResultArtifact()
    a.effect = String(ARTIFACT_ALREADY_PRESENT)
    a.artifact_type = String("CONDA")
    a.build = String("0")
    a.file = String("linux-64/komira-0.1.7-0.conda")
    a.indexed = True
    a.name = String("komira")
    a.platform = String("linux-x86_64")
    a.revision = String(_REV)
    a.sha256 = String(_H)
    a.state_after = String("PRESENT_SAME")
    a.state_before = String("PRESENT_SAME")
    a.subdir = String("linux-64")
    a.version = String("0.1.7")
    r.artifacts.append(a^)
    return r^


def test_golden_finished_noop_is_exit_zero() raises:
    var r = _publish_result().finish_record(String(OUTCOME_NOOP), 2000)
    var text = render_result(r)
    var want = (
        String('{"artifacts":[{"artifact_type":"CONDA","build":"0","effect":"ALREADY_PRESENT",')
        + String('"file":"linux-64/komira-0.1.7-0.conda","indexed":true,"name":"komira",')
        + String('"platform":"linux-x86_64","revision":"') + String(_REV) + String('","sha256":"') + String(_H)
        + String('","state_after":"PRESENT_SAME","state_before":"PRESENT_SAME","subdir":"linux-64","version":"0.1.7"}],')
        + String('"attempt":2,"channel":"gamma","context":{"event":"push","actor_id":"42"},')
        + String('"exit_code":0,"finished_at_ms":2000,')
        + String('"format":"kci.result","invoked_as":"run","kci_version":"0.0.0-unreleased",')
        + String('"machine":{"path":"release/machine.textproto","sha256":"') + String(_H) + String('"},')
        + String('"new_names":[{"channel":"prod","name":"komira_all","stage":"publish-prod","step":"publish"}],')
        + String('"only":[],"outcome":"NOOP","plan":false,"platform":"linux-x86_64",')
        + String('"release_produced_by":{"attempt":1,"run_id":"gh-6"},')
        + String('"retry":"SAFE","revision":"') + String(_REV) + String('","run_id":"gh-7","schema_version":1,')
        + String('"scope":"FULL","set_hash":"') + String(_H) + String('","stage":"publish-gamma","stage_step_kinds":["PUBLISH"],')
        + String('"started_at_ms":1000,"status":"FINISHED",')
        + String('"steps":[{"credential_probe":"","kind":"PUBLISH","name":"publish","outcome":"NOOP",')
        + String('"platform":"linux-x86_64","selected":true}],')
        + String('"validations":[],"verb":"run",')
        + String('"workflow":{"checked":true,"path":".github/workflows/kci.yml","reason":"","sha":"') + String(_REV)
        + String('"}}\n')
    )
    assert_equal(text, want)
    assert_equal(r.exit_code, 0)
    assert_equal(r.retry, String(RETRY_SAFE))


def test_round_trip_is_identity() raises:
    var t1 = render_result(_publish_result().finish_record(String(OUTCOME_NOOP), 2000))
    var t2 = render_result(parse_result(t1, String("r.json")))
    assert_equal(t1, t2)
    var p = parse_result(t1, String("r.json"))
    assert_equal(len(p.context), 2)
    assert_equal(p.context[1].key, String("actor_id"))
    assert_true(p.has_release_produced_by)
    assert_false(p.has_error)
    assert_equal(len(p.ignored_keys), 0)


def test_running_then_finished() raises:
    var rec = MemoryRecorder()
    var r = _publish_result()
    rec.begin(r.begin_record())
    rec.finish(r.finish_record(String(OUTCOME_SUCCEEDED), 3000))
    assert_equal(len(rec.records), 2)
    assert_equal(rec.statuses[0], String("RUNNING"))
    assert_equal(rec.statuses[1], String("FINISHED"))
    var first = parse_result(rec.records[0], String("r.json"))
    # a RUNNING record left behind reads as interrupted, exit 6, retry UNSAFE
    assert_equal(first.outcome, String("INTERRUPTED"))
    assert_equal(first.exit_code, 6)
    assert_equal(first.retry, String("UNSAFE"))
    assert_equal(first.finished_at_ms, 0)
    var last = parse_result(rec.records[1], String("r.json"))
    assert_equal(last.outcome, String("SUCCEEDED"))
    assert_equal(last.exit_code, 0)


def test_errors_pick_the_number() raises:
    # `invoked_as` keeps the word as typed, even one that is not a verb
    var u = RunResult(String(VERB_RUN), String("build"))
    u.set_error(String(ERROR_USAGE), String("--attempt is required"))
    # the first error stays
    u.set_error(String(ERROR_SELECTOR_NO_MATCH), String("later"))
    var f = u.finish_record(String(OUTCOME_REFUSED), 5)
    assert_equal(f.exit_code, 2)
    assert_equal(f.error.id, String(ERROR_USAGE))
    assert_equal(parse_result(render_result(f), String("r.json")).invoked_as, String("build"))
    # a selector that matches nothing is a refusal (3); a malformed one is usage (2)
    var k = RunResult(String(VERB_RUN), String(VERB_RUN))
    k.set_error(String(ERROR_SELECTOR_NO_MATCH), String("stage prod has no step 'x'"))
    assert_equal(k.finish_record(String(OUTCOME_REFUSED), 5).exit_code, 3)
    var sel = RunResult(String(VERB_RUN), String(VERB_RUN))
    sel.set_error(String(ERROR_SELECTOR), String("--only 'x' is not step:<name> or validation:<name>"))
    assert_equal(sel.finish_record(String(OUTCOME_REFUSED), 5).exit_code, 2)
    var p = RunResult(String(VERB_RUN), String(VERB_RUN))
    p.set_error(String(ERROR_PUBLISH_READ_BACK), String("read back differs"))
    var pf = p.finish_record(String(OUTCOME_PARTIAL), 5, String(RETRY_NEEDS_HUMAN))
    assert_equal(pf.exit_code, 6)
    assert_equal(pf.retry, String(RETRY_NEEDS_HUMAN))
    var t = render_result(pf)
    assert_equal(render_result(parse_result(t, String("r.json"))), t)
    var refused = False
    try:
        _ = p.finish_record(String(OUTCOME_PARTIAL), 5, String(RETRY_SAFE))
    except e:
        refused = String(e).find(String("weaker")) >= 0
    assert_true(refused)
    refused = False
    try:
        p.set_error(String("KCI-E-MADE-UP"), String("x"))
    except e:
        refused = True
    assert_true(refused)


def _refusal(text: String) -> String:
    try:
        _ = parse_result(text, String("r.json"))
    except e:
        return String(e)
    return String("<parsed>")


def _golden() raises -> String:
    return render_result(_publish_result().finish_record(String(OUTCOME_NOOP), 2000))


def test_unknown_keys_ignored_reserved_absent() raises:
    var g = _golden()
    # a reserved name is still an ignored key (a deploy key of a step row at
    # the top level is refused instead: test_result_deploy_keys.mojo)
    var t = g.replace(String('"verb":"run",'), String('"verb":"run","security_relevant_changes":[],'))
    t = t.replace(String('"indexed":true,'), String('"indexed":true,"later":1,'))
    var p = parse_result(t, String("r.json"))
    assert_equal(len(p.ignored_keys), 2)
    assert_equal(p.ignored_keys[0], String("security_relevant_changes"))
    assert_equal(p.ignored_keys[1], String("artifacts[0].later"))
    # a re-render drops what was ignored
    assert_equal(render_result(p), g)
    var reserved = reserved_result_keys()
    for i in range(len(reserved)):
        assert_equal(g.find(String('"') + reserved[i] + String('"')), -1)


def test_refusals() raises:
    var g = _golden()
    assert_true(_refusal(g.replace(String('"schema_version":1'), String('"schema_version":2'))).find(String("needs a newer kci")) >= 0)
    assert_true(_refusal(g.replace(String('"format":"kci.result"'), String('"format":"kci.release_set"'))).find(String("is not 'kci.result'")) >= 0)
    assert_true(_refusal(g.replace(String('"exit_code":0'), String('"exit_code":6'))).find(String("exit_code 6 is not 0")) >= 0)
    assert_true(_refusal(g.replace(String('"outcome":"NOOP","plan"'), String('"outcome":"DONE","plan"'))).find(String("is not one of")) >= 0)
    assert_true(_refusal(g.replace(String('"status":"FINISHED"'), String('"status":"RUNNING"'))).find(String("a RUNNING record says INTERRUPTED")) >= 0)
    assert_true(_refusal(g.replace(String('"status":"FINISHED"'), String('"status":"DONE"'))).find(String("is not RUNNING or FINISHED")) >= 0)
    # `build`, `publish`, `stages`, `ci-check` are not verbs: only run
    assert_true(_refusal(g.replace(String('"verb":"run"'), String('"verb":"ci-check"'))).find(String("is not a kci verb")) >= 0)
    assert_true(_refusal(g.replace(String('"verb":"run"'), String('"verb":"publish"'))).find(String("is not a kci verb")) >= 0)
    assert_true(_refusal(g.replace(String('"verb":"run"'), String('"verb":"build"'))).find(String("is not a kci verb")) >= 0)
    assert_true(_refusal(g.replace(String('"stage_step_kinds":["PUBLISH"]'), String('"stage_step_kinds":["SHIP"]'))).find(String("is not BUILD, PUBLISH or DEPLOY")) >= 0)
    assert_true(_refusal(g.replace(String('"effect":"ALREADY_PRESENT"'), String('"effect":"none"'))).find(String("effect 'none' is not one of")) >= 0)
    assert_true(_refusal(g.replace(String('"scope":"FULL"'), String('"scope":"PARTIAL"'))).find(String("scope 'PARTIAL' is not FULL or SELECTIVE")) >= 0)
    assert_true(_refusal(g.replace(String('"plan":false,'), String(''))).find(String("missing 'plan'")) >= 0)
    assert_true(_refusal(g.replace(String('"scope":"FULL",'), String(''))).find(String("missing 'scope'")) >= 0)
    assert_true(_refusal(g.replace(String('"selected":true'), String('"selected":1'))).find(String("'selected' has the wrong JSON type")) >= 0)
    assert_true(_refusal(g.replace(String('"run_id":"gh-7"'), String('"run_id":7'))).find(String("'run_id' has the wrong JSON type")) >= 0)
    assert_true(_refusal(g.replace(String('"retry":"SAFE"'), String('"retry":"MAYBE"'))).find(String("retry 'MAYBE' is not one of")) >= 0)
    assert_true(_refusal(g.replace(String('"revision":"0123'), String('"revision":"X123'))).find(String("is not a full commit id")) >= 0)
    assert_true(_refusal(g.replace(String('"platform":"linux-x86_64","release'), String('"platform":"amiga","release'))).find(String("platform 'amiga' is not one of")) >= 0)
    assert_true(_refusal(g.replace(String('"verb":"run",'), String('"verb":"run","verb":"run",'))).find(String("'verb' is given twice")) >= 0)
    assert_true(_refusal(g.replace(String('"validations":[],'), String(''))).find(String("missing 'validations'")) >= 0)
    assert_true(_refusal(g.replace(String('"new_names":[{'), String('"new_name":[{'))).find(String("missing 'new_names'")) >= 0)
    assert_true(_refusal(g.replace(String('"credential_probe":"",'), String(''))).find(String("missing 'credential_probe'")) >= 0)
    assert_true(_refusal(g.replace(String('"workflow":{'), String('"workflows":{'))).find(String("missing 'workflow'")) >= 0)
    assert_true(_refusal(String("{")).find(String("not JSON")) >= 0)
    # the renderer refuses what the parser would
    var bad = _publish_result()
    bad.revision = String("abc")
    var refused = False
    try:
        _ = render_result(bad)
    except e:
        refused = True
    assert_true(refused)


def _two_step_result() raises -> RunResult:
    """A build+publish stage; the caller sets scope, only and selection."""
    var r = RunResult(String(VERB_RUN), String(VERB_RUN))
    r.stage = String("release")
    r.platform = String("linux-x86_64")
    r.stage_step_kinds.append(String(STEP_KIND_BUILD))
    r.stage_step_kinds.append(String(STEP_KIND_PUBLISH))
    return r^


def test_steps_round_trip_with_selection() raises:
    var r = _two_step_result()
    r.scope = String(SCOPE_SELECTIVE)
    r.only.append(String("step:publish"))
    r.steps.append(ResultStep.unselected(String("build"), String(STEP_KIND_BUILD), String("linux-x86_64")))
    r.steps.append(ResultStep(String("publish"), String(STEP_KIND_PUBLISH), String("linux-x86_64"), String(OUTCOME_SUCCEEDED)))
    var t = render_result(r.finish_record(String(OUTCOME_SUCCEEDED), 9))
    assert_true(t.find(String('"scope":"SELECTIVE"')) >= 0)
    assert_true(t.find(String('"only":["step:publish"]')) >= 0)
    assert_true(
        t.find(String('{"credential_probe":"","kind":"BUILD","name":"build","outcome":"","platform":"linux-x86_64","selected":false}')) >= 0
    )
    var p = parse_result(t, String("r.json"))
    assert_equal(render_result(p), t)
    assert_equal(len(p.steps), 2)
    assert_false(p.steps[0].selected)
    assert_true(p.steps[1].selected)
    assert_equal(p.steps[1].name, String("publish"))
    assert_equal(p.scope, String(SCOPE_SELECTIVE))
    # a selective success is still exit 0: the scope, not the number, tells
    assert_equal(p.exit_code, 0)


def _render_refusal(r: RunResult) -> String:
    try:
        _ = render_result(r)
    except e:
        return String(e)
    return String("<rendered>")


def test_full_never_holds_an_unselected_step() raises:
    var r = _two_step_result()
    r.steps.append(ResultStep.unselected(String("build"), String(STEP_KIND_BUILD), String("linux-x86_64")))
    r.steps.append(ResultStep(String("publish"), String(STEP_KIND_PUBLISH), String("linux-x86_64"), String(OUTCOME_SUCCEEDED)))
    assert_true(_render_refusal(r).find(String("a FULL run selects every step")) >= 0)
    # and the parser refuses the same document written by someone else
    r.scope = String(SCOPE_SELECTIVE)
    r.only.append(String("step:publish"))
    var t = render_result(r)
    var forged = t.replace(String('"only":["step:publish"]'), String('"only":[]')).replace(
        String('"scope":"SELECTIVE"'), String('"scope":"FULL"')
    )
    assert_true(_refusal(forged).find(String("a FULL run selects every step")) >= 0)


def test_selective_names_its_selectors() raises:
    var r = _two_step_result()
    r.scope = String(SCOPE_SELECTIVE)
    r.steps.append(ResultStep(String("build"), String(STEP_KIND_BUILD), String("linux-x86_64"), String(OUTCOME_SUCCEEDED)))
    assert_true(_render_refusal(r).find(String("a SELECTIVE run names its --only selectors")) >= 0)
    # every step selected is still SELECTIVE when --only was given
    r.only.append(String("step:build"))
    assert_equal(_render_refusal(r), String("<rendered>"))
    # FULL with selectors is refused too
    var f = _two_step_result()
    f.only.append(String("step:build"))
    assert_true(_render_refusal(f).find(String("a FULL run has no --only")) >= 0)
    # a selector is recorded canonical and once
    var d = _two_step_result()
    d.scope = String(SCOPE_SELECTIVE)
    d.only.append(String("step:build"))
    d.only.append(String("step:build"))
    assert_true(_render_refusal(d).find(String("is given twice")) >= 0)
    var u = _two_step_result()
    u.scope = String(SCOPE_SELECTIVE)
    u.only.append(String("stage:build"))
    assert_true(_render_refusal(u).find(String("is not a selector kind")) >= 0)
    # an unselected step carries no outcome
    var o = _two_step_result()
    o.scope = String(SCOPE_SELECTIVE)
    o.only.append(String("step:publish"))
    var st = ResultStep.unselected(String("build"), String(STEP_KIND_BUILD), String("linux-x86_64"))
    st.outcome = String(OUTCOME_SUCCEEDED)
    o.steps.append(st^)
    assert_true(_render_refusal(o).find(String("an unselected step has no outcome")) >= 0)


def test_plan_and_would_build() raises:
    var r = _two_step_result()
    r.plan = True
    r.steps.append(ResultStep(String("build"), String(STEP_KIND_BUILD), String("linux-x86_64"), String(OUTCOME_SUCCEEDED)))
    var a = ResultArtifact()
    a.effect = String(ARTIFACT_WOULD_BUILD)
    a.name = String("komira_encoding")
    a.platform = String("linux-x86_64")
    r.artifacts.append(a^)
    var t = render_result(r.finish_record(String(OUTCOME_SUCCEEDED), 9))
    assert_true(t.find(String('"plan":true')) >= 0)
    assert_true(t.find(String('"effect":"WOULD_BUILD"')) >= 0)
    assert_true(parse_result(t, String("r.json")).plan)


def test_old_key_names_are_not_read() raises:
    # `actions`, `stage_action_kinds`, `dry_run` and `artifacts[].action` are
    # the pre-v1.3 names, and `expect_set_hash` a key of an earlier draft:
    # unknown keys now, ignored and never read
    var g = _golden()
    var t = g.replace(
        String('"verb":"run",'),
        String('"verb":"run","actions":[],"stage_action_kinds":["BUILD"],"dry_run":true,"expect_set_hash":"x",'),
    )
    t = t.replace(String('"indexed":true,'), String('"indexed":true,"action":"BUILT",'))
    var p = parse_result(t, String("r.json"))
    assert_equal(len(p.ignored_keys), 5)
    assert_equal(p.ignored_keys[3], String("expect_set_hash"))
    assert_false(p.plan)
    assert_equal(len(p.stage_step_kinds), 1)
    assert_equal(p.stage_step_kinds[0], String("PUBLISH"))
    assert_equal(p.artifacts[0].effect, String("ALREADY_PRESENT"))
    assert_equal(render_result(p), g)


def _gamma_publish(plan: Bool) raises -> RunResult:
    """Stage publish-gamma: one PUBLISH step `publish` that ran."""
    var r = RunResult(String(VERB_RUN), String(VERB_RUN))
    r.stage = String("publish-gamma")
    r.platform = String("linux-x86_64")
    r.channel = String("gamma")
    r.plan = plan
    r.workflow_reason = String("not under GitHub Actions")
    r.stage_step_kinds.append(String(STEP_KIND_PUBLISH))
    r.steps.append(ResultStep(String("publish"), String(STEP_KIND_PUBLISH), String("linux-x86_64"), String(OUTCOME_SUCCEEDED)))
    return r^


def _smoke(var effect: String, var outcome: String) -> ResultValidation:
    return ResultValidation(
        String("install-smoke"), String("publish"), String(VALIDATION_KIND_CONDA_INSTALL_SMOKE), effect^, outcome^
    )


def _check_row(ok: Bool) -> ResultValidationCheck:
    var got = String(_H) if ok else String("bb")
    return ResultValidationCheck(String("sha256 komira_encoding"), String(_H), got^, ok)


def test_validations_round_trip() raises:
    var r = _gamma_publish(False)
    var v = _smoke(String(VALIDATION_VALIDATED), String(OUTCOME_SUCCEEDED))
    v.checks.append(_check_row(True))
    v.checks.append(ResultValidationCheck(String("smoke output"), String("komira_encoding smoke: OK"), String("komira_encoding smoke: OK"), True))
    r.validations.append(v^)
    var t = render_result(r.finish_record(String(OUTCOME_SUCCEEDED), 9))
    assert_true(
        t.find(
            String('"validations":[{"channel_url":"","checks":[{"check":"sha256 komira_encoding","expected":"') + String(_H)
            + String('","got":"') + String(_H) + String('","ok":true},')
        ) >= 0,
        t,
    )
    assert_true(t.find(String('"effect":"VALIDATED","environment":"","kind":"CONDA_INSTALL_SMOKE","name":"install-smoke","outcome":"SUCCEEDED","pixi_sha256":"","skip_reason":"","step":"publish"}]')) >= 0, t)
    var p = parse_result(t, String("r.json"))
    assert_equal(render_result(p), t)
    assert_equal(len(p.validations), 1)
    assert_equal(len(p.validations[0].checks), 2)
    assert_true(p.validations[0].checks[1].ok)
    assert_equal(len(p.ignored_keys), 0)
    # a failed validation: the run is VALIDATION_FAILED, exit 7
    var f = _gamma_publish(False)
    var fv = _smoke(String(VALIDATION_VALIDATED), String(OUTCOME_VALIDATION_FAILED))
    fv.checks.append(_check_row(False))
    f.validations.append(fv^)
    f.set_error(String("KCI-E-VALIDATION"), String("install-smoke: sha256 komira_encoding differs"))
    var ff = f.finish_record(String(OUTCOME_VALIDATION_FAILED), 9)
    assert_equal(ff.exit_code, 7)
    assert_equal(render_result(parse_result(render_result(ff), String("r.json"))), render_result(ff))


def _env_row(var outcome: String) -> ResultValidation:
    var v = ResultValidation(
        String("install-env"), String("publish"), String(VALIDATION_KIND_CONDA_INSTALL_ENV), String(VALIDATION_VALIDATED), outcome^
    )
    v.environment = String(VALIDATION_ENVIRONMENT_ENV)
    v.pixi_sha256 = String(_H)
    v.channel_url = String("https://conda.example.invalid/example/gamma")
    return v^


def test_env_row_keys_round_trip() raises:
    var r = _gamma_publish(False)
    var v = _env_row(String(OUTCOME_SUCCEEDED))
    v.checks.append(_check_row(True))
    r.validations.append(v^)
    var t = render_result(r.finish_record(String(OUTCOME_SUCCEEDED), 9))
    assert_true(t.find(String('"channel_url":"https://conda.example.invalid/example/gamma","checks":[')) >= 0, t)
    assert_true(
        t.find(
            String('"effect":"VALIDATED","environment":"ENV","kind":"CONDA_INSTALL_ENV","name":"install-env",')
            + String('"outcome":"SUCCEEDED","pixi_sha256":"') + String(_H) + String('","skip_reason":"","step":"publish"}')
        ) >= 0,
        t,
    )
    var p = parse_result(t, String("r.json"))
    assert_equal(p.validations[0].environment, String("ENV"))
    assert_equal(p.validations[0].pixi_sha256, String(_H))
    assert_equal(p.validations[0].channel_url, String("https://conda.example.invalid/example/gamma"))
    assert_equal(render_result(p), t)
    assert_equal(len(p.ignored_keys), 0)


def test_a_document_written_before_the_env_keys_still_reads() raises:
    # the four keys were added inside major 1: a record without them reads
    # them as "" and is not refused
    var r = _gamma_publish(False)
    var v = _smoke(String(VALIDATION_VALIDATED), String(OUTCOME_SUCCEEDED))
    v.checks.append(_check_row(True))
    r.validations.append(v^)
    var t = render_result(r.finish_record(String(OUTCOME_SUCCEEDED), 9))
    var old = (
        t.replace(String('"channel_url":"",'), String(""))
        .replace(String('"environment":"",'), String(""))
        .replace(String('"pixi_sha256":"",'), String(""))
        .replace(String('"skip_reason":"",'), String(""))
    )
    assert_true(old.find(String("skip_reason")) < 0, old)
    var p = parse_result(old, String("old.json"))
    assert_equal(p.validations[0].skip_reason, String(""))
    assert_equal(p.validations[0].environment, String(""))
    assert_equal(len(p.ignored_keys), 0)


def test_a_skipped_validation_is_indeterminate_exit_5_never_a_pass() raises:
    var r = _gamma_publish(False)
    var v = _env_row(String(OUTCOME_INDETERMINATE))
    v.skip_reason = String("no network: none of the declared hosts answered")
    v.checks.append(_check_row(False))
    r.validations.append(v^)
    r.set_error(String("KCI-E-VALIDATION"), String("validation 'install-env' could not run: no network"))
    var f = r.finish_record(String(OUTCOME_INDETERMINATE), 9)
    assert_equal(f.exit_code, 5)
    var t = render_result(f)
    assert_true(t.find(String('"skip_reason":"no network: none of the declared hosts answered"')) >= 0, t)
    assert_equal(render_result(parse_result(t, String("r.json"))), t)
    # a skip_reason on any other outcome is refused: a skip never reads as a
    # pass nor as a failure
    var s = _gamma_publish(False)
    var sv = _env_row(String(OUTCOME_SUCCEEDED))
    sv.skip_reason = String("no network")
    sv.checks.append(_check_row(True))
    s.validations.append(sv^)
    assert_true(_render_refusal(s).find(String("a skip_reason belongs to a validation that ran and is INDETERMINATE")) >= 0)
    var forged = t.replace(String('"outcome":"INDETERMINATE","pixi_sha256"'), String('"outcome":"VALIDATION_FAILED","pixi_sha256"'))
    assert_true(_refusal(forged).find(String("a skip_reason belongs to a validation that ran and is INDETERMINATE")) >= 0)


def test_env_row_values_are_checked() raises:
    var e = _gamma_publish(False)
    var ev = _env_row(String(OUTCOME_SUCCEEDED))
    ev.environment = String("VM")
    ev.checks.append(_check_row(True))
    e.validations.append(ev^)
    assert_true(_render_refusal(e).find(String("environment 'VM' is not ENV or CONTAINER")) >= 0)
    var h = _gamma_publish(False)
    var hv = _env_row(String(OUTCOME_SUCCEEDED))
    hv.pixi_sha256 = String("ABC")
    hv.checks.append(_check_row(True))
    h.validations.append(hv^)
    assert_true(_render_refusal(h).find(String("pixi_sha256 'ABC' is not 64 lowercase hex characters")) >= 0)
    var n = _gamma_publish(False)
    var nv = _env_row(String(""))
    nv.effect = String(VALIDATION_NOT_REACHED)
    n.validations.append(nv^)
    assert_true(_render_refusal(n).find(String("did not run has no environment and no pixi_sha256")) >= 0)


def test_a_plan_validation_never_reads_as_a_pass() raises:
    var r = _gamma_publish(True)
    r.validations.append(_smoke(String(VALIDATION_WOULD_VALIDATE), String("")))
    var t = render_result(r.finish_record(String(OUTCOME_SUCCEEDED), 9))
    assert_true(t.find(String('"effect":"WOULD_VALIDATE"')) >= 0)
    assert_true(t.find(String('"outcome":"","pixi_sha256":"","skip_reason":"","step":"publish"')) >= 0)
    # WOULD_VALIDATE with an outcome is refused, by the renderer and the parser
    var o = _gamma_publish(True)
    o.validations.append(_smoke(String(VALIDATION_WOULD_VALIDATE), String(OUTCOME_SUCCEEDED)))
    assert_true(_render_refusal(o).find(String("did not run (WOULD_VALIDATE) has no outcome")) >= 0)
    var forged = t.replace(String('"outcome":"","pixi_sha256"'), String('"outcome":"SUCCEEDED","pixi_sha256"'))
    assert_true(_refusal(forged).find(String("did not run (WOULD_VALIDATE) has no outcome")) >= 0)
    # nor checks
    var c = _gamma_publish(True)
    var cv = _smoke(String(VALIDATION_WOULD_VALIDATE), String(""))
    cv.checks.append(_check_row(True))
    c.validations.append(cv^)
    assert_true(_render_refusal(c).find(String("has no checks")) >= 0)
    # a plan validates nothing; WOULD_VALIDATE belongs to a plan
    var pv = _gamma_publish(True)
    var pvv = _smoke(String(VALIDATION_VALIDATED), String(OUTCOME_SUCCEEDED))
    pvv.checks.append(_check_row(True))
    pv.validations.append(pvv^)
    assert_true(_render_refusal(pv).find(String("a --plan run validates nothing")) >= 0)
    var np = _gamma_publish(False)
    np.validations.append(_smoke(String(VALIDATION_WOULD_VALIDATE), String("")))
    assert_true(_render_refusal(np).find(String("WOULD_VALIDATE belongs to a --plan run")) >= 0)


def test_a_succeeded_validation_holds_ok_checks() raises:
    var none = _gamma_publish(False)
    none.validations.append(_smoke(String(VALIDATION_VALIDATED), String(OUTCOME_SUCCEEDED)))
    assert_true(_render_refusal(none).find(String("holds at least one check and every check ok")) >= 0)
    var bad = _gamma_publish(False)
    var bv = _smoke(String(VALIDATION_VALIDATED), String(OUTCOME_SUCCEEDED))
    bv.checks.append(_check_row(True))
    bv.checks.append(_check_row(False))
    bad.validations.append(bv^)
    assert_true(_render_refusal(bad).find(String("holds at least one check and every check ok")) >= 0)
    # not reached: no outcome, no checks
    var nr = _gamma_publish(False)
    nr.validations.append(_smoke(String(VALIDATION_NOT_REACHED), String(OUTCOME_SUCCEEDED)))
    assert_true(_render_refusal(nr).find(String("was not reached has no outcome")) >= 0)
    # a validation names a step of the stage, a known kind and effect, once
    var ns = _gamma_publish(False)
    var nsv = ResultValidation(String("install-smoke"), String("build"), String(VALIDATION_KIND_CONDA_INSTALL_SMOKE), String(VALIDATION_NOT_REACHED), String(""))
    ns.validations.append(nsv^)
    assert_true(_render_refusal(ns).find(String("names step 'build', which is not in steps[]")) >= 0)
    var nk = _gamma_publish(False)
    nk.validations.append(ResultValidation(String("x"), String("publish"), String("SMOKE"), String(VALIDATION_NOT_REACHED), String("")))
    assert_true(_render_refusal(nk).find(String("is not CONDA_INSTALL_SMOKE")) >= 0)
    var ne = _gamma_publish(False)
    ne.validations.append(_smoke(String("SKIPPED"), String("")))
    assert_true(_render_refusal(ne).find(String("effect 'SKIPPED' is not one of")) >= 0)
    var twice = _gamma_publish(False)
    twice.validations.append(_smoke(String(VALIDATION_NOT_REACHED), String("")))
    twice.validations.append(_smoke(String(VALIDATION_NOT_REACHED), String("")))
    assert_true(_render_refusal(twice).find(String("is given twice")) >= 0)


def test_credential_probe() raises:
    var r = _gamma_publish(True)
    r.steps[0].credential_probe = String(CREDENTIAL_PROBE_MINTED)
    var t = render_result(r.finish_record(String(OUTCOME_SUCCEEDED), 9))
    assert_true(t.find(String('"credential_probe":"MINTED"')) >= 0)
    assert_equal(parse_result(t, String("r.json")).steps[0].credential_probe, String("MINTED"))
    # only under --plan, only on a PUBLISH step, only a known word
    var np = _gamma_publish(False)
    np.steps[0].credential_probe = String(CREDENTIAL_PROBE_NOT_UNDER_CI)
    assert_true(_render_refusal(np).find(String("made by a --plan run only")) >= 0)
    var b = _two_step_result()
    b.plan = True
    b.steps.append(ResultStep(String("build"), String(STEP_KIND_BUILD), String("linux-x86_64"), String(OUTCOME_SUCCEEDED)))
    b.steps[0].credential_probe = String(CREDENTIAL_PROBE_MINTED)
    assert_true(_render_refusal(b).find(String("only a PUBLISH step probes its credential")) >= 0)
    var u = _gamma_publish(True)
    u.steps[0].credential_probe = String("PASSED")
    assert_true(_render_refusal(u).find(String("credential_probe 'PASSED' is not one of")) >= 0)


def test_credential_probe_note() raises:
    # NOT_UNDER_CI is said next to the outcome; MINTED, NOT_OIDC and no probe say nothing
    var r = _gamma_publish(True)
    assert_equal(credential_probe_note(r.steps), String(""))
    r.steps[0].credential_probe = String(CREDENTIAL_PROBE_MINTED)
    assert_equal(credential_probe_note(r.steps), String(""))
    r.steps[0].credential_probe = String("NOT_OIDC")
    assert_equal(credential_probe_note(r.steps), String(""))
    r.steps[0].credential_probe = String(CREDENTIAL_PROBE_NOT_UNDER_CI)
    assert_equal(credential_probe_note(r.steps), String("credential probe NOT RUN (not under GitHub Actions)"))


def test_new_names() raises:
    var p = parse_result(_golden(), String("r.json"))
    assert_equal(len(p.new_names), 1)
    assert_equal(p.new_names[0].stage, String("publish-prod"))
    assert_equal(p.new_names[0].channel, String("prod"))
    assert_equal(p.new_names[0].name, String("komira_all"))
    var e = _gamma_publish(False)
    e.new_names.append(ResultNewName(String("publish-gamma"), String("publish"), String("gamma"), String("")))
    assert_true(_render_refusal(e).find(String("are each non-empty")) >= 0)
    var d = _gamma_publish(False)
    d.new_names.append(ResultNewName(String("publish-gamma"), String("publish"), String("gamma"), String("komira_all")))
    d.new_names.append(ResultNewName(String("publish-gamma"), String("publish"), String("gamma"), String("komira_all")))
    assert_true(_render_refusal(d).find(String("'komira_all' is given twice")) >= 0)


def test_workflow() raises:
    # before the check ran
    var r = RunResult(String(VERB_RUN), String(VERB_RUN))
    var t = render_result(r)
    assert_true(t.find(String('"workflow":{"checked":false,"path":"","reason":"not reached","sha":""}')) >= 0, t)
    var g = _golden()
    var p = parse_result(g, String("r.json"))
    assert_true(p.workflow_checked)
    assert_equal(p.workflow_path, String(".github/workflows/kci.yml"))
    assert_equal(p.workflow_sha, String(_REV))
    # a checked workflow names its path and a full sha, and gives no reason
    assert_true(_refusal(g.replace(String('"sha":"') + String(_REV) + String('"}}'), String('"sha":""}}'))).find(String("names its path and sha")) >= 0)
    assert_true(_refusal(g.replace(String('"sha":"') + String(_REV) + String('"}}'), String('"sha":"abc"}}'))).find(String("workflow.sha 'abc' is not a full commit id")) >= 0)
    assert_true(_refusal(g.replace(String('"reason":""'), String('"reason":"x"'))).find(String("a checked workflow has no reason")) >= 0)
    assert_true(_refusal(g.replace(String('"path":".github/workflows/kci.yml"'), String('"path":"ci/kci.yml"'))).find(String("is not a file under .github/workflows/")) >= 0)
    assert_true(_refusal(g.replace(String('"path":".github/workflows/kci.yml"'), String('"path":".github/workflows/../kci.yml"'))).find(String("is not a file under .github/workflows/")) >= 0)
    # not checked: it says why
    var u = RunResult(String(VERB_RUN), String(VERB_RUN))
    u.workflow_reason = String("")
    assert_true(_render_refusal(u).find(String("was not checked says why")) >= 0)


def _record_through[R: RunRecorder](mut rec: R, r: RunResult) raises:
    rec.begin(r.begin_record())


def test_recorder_trait_and_failing_begin() raises:
    var rec = MemoryRecorder()
    _record_through(rec, _publish_result())
    assert_equal(len(rec.records), 1)
    var bad = MemoryRecorder()
    bad.fail_begin = True
    var refused = False
    try:
        _record_through(bad, _publish_result())
    except e:
        refused = True
    assert_true(refused)
    assert_equal(len(bad.records), 0)


def _affected_result() raises -> RunResult:
    """A one-step pr stage run with --affected-by, answered AFFECTED."""
    var r = RunResult(String(VERB_RUN), String(VERB_RUN))
    r.stage = String("pr")
    r.platform = String("linux-x86_64")
    r.stage_step_kinds.append(String(STEP_KIND_BUILD))
    r.scope = String(SCOPE_SELECTIVE)
    r.has_affected_by = True
    r.affected_base = String(_REV)
    r.affected_verdict = String("AFFECTED")
    r.affected_units.append(String("lib_a"))
    r.affected_units.append(String("lints"))
    r.steps.append(ResultStep(String("check"), String(STEP_KIND_BUILD), String("linux-x86_64"), String(OUTCOME_SUCCEEDED)))
    return r^


def test_affected_by_round_trips_and_is_selective() raises:
    var t = render_result(_affected_result().finish_record(String(OUTCOME_SUCCEEDED), 9))
    assert_true(
        t.startswith(
            String('{"affected_by":{"base":"') + String(_REV)
            + String('","reason":"","units":["lib_a","lints"],"verdict":"AFFECTED"},"artifacts":[]')
        ),
        t,
    )
    assert_true(t.find(String('"only":[],')) >= 0)
    assert_true(t.find(String('"scope":"SELECTIVE"')) >= 0)
    var p = parse_result(t, String("r.json"))
    assert_equal(render_result(p), t)
    assert_true(p.has_affected_by)
    assert_equal(p.affected_units[1], String("lints"))
    # WIDENED carries its reason
    var w = _affected_result()
    w.affected_verdict = String("WIDENED")
    w.affected_reason = String("tools/build/mojo/defs.bzl changed")
    var wt = render_result(w)
    assert_true(wt.find(String('"reason":"tools/build/mojo/defs.bzl changed"')) >= 0)
    assert_equal(render_result(parse_result(wt, String("w.json"))), wt)
    # a document without the key reads as no --affected-by
    assert_false(parse_result(_golden(), String("g.json")).has_affected_by)


def test_affected_by_refusals() raises:
    var full = _affected_result()
    full.scope = String("FULL")
    assert_equal(_render_refusal(full), String("result: affected_by: a FULL run has no --affected-by"))
    var short = _affected_result()
    short.affected_base = String("0123456")
    assert_equal(_render_refusal(short), String("result: affected_by: base '0123456' is not a full commit id"))
    var word = _affected_result()
    word.affected_verdict = String("VACUOUS")
    assert_equal(_render_refusal(word), String("result: affected_by: verdict 'VACUOUS' is not AFFECTED, WIDENED or \"\""))
    var why = _affected_result()
    why.affected_reason = String("because")
    assert_equal(_render_refusal(why), String("result: affected_by: a reason comes with WIDENED, and only with it"))
    var bare = _affected_result()
    bare.affected_verdict = String("WIDENED")
    bare.affected_units.clear()
    assert_equal(_render_refusal(bare), String("result: affected_by: a reason comes with WIDENED, and only with it"))
    var early = _affected_result()
    early.affected_verdict = String("")
    assert_equal(_render_refusal(early), String("result: affected_by: units before any answer"))
    var twice = _affected_result()
    twice.affected_units.append(String("lib_a"))
    assert_equal(_render_refusal(twice), String("result: affected_by: unit 'lib_a' is listed twice"))
    # before the answer: no verdict, no units, still SELECTIVE
    var pending = _affected_result()
    pending.affected_verdict = String("")
    pending.affected_units.clear()
    assert_equal(_render_refusal(pending), String("<rendered>"))
    # without affected_by and without --only, SELECTIVE is refused
    var none = _affected_result()
    none.has_affected_by = False
    assert_true(_render_refusal(none).find(String("a SELECTIVE run names its --only selectors or its --affected-by")) >= 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
