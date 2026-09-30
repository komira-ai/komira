# =============================================================================
# kci_logs/cloud_log_source.mojo — the CLOUD-NEUTRAL seam for reading
#   ONE terminated run-to-completion unit's CONTAINER OUTPUT, plus the adapter
#   that turns what comes back into the `RunLogTail` the deploy report already
#   knows how to print.
# =============================================================================
#
# ⛔ WHY THIS EXISTS. When a deploy gate fails on a cloud execution, a report
# that ends with "read it with: gcloud logging read 'resource.type=...'" is
# advice, not a tool: the release tool knew WHICH artifact held the answer,
# printed its address, and had no verb behind it. The `run_log_*` modules close
# the same gap for a pipeline run's stage logs; this module closes it for a cloud
# unit's container output. **Advice is not a tool.**
#
# ── WHAT IT BUILDS ON ────────────────────────────────────────────────────────
#   * the `run_log_*` modules — the RECORD, the TAIL, the bounded+redacted RENDER, and
#     `DagValidator.failure_run_log_tail`, the enrichment seam `run_validation_
#     dag` calls UNASKED on every STEP_FAIL. ⇒ The printing half already exists.
# This module adds the READ: a read-only Cloud Logging / CloudWatch Logs client
# shape, in a library, cloud-neutral, with the transport behind a trait so every
# branch is provable with no network.
#
# ── ⛔ THE CONTRACT THAT MATTERS MOST: A READ HERE MAY NOT CHANGE A VERDICT ──
# Identical to `fetch_run_log_tail`'s. Every consumer of this seam is, by
# construction, ALREADY reporting a failure. A conformer reports a fault as a
# `CloudLogPage` carrying `fault`; the adapter turns that into a `RunLogTail`
# whose `fetch_error` the renderer states in ONE line. The ORIGINAL failure is
# what the operator came for; the logs are what make it diagnosable.
#
# ── ⛔ AND IT MAY NOT PRINT A SECRET. Entries reach a `RunLogRecord.message`,
# which `render_run_log_tail` puts through `redact_secretish` on the way out.
# Parsers in this package are FIELD-ALLOW-LISTED (`gcp_logging_query` /
# `aws_cloudwatch_query`) — a key that is not on the list is skipped, not stored,
# not rendered, not counted. ⛔ Never hand-build a page out of a raw body.
#
# ENCAPSULATION: value PODs only. ZERO UnsafePointer crosses any
# signature, no wildcard origin, no FFI. Flat `String`/`List[String]`
# fields on per-run values, no byte-slab, no destroy-recreate pool member.
# def-based, Mojo 1.0.0b2.
# =============================================================================

from std.memory import ArcPointer

from kci_logs.run_log_tail import (
    # ★★ THE CREDIBLE FLOOR IS **IMPORTED**, NOT DEFINED HERE. It lives in
    # `run_log_tail` (which cannot depend on this module) so the WAITER
    # below and the RENDERER there read ONE number: the report the operator
    # reads can then state the same judgement the waiter made about a read
    # being mid-ingestion. ⛔ Do NOT re-declare it here: two `= 2`s that must
    # agree by hand is how bounds drift.
    CONTAINER_LOG_CREDIBLE_FLOOR,
    RUN_LOG_STREAM_CONTAINER_STDOUT,
    RunLogRecord,
    RunLogTail,
)


comptime DEFAULT_CONTAINER_LOG_LIMIT: Int = 200
"""How many entries ONE `read_container_output` asks for by default.

The SAME 200 the equivalent `gcloud logging read` command uses, and
for the same reason: a validator's failing rows plus its `VERDICT:` line are at
the END of a bounded stream, and every view of this stream in the tree is
bounded alike. The RENDER bound is separate and smaller
(`DEFAULT_MAX_RENDERED_RECORDS`) — this one bounds the FETCH."""


# =============================================================================
# §1 — CloudLogEntry — ONE line of container output. Flat POD.
# =============================================================================
@fieldwise_init
struct CloudLogEntry(Copyable, Movable, Deinitable):
    """One entry of a terminated unit's log stream, reduced to the three fields
    that are the same question on every cloud.

    THE THREE:

      * `timestamp` — the provider's own emit time, VERBATIM as the provider
                      spelled it (RFC3339 on GCP; a bare epoch-millis integer
                      rendered as digits on AWS). ⛔ NOT normalised — a
                      diagnostic renderer that re-formats a timestamp is a
                      renderer that can disagree with the provider's console,
                      and the operator has both open.
      * `severity`  — the provider's level token (`ERROR` / `INFO` / ...), or
                      EMPTY where the provider attaches none (CloudWatch does
                      not).
      * `text`      — the line itself.

    EVERYTHING ELSE THE PROVIDER SENT IS DROPPED AT THE PARSER, not here — see
    the allow-lists. This POD is what SURVIVED that cut."""

    var timestamp: String
    var severity: String
    var text: String

    @staticmethod
    def empty() -> CloudLogEntry:
        return CloudLogEntry(String(""), String(""), String(""))


