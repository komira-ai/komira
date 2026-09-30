# =============================================================================
# komira_ci_logs/tests/test_empty_stream_speaks_its_own_stream.mojo —
#   ★★ AN EMPTY READ MUST BE REPORTED IN THE **SOURCE'S** VOCABULARY, AND MUST
#   CARRY THE TWO FIELDS THAT SAY WHETHER THE STREAM ACTUALLY ENDED.
# =============================================================================
#
# ── THE DEFECT ───────────────────────────────────────────────────────────────
# A single-vocabulary empty branch prints, over a CLOUD RUN CONTAINER'S
# STDOUT:
#
#     run-log: NO STAGE RECORDS for run <exec> — the stream is empty (read 1
#     page(s)). Nothing wrote a stage record for this run.
#
# THREE DEFECTS IN ONE BRANCH:
#
#   1. IT USES PIPELINE-RUN STAGE VOCABULARY FOR A STREAM THAT IS NOT THE
#      STAGE STREAM. Nothing writes a "stage record" to a container's stdout, so
#      the sentence names a failure that cannot occur — a FINDING-SHAPED
#      NON-FINDING. A reader believes it even about a job that demonstrably
#      printed rows, and goes looking for a missing writer that does not exist.
#
#   2. IT OMITS `done` AND `next_cursor` — the only two fields that separate
#      "genuinely empty" from "page 1 of N", while the RECORDS branch prints
#      both. That is exactly backwards: the empty case is the one that needs
#      them.
#
#   3. THE VOCABULARY WAS CHOSEN BY THE RENDERER, NOT BY THE SOURCE. One
#      `RunLogTail` serves two streams on purpose (a second renderer is a second
#      bounded redacting printer to keep in agreement by hand). So the fix is for
#      the TAIL to carry which stream it is.
#
# ⚠ WHAT THIS FILE MUST **NOT** BE SATISFIABLE BY: a renderer that prints both
# vocabularies, or that prints a fixed caveat on every stream. Every positive
# assertion here has a NEGATIVE twin on the other stream.
#
# Pure: one POD in, one String out. No transport, no cloud, no socket.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_ci_logs import (
    RUN_LOG_STREAM_CONTAINER_STDOUT,
    RUN_LOG_STREAM_STAGE_RECORDS,
    RunLogRecord,
    RunLogTail,
    render_run_log_tail,
)


comptime _EXEC: String = (
    "projects/example-project/locations/us-central1/jobs/example-e2e/executions/"
    "example-e2e-abc12"
)
comptime _RUN: String = "0192f8aa-1111-7abc-9def-0123456789ab"


def _contains(hay: String, needle: String) -> Bool:
    return hay.find(needle) >= 0


def _empty(kind: Int, pages: Int, done: Bool, next_cursor: Int) -> RunLogTail:
    var t = RunLogTail.empty()
    t.run_id = _EXEC if kind == RUN_LOG_STREAM_CONTAINER_STDOUT else _RUN
    t.stream_kind = kind
    t.pages = pages
    t.done = done
    t.next_cursor = next_cursor
    return t^


def _settled(pages: Int, done: Bool, settles: Int) -> RunLogTail:
    """A CONTAINER tail that spent `settles` bounded waits. ⚠ A separate builder
    rather than a fifth parameter on `_empty`: the cases built by `_empty` are
    about the stream vocabulary and assert over a tail that spent no settle
    waits."""
    var t = _empty(RUN_LOG_STREAM_CONTAINER_STDOUT, pages, done, 0)
    t.settles = settles
    return t^


def _row(msg: String) -> RunLogRecord:
    return RunLogRecord(
        1, 0, String(""), String("2026-09-14T00:00:00Z"), msg.copy()
    )


