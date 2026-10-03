# =============================================================================
# src/kci_contract/tests/test_result_document.mojo
#   The result document: a byte-exact golden, render/parse round trips, the
#   RUNNING-then-FINISHED records, unknown keys ignored, every refusal, and
#   the FULL / SELECTIVE scope (a selective run never reads as a full one).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_contract import (
    ARTIFACT_ALREADY_PRESENT,
    ARTIFACT_WOULD_BUILD,
    ContextEntry,
    ERROR_PUBLISH_READ_BACK,
    ERROR_SELECTOR,
    ERROR_SELECTOR_NO_MATCH,
    ERROR_USAGE,
    MemoryRecorder,
    OUTCOME_NOOP,
    OUTCOME_PARTIAL,
    OUTCOME_REFUSED,
    OUTCOME_SUCCEEDED,
    RETRY_NEEDS_HUMAN,
    RETRY_SAFE,
    ResultArtifact,
    ResultStep,
    RunIdentity,
    RunRecorder,
    RunResult,
    SCOPE_SELECTIVE,
    STEP_KIND_BUILD,
    STEP_KIND_PUBLISH,
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
    r.stage = String("prod")
    r.stage_step_kinds.append(String(STEP_KIND_PUBLISH))
    r.revision = String(_REV)
    r.platform = String("linux-x86_64")
    r.started_at_ms = 1000
    r.channel = String("komira")
    r.set_hash = String(_H)
    r.expect_set_hash = String(_H)
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
        + String('"attempt":2,"channel":"komira","context":{"event":"push","actor_id":"42"},')
        + String('"exit_code":0,"expect_set_hash":"') + String(_H) + String('","finished_at_ms":2000,')
        + String('"format":"kci.result","invoked_as":"run","kci_version":"0.0.0-unreleased",')
        + String('"machine":{"path":"release/machine.textproto","sha256":"') + String(_H) + String('"},')
        + String('"only":[],"outcome":"NOOP","plan":false,"platform":"linux-x86_64",')
        + String('"release_produced_by":{"attempt":1,"run_id":"gh-6"},')
        + String('"retry":"SAFE","revision":"') + String(_REV) + String('","run_id":"gh-7","schema_version":1,')
        + String('"scope":"FULL","set_hash":"') + String(_H) + String('","stage":"prod","stage_step_kinds":["PUBLISH"],')
        + String('"started_at_ms":1000,"status":"FINISHED",')
        + String('"steps":[{"kind":"PUBLISH","name":"publish","outcome":"NOOP","platform":"linux-x86_64","selected":true}],')
        + String('"verb":"run"}\n')
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
    var t = g.replace(String('"verb":"run"}'), String('"verb":"run","landed":[]}'))
    t = t.replace(String('"indexed":true,'), String('"indexed":true,"later":1,'))
    var p = parse_result(t, String("r.json"))
    assert_equal(len(p.ignored_keys), 2)
    assert_equal(p.ignored_keys[0], String("landed"))
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
    # `build`, `publish`, `stages` are not verbs any more: only run and ci-check
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
    assert_true(_refusal(g.replace(String('"verb":"run"}'), String('"verb":"run","verb":"run"}'))).find(String("'verb' is given twice")) >= 0)
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
        t.find(String('{"kind":"BUILD","name":"build","outcome":"","platform":"linux-x86_64","selected":false}')) >= 0
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
    # the pre-v1.3 names: unknown keys now, ignored and never read
    var g = _golden()
    var t = g.replace(
        String('"verb":"run"}'),
        String('"verb":"run","actions":[],"stage_action_kinds":["BUILD"],"dry_run":true}'),
    )
    t = t.replace(String('"indexed":true,'), String('"indexed":true,"action":"BUILT",'))
    var p = parse_result(t, String("r.json"))
    assert_equal(len(p.ignored_keys), 4)
    assert_false(p.plan)
    assert_equal(len(p.stage_step_kinds), 1)
    assert_equal(p.stage_step_kinds[0], String("PUBLISH"))
    assert_equal(p.artifacts[0].effect, String("ALREADY_PRESENT"))
    assert_equal(render_result(p), g)


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