# =============================================================================
# §2 — CloudLogPage — ONE read's result.
# =============================================================================
@fieldwise_init
struct CloudLogPage(Copyable, Movable, Deinitable):
    """What ONE `read_container_output` produced.

      * `entries`    — OLDEST -> NEWEST. The order is a REQUIREMENT, not an
                       observation: the rows that explain a validator failure are
                       at the END, so a conformer that receives newest-first MUST
                       reverse before returning (`entries_list_body` asks the
                       provider for ascending order so the GCP arm never has to).
      * `status`     — the HTTP status the provider answered, or 0 when the dial
                       itself never reached a verdict. Kept because a 403 and a
                       DNS failure send the operator to two different places.
      * `fault`      — EMPTY on a read that produced an answer (INCLUDING an
                       empty one). Non-empty means `entries` is not an answer.
      * `next_token` — the provider's continuation token AFTER the last read
                       this page aggregates. EMPTY means the stream ended here;
                       non-empty means it did not, and the renderer says so
                       (`done=false`). ⚠ It is an OPAQUE PROVIDER STRING and is
                       never a cursor any other layer may invent.
      * `pages`        — HOW MANY PROVIDER READS THIS PAGE AGGREGATES. ⛔ NOT
                       decoration and not always 1 (this seam follows
                       `next_token`): the renderer prints "read N page(s)", and a
                       conformer that read three and reported one would put a
                       false statement into the report. 0 means
                       the provider was never reached.
      * `settles`    — HOW MANY BOUNDED WAITS THIS READ SPENT before it accepted
                       its answer. ⛔ A DIFFERENT QUESTION FROM `pages`, and the
                       reason it is its own field rather than folded in: `pages`
                       says how much of the stream was walked, `settles` says
                       WHETHER THE TOOL WAITED FOR INGESTION. `0 entries, 1 page,
                       done=true` is the same string whether the reader gave the
                       provider ten seconds or asked once at T+0 and believed the
                       answer — and the second one is the defect this field
                       exists to expose.
                       An operator cannot act on a number the report does not
                       contain.

    ⛔ `fault` NEVER CARRIES A RESPONSE BODY — the `RunLogTail.fetch_error` rule,
    inherited deliberately. A 4xx body from an auth-adjacent API is exactly the
    body that carries material. Status, byte count, transport message. Never
    bytes the server chose."""

    var entries: List[CloudLogEntry]
    var status: Int
    var fault: String
    var next_token: String
    var pages: Int
    # ★★ HOW MANY BOUNDED WAITS PRODUCED THIS PAGE. See the field
    # docs above: a SECOND quantity, not a refinement of `pages`.
    var settles: Int

    @staticmethod
    def empty(status: Int) -> CloudLogPage:
        """A read that REACHED the provider and got nothing. ⛔ Distinct from a
        failure, and the distinction is the whole reason this is not modelled as
        "zero entries means broken": a validator container that crashed before
        printing one line produces exactly this, and telling the operator "the
        stream is empty" sends them to a different place than "I could not
        read"."""
        return CloudLogPage(
            List[CloudLogEntry](), status, String(""), String(""), 1, 0
        )

    @staticmethod
    def failed(status: Int, reason: String) -> CloudLogPage:
        """A read that did NOT produce an answer. `reason` is a status/transport/
        parse statement — ⛔ never a response body."""
        return CloudLogPage(
            List[CloudLogEntry](),
            status,
            reason.copy(),
            String(""),
            # ⚠ A REFUSAL THAT NEVER DIALLED READ ZERO PAGES; a 4xx DID reach the
            # provider and read one. `status == 0` is this module's own marker for
            # "the dial reached no verdict" (see the field docs), so it is the
            # honest discriminator and the renderer's "read N page(s)" stays true
            # on both shapes.
            1 if status > 0 else 0,
            # ⚠ A REFUSAL SPENT NO WAIT. The settle loop overwrites this with its
            # own running count when a fault ends a settle mid-flight; a page
            # constructed straight from a refusal never reached one.
            0,
        )

    def ok(self) -> Bool:
        """True iff the read produced an answer (whether or not it had entries)."""
        return self.fault.byte_length() == 0


# =============================================================================
# §2b — THE PAGING **POLICY**. Pure arithmetic, zero transport.
#
# ⛔ IT LIVES HERE AND NOT IN THE CONFORMER, FOR THE REASON THIS PACKAGE EXISTS.
# The split is: the LEAF owns the REQUEST, the conformer owns the ROUND TRIP,
# and nothing owns both — and a WALK is a sequence of requests, so the decision
# of whether to make another one is the leaf's. Left in the conformer it would
# sit behind a socket the whole test suite cannot reach, which is exactly how a
# bound becomes a comment.
#
# ⚠ IT IS ALSO CLOUD-NEUTRAL. A CloudWatch arm paging `nextToken` asks the same
# two questions; a second copy of this arithmetic beside it is a second thing to
# keep in agreement.
# =============================================================================
comptime DEFAULT_MAX_CONTAINER_LOG_PAGES: Int = 3
"""How many **PRODUCTIVE** provider reads ONE enrichment may perform — pages
that actually came back with entries in them.

⭐ "PRODUCTIVE" IS THE POINT. Counted over ALL pages, this bound would stop a
read that had walked three pages and returned ZERO rows: a bound whose job is to
cap OUTPUT VOLUME, stopping the one case that had produced no output. Pages that
return nothing are charged to `DEFAULT_MAX_EMPTY_CONTAINER_LOG_PAGES` instead,
which is a separate budget denominated in WALL rather than in rows.

── ⛔ THE PROBLEM THE WALK EXISTS FOR ───────────────────────────────────────
A conformer performing exactly ONE read, issued at T+0 the instant a step is
decided STEP_FAIL. Cloud logging ingests ASYNCHRONOUSLY — seconds to a minute
behind a container that has just died — and `entries:list` routinely answers with
FEWER entries than `pageSize` PLUS a continuation token. A single read would
present a short first page as the container's whole output.

── ⛔ AND THE PROBLEM THE **BOUND** EXISTS FOR, WHICH IS THE BIGGER ONE ────
An unbounded drain is an enrichment that can take longer than the failure it is
annotating, on a path a validation DAG walks once per red step — and the host
process it runs inside may be SIGKILLed on its own deadline, which runs no teardown
and leaves a live cloud service behind. Three is a generous ceiling on "a
validator printed more rows than one page holds"; whatever remains is REPORTED as
remaining rather than silently dropped.

⛔ PAGING IS NOT WAITING. Nothing here re-requests the SAME page: a repeat is a
POLL, and a poll inside a failure report costs wall time exactly where wall time
is a SIGKILL. The ingestion-lag caveat is stated by the RENDERER instead."""


def container_log_next_page_size(want: Int, accumulated: Int) -> Int:
    """How many entries the NEXT request should ask for.

    ⛔ `want` IS THE TOTAL, NOT A PER-PAGE SIZE. `CloudLogSource.read_container_
    output`'s contract is "read up to `limit` entries"; asking for `limit` on each
    of three pages would return up to three times the number the caller stated.
    Each round asks for the REMAINDER, so the aggregate honours it exactly.

    A non-positive `want` means the caller expressed no bound and takes the
    package default — the same normalisation every other reader of `limit`
    applies, stated once here."""
    var total = want if want > 0 else DEFAULT_CONTAINER_LOG_LIMIT
    var left = total - accumulated
    return left if left > 0 else 0


