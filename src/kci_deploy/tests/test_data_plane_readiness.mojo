# =============================================================================
# test_data_plane_readiness -- the data-plane readiness wait.
#
# A control-plane IAM read-back answers GRANTED immediately after the write,
# while the data plane that authorizes the gateway's hop converges on its own
# schedule. These cases drive `await_data_plane_ready` over a scripted probe:
# a transient 403 is waited out, a 404 or 401 is ready (the hop happened), a
# permanent refusal ends on budget, an unreachable host is waited out and then
# reported, a SINGLE_PATH edge has no safe probe and is SKIPPED, and a
# CATCH_ALL edge probes a path nothing serves.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from kci_deploy import (
    DataPlaneProbe,
    DataPlaneReadiness,
    await_data_plane_ready,
    edge_readiness_probe_url,
    is_invoker_refusal,
    is_data_plane_ready,
    DATA_PLANE_UNREACHABLE,
    EDGE_READINESS_PATH,
    PollBudget,
    CaptureReporter,
)


comptime _ORIGIN: String = "https://example-api-edge-abc123.uc.gateway.dev"
comptime _CLIENT_SUFFIX: String = "-client-edge"
comptime _INBOUND_SUFFIX: String = "-inbound-edge"


struct _ScriptedProbe(DataPlaneProbe, Movable, Deinitable):
    var _statuses: List[Int]
    var _cursor: Int
    var _last_url: String

    def __init__(out self, var statuses: List[Int]):
        self._statuses = statuses^
        self._cursor = 0
        self._last_url = String("")

    def calls(self) -> Int:
        return self._cursor

    def last_url(self) -> String:
        return self._last_url.copy()

    def probe_status(mut self, url: String) raises -> Int:
        self._last_url = url.copy()
        var i = self._cursor
        if i >= len(self._statuses):
            i = len(self._statuses) - 1
        self._cursor += 1
        return self._statuses[i]


def _refused_then(refusals: Int, then: Int) -> _ScriptedProbe:
    var s = List[Int]()
    for _ in range(refusals if refusals > 0 else 0):
        s.append(403)
    s.append(then)
    return _ScriptedProbe(s^)


def _always(status: Int) -> _ScriptedProbe:
    var s = List[Int]()
    s.append(status)
    return _ScriptedProbe(s^)


def _budget(n: Int) -> PollBudget:
    return PollBudget.of(n, 0)


def test_the_control_plane_read_back_is_not_evidence() raises:
    var control_plane_says_granted = True
    var probe = _refused_then(3, 404)
    var reporter = CaptureReporter()
    var first = probe.probe_status(_ORIGIN + EDGE_READINESS_PATH)

    assert_true(
        control_plane_says_granted,
        "the control-plane read-back answers GRANTED on attempt 1 — it always"
        " does, which is the problem",
    )
    assert_true(
        is_invoker_refusal(first),
        "...while the DATA plane refuses the very same hop. Both true at once:"
        " the read-back is not evidence about the data plane",
    )
    var out = await_data_plane_ready[_ScriptedProbe, CaptureReporter](
        probe, _ORIGIN + EDGE_READINESS_PATH, _budget(10), reporter
    )
    assert_true(out.ready, "waiting resolves it — the refusal was transient")
    assert_false(out.skipped, "it was probed, not skipped")


def test_a_transient_refusal_is_waited_out() raises:
    var probe = _refused_then(4, 404)
    var reporter = CaptureReporter()
    var out = await_data_plane_ready[_ScriptedProbe, CaptureReporter](
        probe, _ORIGIN + EDGE_READINESS_PATH, _budget(10), reporter
    )
    assert_true(out.ready, "ready once the refusal clears")
    assert_equal(out.attempts, 5, "exactly 4 refusals + the probe that got through")
    assert_equal(out.last_status, 404, "the status that settled it")


def test_a_404_is_ready_because_the_hop_happened() raises:
    var probe = _always(404)
    var reporter = CaptureReporter()
    var out = await_data_plane_ready[_ScriptedProbe, CaptureReporter](
        probe, _ORIGIN + EDGE_READINESS_PATH, _budget(10), reporter
    )
    assert_true(out.ready, "404 => the hop happened => READY")
    assert_equal(out.attempts, 1, "and it settled on the FIRST probe — no waiting")


def test_a_401_is_ready_and_a_403_is_not() raises:
    assert_true(is_invoker_refusal(403), "403 is the refusal")
    assert_false(is_invoker_refusal(401), "401 is NOT — something answered")
    assert_true(is_data_plane_ready(401), "401 => past the IAM front end")
    assert_true(is_data_plane_ready(404), "404 => past the IAM front end")
    assert_true(is_data_plane_ready(500), "500 => past it, badly, but past it")
    assert_false(is_data_plane_ready(403), "403 => refused at the front end")
    assert_false(
        is_data_plane_ready(DATA_PLANE_UNREACHABLE),
        "no response at all is not readiness — a fresh gateway host may not"
        " resolve yet, which is the condition being waited out",
    )


