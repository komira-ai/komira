# =============================================================================
# test_validation_dag -- the parallel step-DAG scheduler and per-step reporting.
#
# `run_validation_dag` orders the wave's steps by their dependencies, runs
# independent steps concurrently (every ready start fires before polling), runs
# ALL steps (no short-circuit), and reports PASS / FAIL / SKIPPED per step.
# Dependents of a failed step are SKIPPED, distinct from FAIL; the overall
# verdict is the AND of every step. Hermetic: scripted validators and a shared
# event log.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false, assert_raises

from kci_deploy import (
    run_validation_dag,
    DagOutcome,
    StepResult,
    ScriptedDagValidator,
    DagEventLog,
    PollBudget,
    CaptureReporter,
    STEP_PASS,
    STEP_FAIL,
    STEP_SKIPPED,
)


def _budget() -> PollBudget:
    return PollBudget.of(20, 0)


def _names3(a: String, b: String, c: String) -> List[String]:
    var n = List[String]()
    n.append(a)
    n.append(b)
    n.append(c)
    return n^


def _no_deps(n: Int) -> List[List[String]]:
    var d = List[List[String]]()
    for _i in range(n):
        d.append(List[String]())
    return d^


def _dep(*names: String) -> List[String]:
    var d = List[String]()
    for ref x in names:
        d.append(x)
    return d^


def test_independent_steps_run_concurrently() raises:
    var log = DagEventLog()
    var vs = List[ScriptedDagValidator]()
    vs.append(ScriptedDagValidator(String("a"), log.share()))
    vs.append(ScriptedDagValidator(String("b"), log.share()))
    vs.append(ScriptedDagValidator(String("c"), log.share()))
    var reporter = CaptureReporter()
    var out = run_validation_dag[ScriptedDagValidator, CaptureReporter](
        vs, _names3(String("a"), String("b"), String("c")), _no_deps(3),
        _budget(), reporter, 0,
    )
    assert_true(out.passed, "all three independent steps pass")
    assert_equal(out.pass_count(), 3, "3 passed")
    var last_start = log.index_of(String("start:c"))
    assert_true(last_start >= 0, "all three started")
    assert_true(
        log.index_of(String("poll:a")) > last_start,
        "poll:a comes AFTER every start (concurrent fire-then-poll batch)",
    )
    assert_true(
        log.index_of(String("poll:b")) > last_start, "poll:b after every start"
    )
    _ = vs^


def test_all_steps_run_despite_one_failing() raises:
    var log = DagEventLog()
    var vs = List[ScriptedDagValidator]()
    vs.append(ScriptedDagValidator(String("a"), log.share()))
    vs.append(ScriptedDagValidator(String("b"), log.share(), 0, False))
    vs.append(ScriptedDagValidator(String("c"), log.share()))
    var reporter = CaptureReporter()
    var out = run_validation_dag[ScriptedDagValidator, CaptureReporter](
        vs, _names3(String("a"), String("b"), String("c")), _no_deps(3),
        _budget(), reporter, 0,
    )
    assert_false(out.passed, "one FAIL => the whole DAG fails")
    assert_equal(len(out.results), 3, "all three steps have a result (no short-circuit)")
    assert_equal(out.results[0].status, STEP_PASS, "a passed")
    assert_equal(out.results[1].status, STEP_FAIL, "b failed")
    assert_equal(out.results[2].status, STEP_PASS, "c passed (ran despite b failing)")
    assert_true(log.index_of(String("start:c")) >= 0, "c actually started (not skipped)")
    _ = vs^


def test_dependents_of_failed_are_skipped() raises:
    var log = DagEventLog()
    var vs = List[ScriptedDagValidator]()
    vs.append(ScriptedDagValidator(String("a"), log.share(), 0, False))
    vs.append(ScriptedDagValidator(String("b"), log.share()))
    vs.append(ScriptedDagValidator(String("c"), log.share()))
    var deps = List[List[String]]()
    deps.append(List[String]())
    deps.append(_dep(String("a")))
    deps.append(_dep(String("b")))
    var reporter = CaptureReporter()
    var out = run_validation_dag[ScriptedDagValidator, CaptureReporter](
        vs, _names3(String("a"), String("b"), String("c")), deps^,
        _budget(), reporter, 0,
    )
    assert_false(out.passed, "a failed => DAG fails")
    assert_equal(out.results[0].status, STEP_FAIL, "a FAILED")
    assert_equal(out.results[1].status, STEP_SKIPPED, "b SKIPPED (dep a failed)")
    assert_equal(out.results[2].status, STEP_SKIPPED, "c SKIPPED (dep b skipped)")
    assert_equal(out.skipped_count(), 2, "two skipped")
    assert_equal(out.fail_count(), 1, "one failed (a) — b/c are skipped, not failed")
    assert_true(log.index_of(String("start:b")) < 0, "b never started (skipped)")
    assert_true(log.index_of(String("start:c")) < 0, "c never started (skipped)")
    _ = vs^


