# =============================================================================
# komira_db_postgres/wire/tests/test_pg_tx_op_sequence.mojo — the reusable poll-shaped
# multi-statement TX op: the statement SEQUENCE + the ROLLBACK path.
# =============================================================================
# `PgTxAsyncOp` runs an application WRITE as a multi-statement transaction
# (`BEGIN` / `INSERT task` / `INSERT task_event(created)` / `COMMIT`, with
# `ROLLBACK` on any statement error) over ONE HELD connection. This test pins
# the op's load-bearing CONTRACT at the cursor level:
#
#   1. THE STATEMENT SEQUENCE (success): the op issues, IN ORDER, `BEGIN` ->
#      the business steps (step-0 = INSERT task, step-1 = INSERT task_event) ->
#      `COMMIT`, and lands READY: the `created` task_event is appended in the
#      SAME TX as the task row.
#   2. THE ROLLBACK PATH (a mid-TX statement error): when a business statement
#      errors (e.g. the task_event INSERT fails), the op switches to `ROLLBACK`,
#      issues it, and lands ERR — it NEVER leaves a dangling open transaction,
#      and it does NOT issue `COMMIT`. So a forced mid-TX failure commits
#      NEITHER the task NOR the event (atomicity).
#   3. THE ERROR-ON-FIRST-STATEMENT PATH: an error on the FIRST business step
#      still rolls back (BEGIN already ran) — `[BEGIN, step-0, ROLLBACK]`.
#
# THE SEAM: the op's WIRE round-trip (s2n/pgwire over a leased connection)
# needs a live server — this test drives the op's CURSOR LOGIC directly via
# the SENDLESS `test_drive_sequence`, which walks the EXACT phase/step
# transitions the live `poll` drives (minus the socket I/O) over a list of
# simulated per-statement outcomes, recording the issued statement labels. So
# the SEQUENCE + the ROLLBACK transition are pinned deterministically with NO
# live PG.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_db_postgres.wire import (
    PgTxAsyncOp,
    TxStep,
    PreparedStatement,
    PgValue,
    PG_TX_CAS_MISS_MARKER,
)


# =============================================================================
# §A — helpers: build the two prepared business steps (the create's INSERTs).
# =============================================================================


def _empty_stmt(var name: String) -> PreparedStatement:
    """A stand-in prepared statement (only the LABEL/sequencing is exercised by
    the SENDLESS drive; the real prepared INSERT is bound at the live step)."""
    return PreparedStatement(
        name^, List[UInt32](), List[UInt32](), List[UInt8](), List[Int]()
    )


def _create_tx_steps() -> List[TxStep]:
    """The two business steps of the create TRANSACTION, in order:
    step-0 = INSERT task, step-1 = INSERT task_event(created). The op auto-wraps
    them in BEGIN … COMMIT."""
    var steps = List[TxStep]()
    steps.append(
        TxStep.prepared(_empty_stmt(String("ins_task")), List[PgValue]())
    )
    steps.append(
        TxStep.prepared(_empty_stmt(String("ins_task_event")), List[PgValue]())
    )
    return steps^


def _labels_equal(got: List[String], expected: List[String]) -> Bool:
    if len(got) != len(expected):
        return False
    for i in range(len(got)):
        if got[i] != expected[i]:
            return False
    return True


def _labels_str(labels: List[String]) -> String:
    var out = String("[")
    for i in range(len(labels)):
        if i > 0:
            out += String(", ")
        out += labels[i]
    out += String("]")
    return out^