def test_a_permanent_refusal_terminates_on_budget() raises:
    var probe = _always(403)
    var reporter = CaptureReporter()
    var out = await_data_plane_ready[_ScriptedProbe, CaptureReporter](
        probe, _ORIGIN + EDGE_READINESS_PATH, _budget(6), reporter
    )
    assert_false(out.ready, "never ready")
    assert_false(out.skipped, "it WAS probed — this is evidence of refusal, not"
                 " an absence of evidence")
    assert_equal(out.attempts, 6, "EXACTLY the budget — a wait that cannot end is"
                 " worse than no wait")
    assert_equal(probe.calls(), 6, "and it made exactly that many requests")
    assert_true(
        out.summary.find(String("row asserting a NON-2xx status PASSES")) >= 0,
        "the summary names the misreporting hazard: during a total refusal, a"
        " validator row that asserts a non-2xx passes trivially, so the suite's"
        " pass count RISES during an outage",
    )


def test_an_unreachable_host_is_waited_out_then_reported() raises:
    var probe = _always(DATA_PLANE_UNREACHABLE)
    var reporter = CaptureReporter()
    var out = await_data_plane_ready[_ScriptedProbe, CaptureReporter](
        probe, _ORIGIN + EDGE_READINESS_PATH, _budget(3), reporter
    )
    assert_false(out.ready, "no response is not readiness")
    assert_equal(out.attempts, 3, "it waited its budget")
    assert_true(
        out.summary.find(String("no response")) >= 0,
        "and says WHICH not-ready this was — 'no response', not 'HTTP 403'."
        " Conflating them sends the next reader to the wrong system",
    )


def test_a_single_path_edge_has_no_safe_probe_and_is_SKIPPED() raises:
    var url = edge_readiness_probe_url(
        String("example-api") + _INBOUND_SUFFIX, _ORIGIN, _CLIENT_SUFFIX
    )
    assert_equal(url, String(""), "no probe URL for a SINGLE_PATH edge")

    var probe = _always(200)
    var reporter = CaptureReporter()
    var out = await_data_plane_ready[_ScriptedProbe, CaptureReporter](
        probe, url, _budget(5), reporter
    )
    assert_true(out.skipped, "SKIPPED — no probe was possible")
    assert_false(
        out.ready,
        "and NOT ready. `skipped` and `ready` are separate fields precisely so"
        " that an absence of evidence cannot be read as evidence",
    )
    assert_equal(probe.calls(), 0, "nothing was dialled — no ingest was fired")
    assert_true(
        out.summary.find(String("CATCH_ALL")) >= 0,
        "the skip reason names the condition, not just 'skipped'",
    )


def test_a_catch_all_edge_probes_a_path_nothing_serves() raises:
    var url = edge_readiness_probe_url(
        String("example-api") + _CLIENT_SUFFIX, _ORIGIN, _CLIENT_SUFFIX
    )
    assert_equal(
        url,
        _ORIGIN + EDGE_READINESS_PATH,
        "a CATCH_ALL edge probes its own origin at the readiness path",
    )
    assert_equal(
        edge_readiness_probe_url(
            String("example-api") + _CLIENT_SUFFIX, _ORIGIN + String("/"),
            _CLIENT_SUFFIX,
        ),
        _ORIGIN + EDGE_READINESS_PATH,
        "a trailing slash on the origin is collapsed, not doubled",
    )
    assert_equal(
        edge_readiness_probe_url(
            String("example-api") + _CLIENT_SUFFIX, String(""), _CLIENT_SUFFIX
        ),
        String(""),
        "an unrecorded origin yields no probe (and therefore a SKIP)",
    )


def main() raises:
    test_the_control_plane_read_back_is_not_evidence()
    print("  test_the_control_plane_read_back_is_not_evidence: PASS")
    test_a_transient_refusal_is_waited_out()
    print("  test_a_transient_refusal_is_waited_out: PASS")
    test_a_404_is_ready_because_the_hop_happened()
    print("  test_a_404_is_ready_because_the_hop_happened: PASS")
    test_a_401_is_ready_and_a_403_is_not()
    print("  test_a_401_is_ready_and_a_403_is_not: PASS")
    test_a_permanent_refusal_terminates_on_budget()
    print("  test_a_permanent_refusal_terminates_on_budget: PASS")
    test_an_unreachable_host_is_waited_out_then_reported()
    print("  test_an_unreachable_host_is_waited_out_then_reported: PASS")
    test_a_single_path_edge_has_no_safe_probe_and_is_SKIPPED()
    print("  test_a_single_path_edge_has_no_safe_probe_and_is_SKIPPED: PASS")
    test_a_catch_all_edge_probes_a_path_nothing_serves()
    print("  test_a_catch_all_edge_probes_a_path_nothing_serves: PASS")
    print("test_data_plane_readiness: ALL PASS")
