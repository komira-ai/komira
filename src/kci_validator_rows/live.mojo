# =============================================================================
# kci_validator_rows/live.mojo — ★ EMIT THE ROW WHEN IT COMPLETES, NOT WHEN THE
#   RUN DOES. The one spelling every app validator's `MatrixOutcome`
#   streams through.
# =============================================================================
#
# ── ⛔ THE DEFECT THIS EXISTS FOR ────────────────────────────────────────────
# Every validator in this family accumulates `RowResult`s in memory and flushes
# them all at the end through `print_report()`. That is correct for a run that
# reaches the end, and it loses EVERYTHING for a run that does not.
#
# A validator that buffers rows and prints them at exit loses every row when
# the platform cancels the run (for example, a Cloud Run execution cancelled at
# its deadline). Rows computed for minutes never reach anyone: they were
# computed into a buffer whose only flush is a line the process never reached.
#
# ── ★ WHY STREAMING AND NOT A SIGTERM HANDLER ───────────────────────────────
# Cloud Run does send SIGTERM before SIGKILL, so a handler that flushed the
# buffer would have caught a platform cancel. It would catch nothing else:
#
#   * a SIGKILL (the grace period expiring) runs no handler at all;
#   * an OOM kill runs no handler;
#   * a container crash or a `raise` escaping the leg runs no handler;
#   * and a validator's `main` terminates via libc `exit`, so nothing with a
#     `__del__` is a candidate either.
#
# A streamed row has no window to lose. It is on stdout BEFORE the next
# assertion starts, so every one of those five terminations keeps every row that
# had completed. The handler is strictly weaker AND strictly more dangerous:
# flushing a `List[RowResult]` means allocating and concatenating Strings inside
# a signal context, which is not async-signal-safe in any dialect.
#
# ── ⭐ `flush=True` IS THE LOAD-BEARING HALF, NOT DECORATION ─────────────────
# `print` in this dialect writes through a USERSPACE buffer. A row printed and
# not flushed is a row sitting in this process's own memory, which is exactly
# where it was before — the defect, relocated. So the emit flushes, every row,
# and the cost is one `write(2)` per row on a validator whose rows each cost
# network round trips anyway.
#
# ── ⛔ IT MUST NOT BE CONFUSABLE WITH THE END-OF-RUN REPORT ──────────────────
# `print_report()`'s format is UNCHANGED and is still the aggregate of record:
# operators and every after-the-fact reading of a run key on
# `[PASS] <name> …` / `VERDICT: …` lines. A streamed row therefore carries its
# own marker and its own ordinal FIRST, so a prefix-anchored reader of the report
# cannot pick one up, and a reader who sees one knows it is a progress line whose
# verdict has not been computed yet.
#
# ⚠ THE ORDINAL IS WITHIN ITS OWN LEG, and each leg restarts at 1. A validator
# may run several legs, each its own `MatrixOutcome`; numbering them globally
# would need a counter shared across those structs, which is state whose only
# purpose is cosmetic. What the
# ordinal is FOR is the truncation question — "row 7 of this leg was the last
# thing that completed" — and it answers that exactly.
#
# ── NO DEPS, like the rest of this package ──────────────────────────────────
# Pure `String` work plus one `print`.
# =============================================================================


comptime LIVE_ROW_MARKER: String = "LIVE-ROW"
"""The token that opens a STREAMED row line.

⛔ DELIBERATELY NOT `[PASS]`/`[FAIL]`-leading. Those two tags open every line of
the end-of-run report, and a progress line that opened the same way would be
counted as a report row by anything reading the log positionally — doubling
every row in the aggregate a reader reconstructs by hand. The tag still APPEARS
(it is the legible half), it just does not come first."""


def live_row_line(ordinal: Int, var formatted: String) -> String:
    """`LIVE-ROW <n>: <the row's own report line>`.

    Pure, and separate from the `print` on purpose: a line-builder that only
    exists inside a print statement is a format nothing can import and therefore
    nothing can test.

    `formatted` is whatever the caller's `RowResult.format()` produced. This
    function does not know the row model and must not: `kci_validator_rows`'s
    consumers each own their own `RowResult`, and the thing they share is a
    rendered line."""
    return (
        String(LIVE_ROW_MARKER)
        + String(" ")
        + String(ordinal)
        + String(": ")
        + formatted^
    )


def emit_live_row(ordinal: Int, var formatted: String):
    """Put one completed row on stdout NOW, flushed.

    ⛔ THE `flush=True` IS NOT OPTIONAL — see the header. Without it the row is
    buffered in this process and a SIGKILL, an OOM or a cancel loses it, which is
    the whole defect this function exists to close."""
    print(live_row_line(ordinal, formatted^), flush=True)
