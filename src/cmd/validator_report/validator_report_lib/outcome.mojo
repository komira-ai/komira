# =============================================================================
# validator_report_lib/outcome.mojo — ★ ONE LEG'S ROWS + ITS AUTHORED SPEC, and
#   the THREE-VALUED exit code the run derives from them.
# =============================================================================
#
# ⛔ EVIDENCE, NOT AUTHORIZATION — see `state.mojo`'s header.
#
# ── WHAT A NON-VACUOUS VERDICT NEEDS ─────────────────────────────────────────
# Every conjunct of `all_passed()`, restated over the state enum:
#   * the POSITIONAL accounting fault (`validator_rows_lib`) — a count cannot see
#     two rows swapping identities;
#   * `asserted_count()` as the DENOMINATOR — otherwise `VERDICT: PASS (6/6 rows)`
#     prints for a run where two of the six were abstentions;
#   * `asserted_count() > 0` — a leg made entirely of abstentions is RED.
#
# ── ★ AND ONE THING IT REPLACES: `validator_exit_code(Bool) -> Int32` ────────
# `validator_rows_lib`'s `validator_exit_code` folds the whole run to a Bool. A
# Bool cannot express UNREADABLE, so adopting it would RE-COLLAPSE the third value
# — the same defect as folding every row of every matrix into one bit.
#
# `report_exit_code` is three-valued, and the PRECEDENCE is load-bearing:
#
#   3  a census fault — an accounting fault, a bad target list, a broken guard
#      list, or ANY unreadable row. THE RUN CANNOT SAY WHAT IT RAN.
#   1  an asserted failure, a NOT-REACHED row, a broken guard, or a leg that
#      asserted nothing.
#   0  otherwise.
#
# ⛔ 3 OUTRANKS 1 ON PURPOSE. A run that cannot say what it ran cannot support
# ANY claim about the deployment — including a negative one. It mirrors the
# release CLI's wave accounting exit code (`komira_ci_cli_lib`) and a test
# runner's split between "accounting violated" and "a test failed".
#
# Deps: `validator_rows_lib` (the ONE positional accounting model) + this
# package's `row`/`target`/`state`. Nothing else — no HTTP, no clock, no store.
# def-based, Mojo 1.0.0b2.
# =============================================================================

from validator_rows_lib import ExpectedRow, row_accounting_fault

from validator_report_lib.row import RowResult, NO_TARGET, row_passed, row_failed
from validator_report_lib.state import (
    REPORT_EXIT_OK,
    REPORT_EXIT_FAILED,
    REPORT_EXIT_CENSUS_FAULT,
)
from validator_report_lib.target import (
    ReportTarget,
    ReportGuard,
    targets_fault,
    guards_fault,
)


comptime DEFAULT_VALIDATOR_NAME: String = "validator"
"""The name a `MatrixOutcome` reports itself under when its constructor was not
told one.

⛔ DELIBERATELY GENERIC. Defaulting to any one validator's name would make every
other validator's accounting fault name the wrong binary — a diagnostic that sends the reader at a subsystem
that is not running. An unhelpful default is recoverable; a confidently wrong one
is not."""

comptime DEFAULT_LEG_NAME: String = "default"
"""The leg name when a validator runs exactly one matrix. ★ `leg` IS A FIELD
because otherwise a run's legs are implicit in CALL ORDER — a validator that
runs several of them could not say which rows came from which. A leg that cannot
be named cannot be queried, and 'which leg went red' is the first question."""