# =============================================================================
# §1 — THE VOCABULARY BELONGS TO THE SOURCE.
# =============================================================================
def test_an_empty_container_read_does_not_accuse_a_stage_writer() raises:
    """★★ THE DEFECT, AS AN ASSERTION.

    RED ON THE DEFECT: with no `stream_kind` on `RunLogTail` and one empty
    branch in the renderer, it says `NO STAGE RECORDS ... Nothing wrote a stage
    record for this run` over a container's stdout."""
    var out = render_run_log_tail(
        _empty(RUN_LOG_STREAM_CONTAINER_STDOUT, 1, True, 0)
    )
    assert_false(
        _contains(out, String("STAGE RECORD")),
        String(
            "⛔ A CONTAINER STREAM HAS NO STAGE RECORDS AND NEVER DID. A"
            " sentence about a missing one is a finding-shaped non-finding: it"
            " names a writer that does not exist for this stream. Got: "
        )
        + out,
    )
    assert_true(
        _contains(out, String("NO CONTAINER OUTPUT read for")),
        String("and it says what it actually means. Got: ") + out,
    )
    assert_true(
        _contains(out, _EXEC),
        String("naming the execution the operator has to go read. Got: ") + out,
    )


def test_the_stage_stream_keeps_its_own_sentence_unchanged() raises:
    """⛔ THE NEGATIVE TWIN, AND WITHOUT IT THE FIX IS UNFALSIFIED. A renderer
    that simply replaced one sentence with the other would pass §1 and would have
    broken the stream this library was WRITTEN for — where "nothing wrote a stage
    record" IS the diagnosis. The default kind is the stage stream precisely so
    every producer that does not set `stream_kind` gets this sentence."""
    var out = render_run_log_tail(
        _empty(RUN_LOG_STREAM_STAGE_RECORDS, 1, False, 0)
    )
    assert_true(
        _contains(out, String("NO STAGE RECORDS for run")),
        String("the pipeline stream's own words survive. Got: ") + out,
    )
    assert_true(
        _contains(out, String("Nothing wrote a stage record for this run.")),
        String("including the diagnosis, which is TRUE there. Got: ") + out,
    )
    assert_false(
        _contains(out, String("CONTAINER OUTPUT")),
        String("and it does not borrow the other stream's words. Got: ") + out,
    )


def test_a_tail_that_claims_no_kind_is_the_stage_stream() raises:
    """⚠ THE DEFAULT IS A COMPATIBILITY CLAIM, not a convenience. A producer
    that does not set `stream_kind` builds its tail through
    `RunLogTail.empty()` / `.failed()` and is reading the pipeline stream. A
    default of "container" would silently give that stream the container
    stream's words."""
    var t = RunLogTail.empty()
    assert_equal(
        t.stream_kind,
        RUN_LOG_STREAM_STAGE_RECORDS,
        "an unclaimed tail is the stage-record stream",
    )
    assert_equal(
        RunLogTail.failed(String("HTTP 403")).stream_kind,
        RUN_LOG_STREAM_STAGE_RECORDS,
        "and so is a failed one",
    )


# =============================================================================
# §2 — `done` IS THE FIELD THE EMPTY BRANCH NEEDED MOST AND DID NOT HAVE.
# =============================================================================
def test_an_empty_read_says_whether_the_stream_actually_ended() raises:
    """⛔ "THE STREAM IS EMPTY" AND "PAGE 1 OF N WAS EMPTY" ARE DIFFERENT
    FINDINGS, and `done` is the only field that separates them. The empty branch
    printed `pages` alone while the RECORDS branch printed `pages` + cursor +
    `done` — exactly backwards, because a records branch already shows the reader
    something."""
    var not_ended = render_run_log_tail(
        _empty(RUN_LOG_STREAM_CONTAINER_STDOUT, 3, False, 0)
    )
    assert_true(
        _contains(not_ended, String("done=false")),
        String("the empty branch carries `done`. Got: ") + not_ended,
    )
    assert_true(
        _contains(not_ended, String("3 page(s)")),
        String("and the honest page count of the walk. Got: ") + not_ended,
    )
    assert_true(
        _contains(not_ended, String("DID NOT REACH THE END")),
        String(
            "★ and it SAYS what `done=false` means rather than leaving the"
            " reader to know. Got: "
        )
        + not_ended,
    )
    var ended = render_run_log_tail(
        _empty(RUN_LOG_STREAM_CONTAINER_STDOUT, 1, True, 0)
    )
    assert_true(
        _contains(ended, String("done=true")),
        String("and the other state is reported too. Got: ") + ended,
    )
    assert_false(
        _contains(ended, String("DID NOT REACH THE END")),
        String(
            "⛔ AND THE TWO STATES MAY NOT SHARE A SENTENCE. Printing the"
            " `done=false` explanation under `done=true` is the same class of"
            " defect as the stage-record vocabulary: a true-sounding sentence"
            " about a state the reader is not in. Got: "
        )
        + ended,
    )


