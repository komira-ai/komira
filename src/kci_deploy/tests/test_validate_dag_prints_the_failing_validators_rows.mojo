# =============================================================================
# test_validate_dag_prints_the_failing_validators_rows -- a FAILING validate step prints its validator's OWN rows.
#
# A red step whose only visible output is `FAIL (VERDICT: FAIL)` cannot be
# diagnosed from the deploy log. These cases pin that the failing row's text
# reaches the report through `ValidationOutcome.detail`, bounded (last N lines,
# clipped lines) and redacted, that a passing step prints nothing extra, and
# that a validator with no output says so.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from kci_deploy import (
    run_validation_dag,
    render_validator_output_tail,
    parse_verdict,
    DagValidator,
    ValidationOutcome,
    PollBudget,
    CaptureReporter,
    STEP_PASS,
    STEP_FAIL,
    VALIDATION_FAIL,
    VALIDATION_INDETERMINATE,
)


comptime _FAILING_ROW: String = (
    "[FAIL] wk-claims-a-job: expected phase ASSIGNED within 30s, observed"
    " PENDING after 13 ticks (job 0f1e2d3c-4b5a-4968-8778-695a4b3c2d1e)"
)

comptime _PASSING_ROW: String = "[PASS] wk-reachable: GET /health -> 200 in 8ms"

comptime _VALIDATOR_STDOUT: String = (
    _PASSING_ROW + "\n" + _FAILING_ROW + "\nVERDICT: FAIL (3/4 rows)\n"
)


def _contains(hay: String, needle: String) -> Bool:
    return hay.find(needle) >= 0


struct _RowPrintingStep(DagValidator, Movable, Deinitable):

    var _stdout: String
    var _exit_code: Int
    var _stall_after_first_answer: Bool
    var _stalled: Bool
    var _polls: Int

    def __init__(
        out self,
        var stdout: String,
        exit_code: Int,
        stall_after_first_answer: Bool = False,
    ):
        self._stdout = stdout^
        self._exit_code = exit_code
        self._stall_after_first_answer = stall_after_first_answer
        self._stalled = False
        self._polls = 0

    def start(mut self) raises:
        pass

    def poll(mut self) raises -> Optional[ValidationOutcome]:
        self._polls += 1
        if self._stalled:
            return None
        return Optional[ValidationOutcome](
            parse_verdict(self._stdout, self._exit_code)
        )

    def restart(mut self) raises -> Bool:
        if self._stall_after_first_answer:
            self._stalled = True
        return True

    def run_once(mut self) raises -> ValidationOutcome:
        self.start()
        var t = self.poll()
        if t:
            return t.value().copy()
        return ValidationOutcome.indeterminate(-1, String("running"))


struct _QuietStep(DagValidator, Movable, Deinitable):

    var _passes: Bool

    def __init__(out self, passes: Bool):
        self._passes = passes

    def start(mut self) raises:
        pass

    def poll(mut self) raises -> Optional[ValidationOutcome]:
        if self._passes:
            return Optional[ValidationOutcome](
                ValidationOutcome.passed(200, String("health 200"))
            )
        return Optional[ValidationOutcome](
            ValidationOutcome.failed(503, String("health 503"))
        )

    def restart(mut self) raises -> Bool:
        return False

    def run_once(mut self) raises -> ValidationOutcome:
        var t = self.poll()
        return t.value().copy()


def _one_step_names(var name: String) -> List[String]:
    var v = List[String]()
    v.append(name^)
    return v^


def _no_deps(n: Int) -> List[List[String]]:
    var d = List[List[String]]()
    for _i in range(n):
        d.append(List[String]())
    return d^


def _budget(rounds: Int = 1) -> PollBudget:
    return PollBudget.of(rounds, 0)


def test_bug_a_failing_step_prints_the_validators_own_rows() raises:
    print("  (r1) a failing step must print the validator's rows...")

    var vs = List[_RowPrintingStep]()
    vs.append(_RowPrintingStep(_VALIDATOR_STDOUT, 1))

    var reporter = CaptureReporter()
    var out = run_validation_dag[_RowPrintingStep, CaptureReporter](
        vs,
        _one_step_names(String("wk-claims-a-job")),
        _no_deps(1),
        _budget(1),
        reporter,
        0,
    )

    assert_false(out.passed, "a FAIL verdict must not pass the DAG")
    assert_equal(out.results[0].status, STEP_FAIL, "the step must be STEP_FAIL")
    assert_true(
        reporter.contains(String("VERDICT: FAIL")),
        "CONTROL: the bare verdict token is still reported — the rows are"
        " added alongside the verdict line, not substituted for it",
    )
    assert_true(
        reporter.contains(
            String("expected phase ASSIGNED within 30s, observed PENDING")
        ),
        "⛔ THE FAILING ROW'S OWN TEXT IS NOT IN THE REPORT. This is the"
        " defect this guards: a red validate step whose only operator-visible"
        " output is `FAIL (VERDICT: FAIL)`, leaving no way to diagnose it from"
        " the deploy log",
    )
    assert_true(
        reporter.contains(String("its validator's own output")),
        "the rows must be introduced by a line saying whose output they are —"
        " an unlabelled block pasted under a verdict reads as the deploy"
        " tool's own output, which sends the reader to the wrong code",
    )
    assert_true(
        _contains(out.results[0].outcome.detail, _FAILING_ROW),
        "the StepResult's own outcome must carry the rows — a report that lives"
        " only in the printed line cannot be re-rendered by any other frontend",
    )


