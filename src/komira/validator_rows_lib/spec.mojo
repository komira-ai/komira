# =============================================================================
# validator_rows_lib/spec.mojo — ★ THE EXPECTED-ROW SPEC. What a validator's
#   matrix PROMISES to emit, in emission order, and what each row asserts.
# =============================================================================
#
# ── THE DEFECT THIS EXISTS TO CLOSE ──────────────────────────────────────────
# A validator that decides its verdict with
#
#     return self.passed_count() == self.total() and self.total() > 0
#
# where `total()` is `len(self.rows)` — THE LENGTH OF WHAT WAS EMITTED — has a
# denominator that is whatever the run produced, so a matrix that emitted a
# PREFIX of its rows and returned prints `PASS (5/5)`: a truncated run reports
# itself as complete.
#
# ── ⚠ A BARE INTEGER COUNT IS NOT THE FIX ────────────────────────────────────
# `total() == 25` is still a number, and a number cannot see:
#   * two rows SWAPPING IDENTITIES — twenty-five rows, all passing, and one of
#     the two mechanisms has silently stopped being asserted;
#   * row 7 becoming a DUPLICATE of row 6 — the count is untouched and the
#     mechanism row 7 named is gone.
# So the accounting here is POSITIONAL: the emitted row NAMES are diffed against
# the authored row NAMES index by index, and the first divergence is printed with
# BOTH names. See `accounting.mojo`.
#
# ── ⚠ THE COUNT'S REASON MUST ENUMERATE ──────────────────────────────────────
# A count whose reason enumerates is a SPEC. Hence
# `ExpectedRow` carries `asserts` — one sentence naming the mechanism THAT ROW
# proves — and `spec_fault` REFUSES a blank one. The consequence is the point: a
# future edit that drops a row must DELETE A STATED OBLIGATION, not decrement a
# number, and the deletion is legible in review as "we stopped asserting X".
#
# ── SCOPE ────────────────────────────────────────────────────────────────────
# NO deps, by construction — pure `String` / `List` work, no FFI, no env, no
# clock, no transport. That is what lets every validator take this dep for one
# line without dragging a closure in, and what makes every function here
# falsifiable with no process.
# =============================================================================


# =============================================================================
# §1 — ExpectedRow — one authored row: its NAME and WHAT IT ASSERTS.
# =============================================================================
@fieldwise_init
struct ExpectedRow(Copyable, Movable, Deinitable):
    """One row the matrix PROMISES to emit.

    `name` is the exact string the matrix passes as the row's name — the
    positional diff compares these, so a rename here without a rename there is a
    red gate (which is the intent: the name is the row's identity).

    `asserts` is WHAT THAT ROW PROVES, in one sentence, in the operator's words.
    It is NOT decoration and it is NOT a docstring: `spec_fault` refuses a blank
    one, so a row cannot be added without saying what it is for, and a row cannot
    be deleted without deleting a stated obligation."""

    var name: String
    var asserts: String


def expected_row(var name: String, var asserts: String) -> ExpectedRow:
    """Construct one authored row. Sugar for `ExpectedRow(name^, asserts^)` that
    reads as a sentence at every call site of a big spec."""
    return ExpectedRow(name^, asserts^)


# =============================================================================
# §2 — derivations over a spec. The COUNT is one of them, and is never written
#      down separately.
# =============================================================================
def expected_names(spec: List[ExpectedRow]) -> List[String]:
    """The authored names, in emission order — the left side of the positional
    diff."""
    var out = List[String]()
    for i in range(len(spec)):
        out.append(spec[i].name.copy())
    return out^


def expected_count(spec: List[ExpectedRow]) -> Int:
    """DERIVED from the spec, never written down separately.

    A count that is written down separately has exactly one correct edit — bump
    it — and bumping it is indistinguishable from repairing it."""
    return len(spec)


# =============================================================================
# §3 — spec_fault — the SPEC's own falsifier.
# =============================================================================
def spec_fault(validator: String, spec: List[ExpectedRow]) -> String:
    """Why this SPEC cannot be trusted as the accounting's authority, or `""`.

    The accounting compares emitted rows against the spec, so a broken spec is a
    broken gate — and every arm below is a way a spec silently stops being one:

      1. EMPTY — a spec with no rows accepts EVERY emission, including none. It
         is the `passed == total` hole wearing a different hat.
      2. BLANK NAME — an unnamed row cannot be positionally diffed.
      3. ★ BLANK `asserts` — a row with no stated obligation is a number again.
         This is the arm that keeps the spec a SPEC: deleting such a row costs
         nothing, so nothing stops a future edit from deleting it.
      4. DUPLICATE NAME — two rows with one name make the report ambiguous about
         which mechanism a `[FAIL]` line refers to, and make a
         row-7-became-a-copy-of-row-6 mutation authorable rather than caught."""
    if len(spec) == 0:
        return (
            validator.copy()
            + String(
                ": the expected-row SPEC IS EMPTY. An empty spec accepts every"
                " emission — including none — which is the `passed == total`"
                " hole this library exists to close, restated."
            )
        )
    for i in range(len(spec)):
        if spec[i].name.byte_length() == 0:
            return (
                validator.copy()
                + String(": expected row at index ")
                + String(i)
                + String(
                    " has an EMPTY NAME. The positional diff compares names, so"
                    " an unnamed row can never be accounted for."
                )
            )
        if spec[i].asserts.byte_length() == 0:
            return (
                validator.copy()
                + String(": expected row '")
                + spec[i].name.copy()
                + String("' (index ")
                + String(i)
                + String(
                    ") states NO OBLIGATION. Every row must say what it"
                    " asserts, so that dropping the row means deleting a stated"
                    " obligation rather than decrementing a number."
                )
            )
    for i in range(len(spec)):
        for j in range(i + 1, len(spec)):
            if spec[i].name == spec[j].name:
                return (
                    validator.copy()
                    + String(": DUPLICATE expected row name '")
                    + spec[i].name.copy()
                    + String("' at indices ")
                    + String(i)
                    + String(" and ")
                    + String(j)
                    + String(
                        " — two rows sharing one name make a [FAIL] line"
                        " ambiguous about which mechanism failed, and make"
                        " 'row N became a copy of row N-1' authorable."
                    )
                )
    return String("")


# =============================================================================
# §4 — the DRY-RUN plan, DERIVED from the spec.
# =============================================================================
def plan_lines(spec: List[ExpectedRow]) -> List[String]:
    """One line per authored row — `<name>  <what it asserts>` — for a
    `--dry-run` / `--list` mode.

    DERIVED rather than hand-written. A hand-written dry-run plan (one literal
    `print` per row) is compared to nothing, so it can describe a matrix that
    no longer exists. A plan built from the same list
    the accounting reads cannot disagree with the rows the matrix emits."""
    var out = List[String]()
    for i in range(len(spec)):
        var line = String("  ") + spec[i].name.copy()
        while line.byte_length() < 40:
            line += String(" ")
        line += String("  ") + spec[i].asserts.copy()
        out.append(line^)
    return out^
