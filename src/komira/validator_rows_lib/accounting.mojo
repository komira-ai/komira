# =============================================================================
# validator_rows_lib/accounting.mojo — ★ THE POSITIONAL ROW ACCOUNTING. Did the
#   matrix emit the rows it authored, in the order it authored them?
# =============================================================================
#
# `spec.mojo` says what a matrix PROMISES. This file asks whether it DELIVERED,
# and it asks positionally because that is the only form of the question a count
# cannot answer:
#
#   * TRUNCATION — the matrix returned early. The prefix it did emit is entirely
#     correct, so a scan over the common prefix finds NO divergence. The fault is
#     the index the report never reached, which is exactly where the leg stopped.
#   * IDENTITY SWAP — rows 4 and 5 exchange names. The count is untouched, every
#     row passes, and one of the two mechanisms is no longer asserted.
#   * DUPLICATION — row 7 is emitted as a second copy of row 6. The count is
#     untouched and the mechanism row 7 named is gone.
#
# Only the third of those is even in principle visible to a count, and only when
# the count is also wrong. So the diff is index-by-index over NAMES.
#
# ── WHY THE FIRST DIVERGENCE AND NOT A FULL DIFF ─────────────────────────────
# Deliberately: after one row moves, every subsequent index disagrees, and a
# wall of differences buries WHICH line moved. The repair is a one-line edit;
# the message names the one line.
#
# No deps beyond `spec.mojo` — pure `String` work.
# =============================================================================

from validator_rows_lib.spec import ExpectedRow, expected_names, spec_fault


# =============================================================================
# §1 — first_name_divergence — THREE cases, and the second is the one a naive
#      prefix scan misses.
# =============================================================================
def first_name_divergence(
    emitted: List[String], expected: List[String]
) -> String:
    """The FIRST index at which the emitted and authored row lists disagree,
    rendered with BOTH names, or EMPTY when they agree entirely.

    Three shapes, not one:

      * DIVERGENCE — the lists differ at a common index. Both names printed.
      * ★ MISSING — the emitted list is a strict PREFIX. Nothing in the common
        range differs, so this is the case a prefix scan reports as "no
        divergence" — and truncation is the shape a returned-early leg actually
        takes, so it is the shape that most needs naming.
      * UNAUTHORED — the matrix emitted a row the spec does not author. That is
        an addition nobody wrote down, and an unwritten row is an unreviewed
        one."""
    var n = len(emitted)
    if len(expected) < n:
        n = len(expected)
    for i in range(n):
        if emitted[i] != expected[i]:
            return (
                String(" FIRST DIVERGENCE at index ")
                + String(i)
                + String(": authored '")
                + expected[i].copy()
                + String("', emitted '")
                + emitted[i].copy()
                + String("'")
            )
    if len(emitted) < len(expected):
        return (
            String(" FIRST MISSING at index ")
            + String(len(emitted))
            + String(": authored '")
            + expected[len(emitted)].copy()
            + String("', emitted NOTHING (the report stops here — this is where")
            + String(" the matrix returned early)")
        )
    if len(emitted) > len(expected):
        return (
            String(" FIRST UNAUTHORED at index ")
            + String(len(expected))
            + String(": emitted '")
            + emitted[len(expected)].copy()
            + String("', which the spec does not author")
        )
    return String("")


# =============================================================================
# §2 — row_accounting_fault — the ONE call a validator's `all_passed()` makes.
# =============================================================================
def row_accounting_fault(
    validator: String, emitted: List[String], spec: List[ExpectedRow]
) -> String:
    """★ WHY THIS RUN'S ROW ACCOUNTING IS UNTRUSTWORTHY, or `""`.

    Four arms, in the order a reader needs them:

      1. SPEC — the spec itself is broken (empty, unnamed row, unstated
         obligation, duplicate name). Reported FIRST because a broken spec makes
         every other answer here meaningless.
      2. EMPTY — the matrix emitted no row at all. Reported on its own because
         `passed == total` is TRUE of an empty list, and every ratio-shaped
         verdict renders it as a clean pass.
      3. COUNT — a length mismatch. The message carries the first divergence too,
         so the operator is told WHICH row went missing, not only that one did.
      4. ★ IDENTITY — a positional name diff at equal length. This is the arm a
         count cannot have, and the reason this library is not `total() == N`.

    A validator wires this into `all_passed()` as a CONJUNCT, never as a
    replacement: "did anything that ran fail?" and "did everything run?" are
    different questions and a matrix that ran almost nothing answers the first
    one cheerfully."""
    var spec_bad = spec_fault(validator, spec)
    if spec_bad.byte_length() > 0:
        return String("SPEC IS INVALID — ") + spec_bad^
    var authored = expected_names(spec)
    if len(emitted) == 0:
        return (
            validator.copy()
            + String(": NO ROWS WERE EMITTED — the matrix authors ")
            + String(len(authored))
            + String(
                " rows and reported none. `passed == total` is VACUOUSLY TRUE of"
                " an empty row list, so this run proves nothing about the"
                " deployment; it proves the matrix did not run."
            )
        )
    if len(emitted) != len(authored):
        return (
            validator.copy()
            + String(": row-count mismatch — emitted ")
            + String(len(emitted))
            + String(" rows, but the matrix authors ")
            + String(len(authored))
            + String(
                ". A row that stops being reported stops being asserted, and the"
                " pass ratio cannot show it."
            )
            + first_name_divergence(emitted, authored)
        )
    var diff = first_name_divergence(emitted, authored)
    if diff.byte_length() > 0:
        return (
            validator.copy()
            + String(
                ": row-IDENTITY mismatch — the COUNT matched and the NAMES did"
                " not. Two rows swapping identities, or one becoming a duplicate"
                " of its neighbour, leaves the total untouched and every row"
                " passing while a mechanism stops being asserted."
            )
            + diff^
        )
    return String("")


# =============================================================================
# §3 — validator_exit_code — the process exit code, as a pure function.
# =============================================================================
def validator_exit_code(all_passed: Bool) -> Int32:
    """0 iff the matrix passed, 1 otherwise — the value each validator `main`
    hands to `exit`.

    Trivial on purpose, and shared on purpose: it is the ONE line that turns a
    verdict into the thing a validate job keys on. Written inline in each
    `main`, it would be out of every test's reach. A truncation
    test can now assert the EXIT CODE the binary would use, not merely a boolean
    a reader must trust is wired to it."""
    return Int32(0) if all_passed else Int32(1)