comptime CONTAINER_LOG_PAGE_ROUND_TRIP_MS: Int = 400
"""THE ASSUMED WALL COST OF **ONE** PROVIDER READ, and it is written down so the
bound below is DERIVED rather than picked.

⛔ IT IS AN ASSUMPTION, STATED SO IT CAN BE FALSIFIED. A `entries:list` against
Cloud Logging is a TLS dial plus a query — hundreds of milliseconds, not the 30s
this seam's client timeout allows for the pathological case. If that number is
wrong, the thing to change is THIS constant; the page bound then moves with it
and the wall budget it was derived from stays where it is. A reader who instead
bumps the page count directly has silently changed the budget."""


comptime CONTAINER_LOG_EMPTY_PAGE_BUDGET_MS: Int = 4_000
"""HOW MUCH WALL A WALK MAY SPEND ON PAGES THAT PRODUCED **NOTHING**.

FOUR SECONDS, and the comparator is not arbitrary: it is strictly less than ONE
`CONTAINER_LOG_SETTLE_S` (5s), the seam's already-accepted unit of added wall on
a red step. An empty-page sweep and a settle are alternative ways of spending
time to get the same rows, so the sweep must not cost more than the wait it
stands in for — and the whole enrichment's ceiling stays the one already argued
(`DEFAULT_MAX_CONTAINER_LOG_SETTLES x CONTAINER_LOG_SETTLE_S` = 10s of waiting,
plus at most this, plus the productive pages)."""


comptime DEFAULT_MAX_EMPTY_CONTAINER_LOG_PAGES: Int = (
    CONTAINER_LOG_EMPTY_PAGE_BUDGET_MS // CONTAINER_LOG_PAGE_ROUND_TRIP_MS
)
"""How many pages THAT RETURNED ZERO ENTRIES one walk may read. DERIVED (10).

── ⛔ THE PROBLEM THIS EXISTS FOR ───────────────────────────────────────────
Without it, a read of a failed execution's logs can report:

    NO CONTAINER OUTPUT read ... — 0 row(s) (3 page(s), 0 settle(s), done=false)

THREE PAGES WALKED, **ZERO ROWS RETURNED**, and a continuation token still
outstanding: `DEFAULT_MAX_CONTAINER_LOG_PAGES` fires — correctly by its own
arithmetic and against the one case it was never meant to stop. Cloud Logging's
`entries:list` returns pages with NO matching entries while it scans a wide
window under a narrow filter, so a walk can burn its whole budget on empty pages
and never reach the rows; it then reports `0 row(s)` AS THE ANSWER.

── ⭐ WHY A SECOND BOUND AND NOT A BIGGER FIRST ONE ──────────────────────────
`DEFAULT_MAX_CONTAINER_LOG_PAGES` bounds OUTPUT VOLUME — `max_pages x want`
entries a failure report may drag back. A page that returned zero entries has
produced no volume, so charging it against that bound is charging the wrong
meter. Raising the volume bound instead would multiply the cost of every HEALTHY
read to fix a case DEFINED by having produced no output, and would still not
close the class: a stream with enough leading empty pages beats any constant.

⛔ NEITHER DOES THIS ONE, AND THAT IS ACCEPTED ON PURPOSE. Any terminating walk
is a constant. What changes is WHICH reads pay it (only those that have achieved
nothing) and what the report says when it binds: the token survives, `done` stays
false, and `_next_action_sentence` tells the operator a RE-READ — not a wait —
is what fetches the rest. A bound that is SAID is not a silent truncation.

⛔ AND IT IS NOT A SETTLE. Nothing here re-requests a page already read; every
round trip carries the provider's own forward cursor. The settle
(`container_log_should_settle`) answers *will there be more in five seconds*;
this answers *is the row I am looking for on a later page RIGHT NOW*. Do not
"unify" them — `container_log_should_settle` declines precisely when a token is
outstanding, which is exactly when this budget is the thing that helps."""


def container_log_should_continue(
    pages_read: Int,
    empty_pages_read: Int,
    accumulated: Int,
    want: Int,
    next_token: String,
    sent_cursor: String,
    max_pages: Int = DEFAULT_MAX_CONTAINER_LOG_PAGES,
    max_empty_pages: Int = DEFAULT_MAX_EMPTY_CONTAINER_LOG_PAGES,
) -> Bool:
    """Should the walk issue ANOTHER request?

    THE FIVE WAYS IT SAYS NO, and every one of them is a fact the caller then
    REPORTS rather than assumes:

      * NO CONTINUATION TOKEN — the provider said the stream ENDS here. This is
        the only `False` that means the read is COMPLETE, and it is why
        `next_token` is folded into `done` rather than dropped.
      * THE CURSOR DID NOT ADVANCE — the provider handed back the SAME token it
        was given. ⛔ THE ANTI-LIVELOCK ARM, and it is what makes this predicate
        safe for a POSITION cursor as well as a page cursor: CloudWatch's
        `nextForwardToken` is ALWAYS present and REPEATS at the end of a stream
        (AWS's own contract is "repeat until the same token comes back twice"),
        so without this arm an AWS walk would spend its entire empty-page budget
        proving a stream had ended. `fetch_run_log_tail` carries the
        identical arm for the identical reason.
      * THE EMPTY-PAGE BUDGET IS SPENT — `max_empty_pages` pages have come back
        with nothing in them. ⭐ See `DEFAULT_MAX_EMPTY_CONTAINER_LOG_PAGES`.
      * THE OUTPUT-VOLUME BOUND IS REACHED — `max_pages` pages THAT ACTUALLY
        PRODUCED ENTRIES. ⭐ `pages_read - empty_pages_read`, NOT `pages_read`:
        this bound exists to cap how much a failure report drags back, and a page
        that returned nothing dragged back nothing. Charging it here would
        stop a zero-row read at three pages.
      * THE CALLER'S `want` IS SATISFIED — stop, but the token is KEPT, so the
        tail renders `done=false` and the reader knows the stream did not end
        where the read did.

    ⛔ AN EMPTY PAGE WITH AN ADVANCING TOKEN IS A `True`, AND THAT IS THE WHOLE
    POINT. Cloud Logging returns exactly that while it is still scanning, and a
    reader that stopped on "zero entries" would reproduce the single-read defect
    with extra steps.

    ⛔ THE RUNNING COUNTS ARE REQUIRED PARAMETERS, NOT DEFAULTED ONES. A budget
    whose running total defaults to zero is a budget the compiler cannot make a
    caller state — it reads as wired while being structurally unreachable.
    The ceilings carry defaults; the facts
    do not.

    ⚠ TERMINATION: every walk stops within `max_pages + max_empty_pages`
    requests, whatever the provider does — a page either produces entries (and is
    charged to the volume bound) or does not (and is charged to the empty bound),
    and a provider that stalls its cursor is cut at the second arm."""
    if next_token.byte_length() == 0:
        return False
    if next_token == sent_cursor:
        return False
    if empty_pages_read >= max_empty_pages:
        return False
    if pages_read - empty_pages_read >= max_pages:
        return False
    return container_log_next_page_size(want, accumulated) > 0


