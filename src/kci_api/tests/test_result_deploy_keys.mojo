# =============================================================================
# src/kci_api/tests/test_result_deploy_keys.mojo
#   The deploy keys of a step row (result_deploy.mojo): every key round-trips
#   byte for byte, a row without a cell reads as before, an absent key reads
#   as empty, and each refusal: a landed node under an outcome that promises
#   nothing landed (FAILED, REFUSED), a deploy key at the top level (refused,
#   never ignored), a deploy value without a cell, a cell without a cloud, a
#   plan_hash that is not sha256 hex.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_api import (
    OUTCOME_FAILED,
    OUTCOME_PARTIAL,
    OUTCOME_REFUSED,
    OUTCOME_SUCCEEDED,
    ResultDeploy,
    ResultFailedNode,
    ResultLanded,
    ResultOutput,
    ResultStep,
    RunResult,
    STEP_KIND_BUILD,
    STEP_KIND_DEPLOY,
    VERB_RUN,
    deploy_step_keys,
    parse_result,
    render_result,
)

comptime _H = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"


def _stage(var step: ResultStep) raises -> RunResult:
    var r = RunResult(String(VERB_RUN), String(VERB_RUN))
    r.stage = String("deploy-gamma")
    r.stage_step_kinds.append(step.kind.copy())
    r.started_at_ms = 10
    r.steps.append(step^)
    return r^


def _full_deploy() -> ResultDeploy:
    """Every deploy key holding a value: an apply that stopped at api/svc."""
    var d = ResultDeploy()
    d.cell = String("gamma-1")
    d.cloud = String("gcp")
    d.landed.append(ResultLanded(String("runner/account"), String("CREATE")))
    d.landed.append(ResultLanded(String("store/bucket"), String("UPDATE")))
    d.pending.append(String("api/svc"))
    d.pending.append(String("api/public"))
    d.has_failed = True
    d.failed = ResultFailedNode(String("api/svc"), String("CREATE"), String("CLOUD"), String("wait timed out"))
    d.outputs.append(ResultOutput(String("store"), String("NAME"), String("store-1")))
    d.plan_hash = String(_H)
    d.leftover.append(String("old/svc"))
    d.left_behind.append(String("logs/bucket"))
    d.released.append(String("legacy/account"))
    return d^


def _deploy_step(var outcome: String, var d: ResultDeploy) -> ResultStep:
    var s = ResultStep(String("deploy"), String(STEP_KIND_DEPLOY), String(""), outcome^)
    s.deploy = d^
    return s^


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


def test_every_step_row_key_round_trips() raises:
    var r = _stage(_deploy_step(String(OUTCOME_PARTIAL), _full_deploy()))
    var t = render_result(r.finish_record(String(OUTCOME_PARTIAL), 20))
    # the whole row, byte for byte: keys sorted, inner objects' keys sorted
    var row = (
        String('"steps":[{"cell":"gamma-1","cloud":"gcp","credential_probe":"",')
        + String('"failed":{"fault_domain":"CLOUD","message":"wait timed out","node":"api/svc","verb":"CREATE"},')
        + String('"kind":"DEPLOY",')
        + String('"landed":[{"node":"runner/account","verb":"CREATE"},{"node":"store/bucket","verb":"UPDATE"}],')
        + String('"left_behind":["logs/bucket"],"leftover":["old/svc"],"name":"deploy","outcome":"PARTIAL",')
        + String('"outputs":[{"output":"NAME","resource":"store","value":"store-1"}],')
        + String('"pending":["api/svc","api/public"],"plan_hash":"') + String(_H) + String('",')
        + String('"platform":"","released":["legacy/account"],"selected":true}]')
    )
    assert_true(t.find(row) >= 0, t)
    var p = parse_result(t, String("r.json"))
    assert_equal(len(p.ignored_keys), 0)
    assert_equal(render_result(p), t)
    ref d = p.steps[0].deploy
    assert_equal(d.cell, String("gamma-1"))
    assert_equal(d.cloud, String("gcp"))
    assert_equal(len(d.landed), 2)
    assert_equal(d.landed[1].node, String("store/bucket"))
    assert_equal(d.landed[1].verb, String("UPDATE"))
    assert_equal(len(d.pending), 2)
    assert_equal(d.pending[0], String("api/svc"))
    assert_true(d.has_failed)
    assert_equal(d.failed.node, String("api/svc"))
    assert_equal(d.failed.verb, String("CREATE"))
    assert_equal(d.failed.fault_domain, String("CLOUD"))
    assert_equal(d.failed.message, String("wait timed out"))
    assert_equal(len(d.outputs), 1)
    assert_equal(d.outputs[0].resource, String("store"))
    assert_equal(d.outputs[0].output, String("NAME"))
    assert_equal(d.outputs[0].value, String("store-1"))
    assert_equal(d.plan_hash, String(_H))
    assert_equal(d.leftover[0], String("old/svc"))
    assert_equal(d.left_behind[0], String("logs/bucket"))
    assert_equal(d.released[0], String("legacy/account"))
    # every key the table names is on the row
    var keys = deploy_step_keys()
    assert_equal(len(keys), 10)
    for i in range(len(keys)):
        assert_true(t.find(String('"') + keys[i] + String('":')) >= 0, keys[i])


