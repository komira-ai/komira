# =============================================================================
# komira_ci_logs/run_log_reader.mojo — THE VERB: read a run's stage logs, with
#   `?after=&limit=` PAGING, over a transport SEAM.
# =============================================================================
#
# A failing validate step should return the relevant logs. This is the half
# that reads them. `run_log_tail.mojo` is the half that
# parses and prints them; `run_log_path.mojo` composes the URL. Nothing here
# names a socket — the transport is a trait, so the whole paging loop, the
# bounding, and every failure branch are provable without one.
#
# ── ⛔ THE CONTRACT THAT MATTERS MOST: THIS FUNCTION DOES NOT RAISE ───────────
# `fetch_run_log_tail` is an ENRICHMENT. Its caller is, by construction, already
# reporting a failure — a red validate step, a run that reached a terminal-bad
# state. If reading the logs could turn that into a DIFFERENT failure, or mask
# it, the enrichment would have destroyed the signal it was added to explain.
# So every fault a transport can produce — a raise, a 4xx, a 5xx, a body that
# does not parse — becomes a `RunLogTail` carrying `fetch_error`, and the caller
# prints ONE line and keeps its own verdict.
#
# ── PAGING, AND WHY IT TERMINATES ────────────────────────────────────────────
# The route is a CURSOR TAIL: `?after=<seq>` returns only lines with `seq >
# after`. The loop advances `after` to the page's `next_cursor` and stops on the
# FIRST of four conditions, three of which are properties of the data and one of
# which is a hard cap:
#   * the page returned ZERO records (nothing new — the ordinary end),
#   * the route said `done` (terminal run, stream flushed),
#   * `next_cursor` did not ADVANCE (a server that keeps answering with the same
#     cursor would otherwise spin forever; this is the anti-livelock arm and it
#     is the reason the loop cannot hang on a misbehaving peer),
#   * `max_pages` is reached — reported in `pages`, so a truncated drain is
#     visible rather than silent.
#
# ── ENCAPSULATION ────────────────────────────────────────────────────────────
# Value-typed surface: a `mut T: RunLogTransport` in, a `RunLogTail` out. ZERO
# UnsafePointer, no wildcard origin, no FFI. def-based, Mojo 1.0.0b2.
# =============================================================================

from komira_ci_logs.run_log_path import (
    DEFAULT_RUN_PATH_PREFIX,
    DEFAULT_RUN_LOG_PAGE_LIMIT,
    build_run_logs_path,
    build_run_logs_query,
    build_run_logs_url,
)
from komira_ci_logs.run_log_tail import (
    RunLogRecord,
    RunLogTail,
    parse_run_logs_body,
)


# =============================================================================
# §1 — RunLogResponse — one round trip's `{status, body}`. Flat value POD.
# =============================================================================
@fieldwise_init
struct RunLogResponse(Copyable, Movable, Deinitable):
    """The `{status, body}` of ONE GET.

    ⚠ THE `body` CROSSES THE SEAM AND IS NEVER PRINTED BY ANYTHING DOWNSTREAM.
    It is handed to `parse_run_logs_body`, which reads the allow-listed fields
    and reports byte counts on failure. No branch in this library renders it."""

    var status: Int
    var body: String

    @staticmethod
    def of(status: Int, body: String) -> RunLogResponse:
        return RunLogResponse(status, body.copy())


# =============================================================================
# §2 — RunLogTransport — the seam.
# =============================================================================
trait RunLogTransport(Movable, Deinitable):
    """ONE authenticated GET against a fully composed run-log URL.

    A conformer owns the dial, the TLS and the bearer — this library owns the
    URL, the paging and the bounding, and neither knows the other's business.
    Conformers: the deploy tool's live HTTPS client; a scripted double in the
    hermetic tests.

    It MAY raise: a dial fault is a normal thing for a transport to report.
    `fetch_run_log_tail` catches it — see that function's contract."""

    def get(mut self, url: String) raises -> RunLogResponse:
        """GET `url`, returning its status + body. May raise on a dial fault."""
        ...


# =============================================================================
# §3 — fetch_run_log_tail — THE VERB.
# =============================================================================
comptime DEFAULT_MAX_PAGES: Int = 25
"""How many pages one call will read before it stops and SAYS it stopped. At the
default page limit that is 5000 records — far past what any bounded render will
print, and still a finite number of round trips against a peer that is answering
oddly."""