# =============================================================================
# ★★ §2b-2 — THE WALK **LOOP** ITSELF, GENERIC, SO IT IS ONE IMPLEMENTATION AND
#   A TEST CAN DRIVE EVERY BRANCH OF IT WITH NO SOCKET.
#
# ── ⛔ WHY IT LIVES HERE ─────────────────────────────────────────────────────
# The POLICY (`container_log_should_continue`) lives in this leaf and is fully
# tested. If the LOOP THAT CALLS IT were written out once per conformer, BEHIND
# A SOCKET, the arguments, the bookkeeping and which result is kept would be
# tested by nothing — the shape this file's own settle-loop header names: *"a
# bound that is really a comment"*. A zero-row read like
# `0 row(s) (3 page(s), 0 settle(s), done=false)` is decided ENTIRELY by the
# four arguments this loop passes, so those arguments must be testable.
#
# ⛔ ONE LOOP, NOT TWO. `read_container_output_settled`'s header states the
# same rule (*"two copies in two conformers is how bounds drift apart"*). The
# conformer keeps the ONE thing that genuinely
# needs a socket: a single round trip.
# =============================================================================
trait ContainerLogPager:
    """ONE round trip against the provider's log API, at a cursor.

    THE ONE HALF OF A WALK A LEAF CANNOT OWN. Everything else about paging — how
    many entries to ask for, whether to ask again, what the accumulated result is
    — is arithmetic, and arithmetic behind a socket is a comment."""

    def fetch_page(
        mut self, handle: String, page_size: Int, cursor: String, session: String
    ) raises -> CloudLogPage:
        """ONE read of `handle`'s stream at `cursor`, asking for `page_size`.

        `cursor` is EMPTY on the first request and is otherwise the provider's
        OWN opaque token from the previous page — ⛔ never a value any layer
        above invented. `session` is whatever one request needs to authenticate,
        minted ONCE by the caller for the whole walk (a credential is a
        parameter, never a field); EMPTY where the conformer signs per request.

        ⛔ IT SHOULD NOT RAISE FOR AN ORDINARY FAULT — a dial failure, a 4xx or
        an unparseable body is `CloudLogPage.failed(...)`, because the walk has
        to decide whether to keep what it already has and a raise would discard
        it."""
        ...


def walk_container_log_pages[
    P: ContainerLogPager,
](
    mut pager: P,
    handle: String,
    want: Int,
    session: String,
    max_pages: Int = DEFAULT_MAX_CONTAINER_LOG_PAGES,
    max_empty_pages: Int = DEFAULT_MAX_EMPTY_CONTAINER_LOG_PAGES,
) raises -> CloudLogPage:
    """ONE bounded walk of `handle`'s stream from the BEGINNING, following the
    provider's own continuation cursor, up to `want` entries in total.

    ── THE FIVE WAYS IT STOPS, and each is REPORTED rather than assumed ───────
      * the provider returned NO cursor      -> the stream ENDED. `done`.
      * the cursor did not ADVANCE           -> same position twice; the
                                                anti-livelock arm. Bounded, SAID.
      * the EMPTY-PAGE budget is spent       -> bounded, SAID.
      * the OUTPUT-VOLUME bound is reached   -> bounded, SAID.
      * a page FAULTED                       -> ⛔ RETURN WHAT WAS READ SO FAR
                                                plus the fault. The renderer's
                                                partial-read arm prints both;
                                                throwing away two good pages
                                                because the third 403'd would
                                                discard the half that usually
                                                explains the failure.

    ⛔ THE SURVIVING CURSOR IS KEPT ON EVERY BOUNDED STOP. `done` is derived from
    it, so a walk that stopped on its own bound renders `done=false` and the
    reader learns the stream did not end where the read did. Dropping it would
    make a truncated read indistinguishable from a complete one.

    ⚠ `settles = 0` HERE IS NOT A CLAIM, IT IS THE ABSENCE OF ONE. This is ONE
    WALK; the settle count belongs to `read_container_output_settled`, which owns
    that loop and overwrites this field."""
    var acc = List[CloudLogEntry]()
    var cursor = String("")
    var pages = 0
    var empty_pages = 0
    while True:
        # ⚠ THE CURSOR WE SENT IS CAPTURED BEFORE THE REQUEST, because the
        # anti-livelock arm compares it against the one that comes BACK. Reading
        # `cursor` after the assignment below would compare a value with itself.
        var sent = cursor.copy()
        var page = pager.fetch_page(
            handle,
            container_log_next_page_size(want, len(acc)),
            sent,
            session,
        )
        pages += 1
        if not page.ok():
            # ⛔ PARTIAL IS REPORTED AS PARTIAL, and the entries obtained before
            # the fault are KEPT.
            return CloudLogPage(
                acc^, page.status, page.fault.copy(), String(""), pages, 0
            )
        if len(page.entries) == 0:
            # ⭐ THE COUNT THE EMPTY-PAGE BUDGET TURNS ON. A page that
            # produced nothing is charged to the EMPTY budget and NOT to the
            # output-volume bound — see `DEFAULT_MAX_EMPTY_CONTAINER_LOG_PAGES`.
            empty_pages += 1
        for i in range(len(page.entries)):
            acc.append(page.entries[i].copy())
        cursor = page.next_token.copy()
        if not container_log_should_continue(
            pages,
            empty_pages,
            len(acc),
            want,
            cursor,
            sent,
            max_pages,
            max_empty_pages,
        ):
            break
    return CloudLogPage(acc^, 200, String(""), cursor^, pages, 0)


