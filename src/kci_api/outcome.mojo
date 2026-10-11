# =============================================================================
# src/kci_api/outcome.mojo -- the closed vocabularies of a run's verdict:
#   the OUTCOME of a run or of one step, and the RETRY advice that goes
#   with it.
# =============================================================================
#
# A driver branches on these words, never on an exit number above 5 (the
# exit table, exit_codes.mojo, maps each outcome onto a number for shells).
#
#   SUCCEEDED          the end state holds and this run made it so
#   NOOP               the end state already held; nothing was changed
#                      (publishing identical bytes that are already published)
#   SUPERSEDED         a successful stop: something newer already reached
#                      this stage, or main has moved past this revision, so
#                      the run did nothing on purpose (a never-backward
#                      publish whose channel's newest build descends from
#                      this revision; a push run that the admission check,
#                      R24, stops before any effect). A driver skips the
#                      jobs after it
#   REFUSED            a check refused; nothing external changed
#   FAILED             a step failed and no external effect landed
#   PARTIAL            some effect landed and the rest did not
#   INTERRUPTED        kci was stopped mid-run (a result file still saying
#                      RUNNING is read as this)
#   VALIDATION_FAILED  a validation of what a step produced failed (a
#                      release's install smoke; the deploy side's later)
#   INDETERMINATE      kci cannot say whether the end state holds; never a pass
#   CANCELLED          the driver cancelled the run; whether an effect landed
#                      is told by the result's steps and artifacts
#
# Retry advice:
#
#   SAFE         re-running the same command cannot do harm
#   UNSAFE       an effect may have landed; look before re-running
#   NEEDS_HUMAN  re-running gives the same answer until someone changes
#                something (a file, a flag, an approval)
#
# The words are fixed; their spelling lives here only.
# Pure functions over owned values; no pointer.
# =============================================================================

comptime OUTCOME_SUCCEEDED: String = "SUCCEEDED"
comptime OUTCOME_NOOP: String = "NOOP"
comptime OUTCOME_SUPERSEDED: String = "SUPERSEDED"
comptime OUTCOME_REFUSED: String = "REFUSED"
comptime OUTCOME_FAILED: String = "FAILED"
comptime OUTCOME_PARTIAL: String = "PARTIAL"
comptime OUTCOME_INTERRUPTED: String = "INTERRUPTED"
comptime OUTCOME_VALIDATION_FAILED: String = "VALIDATION_FAILED"
comptime OUTCOME_INDETERMINATE: String = "INDETERMINATE"
comptime OUTCOME_CANCELLED: String = "CANCELLED"

comptime RETRY_SAFE: String = "SAFE"
comptime RETRY_UNSAFE: String = "UNSAFE"
comptime RETRY_NEEDS_HUMAN: String = "NEEDS_HUMAN"


def all_outcomes() -> List[String]:
    """Every outcome word, in the order of this file's header."""
    var out = List[String]()
    out.append(String(OUTCOME_SUCCEEDED))
    out.append(String(OUTCOME_NOOP))
    out.append(String(OUTCOME_SUPERSEDED))
    out.append(String(OUTCOME_REFUSED))
    out.append(String(OUTCOME_FAILED))
    out.append(String(OUTCOME_PARTIAL))
    out.append(String(OUTCOME_INTERRUPTED))
    out.append(String(OUTCOME_VALIDATION_FAILED))
    out.append(String(OUTCOME_INDETERMINATE))
    out.append(String(OUTCOME_CANCELLED))
    return out^


def all_retries() -> List[String]:
    """Every retry word, in the order of this file's header."""
    var out = List[String]()
    out.append(String(RETRY_SAFE))
    out.append(String(RETRY_UNSAFE))
    out.append(String(RETRY_NEEDS_HUMAN))
    return out^


def _member(words: List[String], w: String) -> Bool:
    for i in range(len(words)):
        if words[i] == w:
            return True
    return False


def _joined(words: List[String]) -> String:
    var s = String("")
    for i in range(len(words)):
        if i > 0:
            s += String(" ")
        s += words[i]
    return s^


def is_outcome(word: String) -> Bool:
    return _member(all_outcomes(), word)


def require_outcome(word: String) raises:
    """Refuse a word that is not an outcome (the vocabulary is closed)."""
    if not is_outcome(word):
        raise Error(
            String("outcome '") + word + String("' is not one of: ") + _joined(all_outcomes())
        )


def require_retry(word: String) raises:
    """Refuse a word that is not a retry advice (the vocabulary is closed)."""
    if not _member(all_retries(), word):
        raise Error(
            String("retry '") + word + String("' is not one of: ") + _joined(all_retries())
        )


def outcome_rank(word: String) raises -> Int:
    """How bad an outcome is, for "the run's outcome is its worst step's":
    SUCCEEDED and NOOP are best, INDETERMINATE worst. Two outcomes of equal
    rank never meet in one run except SUCCEEDED with NOOP, where SUCCEEDED
    wins (something was changed). SUPERSEDED ranks after SUCCEEDED: a run
    whose step stopped superseded ends SUPERSEDED, whatever an earlier step
    did, so the jobs after it skip."""
    require_outcome(word)
    if word == OUTCOME_NOOP:
        return 0
    if word == OUTCOME_SUCCEEDED:
        return 1
    if word == OUTCOME_SUPERSEDED:
        return 2
    if word == OUTCOME_REFUSED:
        return 3
    if word == OUTCOME_FAILED:
        return 4
    if word == OUTCOME_VALIDATION_FAILED:
        return 5
    if word == OUTCOME_CANCELLED:
        return 6
    if word == OUTCOME_INTERRUPTED:
        return 7
    if word == OUTCOME_PARTIAL:
        return 8
    return 9  # INDETERMINATE


def worst_outcome(a: String, b: String) raises -> String:
    """The worse of two outcomes (`outcome_rank`)."""
    if outcome_rank(b) > outcome_rank(a):
        return b.copy()
    return a.copy()