# =============================================================================
# 1. THE SUCCESS SEQUENCE: BEGIN -> INSERT task -> INSERT task_event -> COMMIT.
# =============================================================================
def test_create_tx_success_sequence() raises:
    """A clean create TX issues `BEGIN`, the task INSERT (step-0), the
    task_event INSERT (step-1), and `COMMIT` — IN THAT ORDER — and lands READY.
    The `created` event is appended in the SAME transaction as the task
    row."""
    var op = PgTxAsyncOp.for_sequence_test(_create_tx_steps())

    # All FOUR issued statements (BEGIN + the two INSERTs + COMMIT) complete
    # READY. The op issues one more statement than the step count: BEGIN, the
    # two business steps, then COMMIT — four outcomes.
    var outcomes = List[Bool]()
    outcomes.append(True)  # BEGIN ok
    outcomes.append(True)  # INSERT task ok
    outcomes.append(True)  # INSERT task_event ok
    outcomes.append(True)  # COMMIT ok
    op.test_drive_sequence(outcomes)

    var expected = List[String]()
    expected.append(String("BEGIN"))
    expected.append(String("step-0"))  # INSERT task
    expected.append(String("step-1"))  # INSERT task_event(created)
    expected.append(String("COMMIT"))

    var got = op.executed_labels()
    assert_true(
        _labels_equal(got, expected),
        "the create TX issues BEGIN/INSERT task/INSERT task_event/COMMIT in "
        "order — got " + _labels_str(got),
    )
    assert_true(op.is_ready(), "the TX lands READY after COMMIT")
    assert_true(not op.is_error(), "no error on the clean path")
    assert_true(not op.is_pending(), "the TX is done (not pending)")
    _ = op^
    print(
        "  [1] success: BEGIN -> INSERT task -> INSERT task_event -> COMMIT, "
        "READY (the created event is in the SAME TX) OK"
    )


# =============================================================================
# 2. THE ROLLBACK PATH: a mid-TX statement error -> ROLLBACK, ERR, no COMMIT.
# =============================================================================
def test_create_tx_rollback_on_event_insert_error() raises:
    """When the SECOND business statement (the task_event INSERT) errors, the op
    switches to `ROLLBACK`, issues it, and lands ERR — it NEVER issues `COMMIT`
    and NEVER leaves a dangling open transaction. So a forced mid-TX failure
    commits NEITHER the task NOR the event (atomicity)."""
    var op = PgTxAsyncOp.for_sequence_test(_create_tx_steps())

    # BEGIN ok, INSERT task ok, INSERT task_event ERRORS -> ROLLBACK ok.
    var outcomes = List[Bool]()
    outcomes.append(True)  # BEGIN ok
    outcomes.append(True)  # INSERT task ok
    outcomes.append(False)  # INSERT task_event ERRORS
    outcomes.append(True)  # ROLLBACK ok
    op.test_drive_sequence(outcomes)

    var expected = List[String]()
    expected.append(String("BEGIN"))
    expected.append(String("step-0"))  # INSERT task
    expected.append(String("step-1"))  # INSERT task_event (errors)
    expected.append(String("ROLLBACK"))  # NOT COMMIT

    var got = op.executed_labels()
    assert_true(
        _labels_equal(got, expected),
        "an event-INSERT error issues ROLLBACK (NOT COMMIT) — got "
        + _labels_str(got),
    )
    # The op did NOT issue COMMIT (atomicity: nothing committed).
    var committed = False
    for i in range(len(got)):
        if got[i] == String("COMMIT"):
            committed = True
    assert_true(
        not committed, "a rolled-back TX NEVER issues COMMIT (nothing persists)"
    )
    assert_true(op.is_error(), "the TX lands ERR after ROLLBACK")
    assert_true(not op.is_ready(), "a rolled-back TX is NOT ready")
    assert_true(not op.is_pending(), "the TX is done (not pending)")
    assert_true(
        op.err_text().byte_length() > 0, "the op surfaces the original error text"
    )
    _ = op^
    print(
        "  [2] rollback: BEGIN -> INSERT task -> INSERT task_event(ERR) -> "
        "ROLLBACK, ERR, no COMMIT (atomicity) OK"
    )