# =============================================================================
# ★★ §2b — THE SETTLE. PAGING WAS NOT WAITING, AND WAITING IS WHAT WAS MISSING.
#
# ── ⛔ THE PROBLEM ─────────────────────────────────────────────────────────
# The walk above can work perfectly and still return ONE LINE for a failed
# validate step: the validator printed many rows, the provider has ingested one
# of them, the walk follows every continuation token the provider offers, the
# provider offers none, and the read ends at T+0 plus a few hundred milliseconds
# with almost nothing in it.
#
# ⇒ PAGING ANSWERS "IS THERE MORE **NOW**". It cannot answer "will there be more
#   in five seconds", and for a container that died a moment ago that is the
#   question. `DEFAULT_MAX_CONTAINER_LOG_PAGES`'s own header says "PAGING IS NOT
#   WAITING … a repeat is a POLL"; that is a correct statement of what the walk
#   is, not an argument that no waiting should exist anywhere.
#   The bound belongs on the WAIT, not on the idea of waiting.
#
# ── ⛔ THE COST, STATED, BECAUSE IT IS REAL ─────────────────────────────────
# Every second of settle is a second added to an ALREADY-FAILING wave, and the
# host process this runs inside may be SIGKILLed on its own deadline —
# which runs no teardown and leaves live cloud resources behind. So:
#
#   * ZERO on a green step. The settle lives inside `read_container_output`,
#     which is only reached from `failure_run_log_tail`, which the DAG calls on
#     `STEP_FAIL` only. That cost guard is structural.
#   * ZERO on a read that already returned a credible amount of output — the
#     overwhelmingly common red-step case once ingestion has caught up.
#   * ZERO when the walk stopped on its OWN bound (a continuation token is
#     outstanding): there is demonstrably more where that came from, and waiting
#     buys nothing the page bound did not already decline to spend.
#   * ZERO after a settle that did not GROW the result. If five seconds produced
#     no new entry, the stream is empty because it is empty.
#
# The worst case is therefore `DEFAULT_MAX_CONTAINER_LOG_SETTLES x
# CONTAINER_LOG_SETTLE_S` = 10 seconds, paid only on a red step whose evidence
# would otherwise have been one line, and the tail it cannot buy is REPORTED
# (the renderer's ingestion-lag sentence) rather than waited out. ⛔ DO NOT RAISE
# THESE TO COVER THE MINUTE-LONG TAIL: a DAG with several red steps would
# then spend minutes waiting to annotate failures the operator is already
# reading.
# =============================================================================
comptime CONTAINER_LOG_SETTLE_S: Int = 5
"""How long ONE settle waits before re-reading.

FIVE, and the number is argued from BOTH directions. Cloud Logging's
write-to-queryable lag for a just-terminated Cloud Run container is SECONDS; a
sub-second sleep would re-ask the same too-early question and pay the round trips
for nothing, which is the single-read defect with extra steps. Thirty would be
half a minute of added wall on every red step in a DAG. Five clears the common
case and two of them is a rounding error against the wall of a failing deploy."""


comptime DEFAULT_MAX_CONTAINER_LOG_SETTLES: Int = 2
"""How many settles ONE enrichment may spend. TWO ⇒ a 10-second ceiling.

⛔ THE CEILING IS THE POINT, not the count. An enrichment that can take longer
than the failure it annotates is its own incident, and this one runs inside a
process that gets SIGKILLed on a deadline."""


def container_log_should_settle(
    accumulated: Int,
    next_token: String,
    settles_done: Int,
    grew_since_last: Bool,
    max_settles: Int = DEFAULT_MAX_CONTAINER_LOG_SETTLES,
) -> Bool:
    """Should the reader WAIT and read the whole stream again?

    THE FOUR WAYS IT SAYS NO, in the order they are cheapest to decide:

      * THE SETTLE BUDGET IS SPENT — the ceiling, and it is unconditional.
      * A CONTINUATION TOKEN IS OUTSTANDING — the walk stopped on its OWN bound,
        not on an empty stream. There is more RIGHT NOW; waiting for more to
        arrive is answering a question nobody asked.
      * THE READ IS ALREADY CREDIBLE (`>= CONTAINER_LOG_CREDIBLE_FLOOR`) — the
        enrichment has what it came for. ⛔ This is the branch that keeps the
        common red step at ZERO added seconds.
      * THE LAST SETTLE BOUGHT NOTHING — five seconds produced no new entry, so
        the next five will not either. An empty stream is an ANSWER.

    ⚠ `grew_since_last` IS IGNORED ON THE FIRST DECISION (`settles_done == 0`)
    because there is no previous read to have grown from. Consulting it there
    would make the first settle depend on an uninitialised fact — and, with the
    obvious `False` seed, would disable the settle entirely."""
    if settles_done >= max_settles:
        return False
    if next_token.byte_length() > 0:
        return False
    if accumulated >= CONTAINER_LOG_CREDIBLE_FLOOR:
        return False
    if settles_done > 0 and not grew_since_last:
        return False
    return True