def test_dependent_of_pass_runs_after() raises:
    var log = DagEventLog()
    var vs = List[ScriptedDagValidator]()
    vs.append(ScriptedDagValidator(String("a"), log.share()))
    vs.append(ScriptedDagValidator(String("b"), log.share()))
    var names = List[String]()
    names.append(String("a"))
    names.append(String("b"))
    var deps = List[List[String]]()
    deps.append(List[String]())
    deps.append(_dep(String("a")))
    var reporter = CaptureReporter()
    var out = run_validation_dag[ScriptedDagValidator, CaptureReporter](
        vs, names^, deps^, _budget(), reporter, 0,
    )
    assert_true(out.passed, "both pass")
    assert_true(
        log.index_of(String("start:a")) < log.index_of(String("start:b")),
        "b starts after a (dependency ordering)",
    )
    _ = vs^


def test_per_step_reporting() raises:
    var log = DagEventLog()
    var vs = List[ScriptedDagValidator]()
    vs.append(ScriptedDagValidator(String("a"), log.share(), 0, False))
    vs.append(ScriptedDagValidator(String("b"), log.share()))
    var names = List[String]()
    names.append(String("a"))
    names.append(String("b"))
    var deps = List[List[String]]()
    deps.append(List[String]())
    deps.append(_dep(String("a")))
    var reporter = CaptureReporter()
    var out = run_validation_dag[ScriptedDagValidator, CaptureReporter](
        vs, names^, deps^, _budget(), reporter, 0,
    )
    var saw_a_fail = False
    var saw_b_skip = False
    var saw_rollup = False
    for i in range(reporter.line_count()):
        var line = reporter.line_at(i)
        if line.find(String("step 'a' FAIL")) >= 0:
            saw_a_fail = True
        if line.find(String("step 'b' SKIPPED")) >= 0:
            saw_b_skip = True
        if line.find(String("1 skipped")) >= 0:
            saw_rollup = True
    assert_true(saw_a_fail, "a FAIL is reported")
    assert_true(saw_b_skip, "b SKIPPED is reported (distinct from FAIL)")
    assert_true(saw_rollup, "the roll-up counts the skip")
    assert_false(out.passed, "overall FAIL")
    _ = vs^


def test_running_step_polls_to_terminal() raises:
    var log = DagEventLog()
    var vs = List[ScriptedDagValidator]()
    vs.append(ScriptedDagValidator(String("slow"), log.share(), 2, True))
    var names = List[String]()
    names.append(String("slow"))
    var reporter = CaptureReporter()
    var out = run_validation_dag[ScriptedDagValidator, CaptureReporter](
        vs, names^, _no_deps(1), _budget(), reporter, 0,
    )
    assert_true(out.passed, "the slow step polls through to PASS within the budget")
    var starts = 0
    var polls = 0
    for i in range(log.count()):
        if log.at(i) == String("start:slow"):
            starts += 1
        if log.at(i) == String("poll:slow"):
            polls += 1
    assert_equal(starts, 1, "started exactly once (start is not re-fired each round)")
    assert_true(polls >= 3, "polled at least 3 times (None, None, terminal)")
    _ = vs^


def test_running_step_times_out_to_fail() raises:
    var log = DagEventLog()
    var vs = List[ScriptedDagValidator]()
    vs.append(ScriptedDagValidator(String("hang"), log.share(), 100, True))
    var names = List[String]()
    names.append(String("hang"))
    var reporter = CaptureReporter()
    var out = run_validation_dag[ScriptedDagValidator, CaptureReporter](
        vs, names^, _no_deps(1), PollBudget.of(3, 0), reporter, 0,
    )
    assert_false(out.passed, "a never-terminal step times out to a non-PASS")
    assert_equal(out.results[0].status, STEP_FAIL, "timeout -> FAIL")
    _ = vs^