def test_an_empty_container_read_names_ingestion_lag_as_the_likely_cause() raises:
    """★ THE READ HAPPENS AT T+0 AGAINST A LAGGING PIPELINE. The deploy tool
    issues it the instant a step is decided STEP_FAIL, and cloud logging ingests
    seconds-to-a-minute behind a container that has just died — so an EMPTY FIRST
    READ IS THE EXPECTED RESULT, not evidence that the container printed nothing.
    Reading it as evidence is how a validator whose rows had simply not landed
    yet gets diagnosed as a validator that printed none."""
    var out = render_run_log_tail(
        _empty(RUN_LOG_STREAM_CONTAINER_STDOUT, 1, True, 0)
    )
    assert_true(
        _contains(out, String("NOT PROOF THE CONTAINER PRINTED NOTHING")),
        String("the caveat is stated. Got: ") + out,
    )
    assert_true(
        _contains(out, String("ingests asynchronously")),
        String("naming the mechanism, not just hedging. Got: ") + out,
    )


def test_the_caveat_is_not_printed_on_the_stage_stream() raises:
    """⛔ THE ANTI-VACUITY TWIN. A fixed caveat appended to every empty read
    would satisfy §2's positive assertion and would put a Cloud-Logging
    explanation on a stream that has no cloud-logging provider in it — a second
    sentence about a mechanism that is not there, which is the defect this file
    exists to remove, pointed the other way."""
    var out = render_run_log_tail(
        _empty(RUN_LOG_STREAM_STAGE_RECORDS, 1, True, 0)
    )
    assert_false(
        _contains(out, String("ingests asynchronously")),
        String("no ingestion caveat on the pipeline stream. Got: ") + out,
    )


# =============================================================================
# §3 — `next_cursor` IS THE STAGE STREAM'S, AND ONLY ITS.
# =============================================================================
def test_the_cursor_is_printed_where_it_MEANS_something() raises:
    """⚠ NOT A COSMETIC NARROWING. `next_cursor` is the run-log route's real
    `?after=` cursor, so on the stage stream it is what an operator types next.
    On a container stream NOTHING sets it — the continuation a cloud provider
    returns is an OPAQUE STRING token this POD has no field for — so printing
    `next_cursor=0` would put a number that means nothing beside two that mean
    something, on the branch whose entire job is to stop a reader drawing a
    conclusion the data does not support."""
    var stage = render_run_log_tail(
        _empty(RUN_LOG_STREAM_STAGE_RECORDS, 2, False, 7)
    )
    assert_true(
        _contains(stage, String("next_cursor=7")),
        String("the stage stream prints its cursor. Got: ") + stage,
    )
    var container = render_run_log_tail(
        _empty(RUN_LOG_STREAM_CONTAINER_STDOUT, 2, False, 0)
    )
    assert_false(
        _contains(container, String("next_cursor")),
        String(
            "⛔ and the container stream does not print a cursor nothing sets."
            " Got: "
        )
        + container,
    )


def test_the_records_branch_reports_the_same_extent_as_the_empty_one() raises:
    """★ ONE CLAUSE, BOTH BRANCHES. Two read-extent reports drift when they
    are two pieces of code; `_read_extent_clause` is why they cannot. This pins that a records-bearing container tail is reported with the
    SAME shape the empty one is — the page count and `done`, no cursor."""
    var t = _empty(RUN_LOG_STREAM_CONTAINER_STDOUT, 3, False, 0)
    t.records.append(
        RunLogRecord(1, 0, String(""), String("2026-09-13T00:00:00Z"),
                     String("VERDICT: FAIL (3/10 rows)"))
    )
    var out = render_run_log_tail(t^)
    assert_true(
        _contains(out, String("VERDICT: FAIL (3/10 rows)")),
        String("sanity: the record is rendered. Got: ") + out,
    )
    assert_true(
        _contains(out, String("3 page(s), 0 settle(s), done=false)")),
        String(
            "the SAME extent clause the empty branch uses — page count,"
            " SETTLE COUNT and `done`, adjacent, one function. ⚠ The settle"
            " count lives in ONE place, so both branches report it. Got: "
        )
        + out,
    )
    assert_false(
        _contains(out, String("next_cursor")),
        String(
            "⛔ and the records branch prints no container cursor either"
            " (no `next_cursor=0` on a cloud tail). Got: "
        )
        + out,
    )