# =============================================================================
# ★★ §2c — THE SETTLE **LOOP** ITSELF, GENERIC, SO IT IS ONE IMPLEMENTATION AND
#   A TEST CAN DRIVE EVERY BRANCH OF IT WITH NO CLOCK AND NO SOCKET.
#
# ⛔ WHY IT IS NOT WRITTEN TWICE IN THE CONFORMERS. There are two conformers and
# the loop is ~20 lines; two copies in two conformers is how bounds drift
# apart. More decisively:
# a copy inside a conformer sits BEHIND A SOCKET. The policy predicate would be
# fully tested and the WIRING that calls it — the arguments, the bookkeeping,
# which result is kept — would be tested by nothing, which is the exact shape of
# a bound that is really a comment.
#
# The conformer keeps the only two things that genuinely need a socket and a
# clock: ONE walk, and the wait.
# =============================================================================
trait ContainerLogWalker:
    """ONE bounded walk of a container's log stream, plus the wait between
    walks. The two halves of a settle that a leaf cannot own."""

    def walk_once(
        mut self, handle: String, want: Int, session: String
    ) raises -> CloudLogPage:
        """ONE walk from the BEGINNING of the stream, up to `want` entries.

        ⛔ FROM THE BEGINNING, NEVER RESUMED. A settle happens because the
        provider said the stream ENDED — so there is no continuation token to
        resume from, and entries ingested during the wait are interleaved into
        the stream by TIMESTAMP rather than appended after the last one read.
        Resuming would silently drop everything that arrived out of order.

        `session` is whatever ONE walk needs to authenticate, minted ONCE by the
        caller for the whole settle. ⛔ IT IS A PARAMETER AND MUST NEVER BECOME A
        FIELD, which is why the GCP arm mints in-frame: a stored token can
        outlive its expiry on a long run and fail late on an opaque auth error.
        This library does not inspect it, log
        it, or store it; it forwards it and nothing else. Empty where the
        conformer signs each request itself (the SigV4 arm)."""
        ...

    def settle_wait(mut self, seconds: Int):
        """Wait `seconds` before the next walk. ⛔ The ONLY thing in the settle
        that names a clock — which is what lets the test double count the waits
        instead of taking them."""
        ...


def read_container_output_settled[
    W: ContainerLogWalker,
](
    mut walker: W,
    handle: String,
    limit: Int,
    session: String = String(""),
    max_settles: Int = DEFAULT_MAX_CONTAINER_LOG_SETTLES,
) raises -> CloudLogPage:
    """`handle`'s container output, over AT MOST `max_settles` bounded waits.

    ── THE THREE RULES, and each one has a failure mode that is not obvious ───
      * ⛔ A FAULT ENDS IT IMMEDIATELY AND KEEPS THE BEST READ SO FAR. Settling
        on a 403 or an unparseable handle makes the report LATE without making it
        better; and an earlier settle round's entries must survive the fault, or
        a third-page 403 would trade a diagnosable partial read for an
        undiagnosable empty one.
      * ⛔ IT NEVER REGRESSES THE EVIDENCE. A re-read is a fresh query, not a
        continuation, so it CAN come back with fewer entries (a provider hiccup,
        a retention edge). Whichever read saw more is the one returned.
      * ⛔ `pages` ACCUMULATES ACROSS SETTLES. The field means "how many provider
        reads this cost", and a settle round is literally more provider reads —
        so `(7 page(s), done=true)` is a true statement about the cost. What it
        does not distinguish is reads-within-a-walk from reads-across-settles;
        that is the one thing given up, and it does not justify a new field on a
        POD every producer in the tree constructs.

    ⚠ `want` IS NORMALISED ONCE, HERE, so both conformers agree on what a
    non-positive `limit` means without either of them saying so."""
    var want = limit if limit > 0 else DEFAULT_CONTAINER_LOG_LIMIT
    var best = List[CloudLogEntry]()
    var best_token = String("")
    var pages = 0
    var settles = 0
    var grew = False
    while True:
        var got = walker.walk_once(handle, want, session)
        pages += got.pages
        if not got.ok():
            var keep = got.entries.copy() if len(got.entries) >= len(
                best
            ) else best.copy()
            return CloudLogPage(
                keep^, got.status, got.fault.copy(), String(""), pages, settles
            )
        grew = len(got.entries) > len(best)
        if len(got.entries) >= len(best):
            best = got.entries.copy()
            best_token = got.next_token.copy()
        if not container_log_should_settle(
            len(best), best_token, settles, grew, max_settles
        ):
            break
        settles += 1
        walker.settle_wait(CONTAINER_LOG_SETTLE_S)
    # ★★ `settles` RIDES OUT WITH THE PAGE. ⛔ IT IS COUNTED HERE
    # AND NOWHERE ELSE, for the same reason the loop itself is here: a conformer
    # keeping its own count would be a second piece of bookkeeping behind a
    # socket, and the renderer that prints it would be asserting a number nothing
    # tests. The FAULT return above carries it too — a settle that was spent and
    # then hit a 403 still cost the wall it cost, and a report that dropped it
    # would understate what the enrichment took.
    return CloudLogPage(best^, 200, String(""), best_token^, pages, settles)


