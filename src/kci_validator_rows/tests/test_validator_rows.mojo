# =============================================================================
# tests/test_validator_rows.mojo — THE FALSIFIER for the shared positional
#   row-accounting model (`kci_validator_rows`).
# =============================================================================
#
# WHAT THIS PINS, AND WHY EACH ASSERTION EXISTS.
#
# ★ `test_truncation_is_a_fault` is the load-bearing one, and it is the exact
#   shape that produces a fake `PASS (5/5)`: a matrix leg returns early, so the
#   emitted list is a strict PREFIX of the authored one. Every emitted row is
#   correct and every emitted row passes — which is why a scan
#   over the common prefix reports "no divergence" and why `passed == total`
#   reports a clean run.
#
# ★ `test_identity_swap_is_a_fault` is the one a COUNT cannot have. Twenty-five
#   rows, twenty-five passes, and rows 4 and 5 have exchanged names: one of the
#   two mechanisms is no longer being asserted and no integer anywhere changed.
#   If this library were `total() == N` this assertion would fail.
#
# ★ `test_duplicate_emission_is_a_fault` is the same class one step subtler: row
#   7 emitted as a second copy of row 6. Count untouched.
#
# ★ `test_blank_obligation_is_a_spec_fault` is what keeps the spec a SPEC rather
#   than a list of names. A row with no stated obligation costs nothing to
#   delete, so nothing stops a future edit from deleting it — which is precisely
#   the "decrement a number" failure the enumeration exists to prevent.
#
# ★ `test_exit_code_is_nonzero_for_a_truncated_run` asserts the PROCESS EXIT
#   CODE, not a boolean. A validate job keys on the exit code; a test
#   that stops at `all_passed() == False` is trusting an unexamined line in a
#   `main` no test can import.
#
# Hermetic: pure String work, no process, no environment, no network, no clock.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from kci_validator_rows.spec import (
    ExpectedRow,
    expected_row,
    expected_names,
    expected_count,
    spec_fault,
    plan_lines,
)
from kci_validator_rows.accounting import (
    first_name_divergence,
    row_accounting_fault,
    validator_exit_code,
)


comptime _V: String = "test_validator"


def _spec() -> List[ExpectedRow]:
    """A five-row spec standing in for a real matrix."""
    var s = List[ExpectedRow]()
    s.append(expected_row(String("livez_200"), String("the app answers liveness")))
    s.append(expected_row(String("unauth_401"), String("no bearer is refused")))
    s.append(expected_row(String("create_201"), String("a write lands")))
    s.append(expected_row(String("read_back_200"), String("the write is readable")))
    s.append(expected_row(String("delete_204"), String("the resource is removable")))
    return s^


def _names(*items: String) -> List[String]:
    var out = List[String]()
    for ref it in items:
        out.append(it.copy())
    return out^


def _emitted_all() -> List[String]:
    return expected_names(_spec())