# =============================================================================
# §4 — ★★★ A ZERO-ROW READ MAY NOT RENDER AS A SUCCESSFUL READ.
#
# ── THE SHAPE IT PREVENTS ────────────────────────────────────────────────────
#     validator output: READ BY THIS TOOL — the rows below were fetched from
#     this step's own stream by komira_ci; no raw cloud command is needed. ...
#     validate-dag: 0/1 step(s) passed (1 failed, 0 skipped) — FAIL
#
# The sentence "the rows below were fetched" with NO ROWS BELOW IT violates
# this renderer's standard: ⭐ *"found nothing to look for" and "found nothing"
# are the same output* — and neither is ever a pass.
#
# ⛔ EVERY CASE HERE ASSERTS A **FLOOR AS WELL AS A CEILING**. A renderer that
# printed NOTHING AT ALL would satisfy "does not claim rows it does not have",
# and would be that defect exactly.
# =============================================================================
def test_an_empty_container_read_states_rows_pages_and_settles() raises:
    """★★★ THE THREE NUMBERS THAT DECIDE WHAT AN EMPTY READ MEANS, on one line.

    RED ON A CLAUSE OF `(1 page(s), done=true)` — no row count as a number and
    NO SETTLE COUNT AT ALL, so a reader cannot tell a read that gave the
    provider its full ten-second ingestion window from one that asked once at
    T+0 and believed the answer. The tool makes that distinction internally and
    must not keep it to itself."""
    var out = render_run_log_tail(_settled(1, True, 0))
    assert_true(
        _contains(out, String("0 row(s)")),
        String(
            "⭐ THE FLOOR: the row count is stated as a NUMBER, not only as the"
            " words NO CONTAINER OUTPUT — a report that states only the word"
            " reads as prose a skimmer skips. Got: "
        )
        + out,
    )
    assert_true(
        _contains(out, String("1 page(s)")),
        String("and how much of the stream was walked. Got: ") + out,
    )
    assert_true(
        _contains(out, String("0 settle(s)")),
        String(
            "★★ AND WHETHER THE TOOL WAITED. This is the number the report did"
            " not contain, and it is the one that separates 'the container"
            " printed nothing' from 'the read beat the ingestion'. Got: "
        )
        + out,
    )


def test_an_empty_read_that_spent_NO_settle_says_so_as_a_finding() raises:
    """★★ ZERO SETTLES ON A `done=true` EMPTY READ IS ITS OWN FINDING.

    ⛔ AND ITS NEGATIVE TWIN IS IN THE NEXT CASE. A renderer that printed this
    warning unconditionally would be a fixed caveat, which this file's header
    already forbids."""
    var out = render_run_log_tail(_settled(1, True, 0))
    assert_true(
        _contains(out, String("SPENT **NO** SETTLE")),
        String(
            "a stream reported as ENDED, read with zero wait, over a container"
            " that just died — the report must say the tool did not wait. Got: "
        )
        + out,
    )


def test_a_read_that_DID_settle_is_not_accused_of_not_waiting() raises:
    """⛔ THE NEGATIVE TWIN — delete the `settles == 0` guard and this goes red.

    A read that spent its full budget and still came back empty has done
    everything it can; telling its reader "the tool did not wait" would be false,
    and a caveat printed on every read is a caveat readers learn to skip."""
    var out = render_run_log_tail(_settled(3, True, 2))
    assert_true(
        _contains(out, String("2 settle(s)")),
        String("the waits it DID spend are stated. Got: ") + out,
    )
    assert_false(
        _contains(out, String("SPENT **NO** SETTLE")),
        String(
            "⛔ and it is NOT accused of skipping a wait it took. Got: "
        )
        + out,
    )


