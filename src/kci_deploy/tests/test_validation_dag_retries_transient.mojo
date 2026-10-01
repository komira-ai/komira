# =============================================================================
# test_validation_dag_retries_transient -- retries in the validation DAG.
#
# A step that reports a non-pass on its first attempt and a PASS on a later one
# must reach PASS through `run_validation_dag`, as it does through the serial
# gate: a validate wave launched seconds after an IAM grant sees its first
# attempt refused. These cases also pin the limits of that retry: a gate that
# does not re-arm runs exactly once; a deterministic failure stops after the
# identical-outcome floors (count AND wall) instead of burning its whole
# budget; a changing repeat key keeps the budget; a producer that states
# `no_retry_reason` is not retried and its sentence reaches the report.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from kci_deploy import (
    run_validation_dag,
    DagOutcome,
    StepResult,
    DagValidator,
    ValidationOutcome,
    PollBudget,
    CaptureReporter,
    STEP_PASS,
    STEP_FAIL,
    STEP_SKIPPED,
    VALIDATION_PASS,
    VALIDATION_FAIL,
    VALIDATION_INDETERMINATE,
    derived_identical_outcome_rounds,
    identical_outcome_stop_is_due,
    TEARDOWN_PATH_WAVE_COMPLETED,
)


struct _FlakyDagValidator(DagValidator, Movable, Deinitable):

    var _refusals: Int
    var _refuse_verdict: Int
    var _can_rearm: Bool
    var _starts: Int
    var _polls: Int

    def __init__(
        out self,
        refusals: Int,
        refuse_verdict: Int = VALIDATION_FAIL,
        can_rearm: Bool = True,
    ):
        self._refusals = refusals
        self._refuse_verdict = refuse_verdict
        self._can_rearm = can_rearm
        self._starts = 0
        self._polls = 0

    def starts(self) -> Int:
        return self._starts

    def polls(self) -> Int:
        return self._polls

    def start(mut self) raises:
        self._starts += 1

    def poll(mut self) raises -> Optional[ValidationOutcome]:
        self._polls += 1
        if self._starts <= self._refusals:
            var code = 1 if self._refuse_verdict == VALIDATION_FAIL else -1
            return Optional[ValidationOutcome](
                ValidationOutcome(
                    self._refuse_verdict,
                    code,
                    String("GET edge -> HTTP 403 (attempt ")
                    + String(self._starts)
                    + String(")"),
                )
            )
        return Optional[ValidationOutcome](
            ValidationOutcome.passed(
                0,
                String("GET edge -> HTTP 200 (attempt ")
                + String(self._starts)
                + String(")"),
            )
        )

    def restart(mut self) raises -> Bool:
        return self._can_rearm

    def run_once(mut self) raises -> ValidationOutcome:
        self.start()
        var t = self.poll()
        if t:
            return t.value().copy()
        return ValidationOutcome.indeterminate(-1, String("running"))


def _one(var name: String) -> List[String]:
    var n = List[String]()
    n.append(name^)
    return n^


def _no_deps(n: Int) -> List[List[String]]:
    var d = List[List[String]]()
    for _i in range(n):
        d.append(List[String]())
    return d^


def _budget() -> PollBudget:
    return PollBudget.of(10, 0)


def test_a_transient_non_pass_is_retried_to_PASS() raises:
    var vs = List[_FlakyDagValidator]()
    vs.append(_FlakyDagValidator(2, VALIDATION_INDETERMINATE))
    var reporter = CaptureReporter()
    var out = run_validation_dag[_FlakyDagValidator, CaptureReporter](
        vs, _one(String("api-e2e")), _no_deps(1), _budget(), reporter, 0
    )
    assert_true(
        out.passed,
        "a step refused on its first two attempts must PASS on the third —"
        " the SERIAL gate's documented retry-until-PASS, on the DAG path",
    )
    assert_equal(out.results[0].status, STEP_PASS, "the step is PASS")
    assert_equal(
        vs[0].starts(),
        3,
        "the retry RE-LAUNCHED the attempt (3 starts) — re-reading a finished"
        " attempt is not a retry",
    )
    _ = vs^


def test_a_transient_FAIL_is_retried_to_PASS() raises:
    var vs = List[_FlakyDagValidator]()
    vs.append(_FlakyDagValidator(1, VALIDATION_FAIL))
    var reporter = CaptureReporter()
    var out = run_validation_dag[_FlakyDagValidator, CaptureReporter](
        vs, _one(String("api-e2e")), _no_deps(1), _budget(), reporter, 0
    )
    assert_true(out.passed, "a FAIL on attempt 1 + a PASS on attempt 2 => PASS")
    assert_equal(vs[0].starts(), 2, "exactly two launches")
    _ = vs^