# =============================================================================
# §1 — MatrixOutcome — one leg's rows, its authored spec, and its targets.
# =============================================================================
struct MatrixOutcome(Movable, Deinitable):
    """The accumulated rows + the verdict for ONE leg.

    ★ IT OWNS THE SPEC IT IS ACCOUNTED AGAINST, AND THE CONSTRUCTOR REQUIRES IT.
    There is deliberately no no-arg `__init__`: an outcome with no authored row
    list has the verdict `passed == total`, which is TRUE of a leg that emitted
    its first row and returned.

    ⚠ `targets` here is the LEG's view. The DOCUMENT's `targets` array is what
    `RowResult.target_index` indexes, and `render_step_document` REFUSES a row
    whose index is out of that array's bounds — so the two cannot drift into a
    row attributed to a target nobody listed."""

    var validator: String
    var leg: String
    var rows: List[RowResult]
    var expected: List[ExpectedRow]
    var targets: List[ReportTarget]

    def __init__(
        out self, var validator: String, var leg: String,
        var expected: List[ExpectedRow]
    ):
        """The form every validator should use: it NAMES itself AND names the
        leg, so an accounting fault says which binary and which matrix."""
        self.validator = validator^
        self.leg = leg^
        self.rows = List[RowResult]()
        self.expected = expected^
        self.targets = List[ReportTarget]()

    def __init__(out self, var validator: String, var expected: List[ExpectedRow]):
        """A single-leg validator. Reports under `DEFAULT_LEG_NAME`."""
        self.validator = validator^
        self.leg = String(DEFAULT_LEG_NAME)
        self.rows = List[RowResult]()
        self.expected = expected^
        self.targets = List[ReportTarget]()

    def __init__(out self, var expected: List[ExpectedRow]):
        """The unnamed form. Reports under `DEFAULT_VALIDATOR_NAME`."""
        self.validator = String(DEFAULT_VALIDATOR_NAME)
        self.leg = String(DEFAULT_LEG_NAME)
        self.rows = List[RowResult]()
        self.expected = expected^
        self.targets = List[ReportTarget]()

    def add(mut self, var row: RowResult):
        self.rows.append(row^)

    def add_target(mut self, var target: ReportTarget):
        self.targets.append(target^)

    def obligation_for(self, name: String) -> String:
        """WHAT THIS LEG'S AUTHORED SPEC SAYS THE ROW NAMED `name` PROVES.

        ★ THE ROW'S DEMAND COMES FROM THE SPEC THAT AUTHORED IT, so the two
        cannot state different things. A validator that writes the obligation a
        second time at the emit site has two sentences that drift, and the one a
        reader sees is the one that was NOT reviewed.

        An UNAUTHORED name gets an explicit marker rather than an empty string —
        the positional accounting will red the leg for it anyway, and a blank
        `expected` would render as a row that demanded nothing."""
        for i in range(len(self.expected)):
            if self.expected[i].name == name:
                return self.expected[i].asserts.copy()
        return (
            String("⛔ UNAUTHORED ROW: this leg's spec states no obligation for '")
            + name.copy()
            + String("'")
        )

    def add_claim(mut self, var name: String, passed: Bool, var detail: String):
        """★ THE NON-HTTP ROW, and the constructor that makes adoption a RENAME.

        Many validators emit `(name, passed, detail)` triples against a subject
        that is not an HTTP exchange. For every one of them,
        adopting this library is `rep.add(...)` -> `rep.add_claim(...)` and
        nothing else.

        `expected` is looked up from the authored spec (see `obligation_for`).
        A PASS keeps its `detail` as the OBSERVED value — `state=ACTIVE` is
        the observation, not a note — and a FAIL keeps it as the detail, which is
        the sentence an operator acts on."""
        var obligation = self.obligation_for(name)
        if passed:
            var observed = detail^
            if observed.byte_length() == 0:
                observed = String("held")
            self.add(row_passed(name^, String("-"), observed^, obligation^))
        else:
            self.add(
                row_failed(
                    name^, String("-"), String("did NOT hold"), obligation^,
                    detail^,
                )
            )

    def copy_outcome(self) -> Self:
        """An explicit deep copy (the struct is Movable, NOT Copyable, so a
        caller that wants to hold an outcome AND put it in a list says so).

        ⚠ THE SPEC IS COPIED TOO. A fold over copies that lost their specs would
        compute a verdict without the accounting — the exact hole, one layer
        up."""
        var out = Self(
            self.validator.copy(), self.leg.copy(), copy_row_spec(self.expected)
        )
        for i in range(len(self.rows)):
            out.rows.append(self.rows[i].copy())
        for i in range(len(self.targets)):
            out.targets.append(self.targets[i].copy())
        return out^

    def total(self) -> Int:
        return len(self.rows)

    def not_run_count(self) -> Int:
        var n = 0
        for i in range(len(self.rows)):
            if self.rows[i].is_not_run():
                n += 1
        return n

    def unreadable_count(self) -> Int:
        var n = 0
        for i in range(len(self.rows)):
            if self.rows[i].is_unreadable():
                n += 1
        return n

    def not_reached_count(self) -> Int:
        var n = 0
        for i in range(len(self.rows)):
            if self.rows[i].state == 3:  # ROW_NOT_REACHED
                n += 1
        return n

    def failed_count(self) -> Int:
        """Rows in the FAILED state. ⚠ NOT the same as "red rows" — a NOT-REACHED
        row is red too and is counted separately, because collapsing them loses
        the distinction between "the property is false" and "we never got to
        ask"."""
        var n = 0
        for i in range(len(self.rows)):
            if self.rows[i].state == 1:  # ROW_FAILED
                n += 1
        return n

    def asserted_count(self) -> Int:
        """★ THE VERDICT'S DENOMINATOR — NOT `total()`. `passed == total` is
        satisfied by a leg every one of whose rows abstained, and
        `VERDICT: PASS (6/6 rows)` would print for a run where two of the six
        were abstentions. NOT_RUN and UNREADABLE both leave the ratio."""
        return self.total() - self.not_run_count() - self.unreadable_count()

    def asserted_passed_count(self) -> Int:
        var n = 0
        for i in range(len(self.rows)):
            if self.rows[i].state == 0 and self.rows[i].is_asserted():
                n += 1
        return n

    def row_names(self) -> List[String]:
        var n = List[String]()
        for i in range(len(self.rows)):
            n.append(self.rows[i].name.copy())
        return n^

    def accounting_fault(self) -> String:
        """★ WHY THIS LEG'S ROW ACCOUNTING IS UNTRUSTWORTHY, or `""`. POSITIONAL
        against `expected` — a count cannot see two rows swapping identities."""
        return row_accounting_fault(
            self.validator, self.row_names(), self.expected
        )

    def census_fault(self) -> String:
        """★ WHY THIS LEG CANNOT SAY WHAT IT RAN, or `""` — the exit-3 arm.

        The accounting fault FIRST (a leg that did not emit what it authored
        makes every other answer meaningless), then any UNREADABLE row, which is
        a fault about the SUBJECT rather than about the report."""
        var f = self.accounting_fault()
        if f.byte_length() > 0:
            return f^
        for i in range(len(self.rows)):
            if self.rows[i].is_unreadable():
                return (
                    self.validator.copy()
                    + String(" leg '")
                    + self.leg.copy()
                    + String("': row '")
                    + self.rows[i].name.copy()
                    + String(
                        "' could not OBSERVE its subject, so this leg cannot"
                        " support any claim about the deployment — including a"
                        " negative one. "
                    )
                    + self.rows[i].detail.copy()
                )
        return String("")

    def all_passed(self) -> Bool:
        """PASS iff every row that made a CLAIM passed, at least one row made
        one, no row was UNREADABLE, and the leg emitted the rows it authored in
        order.

        ★ THE ACCOUNTING CONJUNCT IS THE LOAD-BEARING ONE. Without it the verdict
        asks only "did anything that ran fail?" — a question a leg that ran almost
        nothing answers cheerfully."""
        if self.total() == 0:
            return False
        if self.asserted_count() <= 0:
            return False
        if self.unreadable_count() > 0:
            return False
        if self.asserted_passed_count() != self.asserted_count():
            return False
        return self.accounting_fault().byte_length() == 0

    def verdict_line(self) -> String:
        """The one line an operator greps for.

        ⛔ THE RATIO COUNTS ASSERTIONS, NOT ROWS."""
        var fault = self.accounting_fault()
        if fault.byte_length() > 0:
            return String("VERDICT: FAIL — ROW ACCOUNTING: ") + fault^
        var p = self.asserted_passed_count()
        var a = self.asserted_count()
        var nr = self.not_run_count()
        var ur = self.unreadable_count()
        var verdict = String("PASS") if self.all_passed() else String("FAIL")
        var line = (
            String("VERDICT: ")
            + verdict
            + String(" (")
            + String(p)
            + String("/")
            + String(a)
            + String(" asserted")
        )
        if nr > 0:
            line += String(", ") + String(nr) + String(" NOT-RUN")
        if ur > 0:
            line += String(", ") + String(ur) + String(" UNREADABLE")
        if a == 0:
            line += String(
                " — ⛔ EVERY row abstained, so this leg asserted NOTHING and"
                " cannot pass"
            )
        return line + String(" rows)")

    def render(self) -> String:
        """One line per row, then the VERDICT line, as a String.

        Separate from `print_report` because a caller sometimes needs the TEXT —
        a falsifier printing the report so a RED is readable in the test log, a
        wrapper indenting it under a step header. Both go through ONE
        formatting, so the text a test asserts on is the text an operator
        sees."""
        var out = String("")
        for i in range(len(self.rows)):
            out += self.rows[i].format() + String("\n")
        out += self.verdict_line() + String("\n")
        return out^

    def print_report(self):
        """One line per row, then the VERDICT line. The caller reads
        `report_exit_code` for the process exit code."""
        print(self.render())