def test_bug_a_timed_out_step_keeps_the_rows_of_its_last_attempt() raises:
    print("  (r2) a timed-out step must keep its last attempt's rows...")

    var vs = List[_RowPrintingStep]()
    vs.append(_RowPrintingStep(_VALIDATOR_STDOUT, 1, True))

    var reporter = CaptureReporter()
    var out = run_validation_dag[_RowPrintingStep, CaptureReporter](
        vs,
        _one_step_names(String("wk-claims-a-job")),
        _no_deps(1),
        _budget(3),
        reporter,
        0,
    )

    assert_equal(out.results[0].status, STEP_FAIL, "the step must be STEP_FAIL")
    assert_true(
        _contains(out.results[0].outcome.summary, String("timeout after")),
        "CONTROL: this case must actually reach the TIMEOUT arm, not the"
        " ordinary verdict arm — otherwise it proves nothing about the rewrite",
    )
    assert_true(
        _contains(out.results[0].outcome.detail, _FAILING_ROW),
        "⛔ the timeout rewrite DROPPED the rows of the last real attempt. A"
        " step that answered N times must not report less than one that"
        " answered once",
    )
    assert_true(
        reporter.contains(
            String("expected phase ASSIGNED within 30s, observed PENDING")
        ),
        "and the rows must be PRINTED on the timeout arm too",
    )


def test_a_passing_step_adds_no_output_block() raises:
    print("  (r3) a passing step must add no output block...")

    var vs = List[_RowPrintingStep]()
    vs.append(
        _RowPrintingStep(
            _PASSING_ROW + String("\nVERDICT: PASS (4/4 rows)\n"), 0
        )
    )

    var reporter = CaptureReporter()
    var out = run_validation_dag[_RowPrintingStep, CaptureReporter](
        vs,
        _one_step_names(String("wk-reachable")),
        _no_deps(1),
        _budget(1),
        reporter,
        0,
    )

    assert_true(out.passed, "CONTROL: this step must actually PASS")
    assert_equal(out.results[0].status, STEP_PASS, "the step must be STEP_PASS")
    assert_false(
        out.results[0].outcome.has_detail(),
        "a PASSING outcome must carry NO detail",
    )
    assert_false(
        reporter.contains(String("validator output")),
        "a passing step must not print an output block",
    )
    assert_false(
        reporter.contains(String("its validator's own output")),
        "a passing step must not print the enrichment header",
    )


def test_a_conformer_with_no_output_prints_nothing() raises:
    print("  (r4) a conformer with no output must print nothing...")

    var vs = List[_QuietStep]()
    vs.append(_QuietStep(False))

    var reporter = CaptureReporter()
    var out = run_validation_dag[_QuietStep, CaptureReporter](
        vs,
        _one_step_names(String("edge-livez")),
        _no_deps(1),
        _budget(1),
        reporter,
        0,
    )

    assert_equal(out.results[0].status, STEP_FAIL, "CONTROL: it must FAIL")
    assert_true(
        reporter.contains(String("health 503")),
        "CONTROL: the health verdict must still be reported",
    )
    assert_false(
        reporter.contains(String("its validator's own output")),
        "⛔ a conformer with no output must not grow an empty enrichment"
        " header — byte-identical to the report before this seam existed",
    )


def test_parse_verdict_attaches_rows_on_every_non_pass_and_none_on_pass() raises:
    print("  (r5) parse_verdict must attach the rows on every non-pass...")

    var failed = parse_verdict(_VALIDATOR_STDOUT, 1)
    assert_equal(failed.verdict, VALIDATION_FAIL, "CONTROL: FAIL")
    assert_true(
        _contains(failed.detail, _FAILING_ROW),
        "a FAIL must carry the rows",
    )

    var indeterminate = parse_verdict(
        String("[FAIL] wk-claims-a-job: the process died before its verdict\n"),
        139,
    )
    assert_equal(
        indeterminate.verdict,
        VALIDATION_INDETERMINATE,
        "CONTROL: no VERDICT line ⇒ INDETERMINATE",
    )
    assert_true(
        _contains(indeterminate.detail, String("died before its verdict")),
        "⛔ INDETERMINATE is the arm where the output matters MOST — there is no"
        " verdict line to read, so whatever the validator managed to print is"
        " the only evidence that exists",
    )

    var contradicted = parse_verdict(
        _PASSING_ROW + String("\nVERDICT: PASS (4/4 rows)\n"), 7
    )
    assert_equal(
        contradicted.verdict, VALIDATION_FAIL, "CONTROL: exit 7 ⇒ FAIL"
    )
    assert_true(
        contradicted.has_detail(),
        "a PASS contradicted by the exit code must carry the output — the"
        " contradiction is the whole question",
    )

    var passed = parse_verdict(
        _PASSING_ROW + String("\nVERDICT: PASS (4/4 rows)\n"), 0
    )
    assert_false(
        passed.has_detail(), "a clean PASS must carry NOTHING (see r3)"
    )


