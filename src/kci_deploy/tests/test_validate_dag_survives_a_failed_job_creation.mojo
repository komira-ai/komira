# =============================================================================
# test_validate_dag_survives_a_failed_job_creation -- a step whose job CREATION fails must not take the
#   rest of the wave with it.
#
# A start that raises is that step's fault alone: the other steps run and keep
# their verdicts, a create that fails once and then succeeds leaves the step
# passing, and a step that never starts FAILS within its own budget with a
# summary that says it could not start (there is no execution to read).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from kci_deploy import (
    run_validation_dag,
    DagValidator,
    ValidationOutcome,
    PollBudget,
    CaptureReporter,
    STEP_PASS,
    STEP_FAIL,
    STEP_SKIPPED,
    VALIDATION_FAIL,
)


comptime _CREATE_ERR: String = (
    "CloudRunJobs CreateJob failed [13]: [grpc:13] The service has encountered"
    " an internal error. Please try again later"
)


def _contains(hay: String, needle: String) -> Bool:
    return hay.find(needle) >= 0


struct _StartFailingStep(DagValidator, Movable, Deinitable):

    var _fail_starts: Int
    var _passes: Bool
    var _start_attempts: Int
    var _successful_starts: Int
    var _polls: Int

    def __init__(out self, fail_starts: Int, passes: Bool = True):
        self._fail_starts = fail_starts
        self._passes = passes
        self._start_attempts = 0
        self._successful_starts = 0
        self._polls = 0

    def start_attempts(self) -> Int:
        return self._start_attempts

    def successful_starts(self) -> Int:
        return self._successful_starts

    def start(mut self) raises:
        self._start_attempts += 1
        if self._start_attempts <= self._fail_starts:
            raise Error(_CREATE_ERR)
        self._successful_starts += 1
        self._polls = 0

    def poll(mut self) raises -> Optional[ValidationOutcome]:
        if self._successful_starts == 0:
            raise Error(
                "poll() on a step that never started — the scheduler must not"
                " poll a step whose job creation failed"
            )
        self._polls += 1
        if self._polls < 1:
            return None
        if self._passes:
            return Optional[ValidationOutcome](
                ValidationOutcome.passed(0, String("VERDICT: PASS"))
            )
        return Optional[ValidationOutcome](
            ValidationOutcome(
                VALIDATION_FAIL, 7, String("VERDICT: FAIL")
            )
        )

    def restart(mut self) raises -> Bool:
        return False

    def run_once(mut self) raises -> ValidationOutcome:
        self.start()
        var t = self.poll()
        if t:
            return t.value().copy()
        return ValidationOutcome.indeterminate(-1, String("running"))


comptime _NEVER: Int = 1_000_000


def _names(var v: List[String]) -> List[String]:
    return v^


def _no_deps(n: Int) -> List[List[String]]:
    var d = List[List[String]]()
    for _i in range(n):
        d.append(List[String]())
    return d^


def _budget() -> PollBudget:
    return PollBudget.of(4, 0)


def test_bug_a_failed_job_creation_does_not_abort_the_whole_dag() raises:
    print("  (s1) one failed create must not abort the DAG...")

    var vs = List[_StartFailingStep]()
    vs.append(_StartFailingStep(0, True))
    vs.append(_StartFailingStep(_NEVER, True))
    vs.append(_StartFailingStep(0, True))
    vs.append(_StartFailingStep(0, True))

    var names = List[String]()
    names.append(String("api-e2e"))
    names.append(String("relay-session-e2e"))
    names.append(String("app-roundtrip"))
    names.append(String("observability"))

    var reporter = CaptureReporter()
    var raised = False
    var passed_count = 0
    var broken_status = -99
    try:
        var out = run_validation_dag[_StartFailingStep, CaptureReporter](
            vs, names, _no_deps(4), _budget(), reporter, 0
        )
        for i in range(len(out.results)):
            if out.results[i].status == STEP_PASS:
                passed_count += 1
            if out.results[i].name == String("relay-session-e2e"):
                broken_status = out.results[i].status
        assert_false(
            out.passed,
            "a DAG containing a step that could not start must not report"
            " passed",
        )
    except e:
        raised = True

    if raised:
        raise Error(
            "run_validation_dag RAISED out of a failed job creation — that is"
            " the defect this guards: one transient CreateJob must not discard"
            " every other step of the wave, including ones that had"
            " already PASSED"
        )
    assert_equal(
        passed_count,
        3,
        "every step that does NOT depend on the broken one must still run and"
        " pass — a genuinely failed step may not abort steps unrelated to it",
    )
    assert_equal(
        broken_status,
        STEP_FAIL,
        "the step whose create never succeeded must FAIL, not pass and not"
        " vanish",
    )
    _ = vs^
    print("    OK — DAG returned; 3 of 4 passed; the broken one failed")


def test_a_transient_create_failure_is_retried_and_the_step_passes() raises:
    print("  (s2) a create that fails once then works -> step PASSES...")

    var vs = List[_StartFailingStep]()
    vs.append(_StartFailingStep(1, True))
    var names = List[String]()
    names.append(String("relay-session-e2e"))

    var reporter = CaptureReporter()
    var out = run_validation_dag[_StartFailingStep, CaptureReporter](
        vs, names, _no_deps(1), _budget(), reporter, 0
    )

    assert_true(
        out.passed,
        "a create that failed once and then succeeded must leave the step"
        " PASSING — a transient create fault is retried within its own budget",
    )
    assert_equal(out.results[0].status, STEP_PASS)
    assert_equal(
        vs[0].start_attempts(),
        2,
        "the start must have been ATTEMPTED twice — one attempt means the"
        " retry did not happen and the pass came from somewhere else",
    )
    assert_equal(vs[0].successful_starts(), 1)
    _ = vs^
    print("    OK — retried the create once, step passed")


