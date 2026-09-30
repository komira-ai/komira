# =============================================================================
# kci_logs/run_log_path.mojo — the run-scoped READ paths of the pipeline
#   manager, in ONE place every validator and komira_ci compose from.
# =============================================================================
#
# ⛔ WHY THIS FILE EXISTS: a failing validate step should return the relevant
# logs. A validator that can only print
#
#     Read the run's own log stream (.../runs/{r}/logs?after=&limit=)
#     for the failing stage.
#
# leaves every diagnosis of that class to a hand-rolled curl. The path
# composition is the first thing a caller needs, so it must be shareable.
#
# ONE DERIVATION. Every caller imports these rather than defining its own; a
# second derivation of the same path is exactly how two callers would drift
# onto different runs.
#
# ── ENCAPSULATION ────────────────────────────────────────────────────────────
# Pure String arithmetic. ZERO deps, ZERO UnsafePointer, no origin, no FFI, no
# transport — this file names no socket and cannot fail. def-based, Mojo 1.0.0b2.
# =============================================================================


comptime DEFAULT_RUN_PATH_PREFIX: String = "/pipelines/runs/"
"""The run-status route prefix (`GET /pipelines/runs/<run_id>`). A run id appended
to this is the pipeline manager's run-store read."""


comptime DEFAULT_RUN_LOG_PAGE_LIMIT: Int = 200
"""The default `?limit=` this library asks for on ONE page.

The route caps `limit` at 1000 and defaults it to 500. 200 is deliberately
BELOW both: a page is a network round trip whose whole content may be printed to
an operator's terminal, and the paging loop above (`fetch_run_log_tail`) exists
precisely so that asking for less does not mean seeing less."""


def join_url(base: String, path: String) -> String:
    """Join a base `target_url` (`https://svc.run.app`, no trailing slash expected)
    with a `path` (`/pipelines/runs/<id>`) into ONE probe URL, collapsing a double
    slash and inserting a missing one. Empty base -> the path verbatim (surfaced
    later as a dial fault)."""
    if base.byte_length() == 0:
        return path.copy()
    var b = base.copy()
    while b.byte_length() > 0 and b.endswith(String("/")):
        # 1.0.0: `b = String(b[...])` aliases `b` immutably while constructing
        # into it. Materialize the trimmed value first, then transfer.
        var trimmed = String(b[byte=0 : b.byte_length() - 1])
        b = trimmed^
    if path.byte_length() == 0:
        return b^
    if path.startswith(String("/")):
        return b + path
    return b + String("/") + path


def build_run_status_path(run_path_prefix: String, run_id: String) -> String:
    """Compose the run-status READ path `<prefix><run_id>` (e.g.
    `/pipelines/runs/00000000-0000-0000-0000-000000000000`), inserting exactly one
    `/` between the prefix and the id (idempotent whether or not the prefix ends in
    a slash)."""
    var p = run_path_prefix.copy()
    if p.byte_length() == 0:
        p = DEFAULT_RUN_PATH_PREFIX.copy()
    if p.endswith(String("/")):
        return p + run_id
    return p + String("/") + run_id


def build_run_logs_path(run_path_prefix: String, run_id: String) -> String:
    """Compose the run-LOGS read path `<prefix><run_id>/logs` — the pipeline
    manager's run-log route. Derived
    from the SAME prefix + run id as the status path so the two cannot drift onto
    different runs."""
    return build_run_status_path(run_path_prefix, run_id) + String("/logs")


def build_run_logs_query(after: Int, limit: Int) -> String:
    """The `?after=<cursor>&limit=<n>` query string for ONE page of the run-log
    tail, or the EMPTY string when neither is worth stating.

    THE CURSOR CONTRACT, from the handler itself: `after` returns only lines with
    `seq > after` (0 or omitted = from the start) and a negative value is clamped
    to 0 server-side; `limit` is defaulted to 500 and capped at 1000, and a
    non-positive value falls back to the default. This composer states only what
    the caller actually chose — `after <= 0` and `limit <= 0` both emit nothing,
    which is byte-identical to the route's own defaults."""
    var q = String("")
    if after > 0:
        q += String("after=") + String(after)
    if limit > 0:
        if q.byte_length() > 0:
            q += String("&")
        q += String("limit=") + String(limit)
    if q.byte_length() == 0:
        return q^
    return String("?") + q


def build_run_logs_url(
    base_url: String, run_path_prefix: String, run_id: String, after: Int, limit: Int
) -> String:
    """The FULL URL of one page of a run's log tail: `join_url` over
    `build_run_logs_path` + `build_run_logs_query`. The one call a transport
    conformer needs, so no conformer re-derives a path."""
    return join_url(
        base_url, build_run_logs_path(run_path_prefix, run_id)
    ) + build_run_logs_query(after, limit)