def _contains(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


# -----------------------------------------------------------------------------
# The happy path — a faithful emission is NOT a fault.
# -----------------------------------------------------------------------------
def test_faithful_emission_is_clean() raises:
    var fault = row_accounting_fault(_V, _emitted_all(), _spec())
    assert_equal(fault, String(""))
    assert_equal(expected_count(_spec()), 5)
    assert_equal(validator_exit_code(True), Int32(0))


# -----------------------------------------------------------------------------
# ★ TRUNCATION — the shape that produces `PASS (5/5)` from a leg that returned.
# -----------------------------------------------------------------------------
def test_truncation_is_a_fault() raises:
    """A strict PREFIX of the authored list. Every emitted row is CORRECT, so a
    prefix scan finds no divergence and a pass-ratio finds nothing wrong."""
    var emitted = _names(
        String("livez_200"), String("unauth_401"), String("create_201")
    )
    var fault = row_accounting_fault(_V, emitted, _spec())
    assert_true(
        fault.byte_length() > 0,
        String("a truncated emission MUST be an accounting fault"),
    )
    # It must name WHERE it stopped, not merely that a row went missing.
    assert_true(
        _contains(fault, String("FIRST MISSING at index 3")),
        String("the fault must name the index the report stops at: ") + fault,
    )
    assert_true(
        _contains(fault, String("read_back_200")),
        String("the fault must name the first authored row not reached: ") + fault,
    )


def test_truncation_to_one_row_is_a_fault() raises:
    """The sharpest mutant: truncate to ONE passing row. `passed == total`
    reads 1/1 and prints PASS."""
    var fault = row_accounting_fault(_V, _names(String("livez_200")), _spec())
    assert_true(fault.byte_length() > 0, String("1-of-5 must be a fault"))


def test_empty_emission_is_its_own_arm() raises:
    """Reported separately because `passed == total` is TRUE of an empty list and
    every ratio-shaped verdict renders it as a clean pass."""
    var fault = row_accounting_fault(_V, List[String](), _spec())
    assert_true(
        _contains(fault, String("NO ROWS WERE EMITTED")),
        String("an empty emission must be named as such: ") + fault,
    )


def test_exit_code_is_nonzero_for_a_truncated_run() raises:
    """The claim an operator actually depends on: the PROCESS EXIT CODE."""
    var fault = row_accounting_fault(_V, _names(String("livez_200")), _spec())
    var passed = fault.byte_length() == 0
    assert_false(passed, String("a truncated run must not be a pass"))
    assert_equal(
        validator_exit_code(passed),
        Int32(1),
        String("a truncated run must exit NON-ZERO"),
    )


# -----------------------------------------------------------------------------
# ★ IDENTITY — what a bare integer count structurally cannot see.
# -----------------------------------------------------------------------------
def test_identity_swap_is_a_fault() raises:
    """Rows 2 and 3 exchange names. FIVE rows, all present, all passing — and one
    of the two mechanisms has silently stopped being asserted."""
    var emitted = _names(
        String("livez_200"),
        String("unauth_401"),
        String("read_back_200"),  # <- was create_201
        String("create_201"),  # <- was read_back_200
        String("delete_204"),
    )
    assert_equal(len(emitted), expected_count(_spec()))  # the COUNT is intact
    var fault = row_accounting_fault(_V, emitted, _spec())
    assert_true(
        _contains(fault, String("row-IDENTITY mismatch")),
        String("a swap at equal length must be caught: ") + fault,
    )
    assert_true(
        _contains(fault, String("FIRST DIVERGENCE at index 2")),
        String("the fault must name the index: ") + fault,
    )
    # BOTH names, so the operator is told which line moved.
    assert_true(_contains(fault, String("create_201")), fault)
    assert_true(_contains(fault, String("read_back_200")), fault)


def test_duplicate_emission_is_a_fault() raises:
    """Row 4 emitted as a second copy of row 3. The count is untouched."""
    var emitted = _names(
        String("livez_200"),
        String("unauth_401"),
        String("create_201"),
        String("create_201"),  # <- read_back_200 became a duplicate
        String("delete_204"),
    )
    var fault = row_accounting_fault(_V, emitted, _spec())
    assert_true(fault.byte_length() > 0, String("a duplicated row must be caught"))
    assert_true(_contains(fault, String("index 3")), fault)


def test_unauthored_extra_row_is_a_fault() raises:
    """A row nobody wrote down is an unreviewed one."""
    var emitted = _emitted_all()
    emitted.append(String("surprise_row"))
    var fault = row_accounting_fault(_V, emitted, _spec())
    assert_true(fault.byte_length() > 0, String("an extra row must be caught"))
    assert_true(_contains(fault, String("surprise_row")), fault)


# -----------------------------------------------------------------------------
# `first_name_divergence` directly — the three shapes.
# -----------------------------------------------------------------------------
def test_first_divergence_shapes() raises:
    var authored = expected_names(_spec())
    assert_equal(first_name_divergence(authored, authored), String(""))
    assert_true(
        _contains(
            first_name_divergence(_names(String("livez_200")), authored),
            String("FIRST MISSING"),
        )
    )
    assert_true(
        _contains(
            first_name_divergence(_names(String("nope")), _names(String("yes"))),
            String("FIRST DIVERGENCE"),
        )
    )
    assert_true(
        _contains(
            first_name_divergence(
                _names(String("a"), String("b")), _names(String("a"))
            ),
            String("FIRST UNAUTHORED"),
        )
    )


# -----------------------------------------------------------------------------
# The SPEC's own falsifier — a broken spec is a broken gate.
# -----------------------------------------------------------------------------
def test_empty_spec_is_a_fault() raises:
    """An empty spec accepts every emission, including none — the
    `passed == total` hole restated."""
    var fault = spec_fault(_V, List[ExpectedRow]())
    assert_true(_contains(fault, String("SPEC IS EMPTY")), fault)
    # And it must surface through the accounting, not only through spec_fault.
    var via = row_accounting_fault(_V, _emitted_all(), List[ExpectedRow]())
    assert_true(_contains(via, String("SPEC IS INVALID")), via)


def test_blank_obligation_is_a_spec_fault() raises:
    """★ THE ARM THAT KEEPS THE SPEC A SPEC. A row with no stated obligation is a
    number again: deleting it costs nothing, so nothing prevents the decrement
    this whole model exists to make impossible."""
    var s = List[ExpectedRow]()
    s.append(expected_row(String("livez_200"), String("the app answers")))
    s.append(expected_row(String("silent_row"), String("")))
    var fault = spec_fault(_V, s)
    assert_true(_contains(fault, String("states NO OBLIGATION")), fault)
    assert_true(_contains(fault, String("silent_row")), fault)


def test_blank_name_is_a_spec_fault() raises:
    var s = List[ExpectedRow]()
    s.append(expected_row(String(""), String("something")))
    assert_true(_contains(spec_fault(_V, s), String("EMPTY NAME")), spec_fault(_V, s))


def test_duplicate_spec_name_is_a_spec_fault() raises:
    """Two authored rows sharing one name make a [FAIL] line ambiguous, and make
    'row N became a copy of row N-1' authorable rather than caught."""
    var s = List[ExpectedRow]()
    s.append(expected_row(String("dup"), String("a")))
    s.append(expected_row(String("other"), String("b")))
    s.append(expected_row(String("dup"), String("c")))
    var fault = spec_fault(_V, s)
    assert_true(_contains(fault, String("DUPLICATE expected row name")), fault)
    assert_true(_contains(fault, String("indices 0 and 2")), fault)


# -----------------------------------------------------------------------------
# The plan is DERIVED, so it cannot describe a matrix that no longer exists.
# -----------------------------------------------------------------------------
def test_plan_is_derived_from_the_spec() raises:
    var lines = plan_lines(_spec())
    assert_equal(len(lines), expected_count(_spec()))
    assert_true(_contains(lines[0], String("livez_200")), lines[0])
    assert_true(_contains(lines[0], String("the app answers liveness")), lines[0])


def main() raises:
    test_faithful_emission_is_clean()
    test_truncation_is_a_fault()
    test_truncation_to_one_row_is_a_fault()
    test_empty_emission_is_its_own_arm()
    test_exit_code_is_nonzero_for_a_truncated_run()
    test_identity_swap_is_a_fault()
    test_duplicate_emission_is_a_fault()
    test_unauthored_extra_row_is_a_fault()
    test_first_divergence_shapes()
    test_empty_spec_is_a_fault()
    test_blank_obligation_is_a_spec_fault()
    test_blank_name_is_a_spec_fault()
    test_duplicate_spec_name_is_a_spec_fault()
    test_plan_is_derived_from_the_spec()
    print("test_validator_rows: ALL PASS")
