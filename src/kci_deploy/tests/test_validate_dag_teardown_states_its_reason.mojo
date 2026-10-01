# =============================================================================
# test_validate_dag_teardown_states_its_reason -- every teardown states WHY it fired.
#
# When the scheduler raises, the teardown pass cancels executions still in
# flight; the log must say that this was collateral of a scheduler fault and
# quote the fault. When the wave completes, each step's reason carries its own
# verdict and is stamped on its `StepResult`.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from kci_iac import ChangeAction, AppliedNode

from kci_deploy import (
    run_validation_dag,
    step_teardown_reason,
    TEARDOWN_PATH_SCHEDULER_FAULT,
    TEARDOWN_PATH_WAVE_COMPLETED,
    DagValidator,
    Reporter,
    ValidationOutcome,
    PollBudget,
    CaptureReporter,
    STEP_PASS,
    STEP_FAIL,
    STEP_SKIPPED,
)


comptime _POLL_ERR: String = (
    "CloudRunJobs GetExecution failed [16]: [grpc:16] Request had invalid"
    " authentication credentials"
)


def _contains(hay: String, needle: String) -> Bool:
    return hay.find(needle) >= 0


struct _JobStep(DagValidator, Movable, Deinitable):

    var _raise_on_poll: Int
    var _pass_on_poll: Int
    var _polls: Int
    var _started: Bool
    var _ever_started: Bool
    var _teardowns: Int

    def __init__(out self, raise_on_poll: Int = 0, pass_on_poll: Int = 0):
        self._raise_on_poll = raise_on_poll
        self._pass_on_poll = pass_on_poll
        self._polls = 0
        self._started = False
        self._ever_started = False
        self._teardowns = 0

    def teardown_calls(self) -> Int:
        return self._teardowns

    def start(mut self) raises:
        self._started = True
        self._ever_started = True

    def poll(mut self) raises -> Optional[ValidationOutcome]:
        self._polls += 1
        if self._raise_on_poll > 0 and self._polls >= self._raise_on_poll:
            raise Error(_POLL_ERR)
        if self._pass_on_poll > 0 and self._polls >= self._pass_on_poll:
            return Optional[ValidationOutcome](
                ValidationOutcome.passed(0, String("VERDICT: PASS (12/12 rows)"))
            )
        return None

    def restart(mut self) raises -> Bool:
        return True

    def teardown(mut self) raises:
        self._teardowns += 1

    def run_once(mut self) raises -> ValidationOutcome:
        self.start()
        var t = self.poll()
        if t:
            return t.value().copy()
        return ValidationOutcome.indeterminate(-1, String("running"))


struct _FaultingReporter(Reporter, Movable, Deinitable):

    var _infos: Int

    def __init__(out self):
        self._infos = 0

    def info_attempts(self) -> Int:
        return self._infos

    def begin(mut self, phase: String, env: String) raises:
        raise Error("reporter is broken")

    def plan_action(mut self, action: ChangeAction) raises:
        raise Error("reporter is broken")

    def applied_node(mut self, node: AppliedNode) raises:
        raise Error("reporter is broken")

    def info(mut self, message: String) raises:
        self._infos += 1
        raise Error("reporter is broken")

    def finish(mut self, summary: String) raises:
        raise Error("reporter is broken")


def _no_deps(n: Int) -> List[List[String]]:
    var d = List[List[String]]()
    for _i in range(n):
        d.append(List[String]())
    return d^


def _two_names(a: String, b: String) -> List[String]:
    var out = List[String]()
    out.append(a.copy())
    out.append(b.copy())
    return out^


def _budget(rounds: Int) -> PollBudget:
    return PollBudget.of(rounds, 0)


def test_a_scheduler_fault_teardown_names_the_path_and_the_fault() raises:
    print("  (r1) a scheduler fault must name itself at every teardown...")

    var vs = List[_JobStep]()
    vs.append(_JobStep(raise_on_poll=2))
    vs.append(_JobStep())

    var names = _two_names(
        String("app-roundtrip"), String("observability")
    )
    var reporter = CaptureReporter()
    var raised = False
    try:
        var out = run_validation_dag[_JobStep, CaptureReporter](
            vs, names, _no_deps(2), _budget(6), reporter, 0
        )
        _ = out.passed
    except e:
        raised = True
        assert_true(
            _contains(String(e), _POLL_ERR),
            "the scheduler's fault must be re-raised byte-identical — this"
            " change may not swallow it",
        )
    assert_true(
        raised,
        "a raise out of poll() must still escape run_validation_dag unchanged;"
        " this change makes the teardown LEGIBLE, it does not alter control flow",
    )

    assert_true(
        reporter.contains(
            String("step 'app-roundtrip' TEARDOWN — ")
            + String(TEARDOWN_PATH_SCHEDULER_FAULT)
        ),
        "the step whose poll faulted must have its teardown reported as"
        " SCHEDULER-FAULT",
    )
    assert_true(
        reporter.contains(
            String("step 'observability' TEARDOWN — ")
            + String(TEARDOWN_PATH_SCHEDULER_FAULT)
        ),
        "a step torn down as COLLATERAL must say so too — it is the one whose"
        " healthy execution the driver cancels without ever judging it",
    )
    assert_true(
        reporter.contains(_POLL_ERR),
        "the teardown reason must QUOTE the scheduler fault — on this path it is"
        " the only thing that says why a healthy execution was cancelled",
    )
    assert_true(
        reporter.contains(String("CANCELLED by this release")),
        "the reason must state that an in-flight execution is cancelled BY the"
        " release, which is the fact a cloud audit log shows and a run record"
        " would not otherwise carry",
    )

    assert_equal(
        vs[0].teardown_calls(), 1, "the faulting step must still be released"
    )
    assert_equal(
        vs[1].teardown_calls(),
        1,
        "the collateral step must still be released — the report is derived"
        " BEFORE the release and may never gate it",
    )
    _ = vs^
    print("    OK — the fault arm names the path, the fault, and still releases")


