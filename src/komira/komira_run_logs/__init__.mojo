# =============================================================================
# komira_run_logs — READ A PIPELINE RUN'S STAGE LOGS. The shared home.
# =============================================================================
#
# ⛔ WHY THIS PACKAGE EXISTS: a failing validate step should come back with the
# relevant logs, not with advice to go and read them.
#
# A validator that only prints
#
#     Read the run's own log stream (.../apps/runs/{r}/logs?after=&limit=)
#     for the failing stage.
#
# points at a real route with no tool behind it, so every diagnosis of that
# class becomes a hand-rolled curl. This package is the tool: the path, the
# paging read, the allow-listed parse, and the bounded render — in one place,
# shared by every validator and by the deploy tool (`komira_ci`).
#
# THREE FILES, THREE JOBS:
#   * `run_log_path`   — compose the URL. Pure String arithmetic; cannot fail.
#                        One derivation of the path, so two callers cannot
#                        drift onto different runs.
#   * `run_log_tail`   — the record, the tail, the FIELD-ALLOW-LISTED parse, and
#                        the BOUNDED renderer. ⛔ Never echoes a response body.
#   * `run_log_reader` — the transport SEAM + the cursor-paging read.
#                        ⛔ Never raises: it is an enrichment, and an enrichment
#                        that can fail its caller is worse than no enrichment.
#
# ZERO deps. Nothing here names a socket, a cloud, or a proto.
# =============================================================================

from komira_run_logs.run_log_path import (
    DEFAULT_RUN_PATH_PREFIX,
    DEFAULT_RUN_LOG_PAGE_LIMIT,
    join_url,
    build_run_status_path,
    build_run_logs_path,
    build_run_logs_query,
    build_run_logs_url,
)
from komira_run_logs.run_log_tail import (
    RUN_LOG_FIELD_ALLOWLIST,
    RUN_LOG_REDACTED,
    # ★★ WHICH STREAM A TAIL CAME FROM — the renderer speaks the
    # SOURCE's vocabulary rather than choosing one. A producer that claims no
    # kind gets the stage-record stream, which is what this library was written
    # for.
    RUN_LOG_STREAM_STAGE_RECORDS,
    RUN_LOG_STREAM_CONTAINER_STDOUT,
    # ★★ THE CREDIBLE FLOOR. It lives beside the stream kind it is about so
    # that the WAITER (`komira_cloud_logs`) and the RENDERER (this package) read
    # ONE number, and the report the operator reads carries the credibility
    # judgement the tool has just made.
    CONTAINER_LOG_CREDIBLE_FLOOR,
    DEFAULT_MAX_RENDERED_RECORDS,
    DEFAULT_MAX_MESSAGE_BYTES,
    RunLogRecord,
    RunLogTail,
    parse_run_logs_body,
    redact_secretish,
    render_run_log_tail,
    # ⛔ THE BOUNDARY PRIMITIVE. `s[byte=0:n]` aborts the process when `n` is
    # not a UTF-8 codepoint boundary. A walk-back copy-pasted into each caller
    # is one a new caller forgets, and the abort ships again. Exported so the
    # next byte ceiling calls it rather than re-deriving it.
    utf8_clip_end,
)
from komira_run_logs.run_log_reader import (
    DEFAULT_MAX_PAGES,
    RunLogResponse,
    RunLogTransport,
    fetch_run_log_tail,
)