# =============================================================================
# 3. ERROR ON THE FIRST BUSINESS STATEMENT: still rolls back (BEGIN ran).
# =============================================================================
def test_create_tx_rollback_on_first_step_error() raises:
    """An error on the FIRST business statement (the task INSERT) still rolls
    back — BEGIN already opened the TX, so the op MUST issue ROLLBACK to close
    it: `[BEGIN, step-0, ROLLBACK]`, ERR. (The task_event INSERT never runs.)"""
    var op = PgTxAsyncOp.for_sequence_test(_create_tx_steps())

    var outcomes = List[Bool]()
    outcomes.append(True)  # BEGIN ok
    outcomes.append(False)  # INSERT task ERRORS
    outcomes.append(True)  # ROLLBACK ok
    op.test_drive_sequence(outcomes)

    var expected = List[String]()
    expected.append(String("BEGIN"))
    expected.append(String("step-0"))  # INSERT task (errors)
    expected.append(String("ROLLBACK"))

    var got = op.executed_labels()
    assert_true(
        _labels_equal(got, expected),
        "a task-INSERT error issues ROLLBACK; the event INSERT never runs — got "
        + _labels_str(got),
    )
    # step-1 (the task_event INSERT) was NEVER issued.
    var ran_event = False
    for i in range(len(got)):
        if got[i] == String("step-1"):
            ran_event = True
    assert_true(
        not ran_event,
        "an error on the task INSERT short-circuits — the event INSERT never "
        "runs",
    )
    assert_true(op.is_error(), "the TX lands ERR after ROLLBACK")
    _ = op^
    print(
        "  [3] first-step error: BEGIN -> INSERT task(ERR) -> ROLLBACK, ERR, "
        "the event INSERT never ran OK"
    )


# =============================================================================
# 4. THE EXECUTED-LABELS API on a FRESH op is empty (no statement issued yet).
# =============================================================================
def test_fresh_op_has_no_executed_labels() raises:
    """A freshly-built op has issued NO statements (the first is `BEGIN` at
    `start`/the first drive). The label log is empty until the drive runs."""
    var op = PgTxAsyncOp.for_sequence_test(_create_tx_steps())
    assert_equal(
        len(op.executed_labels()), 0, "a fresh op has issued no statements"
    )
    assert_true(op.is_pending(), "a fresh op is pending (not done)")
    _ = op^
    print("  [4] a fresh op has an empty executed-label log + is pending OK")


def test_cas_step_miss_text_is_caller_supplied() raises:
    """A CAS step carries the text the TX fails with on a zero-row result: the
    caller's own text when given, `PG_TX_CAS_MISS_MARKER` otherwise."""
    var own = TxStep.cas(
        _empty_stmt(String("cas")),
        List[PgValue](),
        String("store: concurrent modification"),
    )
    assert_equal(
        own._cas_miss_text,
        String("store: concurrent modification"),
        "a caller-supplied CAS miss text is carried by the step",
    )
    var dflt = TxStep.cas(_empty_stmt(String("cas")), List[PgValue]())
    assert_equal(
        dflt._cas_miss_text,
        PG_TX_CAS_MISS_MARKER,
        "an omitted CAS miss text defaults to PG_TX_CAS_MISS_MARKER",
    )
    var plain = TxStep.prepared(_empty_stmt(String("p")), List[PgValue]())
    assert_equal(
        plain._cas_miss_text.byte_length(), 0, "a plain step has no miss text"
    )
    print("  [5] a CAS step carries the caller's miss text (or the default) OK")


def main() raises:
    test_create_tx_success_sequence()
    test_create_tx_rollback_on_event_insert_error()
    test_create_tx_rollback_on_first_step_error()
    test_fresh_op_has_no_executed_labels()
    test_cas_step_miss_text_is_caller_supplied()
    print(
        "PASS test_pg_tx_op_sequence (the reusable poll-shaped "
        "multi-statement TX op — BEGIN/INSERT task/INSERT task_event/COMMIT "
        "sequence + the ROLLBACK-on-error path, atomicity proven at the cursor "
        "level)"
    )
