# =============================================================================
# tests/test_validator_report_outcome.mojo — the leg's text report, its
# verdict arms, and the target/guard faults (`outcome.mojo`, `row.mojo`,
# `target.mojo`).
#
# Welded beside `test_validator_report.mojo`; this file pins what that one
# leaves unasserted. Each test names the defect it catches:
#
#   * `test_every_state_has_its_own_tag_and_format_line` — a non-PASS row
#     tagged `[PASS]` (or any tag swapped), and a `format` that drops or
#     misorders an optional part.
#   * `test_render_is_rows_then_verdict` — `render` losing a row or the
#     verdict line.
#   * `test_verdict_arms` — an empty leg passing, an accounting fault not
#     leading the verdict, an UNREADABLE count missing from the line.
#   * `test_unnamed_outcome_and_deep_copy` — the generic default name, and a
#     `copy_outcome` that shares or drops rows, targets or the spec.
#   * `test_not_reached_blank_reason_and_predicate_row` — a blank NOT-REACHED
#     reason kept blank; `http_row_predicate` losing its sentence or its state.
#   * `test_target_and_guard_faults_are_indexed` — a nameless target or a
#     NONE source with no note accepted; the list index missing from a fault;
#     a guard fault (nameless, or broken with no reason) not reaching the
#     census.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from kci_validator_rows import ExpectedRow, expected_row

from kci_validator_report import (
    ROW_PASSED,
    ROW_FAILED,
    ROW_NOT_RUN,
    ROW_NOT_REACHED,
    ROW_UNREADABLE,
    VERSION_SOURCE_NONE,
    VERSION_SOURCE_LIVE_SERVING,
    REPORT_EXIT_CENSUS_FAULT,
    RowResult,
    NO_TARGET,
    row_passed,
    row_failed,
    row_not_run,
    row_not_reached,
    row_unreadable,
    http_row_predicate,
    ReportTarget,
    ReportGuard,
    served_target,
    guard_held,
    targets_fault,
    guards_fault,
    MatrixOutcome,
    DEFAULT_VALIDATOR_NAME,
    DEFAULT_LEG_NAME,
    run_census_fault,
    report_exit_code,
)