def test_a_done_false_empty_read_is_not_told_to_wait() raises:
    """⛔ THE OTHER NEGATIVE TWIN, AND IT IS THE ONE THAT KEEPS THE FIX HONEST.

    `done=false` means a continuation token was outstanding — the walk stopped on
    its OWN bound with the stream still going. Spending no settle there is the
    settle policy WORKING (`container_log_should_settle`'s token branch), so
    warning about it would manufacture a finding out of correct behaviour, which
    is the finding-shaped-non-finding class §1 of this file guards against.
    And the remedy differs: what is missing is ALREADY THERE."""
    var out = render_run_log_tail(_settled(3, False, 0))
    assert_false(
        _contains(out, String("SPENT **NO** SETTLE")),
        String(
            "⛔ a walk holding a continuation token was RIGHT not to wait. Got: "
        )
        + out,
    )
    assert_true(
        _contains(out, String("DID NOT REACH THE END OF THE STREAM")),
        String(
            "★ and the reader is told the true reason instead: more exists"
            " right now, so a re-read fetches it and waiting does not. Got: "
        )
        + out,
    )


def test_an_empty_container_read_names_what_to_do_next() raises:
    """★★ AN ABSENCE WITH NO NEXT ACTION IS A DEAD END.

    ⛔ AND THE NEXT ACTION MAY NOT BE A RAW CLOUD COMMAND. The remedy is a
    `komira_ci` command: this read is the tool that replaces a raw `gcloud` or
    `aws` log query, so printing one here would send the reader back to the
    thing it replaces."""
    var out = render_run_log_tail(_settled(1, True, 0))
    assert_true(
        _contains(out, String("NEXT:")),
        String("⭐ THE FLOOR: an absence must name a next action. Got: ") + out,
    )
    assert_true(
        _contains(out, String("--only-validate=step:")),
        String(
            "and it is an EXISTING komira_ci spelling — re-run THIS gate alone"
            " once ingestion has caught up, not a new verb. Got: "
        )
        + out,
    )
    # ⚠ THE TOKEN, NOT THE INSTRUCTION. A sentence such as *"do NOT reach for
    # a raw gcloud/aws command"* FORBIDS the thing and still puts the token in
    # an operator's log, where a grep-based audit (and a skimming reader)
    # cannot tell a mention from an offer. So the sentence names neither tool.
    assert_false(
        _contains(out, String("gcloud")),
        String("⛔ NO RAW CLOUD COMMAND, NOT EVEN NAMED. Got: ") + out,
    )
    assert_false(
        _contains(out, String("aws logs")),
        String("⛔ NOR THE AWS ONE — both arms, one rule. Got: ") + out,
    )


def test_the_next_action_is_NOT_printed_on_the_stage_stream() raises:
    """⛔ THE NEGATIVE TWIN. The pipeline-run stage stream has no ingestion lag,
    no settle, and no `--only-validate` remedy — an empty one means nobody wrote
    a stage record, which is a different diagnosis with a different next step.
    A renderer that printed the cloud advice on both streams would be the
    vocabulary defect this file was opened for, wearing a new hat."""
    var out = render_run_log_tail(_empty(RUN_LOG_STREAM_STAGE_RECORDS, 1, True, 0))
    assert_false(
        _contains(out, String("NEXT:")),
        String("the stage stream keeps its own sentence. Got: ") + out,
    )
    assert_false(
        _contains(out, String("settle(s)")),
        String(
            "⛔ and it prints no settle count: a number that means nothing"
            " printed beside two that mean something is the `next_cursor=0`"
            " defect in the other direction. Got: "
        )
        + out,
    )


def test_a_SHORT_read_is_not_rendered_as_a_complete_one() raises:
    """★★★ THE ONE-LINE READ — the shape the settle policy classes as
    MID-INGESTION.

    RED IF it renders through the ordinary records branch as `showing 1
    record(s)`, indistinguishable from a container that printed one line and
    stopped. The tool knows the number is probably not the answer and would
    print it as if it were — the fail-quiet the settle exists to remove, one
    layer up.

    ⛔ FLOOR: the row is STILL PRINTED. A short read is very often the only
    evidence there is, and suppressing it would trade a partial answer for none."""
    var t = _settled(2, True, 2)
    t.records.append(_row(String("VERDICT: FAIL (3/10 rows)")))
    var out = render_run_log_tail(t^)
    assert_true(
        _contains(out, String("VERDICT: FAIL (3/10 rows)")),
        String(
            "⭐ THE FLOOR: the line is still printed — this ADDS a sentence, it"
            " does not suppress evidence. Got: "
        )
        + out,
    )
    assert_true(
        _contains(out, String("SHORT READ")),
        String(
            "★★ and the report says the tool's OWN settle policy classed this"
            " read as mid-ingestion rather than complete. Got: "
        )
        + out,
    )
    assert_true(
        _contains(out, String("credible floor of 2")),
        String(
            "naming the number it was judged against, so the judgement is"
            " reproducible rather than an assertion. Got: "
        )
        + out,
    )
    assert_true(
        _contains(out, String("NEXT:")),
        String("and a short read gets the next action too. Got: ") + out,
    )


