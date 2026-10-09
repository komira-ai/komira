# =============================================================================
# src/kci_api/exit_codes.mojo -- the ONE exit-code table of every kci
#   verb.
# =============================================================================
#
#   exit  name                     outcomes (outcome.mojo)       meaning
#   0     EXIT_OK                  SUCCEEDED, NOOP               the end state holds. This includes
#                                                                "already published, identical
#                                                                bytes" and a dry run that found
#                                                                nothing wrong: neither is a red job
#   1     EXIT_INTERNAL            (error KCI-E-INTERNAL)        kci itself raised past its handlers
#   2     EXIT_USAGE               (error KCI-E-USAGE)           the command line is wrong; nothing read
#   3     EXIT_REFUSED             REFUSED                       a check refused; nothing external changed
#   4     EXIT_FAILED              FAILED                        a step failed and no external effect
#                                                                landed; re-running is safe
#   5     EXIT_CANNOT_TELL         INDETERMINATE                 kci cannot say whether the end state
#                                                                holds; never a pass
#   6     EXIT_PARTIAL             PARTIAL, INTERRUPTED,         some effect landed and the rest did not,
#                                  CANCELLED                     or the run stopped mid-way; look before
#                                                                re-running
#   7     EXIT_VALIDATION_FAILED   VALIDATION_FAILED             a validation failed
#   8     EXIT_LEFT_BEHIND         (none yet)                    reserved: resources left behind
#
# A driver branches on the result document's `outcome`, `retry` and
# `error.id`; the number is for shells. The numbers are v1 and live ONLY
# here: no other kci package may write an exit literal or its own `EXIT_*`.
#
# Three error ids pick the number by themselves (errors.mojo): KCI-E-INTERNAL
# is 1, and KCI-E-USAGE and KCI-E-SELECTOR (a malformed or repeated `--only`,
# which is a command-line error) are 2, whatever the outcome. Every other
# number follows from the outcome alone.
#
# Retry advice follows from the number (`default_retry`): 0 and 4 are SAFE,
# 6 is UNSAFE, every other number NEEDS_HUMAN. A verb may give stronger
# advice for one case (a publish whose read-back disagrees is 6 with
# NEEDS_HUMAN); it may never give SAFE where the default is not.
#
# Three numbers promise that no external effect landed (`promises_no_effect`):
# 2, 3 and 4. A result document whose step row lists a landed node can never
# carry one of them as that step's outcome (result_deploy.mojo).
#
# Pure functions; no pointer.
# =============================================================================

from kci_api.errors import ERROR_INTERNAL, ERROR_SELECTOR, ERROR_USAGE
from kci_api.outcome import (
    OUTCOME_FAILED,
    OUTCOME_INDETERMINATE,
    OUTCOME_NOOP,
    OUTCOME_REFUSED,
    OUTCOME_SUCCEEDED,
    OUTCOME_VALIDATION_FAILED,
    RETRY_NEEDS_HUMAN,
    RETRY_SAFE,
    RETRY_UNSAFE,
    require_outcome,
    require_retry,
)

comptime EXIT_OK: Int = 0
comptime EXIT_INTERNAL: Int = 1
comptime EXIT_USAGE: Int = 2
comptime EXIT_REFUSED: Int = 3
comptime EXIT_FAILED: Int = 4
comptime EXIT_CANNOT_TELL: Int = 5
comptime EXIT_PARTIAL: Int = 6
comptime EXIT_VALIDATION_FAILED: Int = 7
comptime EXIT_LEFT_BEHIND: Int = 8


struct ExitRow(Copyable, Movable):
    """One row of the exit table.

    Layout: an Int and owned Strings. No pointer field."""

    var code: Int
    var name: String
    var meaning: String

    def __init__(out self, code: Int, var name: String, var meaning: String):
        self.code = code
        self.name = name^
        self.meaning = meaning^


def exit_table() -> List[ExitRow]:
    """The exit table, in the order of this file's header."""
    var t = List[ExitRow]()
    t.append(ExitRow(EXIT_OK, String("EXIT_OK"), String("the end state holds")))
    t.append(ExitRow(EXIT_INTERNAL, String("EXIT_INTERNAL"), String("kci itself raised past its handlers")))
    t.append(ExitRow(EXIT_USAGE, String("EXIT_USAGE"), String("the command line is wrong; nothing was read")))
    t.append(ExitRow(EXIT_REFUSED, String("EXIT_REFUSED"), String("a check refused; nothing external changed")))
    t.append(ExitRow(EXIT_FAILED, String("EXIT_FAILED"), String("a step failed and no external effect landed")))
    t.append(ExitRow(EXIT_CANNOT_TELL, String("EXIT_CANNOT_TELL"), String("kci cannot say whether the end state holds")))
    t.append(ExitRow(EXIT_PARTIAL, String("EXIT_PARTIAL"), String("some effect landed and the rest did not, or the run stopped mid-way")))
    t.append(ExitRow(EXIT_VALIDATION_FAILED, String("EXIT_VALIDATION_FAILED"), String("a validation of what a step produced failed")))
    t.append(ExitRow(EXIT_LEFT_BEHIND, String("EXIT_LEFT_BEHIND"), String("reserved: resources were left behind")))
    return t^


def exit_code_of(outcome: String, error_id: String = String("")) raises -> Int:
    """The exit number of a run whose outcome is `outcome` and whose first
    error (if any) is `error_id` (file header)."""
    require_outcome(outcome)
    if error_id == ERROR_INTERNAL:
        return EXIT_INTERNAL
    if error_id == ERROR_USAGE or error_id == ERROR_SELECTOR:
        return EXIT_USAGE
    if outcome == OUTCOME_SUCCEEDED or outcome == OUTCOME_NOOP:
        return EXIT_OK
    if outcome == OUTCOME_REFUSED:
        return EXIT_REFUSED
    if outcome == OUTCOME_FAILED:
        return EXIT_FAILED
    if outcome == OUTCOME_INDETERMINATE:
        return EXIT_CANNOT_TELL
    if outcome == OUTCOME_VALIDATION_FAILED:
        return EXIT_VALIDATION_FAILED
    # PARTIAL, INTERRUPTED, CANCELLED
    return EXIT_PARTIAL


def default_retry(exit_code: Int) raises -> String:
    """The retry advice of an exit number (file header)."""
    if exit_code < EXIT_OK or exit_code > EXIT_LEFT_BEHIND:
        raise Error(String("exit ") + String(exit_code) + String(" is not in kci's exit table"))
    if exit_code == EXIT_OK or exit_code == EXIT_FAILED:
        return String(RETRY_SAFE)
    if exit_code == EXIT_PARTIAL:
        return String(RETRY_UNSAFE)
    return String(RETRY_NEEDS_HUMAN)


def require_retry_for(exit_code: Int, retry: String) raises:
    """Refuse `retry` advice that is weaker than the exit number's default:
    SAFE where the default is not, or UNSAFE where it is NEEDS_HUMAN."""
    require_retry(retry)
    var d = default_retry(exit_code)
    if retry == d:
        return
    if retry == RETRY_NEEDS_HUMAN:
        return
    raise Error(
        String("retry '") + retry + String("' is weaker than exit ") + String(exit_code)
        + String("'s advice '") + d + String("'")
    )


def promises_no_effect(exit_code: Int) -> Bool:
    """True for the numbers whose meaning says no external effect landed:
    2 (nothing was read), 3 (nothing external changed) and 4 (no external
    effect landed) (file header)."""
    return exit_code == EXIT_USAGE or exit_code == EXIT_REFUSED or exit_code == EXIT_FAILED