def copy_row_spec(spec: List[ExpectedRow]) -> List[ExpectedRow]:
    """A deep copy of an authored row spec."""
    var out = List[ExpectedRow]()
    for i in range(len(spec)):
        out.append(spec[i].copy())
    return out^


def single_row_outcome(
    var validator: String, var name: String, var subject: String,
    var observed: String, var expected: String, ok: Bool
) raises -> MatrixOutcome:
    """★ THE FOUR-LINE CASE. A single-check probe asserts one thing; without
    this, adopting the shared model turns four lines into a
    spec list plus a nine-argument construction, and the gate that requires
    adoption gets argued with.

    The spec is DERIVED from the row — one authored row, whose stated obligation
    is the `expected` sentence — so even the trivial case carries the positional
    accounting rather than opting out of it."""
    var spec = List[ExpectedRow]()
    spec.append(ExpectedRow(name.copy(), expected.copy()))
    var out = MatrixOutcome(validator^, spec^)
    if ok:
        out.add(
            RowResult(
                name^, subject^, observed^, expected^, 0, -1,
                String(""), String(""), NO_TARGET,
            )
        )
    else:
        out.add(
            RowResult(
                name^, subject^, observed^, expected^, 1, -1,
                String("the observed value is not the demanded one"),
                String(""), NO_TARGET,
            )
        )
    return out^