def test_a_CREDIBLE_read_carries_no_short_read_sentence() raises:
    """⛔ THE NEGATIVE TWIN — delete the floor comparison and this goes red.

    Two rows is AT the floor, which is where `container_log_should_settle` stops
    waiting. A caveat on every rendered tail is a caveat nobody reads."""
    var t = _settled(1, True, 0)
    t.records.append(_row(String("row 1/2 ok")))
    t.records.append(_row(String("VERDICT: PASS (2/2 rows)")))
    var out = render_run_log_tail(t^)
    assert_false(
        _contains(out, String("SHORT READ")),
        String("a read at the credible floor is not short. Got: ") + out,
    )
    assert_false(
        _contains(out, String("NEXT:")),
        String(
            "⛔ and a credible read needs no next action — this is what stops"
            " the advice from becoming a fixed footer. Got: "
        )
        + out,
    )


def test_a_short_read_CUT_SHORT_BY_A_FAULT_is_not_blamed_on_ingestion() raises:
    """⛔ TWO CAUSES MAY NOT BE OFFERED FOR ONE EFFECT.

    A read that obtained one row and then FAULTED is short BECAUSE OF THE FAULT,
    and the partial-read line already names it. Adding "this is probably
    ingestion lag" beside a stated 403 is a second, wrong cause — the class of
    true-sounding sentence about a state the reader is not in that this file's §1
    exists to prevent."""
    var t = _settled(2, False, 0)
    t.records.append(_row(String("row 1/9 ok")))
    t.fetch_error = String("HTTP 403 (117 bytes)")
    var out = render_run_log_tail(t^)
    assert_true(
        _contains(out, String("CUT SHORT")),
        String("sanity: the partial-read arm fired. Got: ") + out,
    )
    assert_false(
        _contains(out, String("SHORT READ")),
        String(
            "⛔ and the ingestion explanation is NOT offered on top of a stated"
            " transport fault. Got: "
        )
        + out,
    )


def main() raises:
    test_an_empty_container_read_does_not_accuse_a_stage_writer()
    test_the_stage_stream_keeps_its_own_sentence_unchanged()
    test_a_tail_that_claims_no_kind_is_the_stage_stream()
    test_an_empty_read_says_whether_the_stream_actually_ended()
    test_an_empty_container_read_names_ingestion_lag_as_the_likely_cause()
    test_the_caveat_is_not_printed_on_the_stage_stream()
    test_the_cursor_is_printed_where_it_MEANS_something()
    test_the_records_branch_reports_the_same_extent_as_the_empty_one()
    # §4 — ★★★ a ZERO-ROW read may not render as a successful read.
    # Every case has its negative twin: the warnings must be reachable AND must
    # not fire on the states they would be false about.
    test_an_empty_container_read_states_rows_pages_and_settles()
    test_an_empty_read_that_spent_NO_settle_says_so_as_a_finding()
    test_a_read_that_DID_settle_is_not_accused_of_not_waiting()
    test_a_done_false_empty_read_is_not_told_to_wait()
    test_an_empty_container_read_names_what_to_do_next()
    test_the_next_action_is_NOT_printed_on_the_stage_stream()
    test_a_SHORT_read_is_not_rendered_as_a_complete_one()
    test_a_CREDIBLE_read_carries_no_short_read_sentence()
    test_a_short_read_CUT_SHORT_BY_A_FAULT_is_not_blamed_on_ingestion()
    print("PASS test_empty_stream_speaks_its_own_stream (17 cases)")