def test_a_step_that_can_never_start_fails_loudly_and_terminates() raises:
    print("  (s3/s4) a create that never works -> loud FAIL, no hang...")

    var vs = List[_StartFailingStep]()
    vs.append(_StartFailingStep(_NEVER, True))
    var names = List[String]()
    names.append(String("relay-session-e2e"))

    var reporter = CaptureReporter()
    var out = run_validation_dag[_StartFailingStep, CaptureReporter](
        vs, names, _no_deps(1), _budget(), reporter, 0
    )

    assert_false(out.passed, "a step that never ran must not report passed")
    assert_equal(
        out.results[0].status,
        STEP_FAIL,
        "a step whose job was never created is a FAILURE, not a skip and not"
        " a pass",
    )
    var summary = out.results[0].outcome.summary
    assert_true(
        _contains(summary, String("could not start")),
        String(
            "the summary must say COULD NOT START — 'did not reach a terminal"
            " verdict' sends the operator to read an execution that was never"
            " created. got: "
        )
        + summary,
    )
    assert_true(
        _contains(summary, String("[grpc:13]")),
        String(
            "the summary must carry the CreateJob error verbatim — it is the"
            " only thing that names the real fault. got: "
        )
        + summary,
    )
    assert_true(
        _contains(summary, String("no execution to read")),
        String(
            "the summary must say there is no execution, because the operator's"
            " next move otherwise is the Cloud Run console. got: "
        )
        + summary,
    )
    assert_true(
        vs[0].start_attempts() > 1,
        "the create must have been RETRIED before the step was failed — a"
        " single attempt only re-labels the failure, it does not survive it",
    )
    assert_equal(
        vs[0].successful_starts(),
        0,
        "no start ever succeeded, so no execution exists",
    )
    _ = vs^
    print("    OK — failed loudly, named the create error, terminated")


def test_a_dependent_of_a_never_starting_step_is_skipped_not_passed() raises:
    print("  (s5) a dependent of a never-starting step is SKIPPED...")

    var vs = List[_StartFailingStep]()
    vs.append(_StartFailingStep(_NEVER, True))
    vs.append(_StartFailingStep(0, True))

    var names = List[String]()
    names.append(String("relay-session-e2e"))
    names.append(String("app-roundtrip"))

    var deps = List[List[String]]()
    deps.append(List[String]())
    var d1 = List[String]()
    d1.append(String("relay-session-e2e"))
    deps.append(d1^)

    var reporter = CaptureReporter()
    var out = run_validation_dag[_StartFailingStep, CaptureReporter](
        vs, names, deps, _budget(), reporter, 0
    )

    assert_false(out.passed)
    assert_equal(out.results[0].status, STEP_FAIL)
    assert_equal(
        out.results[1].status,
        STEP_SKIPPED,
        "a step whose dependency could not start must be SKIPPED — running it"
        " would test a precondition that never happened, and passing it would"
        " be a lie",
    )
    assert_true(
        _contains(
            out.results[1].outcome.summary, String("relay-session-e2e")
        ),
        String("the skip must NAME the dependency. got: ")
        + out.results[1].outcome.summary,
    )
    assert_equal(
        vs[1].start_attempts(),
        0,
        "the dependent must never have been started at all",
    )
    _ = vs^
    print("    OK — skipped, dependency named, never started")


def test_a_step_blocked_on_a_dependency_still_burns_none_of_its_budget() raises:
    print("  (s6) a blocked step still burns none of its own budget...")

    var vs = List[_StartFailingStep]()
    for _i in range(3):
        vs.append(_StartFailingStep(0, True))

    var names = List[String]()
    names.append(String("a"))
    names.append(String("b"))
    names.append(String("c"))

    var deps = List[List[String]]()
    deps.append(List[String]())
    var db = List[String]()
    db.append(String("a"))
    deps.append(db^)
    var dc = List[String]()
    dc.append(String("b"))
    deps.append(dc^)

    var reporter = CaptureReporter()
    var out = run_validation_dag[_StartFailingStep, CaptureReporter](
        vs, names, deps, PollBudget.of(3, 0), reporter, 0
    )

    assert_true(
        out.passed,
        "a 3-deep chain under a 3-round PER-STEP budget must pass — if this is"
        " red, the round charger is billing steps that are blocked on a"
        " dependency, which is the blocked-step false-RED",
    )
    for i in range(3):
        assert_equal(out.results[i].status, STEP_PASS)
    _ = vs^
    print("    OK — per-step budget intact")


def main() raises:
    print(
        "test_validate_dag_survives_a_failed_job_creation: one failed CreateJob"
        " must not cost the rest of the wave"
    )
    test_bug_a_failed_job_creation_does_not_abort_the_whole_dag()
    test_a_transient_create_failure_is_retried_and_the_step_passes()
    test_a_step_that_can_never_start_fails_loudly_and_terminates()
    test_a_dependent_of_a_never_starting_step_is_skipped_not_passed()
    test_a_step_blocked_on_a_dependency_still_burns_none_of_its_budget()
    print("ALL PASS")
