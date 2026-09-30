# =============================================================================
# validator_report_lib/row.mojo — ★ THE ONE ROW every validator writes into, and
#   the constructors that keep the simple case FOUR LINES.
# =============================================================================
#
# ⛔ EVIDENCE, NOT AUTHORIZATION — see `state.mojo`'s header. Nothing may gate on
# a record built from these rows.
#
# ── ★ THREE DESIGN CHOICES, EACH FORCED BY A VALIDATOR THAT DID NOT FIT ─────
#
#   ① `subject` REPLACES `method` + `path`. Many validators have NO HTTP shape
#      at all (telemetry, observability, filesystem, bootstrap, authorization
#      and session checks). A model with `method`/`path` fields forces every one
#      of them to write `"-"`/`"-"` — which is how private copies get written
#      instead of one shared type. `http_row(...)` renders
#      `subject = "<METHOD> <path>"`, so the HTTP-shaped copies migrate
#      MECHANICALLY and the non-HTTP ones stop lying.
#
#   ② `observed` / `expected` ARE STRINGS, NOT Ints. A matrix that demands a
#      status SET ("200 or 409") cannot hold it in an Int; `EXPECT_*` Int
#      sentinels exist only so a formatter can render prose for a predicate.
#      Prose is what the field now HOLDS, so the sentinel table is a rendering
#      concern that no longer has to live inside the shared struct.
#
#   ③ `remediation` IS REQUIRED WHEN THE ROW IS UNREADABLE. "I could not observe
#      the subject" is only actionable if it says what would make it observable.
#      `row_unreadable` REFUSES a blank one.
#
# ── ⚠ `target_index` IS WHY THIS FIELD LIST IS NOT A NICETY ──────────────────
# One validate wave can run many steps across several served services on
# DIFFERENT DIGESTS of one logical image. A single top-level `target` on the run
# is therefore WRONG — it can only be right for one of them. Attribution is PER
# ROW: `target_index` indexes the document's `targets` array, and `-1` means "the
# step's sole target".
#
# NO deps beyond `state.mojo` — pure `String` / `Int` work.
# def-based, Mojo 1.0.0b2.
# =============================================================================

from validator_report_lib.state import (
    ROW_PASSED,
    ROW_FAILED,
    ROW_NOT_RUN,
    ROW_NOT_REACHED,
    ROW_UNREADABLE,
    row_state_token,
)


comptime NO_TARGET: Int = -1
"""`RowResult.target_index` for a row that names the step's SOLE target. It is
NOT "no target": a step with one target needs no per-row index, and forcing every
validator to write `0` would make the field ceremonial."""

comptime NO_STATUS: Int = -1
"""`RowResult.status` when the observation carries no numeric code. Explicitly
NOT `0`: `0` is a real value a subprocess exit or a count can take, and a
sentinel that collides with a legal observation is not a sentinel."""