def _contains(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


def _row(state: Int) -> RowResult:
    return RowResult(
        String("n"), String(""), String("o"), String(""), state, -1,
        String(""), String(""), NO_TARGET,
    )


def _spec(a: String, b: String) -> List[ExpectedRow]:
    var s = List[ExpectedRow]()
    s.append(expected_row(a.copy(), String("a holds")))
    if b.byte_length() > 0:
        s.append(expected_row(b.copy(), String("b holds")))
    return s^


def _one_target() -> List[ReportTarget]:
    var t = List[ReportTarget]()
    t.append(served_target(String("t"), String("sha256:aa"), String("u")))
    return t^


# -----------------------------------------------------------------------------
# §1 — tags and the one-line format.
# -----------------------------------------------------------------------------
def test_every_state_has_its_own_tag_and_format_line() raises:
    assert_equal(_row(ROW_PASSED).tag(), String("[PASS]"))
    assert_equal(_row(ROW_FAILED).tag(), String("[FAIL]"))
    assert_equal(_row(ROW_NOT_RUN).tag(), String("[NOT-RUN]"))
    assert_equal(_row(ROW_NOT_REACHED).tag(), String("[NOT-REACHED]"))
    assert_equal(_row(ROW_UNREADABLE).tag(), String("[UNREADABLE]"))
    assert_equal(_row(7).tag(), String("[UNREADABLE]"))
    # Every optional part empty: name, arrow, observed only.
    assert_equal(_row(ROW_PASSED).format(), String("[PASS] n -> o"))
    # Every optional part present, in order.
    var full = RowResult(
        String("n"), String("GET /x"), String("500"), String("200"), ROW_FAILED,
        500, String("boom"), String("fix it"), NO_TARGET,
    )
    assert_equal(
        full.format(),
        String("[FAIL] n GET /x -> 500 (expected 200) [boom] {remediation: fix it}"),
    )


# -----------------------------------------------------------------------------
# §2 — render: one line per row, then the verdict.
# -----------------------------------------------------------------------------
def test_render_is_rows_then_verdict() raises:
    var oc = MatrixOutcome(String("v"), String("l"), _spec(String("a"), String("b")))
    oc.add(row_passed(String("a"), String("-"), String("ok"), String("a holds")))
    oc.add(row_failed(String("b"), String(""), String("no"), String(""), String("")))
    assert_equal(
        oc.render(),
        String(
            "[PASS] a - -> ok (expected a holds)\n"
            "[FAIL] b -> no\n"
            "VERDICT: FAIL (1/2 asserted rows)\n"
        ),
    )
    # print_report writes `render()` to stdout. Only that it runs and leaves
    # the leg unchanged is asserted: a welded test cannot read its own stdout.
    oc.print_report()
    assert_equal(oc.total(), 2)


# -----------------------------------------------------------------------------
# §3 — the verdict's arms.
# -----------------------------------------------------------------------------
def test_verdict_arms() raises:
    # A leg that emitted no row is not a pass (the first conjunct).
    var empty = MatrixOutcome(String("v"), String("l"), _spec(String("a"), String("")))
    assert_true(_contains(empty.accounting_fault(), String("NO ROWS WERE EMITTED")))
    assert_false(empty.all_passed())
    # An accounting fault leads the verdict, ahead of any ratio.
    var short = MatrixOutcome(String("v"), String("l"), _spec(String("a"), String("b")))
    short.add(row_passed(String("a"), String("-"), String("ok"), String("x")))
    var line = short.verdict_line()
    assert_true(line.startswith(String("VERDICT: FAIL — ROW ACCOUNTING: ")), line)
    assert_false(_contains(line, String("asserted rows)")), line)
    # An UNREADABLE row is named in the ratio's tail, with the NOT-RUN count.
    var spec3 = _spec(String("a"), String("b"))
    spec3.append(expected_row(String("c"), String("c holds")))
    var ur = MatrixOutcome(String("v"), String("l"), spec3^)
    ur.add(row_passed(String("a"), String("-"), String("ok"), String("x")))
    ur.add(row_unreadable(String("b"), String("s"), String("dns"), String("fix dns")))
    ur.add(row_not_run(String("c"), String("contract")))
    assert_equal(
        ur.verdict_line(),
        String("VERDICT: FAIL (1/1 asserted, 1 NOT-RUN, 1 UNREADABLE rows)"),
    )


# -----------------------------------------------------------------------------
# §4 — the unnamed constructor, add_target, and a deep copy.
# -----------------------------------------------------------------------------
def test_unnamed_outcome_and_deep_copy() raises:
    var oc = MatrixOutcome(_spec(String("a"), String("")))
    assert_equal(oc.validator, String(DEFAULT_VALIDATOR_NAME))
    assert_equal(oc.leg, String(DEFAULT_LEG_NAME))
    oc.add(row_passed(String("a"), String("-"), String("ok"), String("x")))
    oc.add_target(served_target(String("t1"), String("sha256:1"), String("u1")))
    oc.add_target(served_target(String("t2"), String("sha256:2"), String("u2")))
    var cp = oc.copy_outcome()
    # The original changes after the copy; the copy must not.
    oc.rows[0].name = String("changed")
    oc.targets[1].name = String("changed")
    oc.expected[0].name = String("changed")
    assert_equal(cp.validator, String(DEFAULT_VALIDATOR_NAME))
    assert_equal(cp.leg, String(DEFAULT_LEG_NAME))
    assert_equal(len(cp.rows), 1)
    assert_equal(cp.rows[0].name, String("a"))
    assert_equal(len(cp.targets), 2)
    assert_equal(cp.targets[0].name, String("t1"))
    assert_equal(cp.targets[1].name, String("t2"))
    assert_equal(len(cp.expected), 1)
    assert_equal(cp.expected[0].name, String("a"))
    # The copy keeps its spec, so it is still accounted (and passes).
    assert_true(cp.all_passed())


# -----------------------------------------------------------------------------
# §5 — row constructors' remaining arms.
# -----------------------------------------------------------------------------
def test_not_reached_blank_reason_and_predicate_row() raises:
    var r = row_not_reached(String("x"), String(""))
    assert_equal(r.state, ROW_NOT_REACHED)
    assert_true(r.detail.startswith(String("NOT REACHED: ⛔ NO REASON STATED")), r.detail)
    var p = http_row_predicate(
        String("n"), String("GET"), String("/a"), 503, String("2xx or 409"),
        False, String("d"),
    )
    assert_equal(p.subject, String("GET /a"))
    assert_equal(p.observed, String("503"))
    assert_equal(p.expected, String("2xx or 409"))
    assert_equal(p.state, ROW_FAILED)
    assert_equal(p.status, 503)
    assert_equal(p.detail, String("d"))
    assert_equal(p.target_index, NO_TARGET)
    var q = http_row_predicate(
        String("n"), String("PUT"), String("/b"), 409, String("2xx or 409"),
        True, String(""),
    )
    assert_equal(q.state, ROW_PASSED)
    assert_equal(q.subject, String("PUT /b"))


# -----------------------------------------------------------------------------
# §6 — target and guard faults, indexed, and reaching the census.
# -----------------------------------------------------------------------------
def test_target_and_guard_faults_are_indexed() raises:
    var nameless = ReportTarget(
        String(""), String("service"), String("sha256:1"),
        String(VERSION_SOURCE_LIVE_SERVING), String(""), String("u"),
    )
    assert_true(_contains(nameless.fault(), String("NO NAME")), nameless.fault())
    var no_note = ReportTarget(
        String("t"), String("service"), String(""), String(VERSION_SOURCE_NONE),
        String(""), String("u"),
    )
    assert_true(
        _contains(no_note.fault(), String("target 't': version_source is NONE with NO version_note")),
        no_note.fault(),
    )
    # The FIRST faulty target is named by its index (the second here).
    var ts = _one_target()
    ts.append(no_note.copy())
    ts.append(nameless.copy())
    var tf = targets_fault(ts)
    assert_true(tf.startswith(String("targets[1]: target 't'")), tf)

    # Guards: a nameless guard, and a broken guard with no reason (built
    # directly: `guard_broken` substitutes a reason).
    assert_equal(ReportGuard(String(""), True, String("")).fault(), String("a guard with NO NAME"))
    var silent = ReportGuard(String("g"), False, String(""))
    assert_true(silent.fault().startswith(String("guard 'g' is BROKEN with no stated reason")))
    assert_equal(ReportGuard(String("g"), False, String("r")).fault(), String(""))
    var gs = List[ReportGuard]()
    gs.append(guard_held(String("ok")))
    gs.append(silent.copy())
    assert_true(guards_fault(gs).startswith(String("guards[1]: guard 'g'")), guards_fault(gs))
    # A guard fault is a census fault: exit 3, ahead of the legs.
    var legs = List[MatrixOutcome]()
    var oc = MatrixOutcome(String("v"), String("l"), _spec(String("a"), String("")))
    oc.add(row_passed(String("a"), String("-"), String("ok"), String("x")))
    legs.append(oc^)
    assert_true(run_census_fault(legs, _one_target(), gs).startswith(String("guards[1]:")))
    assert_equal(report_exit_code(legs, _one_target(), gs), REPORT_EXIT_CENSUS_FAULT)


def main() raises:
    test_every_state_has_its_own_tag_and_format_line()
    test_render_is_rows_then_verdict()
    test_verdict_arms()
    test_unnamed_outcome_and_deep_copy()
    test_not_reached_blank_reason_and_predicate_row()
    test_target_and_guard_faults_are_indexed()
    print("test_validator_report_outcome: ALL PASS")