def test_a_plan_row_with_only_a_cell_round_trips() raises:
    # --plan: nothing landed, failed ABSENT, the plan's hash and its reports
    var d = ResultDeploy()
    d.cell = String("gamma-1")
    d.cloud = String("aws")
    d.plan_hash = String(_H)
    d.leftover.append(String("old/svc"))
    var r = _stage(_deploy_step(String(OUTCOME_SUCCEEDED), d^))
    r.plan = True
    var t = render_result(r.finish_record(String(OUTCOME_SUCCEEDED), 20))
    assert_equal(t.find(String('"failed"')), -1)
    assert_true(t.find(String('"landed":[],')) >= 0)
    var p = parse_result(t, String("r.json"))
    assert_false(p.steps[0].deploy.has_failed)
    assert_equal(render_result(p), t)


def test_a_row_without_a_cell_reads_as_before() raises:
    var r = _stage(ResultStep(String("build"), String(STEP_KIND_BUILD), String("linux-x86_64"), String(OUTCOME_SUCCEEDED)))
    var t = render_result(r.finish_record(String(OUTCOME_SUCCEEDED), 20))
    # no deploy key is written for it
    assert_true(
        t.find(String('"steps":[{"credential_probe":"","kind":"BUILD","name":"build","outcome":"SUCCEEDED","platform":"linux-x86_64","selected":true}]')) >= 0,
        t,
    )
    var keys = deploy_step_keys()
    for i in range(len(keys)):
        assert_equal(t.find(String('"') + keys[i] + String('"')), -1)
    var p = parse_result(t, String("r.json"))
    assert_equal(p.steps[0].deploy.cell, String(""))
    assert_false(p.steps[0].deploy.holds_a_value())


def test_an_absent_key_reads_as_empty_and_an_unknown_inner_key_is_ignored() raises:
    var d = ResultDeploy()
    d.cell = String("gamma-1")
    d.cloud = String("gcp")
    d.landed.append(ResultLanded(String("runner/account"), String("CREATE")))
    var t = render_result(_stage(_deploy_step(String(OUTCOME_SUCCEEDED), d^)).finish_record(String(OUTCOME_SUCCEEDED), 20))
    # a writer that knew only cell, cloud and landed
    var old = t.replace(String('"left_behind":[],"leftover":[],'), String('')).replace(
        String('"outputs":[],"pending":[],"plan_hash":"",'), String('')
    ).replace(String(',"released":[]'), String(''))
    assert_true(old.find(String('"pending"')) == -1 and old.find(String('"released"')) == -1, old)
    var p = parse_result(old, String("r.json"))
    assert_equal(len(p.ignored_keys), 0)
    assert_equal(render_result(p), t)
    # an unknown key inside a landed row, and the reserved name on the row,
    # are ignored keys
    var later = t.replace(String('"verb":"CREATE"}'), String('"verb":"CREATE","later":1}')).replace(
        String('"cell":"gamma-1",'), String('"cell":"gamma-1","security_relevant_changes":[],')
    )
    var q = parse_result(later, String("r.json"))
    assert_equal(len(q.ignored_keys), 2)
    assert_equal(q.ignored_keys[0], String("steps[0].security_relevant_changes"))
    assert_equal(q.ignored_keys[1], String("steps[0].landed[0].later"))


def _failed_row_text() raises -> String:
    """A valid FINISHED document whose DEPLOY step FAILED with nothing landed."""
    var d = ResultDeploy()
    d.cell = String("gamma-1")
    d.cloud = String("gcp")
    var t = render_result(_stage(_deploy_step(String(OUTCOME_FAILED), d^)).finish_record(String(OUTCOME_FAILED), 20))
    assert_true(t.find(String('"exit_code":4,')) >= 0, t)
    assert_true(t.find(String('"status":"FINISHED"')) >= 0, t)
    return t^


def test_a_failed_step_row_with_landed_is_refused() raises:
    var t = _failed_row_text()
    _ = parse_result(t, String("r.json"))
    var forged = t.replace(String('"landed":[]'), String('"landed":[{"node":"runner/account","verb":"CREATE"}]'))
    assert_true(forged != t)
    assert_equal(
        _refusal(forged),
        String("result 'r.json': result: steps[0] 'deploy': outcome FAILED (exit 4) says no effect landed,")
        + String(" yet landed lists 1 node(s), the first 'runner/account'"),
    )
    # and the renderer refuses the same row
    var d = ResultDeploy()
    d.cell = String("gamma-1")
    d.cloud = String("gcp")
    d.landed.append(ResultLanded(String("runner/account"), String("CREATE")))
    var r = _stage(_deploy_step(String(OUTCOME_FAILED), d^))
    var f = r.finish_record(String(OUTCOME_FAILED), 20)
    assert_true(_render_refusal(f).find(String("outcome FAILED (exit 4) says no effect landed")) >= 0)


