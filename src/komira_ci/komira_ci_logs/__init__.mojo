# =============================================================================
# komira_ci_logs — READ THE LOGS BEHIND A FAILED STEP: a pipeline run's stage
# logs, and a terminated cloud unit's container output.
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
# or a report that ends with "read it with: gcloud logging read ..." points at
# a real artifact with no tool behind it, so every diagnosis of that class
# becomes a hand-rolled curl or a raw cloud command. This package is the tool,
# shared by every validator and by the deploy tool (`komira_ci`).
#
# TWO FAMILIES, ONE RENDERER.
#
# RUN LOGS — a pipeline run's stage-record stream:
#   * `run_log_path`   — compose the URL. Pure String arithmetic; cannot fail.
#                        One derivation of the path, so two callers cannot
#                        drift onto different runs.
#   * `run_log_tail`   — the record, the tail, the FIELD-ALLOW-LISTED parse, and
#                        the BOUNDED renderer. ⛔ Never echoes a response body.
#   * `run_log_reader` — the transport SEAM + the cursor-paging read.
#                        ⛔ Never raises: it is an enrichment, and an enrichment
#                        that can fail its caller is worse than no enrichment.
#
# CLOUD LOGS — one terminated run-to-completion unit's container output (a
# Cloud Run Job execution or an ECS task), addressed by the provider's own
# handle. Same trait-seamed transport, same never-raises contract, same field
# allow-list; it adapts onto `RunLogTail` rather than growing a second printer:
#   * `cloud_log_source`    — the CLOUD-NEUTRAL seam (`CloudLogSource`), the two
#                             value PODs, the not-configured default, the
#                             hermetic double, and the `RunLogTail` ADAPTER that
#                             is why no new renderer exists.
#   * `json_scan`           — the bounded JSON scanner both cloud arms parse
#                             with. The `json_skip_value` in it is what makes
#                             every allow-list in the cloud family hold.
#   * `gcp_logging_query`   — GCP, PURE: the Cloud Logging filter (byte-identical
#                             to the one in the equivalent `gcloud logging read`
#                             command), the `entries:list` body, the
#                             allow-listed parse.
#   * `aws_cloudwatch_query`— AWS, PURE: the ECS awslogs stream derivation, the
#                             `GetLogEvents` body, the allow-listed parse.
#
# ★★ ONE CREDIBLE FLOOR. `CONTAINER_LOG_CREDIBLE_FLOOR` is defined once, in
# `run_log_tail`, beside the stream kind it is about, so the WAITER
# (`cloud_log_source`) and the RENDERER read ONE number. ⛔ It must not be
# re-declared anywhere else.
#
# BOTH CLOUDS HAVE A LIVE CONFORMER. GCP:
#   `komira_gcp_bridge.LiveCloudRunExecutionLogs`, driven by
#   `CloudRunJobValidator`. AWS: `komira_aws_iac_live.LiveEcsTaskLogs`, driven
#   by `FargateTaskValidator`. A red step on EITHER cloud reports its own
#   container output.
#
#   ⚠ THE ONE ASYMMETRY, AND IT IS THE PROVIDERS', NOT OURS. A GCP
#   handle is TOTAL — the execution resource name carries the project, so the
#   conformer is configured with a credential and nothing else. An ECS task ARN
#   carries the region, the account and the task id but NOT the task's log
#   DESTINATION, because `logConfiguration` is task-DEFINITION state. So the AWS
#   conformer is additionally configured with `{log_group, stream_prefix,
#   container_name}` — by the same party that registered the definition, which
#   is why that is configuration and not a lossy re-encoding. See
#   `LiveEcsTaskLogs`' header.
#
# ⚠ METRICS ARE **NOT** HERE, AND THE SIBLING PACKAGE IS `komira_cloud_metrics`.
#   It carries the seam and both clouds' pure request/parse halves and has NO
#   live conformer and NO caller ON PURPOSE — see its `__init__` header for the
#   argued case (a deploy gate's questions all have direct, synchronous answers;
#   a metric is a lagging sampled proxy; and `timeSeries.list` can stall on
#   large responses in exactly the Cloud Run Job environment an in-cloud
#   validate step runs in).
#
# ZERO deps. Nothing here names a socket, a cloud SDK, or a proto — the
# transport is a trait, which is why every request shape and every failure
# branch is provable with no network. ⛔ Keep it that way: a dep on an HTTP
# client here would put a socket on the `-I` line of every consumer and would
# make the pure halves untestable without one.
# =============================================================================

