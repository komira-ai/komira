# =============================================================================
# test_runner.mojo: the scenario runner reports every way a decision point
# can answer wrongly, so a green scenario table is not vacuous.
# =============================================================================
#
# `ScriptedPdp` is a `PdpEndpoint` that answers every request with one fixed
# reply. Each test hands the runner a scenario the scripted reply breaks in
# one way and asserts that the report names it:
#   - a wrong status, a wrong reason (only with `check_reasons`);
#   - a 200 without `Cache-Control: no-store`;
#   - a decision that differs, too many or too few batch decisions, and the
#     batch's decisions in the wrong order;
#   - a `decision` that is not a top-level JSON boolean (nested inside
#     another member, a string, absent), read as unreadable;
#   - any token the step sent echoed in the body or a header;
#   - a template naming a token the caller did not supply, an unclosed
#     `<<`, a revoke that finds no rule, an allow that raises.
# And the control: the matching reply gives an empty report.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_test_pdp import (
    STEP_ALLOW,
    STEP_REVOKE,
    NamedToken,
    PdpEndpoint,
    PdpReply,
    PdpScenario,
    PdpStep,
    PolicyRule,
    read_decisions,
    resolve_template,
    run_scenario,
)


struct ScriptedPdp(PdpEndpoint, Movable, Deinitable):
    var reply: PdpReply
    var allow_raises: Bool
    var revoke_finds: Bool

    def __init__(out self, var reply: PdpReply):
        self.reply = reply^
        self.allow_raises = False
        self.revoke_finds = True

    def handle(
        mut self,
        method: String,
        path: String,
        authorization: Optional[String],
        body: List[UInt8],
    ) -> PdpReply:
        return self.reply.copy()

    def allow(mut self, rule: PolicyRule) raises:
        if self.allow_raises:
            raise Error("allow refused")

    def revoke(mut self, rule: PolicyRule) raises -> Bool:
        return self.revoke_finds


def _tokens() -> List[NamedToken]:
    var out = List[NamedToken]()
    out.append(NamedToken("b", "BEARERTOKEN"))
    out.append(NamedToken("s", "SUBJECTTOKEN"))
    return out^


def _bools(*values: Bool) -> List[Bool]:
    var out = List[Bool]()
    for i in range(len(values)):
        out.append(values[i])
    return out^


def _scenario(
    want_status: Int, var want: List[Bool], path: String = "/access/v1/evaluation"
) -> PdpScenario:
    var steps = List[PdpStep]()
    steps.append(
        PdpStep(
            method=String("POST"),
            path=path,
            send_authorization=True,
            authorization=String("Bearer <<b>>"),
            body=String('{"t":"<<s>>"}'),
            want_status=want_status,
            want_decisions=want^,
            want_reason=String("decided"),
        )
    )
    return PdpScenario("s", steps^)


def _report(
    var reply: PdpReply, var scenario: PdpScenario, check_reasons: Bool = True
) -> String:
    var pdp = ScriptedPdp(reply^)
    return run_scenario(pdp, scenario, _tokens(), check_reasons)


def _ok(body: String, reason: String = "decided") -> PdpReply:
    return PdpReply(200, body, reason, cache_control=String("no-store"))


def test_control_is_clean() raises:
    assert_equal(_report(_ok('{"decision":true}'), _scenario(200, _bools(True))), String(""))
    assert_equal(
        _report(
            _ok('{"evaluations":[{"decision":true},{"decision":false}]}'),
            _scenario(200, _bools(True, False), "/access/v1/evaluations"),
        ),
        String(""),
    )


def test_status_and_reason() raises:
    var r = _report(PdpReply(403, "{}", "decided"), _scenario(200, _bools(True)))
    assert_true(r.find("status 403 want 200") >= 0, r)
    r = _report(_ok('{"decision":true}', "other"), _scenario(200, _bools(True)))
    assert_true(r.find("reason other want decided") >= 0, r)
    # Without check_reasons the reason is not compared.
    r = _report(_ok('{"decision":true}', "other"), _scenario(200, _bools(True)), False)
    assert_equal(r, String(""))


def test_cache_control() raises:
    var r = _report(PdpReply(200, '{"decision":true}', "decided"), _scenario(200, _bools(True)))
    assert_true(r.find("no Cache-Control") >= 0, r)
    r = _report(
        PdpReply(200, '{"decision":true}', "decided", cache_control=String("no-cache")),
        _scenario(200, _bools(True)),
    )
    assert_true(r.find("no Cache-Control") >= 0, r)