def test_a_permanently_failing_step_still_FAILS() raises:
    var vs = List[_FlakyDagValidator]()
    vs.append(_FlakyDagValidator(999, VALIDATION_FAIL))
    var reporter = CaptureReporter()
    var out = run_validation_dag[_FlakyDagValidator, CaptureReporter](
        vs, _one(String("broken")), _no_deps(1), PollBudget.of(4, 0), reporter, 0
    )
    assert_false(out.passed, "a step that never passes must FAIL")
    assert_equal(out.results[0].status, STEP_FAIL, "FAIL, not PASS, not SKIPPED")
    assert_true(
        vs[0].starts() <= 4,
        "the retries are BOUNDED by the step's own round budget",
    )
    _ = vs^


def test_a_validator_that_refuses_to_rearm_keeps_its_first_verdict() raises:
    var vs = List[_FlakyDagValidator]()
    vs.append(_FlakyDagValidator(1, VALIDATION_FAIL, False))
    var reporter = CaptureReporter()
    var out = run_validation_dag[_FlakyDagValidator, CaptureReporter](
        vs, _one(String("send-message")), _no_deps(1), _budget(), reporter, 0
    )
    assert_false(
        out.passed,
        "a non-re-armable gate keeps the FAIL it reported (it would have PASSed"
        " on a second attempt — that second attempt must not happen)",
    )
    assert_equal(
        vs[0].starts(), 1, "started EXACTLY once — no second execution, no second message"
    )
    _ = vs^


def test_a_first_attempt_pass_is_not_re_run() raises:
    var vs = List[_FlakyDagValidator]()
    vs.append(_FlakyDagValidator(0, VALIDATION_FAIL))
    var reporter = CaptureReporter()
    var out = run_validation_dag[_FlakyDagValidator, CaptureReporter](
        vs, _one(String("livez")), _no_deps(1), _budget(), reporter, 0
    )
    assert_true(out.passed, "PASS on attempt 1")
    assert_equal(vs[0].starts(), 1, "a PASS is never re-launched")
    assert_equal(vs[0].polls(), 1, "and never re-polled")
    _ = vs^


def test_a_dependent_of_a_retried_step_still_runs() raises:
    var vs = List[_FlakyDagValidator]()
    vs.append(_FlakyDagValidator(1, VALIDATION_FAIL))
    vs.append(_FlakyDagValidator(0, VALIDATION_FAIL))
    var names = List[String]()
    names.append(String("livez"))
    names.append(String("api-e2e"))
    var deps = List[List[String]]()
    deps.append(List[String]())
    deps.append(_one(String("livez")))
    var reporter = CaptureReporter()
    var out = run_validation_dag[_FlakyDagValidator, CaptureReporter](
        vs, names^, deps^, _budget(), reporter, 0
    )
    assert_true(out.passed, "both steps PASS")
    assert_equal(
        out.results[1].status,
        STEP_PASS,
        "the dependent RAN — a retried dependency is not a failed one",
    )
    assert_true(vs[1].starts() >= 1, "the dependent actually started")
    _ = vs^


comptime _K: Int = 5


def _contains(hay: String, needle: String) -> Bool:
    return hay.find(needle) >= 0


struct _DeterministicDagValidator(DagValidator, Movable, Deinitable):

    var _changes_on: Int
    var _can_rearm: Bool
    var _starts: Int

    def __init__(out self, changes_on: Int = 0, can_rearm: Bool = True):
        self._changes_on = changes_on
        self._can_rearm = can_rearm
        self._starts = 0

    def starts(self) -> Int:
        return self._starts

    def start(mut self) raises:
        self._starts += 1

    def poll(mut self) raises -> Optional[ValidationOutcome]:
        var moved = self._changes_on > 0 and self._starts >= self._changes_on
        return Optional[ValidationOutcome](
            ValidationOutcome(
                VALIDATION_FAIL,
                1,
                String("CONFIG: relay identity unresolved")
                + (
                    String(" [after re-provision]")
                    if moved
                    else String("")
                ),
            )
        )

    def restart(mut self) raises -> Bool:
        return self._can_rearm

    def run_once(mut self) raises -> ValidationOutcome:
        self.start()
        var t = self.poll()
        if t:
            return t.value().copy()
        return ValidationOutcome.indeterminate(-1, String("running"))