# =============================================================================
# §2 — the RUN-LEVEL derivations over every leg.
# =============================================================================
def combine_outcomes(outcomes: List[MatrixOutcome]) -> Bool:
    """Did EVERY leg pass?

    ⛔ AN EMPTY LIST IS FALSE. "No leg ran" is not "every leg passed", and a fold
    seeded `True` over an empty list says the second."""
    if len(outcomes) == 0:
        return False
    for i in range(len(outcomes)):
        if not outcomes[i].all_passed():
            return False
    return True


def run_census_fault(
    outcomes: List[MatrixOutcome], targets: List[ReportTarget],
    guards: List[ReportGuard]
) -> String:
    """The FIRST reason this RUN cannot say what it ran, or `""`.

    Order: the target list (a record that cannot name what it validated answers
    nothing, whatever its rows say), then the guard list's own well-formedness,
    then each leg's census fault, then the degenerate empty-run case."""
    var tf = targets_fault(targets)
    if tf.byte_length() > 0:
        return tf^
    var gf = guards_fault(guards)
    if gf.byte_length() > 0:
        return gf^
    for i in range(len(outcomes)):
        var f = outcomes[i].census_fault()
        if f.byte_length() > 0:
            return f^
    if len(outcomes) == 0:
        return String(
            "NO LEGS. A run that recorded no outcome at all proves nothing about"
            " the deployment; it proves the matrix did not run."
        )
    return String("")


def report_exit_code(
    outcomes: List[MatrixOutcome], targets: List[ReportTarget],
    guards: List[ReportGuard]
) -> Int32:
    """★ THE THREE-VALUED PROCESS EXIT CODE — the value each validator `main`
    hands to `exit`. See this file's header for the precedence and why 3
    outranks 1.

    ⛔ THIS IS THE GATE. The document this library also renders is NOT: it is a
    record, written by the party being gated, into a bucket that party can write.
    Nothing may read it back as authorization."""
    if run_census_fault(outcomes, targets, guards).byte_length() > 0:
        return REPORT_EXIT_CENSUS_FAULT
    for i in range(len(guards)):
        if not guards[i].held:
            return REPORT_EXIT_FAILED
    if not combine_outcomes(outcomes):
        return REPORT_EXIT_FAILED
    return REPORT_EXIT_OK
