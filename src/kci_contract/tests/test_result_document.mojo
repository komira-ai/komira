# =============================================================================
# src/kci_contract/tests/test_result_document.mojo
#   The result document: a byte-exact golden, render/parse round trips, the
#   RUNNING-then-FINISHED records, unknown keys ignored, every refusal.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_contract import (
    ACTION_PUBLISH,
    ARTIFACT_ALREADY_PRESENT,
    ContextEntry,
    ERROR_PUBLISH_READ_BACK,
    ERROR_STAGE_KIND,
    ERROR_USAGE,
    MemoryRecorder,
    OUTCOME_NOOP,
    OUTCOME_PARTIAL,
    OUTCOME_REFUSED,
    OUTCOME_SUCCEEDED,
    RETRY_NEEDS_HUMAN,
    RETRY_SAFE,
    ResultAction,
    ResultArtifact,
    RunIdentity,
    RunRecorder,
    RunResult,
    VERB_PUBLISH,
    VERB_RUN,
    parse_result,
    render_result,
    reserved_result_keys,
)

comptime _REV = "0123456789abcdef0123456789abcdef01234567"
comptime _H = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"


def _publish_result() raises -> RunResult:
    var r = RunResult(String(VERB_PUBLISH), String(VERB_PUBLISH))
    var run = RunIdentity(String("gh-7"), 2)
    run.add_context(ContextEntry(String("event"), String("push")))
    run.add_context(ContextEntry(String("actor_id"), String("42")))
    r.set_run(run)
    r.machine_path = String("release/machine.textproto")
    r.machine_sha256 = String(_H)
    r.stage = String("prod")
    r.stage_action_kinds.append(String(ACTION_PUBLISH))
    r.revision = String(_REV)
    r.platform = String("linux-x86_64")
    r.started_at_ms = 1000
    r.channel = String("komira")
    r.set_hash = String(_H)
    r.expect_set_hash = String(_H)
    r.has_release_produced_by = True
    r.release_produced_by_run_id = String("gh-6")
    r.release_produced_by_attempt = 1
    r.actions.append(ResultAction(String(ACTION_PUBLISH), String("linux-x86_64"), String(OUTCOME_NOOP)))
    var a = ResultArtifact()
    a.action = String(ARTIFACT_ALREADY_PRESENT)
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
        String('{"actions":[{"kind":"PUBLISH","outcome":"NOOP","platform":"linux-x86_64"}],')
        + String('"artifacts":[{"action":"ALREADY_PRESENT","artifact_type":"CONDA","build":"0",')
        + String('"file":"linux-64/komira-0.1.7-0.conda","indexed":true,"name":"komira",')
        + String('"platform":"linux-x86_64","revision":"') + String(_REV) + String('","sha256":"') + String(_H)
        + String('","state_after":"PRESENT_SAME","state_before":"PRESENT_SAME","subdir":"linux-64","version":"0.1.7"}],')
        + String('"attempt":2,"channel":"komira","context":{"event":"push","actor_id":"42"},"dry_run":false,')
        + String('"exit_code":0,"expect_set_hash":"') + String(_H) + String('","finished_at_ms":2000,')
        + String('"format":"kci.result","invoked_as":"publish","kci_version":"0.0.0-unreleased",')
        + String('"machine":{"path":"release/machine.textproto","sha256":"') + String(_H) + String('"},')
        + String('"outcome":"NOOP","platform":"linux-x86_64","release_produced_by":{"attempt":1,"run_id":"gh-6"},')
        + String('"retry":"SAFE","revision":"') + String(_REV) + String('","run_id":"gh-7","schema_version":1,')
        + String('"set_hash":"') + String(_H) + String('","stage":"prod","stage_action_kinds":["PUBLISH"],')
        + String('"started_at_ms":1000,"status":"FINISHED","verb":"publish"}\n')
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
    var u = RunResult(String(VERB_RUN), String("build"))
    u.set_error(String(ERROR_USAGE), String("--attempt is required"))
    # the first error stays
    u.set_error(String(ERROR_STAGE_KIND), String("later"))
    var f = u.finish_record(String(OUTCOME_REFUSED), 5)
    assert_equal(f.exit_code, 2)
    assert_equal(f.error.id, String(ERROR_USAGE))
    var k = RunResult(String(VERB_RUN), String("build"))
    k.set_error(String(ERROR_STAGE_KIND), String("stage prod holds PUBLISH"))
    assert_equal(k.finish_record(String(OUTCOME_REFUSED), 5).exit_code, 3)
    var p = RunResult(String(VERB_PUBLISH), String("publish"))
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
    var t = g.replace(String('"verb":"publish"}'), String('"verb":"publish","landed":[]}'))
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
    assert_true(_refusal(g.replace(String('"format":"kci.result"'), String('"format":"kci.stages"'))).find(String("is not 'kci.result'")) >= 0)
    assert_true(_refusal(g.replace(String('"exit_code":0'), String('"exit_code":6'))).find(String("exit_code 6 is not 0")) >= 0)
    assert_true(_refusal(g.replace(String('"outcome":"NOOP","platform":"linux-x86_64","release'), String('"outcome":"DONE","platform":"linux-x86_64","release'))).find(String("is not one of")) >= 0)
    assert_true(_refusal(g.replace(String('"status":"FINISHED"'), String('"status":"RUNNING"'))).find(String("a RUNNING record says INTERRUPTED")) >= 0)
    assert_true(_refusal(g.replace(String('"status":"FINISHED"'), String('"status":"DONE"'))).find(String("is not RUNNING or FINISHED")) >= 0)
    assert_true(_refusal(g.replace(String('"verb":"publish"'), String('"verb":"deploy"'))).find(String("is not a kci verb")) >= 0)
    assert_true(_refusal(g.replace(String('"stage_action_kinds":["PUBLISH"]'), String('"stage_action_kinds":["SHIP"]'))).find(String("is not BUILD, PUBLISH or DEPLOY")) >= 0)
    assert_true(_refusal(g.replace(String('"action":"ALREADY_PRESENT"'), String('"action":"none"'))).find(String("action 'none' is not one of")) >= 0)
    assert_true(_refusal(g.replace(String('"run_id":"gh-7"'), String('"run_id":7'))).find(String("'run_id' has the wrong JSON type")) >= 0)
    assert_true(_refusal(g.replace(String('"dry_run":false,'), String(''))).find(String("missing 'dry_run'")) >= 0)
    assert_true(_refusal(g.replace(String('"retry":"SAFE"'), String('"retry":"MAYBE"'))).find(String("retry 'MAYBE' is not one of")) >= 0)
    assert_true(_refusal(g.replace(String('"revision":"0123'), String('"revision":"X123'))).find(String("is not a full commit id")) >= 0)
    assert_true(_refusal(g.replace(String('"platform":"linux-x86_64","release'), String('"platform":"amiga","release'))).find(String("platform 'amiga' is not one of")) >= 0)
    assert_true(_refusal(g.replace(String('"verb":"publish"}'), String('"verb":"publish","verb":"run"}'))).find(String("'verb' is given twice")) >= 0)
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