def fetch_run_log_tail[
    T: RunLogTransport
](
    mut transport: T,
    base_url: String,
    run_id: String,
    run_path_prefix: String = DEFAULT_RUN_PATH_PREFIX,
    after: Int = 0,
    page_limit: Int = DEFAULT_RUN_LOG_PAGE_LIMIT,
    keep_last: Int = 0,
    max_pages: Int = DEFAULT_MAX_PAGES,
) -> RunLogTail:
    """Read a run's stage-log stream from `after` forward, following the cursor,
    and return the tail. ⛔ NEVER RAISES — see the module header.

      * `keep_last > 0` retains only the LAST `keep_last` records, counting what
        it dropped into `dropped_older` so the renderer can say so. This is the
        MEMORY bound, distinct from the render bound: a 5000-record drain should
        not be held in full to print 40 of it.
      * `run_id` is carried into the tail even when the body names none, so a
        failure line can still say which run it was about.

    An EMPTY stream is a SUCCESS (`RunLogTail.empty()` with `pages` set) — the
    ordinary state of a run for which nothing has written a stage record. The
    caller must be able to tell "there is nothing to read" from "I could not
    read", which is why those are different values and not both zero records."""
    var tail = RunLogTail.empty()
    tail.run_id = run_id.copy()
    var cursor = after if after > 0 else 0
    var pages = 0
    var cap_pages = max_pages if max_pages > 0 else 1
    while pages < cap_pages:
        var url = build_run_logs_url(
            base_url, run_path_prefix, run_id, cursor, page_limit
        )
        var resp = RunLogResponse.of(0, String(""))
        try:
            resp = transport.get(url)
        except e:
            # ⛔ A TRANSPORT FAULT IS AN ENRICHMENT FAULT. It is recorded on the
            # tail and returned; it is never re-raised, because the caller is
            # already reporting something more important than this.
            tail.pages = pages
            tail.fetch_error = (
                String("transport fault on page ")
                + String(pages + 1)
                + String(" of ")
                + build_run_logs_path(run_path_prefix, run_id)
                + build_run_logs_query(cursor, page_limit)
                + String(": ")
                + String(e)
            )
            return tail^
        pages += 1
        if resp.status != 200:
            # ⛔ THE BODY IS NOT ECHOED — the status and the path are the whole
            # report. A 4xx here is very often an AUTH answer, and auth answers
            # are exactly the bodies that carry material.
            tail.pages = pages
            tail.fetch_error = (
                String("HTTP ")
                + String(resp.status)
                + String(" from ")
                + build_run_logs_path(run_path_prefix, run_id)
                + build_run_logs_query(cursor, page_limit)
                + String(" (")
                + String(len(resp.body.as_bytes()))
                + String("-byte body NOT echoed)")
            )
            return tail^
        var page = parse_run_logs_body(resp.body, run_id)
        if not page.ok():
            tail.pages = pages
            tail.fetch_error = page.fetch_error.copy()
            return tail^
        if len(page.run_id.as_bytes()) > 0:
            tail.run_id = page.run_id.copy()
        for i in range(len(page.records)):
            tail.records.append(page.records[i].copy())
        # ★ THE MEMORY BOUND, applied as we go rather than at the end.
        if keep_last > 0 and len(tail.records) > keep_last:
            var drop = len(tail.records) - keep_last
            var kept = List[RunLogRecord]()
            for i in range(drop, len(tail.records)):
                kept.append(tail.records[i].copy())
            tail.records = kept^
            tail.dropped_older += drop
        tail.done = page.done
        var advanced = page.next_cursor > cursor
        if page.next_cursor > tail.next_cursor:
            tail.next_cursor = page.next_cursor
        if len(page.records) == 0 or page.done or not advanced:
            # The three DATA ends of the stream. Nothing new, the route said it
            # is finished, or the cursor stood still (anti-livelock).
            tail.pages = pages
            return tail^
        cursor = page.next_cursor
    # ★ THE HARD CAP, and it SAYS SO. A drain that stopped because it hit the
    # page ceiling has NOT reached the end of the stream, and reporting `pages`
    # without that sentence would let a reader conclude it had.
    tail.pages = pages
    tail.fetch_error = (
        String("stopped after the ")
        + String(cap_pages)
        + String("-page ceiling with the stream still advancing (cursor at ")
        + String(tail.next_cursor)
        + String("); re-read from `--after ")
        + String(tail.next_cursor)
        + String("` for the rest")
    )
    return tail^