def test_a_byte_identical_failure_stops_after_K_attempts() raises:
    var vs = List[_DeterministicDagValidator]()
    vs.append(_DeterministicDagValidator())
    var reporter = CaptureReporter()
    var out = run_validation_dag[_DeterministicDagValidator, CaptureReporter](
        vs,
        _one(String("relay-e2e")),
        _no_deps(1),
        PollBudget.of(200, 0),
        reporter,
        0,
    )
    assert_false(out.passed, "a step that never passes must still FAIL")
    assert_equal(out.results[0].status, STEP_FAIL, "FAIL, not SKIPPED, not PASS")
    assert_equal(
        vs[0].starts(),
        _K,
        "⛔ THE BURN. A gate whose answer has not changed in K attempts must be"
        " launched EXACTLY K times, not once per round of a budget derived from"
        " a per-EXECUTION deadline",
    )
    var summary = out.results[0].outcome.summary
    assert_true(
        _contains(summary, String("BYTE-IDENTICAL")),
        "⛔ the recorded reason must NAME the identical-outcome cause. Got: "
        + summary,
    )
    assert_true(
        _contains(summary, String("stopped retrying")),
        "and must say the retry STOPPED (not that it ran out). Got: " + summary,
    )
    assert_true(
        _contains(summary, String("CONFIG: relay identity unresolved")),
        "⛔ and the LAST REAL VERDICT must survive the rewrite — the same rule"
        " the timeout arm follows. Got: " + summary,
    )
    assert_true(
        summary.find(String("timeout")) < 0,
        "⛔ it must NOT read as a timeout: the budget was not exhausted, it was"
        " deliberately not spent. Got: " + summary,
    )
    assert_true(
        reporter.contains(String("BYTE-IDENTICAL on 5 consecutive attempt(s)")),
        "and the deploy LOG must distinguish it too — this is the line an"
        " operator greps when a wave goes red",
    )
    assert_false(
        reporter.contains(String("NOT safely re-runnable")),
        "⛔ and it must NOT be reported as the SAFETY refusal: this gate IS"
        " safely re-runnable, which is a different fault with a different fix",
    )
    _ = vs^


def test_a_changed_summary_RESETS_the_identical_counter() raises:
    var vs = List[_DeterministicDagValidator]()
    vs.append(_DeterministicDagValidator(changes_on=4))
    var reporter = CaptureReporter()
    var out = run_validation_dag[_DeterministicDagValidator, CaptureReporter](
        vs,
        _one(String("api-e2e")),
        _no_deps(1),
        PollBudget.of(200, 0),
        reporter,
        0,
    )
    assert_false(out.passed, "it still never passes, so it still FAILS")
    assert_equal(
        vs[0].starts(),
        3 + _K,
        "⛔ THE RESET. Three identical answers, then a DIFFERENT one, must buy a"
        " fresh K — a converging step is not a deterministic one",
    )
    _ = vs^


def test_a_changing_failure_is_still_retried_to_the_budget() raises:
    var vs = List[_FlakyDagValidator]()
    vs.append(_FlakyDagValidator(999, VALIDATION_FAIL))
    var reporter = CaptureReporter()
    var out = run_validation_dag[_FlakyDagValidator, CaptureReporter](
        vs,
        _one(String("still-converging")),
        _no_deps(1),
        PollBudget.of(12, 0),
        reporter,
        0,
    )
    assert_false(out.passed, "it never passes, so it FAILS")
    assert_equal(
        vs[0].starts(),
        12,
        "⛔ A CHANGING FAILURE MUST KEEP ITS WHOLE BUDGET. If this reads 5, the"
        " stop-rule is firing on evidence that is not identical and has become"
        " 'give up early on everything'",
    )
    assert_true(
        out.results[0].outcome.summary.find(String("BYTE-IDENTICAL")) < 0,
        "and it must NOT be reported as a deterministic stop — it exhausted its"
        " budget, which is a different fault: "
        + out.results[0].outcome.summary,
    )
    _ = vs^


struct _ExecNonceDagValidator(DagValidator, Movable, Deinitable):

    var _vary_key: Int
    var _starts: Int

    def __init__(out self, vary_key: Bool = False):
        self._vary_key = 1 if vary_key else 0
        self._starts = 0

    def starts(self) -> Int:
        return self._starts

    def start(mut self) raises:
        self._starts += 1

    def poll(mut self) raises -> Optional[ValidationOutcome]:
        var key = String("cloud-run job 'relay-e2e' execution failed")
        var summary = (
            String("cloud-run job 'relay-e2e' execution failed:")
            + String(" Cloud Run job execution example-relay-e2e-")
            + String(self._starts)
            + String(" failed (failedCount=1)")
        )
        if self._vary_key == 1:
            summary = String(
                "cloud-run job 'still-converging' execution failed:"
                " a task exited non-zero"
            )
            key += String(" [round ") + String(self._starts) + String("]")
        return Optional[ValidationOutcome](
            ValidationOutcome.failed(1, summary^, String(""), key^)
        )

    def restart(mut self) raises -> Bool:
        return True

    def run_once(mut self) raises -> ValidationOutcome:
        self.start()
        var t = self.poll()
        if t:
            return t.value().copy()
        return ValidationOutcome.indeterminate(-1, String("running"))