from komira_ci_logs.run_log_path import (
    DEFAULT_RUN_PATH_PREFIX,
    DEFAULT_RUN_LOG_PAGE_LIMIT,
    join_url,
    build_run_status_path,
    build_run_logs_path,
    build_run_logs_query,
    build_run_logs_url,
)
from komira_ci_logs.run_log_tail import (
    RUN_LOG_FIELD_ALLOWLIST,
    RUN_LOG_REDACTED,
    # ★★ WHICH STREAM A TAIL CAME FROM — the renderer speaks the
    # SOURCE's vocabulary rather than choosing one. A producer that claims no
    # kind gets the stage-record stream, which is what this library was written
    # for.
    RUN_LOG_STREAM_STAGE_RECORDS,
    RUN_LOG_STREAM_CONTAINER_STDOUT,
    # ★★ THE CREDIBLE FLOOR. It lives beside the stream kind it is about so
    # that the WAITER (`cloud_log_source`) and the RENDERER (`run_log_tail`) read
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
from komira_ci_logs.run_log_reader import (
    DEFAULT_MAX_PAGES,
    RunLogResponse,
    RunLogTransport,
    fetch_run_log_tail,
)

from komira_ci_logs.cloud_log_source import (
    DEFAULT_CONTAINER_LOG_LIMIT,
    CloudLogEntry,
    # ★★ THE PAGING POLICY — pure arithmetic, zero transport, so
    # every branch of a bounded multi-page walk is provable with no network.
    DEFAULT_MAX_CONTAINER_LOG_PAGES,
    # ★★ AND THE EMPTY-PAGE BUDGET — the SECOND bound, because the
    # first one caps OUTPUT VOLUME and a page that returned nothing produced
    # none. See `DEFAULT_MAX_EMPTY_CONTAINER_LOG_PAGES`.
    CONTAINER_LOG_PAGE_ROUND_TRIP_MS,
    CONTAINER_LOG_EMPTY_PAGE_BUDGET_MS,
    DEFAULT_MAX_EMPTY_CONTAINER_LOG_PAGES,
    container_log_next_page_size,
    container_log_should_continue,
    # ★★ AND THE WALK LOOP ITSELF. The loop lives here, beside its policy, so
    # the conformers do not each re-write it behind a socket.
    ContainerLogPager,
    walk_container_log_pages,
    # ★★ THE SETTLE. Paging answers "is there more NOW"; it cannot
    # answer "will there be more in five seconds", and for a container that died
    # a moment ago that is the question. Policy here, mechanism in each
    # conformer — a sleep names a clock and the leaf names nothing.
    CONTAINER_LOG_SETTLE_S,
    DEFAULT_MAX_CONTAINER_LOG_SETTLES,
    container_log_should_settle,
    ContainerLogWalker,
    read_container_output_settled,
    CloudLogPage,
    CloudLogSource,
    NoCloudLogSource,
    ScriptedCloudLogSource,
    cloud_log_page_to_run_log_tail,
)
from komira_ci_logs.json_scan import (
    json_is_space,
    json_scan_number,
    json_scan_string,
    json_skip_space,
    json_skip_value,
)
from komira_ci_logs.gcp_logging_query import (
    ENTRIES_LIST_PATH,
    GCP_LOG_ENTRY_FIELD_ALLOWLIST,
    LOGGING_HOST,
    NON_TEXT_PAYLOAD_MARKER,
    cloud_run_execution_entries_list_body,
    cloud_run_execution_log_filter,
    entries_list_body,
    execution_leaf,
    execution_project,
    json_escape,
    parse_entries_list_body,
    segment_after,
)
from komira_ci_logs.aws_cloudwatch_query import (
    AWS_LOG_EVENT_FIELD_ALLOWLIST,
    CLOUDWATCH_LOGS_TARGET,
    cloudwatch_logs_host,
    ecs_task_arn_region,
    ecs_task_id,
    ecs_task_log_stream,
    get_log_events_body,
    parse_get_log_events_body,
)