def test_a_completed_wave_stamps_each_steps_own_verdict_on_its_teardown() raises:
    print("  (r3) a completed wave stamps the reason where it is durable...")

    var vs = List[_JobStep]()
    vs.append(_JobStep(pass_on_poll=1))
    vs.append(_JobStep())

    var names = _two_names(
        String("livez"), String("app-roundtrip")
    )
    var reporter = CaptureReporter()
    var out = run_validation_dag[_JobStep, CaptureReporter](
        vs, names, _no_deps(2), _budget(2), reporter, 0
    )

    assert_false(out.passed, "a timed-out step must not report a passing wave")
    assert_equal(out.results[0].status, STEP_PASS)
    assert_equal(out.results[1].status, STEP_FAIL)

    assert_true(
        _contains(
            out.results[0].teardown_reason,
            String(TEARDOWN_PATH_WAVE_COMPLETED),
        ),
        "a step released at the ordinary end of a wave must be stamped"
        " WAVE-COMPLETED on its StepResult — the record is written from here",
    )
    assert_true(
        _contains(out.results[0].teardown_reason, String("PASS")),
        "the stamp must carry the step's own status so a release after a pass"
        " reads differently from one after a timeout",
    )
    assert_true(
        _contains(
            out.results[1].teardown_reason,
            String(TEARDOWN_PATH_WAVE_COMPLETED),
        ),
        "the timed-out step is released on the same path and must say so",
    )
    assert_true(
        _contains(out.results[1].teardown_reason, String("timeout")),
        "the timed-out step's stamp must carry its OWN summary — 'the budget ran"
        " out' and 'the scheduler raised' send a reader to different systems",
    )
    assert_false(
        _contains(
            out.results[1].teardown_reason,
            String(TEARDOWN_PATH_SCHEDULER_FAULT),
        ),
        "a completed wave must never be reported as a scheduler fault",
    )
    assert_equal(vs[0].teardown_calls(), 1)
    assert_equal(vs[1].teardown_calls(), 1)
    _ = vs^
    print("    OK — the reason is stamped on the StepResult the record is built from")


def test_the_reason_derivation_is_pure_and_the_fault_outranks_the_status() raises:
    print("  (r4) the derivation: fault outranks status, newlines fold...")

    var faulted = step_teardown_reason(
        String("grpc:16 bad credentials"), STEP_PASS, String("VERDICT: PASS")
    )
    assert_true(
        _contains(faulted, String(TEARDOWN_PATH_SCHEDULER_FAULT)),
        "a non-empty scheduler fault is the discriminator",
    )
    assert_false(
        _contains(faulted, String(TEARDOWN_PATH_WAVE_COMPLETED)),
        "a faulted wave may not also claim to have completed",
    )
    assert_true(_contains(faulted, String("grpc:16 bad credentials")))

    var folded = step_teardown_reason(
        String("line one\nline two"), STEP_FAIL, String("")
    )
    assert_false(
        _contains(folded, String("\n")),
        "the reason is one clause on one line — newlines must be folded",
    )
    assert_true(_contains(folded, String("line one / line two")))

    var completed = step_teardown_reason(
        String(""), STEP_PASS, String("VERDICT: PASS (12/12 rows)")
    )
    assert_true(_contains(completed, String(TEARDOWN_PATH_WAVE_COMPLETED)))
    assert_true(_contains(completed, String("PASS")))
    assert_true(_contains(completed, String("12/12 rows")))

    var skipped = step_teardown_reason(
        String(""), STEP_SKIPPED, String("skipped: dependency 'livez' FAIL")
    )
    assert_true(_contains(skipped, String("SKIPPED")))
    print("    OK — pure, fault-first, single-clause")


def test_a_reporter_that_raises_does_not_skip_the_release() raises:
    print("  (r5) a reporter that raises must not skip a teardown...")

    var vs = List[_JobStep]()
    vs.append(_JobStep(pass_on_poll=1))
    vs.append(_JobStep())

    var names = _two_names(String("livez"), String("app-roundtrip"))
    var reporter = _FaultingReporter()
    try:
        var out = run_validation_dag[_JobStep, _FaultingReporter](
            vs, names, _no_deps(2), _budget(2), reporter, 0
        )
        _ = out.passed
    except e:
        _ = String(e)
    assert_equal(
        vs[0].teardown_calls(),
        1,
        "a started step must be released even when the reporter is broken",
    )
    assert_equal(
        vs[1].teardown_calls(),
        1,
        "EVERY started step must be released even when the reporter is broken —"
        " the teardown pass may not become conditional on being able to speak",
    )
    _ = vs^
    _ = reporter^
    print("    OK — the release survives a broken reporter")


def main() raises:
    print(
        "test_validate_dag_teardown_states_its_reason: a teardown that cancels a"
        " healthy execution must say which exit path fired, and why"
    )
    test_a_scheduler_fault_teardown_names_the_path_and_the_fault()
    test_a_completed_wave_stamps_each_steps_own_verdict_on_its_teardown()
    test_the_reason_derivation_is_pure_and_the_fault_outranks_the_status()
    test_a_reporter_that_raises_does_not_skip_the_release()
    print("ALL PASS")