def test_a_per_attempt_token_does_not_defeat_the_stop() raises:
    var vs = List[_ExecNonceDagValidator]()
    vs.append(_ExecNonceDagValidator())
    var reporter = CaptureReporter()
    var out = run_validation_dag[_ExecNonceDagValidator, CaptureReporter](
        vs,
        _one(String("relay-e2e")),
        _no_deps(1),
        PollBudget.of(200, 0),
        reporter,
        0,
    )
    assert_false(out.passed, "a step that never passes must still FAIL")
    assert_equal(
        vs[0].starts(),
        _K,
        "⛔ THE BURN. A failure whose only per-attempt difference is the"
        " execution id must be launched EXACTLY K times — the nonce is EVIDENCE,"
        " not a changed answer",
    )
    var summary = out.results[0].outcome.summary
    assert_true(
        _contains(summary, String("BYTE-IDENTICAL")),
        "it must be reported as the identical-outcome stop. Got: " + summary,
    )
    assert_true(
        _contains(summary, String("example-relay-e2e-5")),
        "⛔ AND THE EXECUTION ID MUST SURVIVE IN THE REPORT. The key moved the"
        " identity out of the COMPARISON, not out of the operator's line — that"
        " id is how they go read the run. Got: " + summary,
    )
    _ = vs^


def test_a_changing_repeat_key_keeps_the_whole_budget() raises:
    var vs = List[_ExecNonceDagValidator]()
    vs.append(_ExecNonceDagValidator(vary_key=True))
    var reporter = CaptureReporter()
    var out = run_validation_dag[_ExecNonceDagValidator, CaptureReporter](
        vs,
        _one(String("still-converging")),
        _no_deps(1),
        PollBudget.of(12, 0),
        reporter,
        0,
    )
    assert_false(out.passed, "it never passes, so it FAILS")
    assert_equal(
        vs[0].starts(),
        12,
        "⛔ A CHANGING CAUSE MUST KEEP ITS WHOLE BUDGET. This step's SUMMARY is"
        " byte-identical every attempt, so 5 here means the DAG is still"
        " comparing the summary and a conformer can no longer say 'still"
        " moving'",
    )
    assert_true(
        out.results[0].outcome.summary.find(String("BYTE-IDENTICAL")) < 0,
        "and it must NOT be reported as a deterministic stop: "
        + out.results[0].outcome.summary,
    )
    _ = vs^


comptime _PROD_INTERVAL_MS: Int = 5000
comptime _PROD_FLOOR_ROUNDS: Int = 18
comptime _IN_CLOUD_ROUNDS_PER_ATTEMPT: Int = 4


def test_the_stop_needs_a_wall_and_not_only_a_count() raises:
    assert_equal(
        derived_identical_outcome_rounds(_PROD_INTERVAL_MS),
        _PROD_FLOOR_ROUNDS,
        "⛔ the settling floor at the production interval must be 18 rounds ="
        " 90s. If this moved, IDENTICAL_OUTCOME_MIN_WALL_S moved, and that is a"
        " policy change that must be read against the ~35-90s IAM propagation"
        " window",
    )

    assert_false(
        identical_outcome_stop_is_due(_K, _K - 1, _PROD_INTERVAL_MS),
        "⛔ THE COUNT-ONLY REGRESSION. K identical answers from a one-round"
        " conformer span 4 rounds = 20s — INSIDE the propagation window this"
        " retry exists to survive. Stopping here reds a gate that would have"
        " gone green, which is the case the retry was built for",
    )
    assert_false(
        identical_outcome_stop_is_due(
            _PROD_FLOOR_ROUNDS, _PROD_FLOOR_ROUNDS - 1, _PROD_INTERVAL_MS
        ),
        "and it must still not stop one round short of the floor (85s < 90s) —"
        " a floor that is 'about right' is a floor that was chosen, not derived",
    )
    assert_true(
        identical_outcome_stop_is_due(
            _PROD_FLOOR_ROUNDS + 1, _PROD_FLOOR_ROUNDS, _PROD_INTERVAL_MS
        ),
        "⛔ ANTI-VACUITY FOR DIRECTION A. Once the streak HAS spanned 90s the"
        " stop must fire — 19 cheap probes, not the whole 60-round budget. A"
        " rule that never stops a health probe is 'delete the stop-rule'",
    )

    assert_false(
        identical_outcome_stop_is_due(
            _K, _IN_CLOUD_ROUNDS_PER_ATTEMPT * (_K - 1), _PROD_INTERVAL_MS
        ),
        "at K the in-cloud streak has spanned 16 rounds = 80s, still short of"
        " the 90s floor",
    )
    assert_true(
        identical_outcome_stop_is_due(
            _K + 1, _IN_CLOUD_ROUNDS_PER_ATTEMPT * _K, _PROD_INTERVAL_MS
        ),
        "⛔ THE BURN MUST STAY FIXED. One attempt later the streak has spanned"
        " 20 rounds = 100s and the stop MUST fire: 6 launches / ~114s instead of"
        " re-launching for the whole derived budget. If this reads False the"
        " wall floor has been sized so large it re-opens the storm",
    )

    assert_false(
        identical_outcome_stop_is_due(_K - 1, 100000, _PROD_INTERVAL_MS),
        "⛔ ANDed, NEVER ORed. An enormous wall must not license a stop on"
        " fewer than K identical answers — 'the same answer twice' is not"
        " evidence of a deterministic failure",
    )
    assert_false(
        identical_outcome_stop_is_due(2, 100000, 60000),
        "and the same at a 60s interval, which is where a wall-only rule would"
        " terminate on TWO answers",
    )

    assert_equal(
        derived_identical_outcome_rounds(0),
        0,
        "a round that costs no wall measures no wall — the time floor is"
        " vacuous on the hermetic path, exactly as derived_step_poll_attempts"
        " leaves the ceiling alone there",
    )
    assert_true(
        identical_outcome_stop_is_due(_K, 0, 0),
        "⛔ COMPATIBILITY. At interval 0 the rule must be EXACTLY K — every"
        " hermetic case in this file, and any in-cloud end-to-end test, drive"
        " that path and must be byte-identical",
    )