def test_the_output_tail_is_bounded_and_states_every_cut() raises:
    print("  (r6) the tail must be bounded and state its cuts...")

    var many = String("")
    for i in range(800):
        many += String("[PASS] row ") + String(i) + String("\n")
    many += _FAILING_ROW + String("\nVERDICT: FAIL\n")

    var rendered = render_validator_output_tail(many)
    assert_true(
        _contains(rendered, _FAILING_ROW),
        "the TAIL is kept, so the failing row (which is at the END) survives",
    )
    assert_false(
        _contains(rendered, String("[PASS] row 0\n")),
        "the head must be dropped — 800 passing rows are not the answer",
    )
    assert_true(
        _contains(rendered, String("EARLIER line(s) omitted")),
        "⛔ a SILENT truncation is a truncated report that reads like a"
        " complete one",
    )

    var long_line = String("")
    for _i in range(200):
        long_line += String("0123456789")
    var clipped = render_validator_output_tail(long_line + String("\n"))
    assert_true(
        _contains(clipped, String("line clipped:")),
        "an over-long line must be clipped WITH the cut stated",
    )
    assert_true(
        clipped.byte_length() < 2000,
        "a 2000-byte line must not ride out whole",
    )

    assert_equal(
        render_validator_output_tail(String("")).byte_length(),
        0,
        "no output ⇒ no block (see r4)",
    )
    assert_true(
        _contains(
            render_validator_output_tail(String("   \n\n  \n")),
            String("produced NO OUTPUT"),
        ),
        "a validator that RAN and printed only whitespace is an ANSWER, not"
        " blank space — rendering it blank is how a reader concludes the tool"
        " is broken",
    )


def test_the_clip_never_cuts_a_multibyte_character() raises:
    print("  (r7) the clip must never cut a multi-byte character...")

    var star_line = String("")
    for _i in range(400):
        star_line += String("★")
    var rendered = render_validator_output_tail(star_line + String("\n"))
    assert_true(
        _contains(rendered, String("line clipped:")),
        "CONTROL: this line must actually be long enough to be clipped —"
        " otherwise the codepoint walk-back is never exercised",
    )
    assert_true(
        _contains(rendered, String("★")),
        "the kept head must still be readable text",
    )

    for cap in range(1, 40):
        var one = render_validator_output_tail(
            String("★★★★★★★★★★\n"), 40, cap
        )
        assert_true(
            one.byte_length() > 0,
            "a clip at any byte ceiling must produce a rendered block",
        )


def test_a_credential_shaped_row_is_redacted() raises:
    print("  (r8) a credential-shaped row must be redacted...")

    var rendered = render_validator_output_tail(
        String("[FAIL] edge: request refused\n")
        + String("  sent: Authorization: Bearer ya29.A0AfHKSVERYSECRETVALUE\n")
        + String("VERDICT: FAIL\n")
    )
    assert_false(
        _contains(rendered, String("ya29.A0AfHKSVERYSECRETVALUE")),
        "⛔ a bearer token from a validator row reached the deploy log verbatim",
    )
    assert_true(
        _contains(rendered, String("[REDACTED]")),
        "and the redaction must be LOUD — a redaction an operator cannot see is"
        " a diagnosis they will make wrongly",
    )
    assert_true(
        _contains(rendered, String("[FAIL] edge: request refused")),
        "CONTROL: the ordinary rows must survive the scrub",
    )


def main() raises:
    print(
        "test_validate_dag_prints_the_failing_validators_rows: a red validate"
        " step must be diagnosable from the deploy log"
    )
    test_bug_a_failing_step_prints_the_validators_own_rows()
    test_bug_a_timed_out_step_keeps_the_rows_of_its_last_attempt()
    test_a_passing_step_adds_no_output_block()
    test_a_conformer_with_no_output_prints_nothing()
    test_parse_verdict_attaches_rows_on_every_non_pass_and_none_on_pass()
    test_the_output_tail_is_bounded_and_states_every_cut()
    test_the_clip_never_cuts_a_multibyte_character()
    test_a_credential_shaped_row_is_redacted()
    print("  ALL PASS")