# =============================================================================
# §3 — CloudLogSource — THE SEAM.
# =============================================================================
trait CloudLogSource(Movable, Deinitable):
    """Read the CONTAINER OUTPUT of ONE terminated run-to-completion unit,
    addressed by that cloud's OWN handle for it.

    ⛔ ONE VERB, AND `handle` IS DELIBERATELY THE PROVIDER'S OWN STRING. The
    alternative — a normalised `{project, region, kind, id}` POD — would put a
    LOSSY re-encoding between the party that HAS the handle (the pod manager
    recorded it off the wire) and the party that must address the provider with
    it. Every arm's handle is already self-addressing:

      * GCP  — a Cloud Run execution resource name,
               `projects/<p>/locations/<r>/jobs/<j>/executions/<e>`. The project
               and the leaf id are IN it, which is why
               `cloud_run_execution_log_filter` needs nothing else.
      * AWS  — an ECS task ARN,
               `arn:aws:ecs:<region>:<acct>:task/<cluster>/<taskId>`. The region,
               the account and the task id are IN it, which is why
               `ecs_task_log_stream` needs only it and the awslogs prefix.

    A conformer that cannot parse the handle it was given must return
    `CloudLogPage.failed(...)` SAYING SO — it must NOT guess, because a log query
    that silently reads the wrong project returns SOMEONE ELSE'S lines and the
    operator reads them as this execution's. That is the identical refusal
    the printed `gcloud` fallback command makes by being empty rather than
    project-less.

    ⛔ IT MAY RAISE ONLY ON A PROGRAMMING FAULT. A dial failure, a 4xx, a body
    that does not parse — those are `CloudLogPage.failed(...)`, because the
    caller is already reporting something more important. `CloudRunJobValidator.
    failure_run_log_tail` nets a raise anyway (the DAG nets it a second time),
    but a conformer that raises on an ordinary transport fault has converted an
    enrichment into a second failure report.

    Conformers: `LiveCloudRunExecutionLogs` (GCP, in `komira_gcp_bridge` where
    the TLS transport already lives), `ScriptedCloudLogSource` (the hermetic
    double, below), `NoCloudLogSource` (the not-configured default)."""

    def read_container_output(
        mut self, handle: String, limit: Int
    ) raises -> CloudLogPage:
        """Read up to `limit` entries of `handle`'s container output, oldest
        first. Returns a `CloudLogPage`; see the trait docstring for what may and
        may not raise."""
        ...


# =============================================================================
# §4 — NoCloudLogSource — the NOT-CONFIGURED default.
# =============================================================================
struct NoCloudLogSource(CloudLogSource, Copyable, Movable, Deinitable):
    """The default binding of every `CloudLogSource` type parameter in the tree.

    ⛔ IT REFUSES, IT DOES NOT RETURN AN EMPTY PAGE, and the difference is the
    whole reason this type is not `CloudLogPage.empty()`. An empty page means
    *the stream had nothing in it* — a real, actionable answer about a container
    that crashed before printing. "Nobody wired a log source into this binary" is
    a DIFFERENT fact with a different next action, and collapsing the two is how
    a missing wiring gets diagnosed for weeks as a quiet validator.

    ⚠ In practice a caller holding this never calls it: `CloudRunJobValidator`
    keeps `Optional[L]` and returns `None` from `failure_run_log_tail` when it is
    empty, so the report simply carries no container-output section. This
    refusal is the net under a caller that does call it."""

    var _placeholder: UInt8

    def __init__(out self):
        self._placeholder = UInt8(0)

    def read_container_output(
        mut self, handle: String, limit: Int
    ) raises -> CloudLogPage:
        return CloudLogPage.failed(
            0,
            String(
                "no cloud log source is configured in this binary — the handle"
                " was recorded but nothing here can read it"
            ),
        )


# =============================================================================
# §5 — ScriptedCloudLogSource — the hermetic double.
# =============================================================================
struct _ScriptedLogState(Movable):
    """The double's interior: the per-handle script + the LOG OF EVERY READ.
    Flat `List[String]` / `List[CloudLogPage]`, no byte-slab, no
    wildcard origin, no UnsafePointer."""

    var handles: List[String]
    var pages: List[CloudLogPage]
    var calls: List[String]

    def __init__(out self):
        self.handles = List[String]()
        self.pages = List[CloudLogPage]()
        self.calls = List[String]()


struct ScriptedCloudLogSource(CloudLogSource, Movable, Deinitable):
    """An in-process `CloudLogSource` that answers from a script and RECORDS every
    read.

    IT LIVES IN THE LIBRARY, NOT IN A TEST FILE — the same convention as the
    other cloud API mocks (`MockCloudRunJobsApi` / `MockSecretGetApi`).
    `CloudRunJobValidator` is generic over its log
    source, so the double has to be nameable by any test in any package that
    builds one, and a double reachable from only one file gets re-derived in the
    next.

    ⛔ BEHIND AN `ArcPointer` SO `share()` READS THE AGGREGATE **AFTER** THE
    DOUBLE HAS BEEN MOVED INTO THE SUBJECT, and that is not a convenience. The
    validator takes its log source BY VALUE (`var logs: Self.L`), so a test that
    handed over its only handle could no longer ask "was it actually consulted?"
    — and an implementation that fabricated a plausible tail WITHOUT consulting
    the source would pass every content assertion. `call_count()` on a second
    handle is the anti-vacuity check, and it needs shared state to exist.

    ⚠ This is the sanctioned `ArcPointer` case and no more: TRUE shared
    ownership, ONE thread, a test double.

    THE SCRIPT IS PER-HANDLE, so one instance can serve a whole DAG and a test
    can prove the rows attached to a failing step are THAT step's rows and not a
    neighbour's. A handle with no script gets `CloudLogPage.empty()` — a
    reached-the-provider-and-got-nothing answer, which is exactly what a real
    provider returns for an execution that printed nothing."""

    var _p: ArcPointer[_ScriptedLogState]

    def __init__(out self):
        self._p = ArcPointer[_ScriptedLogState](_ScriptedLogState())

    def __init__(out self, *, var _share: ArcPointer[_ScriptedLogState]):
        self._p = _share^

    def share(self) -> ScriptedCloudLogSource:
        """A SECOND handle over ONE `_ScriptedLogState`. SAFETY: ArcPointer
        ref-counted shared ownership; a TEST DOUBLE on ONE thread."""
        return ScriptedCloudLogSource(
            _share=ArcPointer[_ScriptedLogState](copy=self._p)
        )

    def script_text(mut self, handle: String, lines: List[String]):
        """Script `handle`'s stream as plain container stdout — one entry per
        element of `lines`, oldest first, with no severity (the shape a container
        writing to stdout actually produces)."""
        var page = CloudLogPage.empty(200)
        for i in range(len(lines)):
            page.entries.append(
                CloudLogEntry(String(""), String(""), lines[i].copy())
            )
        self._p[].handles.append(handle.copy())
        self._p[].pages.append(page^)

    def script_page(mut self, handle: String, var page: CloudLogPage):
        """Script `handle`'s stream as an arbitrary page — INCLUDING a FAILED
        one, which is how a test proves the enrichment reports a fault in one
        line instead of changing the step's verdict."""
        self._p[].handles.append(handle.copy())
        self._p[].pages.append(page^)

    def read_container_output(
        mut self, handle: String, limit: Int
    ) raises -> CloudLogPage:
        self._p[].calls.append(handle.copy())
        for i in range(len(self._p[].handles)):
            if self._p[].handles[i] == handle:
                var p = self._p[].pages[i].copy()
                # ★ THE LIMIT IS HONOURED BY THE DOUBLE, keeping the LAST
                # `limit` entries. A double that ignores a bound its live peer
                # enforces lets a test pass over an unbounded read.
                if limit > 0 and len(p.entries) > limit:
                    var kept = List[CloudLogEntry]()
                    for k in range(len(p.entries) - limit, len(p.entries)):
                        kept.append(p.entries[k].copy())
                    p.entries = kept^
                return p^
        return CloudLogPage.empty(200)

    def call_count(self) -> Int:
        """How many reads this double served — the anti-vacuity check for a test
        asserting that a failing step ASKED for its output."""
        return len(self._p[].calls)

    def last_handle(self) -> String:
        """The handle of the most recent read, or EMPTY. Lets a test prove the
        step addressed its OWN execution rather than a plausible string."""
        var n = len(self._p[].calls)
        if n == 0:
            return String("")
        return self._p[].calls[n - 1].copy()