def test_a_fast_deterministic_step_keeps_its_budget_inside_the_window() raises:
    var vs = List[_DeterministicDagValidator]()
    vs.append(_DeterministicDagValidator())
    var reporter = CaptureReporter()
    var out = run_validation_dag[_DeterministicDagValidator, CaptureReporter](
        vs,
        _one(String("api-e2e")),
        _no_deps(1),
        PollBudget.of(8, 100),
        reporter,
        0,
    )
    assert_false(out.passed, "it never passes, so it still FAILS")
    assert_equal(
        vs[0].starts(),
        8,
        "⛔ THE COUNT-ONLY REGRESSION, END TO END. At a REAL poll interval a"
        " one-round-per-attempt step whose streak has not yet spanned the"
        " settling floor keeps every round of its budget. 5 here means the"
        " scheduler is still deciding on the COUNT alone and a propagation"
        " window is again a red gate",
    )
    assert_true(
        out.results[0].outcome.summary.find(String("BYTE-IDENTICAL")) < 0,
        "and it must NOT be recorded as a deterministic stop — the budget ran"
        " out, which is a different fault with a different next action: "
        + out.results[0].outcome.summary,
    )
    assert_false(
        reporter.contains(String("BYTE-IDENTICAL")),
        "⛔ nor may the deploy LOG say it stopped for repetition. That is the"
        " line an operator greps, and it would send them to the config when the"
        " world may still have been settling",
    )
    _ = vs^


def test_the_deterministic_stop_reports_the_wall_it_required() raises:
    var vs = List[_DeterministicDagValidator]()
    vs.append(_DeterministicDagValidator())
    var reporter = CaptureReporter()
    var out = run_validation_dag[_DeterministicDagValidator, CaptureReporter](
        vs,
        _one(String("relay-e2e")),
        _no_deps(1),
        PollBudget.of(200, 0),
        reporter,
        0,
    )
    assert_equal(
        vs[0].starts(),
        _K,
        "the hermetic path must still stop at exactly K — every other case in"
        " this file and the in-cloud end-to-end falsifier depend on it",
    )
    assert_true(
        reporter.contains(String("settling floor")),
        "⛔ THE LINE MUST NAME THE SECOND FLOOR. A stop reported as a bare"
        " count is unfalsifiable to its reader: it looks the same whether the"
        " streak spanned 20 seconds or 20 minutes",
    )
    assert_true(
        _contains(out.results[0].outcome.summary, String("settling floor")),
        "and so must the recorded verdict, for the same reason the verdict"
        " already has to say this is not budget exhaustion. Got: "
        + out.results[0].outcome.summary,
    )
    _ = vs^