# =============================================================================
# §1 — RowResult — one assertion's outcome (a flat value POD).
# =============================================================================
@fieldwise_init
struct RowResult(Copyable, Movable, Deinitable):
    """One matrix row's outcome.

      * `name`        — the authored row name. THE POSITIONAL ACCOUNTING KEY:
                        `row_accounting_fault` diffs these index-by-index against
                        the authored spec, so a rename here without a rename in
                        the spec is a red gate, deliberately.
      * `subject`     — WHAT was observed: a URI, a path, a resource id, or `"-"`.
      * `observed`    — what was SEEN, rendered.
      * `expected`    — what was DEMANDED. MAY name a SET ("200 or 409").
      * `state`       — one of the `ROW_*` ordinals (`state.mojo`).
      * `status`      — an optional numeric observation (an HTTP status, an exit
                        code, a count). `NO_STATUS` when there is none.
      * `detail`      — a free note. ⚠ BOUND AND REDACT IT AT THE POINT OF
                        CAPTURE: this string lands in a durable object and an
                        error body can echo a credential back at you.
      * `remediation` — what would make an UNREADABLE subject readable. REQUIRED
                        non-empty for `ROW_UNREADABLE`.
      * `target_index`— index into the document's `targets`, or `NO_TARGET`."""

    var name: String
    var subject: String
    var observed: String
    var expected: String
    var state: Int
    var status: Int
    var detail: String
    var remediation: String
    var target_index: Int

    def is_not_run(self) -> Bool:
        """True iff this row ASSERTED NOTHING. Neither a pass nor a failure; the
        accounting counts it as neither."""
        return self.state == ROW_NOT_RUN

    def is_unreadable(self) -> Bool:
        """True iff the SUBJECT could not be observed. A RUN-LEVEL fault."""
        return self.state == ROW_UNREADABLE

    def is_asserted(self) -> Bool:
        """True iff this row made a CLAIM — i.e. it is in the verdict's
        denominator. NOT_RUN and UNREADABLE are the two that are not."""
        return not self.is_not_run() and not self.is_unreadable()

    def is_failure(self) -> Bool:
        """True iff this row is RED. ⛔ `ROW_NOT_REACHED` IS INCLUDED: a row that
        meant to claim and could not is a failure, not an abstention. Making it
        an abstention is how "the leg fell over before it asserted anything"
        becomes a clean pass."""
        return self.state == ROW_FAILED or self.state == ROW_NOT_REACHED

    def state_token(self) -> String:
        return row_state_token(self.state)

    def tag(self) -> String:
        """The bracketed report tag. ⛔ NEVER `[PASS]` for anything but
        `ROW_PASSED` — a reader scanning tags is counting assertions that
        HELD."""
        if self.state == ROW_PASSED:
            return String("[PASS]")
        if self.state == ROW_FAILED:
            return String("[FAIL]")
        if self.state == ROW_NOT_RUN:
            return String("[NOT-RUN]")
        if self.state == ROW_NOT_REACHED:
            return String("[NOT-REACHED]")
        return String("[UNREADABLE]")

    def format(self) -> String:
        """`<TAG> <name> <subject> -> <observed> (expected <expected>)[ note]`."""
        var line = self.tag() + String(" ") + self.name.copy()
        if self.subject.byte_length() > 0:
            line += String(" ") + self.subject.copy()
        line += String(" -> ") + self.observed.copy()
        if self.expected.byte_length() > 0:
            line += String(" (expected ") + self.expected.copy() + String(")")
        if self.detail.byte_length() > 0:
            line += String(" [") + self.detail.copy() + String("]")
        if self.remediation.byte_length() > 0:
            line += String(" {remediation: ") + self.remediation.copy() + String("}")
        return line^


# =============================================================================
# §2 — the constructors. ★ THE SIMPLE CASE MUST STAY FOUR LINES.
#
# A single-check service probe asserts one thing. If adopting the shared model
# turned its four lines into a nine-argument positional
# construction, the gate that requires adoption would get argued with — and it
# would deserve to be. Every constructor below exists so that the cost of
# adopting is LOWER than the cost of a private copy.
# =============================================================================


def row_passed(
    var name: String, var subject: String, var observed: String,
    var expected: String
) -> RowResult:
    """A row that RAN and HELD."""
    return RowResult(
        name^, subject^, observed^, expected^, ROW_PASSED, NO_STATUS,
        String(""), String(""), NO_TARGET,
    )


def row_failed(
    var name: String, var subject: String, var observed: String,
    var expected: String, var detail: String
) -> RowResult:
    """A row that RAN and did NOT hold. `detail` is the operator's sentence."""
    return RowResult(
        name^, subject^, observed^, expected^, ROW_FAILED, NO_STATUS,
        detail^, String(""), NO_TARGET,
    )


def row_not_run(var name: String, var reason: String) -> RowResult:
    """A row this leg's CONTRACT says does not run. Asserts nothing.

    ⛔ REFUSES A BLANK REASON BY RETURNING A FAILED ROW. An abstention with no
    stated reason is indistinguishable from a row that was quietly dropped, and
    it leaves the denominator — so a blank-reason abstention is a free way to
    shrink the gate."""
    if reason.byte_length() == 0:
        return RowResult(
            name^,
            String("-"),
            String("(abstained)"),
            String("a STATED reason for not running"),
            ROW_FAILED,
            NO_STATUS,
            String(
                "⛔ ABSTENTION WITH NO REASON. A row that asserts nothing and"
                " says nothing about why leaves the verdict's denominator for"
                " free. State the contract that says this row does not run."
            ),
            String(""),
            NO_TARGET,
        )
    return RowResult(
        name^,
        String("-"),
        String("(not run)"),
        String("NO CLAIM: this leg's contract says the row does not run"),
        ROW_NOT_RUN,
        NO_STATUS,
        String("NOT RUN: ") + reason^,
        String(""),
        NO_TARGET,
    )