def test_dangling_dependency_raises() raises:
    var log = DagEventLog()
    var vs = List[ScriptedDagValidator]()
    vs.append(ScriptedDagValidator(String("a"), log.share()))
    var names = List[String]()
    names.append(String("a"))
    var deps = List[List[String]]()
    deps.append(_dep(String("ghost")))
    var reporter = CaptureReporter()
    with assert_raises():
        _ = run_validation_dag[ScriptedDagValidator, CaptureReporter](
            vs, names^, deps^, _budget(), reporter, 0,
        )
    assert_true(log.index_of(String("start:a")) < 0, "no step started on a dangling DAG")
    _ = vs^


def test_cycle_raises() raises:
    var log = DagEventLog()
    var vs = List[ScriptedDagValidator]()
    vs.append(ScriptedDagValidator(String("x"), log.share()))
    vs.append(ScriptedDagValidator(String("y"), log.share()))
    var names = List[String]()
    names.append(String("x"))
    names.append(String("y"))
    var deps = List[List[String]]()
    deps.append(_dep(String("y")))
    deps.append(_dep(String("x")))
    var reporter = CaptureReporter()
    with assert_raises():
        _ = run_validation_dag[ScriptedDagValidator, CaptureReporter](
            vs, names^, deps^, _budget(), reporter, 0,
        )
    _ = vs^


def test_empty_dag_passes() raises:
    var vs = List[ScriptedDagValidator]()
    var reporter = CaptureReporter()
    var out = run_validation_dag[ScriptedDagValidator, CaptureReporter](
        vs, List[String](), List[List[String]](), _budget(), reporter, 0,
    )
    assert_true(out.passed, "an empty DAG (no steps) passes")
    assert_equal(len(out.results), 0, "no step results")


def test_concurrency_cap_bounds_running() raises:
    var log = DagEventLog()
    var vs = List[ScriptedDagValidator]()
    var names = List[String]()
    for c in String("abcd"):
        vs.append(ScriptedDagValidator(String(c), log.share(), 2, True))
        names.append(String(c))
    var reporter = CaptureReporter()
    var out = run_validation_dag[ScriptedDagValidator, CaptureReporter](
        vs, names^, _no_deps(4), PollBudget.of(30, 0), reporter, 2,
    )
    assert_true(out.passed, "all four complete + pass even under a concurrency cap")
    assert_equal(out.pass_count(), 4, "4 passed")
    var first_two_started = (
        log.index_of(String("start:a")) >= 0
        and log.index_of(String("start:b")) >= 0
    )
    assert_true(first_two_started, "the first two ready steps started under the cap")
    _ = vs^