def test_a_self_healing_gate_is_not_retried_into_a_green() raises:
    var control = List[_FlakyDagValidator]()
    control.append(_FlakyDagValidator(1, VALIDATION_FAIL, True))
    var control_reporter = CaptureReporter()
    var control_out = run_validation_dag[
        _FlakyDagValidator, CaptureReporter
    ](
        control,
        _one(String("cloud-leak-enforce")),
        _no_deps(1),
        _budget(),
        control_reporter,
        0,
    )
    assert_true(
        control_out.passed,
        "⛔ THE CONTROL MUST GO GREEN. A self-healing gate that is re-armable is"
        " retried and its second attempt passes — that IS the defect. If this"
        " assertion fails, the SUBJECT arm below proves nothing, because the"
        " double could not have flipped in the first place.",
    )
    assert_equal(control[0].starts(), 2, "the control really did run twice")
    _ = control^

    var vs = List[_FlakyDagValidator]()
    vs.append(_FlakyDagValidator(1, VALIDATION_FAIL, False))
    var reporter = CaptureReporter()
    var out = run_validation_dag[_FlakyDagValidator, CaptureReporter](
        vs,
        _one(String("cloud-leak-enforce")),
        _no_deps(1),
        _budget(),
        reporter,
        0,
    )
    assert_false(
        out.passed,
        "a gate that mutates what it observes keeps its FIRST verdict — the"
        " wave LEAKED, and the scheduler may not erase that by asking again",
    )
    assert_equal(
        out.results[0].status,
        STEP_FAIL,
        "FAIL, not PASS and not SKIPPED — a cleaned-up leak is still a red run",
    )
    assert_equal(
        vs[0].starts(),
        1,
        "started EXACTLY once. A second start is a second FLEET SCAN, and under"
        " --enforce a second scan is a second DELETE",
    )
    assert_true(
        reporter.contains(String("NOT safely re-runnable")),
        "⛔ AND THE REPORT MUST SAY WHY IT WAS NOT RETRIED. A red step that"
        " stopped after one attempt reads like budget exhaustion otherwise, and"
        " sends the operator at the poll budget — the one thing that was never"
        " the problem here",
    )
    _ = vs^


struct _ClassifiedFailureValidator(DagValidator, Movable, Deinitable):

    var _state_from: Int
    var _pass_on: Int
    var _can_rearm: Bool
    var _starts: Int
    var _teardowns: Int

    def __init__(
        out self,
        state_from: Int,
        pass_on: Int = 0,
        can_rearm: Bool = True,
    ):
        self._state_from = state_from
        self._pass_on = pass_on
        self._can_rearm = can_rearm
        self._starts = 0
        self._teardowns = 0

    def starts(self) -> Int:
        return self._starts

    def teardown_calls(self) -> Int:
        return self._teardowns

    def start(mut self) raises:
        self._starts += 1

    def poll(mut self) raises -> Optional[ValidationOutcome]:
        if self._pass_on > 0 and self._starts >= self._pass_on:
            return Optional[ValidationOutcome](
                ValidationOutcome.passed(0, String("VERDICT: PASS (7/7 rows)"))
            )
        var reason = String("")
        if self._state_from > 0 and self._starts >= self._state_from:
            reason = String(
                "the Google OAuth refresh grant was REFUSED (invalid_grant):"
                " only a human completing the one-time consent capture can"
                " change this answer"
            )
        return Optional[ValidationOutcome](
            ValidationOutcome.failed(
                1,
                String(
                    "VERDICT: FAIL (4/7 rows) — access_token_mint: Google token"
                    " endpoint -> HTTP 400 error=invalid_grant"
                ),
                String(""),
                String(""),
                reason^,
            )
        )

    def restart(mut self) raises -> Bool:
        return self._can_rearm

    def teardown(mut self) raises:
        self._teardowns += 1

    def run_once(mut self) raises -> ValidationOutcome:
        self.start()
        var t = self.poll()
        if t:
            return t.value().copy()
        return ValidationOutcome.indeterminate(-1, String("running"))


def test_a_stated_no_retry_reason_is_attempted_exactly_once() raises:
    var vs = List[_ClassifiedFailureValidator]()
    vs.append(_ClassifiedFailureValidator(1))
    var reporter = CaptureReporter()
    var out = run_validation_dag[_ClassifiedFailureValidator, CaptureReporter](
        vs,
        _one(String("bootstrap-test")),
        _no_deps(1),
        PollBudget.of(20, 0),
        reporter,
        0,
    )
    assert_false(out.passed, "a credential refusal is still a RED wave")
    assert_equal(out.results[0].status, STEP_FAIL, "FAIL, not SKIPPED")
    assert_equal(
        vs[0].starts(),
        1,
        "a failure whose producer states that no attempt can differ must be"
        " LAUNCHED ONCE — every further launch is a Cloud Run Job created to"
        " re-ask a question only a human can answer",
    )
    _ = vs^