def test_a_refused_step_row_with_landed_is_refused() raises:
    var d = ResultDeploy()
    d.cell = String("gamma-1")
    d.cloud = String("gcp")
    d.landed.append(ResultLanded(String("runner/account"), String("CREATE")))
    var r = _stage(_deploy_step(String(OUTCOME_REFUSED), d.copy()))
    assert_true(_render_refusal(r.finish_record(String(OUTCOME_REFUSED), 20)).find(String("outcome REFUSED (exit 3) says no effect landed")) >= 0)
    # PARTIAL is where a landed node belongs
    var ok = _stage(_deploy_step(String(OUTCOME_PARTIAL), d^))
    assert_equal(_render_refusal(ok.finish_record(String(OUTCOME_PARTIAL), 20)), String("<rendered>"))


def test_a_top_level_landed_is_refused_not_ignored() raises:
    var t = _failed_row_text()
    var forged = t.replace(String('"verb":"run",'), String('"verb":"run","landed":[{"node":"runner/account","verb":"CREATE"}],'))
    assert_true(forged != t)
    assert_equal(
        _refusal(forged),
        String("result 'r.json': 'landed' is a key of a step row (steps[].landed), never of the document:")
        + String(" a stage can deploy into several cells"),
    )
    # every deploy key, even an empty one
    var keys = deploy_step_keys()
    for i in range(len(keys)):
        var f = t.replace(String('"verb":"run",'), String('"verb":"run","') + keys[i] + String('":[],'))
        assert_true(_refusal(f).find(String("'") + keys[i] + String("' is a key of a step row")) >= 0, keys[i])


def test_deploy_values_need_a_cell_and_a_cell_needs_its_cloud() raises:
    var no_cell = ResultDeploy()
    no_cell.leftover.append(String("old/svc"))
    assert_equal(
        _render_refusal(_stage(_deploy_step(String(OUTCOME_SUCCEEDED), no_cell^))),
        String("result: steps[0] 'deploy': the deploy keys belong to a step that names its cell (cell is EMPTY)"),
    )
    var cloud_only = ResultDeploy()
    cloud_only.cloud = String("gcp")
    assert_true(
        _render_refusal(_stage(_deploy_step(String(OUTCOME_SUCCEEDED), cloud_only^))).find(String("(cell is EMPTY)")) >= 0
    )
    var no_cloud = ResultDeploy()
    no_cloud.cell = String("gamma-1")
    assert_equal(
        _render_refusal(_stage(_deploy_step(String(OUTCOME_SUCCEEDED), no_cloud^))),
        String("result: steps[0] 'deploy': a step that names its cell names its cloud (cloud is EMPTY)"),
    )
    # the parser refuses a forged row the same way
    var t = _failed_row_text()
    assert_true(_refusal(t.replace(String('"cell":"gamma-1",'), String('"cell":"",'))).find(String("(cell is EMPTY)")) >= 0)


def test_plan_hash_is_sha256_hex() raises:
    var d = ResultDeploy()
    d.cell = String("gamma-1")
    d.cloud = String("gcp")
    d.plan_hash = String(_H).replace(String("b"), String("B"))
    assert_true(
        _render_refusal(_stage(_deploy_step(String(OUTCOME_SUCCEEDED), d^))).find(String("is not 64 lowercase hex characters")) >= 0
    )


def test_a_deploy_value_of_the_wrong_json_type_is_refused() raises:
    var t = render_result(_stage(_deploy_step(String(OUTCOME_PARTIAL), _full_deploy())).finish_record(String(OUTCOME_PARTIAL), 20))
    assert_equal(_refusal(t), String("<parsed>"))
    # each list of node ids, at its second element
    var ids = List[String]()
    ids.append(String('"pending":["api/svc","api/public"]|"pending":["api/svc",1]|pending[1]'))
    ids.append(String('"leftover":["old/svc"]|"leftover":["old/svc",true]|leftover[1]'))
    ids.append(String('"left_behind":["logs/bucket"]|"left_behind":["logs/bucket",{}]|left_behind[1]'))
    ids.append(String('"released":["legacy/account"]|"released":["legacy/account",null]|released[1]'))
    for i in range(len(ids)):
        var parts = ids[i].split(String("|"))
        var old = String(parts[0])
        assert_equal(t.count(old), 1, old)
        assert_equal(
            _refusal(t.replace(old, String(parts[1]))),
            String("result 'r.json': steps[0]: ") + String(parts[2]) + String(" is not a string"),
        )
    # each list of objects, at its second element
    var landed = String('"landed":[{"node":"runner/account","verb":"CREATE"},')
    assert_equal(t.count(landed), 1)
    assert_equal(
        _refusal(t.replace(landed, landed + String('"x",'))),
        String("result 'r.json': steps[0]: landed[1]: not an object"),
    )
    var outputs = String('"outputs":[')
    assert_equal(t.count(outputs), 1)
    assert_equal(
        _refusal(t.replace(outputs, outputs + String('{"output":"A","resource":"r","value":"v"},2,'))),
        String("result 'r.json': steps[0]: outputs[1]: not an object"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