# =============================================================================
# §6 — the ADAPTER onto `RunLogTail` — why this seam needs no new renderer.
# =============================================================================
def cloud_log_page_to_run_log_tail(
    page: CloudLogPage, handle: String
) -> RunLogTail:
    """Turn ONE `CloudLogPage` into the `RunLogTail` `render_run_log_tail`
    already prints, so a cloud container stream reaches the operator through the
    EXACT path a pipeline run stream does — same bound, same redaction, same
    three states (COULD NOT READ / NO RECORDS / records).

    ⛔ AN ADAPTER, NOT A SECOND RENDERER, AND THAT IS THE POINT. The obvious
    alternative — a `render_cloud_log_page` next to the existing one — produces
    two bounded redacting printers that must be kept in agreement by hand, and
    the one that is not on the hot path is the one that drifts. `RunLogTail` is
    already the currency of `DagValidator.failure_run_log_tail`; a conformer that
    speaks it needs no change anywhere above.

    THE FIELD MAPPING, and the one place it is a deliberate stretch:
      * `run_id`  <- `handle`. The renderer's header becomes "run-log for run
                     projects/.../executions/example-e2e-abc12", which is the
                     string the operator needs to go read it in the console.
      * `seq`     <- the 1-based ORDINAL in the page. Cloud Logging has no
                     integer cursor; the ordinal is what makes the rendered
                     `[n]` prefix mean "the nth line of what I read", which is
                     true and useful. ⛔ It is NOT a provider cursor and must not
                     be fed back as one.
      * `level`   <- `severity`.
      * `step`    <- ⚠ `timestamp`. A container stream has no PIPELINE STAGE, so
                     the field that renders in that slot would otherwise print
                     `-` on every line. The timestamp is the most useful thing a
                     reader can have there — it is how a row is correlated with
                     the deploy's own timeline — so it goes there, AND IT IS
                     SAID OUT LOUD HERE because the field's NAME says otherwise.
                     A future reader tempted to "fix" this should change the
                     RENDERER's column, not this mapping, and should know that
                     `step` is allow-listed for exactly one emitter's vocabulary.
      * `ts`      <- 0. The provider's time is a STRING here, kept verbatim (see
                     `CloudLogEntry.timestamp`); inventing a micros integer from
                     it would be a normalisation this package refuses to make.
      * `pages`   <- `CloudLogPage.pages`, the conformer's OWN count of provider
                     reads. ⛔ NOT a constant 1: the GCP conformer
                     follows `next_token` up to a bound, so the renderer's "read
                     N page(s)" has to come from the party that did the reading.
      * `stream_kind` <- `RUN_LOG_STREAM_CONTAINER_STDOUT`, ALWAYS. This is a
                     container's stdout and never a pipeline stage stream, and
                     saying so is what stops the renderer's empty branch from
                     reporting a missing "stage record" writer that does not
                     exist here.
      * `done`    <- True iff the provider handed back no continuation token.
                     ⛔ Not "true always": a page that stopped at the fetch bound
                     with the stream still going must not render as complete.

    ⛔ A FAULT BECOMES `fetch_error`, WHICH THE RENDERER STATES AND WHICH CHANGES
    NO VERDICT — including when entries were obtained AND the read then failed
    (the renderer's partial-read arm prints both). Pure: no transport, no raise."""
    var tail = RunLogTail.empty()
    tail.run_id = handle.copy()
    # ★★ THE STREAM KIND — THE HALF THAT STOPS THE RENDERER FROM
    # INVENTING A VOCABULARY. Without it, an empty container read would print
    # "NO STAGE RECORDS ... Nothing wrote a stage record for this run" over a
    # Cloud Run container's stdout: a finding-shaped non-finding naming a writer
    # that does not exist for this stream. The vocabulary belongs to the SOURCE
    # and this is where the source is known.
    tail.stream_kind = RUN_LOG_STREAM_CONTAINER_STDOUT
    # ⚠ THE CONFORMER'S OWN COUNT, NOT A CONSTANT: the seam follows
    # `next_token`, so a literal `1` would be false for a multi-page read.
    tail.pages = page.pages
    # ★★ AND THE WAITS — the half of "what did this read cost" that
    # `pages` cannot carry. Without it a report cannot distinguish a read that
    # gave the provider its full 10s ingestion window from one that asked once at
    # T+0; `render_run_log_tail` prints it for this stream kind only.
    tail.settles = page.settles
    for i in range(len(page.entries)):
        var e = page.entries[i].copy()
        tail.records.append(
            RunLogRecord(
                i + 1,
                0,
                e.severity.copy(),
                e.timestamp.copy(),
                e.text.copy(),
            )
        )
    tail.done = page.ok() and page.next_token.byte_length() == 0
    if not page.ok():
        tail.fetch_error = page.fault.copy()
    return tail^