def test_a_terminal_credential_refusal_still_runs_its_teardown() raises:
    var vs = List[_ClassifiedFailureValidator]()
    vs.append(_ClassifiedFailureValidator(1))
    var reporter = CaptureReporter()
    var out = run_validation_dag[_ClassifiedFailureValidator, CaptureReporter](
        vs,
        _one(String("bootstrap-test")),
        _no_deps(1),
        PollBudget.of(20, 0),
        reporter,
        0,
    )
    assert_equal(
        vs[0].teardown_calls(),
        1,
        "the terminal step's teardown ran EXACTLY once — a stopped retry that"
        " leaks its job has traded one red for a worse one",
    )
    assert_true(
        _contains(
            out.results[0].teardown_reason,
            String(TEARDOWN_PATH_WAVE_COMPLETED),
        ),
        "and it was released on the ORDINARY end-of-wave path, which is what"
        " lets the wave go on to reach its terminal cloud-leak gate — a"
        " scheduler fault would stamp a different path and mean something else",
    )
    _ = vs^


def test_a_failure_that_states_no_reason_is_still_retried_to_PASS() raises:
    var vs = List[_ClassifiedFailureValidator]()
    vs.append(_ClassifiedFailureValidator(0, 3))
    var reporter = CaptureReporter()
    var out = run_validation_dag[_ClassifiedFailureValidator, CaptureReporter](
        vs,
        _one(String("api-e2e")),
        _no_deps(1),
        PollBudget.of(20, 0),
        reporter,
        0,
    )
    assert_true(
        out.passed,
        "a failure that states no reason is TRANSIENT as far as the scheduler is"
        " concerned, and must reach its PASS",
    )
    assert_equal(vs[0].starts(), 3, "three launches — the budget was spent")
    _ = vs^


def test_a_reason_stated_on_a_LATER_attempt_stops_the_step_there() raises:
    var vs = List[_ClassifiedFailureValidator]()
    vs.append(_ClassifiedFailureValidator(2))
    var reporter = CaptureReporter()
    var out = run_validation_dag[_ClassifiedFailureValidator, CaptureReporter](
        vs,
        _one(String("bootstrap-test")),
        _no_deps(1),
        PollBudget.of(20, 0),
        reporter,
        0,
    )
    assert_false(out.passed, "still red")
    assert_equal(
        vs[0].starts(),
        2,
        "attempt 1 stated nothing and was RIGHTLY retried; attempt 2 stated the"
        " reason and ended the step there",
    )
    _ = vs^


def test_the_report_states_the_reason_the_step_was_not_retried() raises:
    var vs = List[_ClassifiedFailureValidator]()
    vs.append(_ClassifiedFailureValidator(1))
    var reporter = CaptureReporter()
    var out = run_validation_dag[_ClassifiedFailureValidator, CaptureReporter](
        vs,
        _one(String("bootstrap-test")),
        _no_deps(1),
        PollBudget.of(20, 0),
        reporter,
        0,
    )
    assert_true(
        reporter.contains(String("not retried")),
        "the report must say the step was not retried",
    )
    assert_true(
        reporter.contains(String("consent capture")),
        "and it must carry the PRODUCER's own sentence — the scheduler has no"
        " words of its own about a credential and must not invent any",
    )
    assert_false(
        reporter.contains(String("timeout after")),
        "⛔ AND IT MUST NOT READ AS A TIMEOUT. The budget was deliberately NOT"
        " spent; reporting exhaustion would send the operator to --poll-attempts",
    )
    var summary = out.results[0].outcome.summary.copy()
    assert_true(
        _contains(summary, String("invalid_grant")),
        "the DURABLE record keeps the validator's own verdict — a stop that"
        " reported less than a single failure would have is a regression",
    )
    assert_true(
        _contains(summary, String("consent capture")),
        "and it states why no further attempt was made, where a reader finds it"
        " a day later",
    )
    _ = vs^


def test_a_non_rearmable_gate_still_reports_the_rearm_reason() raises:
    var vs = List[_ClassifiedFailureValidator]()
    vs.append(_ClassifiedFailureValidator(1, 0, False))
    var reporter = CaptureReporter()
    var out = run_validation_dag[_ClassifiedFailureValidator, CaptureReporter](
        vs,
        _one(String("send-message")),
        _no_deps(1),
        PollBudget.of(20, 0),
        reporter,
        0,
    )
    assert_false(out.passed, "still red")
    assert_equal(vs[0].starts(), 1, "started exactly once either way")
    assert_true(
        reporter.contains(String("NOT safely re-runnable")),
        "the SAFETY axis is the one that stopped this step and the report names"
        " it — the axes are ANDed, and the note reports the nearest cause",
    )
    _ = vs^