def test_decisions() raises:
    var r = _report(_ok('{"decision":false}'), _scenario(200, _bools(True)))
    assert_true(r.find("decisions [false] want [true]") >= 0, r)
    var batch = String("/access/v1/evaluations")
    r = _report(_ok('{"evaluations":[{"decision":true}]}'), _scenario(200, _bools(True, False), batch))
    assert_true(r.find("decisions [true] want [true,false]") >= 0, r)
    r = _report(
        _ok('{"evaluations":[{"decision":true},{"decision":false},{"decision":false}]}'),
        _scenario(200, _bools(True, False), batch),
    )
    assert_true(r.find("want [true,false]") >= 0, r)
    r = _report(
        _ok('{"evaluations":[{"decision":false},{"decision":true}]}'),
        _scenario(200, _bools(True, False), batch),
    )
    assert_true(r.find("decisions [false,true] want [true,false]") >= 0, r)
    # The last decision differs.
    r = _report(
        _ok('{"evaluations":[{"decision":true},{"decision":true}]}'),
        _scenario(200, _bools(True, False), batch),
    )
    assert_true(r.find("decisions [true,true] want [true,false]") >= 0, r)


def test_unreadable_decisions() raises:
    var bad = List[String]()
    bad.append(String('{"x":{"decision":true}}'))
    bad.append(String('{"decisions":true}'))
    bad.append(String('{"decision":"true"}'))
    bad.append(String('{"decision":1}'))
    bad.append(String("[true]"))
    bad.append(String("{"))
    for i in range(len(bad)):
        var r = _report(_ok(bad[i]), _scenario(200, _bools(True)))
        assert_true(r.find("unreadable decision body") >= 0, bad[i] + ": " + r)
    var batch = String("/access/v1/evaluations")
    var bad_batch = List[String]()
    bad_batch.append(String('{"decision":true}'))
    bad_batch.append(String('{"evaluations":{"decision":true}}'))
    bad_batch.append(String('{"evaluations":[{"decision":true},{"x":true}]}'))
    bad_batch.append(String('{"evaluations":[{"decision":true},{"decision":"false"}]}'))
    bad_batch.append(String('{"evaluations":[{"decision":true},true]}'))
    for i in range(len(bad_batch)):
        var r = _report(_ok(bad_batch[i]), _scenario(200, _bools(True, False), batch))
        assert_true(r.find("unreadable decision body") >= 0, bad_batch[i] + ": " + r)
    # Read directly: the top-level boolean is what counts.
    var d = read_decisions('{"decision":false,"x":{"decision":true}}', False)
    assert_true(Bool(d))
    assert_equal(len(d.value()), 1)
    assert_true(not d.value()[0])


def test_leaks() raises:
    var r = _report(_ok('{"decision":true,"t":"SUBJECTTOKEN"}'), _scenario(200, _bools(True)))
    assert_true(r.find("a token in the reply") >= 0, r)
    r = _report(PdpReply(401, "{}", "decided", www_authenticate=String("Bearer BEARERTOKEN")), _scenario(401, _bools()))
    assert_true(r.find("a token in the reply") >= 0, r)
    r = _report(
        PdpReply(200, '{"decision":true}', "decided", cache_control=String("no-store BEARERTOKEN")),
        _scenario(200, _bools(True)),
    )
    assert_true(r.find("a token in the reply") >= 0, r)


def test_templates_and_policy_steps() raises:
    var toks = _tokens()
    assert_equal(resolve_template("a<<b>>c<<s>>", toks), String("aBEARERTOKENcSUBJECTTOKEN"))
    assert_equal(resolve_template("no templates", toks), String("no templates"))
    var raised = False
    try:
        _ = resolve_template("<<x>>", toks)
    except:
        raised = True
    assert_true(raised, "unknown token name accepted")
    raised = False
    try:
        _ = resolve_template("<<b", toks)
    except:
        raised = True
    assert_true(raised, "unclosed template accepted")

    var steps = List[PdpStep]()
    steps.append(PdpStep(STEP_REVOKE, PolicyRule("a", "b", "c", "d", "e")))
    var pdp = ScriptedPdp(_ok("{}"))
    pdp.revoke_finds = False
    var r = run_scenario(pdp, PdpScenario("s", steps.copy()), toks, True)
    assert_true(r.find("revoke found no rule") >= 0, r)
    steps.append(PdpStep(STEP_ALLOW, PolicyRule("a", "b", "c", "d", "e")))
    pdp.revoke_finds = True
    pdp.allow_raises = True
    r = run_scenario(pdp, PdpScenario("s", steps^), toks, True)
    assert_true(r.find("allow refused") >= 0, r)
    var bad = _scenario(200, _bools(True))
    bad.steps[0].body = String("<<nobody>>")
    r = _report(_ok('{"decision":true}'), bad^)
    assert_true(r.find("no token supplied for <<nobody>>") >= 0, r)


def main() raises:
    test_control_is_clean()
    test_status_and_reason()
    test_cache_control()
    test_decisions()
    test_unreadable_decisions()
    test_leaks()
    test_templates_and_policy_steps()
    print("PASS komira_test_pdp test_runner")