def row_not_reached(var name: String, var reason: String) -> RowResult:
    """A row that WAS going to claim, prevented by an earlier failure in this
    leg. ⛔ RED, not an abstention — see `ROW_NOT_REACHED`.

    A blank reason is refused the same way `row_not_run` refuses one: the row is
    red either way, so the refusal costs a verdict nothing and buys the record
    the one thing it is for."""
    var why = reason^
    if why.byte_length() == 0:
        why = String(
            "⛔ NO REASON STATED. Name the earlier failure that prevented this"
            " row from claiming — 'not reached' with no antecedent is not a"
            " diagnosis."
        )
    return RowResult(
        name^,
        String("-"),
        String("(not reached)"),
        String("the row's own predicate, which this run never got to evaluate"),
        ROW_NOT_REACHED,
        NO_STATUS,
        String("NOT REACHED: ") + why^,
        String(""),
        NO_TARGET,
    )


def row_unreadable(
    var name: String, var subject: String, var reason: String,
    var remediation: String
) -> RowResult:
    """The SUBJECT could not be observed. Neither pass nor fail — a RUN-LEVEL
    fault that drives `report_exit_code` to 3.

    ⛔ REFUSES A BLANK `remediation` by returning a FAILED row. A probe that
    could not read its subject would otherwise report greens for checks that
    never ran; the value of typing that state is entirely in the sentence that says
    what would make the subject readable. Without it this state is just a red row
    with extra ceremony."""
    if remediation.byte_length() == 0:
        return RowResult(
            name^,
            subject^,
            String("(unobservable)"),
            String("a STATED remediation for an unreadable subject"),
            ROW_FAILED,
            NO_STATUS,
            String(
                "⛔ UNREADABLE WITH NO REMEDIATION. This state removes the row"
                " from the verdict's denominator; the price is saying what would"
                " make the subject readable. "
            ) + reason^,
            String(""),
            NO_TARGET,
        )
    return RowResult(
        name^,
        subject^,
        String("(unobservable)"),
        String("the subject to be OBSERVABLE at all"),
        ROW_UNREADABLE,
        NO_STATUS,
        String("UNREADABLE: ") + reason^,
        remediation^,
        NO_TARGET,
    )


def http_row(
    var name: String, var method: String, var path: String, status: Int,
    expected_status: Int, ok: Bool, var detail: String
) -> RowResult:
    """★ THE MECHANICAL-MIGRATION CONSTRUCTOR for the HTTP-shaped private copies.

    Renders `subject = "<METHOD> <path>"`, `observed = String(status)`,
    `expected = String(expected_status)` — so a validator whose private row model
    is `(name, method, path, status, expected, passed, detail)` adopts this leaf
    by changing a constructor NAME and nothing else."""
    var subject = method^
    subject += String(" ")
    subject += path^
    return RowResult(
        name^,
        subject^,
        String(status),
        String(expected_status),
        ROW_PASSED if ok else ROW_FAILED,
        status,
        detail^,
        String(""),
        NO_TARGET,
    )


def http_row_predicate(
    var name: String, var method: String, var path: String, status: Int,
    var expected: String, ok: Bool, var detail: String
) -> RowResult:
    """`http_row` for a row whose pass condition is a PREDICATE rather than an
    exact status — the shape the old `EXPECT_*` Int sentinels existed to render.
    `expected` is the operator-facing sentence, so a new predicate needs no new
    sentinel and no edit to this leaf."""
    var subject = method^
    subject += String(" ")
    subject += path^
    return RowResult(
        name^,
        subject^,
        String(status),
        expected^,
        ROW_PASSED if ok else ROW_FAILED,
        status,
        detail^,
        String(""),
        NO_TARGET,
    )


def with_target(var row: RowResult, target_index: Int) -> RowResult:
    """Attribute an already-built row to one of the document's targets. Separate
    from the constructors on purpose: a leg usually builds its rows against one
    target and attributes them in a loop, and threading an index through eight
    constructors would make the four-line case five."""
    var out = row^
    out.target_index = target_index
    return out^