def test_two_independent_failures_are_both_reported() raises:
    var log = DagEventLog()
    var vs = List[ScriptedDagValidator]()
    vs.append(ScriptedDagValidator(String("a"), log.share(), 0, False))
    vs.append(ScriptedDagValidator(String("b"), log.share(), 0, False))
    vs.append(ScriptedDagValidator(String("c"), log.share()))
    vs.append(ScriptedDagValidator(String("d"), log.share()))
    vs.append(ScriptedDagValidator(String("e"), log.share()))
    var names = List[String]()
    for c in String("abcde"):
        names.append(String(c))
    var deps = List[List[String]]()
    deps.append(List[String]())
    deps.append(List[String]())
    deps.append(List[String]())
    deps.append(_dep(String("a")))
    deps.append(_dep(String("b")))
    var reporter = CaptureReporter()
    var out = run_validation_dag[ScriptedDagValidator, CaptureReporter](
        vs, names^, deps^, _budget(), reporter, 0,
    )

    var reds = List[String]()
    if out.fail_count() != 2:
        reds.append(
            String("FACT A — the roll-up counted ")
            + String(out.fail_count())
            + String(" failure(s), want 2. A DAG that stops at the first failing")
            + String(" step reports 1 here and reads as a single problem.")
        )
    if out.results[0].status != STEP_FAIL:
        reds.append(String("FACT A — step 'a' is not recorded FAIL"))
    if out.results[1].status != STEP_FAIL:
        reds.append(
            String("FACT A — step 'b' is not recorded FAIL: the SECOND")
            + String(" independent failure was dropped")
        )
    if not reporter.contains(String("step 'a' FAIL")):
        reds.append(String("FACT B — the report does not name 'a' as FAIL"))
    if not reporter.contains(String("step 'b' FAIL")):
        reds.append(
            String("FACT B — the report does not name 'b' as FAIL; a count")
            + String(" without the names sends the reader back to the logs")
        )
    if out.results[2].status != STEP_PASS:
        reds.append(
            String("FACT C — 'c' is independent of both failures and did not")
            + String(" PASS (status ")
            + String(out.results[2].status)
            + String(")")
        )
    if log.index_of(String("start:c")) < 0:
        reds.append(String("FACT C — 'c' never started"))
    if out.results[3].status != STEP_SKIPPED:
        reds.append(String("FACT D — 'd' must stay SKIPPED behind failed 'a'"))
    if out.results[4].status != STEP_SKIPPED:
        reds.append(String("FACT D — 'e' must stay SKIPPED behind failed 'b'"))
    if out.skipped_count() != 2:
        reds.append(
            String("FACT D — skipped_count is ")
            + String(out.skipped_count())
            + String(", want 2")
        )
    if log.index_of(String("start:d")) >= 0 or log.index_of(String("start:e")) >= 0:
        reds.append(
            String("FACT D — a step whose premise failed was RUN anyway; its")
            + String(" result would be noise the reader must learn to ignore")
        )
    if not reporter.contains(String("step 'd' SKIPPED (dependency 'a' FAIL)")):
        reds.append(
            String("FACT D — 'd's skip line does not name ITS OWN dependency 'a'")
        )
    if not reporter.contains(String("step 'e' SKIPPED (dependency 'b' FAIL)")):
        reds.append(
            String("FACT D — 'e's skip line does not name ITS OWN dependency 'b';")
            + String(" one global 'something failed' reason is not a diagnosis")
        )
    if out.passed:
        reds.append(String("FACT E — two failing steps and the DAG reports passed"))
    if out.summary().find(String("1/5 step(s) passed")) < 0:
        reds.append(
            String("FACT E — the roll-up does not state the true shape: got '")
            + out.summary()
            + String("'")
        )

    for ref f in reds:
        print("  RED " + f)
    if len(reds) > 0:
        raise Error(
            String("test_two_independent_failures_are_both_reported: ")
            + String(len(reds))
            + String(" independent fact(s) red (listed above)")
        )
    _ = vs^


def main() raises:
    var failures = List[String]()
    var ran = 0

    ran += 1
    try:
        test_independent_steps_run_concurrently()
    except e:
        failures.append(String("independent_steps_run_concurrently: ") + String(e))
    ran += 1
    try:
        test_all_steps_run_despite_one_failing()
    except e:
        failures.append(String("all_steps_run_despite_one_failing: ") + String(e))
    ran += 1
    try:
        test_two_independent_failures_are_both_reported()
    except e:
        failures.append(
            String("two_independent_failures_are_both_reported: ") + String(e)
        )
    ran += 1
    try:
        test_dependents_of_failed_are_skipped()
    except e:
        failures.append(String("dependents_of_failed_are_skipped: ") + String(e))
    ran += 1
    try:
        test_dependent_of_pass_runs_after()
    except e:
        failures.append(String("dependent_of_pass_runs_after: ") + String(e))
    ran += 1
    try:
        test_per_step_reporting()
    except e:
        failures.append(String("per_step_reporting: ") + String(e))
    ran += 1
    try:
        test_running_step_polls_to_terminal()
    except e:
        failures.append(String("running_step_polls_to_terminal: ") + String(e))
    ran += 1
    try:
        test_running_step_times_out_to_fail()
    except e:
        failures.append(String("running_step_times_out_to_fail: ") + String(e))
    ran += 1
    try:
        test_dangling_dependency_raises()
    except e:
        failures.append(String("dangling_dependency_raises: ") + String(e))
    ran += 1
    try:
        test_cycle_raises()
    except e:
        failures.append(String("cycle_raises: ") + String(e))
    ran += 1
    try:
        test_empty_dag_passes()
    except e:
        failures.append(String("empty_dag_passes: ") + String(e))
    ran += 1
    try:
        test_concurrency_cap_bounds_running()
    except e:
        failures.append(String("concurrency_cap_bounds_running: ") + String(e))

    for ref f in failures:
        print("  RED " + f)
    if len(failures) > 0:
        raise Error(
            String("FAIL test_validation_dag — ")
            + String(len(failures))
            + String(" of ")
            + String(ran)
            + String(" case(s) red (listed above)")
        )
    print(
        "test_validation_dag: all parallel step-DAG and per-step"
        " reporting cases PASSED ("
        + String(ran)
        + " case(s))"
    )