def test_a_wave_completes_around_a_terminal_step() raises:
    var vs = List[_ClassifiedFailureValidator]()
    vs.append(_ClassifiedFailureValidator(1))
    vs.append(_ClassifiedFailureValidator(0, 1))
    var names = List[String]()
    names.append(String("bootstrap-test"))
    names.append(String("bootstrap-e2e-lifecycle"))
    var deps = List[List[String]]()
    deps.append(List[String]())
    deps.append(_one(String("bootstrap-test")))
    var reporter = CaptureReporter()
    var out = run_validation_dag[_ClassifiedFailureValidator, CaptureReporter](
        vs, names, deps, PollBudget.of(20, 0), reporter, 0
    )
    assert_false(out.passed, "the wave is red")
    assert_equal(out.results[0].status, STEP_FAIL, "the refusal FAILED")
    assert_equal(
        out.results[1].status,
        STEP_SKIPPED,
        "its dependent is SKIPPED with the dependency named — a terminal verdict"
        " propagates exactly like any other non-PASS",
    )
    assert_equal(vs[0].starts(), 1, "one launch for the terminal step")
    assert_equal(vs[1].starts(), 0, "the dependent never launched")
    assert_equal(
        vs[0].teardown_calls(), 1, "the terminal step was released"
    )
    assert_equal(
        vs[1].teardown_calls(),
        1,
        "⚠ AND SO WAS THE SKIPPED ONE. `run_validation_dag` tears down EVERY"
        " validator in the wave, not only the ones that started — that is what"
        " makes the wave's terminal leak gate answerable",
    )
    _ = vs^


def main() raises:
    test_a_transient_non_pass_is_retried_to_PASS()
    print("  test_a_transient_non_pass_is_retried_to_PASS: PASS")
    test_a_transient_FAIL_is_retried_to_PASS()
    print("  test_a_transient_FAIL_is_retried_to_PASS: PASS")
    test_a_permanently_failing_step_still_FAILS()
    print("  test_a_permanently_failing_step_still_FAILS: PASS")
    test_a_validator_that_refuses_to_rearm_keeps_its_first_verdict()
    print("  test_a_validator_that_refuses_to_rearm_keeps_its_first_verdict: PASS")
    test_a_first_attempt_pass_is_not_re_run()
    print("  test_a_first_attempt_pass_is_not_re_run: PASS")
    test_a_dependent_of_a_retried_step_still_runs()
    print("  test_a_dependent_of_a_retried_step_still_runs: PASS")
    test_a_byte_identical_failure_stops_after_K_attempts()
    print("  test_a_byte_identical_failure_stops_after_K_attempts: PASS")
    test_a_changed_summary_RESETS_the_identical_counter()
    print("  test_a_changed_summary_RESETS_the_identical_counter: PASS")
    test_a_changing_failure_is_still_retried_to_the_budget()
    print("  test_a_changing_failure_is_still_retried_to_the_budget: PASS")
    test_a_per_attempt_token_does_not_defeat_the_stop()
    print("  test_a_per_attempt_token_does_not_defeat_the_stop: PASS")
    test_a_changing_repeat_key_keeps_the_whole_budget()
    print("  test_a_changing_repeat_key_keeps_the_whole_budget: PASS")
    test_the_stop_needs_a_wall_and_not_only_a_count()
    print("  test_the_stop_needs_a_wall_and_not_only_a_count: PASS")
    test_a_fast_deterministic_step_keeps_its_budget_inside_the_window()
    print(
        "  test_a_fast_deterministic_step_keeps_its_budget_inside_the_window:"
        " PASS"
    )
    test_the_deterministic_stop_reports_the_wall_it_required()
    print("  test_the_deterministic_stop_reports_the_wall_it_required: PASS")
    test_a_self_healing_gate_is_not_retried_into_a_green()
    print("  test_a_self_healing_gate_is_not_retried_into_a_green: PASS")
    test_a_stated_no_retry_reason_is_attempted_exactly_once()
    print("  test_a_stated_no_retry_reason_is_attempted_exactly_once: PASS")
    test_a_terminal_credential_refusal_still_runs_its_teardown()
    print("  test_a_terminal_credential_refusal_still_runs_its_teardown: PASS")
    test_a_failure_that_states_no_reason_is_still_retried_to_PASS()
    print("  test_a_failure_that_states_no_reason_is_still_retried_to_PASS: PASS")
    test_a_reason_stated_on_a_LATER_attempt_stops_the_step_there()
    print("  test_a_reason_stated_on_a_LATER_attempt_stops_the_step_there: PASS")
    test_the_report_states_the_reason_the_step_was_not_retried()
    print("  test_the_report_states_the_reason_the_step_was_not_retried: PASS")
    test_a_non_rearmable_gate_still_reports_the_rearm_reason()
    print("  test_a_non_rearmable_gate_still_reports_the_rearm_reason: PASS")
    test_a_wave_completes_around_a_terminal_step()
    print("  test_a_wave_completes_around_a_terminal_step: PASS")
    print("test_validation_dag_retries_transient: ALL PASS")
